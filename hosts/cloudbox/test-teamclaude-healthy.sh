#!/usr/bin/env bash
# Tests for hosts/cloudbox/teamclaude-healthy.jq, the account classification
# the TeamClaude pool canary compares against its high-water mark
# (bead claude-failover-proxy-w1w).
#
# Two halves:
#   1. Synthetic status bodies, one per state the canary must tell apart.
#   2. A replay of REAL canary samples (teamclaude-pool-samples.fixture.jsonl,
#      extracted from /var/lib/teamclaude-pool-canary/quota-samples.jsonl):
#      the 2026-09-07 weekly-roll null blip and the 2026-09-10 throttle storm.
#      The pre-fix filter is replayed alongside as a control, so this suite
#      proves the fixture still REPRODUCES the storm -- otherwise "no storm
#      under the new filter" would pass vacuously on a fixture that never had
#      one.
#
# Samples do not record reset timestamps, so the replay synthesizes them from
# TeamClaude's own invariant: it nulls a bucket's utilization AND reset
# together on the first status read after the reset passes, so a non-null
# utilization implies a reset still ahead.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${TEAMCLAUDE_HEALTHY_JQ:-$HERE/teamclaude-healthy.jq}"
FIXTURE="$HERE/teamclaude-pool-samples.fixture.jsonl"

pass=0; fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1: expected [$2] got [$3]"; fi
}

NOW_MS=$(( $(date +%s) * 1000 ))
AHEAD=$(( NOW_MS + 3600000 ))       # 1h ahead
PAST_IN_GRACE=$(( NOW_MS - 300000 ))  # 5m ago (inside the 15m skew grace)
PAST=$(( NOW_MS - 7200000 ))        # 2h ago

# acct NAME STATUS U5H U7D U7DF R5H R7D [DISABLED]
acct() {
  jq -nc --arg n "$1" --arg s "$2" --argjson u5 "$3" --argjson u7 "$4" --argjson f "$5" \
         --argjson r5 "$6" --argjson r7 "$7" --argjson d "${8:-false}" \
    '{name: $n, status: $s, disabled: $d,
      quota: {unified5h: $u5, unified7d: $u7, unified7dFable: $f,
              unified5hReset: $r5, unified7dReset: $r7}}'
}
body() { jq -sc '{accounts: .}'; }
run() { jq -r -f "$FILTER"; }

OK1=$(acct a active 0.2 0.3 0.1 "$AHEAD" "$AHEAD")
OK2=$(acct b active 0 0.4 0 null "$AHEAD")
OK3=$(acct c active 0.1 null 0.2 "$AHEAD" null)   # null 7d, live Fable: healthy
OK4=$(acct d active 0.5 0.5 0.5 "$AHEAD" "$AHEAD")

# --- 1. synthetic states ------------------------------------------------------
check "all serving" "4 4" "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$OK4" | body | run)"

check "5h-spent throttled account stays healthy (the 09-10 case)" "4 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 1.0 0.1 0.1 "$AHEAD" "$AHEAD")" | body | run)"

check "7d-spent throttled account, 5h idle, stays healthy" "4 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 0 1.0 0.5 null "$AHEAD")" | body | run)"

check "throttled with reset just past (inside skew grace) stays healthy" "4 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 1.0 null null "$PAST_IN_GRACE" null)" | body | run)"

check "dead grant (status=error) is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d error 0.2 0.2 0.2 "$AHEAD" "$AHEAD")" | body | run)"

check "disabled account is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d active 0.2 0.2 0.2 "$AHEAD" "$AHEAD" true)" | body | run)"

check "disabled+throttled account is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 1.0 0.2 0.2 "$AHEAD" "$AHEAD" true)" | body | run)"

check "plan-less active account is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d active 0 null null null null)" | body | run)"

check "plan-less throttled account is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled null null null null null)" | body | run)"

check "backstop: throttled, reporting, but no reset ahead is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 1.0 0.3 0.3 null null)" | body | run)"

check "backstop: throttled with every reset long past is NOT healthy" "3 3" \
  "$(printf '%s\n' "$OK1" "$OK2" "$OK3" "$(acct d throttled 1.0 0.3 0.3 "$PAST" "$PAST")" | body | run)"

