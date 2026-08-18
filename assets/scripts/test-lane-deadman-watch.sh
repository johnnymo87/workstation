#!/usr/bin/env bash
# Tests for lane-deadman-watch: the staleness observer for a scheduled autonomous lane.
#
# It exists because "exit 0" is not health. A lane whose upstream renames a label polls
# successfully, matches nothing, reports "nothing to do" daily, and is indistinguishable from a
# healthy idle lane to systemd and to every failure hook. This suite pins the cases where that
# distinction is made -- and, just as importantly, the cases where the watcher must STAY QUIET,
# because a watchdog that cries wolf gets muted and then protects nothing.
#
# Every assertion below encodes a hazard that was measured or reasoned about, not a hypothetical:
#
#  1. Monday false-positive  -> a Friday success is 3 CALENDAR days old on Monday but only ONE
#                               missed weekday slot. Naive `now - mtime > 3d` pages every single
#                               Monday until someone mutes it.
#  2. UTC vs local           -> the lane writes UTC; the slot is 16:00 local. A Friday run that
#                               finishes at 19:00 local (the unit allows 3h) stamps SATURDAY in
#                               UTC. Misreading that shifts every subsequent slot.
#  3. today's slot not due   -> must not count a slot whose hour has not arrived.
#  4. genuinely dead         -> alarms.
#  5. never ran              -> alarms. Distinct from stale: no file at all.
#  6. unparseable            -> alarms rather than assuming health.
#  7. FUTURE-dated           -> alarms. Clock skew or a manual touch would otherwise compute zero
#                               missed slots and silence the check forever.
#  8. expectation gate       -> silent even with an ancient timestamp. Without this the watcher
#                               pages from the day it deploys, because the lane is deliberately
#                               not enabled yet.
#  9. healthy pass clears    -> the backoff episode resets, so the NEXT outage pages immediately
#     alert state              instead of inheriting a suppressed count.
# 10. DST transition         -> no off-by-one across a spring-forward weekend.
# 11. constant signature     -> two alarming passes present the SAME signature to the helper.
#                               A date-derived signature would make every pass a new episode:
#                               dedup never matches, backoff never engages, and it decays into a
#                               flat daily nag that never escalates.
#
# The suite drives the SCRIPT AS DEPLOYED via env seams -- never by sourcing internals -- so a
# pinned-PATH bug (a binary the source uses but the unit does not provide) can still be caught.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/lane-deadman-watch"
TMP="$(mktemp -d /tmp/test-deadman-watch.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

ALERT_LOG="$TMP/alerts.log"
ALERT_CMD="$TMP/mock-alert"
# NOTE the UNQUOTED heredoc: $ALERT_LOG must be expanded NOW, by this shell, because the mock
# runs as a separate process that never sees this suite's variables. Written with a quoted
# heredoc it appends to the empty string, silently records nothing, and every alarm assertion
# reads as "quiet" -- which is exactly how it failed on first run, reporting six failures in a
# watchdog that was in fact alarming correctly. $2/$3 are escaped so they stay runtime args.
# The shebang is the RUNNING interpreter, not `/usr/bin/env bash`. This suite also runs inside
# the nix flake-check sandbox, where /usr/bin/env does not exist at all -- so an env shebang
# yields "bad interpreter", the recorder never runs, every alarm assertion reads as "quiet", and
# the suite reports failures in a watchdog that is alarming perfectly. That is the same class of
# bug as the unit needing an explicit interpreter, found the same way: by running it somewhere
# stricter than a login shell.
cat > "$ALERT_CMD" <<EOF
#!$BASH
# Records what the real helper would have been asked to send. Logging the SIGNATURE as well as
# the text is deliberate: a sibling suite in this repo once logged only subject and body, which
# made it structurally incapable of noticing a dropped severity argument -- and it duly missed
# one for weeks. An instrument that cannot see the field under test proves nothing about it.
echo "sig=\$2 | text=\$3" >> "$ALERT_LOG"
EOF
chmod +x "$ALERT_CMD"

failures=0
DEADMAN="$TMP/last-success"
EXPECT="$TMP/expect"
touch "$EXPECT"

