#!/usr/bin/env bash
#
# Tests reset-workspace's turn-cut wiring (workstation-dg6): the shell side that
# snapshots in-flight turns before each restart and sends the notices after.
# turn-cut-notice itself is tested by pkgs/turn-cut-notice/test_turn_cut_notice.py;
# this suite proves the reset hands it the right arguments, and -- the property
# that matters most -- that NO failure of it can take the reset down.
#
# Drives the REAL helper functions, extracted from the BUILT reset-workspace
# (same seam as test-shada-report.sh), against a fake `turn-cut-notice`,
# `honk` and `systemctl` on PATH. Then pins the call sites in the built script
# so a refactor that drops or reorders them fails here.
set -uo pipefail

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

LAB="$(mktemp -d "${TMPDIR:-/tmp}/reset-turn-cut-test.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
if [ -n "${RESET_WORKSPACE_BIN:-}" ]; then
  src="$RESET_WORKSPACE_BIN"
else
  built="$(nix build --no-link --print-out-paths "$repo_root#reset-workspace" 2>/dev/null | tail -1)"
  [ -n "$built" ] || { echo "FAIL: could not build reset-workspace"; exit 1; }
  src="$built/bin/reset-workspace"
fi
[ -r "$src" ] || { echo "FAIL: reset-workspace not readable: $src"; exit 1; }

# ---- extract the helpers -----------------------------------------------------
extract() { # extract <fn>: the function body, 4-space indented as built
  awk -v fn="$1" '
    $0 ~ "^    " fn "\\(\\) \\{" { on=1 }
    on { print }
    on && /^    \}$/ { exit }
  ' "$src"
}
fns=""
for f in get_unit_invocation_id turn_cut_snapshot_opencode turn_cut_snapshot_goose turn_cut_notify; do
  body="$(extract "$f")"
  if [ -z "$body" ]; then bad "could not extract $f -- source drifted"; continue; fi
  fns="$fns$body"$'\n'
done
[ "$fail" -eq 0 ] || exit 1
ok "extracted the four turn-cut helpers from $src"

# ---- fakes -------------------------------------------------------------------
BIN="$LAB/bin"; mkdir -p "$BIN"
BASH_BIN="$(command -v bash)"   # no /usr/bin/env in a nix build sandbox
CALLS="$LAB/calls"
cat > "$BIN/turn-cut-notice" <<'EOF'
#!BASH
printf '%s\n' "$*" >> "$CALLS"
case "$1" in
  snapshot-*) [ "${FAKE_TCN_RC:-0}" -eq 0 ] && { while [ $# -gt 0 ]; do [ "$1" = --out ] && echo '{}' > "$2"; shift; done; }; exit "${FAKE_TCN_RC:-0}" ;;
  notify) exit "${FAKE_TCN_NOTIFY_RC:-0}" ;;
esac
exit 2
EOF
cat > "$BIN/systemctl" <<'EOF'
#!BASH
# show -p InvocationID --value opencode-serve@<port>.service
for a in "$@"; do case "$a" in opencode-serve@*.service) p="${a#opencode-serve@}"; p="${p%.service}";; esac; done
case "${p:-}" in
  4096) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  4097) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  4098) echo not-an-invocation-id ;;
  *) echo "" ;;
