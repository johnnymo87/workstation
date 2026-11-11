#!/usr/bin/env bash
# Tests for users/dev/hm-atomic-profile.sh (installPackages without the window in
# which ~/.nix-profile has no home-manager packages).
#
# `nix` and `nix-env` are STUBS that log every call and move fake symlinks, so the
# suite runs in the flake-check sandbox and never touches a real profile. The real
# commands were exercised by hand on cloudbox 2026-11-11 against a throwaway
# profile in /tmp (live profile went generation 1 -> 2 in one step, with the
# home-manager-path element replaced); see the commit that added this file.
#
# The property under test is the one the module exists for: the LIVE profile link
# is written exactly once, by `nix-env --set`, and only after the staged profile is
# complete. Every remove/install happens against the staging profile.
#
# Run: bash users/dev/test-hm-atomic-profile.sh
set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/hm-atomic-profile.sh"

pass_n=0
ok()   { printf 'PASS  %s\n' "$1"; pass_n=$((pass_n + 1)); }
oops() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf -- "$ROOT"' EXIT
export TMPDIR="$ROOT/tmp"; mkdir -p "$TMPDIR"
STUB="$ROOT/stub"; mkdir -p "$STUB"
# No /usr/bin/env in the flake-check sandbox: stubs get an absolute interpreter.
BASH_BIN="$(command -v bash)"

# --- stubs -------------------------------------------------------------------
printf '#!%s\n' "$BASH_BIN" > "$STUB/nix"
cat >> "$STUB/nix" <<'EOF'
# stub nix: profile list|remove|install --profile P ...
echo "nix $*" >> "$STUB_LOG"
[[ "$1" == profile ]] || exit 2
op="$2"; shift 2
[[ "$1" == --profile ]] || exit 2
P="$2"; shift 2
case "$op" in
  list) cat "$(readlink -f "$P")/list.json" ;;
  remove)
    n=$(( $(cat "$STUB_DIR/n") + 1 )); echo $n > "$STUB_DIR/n"
    g="$STUB_DIR/store/gen$n"; mkdir -p "$g"
    jq '.elements |= with_entries(select(.key != "home-manager-path"))' \
      "$(readlink -f "$P")/list.json" > "$g/list.json"
    ln -sfn "$g" "$P" ;;
  install)
    [[ -n "${STUB_FAIL_INSTALL:-}" ]] && { echo "error: conflict" >&2; exit 1; }
    n=$(( $(cat "$STUB_DIR/n") + 1 )); echo $n > "$STUB_DIR/n"
    g="$STUB_DIR/store/gen$n"; mkdir -p "$g"
    jq --arg p "$1" '.elements["home-manager-path"] = {storePaths: [$p]}' \
      "$(readlink -f "$P")/list.json" > "$g/list.json"
    ln -sfn "$g" "$P" ;;
  *) exit 2 ;;
esac
EOF
printf '#!%s\n' "$BASH_BIN" > "$STUB/nix-env"
cat >> "$STUB/nix-env" <<'EOF'
echo "nix-env $*" >> "$STUB_LOG"
[[ "$1" == --profile && "$3" == --set ]] || exit 2
[[ -n "${STUB_FAIL_SET:-}" ]] && exit 1
ln -sfn "$4" "$2"
EOF
chmod +x "$STUB/nix" "$STUB/nix-env"
export HM_ATOMIC_NIX="$STUB/nix" HM_ATOMIC_NIX_ENV="$STUB/nix-env"

# A fresh world: a live profile link -> generation link -> store dir whose
# list.json has home-manager-path (old) plus one unrelated package.
setup() {
  W="$ROOT/w$1"; mkdir -p "$W/store/gen0" "$W/profiles" "$W/home"
  export STUB_DIR="$W" STUB_LOG="$W/log"; : > "$STUB_LOG"; echo 0 > "$W/n"
  jq -n '{version:3, elements:{
            "home-manager-path": {storePaths:["/nix/store/old-home-manager-path"]},
            "sops": {storePaths:["/nix/store/x-sops"]}}}' > "$W/store/gen0/list.json"
  ln -s "$W/store/gen0" "$W/profiles/profile-1-link"
  ln -s profile-1-link "$W/profiles/profile"
  ln -s "$W/profiles/profile" "$W/home/.nix-profile"
  LIVE="$W/profiles/profile"
}
hm_of() { jq -r '.elements["home-manager-path"].storePaths[0] // "NONE"' "$(readlink -f "$1")/list.json"; }

# --- hmResolveProfileLink ----------------------------------------------------
setup r
[[ "$(hmResolveProfileLink "$W/home/.nix-profile")" == "$LIVE" ]] \
  && ok "resolves ~/.nix-profile to the profile link nix manages" \
  || oops "did not resolve ~/.nix-profile"
ln -s ../profiles/profile "$W/home/rel"
[[ "$(hmResolveProfileLink "$W/home/rel")" == "$W/home/../profiles/profile" ]] \
  && ok "resolves a relative ~/.nix-profile link" || oops "relative link"
