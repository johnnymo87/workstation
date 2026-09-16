#!/usr/bin/env bash
# unwired-test(workstation-o5s1): this suite runs the nix-built canary, which
# derives its port list and unit state from systemd, needs root for
# /var/lib/opencode-serve-canary, and whose S8 case is by definition a real
# collection run against live serves over loopback. A build sandbox provides
# none of that. Tracked as workstation-o5s1.8, which argues the analysis half
# (S1-S6e, ~30 assertions) could be made hermetic by extracting it from the
# liveness leg. The marker names the EPIC because
# users/dev/test-unwired-tests.sh:331 uses MARKER_RE='unwired-test\([a-z0-9-]+\)',
# which admits no dot and therefore no child bead id.
#
# Run it by hand on cloudbox after touching the stall probe:
#
#   ./hosts/cloudbox/test-serve-canary-stall-probe.sh
#
# Tests the STALL PROBE added by bead workstation-o5s1.1 (the serve canary's
# answer to the 2026-09-15 episode, where every serve stalled 1-2.6s on disk I/O
# every 10-30s and every canary probe passed).
#
# WHY A FIXTURE SEAM AT ALL. The branch that matters is the one that fires when a
# serve IS stalling, and that cannot be produced on a healthy host on demand. A
# WARNING that has never been observed to fire is a WARNING nobody should trust
# — and the specific way it would fail is silent, since a probe that never warns
# looks exactly like a pool that is never slow. OPENCODE_CANARY_STALL_FIXTURE
# points the shipped analysis at pre-collected samples, so what is under test is
# the production code path and not a restatement of it.
#
# NOT TESTED HERE, and worth saying out loud rather than implying coverage:
# the COLLECTION half (curl bursts, wchan sampling, the parallel fan-out) runs
# only against real serves. It is exercised by running the canary for real,
# which this script does last as a smoke test.
set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=[$3] got=[$2])"; fi; }

CANARY="${CANARY_OVERRIDE:-}"
if [ -z "$CANARY" ]; then
  echo "building canary from $REPO ..."
  DRV=$(nix eval --raw --impure --expr "let f = builtins.getFlake \"$REPO\"; s = f.nixosConfigurations.cloudbox.config.systemd.services.opencode-serve-canary.serviceConfig.ExecStart; in builtins.head (builtins.attrNames (builtins.getContext s))") || exit 1
  CANARY=$(nix-store -r "$DRV" 2>/dev/null) || exit 1
fi
echo "canary: $CANARY"

# The canary's restart logic needs root (systemctl restart, root-owned STATE).
# We are only ever reading the stall-probe block's output, but the script is run
# whole, so it must run as the unit does.
if [ "$(id -u)" != 0 ]; then
  echo "must run as root (the canary writes /var/lib/opencode-serve-canary and calls systemctl)"; exit 1
fi

LAB="$(mktemp -d "${TMPDIR:-/tmp}/canarystall.XXXXXX")"
trap 'rm -rf "$LAB"' EXIT

# The port the fixtures describe. Any pool port works; the analysis loop walks
# the configured list and skips ports with no .lat file.
PORT=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active |
  awk '{print $1}' | head -1 | sed 's/.*@\([0-9]*\)\.service/\1/')
[ -n "$PORT" ] || { echo "no active opencode-serve@* unit; start the pool first"; exit 1; }
echo "fixture port: $PORT"

# mkfix <dir> <lat-generator-awk> <wchan-lines>
run_fixture() {
  local dir="$1"
  OUT=$(OPENCODE_CANARY_STALL_FIXTURE="$dir" "$CANARY" 2>&1)
  RC=$?
}

echo "== S1: a healthy serve reports a plain line, no WARNING =="
D="$LAB/s1"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.001" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 20; i++) print "do_epoll_wait" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "exit 0"            "$RC" 0
check "reports the probe" "$(printf '%s' "$OUT" | grep -c "canary: opencode-serve@$PORT.service stall probe:")" 1
check "no STALLING warning" "$(printf '%s' "$OUT" | grep -c 'STALLING')" 0
check "counts 200 samples" "$(printf '%s' "$OUT" | grep -c 'n=200')" 1
check "all idle"          "$(printf '%s' "$OUT" | grep -c 'idle=20 run=0 io=0/20')" 1