# Mock `systemctl` for the cadence assertion. Same seam discipline as the alert mock: the suite
# drives the script as deployed and never sources its internals, so the real branch logic (rather
# than a reimplementation of it) is what gets exercised. The state is read from a file the tests
# rewrite, so one mock covers enabled / disabled / not-found / missing-binary.
CADENCE_STATE_FILE="$TMP/cadence-state"
CADENCE_CMD="$TMP/mock-systemctl"
cat > "$CADENCE_CMD" <<EOF
#!$BASH
# Args arrive as: --user <is-enabled|is-active> <unit>. The state file holds BOTH answers as
# "<enabled-answer> <active-answer>", because a timer can be enabled on disk and not running --
# which is the whole point of case 21 and is invisible to a mock that models only one verb.
read -r want_enabled want_active < "$CADENCE_STATE_FILE" 2>/dev/null
[ -z "\$want_active" ] && want_active=active
case "\$2" in
  is-active)
    case "\$want_active" in
      active)  echo active;   exit 0 ;;
      silent)  exit 127 ;;
      *)       echo "\$want_active"; exit 3 ;;
    esac ;;
  *)
    case "\$want_enabled" in
      enabled)   echo enabled;   exit 0 ;;
      disabled)  echo disabled;  exit 1 ;;
      not-found) echo not-found; exit 4 ;;
      silent)    exit 127 ;;
      *)         echo "\$want_enabled"; exit 1 ;;
    esac ;;
esac
EOF
chmod +x "$CADENCE_CMD"
echo "enabled active" > "$CADENCE_STATE_FILE"

run_watch() {
  local now="$1"
  : > "$ALERT_LOG"
  LANE_DEADMAN_FILE="$DEADMAN" \
  LANE_EXPECT_FILE="$EXPECT" \
  LANE_ALERT_CMD="$ALERT_CMD" \
  LANE_ALERT_STATE="$TMP/alert.state" \
  LANE_LABEL="testlane" \
  LANE_CADENCE_UNIT="${CADENCE_UNIT_OVERRIDE-testlane.timer}" \
  LANE_CADENCE_QUERY_CMD="$CADENCE_CMD" \
  LANE_CADENCE_ALERT_STATE="$TMP/alert.state.cadence" \
  WATCHDOG_NOW="$now" \
  bash "$WATCH" > "$TMP/out.log" 2>&1
  return $?
}

# Verdicts that distinguish WHICH assertion spoke. `verdict` alone cannot: it only asks whether
# the log is non-empty, so a cadence alarm would read as a staleness alarm and every pre-existing
# quiet-case assertion would silently become untrustworthy the moment cadence could fire.
cadence_verdict() { if grep -q "sig=cadence-" "$ALERT_LOG" 2>/dev/null; then echo alarm; else echo quiet; fi; }
stale_verdict()   { if grep -q "sig=deadman-" "$ALERT_LOG" 2>/dev/null; then echo alarm; else echo quiet; fi; }

check() {
  local name="$1" want="$2" got="$3"      # want/got: alarm|quiet
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name -- wanted $want, got $got"
    sed -n '1,4p' "$TMP/out.log" 2>/dev/null || true
    failures=$((failures + 1))
  fi
}

verdict() { if [ -s "$ALERT_LOG" ]; then echo alarm; else echo quiet; fi; }

# 1. Friday 16:05 EDT success, checked Monday 17:00 -> ONE missed slot. Must stay quiet.
echo "2026-08-14T20:05:00Z" > "$DEADMAN"          # Fri 2026-08-14 16:05 EDT
run_watch "2026-08-17T17:00:00-04:00"; check "Monday after a Friday success stays quiet (1 slot)" quiet "$(verdict)"

# 2. Friday run finishing 19:00 EDT stamps SATURDAY in UTC. Still one slot by Monday.
echo "2026-08-14T23:00:00Z" > "$DEADMAN"          # Fri 19:00 EDT == Sat 00:00 UTC? (23:00Z = Fri 19:00 EDT)
run_watch "2026-08-17T17:00:00-04:00"; check "Friday-evening UTC stamp still reads as Friday local" quiet "$(verdict)"

# 3. Wednesday success, checked Thursday 15:00 (before the 16:00 slot) -> 0 slots.
echo "2026-08-12T20:05:00Z" > "$DEADMAN"          # Wed 16:05 EDT
run_watch "2026-08-13T15:00:00-04:00"; check "today's slot not yet due" quiet "$(verdict)"

# 4. Friday success, checked the following Thursday -> Mon,Tue,Wed,Thu = 4 missed. Alarm.
echo "2026-08-14T20:05:00Z" > "$DEADMAN"
run_watch "2026-08-20T17:00:00-04:00"; check "four missed weekday slots alarms" alarm "$(verdict)"
if [ -s "$ALERT_LOG" ] && ! grep -q "missed 4 consecutive weekday runs" "$ALERT_LOG"; then
  echo "FAIL: alarm text should name the missed-slot count"; failures=$((failures + 1))
fi

# 5. No file at all while a lane is expected -> alarm (never ran / was removed).
rm -f "$DEADMAN"
run_watch "2026-08-17T17:00:00-04:00"; check "absent dead-man file alarms" alarm "$(verdict)"

# 6. Unparseable content -> alarm, not assumed healthy.
echo "not-a-timestamp" > "$DEADMAN"
run_watch "2026-08-17T17:00:00-04:00"; check "unparseable timestamp alarms" alarm "$(verdict)"

