#!/usr/bin/env bash
# Tests for the home-manager drift canary library (workstation-4ze8).
#
# Runs in `nix flake check` as the `hm-deploy-canary` check. Every assertion is
# hermetic: throwaway git repos and a scratch $TMPDIR tree, no network, no
# systemctl, no live profile. The CI sandbox has none of those.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../hm-deploy-gate-sh/hm-deploy-gate.sh"
# shellcheck source=/dev/null
source "$HERE/hm-deploy-canary.sh"

FAILED=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; FAILED=1; }
is() {
  local got="$1" want="$2" what="$3"
  if [ "$got" = "$want" ]; then pass "$what"; else fail "$what (got '$got', want '$want')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=canary GIT_AUTHOR_EMAIL=c@example.invalid
export GIT_COMMITTER_NAME=canary GIT_COMMITTER_EMAIL=c@example.invalid
# ISOLATE THE HOST'S GIT CONFIG. Without this the fixtures below behave
# differently on a developer box than in the nix sandbox, which is the failure
# this repo keeps relearning. Measured: the host config made `git tag` create an
# ANNOTATED tag ("fatal: no tag message?") and `git init` produce `main` where
# the sandbox produces `master`. Both silently broke fixtures rather than the
# code under test.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

echo "== hm_canary_beacon_state =="
SHA40=0123456789abcdef0123456789abcdef01234567
is "$(hm_canary_beacon_state "")"                    absent    "empty input is absent"
is "$(hm_canary_beacon_state $'\n')"                 empty     "newline-only is empty, not absent"
is "$(hm_canary_beacon_state "unknown")"             unknown   "the literal 'unknown' the gate writes"
is "$(hm_canary_beacon_state "$SHA40")"              ok        "a bare 40-hex rev"
is "$(hm_canary_beacon_state "$SHA40"$'\n')"         ok        "trailing newline is stripped"
is "$(hm_canary_beacon_state "$SHA40-dirty")"        dirty     "the dirtyRev form"
is "$(hm_canary_beacon_state "${SHA40:0:39}")"       malformed "39 hex chars is not a rev"
is "$(hm_canary_beacon_state "${SHA40}f")"           malformed "41 hex chars is not a rev"
is "$(hm_canary_beacon_state "${SHA40^^}")"          malformed "uppercase is not the form git writes"
is "$(hm_canary_beacon_state "deadbeef nope")"       malformed "trailing junk is not normalised away"
is "$(hm_canary_beacon_state " $SHA40")"             malformed "leading space is corruption, not whitespace"

echo "== hm_canary_provenance =="
P="$WORK/prov"; mkdir -p "$P/store" "$P/gen"
echo x > "$P/store/real"
ln -s "$P/store/real" "$P/beacon"
ln -s "$P/store/real" "$P/gen/beacon"
is "$(hm_canary_provenance "$P/beacon" "$P/gen/beacon")" ok "same resolved target"

# PRODUCTION SHAPE, and the reason this predicate resolves fully instead of
# comparing the first hop. Measured on cloudbox: the beacon points into
# ...-home-manager-files/.local/state/hm-deploy-rev while the generation path
# points at the file's own derivation -- DIFFERENT first hops, identical after
# `readlink -f`. A fixture where both sides share a first hop cannot tell the
# two implementations apart: mutating `readlink -f` to `readlink` survived it.
mkdir -p "$P/hm-files"
ln -s "$P/store/real" "$P/hm-files/rev"
ln -s "$P/hm-files/rev" "$P/beacon-chained"
is "$(hm_canary_provenance "$P/beacon-chained" "$P/gen/beacon")" ok \
  "different first hops that resolve to the same file"

# The hole this closes: a REGULAR FILE beacon is well-formed and invisible to
# every other predicate, and layer 1 would trust it.
echo "$SHA40" > "$P/plain"
is "$(hm_canary_provenance "$P/plain" "$P/gen/beacon")" not-symlink "a hand-written regular file"

ln -s "$P/store/other" "$P/beacon-other"
echo y > "$P/store/other"
is "$(hm_canary_provenance "$P/beacon-other" "$P/gen/beacon")" mismatch "resolves elsewhere"
is "$(hm_canary_provenance "$P/nope" "$P/gen/beacon")"         beacon-absent     "no beacon at all"
is "$(hm_canary_provenance "$P/beacon" "$P/nope")"             generation-absent "no generation to compare with"
# A dangling beacon symlink resolves to a path that does not exist; readlink -f
# still prints it, so this must not be silently 'ok'.
ln -s "$P/store/missing" "$P/dangling"
is "$(hm_canary_provenance "$P/dangling" "$P/gen/beacon")"     mismatch "a dangling beacon link"

echo "== hm_canary_judge / alertable =="
R="$WORK/repo"; mkdir -p "$R"
(
  cd "$R"
  git init -q .
  echo 1 > f && git add f && git commit -q -m one
  git branch -f old
  echo 2 > f && git add f && git commit -q -m two
  # pubref points at the NEWER commit: the commit that would be dropped is
  # PUBLISHED, which is what makes the regression provable rather than the
  # benign squash shape. Getting this backwards makes every "regression"
  # fixture silently produce regress-unpub -- which is exactly what the first
  # draft of this suite did, and the suite caught it.
  git branch -f pubref
) >/dev/null 2>&1
C1="$(git -C "$R" rev-parse old)"
C2="$(git -C "$R" rev-parse HEAD)"

is "$(hm_canary_judge "$R" "$C1" "$C2" pubref)" refuse:regress  "deploying an older rev over a published newer one"
is "$(hm_canary_judge "$R" "$C2" "$C1" pubref)" allow:forward   "ordinary forward deploy"
is "$(hm_canary_judge "$R" "$C2" "$C2" pubref)" allow:same      "redeploying the same rev"
is "$(hm_canary_judge "$R" "$C2" "" pubref)"    warn:no-beacon  "no previous beacon"
is "$(hm_canary_judge "$R" "" "$C2" pubref)"    warn:unknown-rev "incoming has no rev"
is "$(hm_canary_judge "$WORK/nosuch" "$C1" "$C2" pubref)" warn:no-repo "no clone to reason in"

is "$(hm_canary_alertable refuse:regress)" yes "a proven regression pages"
is "$(hm_canary_alertable allow:forward)"  no  "a forward deploy does not"
is "$(hm_canary_alertable warn:no-beacon)" no  "doubt does not page from this predicate"

# THE SQUASH-MERGE CASE. An agent deploys a PR branch; it is squash-merged, so
# the branch sha is never reachable from the published ref. Switching back to
# main drops only unpublished work. Layer 1 pays for this distinction and the
# canary must inherit it, or it pages on this repo's ONLY merge strategy.
B="$WORK/squash"; mkdir -p "$B"
(
  cd "$B"
  git init -q .
  echo 1 > f && git add f && git commit -q -m base
  # The default branch name is git-version and config dependent (master in the
  # nix sandbox, main on this host). Ask, never assume.
  DEFBR="$(git symbolic-ref --short HEAD)"
  git checkout -q -b feature
  echo 2 > f && git add f && git commit -q -m "on the branch"
  git checkout -q "$DEFBR"
  echo 2 > f && git add f && git commit -q -m "squashed equivalent"
  git branch -f pubref
) >/dev/null 2>&1
BR="$(git -C "$B" rev-parse feature)"
MAIN="$(git -C "$B" rev-parse pubref)"
is "$(hm_canary_judge "$B" "$MAIN" "$BR" pubref)" warn:regress-unpub "squash-merged branch is not a regression"
is "$(hm_canary_alertable "$(hm_canary_judge "$B" "$MAIN" "$BR" pubref)")" no "and therefore does not page"

echo "== the override leg (this is the strongest thing the canary does) =="
# Layer 1 downgrades a proven regression to warn:override when the agent sets
# HM_ALLOW_STALE_DEPLOY=1. The canary must NOT inherit that, and must not be
# reachable by the environment variable either.
is "$(hm_gate_verdict regress 1)" warn:override "layer 1 downgrades an override"
is "$(HM_ALLOW_STALE_DEPLOY=1 hm_canary_judge "$R" "$C1" "$C2" pubref)" refuse:regress \
  "the canary still refuses with HM_ALLOW_STALE_DEPLOY=1 exported"

echo "== hm_canary_generation_revs =="
G="$WORK/profiles"; mkdir -p "$G"
mk_gen() {
  local n="$1" rev="$2" when="$3"
  mkdir -p "$G/home-manager-$n-link/home-files/.local/state"
  printf '%s\n' "$rev" > "$G/home-manager-$n-link/home-files/.local/state/hm-deploy-rev"
  touch -d "$when" "$G/home-manager-$n-link"
}
mk_gen 604 cccccccccccccccccccccccccccccccccccccccc "2026-08-18 08:00:00"
mk_gen 602 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "2026-08-18 06:00:00"
mk_gen 603 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "2026-08-18 07:00:00"
mkdir -p "$G/home-manager-601-link"   # a generation with no beacon: predates the gate
GOT="$(hm_canary_generation_revs "$G" | cut -f2 | tr '\n' ' ')"
is "$GOT" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc " \
  "ordered oldest-first by link mtime, beacon-less generations skipped"
is "$(hm_canary_generation_revs "$WORK/nosuch" | wc -l | tr -d ' ')" 0 "missing profiles dir yields nothing"

# Ordering must come from the link MTIME, not from the generation NUMBER in the
# name: `sort -n` on the path would order 601 < 602 < ... which is usually the
# same answer and silently wrong after a rollback.
mk_gen 700 dddddddddddddddddddddddddddddddddddddddd "2026-08-18 05:00:00"
is "$(hm_canary_generation_revs "$G" | head -1 | cut -f2)" dddddddddddddddddddddddddddddddddddddddd \
  "a higher-numbered generation activated EARLIER sorts first"

echo "== hm_canary_selftest =="
is "$(hm_canary_selftest "$WORK")" ok "the per-pass tripwire passes when the gate is sourced"

# And it must FAIL when the gate library is not sourced -- the exact condition
# that once made the real gate allow every deploy in silence.
SUB="$(
  bash -c '
    set -uo pipefail
    source '"$HERE"'/hm-deploy-canary.sh
    hm_canary_selftest '"$WORK"'
  ' 2>/dev/null
)"
is "$SUB" FAIL:gate-not-sourced "the tripwire fails when hm_gate_* is missing"

echo ""
if [ "$FAILED" = 0 ]; then
  echo "hm-deploy-canary: ALL PASS"
else
  echo "hm-deploy-canary: FAILURES"
  exit 1
fi
