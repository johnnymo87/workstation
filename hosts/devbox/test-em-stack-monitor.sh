#!/usr/bin/env bash
# Tests for em-stack-monitor.sh. Everything outside the script is faked through
# its env hooks (fetch, gate, mode, stack-health, Telegram, clock), so this runs
# in the nix sandbox: no network, no /home, no stack. The fixtures under
# test-em-stack-monitor-fixtures/ were captured from the live stack on
# 2026-11-04 (real field types); variants are derived from them with jq.
# shellcheck disable=SC2016
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fx=$here/test-em-stack-monitor-fixtures
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }

# Build a runnable copy the way writeShellApplication would.
# Absolute shebangs: the flake-check sandbox has no /usr/bin/env.
bash_bin=$(command -v bash)
bin=$(mktemp)
repo=$(mktemp -d)
trap 'rm -f "$bin"; rm -rf "$repo"' EXIT
{ echo "#!$bash_bin"; echo 'set -euo pipefail'; cat "$here/em-stack-monitor.sh"; } >"$bin"; chmod +x "$bin"

# A throwaway repo (the one place bare identity flags are right) so the message
# can name a real short HEAD.
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m x
head_sha=$(git -C "$repo" rev-parse --short HEAD)

T0=1800000000   # an hour boundary

setup() { # fresh sandbox per case; the healthy live stack
  S=$(mktemp -d)
  export STATE_DIRECTORY=$S/state CREDENTIALS_DIRECTORY=$S/cred
  mkdir -p "$STATE_DIRECTORY" "$CREDENTIALS_DIRECTORY" "$S/web" "$S/tg" "$S/bin"
  echo bot >"$CREDENTIALS_DIRECTORY/tg_bot_token"; echo 1 >"$CREDENTIALS_DIRECTORY/tg_chat_id"
  export EM_STACK_REPO=$repo EM_STACK_RUNBOOK="eternal-machinery docs/runbooks/stack-health.md" \
         EM_STACK_REMIND_H=6 EM_STACK_GM_MIN=20 EM_STACK_NOW=$T0
  unset EM_STACK_MONITOR_DRY_RUN
  cat >"$S/fetch" <<EOF
#!$bash_bin
name=\$(printf '%s' "\${1#http://127.0.0.1:}" | tr '/' '_')
echo "\$1" >>"$S/fetch.log"
[ ! -e "$S/web/\$name.refused" ] || exit 7    # curl rc 7: connection refused (source gone)
[ -f "$S/web/\$name" ] || exit 28             # curl rc 28: timeout (source failed)
cat "$S/web/\$name"
EOF
  printf '#!%s\n[ ! -e "%s/nostack" ]\n' "$bash_bin" "$S" >"$S/gate"
  printf '#!%s\ncat "%s/mode" 2>/dev/null || true\n' "$bash_bin" "$S" >"$S/mode_cmd"
  printf '#!%s\ncat "%s/health"\n' "$bash_bin" "$S" >"$S/health_cmd"
  # Telegram stub: fails (records nothing) while tg_down exists.
  cat >"$S/tg_cmd" <<EOF
#!$bash_bin
if [ -e "$S/tg_down" ]; then cat >/dev/null; exit 7; fi
n=\$(ls "$S/tg" | wc -l)
cat >"$S/tg/\$n"
EOF
  chmod +x "$S/fetch" "$S/gate" "$S/mode_cmd" "$S/health_cmd" "$S/tg_cmd"
  export EM_STACK_FETCH_CMD=$S/fetch EM_STACK_GATE_CMD=$S/gate EM_STACK_MODE_CMD=$S/mode_cmd \
         EM_STACK_HEALTH_CMD=$S/health_cmd EM_STACK_TG_CMD=$S/tg_cmd
  echo manual-live >"$S/mode"
  cat "$fx/stack-health.txt" >"$S/health"
  serve 4002_v1_presence 200 "$fx/presence.json"
  serve 4002_v1_sessions_jonathan_status 200 "$fx/status-jonathan.json"
  serve 4002_v1_sessions_livia_status 503 "$fx/status-livia-503.json"
  serve 4400_em_quiescence 200 "$fx/quiescence.json"
}
serve() { { echo "$2"; cat "$3"; } >"$S/web/$1"; } # $1: name, $2: HTTP code, $3: body file
serve_jq() { # $1: name, $2: fixture, $3: jq filter (args: $4...) -> served 200
  local name=$1 f=$2 filter=$3; shift 3
  jq "$@" "$filter" "$fx/$f" >"$S/body.json"; serve "$name" 200 "$S/body.json"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123456Z; } # microseconds, as the API sends them

# stack-health output: the live capture with extra lines (before SUMMARY).
mkhealth() { # each arg: "name VERDICT detail"
  { grep -v '^SUMMARY' "$fx/stack-health.txt"
    for l in "$@"; do read -r n v d <<<"$l"; printf '  %-12s %-8s %s\n' "$n" "$v" "$d"; done
    echo "SUMMARY: FAIL — do not open a live window until this is green"; } >"$S/health"
}
# Replace one of the live capture's lines by a verdict (e.g. agentos DOWN).
sethealth() { # $1: check name, $2: verdict, $3: detail
  { grep -v "^SUMMARY\|^  $1 " "$fx/stack-health.txt"
    printf '  %-12s %-8s %s\n' "$1" "$2" "$3"
    echo "SUMMARY: FAIL — do not open a live window until this is green"; } >"$S/health"
}

