# shellcheck shell=bash
# em-stack monitor: one pass. Wrapped by writeShellApplication in
# em-stack-monitor.nix, which supplies PATH and `set -euo pipefail`.
# Spec: docs/plans/2026-11-04-em-stack-monitor.md (read it for the rules; this
# header only says where each one lives).
#
# Credentials come from systemd LoadCredential ($CREDENTIALS_DIRECTORY):
#   slack_webhook   the em-alerts app's incoming webhook (#em-alerts; em-slack.sh)
#   hc_ping_url     healthchecks.io ping URL; optional, the dead-man's ping is
#                   sent only when this file exists (hcEnabled in the .nix)
# Secrets (the webhook URL, the ping URL) reach curl only through a
# config on stdin (`-K -`, written by the printf builtin), never on a command
# line, where any host user could read them from /proc.
#
# Configuration (environment, set by the unit): EM_STACK_REPO (the main EM
# checkout, where bin/stack-health runs), EM_STACK_RUNBOOK, EM_STACK_REMIND_H,
# EM_STACK_GM_MIN, STATE_DIRECTORY, PIGEON_SLACK_NOTIFY_OWNER and
# EM_SLACK_OWNER_ID (em-slack.sh).
# EM_STACK_MONITOR_DRY_RUN=1 prints the raw
# key set and the message instead of sending and pinging, and keeps no state.
#
# Test hooks (everything outside this script is injectable; each is the path of
# an executable, or unset for the real thing):
#   EM_STACK_FETCH_CMD   $1 = URL; prints the HTTP code on line 1, the body
#                        after it; non-zero (curl's exit code: 7 = refused,
#                        28 = timeout) when nothing answered.
#   EM_STACK_GATE_CMD    exit 0 when a stack (a BEAM on 127.0.0.1:4002) is up.
#   EM_STACK_MODE_CMD    prints the BEAM's EM_MODE (empty when unknown).
#   EM_STACK_HEALTH_CMD  prints bin/stack-health's output (exit code ignored).
#   EM_STACK_QUOTA_CMD   prints teamclaude's quota state (JSON); exit 3 when
#                        there is none (no teamclaude here), other non-zero
#                        when it could not be read.
#   EM_STACK_SLACK_CMD   reads the Slack message on stdin; non-zero = failed.
#   EM_STACK_NOW         epoch seconds.
#
# Source tolerance. Under errexit/nounset/pipefail every source is graded on
# its own: a fetch that fails or a body that does not parse means "no data from
# that source" (for stack-health, the key monitor:blind), never an aborted
# pass. So every command that may fail sits in an `if` or has `|| true`.
#
# Carry-forward. A source that FAILS to answer for a pass (timeout, reset, a 5xx
# other than session_not_found, a 200 that does not parse) must neither drop a
# standing key nor produce a false "resolved". A source that answers "not here"
# (connection refused, 404 and, outside a live mode, a refused :4400; session_not_found, a complete stack-health run with
# no line for the check) is GONE: its keys clear like any absent key. A key that
# was active last pass, is missing now, and whose source failed is carried
# forward with its stored text:
#   fail:<check>, session_not_started
#                  carried when stack-health printed no SUMMARY line, or that
#                  check (api, for session_not_started) reads UNKNOWN
#   monitor:blind  never carried (it is derived from the stack-health output)
#   presence:<sid>, idleout:<sid>
#                  carried while the presence fetch failed
#   gm_halt:<sid>  carried while the presence fetch failed, or this session's
#                  status fetch failed (a 503 session_not_found is an answer)
#   quota:pool     carried while the quota state could not be read
#   quarantine:*   carried while the quiescence fetch failed (in a live mode, or
#                  an unknown one, a refused :4400 counts as failed: AgentOS is
#                  meant to be up, and fail:agentos takes over)
# There is no global degraded flag: quiescence never answers in sim modes.
# Carrying is capped at 3 consecutive passes per key (state `carried`), reset
# whenever the key is observed directly; the 4th failed pass lets it resolve.
# Pending (debounce) counts of such keys are carried under the same cap.
#
# State ($STATE_DIRECTORY/state.json), written only after a pass that delivered
# everything it owed. It is normalized at load, field by field, so valid JSON
# of the wrong shape (or corrupt JSON) falls back to defaults, never kills a pass:
#   sig      what was last announced: "" nothing, "ok", or a hash of the
#            sorted active key set (numbers and times never reach a key)
#   keys     the active keys behind sig, so a "stopped" line can name them
#   texts    {key: text} of the active keys, for carry-forward
#   sent_at  when the standing message last went out (for the 6 h reminder)
#   pending  {key: consecutive passes seen} for the debounced keys
#   carried  {key: consecutive passes carried forward}
#   events   {event key: time sent}, pruned after 2 h (never under the 1 h
#            rate window)
#
# Heartbeat contract (as em-ci-monitor). The healthchecks.io check measures the
# MONITOR: a pass that observed everything and delivered every Slack message
# it owed pings success (a reported problem still earns a success ping). A pass
# that could not deliver, or exits non-zero for any other reason, pings /fail.
# A pass that never runs sends nothing; healthchecks.io reports it down.

