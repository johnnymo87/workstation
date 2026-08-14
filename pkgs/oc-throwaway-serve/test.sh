#!/usr/bin/env bash
# Tests for oc-throwaway-serve.
#
# Two halves, and the split is deliberate:
#
#   1. BEHAVIOURAL -- the fd measurement is the safety property (the 2026-08-14
#      incident happened because everyone REASONED that the isolation held and
#      nobody measured it), so it is exercised against a real process holding a
#      real open file descriptor, not asserted about by grep.
#   2. SOURCE GUARDS -- the environment construction can only be verified for
#      real by booting opencode, which is out of scope for a nix check; instead
#      each var that MUST be set or scrubbed is pinned, because dropping one is
#      silent (that is exactly how OPENCODE_DB was missed).
#
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/default.nix"

pass=0
ok() { printf 'PASS  %s\n' "$1"; pass=$(( pass + 1 )); }
fail() { printf 'FAIL  %s\n' "$1"; exit 1; }

assert_eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; ok "$3"; }

# ---- mirrors of the production functions (kept honest by the guards below) ---

fd_targets() {
  local pid="$1"
  for fd in /proc/"$pid"/fd/*; do
    readlink "$fd" 2>/dev/null || true
  done
}

violations() {
  local protected="$1"
  grep -F -e "$protected" || true
}

# ---- 1. behavioural: does the measurement actually see an open handle? -------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
protected="$tmp/opencode.db"
scratch="$tmp/scratch.db"
: > "$protected"
: > "$protected-wal"
: > "$scratch"

# A process holding the protected DB open, exactly as a mis-isolated serve would.
bash -c 'exec 9<"$1"; sleep 30' _ "$protected" &
bad=$!
sleep 0.3
found="$(fd_targets "$bad" | violations "$protected")"
[ -n "$found" ] || fail "measurement detects a process holding the protected DB open"
ok "measurement detects a process holding the protected DB open"
kill "$bad" 2>/dev/null || true

# The WAL sidecar alone is still production: a serve can hold -wal open while
# the main file handle is momentarily absent, and that process is still writing
# real data. A check that only matched the bare .db path would pass it.
bash -c 'exec 9<"$1"; sleep 30' _ "$protected-wal" &
badwal=$!
sleep 0.3
found="$(fd_targets "$badwal" | violations "$protected")"
[ -n "$found" ] || fail "measurement detects a -wal-only handle on the protected DB"
ok "measurement detects a -wal-only handle on the protected DB"
kill "$badwal" 2>/dev/null || true

# ...and the negative control: a correctly isolated process must produce NO
# violations. Without this the test above is satisfied by a check that always
# fires, which would make the wrapper unusable-but-green.
bash -c 'exec 9<"$1"; sleep 30' _ "$scratch" &
good=$!
sleep 0.3
found="$(fd_targets "$good" | violations "$protected")"
assert_eq "" "$found" "correctly isolated process produces no violations"
# ...while still measurably holding the scratch DB (the positive half the
# wrapper asserts, so a vacuous green is impossible).
fd_targets "$good" | grep -qF "$scratch" || fail "isolated process measurably holds the scratch DB"
ok "isolated process measurably holds the scratch DB"
kill "$good" 2>/dev/null || true

# ---- 2. source guards on the production script -------------------------------

guard() {
  local pattern="$1" msg="$2"
  grep -q -- "$pattern" "$SRC" || fail "$msg"
  ok "$msg"
}

# The variable this whole wrapper exists for. If it stops being set explicitly,
# the serve silently inherits the session-wide production OPENCODE_DB again and
# we are back to 2026-08-14 with a wrapper that looks like it protects us.
guard 'OPENCODE_DB="\$db"' 'sets OPENCODE_DB explicitly to the scratch database'
guard 'XDG_DATA_HOME="\$scratch/data"' 'redirects XDG_DATA_HOME to the scratch dir'
guard 'OPENCODE_DISABLE_CHANNEL_DB=1' 'pins the channel-suffixed DB default off'

# Routing-slot hazard (2026-07-25): a throwaway that inherits these can hijack a
# live pool slot. serve.ts fences it, but the wrapper must not rely on the fence
# being armed.
for v in OPENCODE_SERVE_ID OPENCODE_ROUTING_DB OPENCODE_SERVE_EXPECTED_PORT OPENCODE_SERVE_EXPECTED_PID; do
  guard "\-u $v" "scrubs $v from the throwaway's environment"
done

# The measurement must happen BEFORE the URL is printed -- a wrapper that
# announces a ready serve and only then checks has already handed the operator a
# handle on production.
ready_line="$(grep -n 'VERIFIED isolated' "$SRC" | head -1 | cut -d: -f1)"
last_assert="$(grep -n 'assert_isolated "\$pid"' "$SRC" | tail -1 | cut -d: -f1)"
[ -n "$ready_line" ] && [ -n "$last_assert" ] || fail "found both the readiness banner and the isolation assert"
[ "$last_assert" -lt "$ready_line" ] || fail "isolation is asserted before the serve URL is printed"
ok "isolation is asserted before the serve URL is printed"

# A violation must be fatal AND kill the serve; logging it would leave a process
# with production handles running unattended.
grep -A6 'has the PROTECTED database open' "$SRC" | grep -q 'kill -9' \
  || fail "a detected violation kills the serve rather than only warning"
ok "a detected violation kills the serve rather than only warning"

# VACUUM INTO, not cp: `cp` of a live WAL database can capture a torn page set.
guard 'VACUUM INTO' 'snapshots with VACUUM INTO (consistent, read-only on the source)'
grep -q 'mode=ro' "$SRC" || fail "opens the protected DB read-only when snapshotting"
ok "opens the protected DB read-only when snapshotting"

printf '\nall oc-throwaway-serve tests passed (%d assertions)\n' "$pass"
