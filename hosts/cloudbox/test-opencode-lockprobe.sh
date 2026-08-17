#!/usr/bin/env bash
# unwired-test(workstation-k7t4): NOT live state -- fully fixture-injected (LOCKPROBE_LOCKS/WCHAN_FMT/SHM_INO, :38-47) and hermetic in 29s, but several assertions bound wall-clock timing (:89 and :115 assert 800<d<1300, :271 asserts max_gap<200ms) and would flake on a loaded CI runner. See the bead note: lower bounds are load-safe, upper bounds are assertions about the environment
# Tests for hosts/cloudbox/opencode-lockprobe.py (W2d, bead workstation-yvxh.12).
#
# The sampler's whole job is to be believed about a distribution nobody can
# check by eye, so the failure that matters is the SILENT one: a probe that
# reads the wrong PID, or a dead one, logs "no contention" forever and looks
# perfectly healthy. These tests drive the state machine against synthetic
# procfs fixtures and assert the instrument reports what actually happened --
# including that it says so LOUDLY when it can see nothing.
#
# Run: bash hosts/cloudbox/test-opencode-lockprobe.sh
set -o nounset -o pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$here/opencode-lockprobe.py"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
no()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
chk_ge() { if [ "$(printf '%s\n' "$2" "$3" | sort -g | head -1)" = "$3" ]; then ok "$1"; else no "$1 ($2 < $3)"; fi; }
have() { if [ -n "$2" ]; then ok "$1"; else no "$1 (empty)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INO=424242
SERVE_PID=1234
HOLDER_PID=9999

mk_wchan() { mkdir -p "$TMP/proc/$1"; printf '%s\n' "$2" > "$TMP/proc/$1/wchan"; }
locks_write() { printf '%s\n' "$@" > "$TMP/locks"; }
# A lock line in /proc/locks shape: id: POSIX ADVISORY WRITE <pid> <maj:min:ino> <s> <e>
lockline() { printf '%d: POSIX  ADVISORY  WRITE %s 103:02:%s %s %s' "$1" "$2" "$INO" "$3" "$3"; }
noise() { printf '7: POSIX  ADVISORY  READ 5555 103:02:999999 128 128'; }

run_probe() { # run_probe <seconds> <outfile> [extra env assignments...]
  local secs="$1" out="$2"; shift 2
  env LOCKPROBE_LOCKS="$TMP/locks" \
      LOCKPROBE_WCHAN_FMT="$TMP/proc/{pid}/wchan" \
      LOCKPROBE_SHM_INO="$INO" \
      LOCKPROBE_OUT="$out" \
      LOCKPROBE_HZ=100 \
      LOCKPROBE_DURATION="$secs" \
      LOCKPROBE_ROLLUP_SEC=999 \
      LOCKPROBE_REDISCOVER_SEC=999 \
      LOCKPROBE_DISCOVER_STATIC="$SERVE_PID:4096" \
      "$@" python3 "$PROBE" > "$out.log" 2>&1
}
jq_type() { python3 -c "
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get('type')==sys.argv[2]: print(json.dumps(r))
" "$1" "$2"; }
field() { python3 -c "
import json,sys
print(json.loads(sys.argv[1]).get(sys.argv[2],''))
" "$1" "$2"; }

echo "=== 1. static checks ==="
[ -f "$PROBE" ] && ok "sampler exists" || no "sampler exists"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PROBE" \
  && ok "sampler parses" || no "sampler parses"
# The guard (users/dev/test-frontdoor-opacity.sh) flags 127.0.0.1:409[6-9].
# Discovery is via a systemd unit glob precisely so this file never needs an
# exemption. If someone "helpfully" hardcodes the pool ports, catch it here.
if grep -qE '(127\.0\.0\.1|localhost):409[6-9]' "$PROBE"; then
  no "sampler names no serve port (would need a frontdoor exemption)"
else ok "sampler names no serve port (would need a frontdoor exemption)"; fi
grep -q "opencode-serve@\*.service" "$PROBE" \
  && ok "discovery uses a unit glob" || no "discovery uses a unit glob"
# Read-only discipline: the sampler must never open the DB itself.
if grep -qE 'import sqlite3|sqlite3\.connect|BEGIN IMMEDIATE|\.execute\(' "$PROBE"; then
  no "sampler never touches the database"
else ok "sampler never touches the database"; fi

echo "=== 2. hold (H) detection and duration ==="
mk_wchan "$SERVE_PID" do_epoll_wait
locks_write "$(lockline 1 "$HOLDER_PID" 120)" "$(noise)"
( sleep 1; locks_write "$(noise)" ) &      # release the lock 1s in
run_probe 2.5 "$TMP/o1.jsonl" LOCKPROBE_HOLD_DETAIL_MS=50
wait
H="$(jq_type "$TMP/o1.jsonl" hold | head -1)"
have "hold record emitted" "$H"
chk "hold pid" "$(field "$H" pid)" "$HOLDER_PID"
chk "hold byte" "$(field "$H" byte)" "120"
chk "hold byte_name" "$(field "$H" byte_name)" "write"
D="$(field "$H" dur_ms)"
python3 -c "import sys; d=float(sys.argv[1]); sys.exit(0 if 800<d<1300 else 1)" "$D" \
  && ok "hold duration ~1000ms (got ${D}ms)" || no "hold duration ~1000ms (got ${D}ms)"
have "hold carries res_ms (error bound)" "$(field "$H" res_ms)"

echo "=== 3. short holds are counted but NOT detailed (volume control) ==="
locks_write "$(noise)"
( sleep 0.4; locks_write "$(lockline 1 "$HOLDER_PID" 120)" "$(noise)"; \
  sleep 0.1; locks_write "$(noise)" ) &
run_probe 2 "$TMP/o2.jsonl" LOCKPROBE_HOLD_DETAIL_MS=500
wait
chk "sub-threshold hold emits no detail record" "$(jq_type "$TMP/o2.jsonl" hold | wc -l | tr -d ' ')" "0"
R="$(jq_type "$TMP/o2.jsonl" rollup | tail -1)"
chk_ge "but IS counted in the rollup histogram" "$(python3 -c "
import json,sys; print(sum(json.loads(sys.argv[1])['hold_hist'].values()))" "$R")" 1

echo "=== 4. freeze (F) detection ==="
locks_write "$(noise)"
mk_wchan "$SERVE_PID" hrtimer_nanosleep
( sleep 1; mk_wchan "$SERVE_PID" do_epoll_wait ) &
run_probe 2.5 "$TMP/o3.jsonl" LOCKPROBE_FREEZE_DETAIL_MS=50
wait
F="$(jq_type "$TMP/o3.jsonl" freeze | head -1)"
have "freeze record emitted" "$F"
chk "freeze pid" "$(field "$F" pid)" "$SERVE_PID"
chk "freeze port" "$(field "$F" port)" "4096"
FD="$(field "$F" dur_ms)"
python3 -c "import sys; d=float(sys.argv[1]); sys.exit(0 if 800<d<1300 else 1)" "$FD" \
  && ok "freeze duration ~1000ms (got ${FD}ms)" || no "freeze duration ~1000ms (got ${FD}ms)"
chk "unvalidated freeze has no overlapped holder" "$(field "$F" overlapped_hold_pid)" "None"

echo "=== 5. coincidence flag validates the wchan reading ==="
# Freeze on the serve WHILE a different pid holds byte 120 => near-conclusive
# that this sleep is SQLite's busy-wait and not some other sync sleep.
locks_write "$(lockline 1 "$HOLDER_PID" 120)" "$(noise)"
mk_wchan "$SERVE_PID" hrtimer_nanosleep
( sleep 1; locks_write "$(noise)"; mk_wchan "$SERVE_PID" do_epoll_wait ) &
run_probe 2.5 "$TMP/o4.jsonl" LOCKPROBE_FREEZE_DETAIL_MS=50
wait
F2="$(jq_type "$TMP/o4.jsonl" freeze | head -1)"
have "freeze record emitted (contended)" "$F2"
chk "overlapping holder recorded" "$(field "$F2" overlapped_hold_pid)" "$HOLDER_PID"
# A serve must not be credited as blocking on ITSELF.
locks_write "$(lockline 1 "$SERVE_PID" 120)" "$(noise)"
mk_wchan "$SERVE_PID" hrtimer_nanosleep
( sleep 0.8; locks_write "$(noise)"; mk_wchan "$SERVE_PID" do_epoll_wait ) &
run_probe 2 "$TMP/o5.jsonl" LOCKPROBE_FREEZE_DETAIL_MS=50
wait
chk "self-held lock is not counted as an overlap" \
  "$(field "$(jq_type "$TMP/o5.jsonl" freeze | head -1)" overlapped_hold_pid)" "None"

echo "=== 6. rollup is the heartbeat (quiet vs broken) ==="
locks_write "$(noise)"; mk_wchan "$SERVE_PID" do_epoll_wait
run_probe 1.2 "$TMP/o6.jsonl"
RF="$(jq_type "$TMP/o6.jsonl" rollup | tail -1)"
have "final rollup written on exit" "$RF"
chk "final rollup marked final" "$(field "$RF" final)" "True"
chk "rollup reports serves_found" "$(field "$RF" serves_found)" "1"
chk_ge "rollup reports sample count" "$(field "$RF" samples)" 30
chk_ge "rollup reports achieved hz" "$(field "$RF" hz)" 30
chk "quiet period reports zero freezes" "$(field "$RF" freezes)" "0"
# The distinguishing case: no serves at all must be VISIBLE, not silent.
run_probe 1 "$TMP/o7.jsonl" LOCKPROBE_DISCOVER_STATIC=none
chk "zero-serve run reports serves_found=0" \
  "$(field "$(jq_type "$TMP/o7.jsonl" rollup | tail -1)" serves_found)" "0"
grep -q "zero serves discovered" "$TMP/o7.jsonl.log" \
  && ok "zero-serve run warns loudly in the journal" || no "zero-serve run warns loudly in the journal"
S="$(jq_type "$TMP/o6.jsonl" start | head -1)"
have "start record written" "$S"
chk "start record carries resolution" "$(python3 -c "
import json,sys; print(round(json.loads(sys.argv[1])['res_ms']))" "$S")" "10"

echo "=== 7. output cap degrades to counts-only, never silently ==="
locks_write "$(lockline 1 "$HOLDER_PID" 120)" "$(noise)"
( sleep 0.3; locks_write "$(noise)"; sleep 0.2; \
  locks_write "$(lockline 1 "$HOLDER_PID" 121)" "$(noise)"; \
  sleep 0.3; locks_write "$(noise)" ) &
run_probe 1.6 "$TMP/o8.jsonl" LOCKPROBE_HOLD_DETAIL_MS=10 LOCKPROBE_MAX_BYTES=1
wait
chk "cap_reached record emitted" "$(jq_type "$TMP/o8.jsonl" cap_reached | wc -l | tr -d ' ')" "1"
chk_ge "rollups still written after cap" "$(jq_type "$TMP/o8.jsonl" rollup | wc -l | tr -d ' ')" 1
chk "rollup records the capped state" \
  "$(field "$(jq_type "$TMP/o8.jsonl" rollup | tail -1)" capped)" "True"
chk_ge "counts survive capping" \
  "$(python3 -c "
import json,sys; print(sum(json.loads(sys.argv[1])['hold_hist'].values()))" \
    "$(jq_type "$TMP/o8.jsonl" rollup | tail -1)")" 1

echo "=== 8. non-write and foreign-inode locks are ignored ==="
locks_write "7: POSIX  ADVISORY  READ $HOLDER_PID 103:02:$INO 120 120" \
            "8: POSIX  ADVISORY  WRITE $HOLDER_PID 103:02:777777 120 120" \
            "9: FLOCK  ADVISORY  WRITE $HOLDER_PID 103:02:$INO 120 120" \
            "$(noise)"
mk_wchan "$SERVE_PID" do_epoll_wait
run_probe 1 "$TMP/o9.jsonl" LOCKPROBE_HOLD_DETAIL_MS=1
chk "READ lock / foreign inode / FLOCK all ignored" \
  "$(jq_type "$TMP/o9.jsonl" hold | wc -l | tr -d ' ')" "0"
# Byte 121 (checkpoint) IS in range and must be captured -- long checkpoints are
# a prime suspect for the long-hold tail.
locks_write "$(lockline 1 "$HOLDER_PID" 121)" "$(noise)"
( sleep 0.5; locks_write "$(noise)" ) &
run_probe 1.5 "$TMP/o10.jsonl" LOCKPROBE_HOLD_DETAIL_MS=50
wait
chk "checkpoint byte 121 captured as 'ckpt'" \
  "$(field "$(jq_type "$TMP/o10.jsonl" hold | head -1)" byte_name)" "ckpt"

echo "=== 9. -shm inode change must not silently blind the hold side ==="
# The BLOCKER found in adversarial review. The -shm file is unlinked and
# recreated whenever the last connection closes (pool stop, upgrade, reboot,
# WAL recovery) -- confirmed to have happened on cloudbox mid-uptime. A probe
# that statted the inode once would then match nothing in /proc/locks while
# rollups kept flowing and serves_found stayed healthy, and the spec's
# continuity rule would certify that blindness as a real null result.
# Deliberately does NOT set LOCKPROBE_SHM_INO: the static override would bake
# in the very assumption under test.
SHMDIR="$TMP/shm"; mkdir -p "$SHMDIR"
: > "$SHMDIR/x.db-shm"
INO_A="$(stat -c %i "$SHMDIR/x.db-shm")"
printf '1: POSIX  ADVISORY  WRITE %s 103:02:%s 120 120\n' "$HOLDER_PID" "$INO_A" > "$TMP/locks"
# Create-then-rename, NOT rm-then-touch: a freed inode can be immediately
# REUSED, which silently produces INO_B == INO_A and a vacuously passing test.
# That flake was observed once before this comment existed.
: > "$SHMDIR/staged"
INO_B="$(stat -c %i "$SHMDIR/staged")"
chk_ne() { if [ "$2" != "$3" ]; then ok "$1"; else no "$1 (both '$2')"; fi; }
chk_ne "test precondition: the two inodes really differ" "$INO_A" "$INO_B"
(
  sleep 1.2
  mv -f "$SHMDIR/staged" "$SHMDIR/x.db-shm"   # atomically swap in the new inode
  printf '1: POSIX  ADVISORY  WRITE %s 103:02:%s 120 120\n' "$HOLDER_PID" "$INO_B" > "$TMP/locks"
  sleep 1.0
  printf '7: POSIX  ADVISORY  READ 5555 103:02:999999 128 128\n' > "$TMP/locks"
) &
env LOCKPROBE_LOCKS="$TMP/locks" LOCKPROBE_WCHAN_FMT="$TMP/proc/{pid}/wchan" \
    LOCKPROBE_DB="$SHMDIR/x.db" LOCKPROBE_OUT="$TMP/o11.jsonl" LOCKPROBE_HZ=100 \
    LOCKPROBE_DURATION=3.2 LOCKPROBE_ROLLUP_SEC=999 LOCKPROBE_REDISCOVER_SEC=0.3 \
    LOCKPROBE_HOLD_DETAIL_MS=50 LOCKPROBE_DISCOVER_STATIC="$SERVE_PID:4096" \
    python3 "$PROBE" > "$TMP/o11.jsonl.log" 2>&1
wait
chk "inode change is detected and recorded" \
  "$(jq_type "$TMP/o11.jsonl" shm_changed | wc -l | tr -d ' ')" "1"
chk "old inode reported" "$(field "$(jq_type "$TMP/o11.jsonl" shm_changed)" old)" "$INO_A"
# The point of the fix: holds on the NEW inode are still measured afterwards.
chk_ge "hold on the NEW inode is still captured" \
  "$(jq_type "$TMP/o11.jsonl" hold | wc -l | tr -d ' ')" 1
chk "rollup carries the live inode for auditability" \
  "$(field "$(jq_type "$TMP/o11.jsonl" rollup | tail -1)" shm_ino)" \
  "$(stat -c %i "$SHMDIR/x.db-shm")"

echo "=== 10. rediscovery survives the nightly reset (pids change) ==="
locks_write "$(noise)"; mk_wchan "$SERVE_PID" do_epoll_wait
DF="$TMP/discover"; echo "$SERVE_PID:4096" > "$DF"
mk_wchan 4321 do_epoll_wait
( sleep 0.8; echo "4321:4097" > "$DF" ) &     # pool restarts, every PID changes
run_probe 2 "$TMP/o12.jsonl" LOCKPROBE_REDISCOVER_SEC=0.3 LOCKPROBE_DISCOVER_FILE="$DF"
wait
PC="$(jq_type "$TMP/o12.jsonl" pids_changed | head -1)"
have "pid change detected" "$PC"
chk "rollup follows the new pid set" \
  "$(field "$(jq_type "$TMP/o12.jsonl" rollup | tail -1)" pids)" "['4321']"

echo "=== 11. discovery failure eventually admits blindness ==="
# Stale serve set would make serves_found=0 unreachable after startup, and
# reading wchan of dead PIDs yields plausible FAKE freezes after PID reuse
# (hrtimer_nanosleep is the wchan of ANY sleeping process).
echo "$SERVE_PID:4096" > "$DF"
( sleep 0.6; echo "none" > "$DF" ) &
run_probe 2.5 "$TMP/o13.jsonl" LOCKPROBE_REDISCOVER_SEC=0.3 LOCKPROBE_DISCOVER_FILE="$DF"
wait
chk "serves_lost recorded after repeated misses" \
  "$(jq_type "$TMP/o13.jsonl" serves_lost | wc -l | tr -d ' ')" "1"
chk_ge "only after tolerating a transient blip" \
  "$(field "$(jq_type "$TMP/o13.jsonl" serves_lost)" after_misses)" 3
chk "and serves_found=0 then actually fires" \
  "$(field "$(jq_type "$TMP/o13.jsonl" rollup | tail -1)" serves_found)" "0"

echo "=== 12. rollup exposes sampling degradation, not just an average ==="
locks_write "$(noise)"; mk_wchan "$SERVE_PID" do_epoll_wait
run_probe 1.2 "$TMP/o14.jsonl"
RG="$(jq_type "$TMP/o14.jsonl" rollup | tail -1)"
have "rollup reports max inter-sample gap" "$(field "$RG" max_gap_ms)"
# res_ms is the NOMINAL period; max_gap_ms is what actually bounds the error.
python3 -c "
import sys; g=float(sys.argv[1]); sys.exit(0 if 0 < g < 200 else 1)" "$(field "$RG" max_gap_ms)" \
  && ok "max gap is plausible on an idle box" || no "max gap is plausible on an idle box"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