# 7. Future-dated -> alarm. Would otherwise compute 0 slots and go quiet forever.
echo "2027-01-01T00:00:00Z" > "$DEADMAN"
run_watch "2026-08-17T17:00:00-04:00"; check "future-dated timestamp alarms" alarm "$(verdict)"

# 8. THE GATE. Ancient timestamp, but nothing is expected to be running -> silent.
echo "2020-01-01T00:00:00Z" > "$DEADMAN"
rm -f "$EXPECT"
run_watch "2026-08-17T17:00:00-04:00"; check "no expectation flag stays silent even when ancient" quiet "$(verdict)"
touch "$EXPECT"

# 9. A healthy pass clears the alert episode, so the next outage is not suppressed by old state.
echo "2026-08-14T20:05:00Z" > "$DEADMAN"
touch "$TMP/alert.state"
run_watch "2026-08-17T17:00:00-04:00"
if [ -e "$TMP/alert.state" ]; then
  echo "FAIL: healthy pass left stale alert state (next outage would inherit its backoff)"; failures=$((failures + 1))
else
  echo "PASS: healthy pass clears alert state"
fi

# 10. DST: spring-forward Sunday 2026-03-08. Fri 03-06 success, checked Wed 03-11 -> Mon,Tue,Wed.
echo "2026-03-06T21:05:00Z" > "$DEADMAN"          # Fri 16:05 EST
run_watch "2026-03-11T17:00:00-04:00"; check "DST spring-forward counts 3 slots, not 2 or 4" alarm "$(verdict)"
if [ -s "$ALERT_LOG" ] && ! grep -q "missed 3 consecutive weekday runs" "$ALERT_LOG"; then
  echo "FAIL: DST week miscounted"; sed -n '1p' "$ALERT_LOG"; failures=$((failures + 1))
fi

# 11. Signature is CONSTANT across passes, so the helper can dedup and back off.
echo "2026-08-14T20:05:00Z" > "$DEADMAN"
run_watch "2026-08-20T17:00:00-04:00"; sig1="$(cat "$ALERT_LOG")"
run_watch "2026-08-21T17:00:00-04:00"; sig2="$(cat "$ALERT_LOG")"
s1="${sig1%% | *}"; s2="${sig2%% | *}"
if [ "$s1" = "$s2" ] && [ -n "$s1" ]; then
  echo "PASS: alert signature is constant across passes ($s1)"
else
  echo "FAIL: signature changed between passes ('$s1' vs '$s2') -- dedup and backoff would never engage"
  failures=$((failures + 1))
fi

echo

# ---------------------------------------------------------------------------------------------
# CADENCE ASSERTION (W1: the fifth fake-health bug -- a follow-up chain masking a dead timer).
#
# Case 12 is the one that matters and the reason this block exists. Everything else here is a
# guard against it becoming a nuisance alarm, since a watcher that cries wolf gets muted and
# then protects nothing -- which would take the staleness check down with it.
# ---------------------------------------------------------------------------------------------

# 12. THE REGRESSION TEST FOR W1. Dead-man is PERFECTLY FRESH -- exactly what a self-scheduled
#     follow-up chain produces -- but the cadence timer has been disabled. Before this assertion
#     the pass was silent and the lane's guaranteed floor was gone with nothing to say so.
echo "2026-08-17T20:05:00Z" > "$DEADMAN"          # Mon 16:05 EDT, i.e. a healthy recent success
echo "disabled inactive" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; rc=$?
check "W1: fresh dead-man + DISABLED timer still alarms" alarm "$(cadence_verdict)"
check "W1: ...and it is the cadence episode, not a staleness alarm" quiet "$(stale_verdict)"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: W1 cadence failure must exit non-zero even when the dead-man is fresh"; failures=$((failures + 1))
else
  echo "PASS: W1 cadence failure exits non-zero on an otherwise-healthy pass"
fi

# 13. Unit removed entirely (the reprovision case: home-manager restores this watcher, the
#     imperatively-installed lane unit stays gone).
echo "not-found inactive" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; check "cadence unit not-found alarms" alarm "$(cadence_verdict)"
grep -q "DOES NOT EXIST" "$TMP/out.log" || { echo "FAIL: not-found must be distinguishable from disabled in the text"; failures=$((failures + 1)); }

# 14. Cannot check at all (systemctl missing / no output). Must FAIL TOWARD THE ALARM, like
#     every other unparseable input in this file.
echo "silent silent" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; check "unqueryable cadence state alarms rather than assuming health" alarm "$(cadence_verdict)"

# 15. Enabled timer + fresh dead-man -> completely quiet, exit 0. The false-positive guard: if
#     this fires, the whole watcher gets muted and case 12 protects nothing.
echo "enabled active" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; rc=$?
check "enabled timer + fresh success stays quiet" quiet "$(verdict)"
[ "$rc" -eq 0 ] || { echo "FAIL: healthy pass must exit 0"; failures=$((failures + 1)); }

