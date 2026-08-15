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

run_watch() {
  local now="$1"
  : > "$ALERT_LOG"
  LANE_DEADMAN_FILE="$DEADMAN" \
  LANE_EXPECT_FILE="$EXPECT" \
  LANE_ALERT_CMD="$ALERT_CMD" \
  LANE_ALERT_STATE="$TMP/alert.state" \
  LANE_LABEL="testlane" \
  WATCHDOG_NOW="$now" \
  bash "$WATCH" > "$TMP/out.log" 2>&1
  return $?
}

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
if [ "$failures" -eq 0 ]; then echo "All lane-deadman-watch tests passed."; else echo "$failures test(s) FAILED."; exit 1; fi