set -E
: "${EM_STACK_REPO:=/home/dev/projects/eternal-machinery}"
: "${EM_STACK_RUNBOOK:=eternal-machinery docs/runbooks/stack-health.md}"
cred() { cat "${CREDENTIALS_DIRECTORY:?}/$1"; }
dry() { [ "${EM_STACK_MONITOR_DRY_RUN:-0}" = 1 ]; }
failed_pinged=0

hc_ping() { # $1: "" for success, "/fail" for failure; $2: body
  if dry; then echo "[dry-run] hc ping${1:-/success}: $2"; return 0; fi
  [ -f "${CREDENTIALS_DIRECTORY:-/nonexistent}/hc_ping_url" ] || return 0
  printf 'url = "%s%s"\n' "$(cred hc_ping_url)" "$1" |
    curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$2" -K - || true
}

# shellcheck disable=SC2329  # invoked via the EXIT trap
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$failed_pinged" = 0 ]; then
    hc_ping /fail "em-stack monitor exited $rc; see journalctl -u em-stack-monitor on devbox"
  fi
}
trap on_exit EXIT

send() { # $1: text. Returns non-zero when delivery failed. slack_send: em-slack.sh.
  if dry; then printf '[dry-run] slack:\n%s\n' "$1"; return 0; fi
  if [ -n "${EM_STACK_SLACK_CMD:-}" ]; then
    printf '%s' "$1" | "$EM_STACK_SLACK_CMD"
    return
  fi
  slack_send "$1"
}

# --- Sources (default implementations; tests replace them) -------------------------
fetch() { # $1: URL. HTTP code on line 1, body after it. Non-zero: no answer.
  if [ -n "${EM_STACK_FETCH_CMD:-}" ]; then "$EM_STACK_FETCH_CMD" "$1"; return; fi
  local raw
  raw=$(curl -sS -m 10 -w '\n%{http_code}' "$1") || return $?
  printf '%s\n%s\n' "${raw##*$'\n'}" "${raw%$'\n'*}"
}

stack_up() { # exit 0 when something serves 127.0.0.1:4002
  if [ -n "${EM_STACK_GATE_CMD:-}" ]; then "$EM_STACK_GATE_CMD"; return; fi
  (exec 3<>/dev/tcp/127.0.0.1/4002) 2>/dev/null
}

stack_mode() { # prints EM_MODE of the BEAM on :4002, empty when unknown
  if [ -n "${EM_STACK_MODE_CMD:-}" ]; then "$EM_STACK_MODE_CMD"; return; fi
  local pid
  pid=$(ss -Htlnp 'sport = :4002' | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2) || true
  [ -n "$pid" ] || return 0
  tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^EM_MODE=//p' | head -n 1 || true
}

# teamclaude's quota state (eternal-machinery a8gw1). Only the .state.json file:
# never ~/.config/teamclaude.json, which holds the accounts' credentials.
quota_state() { # prints the quota state JSON; exit 3: no state here; other non-zero: unreadable
  if [ -n "${EM_STACK_QUOTA_CMD:-}" ]; then "$EM_STACK_QUOTA_CMD"; return; fi
  local f=${EM_STACK_QUOTA_FILE:-/home/dev/.config/teamclaude.state.json}
  [ -e "$f" ] || return 3
  cat "$f"
}

stack_health() { # prints bin/stack-health output; exit code is ignored by the caller
  if [ -n "${EM_STACK_HEALTH_CMD:-}" ]; then "$EM_STACK_HEALTH_CMD" 2>&1; return; fi
  cd "$EM_STACK_REPO" && timeout 200 ./bin/stack-health 2>&1
}