esac
EOF
cat > "$BIN/honk" <<'EOF'
#!BASH
exit 0
EOF
sed -i "1s|^#!BASH$|#!$BASH_BIN|" "$BIN"/*
chmod +x "$BIN"/*
export CALLS

# Run a snippet with the helpers loaded, as the reset would (set -e, pipefail,
# nounset: writeShellApplication's options).
run() { # run <snippet> -> stdout+stderr in $OUT, rc in $RC
  OUT="$(
    PATH="$BIN:$PATH" XDG_STATE_HOME="$LAB/state" OPENCODE_DB="${DB_OVERRIDE:-$LAB/opencode.db}" \
    bash -c '
      set -euo pipefail
      log() { printf "[reset-workspace] %s\n" "$*" >&2; }
      TURN_CUT_DIR="$XDG_STATE_HOME/reset-workspace"
      TURN_CUT_OC="$TURN_CUT_DIR/turn-cut-opencode.json"
      TURN_CUT_GOOSE="$TURN_CUT_DIR/turn-cut-goose.json"
      TURN_CUT_DB="$OPENCODE_DB"
      TURN_CUT_SNAPS=()
      '"$fns"'
      '"$1"'
      echo "REACHED_END"
    ' 2>&1
  )"
  RC=$?
}

: > "$LAB/opencode.db"

# 1. opencode snapshot passes only well-formed invocation ids, comma-joined.
: > "$CALLS"
run 'turn_cut_snapshot_opencode user 4096 4097 4098 4099'
if [ "$RC" -eq 0 ] && grep -q -- '--live-invocation-ids aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --out' "$CALLS"; then
  ok "snapshot-opencode gets the pool's valid InvocationIDs"
else bad "snapshot-opencode args: rc=$RC calls=$(cat "$CALLS") out=$OUT"; fi
grep -q -- "--db $LAB/opencode.db" "$CALLS" && ok "snapshot-opencode reads \$OPENCODE_DB" || bad "db arg: $(cat "$CALLS")"

# 2. a failing snapshot is non-fatal and reported.
: > "$CALLS"
FAKE_TCN_RC=1 run 'if turn_cut_snapshot_opencode user 4096; then echo SNAP_OK; else echo SNAP_FAILED; fi'
if grep -q SNAP_FAILED <<<"$OUT" && grep -q REACHED_END <<<"$OUT" && grep -q 'WARNING: turn-cut: opencode snapshot failed' <<<"$OUT"; then
  ok "failed opencode snapshot: warning, reset continues"
else bad "failed opencode snapshot: rc=$RC out=$OUT"; fi
[ ! -e "$LAB/state/reset-workspace/turn-cut-opencode.json" ] && ok "failed snapshot leaves no stale file" || bad "stale snapshot file left behind"

# 3. missing opencode.db: no call, no failure.
: > "$CALLS"
DB_OVERRIDE="$LAB/nope.db" run 'turn_cut_snapshot_opencode user 4096 || echo SNAP_FAILED'
if grep -q SNAP_FAILED <<<"$OUT" && grep -q REACHED_END <<<"$OUT" && [ ! -s "$CALLS" ]; then
  ok "missing opencode.db: skipped"
else bad "missing db: out=$OUT calls=$(cat "$CALLS")"; fi

# 4. goose snapshot; honk absent -> skipped.
: > "$CALLS"
run 'turn_cut_snapshot_goose'
grep -q '^snapshot-goose --out .*/turn-cut-goose.json$' "$CALLS" && ok "snapshot-goose called" || bad "snapshot-goose: $(cat "$CALLS") $OUT"
mv "$BIN/honk" "$BIN/honk.off"
: > "$CALLS"
OUT="$(PATH="$BIN:/nonexistent" XDG_STATE_HOME="$LAB/state" OPENCODE_DB="$LAB/opencode.db" "$(command -v bash)" -c '
  set -euo pipefail
  log() { printf "[reset-workspace] %s\n" "$*" >&2; }
  TURN_CUT_DIR="$XDG_STATE_HOME/reset-workspace"; TURN_CUT_GOOSE="$TURN_CUT_DIR/g.json"
  mkdir() { :; }; rm() { :; }
  '"$(extract turn_cut_snapshot_goose)"'
  turn_cut_snapshot_goose || echo SKIPPED; echo REACHED_END' 2>&1)"
mv "$BIN/honk.off" "$BIN/honk"
if grep -q SKIPPED <<<"$OUT" && grep -q 'honk not on PATH' <<<"$OUT" && [ ! -s "$CALLS" ]; then
  ok "no honk: goose snapshot skipped"