echo "== S2: a RUNNING serve (wchan 0) is healthy, not 'other' =="
# The kernel reports wchan as literal 0 for a task on CPU. Counting that as a
# blocking state makes a busy healthy serve look like the thing this probe hunts.
D="$LAB/s2"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.002" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 12; i++) print "do_epoll_wait"; for (i = 0; i < 8; i++) print "0" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "no STALLING warning" "$(printf '%s' "$OUT" | grep -c 'STALLING')" 0
check "running counted as running" "$(printf '%s' "$OUT" | grep -c 'idle=12 run=8 io=0/20')" 1
check "not reported as other"      "$(printf '%s' "$OUT" | grep -c 'other=')" 0

echo "== S3: a latency stall >1s produces a WARNING =="
# THE acceptance criterion of workstation-o5s1.1, and the branch a healthy host
# can never reach. Three slow samples, not ten: requests are paced 50ms apart
# over one keep-alive connection, so a single 1.5s stall is absorbed by the few
# requests that overlap it, not by a whole burst queueing behind it.
D="$LAB/s3"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 197; i++) print "200 0.001"; for (i = 0; i < 3; i++) print "200 1.480" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 20; i++) print "do_epoll_wait" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "exit 0"                "$RC" 0
check "WARNs"                 "$(printf '%s' "$OUT" | grep -c "WARNING: opencode-serve@$PORT.service STALLING")" 1
check "says not restarting"   "$(printf '%s' "$OUT" | grep -c 'not restarting — observability only')" 1
check "counts the >1s samples" "$(printf '%s' "$OUT" | grep -c '>1s=3')" 1
check "reports max"           "$(printf '%s' "$OUT" | grep -c 'max=1.480s')" 1

echo "== S4: an I/O-blocked wchan WARNs even when latency looks clean =="
# The two instruments fail in opposite directions: a 10s latency window often
# misses a stall that occupies ~7% of the timeline, while wchan sees the loop
# sitting in the block layer. If this only warned on latency, the sensitive
# instrument would be decoration.
D="$LAB/s4"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.001" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 6; i++) print "do_epoll_wait"; for (i = 0; i < 9; i++) print "folio_wait_bit_common"; for (i = 0; i < 5; i++) print "rq_qos_wait" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "WARNs on wchan alone"  "$(printf '%s' "$OUT" | grep -c "WARNING: opencode-serve@$PORT.service STALLING")" 1
check "latency was clean"     "$(printf '%s' "$OUT" | grep -c '>1s=0')" 1
check "io counted"            "$(printf '%s' "$OUT" | grep -c 'io=14/20')" 1
check "ioblock reported"      "$(printf '%s' "$OUT" | grep -c 'ioblock=14')" 1

echo "== S5: a non-I/O blocking state is reported but does NOT warn =="
# futex_wait_queue is a lock wait, not the disk. Warning on it would make the
# signal noisy, and a noisy warning is one the operator learns to skip.
D="$LAB/s5"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.001" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 17; i++) print "do_epoll_wait"; for (i = 0; i < 3; i++) print "futex_wait_queue" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "no warning"        "$(printf '%s' "$OUT" | grep -c 'STALLING')" 0
check "other is reported" "$(printf '%s' "$OUT" | grep -c 'other=3 top=futex_wait_queue(3)')" 1

echo "== S6: an empty sample set says so rather than reporting zeros =="
# A probe that collected nothing and a serve that was perfectly fast both have
# no samples over 1s. They must not print the same thing.
D="$LAB/s6"; mkdir -p "$D"
: > "$D/$PORT.lat"
: > "$D/$PORT.wchan"
run_fixture "$D"
check "exit 0"        "$RC" 0
check "says n=0"      "$(printf '%s' "$OUT" | grep -c 'n=0 fail=0 (no answered samples)')" 1
check "no warning"    "$(printf '%s' "$OUT" | grep -c 'STALLING')" 0

echo "== S6b: unanswered requests are counted, never timed =="
# THE dangerous direction. A refused or reset connection completes in ~0.0001s,
# so folding it into the percentiles turns a serve that died mid-probe into a
# flawless bill of health -- faster than healthy, by a lot. These must be
# excluded from the timings and reported on their own.
D="$LAB/s6b"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 100; i++) print "200 0.002"; for (i = 0; i < 100; i++) print "000 0.000098" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 20; i++) print "do_epoll_wait" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "exit 0"                  "$RC" 0
check "failures excluded from n" "$(printf '%s' "$OUT" | grep -c 'n=100 fail=100')" 1
check "p50 is the real latency"  "$(printf '%s' "$OUT" | grep -c 'p50=0.002s')" 1
check "warns about the failures" "$(printf '%s' "$OUT" | grep -c 'unanswered request(s) during the stall probe')" 1

