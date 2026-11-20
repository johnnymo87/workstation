#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Build a runnable copy the way writeShellApplication would.
# Absolute shebangs: the flake-check sandbox has no /usr/bin/env
# (same trap as users/dev/test-disk-watch.sh:121-125).
bash_bin=$(command -v bash)
bin=$(mktemp)
trap 'rm -f "$bin"' EXIT
{ echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/em-slack.sh" "$here/em-ci-failover.sh"; } >"$bin"; chmod +x "$bin"

setup() { # fresh sandbox per case
  S=$(mktemp -d); export STATE_DIRECTORY=$S/state CREDENTIALS_DIRECTORY=$S/cred
  mkdir -p "$STATE_DIRECTORY" "$CREDENTIALS_DIRECTORY"
  echo tok >"$CREDENTIALS_DIRECTORY/gh_token"; echo https://hooks.slack.com/services/T0/B0/x >"$CREDENTIALS_DIRECTORY/slack_webhook"
  export EM_CI_REPO=o/r EM_CI_PRIMARY_PREFIX=gamebox- EM_CI_FALLBACK_RUNNERS="devbox-em-ci-1 devbox-em-ci-2" \
         EM_CI_LABEL=em-ci EM_CI_TICKS=3 EM_CI_ERROR_ALERT=10 EM_CI_PRIMARY_OFFLINE_ALERT_H=6 EM_CI_NOW=1000000 \
         EM_CI_OVERFLOW_TICKS=2 EM_CI_OVERFLOW_MIN_MEM_GB=14 EM_CI_MEMINFO=$S/meminfo
  echo "MemAvailable:   20000000 kB" >"$S/meminfo"
  # Stub: GET answers from $S/runners.json (or fails if $S/api_down exists);
  # writes are appended to $S/writes.
  cat >"$S/gh" <<EOF
#!$bash_bin
[ -e "$S/api_down" ] && exit 22
[ -e "$S/write_down" ] && [ "\$1" != GET ] && exit 22
case "\$1" in GET) cat "$S/runners.json" ;; *) echo "\$*" >>"$S/writes" ;; esac
EOF
  # Slack stub fails (sends nothing) while $S/tg_down exists.
  printf '#!%s\n[ -e "%s/tg_down" ] && exit 7\necho "$1" >>"%s/tg"\n' "$bash_bin" "$S" "$S" >"$S/tgs"
  chmod +x "$S/gh" "$S/tgs"; export EM_CI_GH_API_STUB=$S/gh EM_CI_SLACK_STUB=$S/tgs
}
runners() { # $1: gamebox status, $2: devbox labels json array (e.g. '["em-ci"]' or '[]'), [$3: gamebox busy]
  jq -n --arg g "$1" --argjson d "$2" --argjson b "${3:-false}" '{runners:[
    {id:1,name:"gamebox-em-ci-1",status:$g,busy:$b,labels:[{name:"em-ci"}]},
    {id:11,name:"devbox-em-ci-1",status:"online",busy:false,labels:($d|map({name:.}))},
    {id:12,name:"devbox-em-ci-2",status:"online",busy:false,labels:($d|map({name:.}))}]}' >"$S/runners.json"
}
tick() { "$bin"; }
writes() { cat "$S/writes" 2>/dev/null || true; }

# 1. Empty state, gamebox online once: desired stays present; label already present -> no writes.
setup; runners online '["em-ci"]'; tick
check "initial desired present" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'
check "no writes when no drift" '[ -z "$(writes)" ]'

# 2. Online for 3 ticks -> desired absent -> DELETE on both devbox runners, one Slack message.
setup; runners online '["em-ci"]'; tick; tick; tick
check "absent after 3 online" '[ "$(cat $STATE_DIRECTORY/desired)" = absent ]'
check "deleted label on runner 11" 'grep -q "DELETE /repos/o/r/actions/runners/11/labels/em-ci" <<<"$(writes)"'
check "deleted label on runner 12" 'grep -q "DELETE /repos/o/r/actions/runners/12/labels/em-ci" <<<"$(writes)"'
check "one transition message" '[ "$(wc -l <"$S/tg")" -eq 1 ]'

# 3. Absent, label already gone -> next tick no writes.
: >"$S/writes"; runners online '[]'; tick
check "no writes once converged" '[ -z "$(writes)" ]'