else bad "no honk: $OUT"; fi

# 5. notify: nothing recorded -> no call.
: > "$CALLS"
run 'turn_cut_notify'
if [ "$RC" -eq 0 ] && [ ! -s "$CALLS" ] && grep -q 'no snapshot to act on' <<<"$OUT"; then
  ok "notify with no snapshots does nothing"
else bad "empty notify: $OUT"; fi

# 6. notify passes every recorded snapshot and the db.
: > "$CALLS"
run 'TURN_CUT_SNAPS+=("/s/oc.json" "/s/g.json"); turn_cut_notify'
if grep -q "^notify --snapshot /s/oc.json --snapshot /s/g.json --db $LAB/opencode.db$" "$CALLS"; then
  ok "notify gets both snapshots and the db"
else bad "notify args: $(cat "$CALLS")"; fi

# 7. a failing notify is non-fatal.
FAKE_TCN_NOTIFY_RC=1 run 'TURN_CUT_SNAPS+=("/s/oc.json"); turn_cut_notify; echo AFTER_NOTIFY'
if [ "$RC" -eq 0 ] && grep -q AFTER_NOTIFY <<<"$OUT" && grep -q 'WARNING: turn-cut: some notices were not sent' <<<"$OUT"; then
  ok "failed notify: warning, reset continues"
else bad "failed notify: rc=$RC $OUT"; fi

# ---- call sites in the built script --------------------------------------------
line_of() { grep -n -m1 -F -- "$1" "$src" | cut -d: -f1; }
snap_oc="$(line_of 'if turn_cut_snapshot_opencode "$POOL_SCOPE"')"
restart_pool="$(line_of '    restart_pool_target "$POOL_SCOPE"')"
add_oc="$(line_of 'TURN_CUT_SNAPS+=("$TURN_CUT_OC")')"
snap_g="$(line_of 'if turn_cut_snapshot_goose; then turn_cut_goose_ok=1; fi')"
restart_g="$(line_of 'sudo -n systemctl restart "$GOOSE_UNIT"')"
add_g="$(line_of 'TURN_CUT_SNAPS+=("$TURN_CUT_GOOSE")')"
notify="$(grep -n -m1 -x -F '    turn_cut_notify' "$src" | cut -d: -f1)"
report="$(line_of '    shada_watch_report "$nvim_exited"')"
for v in snap_oc restart_pool add_oc snap_g restart_g add_g notify report; do
  [ -n "${!v}" ] || bad "call site $v not found in the built script"
done
if [ "$fail" -eq 0 ] && [ "$snap_oc" -lt "$restart_pool" ] && [ "$restart_pool" -lt "$add_oc" ] \
   && [ "$add_oc" -lt "$snap_g" ] && [ "$snap_g" -lt "$restart_g" ] && [ "$restart_g" -lt "$add_g" ] \
   && [ "$add_g" -lt "$notify" ] && [ "$notify" -lt "$report" ]; then
  ok "order: snapshot < restart < record, opencode then goose, notify before the ShaDa report"
else bad "call-site order: $snap_oc $restart_pool $add_oc $snap_g $restart_g $add_g $notify $report"; fi
# The goose restart failure path must un-record the snapshot.
if awk -v a="$restart_g" 'NR>a && NR<a+6' "$src" | grep -q 'turn_cut_goose_ok=0'; then
  ok "a failed goose restart notifies nobody"
else bad "failed goose restart does not clear turn_cut_goose_ok"; fi
grep -q -- "-turn-cut-notice-" "$src" && ok "turn-cut-notice is on reset-workspace's PATH" \
  || bad "turn-cut-notice store path not in reset-workspace's PATH"

if [ "$fail" -eq 0 ]; then
  echo "all reset-workspace turn-cut tests passed"
else
  exit 1
fi
