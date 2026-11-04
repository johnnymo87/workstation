# shellcheck shell=bash
# em-stack monitor: one pass. Wrapped by writeShellApplication in
# em-stack-monitor.nix, which supplies PATH and `set -euo pipefail`.
# Spec: docs/plans/2026-11-04-em-stack-monitor.md (read it for the rules; this
# header only says where each one lives).
#
# Credentials come from systemd LoadCredential ($CREDENTIALS_DIRECTORY):
#   tg_bot_token    pigeon's Telegram bot token
#   tg_chat_id      the forum group's chat id (no thread id -> General topic)
#   hc_ping_url     healthchecks.io ping URL; optional, the dead-man's ping is
#                   sent only when this file exists (hcEnabled in the .nix)
# Secrets reach curl only through a config on stdin (`-K -`, written by the
# printf builtin), never on a command line, where any host user could read
# them from /proc.
#
# Configuration (environment, set by the unit): EM_STACK_REPO (the main EM
# checkout, where bin/stack-health runs), EM_STACK_RUNBOOK, EM_STACK_REMIND_H,
# EM_STACK_GM_MIN, STATE_DIRECTORY. EM_STACK_MONITOR_DRY_RUN=1 prints the raw
# key set and the message instead of sending and pinging, and keeps no state.
#
# Test hooks (everything outside this script is injectable; each is the path of
# an executable, or unset for the real thing):
#   EM_STACK_FETCH_CMD   $1 = URL; prints the HTTP code on line 1, the body
#                        after it; non-zero when nothing answered.
#   EM_STACK_GATE_CMD    exit 0 when a stack (a BEAM on 127.0.0.1:4002) is up.
#   EM_STACK_MODE_CMD    prints the BEAM's EM_MODE (empty when unknown).
#   EM_STACK_HEALTH_CMD  prints bin/stack-health's output (exit code ignored).
#   EM_STACK_TG_CMD      reads the Telegram message on stdin; non-zero = failed.
#   EM_STACK_NOW         epoch seconds.
#
# Source tolerance. Under errexit/nounset/pipefail every source is graded on
# its own: a fetch that fails or a body that does not parse means "no data from
# that source" (for stack-health, the key monitor:blind), never an aborted
# pass. So every command that may fail sits in an `if` or has `|| true`.
#
# State ($STATE_DIRECTORY/state.json), written only after a pass that delivered
# everything it owed:
#   sig      what was last announced: "" nothing, "ok", or a hash of the
#            sorted active key set (numbers and times never reach a key)
#   keys     the keys behind sig, so a "stopped" line can name them
#   sent_at  when the standing message last went out (for the 6 h reminder)
#   pending  {key: consecutive passes seen} for the debounced keys
#   events   {event key: time sent}, pruned after 2 h
#
# Heartbeat contract (as em-ci-monitor). The healthchecks.io check measures the
# MONITOR: a pass that observed everything and delivered every Telegram message
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

tg_send() { # $1: text. Returns non-zero when delivery failed.
  if dry; then printf '[dry-run] telegram:\n%s\n' "$1"; return 0; fi
  if [ -n "${EM_STACK_TG_CMD:-}" ]; then
    printf '%s' "$1" | "$EM_STACK_TG_CMD"
    return
  fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cred tg_bot_token)" |
    curl -fsS -m 20 --retry 3 -o /dev/null \
      --data-urlencode "chat_id=$(cred tg_chat_id)" \
      --data-urlencode "text=$1" \
      --data-urlencode "disable_web_page_preview=true" \
      -K -
}

