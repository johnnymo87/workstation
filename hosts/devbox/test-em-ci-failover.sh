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
{ echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/em-ci-failover.sh"; } >"$bin"; chmod +x "$bin"

setup() { # fresh sandbox per case
  S=$(mktemp -d); export STATE_DIRECTORY=$S/state CREDENTIALS_DIRECTORY=$S/cred
  mkdir -p "$STATE_DIRECTORY" "$CREDENTIALS_DIRECTORY"
  echo tok >"$CREDENTIALS_DIRECTORY/gh_token"; echo bot >"$CREDENTIALS_DIRECTORY/tg_bot_token"; echo 1 >"$CREDENTIALS_DIRECTORY/tg_chat_id"
  export EM_CI_REPO=o/r EM_CI_PRIMARY_PREFIX=gamebox- EM_CI_FALLBACK_RUNNERS="devbox-em-ci-1 devbox-em-ci-2" \
         EM_CI_LABEL=em-ci EM_CI_TICKS=3 EM_CI_ERROR_ALERT=10 EM_CI_PRIMARY_OFFLINE_ALERT_H=6 EM_CI_NOW=1000000
  # Stub: GET answers from $S/runners.json (or fails if $S/api_down exists);
  # writes are appended to $S/writes.
  cat >"$S/gh" <<EOF
#!$bash_bin
[ -e "$S/api_down" ] && exit 22
case "\$1" in GET) cat "$S/runners.json" ;; *) echo "\$*" >>"$S/writes" ;; esac
EOF
  printf '#!%s\necho "$1" >>"%s/tg"\n' "$bash_bin" "$S" >"$S/tgs"
  chmod +x "$S/gh" "$S/tgs"; export EM_CI_GH_API_STUB=$S/gh EM_CI_TG_STUB=$S/tgs
}
runners() { # $1: gamebox status, $2: devbox labels json array (e.g. '["em-ci"]' or '[]')
  jq -n --arg g "$1" --argjson d "$2" '{runners:[
    {id:1,name:"gamebox-em-ci-1",status:$g,busy:false,labels:[{name:"em-ci"}]},
    {id:11,name:"devbox-em-ci-1",status:"online",busy:false,labels:($d|map({name:.}))},
    {id:12,name:"devbox-em-ci-2",status:"online",busy:false,labels:($d|map({name:.}))}]}' >"$S/runners.json"
}
tick() { "$bin"; }
writes() { cat "$S/writes" 2>/dev/null || true; }

# 1. Empty state, gamebox online once: desired stays present; label already present -> no writes.
setup; runners online '["em-ci"]'; tick
check "initial desired present" '[ "$(cat $STATE_DIRECTORY/desired)" = present ]'
check "no writes when no drift" '[ -z "$(writes)" ]'

# 2. Online for 3 ticks -> desired absent -> DELETE on both devbox runners, one Telegram.
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

[ "$fail" -eq 0 ] || { echo "FAILED $fail"; exit 1; }
echo "ALL PASS ($pass assertions)"