echo "== S6c: a single io sample does NOT warn; recurring io does =="
# The bead says io "recurring with NO return to do_epoll_wait", not "seen once".
# On a host whose DB working set exceeds page cache, one folio wait in 20 during
# an ordinary read is unremarkable; warning on it makes the channel noise, and
# this file's own bcmi lesson is what that costs.
D="$LAB/s6c"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.001" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 19; i++) print "do_epoll_wait"; print "folio_wait_bit_common" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "one io sample does not warn" "$(printf '%s' "$OUT" | grep -c 'STALLING')" 0
check "but it is still reported"    "$(printf '%s' "$OUT" | grep -c 'io=1/20')" 1

# ...unless a slow request corroborates it.
D="$LAB/s6d"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 199; i++) print "200 0.001"; print "200 0.310" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 19; i++) print "do_epoll_wait"; print "rq_qos_wait" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "one io sample + a slow request DOES warn" "$(printf '%s' "$OUT" | grep -c 'STALLING')" 1

echo "== S6e: a WAL-commit wait is io, not 'other' =="
# The io set was originally the two symbols this one incident produced. Matching
# by equality drops every other block-layer wait into 'other', where it warns
# about nothing -- a detector written from a single sample.
D="$LAB/s6e"; mkdir -p "$D"
awk 'BEGIN { for (i = 0; i < 200; i++) print "200 0.001" }' > "$D/$PORT.lat"
awk 'BEGIN { for (i = 0; i < 16; i++) print "do_epoll_wait"; for (i = 0; i < 4; i++) print "jbd2_log_wait_commit" }' > "$D/$PORT.wchan"
run_fixture "$D"
check "classified as io"   "$(printf '%s' "$OUT" | grep -c 'io=4/20')" 1
check "warns"              "$(printf '%s' "$OUT" | grep -c 'STALLING')" 1
check "not dumped in other" "$(printf '%s' "$OUT" | grep -c 'other=')" 0

echo "== S7: the probe never restarts anything =="
# The whole point, and the one property worth pinning against the live system
# rather than against output text. The block sits after every restart decision,
# so this is structural -- but "structural" is a claim about code layout, and a
# future edit that moves the block is exactly what would break it silently.
BEFORE=$(systemctl show "opencode-serve@$PORT.service" -p ActiveEnterTimestampMonotonic --value)
run_fixture "$LAB/s4"
AFTER=$(systemctl show "opencode-serve@$PORT.service" -p ActiveEnterTimestampMonotonic --value)
check "serve was not restarted by an alarming fixture" "$AFTER" "$BEFORE"

echo "== S8: SMOKE -- a real collection run against the live pool =="
# The fixture seam covers analysis; only this covers collection. It is a smoke
# test on purpose: it asserts the probe produced a full sample set per serve and
# stayed inside the canary's one-minute timer budget, not that the host is fast.
#
# EVERY CASE IN THIS FILE RUNS THE WHOLE CANARY, restart logic included -- the
# fixture seam skips only the stall probe's COLLECTION, not the liveness leg. So
# the suite is ~11 extra canary passes, not one. Each is the same kind of event
# the timer produces every 60 seconds, but they are not inert: a serve already at
# 6 of 7 consecutive health failures will be restarted by this suite, several
# passes earlier than it otherwise would have been. Do not run it while nursing
# a sick pool.
T0=$(date +%s)
OUT=$("$CANARY" 2>&1); RC=$?
T1=$(date +%s)
ELAPSED=$((T1 - T0))
echo "  (real canary run: ${ELAPSED}s)"
check "exit 0" "$RC" 0
# Per-serve, not "at least one": a fan-out bug that probed only the first port
# would satisfy any aggregate check while silently halving the instrument.
NPORTS=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active | awk 'NF' | wc -l)
NPROBED=$(printf '%s' "$OUT" | grep -c 'stall probe:\|STALLING\|unanswered request')
check "probed every active serve" "$NPROBED" "$NPORTS"
# Likewise n=200 per serve, not somewhere in the output.
NFULL=$(printf '%s' "$OUT" | grep -c 'n=200 fail=0')
check "every serve collected a full clean sample set" "$NFULL" "$NPORTS"
if [ "$ELAPSED" -le 30 ]; then ok "ran in ${ELAPSED}s (<=30s, inside the 60s timer budget)"
else bad "took ${ELAPSED}s -- too close to the canary's 60s timer interval"; fi
# 200 samples is 20 rounds x a 10-request burst. A partial count means curl is
# writing somewhere unexpected or a burst is failing silently.


echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