# get_json URL: leaves the HTTP code in GOT_CODE, the body in GOT_BODY and the
# kind of outcome in GOT_KIND: "answered" (valid JSON, any code; the caller
# judges the code), "gone" (curl rc 7, connection refused, or HTTP 404: the
# source says "not here") or "failed" (any other fetch failure, or a body that
# is not JSON). Returns non-zero unless "answered".
GOT_CODE=""; GOT_BODY=""; GOT_KIND=failed
get_json() {
  local raw rc=0
  GOT_CODE=""; GOT_BODY=""; GOT_KIND=failed
  raw=$(fetch "$1") || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 7 ] || GOT_KIND=gone
    return 1
  fi
  GOT_CODE=${raw%%$'\n'*}
  case "$raw" in *$'\n'*) GOT_BODY=${raw#*$'\n'} ;; *) GOT_BODY="" ;; esac
  if [ "$GOT_CODE" = 404 ]; then GOT_KIND=gone; return 1; fi
  jq -e . >/dev/null 2>&1 <<<"$GOT_BODY" || return 1
  GOT_KIND=answered
}

# --- Collect ------------------------------------------------------------------------
# text[key] is the line shown for a key; cls[key] is "deb" (debounced: must be
# seen on 2 passes in a row) or "imm" (alerts at once).
declare -A text=() cls=()
add() { text[$1]=$2; cls[$1]=$3; } # $1: stable key, $2: text, $3: deb|imm

now=${EM_STACK_NOW:-$(date +%s)}
state_file="${STATE_DIRECTORY:?}/state.json"
empty_state='{"sig":"","keys":[],"texts":{},"sent_at":0,"pending":{},"events":{},"carried":{}}'
state=$empty_state
if [ -f "$state_file" ] && st=$(cat "$state_file"); then
  state=$(jq -c '
    (if type == "object" then . else {} end) as $s
    | def nums: if type == "object" then with_entries(select((.value | type == "number") and .value >= 0) | .value |= floor) else {} end;
      {sig: (if ($s.sig | type) == "string" then $s.sig else "" end),
       keys: (if ($s.keys | type) == "array" then [$s.keys[] | select(type == "string")] else [] end),
       texts: (if ($s.texts | type) == "object" then ($s.texts | with_entries(select(.value | type == "string"))) else {} end),
       sent_at: (if ($s.sent_at | type) == "number" then ($s.sent_at | floor) else 0 end),
       pending: ($s.pending | nums),
       events: ($s.events | nums),
       carried: ($s.carried | nums)}' <<<"$st" 2>/dev/null) || state=$empty_state
  [ -n "$state" ] || state=$empty_state
fi
prev_sig=$(jq -r '.sig' <<<"$state")
prev_sent=$(jq -r '.sent_at' <<<"$state")
case "$prev_sent" in ''|*[!0-9]*) prev_sent=0 ;; esac
prev_keys_txt=$(jq -r '.keys | join(", ")' <<<"$state")

# Seen events, pruned after 2 h.
events_seen=$(jq -c --argjson now "$now" \
  '.events | with_entries(select(.value > ($now - 7200)))' <<<"$state")

# Which sources failed this pass (for carry-forward); see the header.
declare -A unknown_set=() sidset=() status_state=() prev_carried=() carried_n=()
have_summary=0
presence_state=failed; quies_state=failed; quota_kind=failed
source_failed() { # $1: key. 0 when the source behind that key FAILED this pass
  local sid chk
  case "$1" in
    fail:*|session_not_started)
      chk=${1#fail:}; [ "$1" != session_not_started ] || chk=api
      [ "$have_summary" = 0 ] || [ -n "${unknown_set[$chk]+x}" ] ;;
    presence:*|idleout:*) [ "$presence_state" = failed ] ;;
    gm_halt:*)
      sid=${1#gm_halt:}
      [ "$presence_state" = failed ] || { [ -n "${sidset[$sid]+x}" ] && [ "${status_state[$sid]:-}" = failed ]; } ;;
    quarantine:*) [ "$quies_state" = failed ] ;;
    quota:*) [ "$quota_kind" = failed ] ;;
    *) return 1 ;;
  esac
}
carry_step() { # $1: key. 0 if it may be carried one more pass (and counts it)
  local n
  [ -z "${carried_n[$1]+x}" ] || return 0   # already counted this pass
  n=$(( ${prev_carried[$1]:-0} + 1 ))
  [ "$n" -le 3 ] || return 1
  carried_n[$1]=$n
}
while IFS=$'\t' read -r k n; do
  [ -z "$k" ] || prev_carried["$k"]=$n