run() { rc=0; "$bin" >"$S/out" 2>"$S/err" || rc=$?; }
at() { export EM_STACK_NOW=$((T0 + $1)); }
tgn() { ls "$S/tg" | wc -l; }
tgall() { cat "$S/tg"/* 2>/dev/null || true; }
tglast() { cat "$S/tg/$(( $(tgn) - 1 ))"; }
st() { jq -r "$1" "$STATE_DIRECTORY/state.json"; }
pend() { st ".pending[\"$1\"]"; }

# 1. Healthy live stack: quiet, records ok; the live WARNs never alert.
setup; run
check "healthy: exit 0" '[ "$rc" -eq 0 ]'
check "healthy: nothing sent" '[ "$(tgn)" -eq 0 ]'
check "healthy: state is ok" '[ "$(st .sig)" = ok ]'
check "healthy: all sources were read" 'grep -q "/v1/presence" "$S/fetch.log" && grep -q "jonathan/status" "$S/fetch.log" && grep -q "/em/quiescence" "$S/fetch.log"'
at 600; run; at 1200; run
check "healthy: still quiet after more passes (WARN lines, wanted close)" '[ "$(tgn)" -eq 0 ]'

# 1b. A never-started session (deferred boot), as stack-health prints it since
# EM #1173: INFO/WARN lines, no UNKNOWN. The fixture is a real run of #1173's
# stack-health as livia against the live stack (manual-live, the default mode here).
setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; run; at 600; run; at 1200; run
check "deferred boot (INFO/WARN only): no alert over three passes" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 0 ]'
export EM_STACK_MONITOR_DRY_RUN=1; run; unset EM_STACK_MONITOR_DRY_RUN
check "deferred boot: the raw key set is empty (no monitor:blind)" 'grep -qx "\[dry-run\] raw keys: (none)" "$S/out"'
check "fixture: the deferred capture has INFO and WARN lines and no UNKNOWN" \
  'grep -q "^  tape  *INFO" "$fx/stack-health-deferred.txt" && grep -q "^  routing_consumer WARN" "$fx/stack-health-deferred.txt" && ! grep -q UNKNOWN "$fx/stack-health-deferred.txt"'

# 2. No stack: quiet, clears pending without "resolved", asks nothing of the API.
setup; mkhealth "postgres FAIL refused"; run   # pass 1 of a debounced FAIL
: >"$S/fetch.log"; touch "$S/nostack"; at 600; run
check "no stack: quiet" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 0 ]'
check "no stack: no API fetch" '[ "$(wc -l <"$S/fetch.log")" -eq 0 ]'
check "no stack: pending dropped" '[ "$(st ".pending | length")" -eq 0 ] && [ "$(st .sig)" = "" ]'
rm "$S/nostack"; at 1200; run
check "after a restart the dropped problem restarts its debounce" '[ "$(tgn)" -eq 0 ]'
at 1800; run
check "and alerts fresh on its second pass" '[ "$(tgn)" -eq 1 ] && grep -q "^EM stack: problem" <<<"$(tglast)"'

# 3. Announced problems, then the stack stops: one "stopped" line, only once.
setup; mkhealth "postgres FAIL refused"; run; at 600; run
check "announced before stopping" '[ "$(tgn)" -eq 1 ]'
touch "$S/nostack"; at 1200; run
check "stopped: one closing line naming the key" '[ "$(tgn)" -eq 2 ] && grep -q "^EM stack: stopped, no longer watching: fail:postgres" <<<"$(tglast)"'
at 1800; run
check "stopped: not repeated" '[ "$(tgn)" -eq 2 ]'
rm "$S/nostack"; at 2400; run; at 3000; run
check "stack back with the problem: announced fresh as problem" '[ "$(tgn)" -eq 3 ] && grep -q "^EM stack: problem" <<<"$(tglast)"'
check "no resolved was ever sent" '! grep -q resolved <<<"$(tgall)"'

# 4. A FAIL alerts only on its second pass in a row; one clean pass resets it.
setup; mkhealth "postgres FAIL accepting no connections on 5434"; run
check "FAIL: first pass quiet" '[ "$(tgn)" -eq 0 ]'
sethealth postgres OK fine; at 600; run   # blip over (clean pass)
mkhealth "postgres FAIL again"; at 1200; run
check "FAIL: a clean pass between resets the count" '[ "$(tgn)" -eq 0 ]'
at 1800; run
check "FAIL: second pass in a row alerts once" '[ "$(tgn)" -eq 1 ]'
check "FAIL: message has head, key text, checkout HEAD and runbook" \
  'm=$(tglast); head -n 1 <<<"$m" | grep -qx "EM stack: problem" && grep -q "^- postgres FAIL: again" <<<"$m" && grep -q "@ $head_sha" <<<"$m" && grep -q "docs/runbooks/stack-health.md" <<<"$m"'
at 2400; run
check "FAIL: standing problem not repeated" '[ "$(tgn)" -eq 1 ]'
for v in DOWN DEAD_MANAGER; do
  setup; mkhealth "manager $v process manager gone"; run; at 600; run
  check "$v counts as a failure" 'grep -q "^- manager $v" <<<"$(tglast)"'
done

# 5. WARN and UNKNOWN lines never alert as such; UNKNOWN is monitor:blind only.
setup; mkhealth "api WARN HTTP 200 but session jonathan status=disconnected" "routing_consumer WARN BEAM predates routing"; run; at 600; run
check "WARN never alerts" '[ "$(tgn)" -eq 0 ]'
setup; mkhealth "map_fence UNKNOWN psql unresolvable"; run
check "UNKNOWN: first pass quiet" '[ "$(tgn)" -eq 0 ]'
at 600; run
check "UNKNOWN reads as monitor:blind on the second pass" '[ "$(tgn)" -eq 1 ] && grep -q "could not check: map_fence" <<<"$(tglast)"'
check "UNKNOWN never becomes fail:<check>" '! grep -q "map_fence FAIL" <<<"$(tglast)"'
setup; : >"$S/health"; run; at 600; run
check "no SUMMARY line is monitor:blind" '[ "$(tgn)" -eq 1 ] && grep -q "printed no SUMMARY" <<<"$(tglast)"'
setup; printf '#!%s\necho "boom" >&2; exit 3\n' "$bash_bin" >"$S/health_cmd"; run; at 600; run
check "stack-health crashing is monitor:blind and does not abort the pass" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ] && grep -q "printed no SUMMARY" <<<"$(tglast)"'

# 6. agentos DOWN: expected outside a live mode, a problem inside one.
setup; echo sim >"$S/mode"; sethealth agentos DOWN "not running"; run; at 600; run
check "agentos DOWN in sim is quiet" '[ "$(tgn)" -eq 0 ]'
setup; echo sim-reactive >"$S/mode"; sethealth agentos DOWN "not running"; run; at 600; run
check "agentos DOWN in sim-reactive is quiet" '[ "$(tgn)" -eq 0 ]'
setup; echo manual-live >"$S/mode"; sethealth agentos DOWN "not running"; run; at 600; run
check "agentos DOWN in manual-live alerts" '[ "$(tgn)" -eq 1 ] && grep -q "^- agentos DOWN" <<<"$(tglast)"'
setup; : >"$S/mode"; sethealth agentos DOWN "not running"; run; at 600; run
check "agentos DOWN with an unknown mode alerts (never silently blind)" '[ "$(tgn)" -eq 1 ]'
setup; echo sim >"$S/mode"; sethealth postgres FAIL refused; run; at 600; run
check "other FAILs in sim mode still alert" '[ "$(tgn)" -eq 1 ] && grep -q "^- postgres FAIL" <<<"$(tglast)"'

# 7. Stuck recovery needs no key of its own: stack-health's agentos FAIL carries it.
setup; sethealth agentos FAIL "recovering mcp child for 700s"; run; at 600; run
check "stuck recovery comes through as fail:agentos" '[ "$(tgn)" -eq 1 ] && grep -q "^- agentos FAIL: recovering" <<<"$(tglast)"'

# 8. Presence: a server close nobody asked for alerts; a wanted close does not.
setup
check "fixture: the live capture holds a wanted server close" \
  '[ "$(jq -r ".presence.jonathan | [.last_close.cause, (.wants_out | type)] | join(\",\")" "$fx/presence.json")" = "server,object" ]'
run; at 600; run; at 1200; run
check "wanted close (wants_out object) is quiet" '[ "$(tgn)" -eq 0 ]'
setup
serve_jq 4002_v1_presence presence.json \
  '.presence.livia.last_close = {at: $at, by: null, cause: "server", code: 1006, idle: true}' --arg at 2026-11-04T19:00:00Z
run
check "unwanted server close: first pass quiet" '[ "$(tgn)" -eq 0 ]'
at 600; run
check "unwanted server close alerts on the second pass" '[ "$(tgn)" -eq 1 ]'
check "presence text names the session, time, code and idle" \
  'm=$(tglast); grep -q "^- session livia is offline" <<<"$m" && grep -q "2026-11-04T19:00:00Z" <<<"$m" && grep -q "code 1006" <<<"$m" && grep -q "while idle" <<<"$m"'
serve_jq 4002_v1_presence presence.json '.presence.livia.last_close = {at: "2026-11-04T19:00:00Z", by: null, cause: "client", code: 1000, idle: false}'
at 1200; run
check "a client close clears it: resolved" '[ "$(tgn)" -eq 2 ] && grep -q "^EM stack: resolved, all checks OK again." <<<"$(tglast)"'
setup
serve_jq 4002_v1_presence presence.json '.presence.livia.link = "online" | .presence.livia.last_close = {at: "x", by: null, cause: "server", code: 1006, idle: false}'
run; at 600; run
check "an online link is not a presence problem" '[ "$(tgn)" -eq 0 ]'

# 9. Quarantine: the reason is a string; null is fine.
setup
serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "mcp child unrecoverable after 5 restarts"'
run
check "quarantine: first pass quiet" '[ "$(tgn)" -eq 0 ]'
at 600; run
check "quarantine alerts on the second pass, naming agent and reason" \
  '[ "$(tgn)" -eq 1 ] && grep -q "^- agent warrior_f is quarantined: mcp child unrecoverable" <<<"$(tglast)"'

# 10. GM halt.
gm_status() { # $1: state, $2: reason, $3: halted_at (ISO or "null")
  serve_jq 4002_v1_sessions_jonathan_status status-jonathan.json \
    '.interlock = {state: $s, reason: $r, speaker: "Neathius", halted_at: (if $h == "null" then null else $h end), restored: false, latch_persisted: true}' \
    --arg s "$1" --arg r "$2" --arg h "$3"
}
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 10 * 60)))"; run
check "GM halt 10 min old is quiet" '[ "$(tgn)" -eq 0 ]'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
check "GM halt 25 min old alerts at once (microseconds stripped)" '[ "$(tgn)" -eq 1 ]'
check "GM halt text names the reason, speaker and age" \
  'm=$(tglast); grep -q "^- GM halt on session jonathan (gm_halted, reason gm_contact, speaker Neathius), halted 25 min ago" <<<"$m"'
setup; gm_status awaiting_ooc_reply gm_contact "$(iso $((T0 - 40 * 60)))"; run
check "awaiting_ooc_reply counts too" '[ "$(tgn)" -eq 1 ] && grep -q "awaiting_ooc_reply" <<<"$(tglast)"'
setup; gm_status gm_halted operator_halt "$(iso $((T0 - 5 * 3600)))"; run; at 600; run
check "operator_halt is quiet" '[ "$(tgn)" -eq 0 ]'
setup; gm_status gm_halted fence_halted null; run
check "no halted_at: quiet on the first pass" '[ "$(tgn)" -eq 0 ]'
at 600; run
check "no halted_at: alerts on the second pass" '[ "$(tgn)" -eq 1 ] && grep -q "no halt time known" <<<"$(tglast)"'
setup; gm_status gm_halted gm_contact "not a date"; run; at 600; run
check "unparseable halted_at is treated as missing, not as an abort" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ]'
setup; gm_status running x null; run
check "a running interlock is quiet" '[ "$(tgn)" -eq 0 ]'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
gm_status running x null; at 600; run
check "a cleared halt resolves" '[ "$(tgn)" -eq 2 ] && grep -q "resolved" <<<"$(tglast)"'

# 11. Failing sources do not abort the pass; the other sources still speak.
for how in missing html 503; do
  setup; mkhealth "postgres FAIL refused"
  case "$how" in
    missing) rm -f "$S"/web/4002_v1_presence "$S"/web/4400_em_quiescence ;;
    html) printf '<html>bad gateway</html>\n' >"$S/body.html"
          serve 4002_v1_presence 200 "$S/body.html"; serve 4400_em_quiescence 200 "$S/body.html" ;;
    503) serve 4002_v1_presence 503 "$fx/status-livia-503.json"; serve 4400_em_quiescence 503 "$fx/status-livia-503.json" ;;
  esac
  run; at 600; run
  check "source $how: exit 0 and the stack-health problem still alerts" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ] && grep -q "^- postgres FAIL" <<<"$(tglast)"'
done
setup; serve_jq 4002_v1_presence presence.json '.presence = []'; run
check "presence of an unexpected shape does not abort" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 0 ]'
setup; rm -f "$S"/web/4002_v1_sessions_jonathan_status; run
check "a session status that does not answer does not abort" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 0 ]'

# 12. STILL after 6 h, resolved after a clean pass.
setup; mkhealth "postgres FAIL refused"; run; at 600; run
at $((600 + 6 * 3600 - 60)); run
check "no reminder before 6 h" '[ "$(tgn)" -eq 1 ]'
at $((600 + 6 * 3600)); run
check "STILL failing after 6 h" '[ "$(tgn)" -eq 2 ] && head -n 1 <<<"$(tglast)" | grep -qx "EM stack: STILL failing"'
at $((600 + 6 * 3600 + 600)); run
check "reminder clock restarted" '[ "$(tgn)" -eq 2 ]'
sethealth postgres OK fine; at $((600 + 6 * 3600 + 1200)); run
check "resolved after one clean pass" '[ "$(tgn)" -eq 3 ] && [ "$(tglast)" = "EM stack: resolved, all checks OK again." ]'
at $((600 + 6 * 3600 + 1800)); run
check "resolved is sent once" '[ "$(tgn)" -eq 3 ]'
# A changed problem set is announced as a new problem, not a reminder.
setup; mkhealth "postgres FAIL refused"; run; at 600; run
mkhealth "postgres FAIL refused" "tec-mcp DOWN gone"; at 1200; run; at 1800; run
check "a new key re-announces as problem listing both" \
  '[ "$(tgn)" -eq 2 ] && head -n 1 <<<"$(tglast)" | grep -qx "EM stack: problem" && grep -q "tec-mcp" <<<"$(tglast)" && grep -q "postgres" <<<"$(tglast)"'

# 13. Events: child_restart_failed posts once per recovery, and at most hourly per agent.
A1=2026-11-04T19:00:00Z; A2=2026-11-04T19:20:00Z; A3=2026-11-04T19:50:00Z
crf() { # $1: boot_id, $2: cause, $3: at (the newest recovery's time)
  serve_jq 4400_em_quiescence quiescence.json \
    '.boot_id = $b | .agents.warrior_f.recoveries = [{at: $a, cause: $c, detail: "boom: mcp child would not start"}]' \
    --arg b "$1" --arg c "$2" --arg a "${3:-$A1}"
}
setup; crf b1 child_restart_failed; run
check "crf: posts an event once" '[ "$(tgn)" -eq 1 ] && head -n 1 <<<"$(tglast)" | grep -qx "EM stack: event" && grep -q "agent warrior_f: child_restart_failed" <<<"$(tglast)"'
check "crf: the event carries the checkout and runbook" 'grep -q "@ $head_sha" <<<"$(tglast)"'
check "event alone leaves the standing state ok" '[ "$(st .sig)" = ok ]'
check "crf: the key names the recovery time" '[ "$(st ".events | keys[0]")" = "b1:warrior_f:crf:$A1" ]'
at 600; run; at 1200; run
check "crf: not again on later passes" '[ "$(tgn)" -eq 1 ]'
at 3600; run; at 3900; run
check "crf: the same recovery an hour later does not post again" '[ "$(tgn)" -eq 1 ]'
crf b1 child_restart_failed "$A2"; at 1800; run
check "crf: a newer recovery inside the rate window does not post" '[ "$(tgn)" -eq 1 ]'
check "crf: and is not recorded" '[ "$(st ".events | length")" -eq 1 ]'
at 3600; run
check "crf: a newer recovery after the rate window posts" '[ "$(tgn)" -eq 2 ] && grep -q "$A2" <<<"$(tglast)"'
at 3900; run
check "crf: and only once" '[ "$(tgn)" -eq 2 ]'
at 7000; run
check "seen events are kept at least 2 h" '[ "$(st ".events | length")" -eq 2 ]'
crf b1 child_restart_failed "$A3"; at 7300; run
check "a new recovery after the window posts again" '[ "$(tgn)" -eq 3 ]'
check "seen events older than 2 h are pruned" '! st ".events | keys[]" | grep -q "crf:$A1"'
check "an event never made a resolved" '! grep -q resolved <<<"$(tgall)"'
setup; crf b1 "run_limit+child_restart_failed"; run
check "crf inside a joined cause counts" '[ "$(tgn)" -eq 1 ]'
setup; serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.recoveries = [{at: "2026-11-04T19:00:00Z", cause: "run_limit", detail: "x"}]'; run
check "a single recovery stays quiet" '[ "$(tgn)" -eq 0 ]'
flap() { # $1..: the `at` of each recovery
  local a; local -a items=()
  for a in "$@"; do items+=("{\"at\":\"$a\",\"cause\":\"run_limit\",\"detail\":\"x\"}"); done
  local IFS=,
  serve_jq 4400_em_quiescence quiescence.json ".agents.warrior_f.recoveries = [${items[*]}]"
}
setup; flap "$A1" "$A1" "$A1"; run
check "3 recoveries post a flap event" '[ "$(tgn)" -eq 1 ] && grep -q "agent warrior_f: 3 recoveries in the last hour (run_limit)" <<<"$(tglast)"'
at 600; run; at 3600; run
check "the flap posts once for the same recoveries" '[ "$(tgn)" -eq 1 ]'
flap "$A1" "$A1" "$A1" "$A2"; at 1200; run
check "a flap with a newer recovery inside the rate window does not post" '[ "$(tgn)" -eq 1 ]'
at 3600; run
check "and posts after the rate window" '[ "$(tgn)" -eq 2 ]'
setup; serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.recoveries = [{at: "x", cause: "run_limit", detail: "x"}, {at: "x", cause: "run_limit", detail: "x"}, {at: "x", cause: "child_restart_failed", detail: "x"}]'; run
check "child_restart_failed ones do not count toward a flap" '[ "$(tgn)" -eq 1 ] && ! grep -q "recoveries in the last hour" <<<"$(tglast)"'
setup; crf b1 child_restart_failed; run
serve_jq 4400_em_quiescence quiescence.json '.boot_id = "b2"'; at 600; run
check "a new boot_id (empty recoveries) replays nothing" '[ "$(tgn)" -eq 1 ]'

# 13b. A source that fails for one pass neither drops a standing key nor resolves it.
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
check "GM halt announced" '[ "$(tgn)" -eq 1 ]'
rm -f "$S/web/4002_v1_presence"; at 600; run
check "presence timeout during a standing GM halt: no resolved, no new message" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ] && [ "$(st ".keys | join(\",\")")" = gm_halt:jonathan ]'
at 1200; run
serve 4002_v1_presence 200 "$fx/presence.json"; at 1800; run
check "presence back: still quiet (same set, no reminder yet)" '[ "$(tgn)" -eq 1 ]'
rm -f "$S/web/4002_v1_sessions_jonathan_status"; at 2400; run
check "status timeout during a standing GM halt: no resolved" '[ "$(tgn)" -eq 1 ] && [ "$(st ".keys | length")" -eq 1 ]'
gm_status running x null; at 3000; run
check "the halt really clearing resolves" '[ "$(tgn)" -eq 2 ] && [ "$(tglast)" = "EM stack: resolved, all checks OK again." ]'

setup; mkhealth "postgres FAIL refused"; run; at 600; run
: >"$S/health"; at 1200; run
check "no SUMMARY while fail:postgres stands: not resolved, first blind pass quiet" '[ "$(tgn)" -eq 1 ] && [ "$(st .keys[0])" = fail:postgres ]'
at 1800; run
check "monitor:blind joins, and fail:postgres is carried with its text" \
  '[ "$(tgn)" -eq 2 ] && m=$(tglast) && grep -q "^- postgres FAIL: refused" <<<"$m" && grep -q "printed no SUMMARY" <<<"$m" && ! grep -q resolved <<<"$m"'
sethealth postgres OK fine; at 2400; run
check "stack-health answering again resolves everything" '[ "$(tgn)" -eq 3 ] && [ "$(tglast)" = "EM stack: resolved, all checks OK again." ]'

setup; mkhealth "postgres FAIL refused"; run; at 600; run
sethealth postgres UNKNOWN "psql unresolvable"; at 1200; run
check "a standing fail:<check> read UNKNOWN is carried, not resolved" '[ "$(tgn)" -eq 1 ] && [ "$(st .keys[0])" = fail:postgres ]'

setup; mkhealth "postgres FAIL refused"; run
: >"$S/health"; at 600; run
mkhealth "postgres FAIL refused"; at 1200; run
check "a debounce count survives a pass whose source failed" '[ "$(tgn)" -eq 1 ] && grep -q "^- postgres FAIL" <<<"$(tglast)"'

setup
serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "mcp child unrecoverable"'; run; at 600; run
rm -f "$S/web/4400_em_quiescence"; at 1200; run; at 1800; run
check "quiescence down while a quarantine stands: no resolved" '[ "$(tgn)" -eq 1 ] && [ "$(st .keys[0])" = quarantine:warrior_f ]'
serve 4400_em_quiescence 200 "$fx/quiescence.json"; at 2400; run
check "quiescence back and the quarantine gone: resolved" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'

setup
serve_jq 4002_v1_presence presence.json '.presence.livia.last_close = {at: "2026-11-04T19:00:00Z", by: null, cause: "server", code: 1006, idle: false}'
run; at 600; run
serve 4002_v1_presence 503 "$fx/status-livia-503.json"; at 1200; run
check "presence down while a presence key stands: no resolved" '[ "$(tgn)" -eq 1 ] && [ "$(st .keys[0])" = presence:livia ]'

# A source answering "all clear" does clear its keys (carry-forward is only for silence).
setup; mkhealth "postgres FAIL refused"; run; at 600; run
sethealth postgres OK fine; at 1200; run
check "an answered check clears its key" '[ "$(tgn)" -eq 2 ] && [ "$(st ".keys | length")" -eq 0 ]'

# 13c. A source that is GONE (answered "not here") clears its keys; only a FAILED
# source is carried, and carrying is capped at 3 passes.
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
serve 4002_v1_sessions_jonathan_status 503 "$fx/status-livia-503.json"; at 600; run
check "A: session stopped (status 503 session_not_found) clears the GM halt" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)" && [ "$(st ".keys | length")" -eq 0 ]'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
rm -f "$S/web/4002_v1_sessions_jonathan_status"; touch "$S/web/4002_v1_sessions_jonathan_status.refused"; at 600; run
check "status refused (gone) clears the GM halt" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
serve 4002_v1_sessions_jonathan_status 404 "$fx/status-livia-503.json"; at 600; run
check "status 404 (gone) clears the GM halt" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
serve 4002_v1_sessions_jonathan_status 502 "$fx/status-livia-503.json"; at 600; run
check "status 502 (failed, not session_not_found) is carried" '[ "$(tgn)" -eq 1 ] && [ "$(st ".keys | length")" -eq 1 ]'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
serve 4002_v1_sessions_jonathan_status 200 <(echo '<html>'); at 600; run
check "status 200 that does not parse is carried" '[ "$(tgn)" -eq 1 ] && [ "$(st ".keys | length")" -eq 1 ]'
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
rm -f "$S/web/4002_v1_presence"; touch "$S/web/4002_v1_presence.refused"; at 600; run
check "presence refused (gone) drops the GM halt" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'

setup
serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "mcp child unrecoverable"'; run; at 600; run
rm -f "$S/web/4400_em_quiescence"; touch "$S/web/4400_em_quiescence.refused"; at 1200; run
check "B: AgentOS stopped (:4400 refused) clears the quarantine" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'
setup
serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "mcp child unrecoverable"'; run; at 600; run
serve 4400_em_quiescence 404 "$fx/status-livia-503.json"; at 1200; run
check "quiescence 404 (gone) clears the quarantine" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'

setup; mkhealth "foo FAIL broke"; run; at 600; run
check "C: fail:foo announced" '[ "$(tgn)" -eq 1 ]'
sethealth postgres OK fine; at 1200; run
check "C: a complete run (SUMMARY) with no foo line clears fail:foo" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'

# The cap: a source timing out 4 passes in a row resolves on the 4th.
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
rm -f "$S/web/4002_v1_presence"
at 600; run
check "cap: carried on timeout 1" '[ "$(tgn)" -eq 1 ] && [ "$(st ".carried[\"gm_halt:jonathan\"]")" -eq 1 ]'
at 1200; run; at 1800; run
check "cap: carried on timeouts 2 and 3" '[ "$(tgn)" -eq 1 ] && [ "$(st ".carried[\"gm_halt:jonathan\"]")" -eq 3 ]'
at 2400; run
check "cap: resolved on timeout 4" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)" && [ "$(st ".carried | length")" -eq 0 ]'
# ... and observing the key directly resets the count.
setup; gm_status gm_halted gm_contact "$(iso $((T0 - 25 * 60)))"; run
cp "$S/web/4002_v1_presence" "$S/presence.keep"; rm -f "$S/web/4002_v1_presence"
at 600; run; at 1200; run; at 1800; run
cp "$S/presence.keep" "$S/web/4002_v1_presence"; at 2400; run
check "reset: observed directly, the carry count clears" '[ "$(st ".carried | length")" -eq 0 ] && [ "$(tgn)" -eq 1 ]'
rm -f "$S/web/4002_v1_presence"; at 3000; run; at 3600; run; at 4200; run
check "reset: three more timeouts are carried again" '[ "$(tgn)" -eq 1 ]'
at 4800; run
check "reset: and the 4th resolves" '[ "$(tgn)" -eq 2 ]'
# Pending counts obey the same cap.
setup; serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "x"'; run
cp "$S/web/4400_em_quiescence" "$S/q.keep"; rm -f "$S/web/4400_em_quiescence"
at 600; run; at 1200; run; at 1800; run
cp "$S/q.keep" "$S/web/4400_em_quiescence"; at 2400; run
check "debounce count carried through 3 failed passes: alerts when seen again" '[ "$(tgn)" -eq 1 ]'
setup; serve_jq 4400_em_quiescence quiescence.json '.agents.warrior_f.quarantined = "x"'; run
cp "$S/web/4400_em_quiescence" "$S/q.keep"; rm -f "$S/web/4400_em_quiescence"
at 600; run; at 1200; run; at 1800; run; at 2400; run
cp "$S/q.keep" "$S/web/4400_em_quiescence"; at 3000; run
check "debounce count past the cap is dropped: seen again counts as 1" '[ "$(tgn)" -eq 0 ]'

# session_not_started: stack-health says the session it probed never started.
for m in sim sim-reactive reactive-live autonomous-live; do
  setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; echo "$m" >"$S/mode"; run
  check "mode $m: first pass quiet" '[ "$(tgn)" -eq 0 ]'
  at 600; run
  check "mode $m: session never started alerts on the second pass, naming session and mode" \
    '[ "$(tgn)" -eq 1 ] && grep -q "^- session livia was never started .* in mode $m," <<<"$(tglast)"'
done
setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; echo manual-live >"$S/mode"; run; at 600; run
check "mode manual-live: a deferred session is normal, quiet" '[ "$(tgn)" -eq 0 ]'
setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; : >"$S/mode"; run; at 600; run
check "unknown mode: also alerts" '[ "$(tgn)" -eq 1 ] && grep -q "in mode unknown" <<<"$(tglast)"'
setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; echo sim >"$S/mode"; run; at 600; run
cat "$fx/stack-health.txt" >"$S/health"; at 1200; run
check "session_not_started clears when the session is up" '[ "$(tgn)" -eq 2 ] && grep -q resolved <<<"$(tglast)"'
setup; cat "$fx/stack-health-deferred.txt" >"$S/health"; echo sim >"$S/mode"; run; at 600; run
: >"$S/health"; at 1200; run
check "session_not_started is carried when stack-health printed no SUMMARY" '[ "$(tgn)" -eq 1 ] && [ "$(st ".keys | index(\"session_not_started\") != null")" = true ]'

# 14. One Telegram message per pass: events ride with the standing problems.
setup; mkhealth "postgres FAIL refused"; run
crf b1 child_restart_failed; at 600; run
check "problem and event leave in ONE message" '[ "$(tgn)" -eq 1 ] && grep -q "^EM stack: problem" <<<"$(tglast)" && grep -q "^Events:" <<<"$(tglast)"'
# ... and a failed send retried next pass cannot duplicate part of it.
setup; mkhealth "postgres FAIL refused"; run
crf b1 child_restart_failed; touch "$S/tg_down"; at 600; run
check "Telegram failure: exit non-zero" '[ "$rc" -ne 0 ]'
check "Telegram failure: records nothing" '[ "$(tgn)" -eq 0 ] && [ "$(st ".events | length")" -eq 0 ] && [ "$(st .sig)" = ok ]'
rm "$S/tg_down"; at 1200; run
check "after the failure the next pass delivers it all in one message" \
  '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ] && grep -q "^- postgres FAIL" <<<"$(tglast)" && grep -q "child_restart_failed" <<<"$(tglast)"'
at 1800; run
check "and nothing is sent twice" '[ "$(tgn)" -eq 1 ]'
setup; mkhealth "postgres FAIL refused"; run; touch "$S/tg_down"; at 600; run
check "a failed first announcement is not latched" '[ "$rc" -ne 0 ] && [ "$(st .sig)" = ok ]'
rm "$S/tg_down"; at 1200; run
check "a failed announcement is retried" '[ "$(tgn)" -eq 1 ]'

# 15. Truncation: Telegram rejects messages over 4096 characters.
setup
{ grep -v '^SUMMARY' "$fx/stack-health.txt"
  for i in $(seq 1 60); do printf '  %-12s %-8s %s\n' "check$i" FAIL "$(printf 'x%.0s' $(seq 1 280))"; done
  echo "SUMMARY: FAIL — x"; } >"$S/health"
run; at 600; run
check "long message is truncated under 4096 and says so" '[ "$(tgn)" -eq 1 ] && [ "$(wc -m <"$S/tg/0")" -lt 4096 ] && grep -q "(truncated" "$S/tg/0" && grep -q "docs/runbooks/stack-health.md" "$S/tg/0"'

# 16. Dry run: raw keys before debounce and the message; no send, no state, no ping.
setup; mkhealth "postgres FAIL refused" "map_fence UNKNOWN psql unresolvable"
export EM_STACK_MONITOR_DRY_RUN=1
run
check "dry run: raw key set shows undebounced keys" 'grep -qx "\[dry-run\] raw keys: fail:postgres monitor:blind" "$S/out"'
check "dry run: sends nothing and keeps no state" '[ "$(tgn)" -eq 0 ] && [ ! -e "$STATE_DIRECTORY/state.json" ]'
setup; export EM_STACK_MONITOR_DRY_RUN=1; run
check "dry run on a healthy stack: empty key set" 'grep -qx "\[dry-run\] raw keys: (none)" "$S/out"'
setup; touch "$S/nostack"; export EM_STACK_MONITOR_DRY_RUN=1; run
check "dry run without a stack says so" 'grep -q "stack: none" "$S/out" && [ "$rc" -eq 0 ]'
unset EM_STACK_MONITOR_DRY_RUN

# 17. Corrupt state, or valid JSON of the wrong shape, is normalized field by field.
setup; echo 'not json' >"$STATE_DIRECTORY/state.json"; mkhealth "postgres FAIL refused"; run
check "corrupt state does not abort" '[ "$rc" -eq 0 ] && [ "$(pend fail:postgres)" -eq 1 ]'
for bad in '{"keys":"x"}' '{"pending":[1]}' '[1,2]' '{"sig":5,"sent_at":"soon","texts":[],"events":{"a":"b"},"keys":[1]}' '{"pending":{"fail:postgres":"many"}}'; do
  setup; echo "$bad" >"$STATE_DIRECTORY/state.json"; mkhealth "postgres FAIL refused"; run; at 600; run
  check "wrong-shape state $bad does not kill a pass" '[ "$rc" -eq 0 ] && [ "$(tgn)" -eq 1 ] && [ "$(st .sig)" != "" ]'
done

# 18. Secrets and the dead-man's ping, through a fake curl.
prun() { PATH="$S/bin:$PATH" run; }
fake_curl() { # records argv and stdin; never touches the network
  cat >"$S/bin/curl" <<EOF
#!$bash_bin
echo "\$*" >>"$S/curl.args"
cat >>"$S/curl.in"
EOF
  chmod +x "$S/bin/curl"
}
setup; fake_curl; unset EM_STACK_TG_CMD
echo "https://hc.example.invalid/ping/abc" >"$CREDENTIALS_DIRECTORY/hc_ping_url"
mkhealth "postgres FAIL refused"; prun; at 600; prun
check "default Telegram path: token and chat id reach curl on stdin only" \
  'grep -q "api.telegram.org/botbot/sendMessage" "$S/curl.in" && grep -q "chat_id=1" "$S/curl.in" && ! grep -q "botbot" "$S/curl.args" && ! grep -q "chat_id" "$S/curl.args" && ! grep -q "api.telegram" "$S/curl.args"'
check "default Telegram path: the message text goes out as form data" 'grep -q "text=EM stack: problem" "$S/curl.args"'
check "dead-man ping: success after a delivering pass, URL on stdin" 'grep -q "hc.example.invalid/ping/abc\"" "$S/curl.in" && ! grep -q "hc.example.invalid" "$S/curl.args"'
setup; fake_curl; echo "https://hc.example.invalid/ping/abc" >"$CREDENTIALS_DIRECTORY/hc_ping_url"
touch "$S/tg_down"; mkhealth "postgres FAIL refused"; prun; at 600; prun
check "dead-man ping: /fail when delivery fails" '[ "$rc" -ne 0 ] && grep -q "ping/abc/fail" "$S/curl.in" && [ "$(grep -c "ping/abc/fail" "$S/curl.in")" -eq 1 ]'
setup; fake_curl; prun
check "no hc_ping_url credential: no ping at all" '[ ! -e "$S/curl.args" ]'

[ "$fail" -eq 0 ] || { echo "FAILED $fail"; exit 1; }
echo "ALL PASS ($pass assertions)"