check "whole pool spent: healthy 4, serving 0" "4 0" \
  "$(printf '%s\n' "$(acct a throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" "$(acct b throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" \
                   "$(acct c throttled 0 1.0 0.3 null "$AHEAD")" "$(acct d throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" | body | run)"

check "global quota outage (nobody reports) falls back to active count" "4 4" \
  "$(printf '%s\n' "$(acct a active 0 null null null null)" "$(acct b active 0 null null null null)" \
                   "$(acct c active 0 null null null null)" "$(acct d active 0 null null null null)" | body | run)"

check "spent accounts reporting quota disable the outage fallback for a plan-less one" "3 0" \
  "$(printf '%s\n' "$(acct a throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" "$(acct b throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" \
                   "$(acct c throttled 1.0 0.3 0.3 "$AHEAD" "$AHEAD")" "$(acct d active 0 null null null null)" | body | run)"

check "empty roster" "0 0" "$(echo '{"accounts": []}' | run)"
check "missing accounts key" "0 0" "$(echo '{}' | run)"

# --- 2. replay of real samples -------------------------------------------------
[ -s "$FIXTURE" ] || { echo "FAIL fixture missing: $FIXTURE"; exit 1; }

# The pre-fix filter (workstation PR #465), verbatim, as the control.
OLD_FILTER='
  ( [ (.accounts // [])[]
      | select(.disabled != true and .status == "active") ] ) as $active
  | ( [ $active[] | select( ((.quota.unified7d) != null)
                         or ((.quota.unified7dFable) != null)
                         or (((.quota.unified5h) // 0) > 0) ) ] ) as $reporting
  | (if ($reporting | length) == 0 then ($active | length) else ($reporting | length) end)'

BODIES=$(jq -c --argjson now "$NOW_MS" '{ts, accounts: [.accounts[] | {
    name: .n, status: .s, disabled: false,
    quota: {unified5h: .u5h, unified7d: .u7d, unified7dFable: .u7dF,
            unified5hReset: (if .u5h != null then $now + 3600000 else null end),
            unified7dReset: (if .u7d != null then $now + 86400000 else null end)}}]}' "$FIXTURE")

# Canary gate: HEALTHY below the high-water mark (4, as deployed) on 2
# consecutive passes. Counts passes that would have reached the pager.
pageable() { # day, then one healthy count per line on stdin (ordered)
  local pend=0 n=0 h
  while read -r h; do
    if [ "$h" -lt 4 ]; then pend=$((pend + 1)); [ "$pend" -ge 2 ] && n=$((n + 1)); else pend=0; fi
  done
  echo "$n"
}
day() { jq -c --arg d "$1" 'select(.ts | startswith($d))' <<<"$BODIES"; }

OLD_0910=$(day 2026-09-10 | jq -r "$OLD_FILTER")
NEW_0910=$(day 2026-09-10 | jq -r -f "$FILTER")
check "control: pre-fix filter reproduces the 09-10 storm (39 degraded passes)" "39" \
  "$(awk '$1 < 4' <<<"$OLD_0910" | wc -l)"
check "control: of which 38 were pageable (2-consecutive gate)" "38" "$(pageable <<<"$OLD_0910")"
check "new filter: 09-10 has zero degraded passes" "0" \
  "$(cut -d' ' -f1 <<<"$NEW_0910" | awk '$1 < 4' | wc -l)"
check "new filter: 09-10 whole-pool-spent passes (serving=0)" "8" \
  "$(cut -d' ' -f2 <<<"$NEW_0910" | awk '$1 == 0' | wc -l)"

NEW_0907=$(day 2026-09-07 | jq -r -f "$FILTER" | cut -d' ' -f1)
check "09-07 weekly-roll null blip still reads as 3 for exactly one pass" "1" \
  "$(awk '$1 == 3' <<<"$NEW_0907" | wc -l)"
check "09-07 blip is still absorbed by the 2-consecutive gate" "0" "$(pageable <<<"$NEW_0907")"

# Same real 09-10 bodies, with a dead or plan-less account injected in place of
# johnnymo873: the fix must not have blinded the canary to either.
DEAD=$(day 2026-09-10 | jq -c '.accounts |= map(if .name == "johnnymo873" then .status = "error" else . end)' \
  | jq -r -f "$FILTER" | cut -d' ' -f1)
check "real 09-10 + dead grant: every pass degraded" "45" "$(awk '$1 < 4' <<<"$DEAD" | wc -l)"
PLANLESS=$(day 2026-09-10 | jq -c '.accounts |= map(if .name == "johnnymo873"
    then .status = "active" | .quota = {unified5h: 0, unified7d: null, unified7dFable: null,
                                        unified5hReset: null, unified7dReset: null} else . end)' \
  | jq -r -f "$FILTER" | cut -d' ' -f1)
check "real 09-10 + plan-less account: every pass degraded" "45" "$(awk '$1 < 4' <<<"$PLANLESS" | wc -l)"

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS ($pass assertions)"
else
  echo "FAILED: $fail of $((pass + fail)) assertions"
  exit 1
fi