done < <(jq -r '.carried | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$state")

declare -a new_event_keys=() new_event_texts=()
nostack=0
mode=""

if ! stack_up; then
  nostack=1
else
  mode=$(stack_mode) || mode=""
  live=1
  # Outside a *-live mode `agentos DOWN` is expected. An unknown mode does not
  # suppress anything (a wrongly quiet monitor is worse than a noisy one).
  case "$mode" in ""|*-live) ;; *) live=0 ;; esac

  # --- bin/stack-health -------------------------------------------------------------
  health_out=$(stack_health) || true
  unknown_checks=()
  session_probe=""
  # `api WARN session X not started (HTTP 503 session_not_found ...`: the session
  # stack-health probed has not started (deferred boot, EM #1173).
  re_api='^  api[[:space:]]+WARN[[:space:]]+session[[:space:]]+([^[:space:]]+)[[:space:]]+not started \(HTTP 503 session_not_found'
  re_bad='^  ([^[:space:]]+)[[:space:]]+(FAIL|DOWN|DEAD_MANAGER)([[:space:]]|$)(.*)$'
  re_unk='^  ([^[:space:]]+)[[:space:]]+UNKNOWN([[:space:]]|$)'
  while IFS= read -r line; do
    case "$line" in SUMMARY:*) have_summary=1 ;; esac
    if [[ $line =~ $re_api ]]; then session_probe=${BASH_REMATCH[1]}; fi
    if [[ $line =~ $re_bad ]]; then
      chk=${BASH_REMATCH[1]}
      if [ "$chk" = agentos ] && [ "$live" = 0 ]; then continue; fi
      detail=${BASH_REMATCH[4]}
      detail=${detail#"${detail%%[![:space:]]*}"}  # the verdict column's padding
      add "fail:$chk" "$chk ${BASH_REMATCH[2]}: ${detail:0:300}" deb
    elif [[ $line =~ $re_unk ]]; then
      unknown_checks+=("${BASH_REMATCH[1]}")
      unknown_set["${BASH_REMATCH[1]}"]=1
    fi
  done <<<"$health_out"
  # manual-live starts the session lazily, so this is normal there; every other
  # known mode starts it eagerly. An unknown mode errs noisy (as agentos does).
  if [ -n "$session_probe" ] && [ "$mode" != manual-live ]; then
    add "session_not_started" "session $session_probe was never started (stack-health: HTTP 503 session_not_found) in mode ${mode:-unknown}, which starts it eagerly" deb
  fi
  if [ "$have_summary" = 0 ]; then
    add "monitor:blind" "bin/stack-health printed no SUMMARY line (it timed out or crashed): the monitor cannot see the stack" deb
  elif [ "${#unknown_checks[@]}" -gt 0 ]; then
    add "monitor:blind" "bin/stack-health could not check: ${unknown_checks[*]}; the monitor cannot see those" deb
  fi

  # --- Model quota (teamclaude, a8gw1) ----------------------------------------------
  # Every account spent means no agent (character, coordinator, runner) can call
  # the model: the 1122a afternoon, when all five sat at 98% weekly and nothing
  # said so for 6 h. An account is spent while a window's utilization is at
  # EM_STACK_QUOTA_FULL or more and that window's reset is still ahead (a reset
  # already past means the number is stale and the account is usable again).
  # EM_STACK_QUOTA_FULL is teamclaude's own switch threshold (0.98 unless
  # someone runs `teamclaude threshold`): keep the two equal. Only Anthropic
  # accounts count; the state file lists other providers too. Debounced like a
  # check, so it alerts after about 20 minutes; the standing message repeats
  # every EM_STACK_REMIND_H and says "resolved" when it clears. It is read only
  # while a stack is up, as everything here is.
  quota_spent=0
  qrc=0; q=$(quota_state 2>/dev/null) || qrc=$?
  if [ "$qrc" -eq 3 ]; then
    quota_kind=gone
  elif [ "$qrc" -eq 0 ] && jq -e '.quota | type == "array"' >/dev/null 2>&1 <<<"$q"; then
    quota_kind=answered
    quota_line=$(jq -r --argjson now "$now" --argjson full "${EM_STACK_QUOTA_FULL:-0.98}" '
      def spent($u; $r): ($u | type) == "number" and $u >= $full and ($r | type) == "number" and $r > ($now * 1000);
      [ .quota[] | select(type == "object" and (.provider // "anthropic") == "anthropic") | (.quota // {}) as $q
        | [ (if spent($q.unified7d; $q.unified7dReset) then $q.unified7dReset else empty end),
            (if spent($q.unified5h; $q.unified5hReset) then $q.unified5hReset else empty end) ] as $r
        | {name: ((.name // "?") | tostring | split("@")[0]), spent: ($r | length > 0), back: ($r | max)} ] as $a
      | select(($a | length) > 0 and all($a[]; .spent))
      | ($a | min_by(.back)) as $next
      | "model quota is spent on all \($a | length) teamclaude accounts, so no agent can act;"
        + " the first back is \($next.name) at \($next.back / 1000 | floor | strftime("%Y-%m-%dT%H:%MZ"))"
      ' <<<"$q" 2>/dev/null) || quota_line=""
    if [ -n "$quota_line" ]; then
      quota_spent=1
      add "quota:pool" "$quota_line" deb
    fi
  fi

  # --- Presence ---------------------------------------------------------------------
  sids=()
  if get_json "http://127.0.0.1:4002/v1/presence" && [ "$GOT_CODE" = 200 ] &&
     jq -e '.presence | type == "object"' >/dev/null 2>&1 <<<"$GOT_BODY"; then
    presence_state=answered
    while IFS= read -r sid; do
      [ -z "$sid" ] || { sids+=("$sid"); sidset["$sid"]=1; }
    done < <(jq -r '.presence | keys[] | select(test("^[A-Za-z0-9_-]+$"))' <<<"$GOT_BODY" 2>/dev/null || true)
    # last_close.cause "server" with wants_out null (it is an object {why, at}
    # when the close was wanted) means the server dropped us unasked.
    # The game's idle close (last_close.idle true, eternal-machinery kdubj.115)
    # is the game enforcing its idle rule, not a fault of the stack. With no
    # agent playing (agent_driven false) nobody was typing: one event, told
    # once and only while the close is under an hour old. With an agent playing
    # (a8gw1) it stands as idleout:<sid> until the session is back, because
    # nothing logs the character back in: until the agent can act, a character
    # in the world would stand there unattended and be closed again, so the
    # restart is a person's or the runner's. Its text says when the agent last
    # acted (the close less the game's idle minutes) and the likely cause:
    # every model account spent (quota:pool above), or an agent that stopped
    # while the stack stayed up. It is an agent key, so it does not read as a
    # stack problem (the header below). A BEAM older than agent_driven leaves
    # the field out, and that reads as a problem as before.
    while IFS=$'\t' read -r key line; do
      [ -n "$key" ] || continue
      if jq -e --arg k "$key" 'has($k)' >/dev/null <<<"$events_seen"; then continue; fi
      new_event_keys+=("$key"); new_event_texts+=("$line")
    done < <(jq -r --argjson now "$now" '
      .presence | to_entries[]
      | select(.value.link == "offline" and .value.last_close.cause == "server" and .value.wants_out == null
               and .value.last_close.idle == true and .value.agent_driven == false)
      | select(((.value.last_close.at // "") | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch 0) > ($now - 3600))
      | ["idle:" + .key + ":" + (.value.last_close.at | tostring),
         "session \(.key): the game closed an idle link at \(.value.last_close.at)"
         + (if .value.last_close.idle_minutes then " after \(.value.last_close.idle_minutes) min without input" else " after its idle notice" end)
         + "; no agent plays this account, so nothing is wrong"]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
    while IFS=$'\t' read -r key line; do
      [ -z "$key" ] || add "$key" "$line" deb
    done < <(jq -r --argjson quota "$quota_spent" '
      .presence | to_entries[]
      | select(.value.link == "offline" and .value.last_close.cause == "server" and .value.wants_out == null
               and .value.last_close.idle == true and .value.agent_driven == true)
      | ((.value.last_close.at // "") | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) as $t
      | .value.last_close.idle_minutes as $m
      | ["idleout:" + .key,
         "session \(.key): the game logged out the idle character at \(.value.last_close.at // "?")"
         + (if ($m | type) == "number" and $t != null then
              ", \($m) min after its agent last acted (\($t - $m * 60 | strftime("%Y-%m-%dT%H:%MZ")))"
            else ", after its idle notice" end)
         + (if $quota == 1 then
              "; model quota is spent on every account, so the agent likely could not act."
              + " Start the session again once quota is back"
            else
              "; model quota is not spent now, so start the session again"
              + " (if the agent stopped on its own, look at agentos and the runner on duty)"
            end)]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
    while IFS=$'\t' read -r key line; do
      [ -z "$key" ] || add "$key" "$line" deb
    done < <(jq -r '
      .presence | to_entries[]
      | select(.value.link == "offline" and .value.last_close.cause == "server" and .value.wants_out == null)
      | select((.value.last_close.idle == true and (.value.agent_driven | type) == "boolean") | not)
      | ["presence:" + .key,
         "session \(.key) is offline: the server closed the link at \(.value.last_close.at // "?") (code \(.value.last_close.code // "?"))"
         + (if .value.last_close.idle == true then ", while idle (TEC logs out an idle character)" else "" end)
         + ", and nobody asked for it"]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
  fi

  # Only a refusal or a 404 says the endpoint is gone; anything else failed.
  [ "$presence_state" = answered ] || [ "$GOT_KIND" != gone ] || presence_state=gone

  # --- GM halt, per session ---------------------------------------------------------
  for sid in "${sids[@]}"; do
    status_state["$sid"]=failed
    if get_json "http://127.0.0.1:4002/v1/sessions/$sid/status" && [ "$GOT_CODE" = 200 ]; then
      status_state["$sid"]=answered
      # halted_at is a microsecond ISO string; fromdateiso8601 wants none.
      while IFS=$'\t' read -r kind line; do
        [ -z "$kind" ] || add "gm_halt:$sid" "$line" "$kind"
      done < <(jq -r --argjson now "$now" --argjson min "${EM_STACK_GM_MIN:-20}" --arg sid "$sid" '
        .interlock as $i
        | select($i.state == "gm_halted" or $i.state == "awaiting_ooc_reply")
        | select(($i.reason // "") != "operator_halt")
        | (try ($i.halted_at | sub("\\.[0-9]+"; "") | fromdateiso8601) catch null) as $t
        | "GM halt on session \($sid) (\($i.state), reason \($i.reason // "?"), speaker \($i.speaker // "?"))" as $what
        | if $t == null then ["deb", "\($what), no halt time known"]
          elif ($now - $t) >= ($min * 60) then ["imm", "\($what), halted \((($now - $t) / 60) | floor) min ago"]
          else empty end
        | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
    elif [ "$GOT_KIND" = gone ]; then
      status_state["$sid"]=gone
    elif [ "$GOT_KIND" = answered ] && [ "$GOT_CODE" = 503 ] &&
         jq -e '.error == "session_not_found"' >/dev/null 2>&1 <<<"$GOT_BODY"; then
      status_state["$sid"]=answered   # the session is not running: no halt to report
    fi
  done

  # --- AgentOS quiescence: quarantine and events --------------------------------------
  if get_json "http://127.0.0.1:4400/em/quiescence" && [ "$GOT_CODE" = 200 ]; then
    quies_state=answered
    while IFS=$'\t' read -r key line; do
      [ -z "$key" ] || add "$key" "$line" deb
    done < <(jq -r '
      (.agents // {}) | to_entries[]
      | select(.value.quarantined != null)
      | ["quarantine:" + .key, "agent \(.key) is quarantined: \(.value.quarantined | tostring | gsub("\\s+"; " ") | .[0:300])"]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)

    # Events: a child_restart_failed recovery, or 3+ other recoveries (flapping).
    # A recovery stays in the list for an hour, so the key names the newest
    # relevant recovery's `at` (the same recovery is the same event), and a
    # stuck heal that keeps adding recoveries is rate-limited per
    # <boot>:<agent>:<kind>: nothing is posted, or recorded, while a seen key
    # with that prefix is under an hour old.
    while IFS=$'\t' read -r key prefix line; do
      [ -n "$key" ] || continue
      if jq -e --arg k "$key" --arg p "$prefix" --argjson now "$now" \
           'has($k) or any(to_entries[]; (.key | startswith($p)) and .value > ($now - 3600))' \
           >/dev/null <<<"$events_seen"; then continue; fi
      new_event_keys+=("$key"); new_event_texts+=("$line")
    done < <(jq -r '
      (.boot_id | tostring) as $b
      | (.agents // {}) | to_entries[]
      | .key as $a
      | ((.value.recoveries // []) | map(select(type == "object"))) as $r
      | ($r | map(select((.cause // "" | tostring) | contains("child_restart_failed")))) as $crf
      | ($r | map(select(((.cause // "" | tostring) | contains("child_restart_failed")) | not))) as $oth
      | (if ($crf | length) > 0 then
           ($crf | max_by(.at // "")) as $c
           | ["\($b):\($a):crf:\($c.at // "?")", "\($b):\($a):crf:",
              "agent \($a): child_restart_failed at \($c.at // "?") (\($crf | length) in the last hour): \(($c.detail // "") | tostring | gsub("\\s+"; " ") | .[0:200])"]
         else empty end),
        (if ($oth | length) >= 3 then
           ($oth | max_by(.at // "")) as $c
           | ["\($b):\($a):flap:\($c.at // "?")", "\($b):\($a):flap:",
              "agent \($a): \($oth | length) recoveries in the last hour (\($oth | map(.cause | tostring) | unique | join(", ")))"]
         else empty end)
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
  elif [ "$GOT_KIND" = gone ]; then
    # In a live mode AgentOS is supposed to be up, so a refusal is a failure to
    # carry (the 3-pass cap) until fail:agentos takes over; elsewhere it is gone.
    if [ "$live" = 1 ]; then quies_state=failed; else quies_state=gone; fi
  fi

  # --- Carry forward keys whose source did not answer ---------------------------------
  mapfile -t prev_active < <(jq -r '.keys[]' <<<"$state")
  for k in "${prev_active[@]}"; do
    [ -n "$k" ] || continue
    [ -z "${text[$k]+x}" ] || continue
    if source_failed "$k" && carry_step "$k"; then
      add "$k" "$(jq -r --arg k "$k" '.texts[$k] // $k' <<<"$state")" carry
    fi
  done
fi

# --- Decide what to say -------------------------------------------------------------
mapfile -t all_keys < <(printf '%s\n' "${!text[@]}" | sort | sed '/^$/d')

if dry; then
  echo "[dry-run] mode: ${mode:-unknown}; stack: $([ "$nostack" = 1 ] && echo none || echo up)"
  echo "[dry-run] raw keys: ${all_keys[*]:-(none)}"
  for k in "${all_keys[@]}"; do echo "[dry-run]   $k [${cls[$k]}]: ${text[$k]}"; done
  for i in "${!new_event_keys[@]}"; do echo "[dry-run]   event ${new_event_keys[$i]}: ${new_event_texts[$i]}"; done
fi

active=()
pending_json='{}'
sig=""
if [ "$nostack" = 0 ]; then
  prev_pending=$(jq -c '.pending // {}' <<<"$state")
  for k in "${all_keys[@]}"; do
    if [ "${cls[$k]}" = imm ] || [ "${cls[$k]}" = carry ]; then
      active+=("$k")
    else
      n=$(( $(jq -r --arg k "$k" '.[$k] // 0 | tonumber? // 0' <<<"$prev_pending") + 1 ))
      pending_json=$(jq -c --arg k "$k" --argjson n "$n" '.[$k] = $n' <<<"$pending_json")
      [ "$n" -lt 2 ] || active+=("$k")
    fi
  done
  # A debounce count survives a pass in which its source did not answer.
  while IFS=$'\t' read -r k n; do
    [ -n "$k" ] || continue
    if jq -e --arg k "$k" 'has($k) | not' >/dev/null <<<"$pending_json" && source_failed "$k" && carry_step "$k"; then
      pending_json=$(jq -c --arg k "$k" --argjson n "$n" '.[$k] = $n' <<<"$pending_json")
    fi
  done < <(jq -r '.pending | to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$state")
  if [ "${#active[@]}" -eq 0 ]; then
    sig=ok
  else
    sig=$(printf '%s\n' "${active[@]}" | sort -u | sha256sum | cut -c1-16)
  fi
fi

if [ "$nostack" = 0 ] && [ -z "$sig" ]; then
  echo "em-stack-monitor: internal error: no signature for the active key set" >&2
  exit 1
fi

short_head=$(git -C "$EM_STACK_REPO" rev-parse --short HEAD 2>/dev/null) || short_head=unknown
# stack-health runs from the main checkout, the one the stack is started from,
# so its checks match that code. The tree moves only when someone pulls (the
# BEAM keeps running the commit it booted), and this unit does not fetch: say
# how far the checkout trails origin/main as of its last fetch (a8gw1).
staleness="how far it trails origin/main is unknown"
if behind=$(git -C "$EM_STACK_REPO" rev-list --count HEAD..refs/remotes/origin/main 2>/dev/null); then
  fetch_head=$(git -C "$EM_STACK_REPO" rev-parse --path-format=absolute --git-path FETCH_HEAD 2>/dev/null) || fetch_head=""
  fetched_at=$(stat -c %Y "$fetch_head" 2>/dev/null) || fetched_at=""
  as_of=""
  [ -z "$fetched_at" ] || as_of=" as of its last fetch, $(date -u -d "@$fetched_at" +%Y-%m-%dT%H:%MZ)"
  if [ "$behind" = 0 ]; then
    staleness="level with origin/main$as_of"
  else
    staleness="$behind commits behind origin/main$as_of"
  fi
fi
footer="stack-health ran from the checkout $EM_STACK_REPO @ $short_head, $staleness
Runbook: $EM_STACK_RUNBOOK"

msg=""
if [ "$nostack" = 1 ]; then
  # Nothing is serving :4002. Pending problems are dropped silently; announced
  # ones get one closing line so "problem" is never the last word.
  if [ -n "$prev_sig" ] && [ "$prev_sig" != ok ]; then
    msg="EM stack: stopped, no longer watching: ${prev_keys_txt:-the earlier problems}"
  fi
else
  standing=""
  if [ "$sig" = ok ]; then
    if [ -n "$prev_sig" ] && [ "$prev_sig" != ok ]; then
      standing="EM stack: resolved, all checks OK again."
    fi
  elif [ "$sig" != "$prev_sig" ] || [ $(( now - prev_sent )) -ge $(( ${EM_STACK_REMIND_H:-6} * 3600 )) ]; then
    # Agent keys (a8gw1): the model quota and an agent's character logged out
    # for idling. When nothing else stands, the header says it is the agents,
    # not the stack.
    stack_side=0
    for k in "${active[@]}"; do
      case "$k" in quota:*|idleout:*) ;; *) stack_side=1 ;; esac
    done
    if [ "$stack_side" = 1 ]; then
      standing="EM stack: problem"
      [ "$sig" != "$prev_sig" ] || standing="EM stack: STILL failing"
    else
      standing="EM agents: not acting (the stack is up)"
      [ "$sig" != "$prev_sig" ] || standing="EM agents: STILL not acting (the stack is up)"
    fi
    for k in "${active[@]}"; do standing+=$'\n'"- ${text[$k]}"; done
  fi
  evtxt=""
  if [ "${#new_event_keys[@]}" -gt 0 ]; then
    evtxt="Events:"
    for t in "${new_event_texts[@]}"; do evtxt+=$'\n'"- $t"; done
  fi
  if [ -n "$standing" ] && [ -n "$evtxt" ]; then
    body="$standing"$'\n'"$evtxt"
  elif [ -n "$standing" ]; then
    body="$standing"
  elif [ -n "$evtxt" ]; then
    body="EM stack: event"$'\n'"$evtxt"
  else
    body=""
  fi
  if [ -n "$body" ]; then
    # Keep under 4096 characters (a 4096 cap kept for Slack: an
    # alert that long is unreadable on a phone anyway).
    [ "${#body}" -le 3500 ] || body="${body:0:3500}... (truncated; see the runbook)"
    msg="$body"
    # A bare "resolved" needs no footer; everything else names the checkout.
    if [ "$sig" != ok ] || [ -n "$evtxt" ]; then msg+=$'\n'"$footer"; fi
  fi
fi

# One Slack message per pass. A failed send records nothing, so the next
# pass redoes the whole message and nothing is half-announced.
sent_at=$prev_sent
if [ -n "$msg" ]; then
  if ! send "$msg"; then
    hc_ping /fail "em-stack monitor could not deliver to Slack: ${msg:0:1000}"
    failed_pinged=1
    exit 1
  fi
  # The reminder clock restarts only when the standing message (or "stopped")
  # went out, not for an event-only message.
  if [ "$nostack" = 1 ] || [ -n "${standing:-}" ]; then sent_at=$now; fi
fi

if ! dry; then
  events_new=$events_seen
  for k in "${new_event_keys[@]}"; do
    events_new=$(jq -c --arg k "$k" --argjson now "$now" '.[$k] = $now' <<<"$events_new")
  done
  keys_json=$(printf '%s\n' "${active[@]}" | jq -R . | jq -sc 'map(select(. != ""))')
  texts_json='{}'
  for k in "${active[@]}"; do
    texts_json=$(jq -c --arg k "$k" --arg t "${text[$k]}" '.[$k] = $t' <<<"$texts_json")
  done
  carried_json='{}'
  for k in "${!carried_n[@]}"; do
    carried_json=$(jq -c --arg k "$k" --argjson n "${carried_n[$k]}" '.[$k] = $n' <<<"$carried_json")
  done
  jq -n --arg sig "$sig" --argjson keys "$keys_json" --argjson texts "$texts_json" --argjson sent "$sent_at" \
    --argjson pending "$pending_json" --argjson events "$events_new" --argjson carried "$carried_json" \
    '{sig: $sig, keys: $keys, texts: $texts, sent_at: $sent, pending: $pending, events: $events, carried: $carried}' \
    >"$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
fi

if [ "$sig" = ok ] || [ "$nostack" = 1 ]; then
  hc_ping "" "ok"
else
  hc_ping "" "problems reported to Slack: ${#active[@]}"
fi
exit 0