# 4. Then offline for 2 ticks -> unchanged; 3rd -> present, POST on both.
runners offline '[]'; tick; tick
check "hysteresis holds at 2" '[ "$(cat $STATE_DIRECTORY/desired)" = absent ]'
tick
check "present after 3 offline" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'
check "posted label on 11" 'grep -q "POST /repos/o/r/actions/runners/11/labels" <<<"$(writes)"'

# 5. Mixed sequence resets the streak.
setup; runners online '["em-ci"]'; tick; tick; runners offline '["em-ci"]'; tick; runners online '["em-ci"]'; tick; tick
check "streak reset by an offline tick" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'

# 6. Drift: desired absent but a re-registration put the label back -> DELETE again.
setup; runners online '["em-ci"]'; tick; tick; tick; : >"$S/writes"; tick
check "re-asserts after drift" 'grep -q "DELETE /repos/o/r/actions/runners/11/labels/em-ci" <<<"$(writes)"'

# 7. API down: no state change, no writes; alert exactly once at 10 errors.
setup; runners online '["em-ci"]'; tick; touch "$S/api_down"
for _ in 1 2 3 4 5 6 7 8 9; do tick; done
check "no alert before 10 errors" '[ ! -e "$S/tg" ]'
tick
check "alert at 10 errors" '[ "$(grep -c "cannot reach the GitHub API" "$S/tg")" -eq 1 ]'
tick
check "not repeated at 11" '[ "$(grep -c "cannot reach the GitHub API" "$S/tg")" -eq 1 ]'
check "desired unchanged while API down" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'

# 8. Primary offline > 6 h -> one alert; clears when back online.
setup; runners offline '["em-ci"]'; tick
EM_CI_NOW=$((1000000 + 6*3600)) tick
check "offline-6h alert" '[ "$(grep -c "offline for" "$S/tg")" -eq 1 ]'
EM_CI_NOW=$((1000000 + 7*3600)) tick
check "offline-6h alert not repeated" '[ "$(grep -c "offline for" "$S/tg")" -eq 1 ]'

# 9. Missing fallback runner: skipped, no crash.
setup; jq -n '{runners:[{id:1,name:"gamebox-em-ci-1",status:"online",busy:false,labels:[]}]}' >"$S/runners.json"
check "missing fallback runner tolerated" 'tick; tick; tick'

# 10. Empty state files (crash mid-write) read as defaults, not "".
setup; runners online '["em-ci"]'; : >"$STATE_DIRECTORY/desired"; : >"$STATE_DIRECTORY/on"; tick
check "empty state file reads as default" '[ "$(cat $STATE_DIRECTORY/desired)" = present ] && [ "$(cat $STATE_DIRECTORY/on)" = 1 ]'

# 11. gamebox online but WITHOUT the em-ci label is not primary capacity.
setup; jq -n '{runners:[
  {id:1,name:"gamebox-em-ci-1",status:"online",busy:false,labels:[{name:"self-hosted"}]},
  {id:11,name:"devbox-em-ci-1",status:"online",busy:false,labels:[{name:"em-ci"}]}]}' >"$S/runners.json"
tick; tick; tick
check "label-less gamebox does not strip devbox" '[ "$(cat $STATE_DIRECTORY/desired)" = present ] && [ -z "$(writes)" ]'

# 12. Persistent label-write failures alert once, at EM_CI_ERROR_ALERT passes.
setup; runners online '["em-ci"]'; tick; tick; tick; touch "$S/write_down"; : >"$S/tg"
for _ in 1 2 3 4 5 6 7 8 9; do tick; done
check "no write alert before 10 failed passes" '[ "$(grep -c "label writes" "$S/tg")" -eq 0 ]'
tick
check "write alert at 10 failed passes" '[ "$(grep -c "label writes" "$S/tg")" -eq 1 ]'
tick
check "write alert not repeated" '[ "$(grep -c "label writes" "$S/tg")" -eq 1 ]'

# 13. A failed send of the offline alert is retried next pass, not lost.
setup; runners offline '["em-ci"]'; tick; touch "$S/tg_down"
EM_CI_NOW=$((1000000 + 6*3600)) tick
check "offline alert not latched when send fails" '[ "$(cat $STATE_DIRECTORY/offline_alerted)" = 0 ]'
rm -f "$S/tg_down"; EM_CI_NOW=$((1000000 + 6*3600 + 60)) tick
check "offline alert sent on retry" '[ "$(grep -c "offline for" "$S/tg")" -eq 1 ]'