hmResolveProfileLink "$W/store/gen0" >/dev/null && oops "accepted a non-link" || ok "refuses a non-link"
ln -s "$W/store/gen0" "$W/home/direct"
hmResolveProfileLink "$W/home/direct" >/dev/null && oops "accepted a link straight to a store dir" \
  || ok "refuses a link that is not a profile-generation chain"

# --- happy path --------------------------------------------------------------
setup a
hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path >/dev/null 2>&1 || oops "happy path returned non-zero"
[[ "$(hm_of "$LIVE")" == /nix/store/new-home-manager-path ]] && ok "live profile ends on the new home-manager-path" \
  || oops "live profile has $(hm_of "$LIVE")"
jq -e '.elements.sops' "$(readlink -f "$LIVE")/list.json" >/dev/null && ok "unrelated packages kept" || oops "sops lost"
[[ "$(grep -c "$LIVE" "$STUB_LOG")" == 1 ]] && grep -q "^nix-env --profile $LIVE --set " "$STUB_LOG" \
  && ok "the live profile is written exactly once, by nix-env --set" || oops "live writes: $(cat "$STUB_LOG")"
[[ "$(tail -1 "$STUB_LOG")" == "nix-env --profile $LIVE --set "* ]] && ok "the live switch is the LAST call" \
  || oops "order: $(cat "$STUB_LOG")"
grep -q "^nix profile remove --profile $TMPDIR/hm-atomic-profile\..*/profile /nix/store/old-home-manager-path$" "$STUB_LOG" \
  && ok "the old home-manager-path is removed from the STAGING profile, by store path" || oops "remove: $(cat "$STUB_LOG")"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "staging dir cleaned up" || oops "staging left: $(ls "$TMPDIR")"

# --- the window property, observed from outside --------------------------------
# Watch the live profile after every stub call: it must never lack home-manager-path.
setup b
printf '#!%s\n' "$BASH_BIN" > "$STUB/watch"
cat >> "$STUB/watch" <<'EOF'
"$@"; rc=$?
jq -e '.elements["home-manager-path"]' "$(readlink -f "$WATCH_LIVE")/list.json" >/dev/null || echo EMPTY >> "$WATCH_OUT"
exit $rc
EOF
chmod +x "$STUB/watch"
export WATCH_LIVE="$LIVE" WATCH_OUT="$W/watch"; : > "$WATCH_OUT"
cat > "$STUB/nixw" <<EOF
#!$BASH_BIN
exec "$STUB/watch" "$STUB/nix" "\$@"
EOF
chmod +x "$STUB/nixw"
HM_ATOMIC_NIX="$STUB/nixw" hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path >/dev/null 2>&1 || oops "watched run failed"
[[ ! -s "$WATCH_OUT" ]] && ok "live profile never observed without home-manager-path" || oops "window observed"

# --- first activation: nothing to remove -----------------------------------------
setup c
jq '.elements |= del(.["home-manager-path"])' "$W/store/gen0/list.json" > "$W/l" && mv "$W/l" "$W/store/gen0/list.json"
hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path >/dev/null 2>&1 || oops "first activation failed"
! grep -q 'profile remove' "$STUB_LOG" && [[ "$(hm_of "$LIVE")" == /nix/store/new-home-manager-path ]] \
  && ok "first activation installs without removing" || oops "first activation: $(cat "$STUB_LOG")"

# --- failures leave the live profile untouched -----------------------------------
setup d
before="$(readlink "$LIVE")"
STUB_FAIL_INSTALL=1 hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path >/dev/null 2>&1 \
  && oops "install failure returned 0" || true
[[ "$(readlink "$LIVE")" == "$before" && "$(hm_of "$LIVE")" == /nix/store/old-home-manager-path ]] \
  && ok "install failure: non-zero, live profile untouched" || oops "install failure changed live"
! grep -q '^nix-env' "$STUB_LOG" && ok "install failure: nix-env --set never called" || oops "set called after failure"
[[ -z "$(ls -A "$TMPDIR")" ]] && ok "install failure: staging dir cleaned up" || oops "staging left after failure"

setup e
STUB_FAIL_SET=1 hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path >/dev/null 2>&1 \
  && oops "set failure returned 0" || ok "nix-env --set failure is reported"

# --- dry run ----------------------------------------------------------------------
setup f
out="$(DRY_RUN=1 hmAtomicReplaceProfile "$LIVE" /nix/store/new-home-manager-path 2>&1)" || oops "dry run failed"
[[ ! -s "$STUB_LOG" && "$(hm_of "$LIVE")" == /nix/store/old-home-manager-path && "$out" == *"dry run"* ]] \
  && ok "DRY_RUN changes nothing and says what it would do" || oops "dry run: $(cat "$STUB_LOG")"

echo "all hm-atomic-profile tests passed ($pass_n)"