# --- Sources (default implementations; tests replace them) -------------------------
fetch() { # $1: URL. HTTP code on line 1, body after it. Non-zero: no answer.
  if [ -n "${EM_STACK_FETCH_CMD:-}" ]; then "$EM_STACK_FETCH_CMD" "$1"; return; fi
  local raw
  raw=$(curl -sS -m 10 -w '\n%{http_code}' "$1") || return 1
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

stack_health() { # prints bin/stack-health output; exit code is ignored by the caller
  if [ -n "${EM_STACK_HEALTH_CMD:-}" ]; then "$EM_STACK_HEALTH_CMD" 2>&1; return; fi
  cd "$EM_STACK_REPO" && timeout 200 ./bin/stack-health 2>&1
}

# get_json URL: leaves the HTTP code in GOT_CODE and the body in GOT_BODY.
# Returns non-zero (no data) when nothing answered or the body is not JSON.
GOT_CODE=""; GOT_BODY=""
get_json() {
  local raw
  GOT_CODE=""; GOT_BODY=""
  raw=$(fetch "$1") || return 1
  GOT_CODE=${raw%%$'\n'*}
  case "$raw" in *$'\n'*) GOT_BODY=${raw#*$'\n'} ;; *) GOT_BODY="" ;; esac
  jq -e . >/dev/null 2>&1 <<<"$GOT_BODY"
}

# --- Collect ------------------------------------------------------------------------
# text[key] is the line shown for a key; cls[key] is "deb" (debounced: must be
# seen on 2 passes in a row) or "imm" (alerts at once).
declare -A text=() cls=()
add() { text[$1]=$2; cls[$1]=$3; } # $1: stable key, $2: text, $3: deb|imm

now=${EM_STACK_NOW:-$(date +%s)}
hour=$(( now / 3600 ))
state_file="${STATE_DIRECTORY:?}/state.json"
state='{}'
if [ -f "$state_file" ] && st=$(cat "$state_file") && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$st"; then
  state=$st
fi
prev_sig=$(jq -r '.sig // ""' <<<"$state")
prev_sent=$(jq -r '.sent_at // 0' <<<"$state")
case "$prev_sent" in ''|*[!0-9]*) prev_sent=0 ;; esac
prev_keys_txt=$(jq -r '(.keys // []) | join(", ")' <<<"$state")