# 14. Overflow (kdubj.102): every gamebox runner busy for EM_CI_OVERFLOW_TICKS -> devbox
#     takes em-ci jobs too; gamebox not saturated for EM_CI_TICKS -> stripped again.
setup; runners online '["em-ci"]'; tick; tick; tick; : >"$S/writes"; : >"$S/tg"
runners online '[]' true; tick
check "overflow waits at 1 saturated tick" '[ -z "$(writes)" ]'
tick
check "overflow adds label on 11" 'grep -q "POST /repos/o/r/actions/runners/11/labels" <<<"$(writes)"'
check "overflow adds label on 12" 'grep -q "POST /repos/o/r/actions/runners/12/labels" <<<"$(writes)"'
check "failover state stays absent in overflow" '[ "$(cat $STATE_DIRECTORY/desired)" = absent ]'
check "overflow sends no Slack message" '[ ! -s "$S/tg" ]'
: >"$S/writes"; runners online '["em-ci"]' true; tick
check "no writes while overflow holds" '[ -z "$(writes)" ]'
runners online '["em-ci"]' false; tick; tick
check "overflow holds through 2 unsaturated ticks" '[ -z "$(writes)" ]'
tick
check "overflow ends after 3 unsaturated ticks" 'grep -q "DELETE /repos/o/r/actions/runners/11/labels/em-ci" <<<"$(writes)"'

# 15. Saturation streak resets on an unsaturated tick.
setup; runners online '[]'; tick; tick; tick; : >"$S/writes"
runners online '[]' true; tick; runners online '[]' false; tick; runners online '[]' true; tick
check "saturation streak reset" '[ -z "$(writes)" ]'

# 16. One busy and one idle gamebox runner is not saturation.
setup; jq -n '{runners:[
  {id:1,name:"gamebox-em-ci-1",status:"online",busy:true,labels:[{name:"em-ci"}]},
  {id:2,name:"gamebox-em-ci-2",status:"online",busy:false,labels:[{name:"em-ci"}]},
  {id:11,name:"devbox-em-ci-1",status:"online",busy:false,labels:[]}]}' >"$S/runners.json"
tick; tick; tick; : >"$S/writes"; tick; tick; tick
check "partly busy gamebox is not saturated" '[ -z "$(writes)" ]'

# 17. Busy-but-offline primaries (all offline) are failover, not overflow: still present.
setup; runners offline '["em-ci"]' true; tick; tick; tick
check "offline busy primary stays failover present" '[ "$(cat $STATE_DIRECTORY/desired)" = present ] && [ -z "$(writes)" ]'

# 18. Overflow holds back while devbox memory is short; failover is unaffected.
setup; runners online '["em-ci"]'; tick; tick; tick; : >"$S/writes"
echo "MemAvailable:   8000000 kB" >"$S/meminfo"
runners online '[]' true; tick; tick; tick
check "overflow held back on low memory" '[ -z "$(writes)" ] && [ "$(cat $STATE_DIRECTORY/overflow)" = 1 ]'
echo "MemAvailable:   20000000 kB" >"$S/meminfo"; tick
check "overflow resumes when memory is back" 'grep -q "POST /repos/o/r/actions/runners/11/labels" <<<"$(writes)"'
setup; echo "MemAvailable:   8000000 kB" >"$S/meminfo"; runners offline '[]'; tick
check "failover ignores the memory guard" 'grep -q "POST /repos/o/r/actions/runners/11/labels" <<<"$(writes)"'

# 19. Without the stub, an alert goes through em-slack.sh's slack_send (fake curl).
setup; unset EM_CI_SLACK_STUB; export EM_SLACK_OWNER_ID=U0OWNER1
mkdir -p "$S/bin"; printf '#!%s\nprintf "%%s\\n" "$*" >>"%s/curl.args"\ncat >>"%s/curl.in"\n' "$bash_bin" "$S" "$S" >"$S/bin/curl"
chmod +x "$S/bin/curl"; touch "$S/api_down"
for _ in 1 2 3 4 5 6 7 8 9 10; do PATH="$S/bin:$PATH" tick; done
check "real path: the alert reaches the webhook via slack_send" \
  'grep -qx "url = \"https://hooks.slack.com/services/T0/B0/x\"" "$S/curl.in" && grep -qF "\"text\":\"em-ci failover (devbox): cannot reach the GitHub API" "$S/curl.args"'
unset EM_SLACK_OWNER_ID

[ "$fail" -eq 0 ] || { echo "FAILED $fail"; exit 1; }
echo "ALL PASS ($pass assertions)"