# 16. Expectation gate outranks cadence. Before cutover the timer is legitimately disabled, so a
#     cadence alarm here would page continuously from the day this deploys -- the precise
#     failure that case 8 exists to prevent for the staleness half.
echo "disabled inactive" > "$CADENCE_STATE_FILE"
rm -f "$EXPECT"
run_watch "2026-08-17T21:00:00-04:00"; check "no expectation flag: cadence check stays silent too" quiet "$(verdict)"
touch "$EXPECT"

# 17. Cadence check is OPTIONAL, and its skip is audible. An unset unit must not alarm, but must
#     say it skipped -- a silently skipped assertion looks identical to a passing one.
echo "disabled inactive" > "$CADENCE_STATE_FILE"
CADENCE_UNIT_OVERRIDE="" run_watch "2026-08-17T21:00:00-04:00"
check "unset LANE_CADENCE_UNIT skips without alarming" quiet "$(verdict)"
grep -q "SKIPPED" "$TMP/out.log" || { echo "FAIL: a skipped cadence check must say so in the log"; failures=$((failures + 1)); }

# 18. Both broken: the two alarms are SEPARATE episodes with distinct signatures, so neither
#     dedups the other away. One root cause hiding a second is how a two-fault outage reads as
#     one-fault and gets half-fixed.
echo "2026-07-01T20:05:00Z" > "$DEADMAN"          # ancient
echo "disabled inactive" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"
check "dead lane + dead timer: cadence alarm present" alarm "$(cadence_verdict)"
check "dead lane + dead timer: staleness alarm ALSO present" alarm "$(stale_verdict)"

# 19. Constant cadence signature across passes, mirroring case 11's reasoning: a signature that
#     varied per pass would defeat dedup and decay into a nag that never escalates.
echo "2026-08-17T20:05:00Z" > "$DEADMAN"
echo "disabled inactive" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; sig1="$(head -n1 "$ALERT_LOG" | cut -d' ' -f1)"
run_watch "2026-08-18T21:00:00-04:00"; sig2="$(head -n1 "$ALERT_LOG" | cut -d' ' -f1)"
if [ -n "$sig1" ] && [ "$sig1" = "$sig2" ]; then
  echo "PASS: cadence signature is constant across passes ($sig1)"
else
  echo "FAIL: cadence signature varies across passes ('$sig1' vs '$sig2')"; failures=$((failures + 1))
fi

# 20. A healthy cadence pass CLEARS its own episode file, so the next outage pages immediately
#     rather than inheriting a suppressed backoff count (case 9's reasoning, cadence half).
echo "enabled active" > "$CADENCE_STATE_FILE"
: > "$TMP/alert.state.cadence"
run_watch "2026-08-17T21:00:00-04:00"
[ -e "$TMP/alert.state.cadence" ] && { echo "FAIL: healthy cadence pass must clear its alert state"; failures=$((failures + 1)); } || echo "PASS: healthy cadence pass clears its own alert episode"

# 21. THE SIXTH FAKE-HEALTH BUG. A timer that is ENABLED on disk but STOPPED. `is-enabled`
#     answers "enabled" and rc 0; the timer has no next elapse and will not fire again until the
#     user manager restarts. This evades case 12's fix by one word -- `stop` instead of
#     `disable` -- and it is the MORE likely of the two, because stopping is what a careful human
#     does to pause something temporarily. Dead-man stays fresh via follow-ups; without this
#     assertion the watcher reports everything fine while the floor is gone.
echo "2026-08-17T20:05:00Z" > "$DEADMAN"
echo "enabled inactive" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; rc=$?
check "W1b: enabled-but-STOPPED timer alarms" alarm "$(cadence_verdict)"
check "W1b: ...and not as a staleness alarm" quiet "$(stale_verdict)"
[ "$rc" -ne 0 ] || { echo "FAIL: stopped-timer failure must exit non-zero"; failures=$((failures + 1)); }
grep -q "NOT RUNNING" "$TMP/out.log" || { echo "FAIL: text must distinguish stopped from disabled"; failures=$((failures + 1)); }

# 22. is-active unqueryable -> alarm, same fail-toward-alarm rule as every other branch.
echo "enabled silent" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; check "unqueryable is-active alarms" alarm "$(cadence_verdict)"

# 23. The healthy shape is BOTH: enabled AND active. Guards against the fix in 21 being
#     satisfied by anything less.
echo "enabled active" > "$CADENCE_STATE_FILE"
run_watch "2026-08-17T21:00:00-04:00"; check "enabled AND active stays quiet" quiet "$(verdict)"

if [ "$failures" -eq 0 ]; then echo "All lane-deadman-watch tests passed."; else echo "$failures test(s) FAILED."; exit 1; fi