# Seen events, pruned after 2 h.
events_seen=$(jq -c --argjson now "$now" \
  '(.events // {}) | with_entries(select(.value > ($now - 7200)))' <<<"$state")

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
  have_summary=0
  unknown_checks=()
  re_bad='^  ([^[:space:]]+)[[:space:]]+(FAIL|DOWN|DEAD_MANAGER)([[:space:]]|$)(.*)$'
  re_unk='^  ([^[:space:]]+)[[:space:]]+UNKNOWN([[:space:]]|$)'
  while IFS= read -r line; do
    case "$line" in SUMMARY:*) have_summary=1 ;; esac
    if [[ $line =~ $re_bad ]]; then
      chk=${BASH_REMATCH[1]}
      if [ "$chk" = agentos ] && [ "$live" = 0 ]; then continue; fi
      detail=${BASH_REMATCH[4]}
      detail=${detail#"${detail%%[![:space:]]*}"}  # the verdict column's padding
      add "fail:$chk" "$chk ${BASH_REMATCH[2]}: ${detail:0:300}" deb
    elif [[ $line =~ $re_unk ]]; then
      unknown_checks+=("${BASH_REMATCH[1]}")
    fi
  done <<<"$health_out"
  if [ "$have_summary" = 0 ]; then
    add "monitor:blind" "bin/stack-health printed no SUMMARY line (it timed out or crashed): the monitor cannot see the stack" deb
  elif [ "${#unknown_checks[@]}" -gt 0 ]; then
    add "monitor:blind" "bin/stack-health could not check: ${unknown_checks[*]}; the monitor cannot see those" deb
  fi

  # --- Presence ---------------------------------------------------------------------
  sids=()
  if get_json "http://127.0.0.1:4002/v1/presence" && [ "$GOT_CODE" = 200 ]; then
    while IFS= read -r sid; do
      [ -z "$sid" ] || sids+=("$sid")
    done < <(jq -r '.presence | keys[] | select(test("^[A-Za-z0-9_-]+$"))' <<<"$GOT_BODY" 2>/dev/null || true)
    # last_close.cause "server" with wants_out null (it is an object {why, at}
    # when the close was wanted) means the server dropped us unasked.
    while IFS=$'\t' read -r key line; do
      [ -z "$key" ] || add "$key" "$line" deb
    done < <(jq -r '
      .presence | to_entries[]
      | select(.value.link == "offline" and .value.last_close.cause == "server" and .value.wants_out == null)
      | ["presence:" + .key,
         "session \(.key) is offline: the server closed the link at \(.value.last_close.at // "?") (code \(.value.last_close.code // "?"))"
         + (if .value.last_close.idle == true then ", while idle (TEC logs out an idle character)" else "" end)
         + ", and nobody asked for it"]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
  fi

  # --- GM halt, per session ---------------------------------------------------------
  for sid in "${sids[@]}"; do
    if get_json "http://127.0.0.1:4002/v1/sessions/$sid/status"; then
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
    fi
  done

  # --- AgentOS quiescence: quarantine and events --------------------------------------
  if get_json "http://127.0.0.1:4400/em/quiescence" && [ "$GOT_CODE" = 200 ]; then
    while IFS=$'\t' read -r key line; do
      [ -z "$key" ] || add "$key" "$line" deb
    done < <(jq -r '
      (.agents // {}) | to_entries[]
      | select(.value.quarantined != null)
      | ["quarantine:" + .key, "agent \(.key) is quarantined: \(.value.quarantined | tostring | gsub("\\s+"; " ") | .[0:300])"]
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)

    # Events: a child_restart_failed recovery, or 3+ other recoveries (flapping).
    # Hourly keys, so a stuck heal posts at most once an hour per agent.
    while IFS=$'\t' read -r key line; do
      [ -n "$key" ] || continue
      if jq -e --arg k "$key" 'has($k)' >/dev/null <<<"$events_seen"; then continue; fi
      new_event_keys+=("$key"); new_event_texts+=("$line")
    done < <(jq -r --argjson hour "$hour" '
      (.boot_id | tostring) as $b
      | (.agents // {}) | to_entries[]
      | .key as $a
      | ((.value.recoveries // []) | map(select(type == "object"))) as $r
      | ($r | map(select((.cause // "" | tostring) | contains("child_restart_failed")))) as $crf
      | ($r | map(select(((.cause // "" | tostring) | contains("child_restart_failed")) | not))) as $oth
      | (if ($crf | length) > 0 then
           ["\($b):\($a):crf:\($hour)",
            "agent \($a): child_restart_failed at \($crf[-1].at // "?") (\($crf | length) in the last hour): \(($crf[-1].detail // "") | tostring | gsub("\\s+"; " ") | .[0:200])"]
         else empty end),
        (if ($oth | length) >= 3 then
           ["\($b):\($a):flap:\($hour)",
            "agent \($a): \($oth | length) recoveries in the last hour (\($oth | map(.cause | tostring) | unique | join(", ")))"]
         else empty end)
      | @tsv' <<<"$GOT_BODY" 2>/dev/null || true)
  fi
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
    if [ "${cls[$k]}" = imm ]; then
      active+=("$k")
    else
      n=$(( $(jq -r --arg k "$k" '.[$k] // 0 | tonumber? // 0' <<<"$prev_pending") + 1 ))
      pending_json=$(jq -c --arg k "$k" --argjson n "$n" '.[$k] = $n' <<<"$pending_json")
      [ "$n" -lt 2 ] || active+=("$k")
    fi
  done
  if [ "${#active[@]}" -eq 0 ]; then
    sig=ok
  else
    sig=$(printf '%s\n' "${active[@]}" | sort -u | sha256sum | cut -c1-16)
  fi
fi

short_head=$(git -C "$EM_STACK_REPO" rev-parse --short HEAD 2>/dev/null) || short_head=unknown
footer="stack-health ran from $EM_STACK_REPO @ $short_head (nothing keeps that tree current)
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
    standing="EM stack: problem"
    [ "$sig" != "$prev_sig" ] || standing="EM stack: STILL failing"
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
    # Telegram rejects messages over 4096 characters.
    [ "${#body}" -le 3500 ] || body="${body:0:3500}... (truncated; see the runbook)"
    msg="$body"
    # A bare "resolved" needs no footer; everything else names the checkout.
    if [ "$sig" != ok ] || [ -n "$evtxt" ]; then msg+=$'\n'"$footer"; fi
  fi
fi

# One Telegram message per pass. A failed send records nothing, so the next
# pass redoes the whole message and nothing is half-announced.
sent_at=$prev_sent
if [ -n "$msg" ]; then
  if ! tg_send "$msg"; then
    hc_ping /fail "em-stack monitor could not deliver to Telegram: ${msg:0:1000}"
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
  jq -n --arg sig "$sig" --argjson keys "$keys_json" --argjson sent "$sent_at" \
    --argjson pending "$pending_json" --argjson events "$events_new" \
    '{sig: $sig, keys: $keys, sent_at: $sent, pending: $pending, events: $events}' \
    >"$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
fi

if [ "$sig" = ok ] || [ "$nostack" = 1 ]; then
  hc_ping "" "ok"
else
  hc_ping "" "problems reported to Telegram: ${#active[@]}"
fi
exit 0
