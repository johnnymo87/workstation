# shellcheck shell=bash
# em-ci monitor: one pass. Wrapped by writeShellApplication in em-ci-monitor.nix,
# which supplies PATH and `set -euo pipefail`.
#
# Credentials come from systemd LoadCredential ($CREDENTIALS_DIRECTORY):
#   gh_token        GitHub token that can list runners and read Actions
#   tg_bot_token    pigeon's Telegram bot token
#   tg_chat_id      the forum group's chat id (no thread id -> General topic)
#   hc_ping_url     healthchecks.io ping URL (the dead-man's switch)
#
# Configuration (environment, set by the unit):
#   EM_CI_REPO, EM_CI_RUNNERS (space-separated runner names),
#   EM_CI_CONTAINERS (space-separated container names), EM_CI_LABEL,
#   EM_CI_QUEUE_MAX_MIN, EM_CI_BACKLOG_MAX_MIN, EM_CI_ROOT_MIN_GB, EM_CI_VOLUME, EM_CI_VOLUME_MIN_GB,
#   EM_CI_REMIND_H, EM_CI_RUNBOOK, STATE_DIRECTORY.
#   EM_CI_MONITOR_DRY_RUN=1 prints instead of sending and pinging.
#
# Heartbeat contract: the healthchecks.io check gets a success ping whenever
# this pass ran to the end AND every Telegram message it needed to send was
# delivered. It gets /fail when delivery failed or the pass crashed, so a
# problem can never be silent: either General hears it from devbox, or
# healthchecks.io says devbox's monitor is down. Devbox itself being down shows
# up as missing pings.

cred() { cat "${CREDENTIALS_DIRECTORY:?}/$1"; }
dry() { [ "${EM_CI_MONITOR_DRY_RUN:-0}" = 1 ]; }

hc_ping() { # $1: "" for success, "/fail" for failure; $2: body
  if dry; then echo "[dry-run] hc ping${1:-/success}: $2"; return 0; fi
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$2" "$(cred hc_ping_url)$1" || true
}

# shellcheck disable=SC2329  # invoked via the ERR trap
on_crash() {
  hc_ping /fail "em-ci monitor crashed at line $1"
}
trap 'on_crash $LINENO' ERR

tg_send() { # $1: text. Returns non-zero when delivery failed.
  if dry; then printf '[dry-run] telegram:\n%s\n' "$1"; return 0; fi
  local token chat
  token=$(cred tg_bot_token); chat=$(cred tg_chat_id)
  curl -fsS -m 20 --retry 3 -o /dev/null \
    --data-urlencode "chat_id=$chat" \
    --data-urlencode "text=$1" \
    --data-urlencode "disable_web_page_preview=true" \
    "https://api.telegram.org/bot$token/sendMessage"
}

gh_api() { # $1: path. Prints JSON; non-zero on HTTP error.
  curl -fsS -m 30 --retry 2 \
    -H "Authorization: Bearer $(cred gh_token)" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com$1"
}

problems=()
keys=()
add() { keys+=("$1"); problems+=("$2"); } # $1: stable key, $2: text

# --- GitHub: runners online --------------------------------------------------
idle_runners=0
if runners_json=$(gh_api "/repos/$EM_CI_REPO/actions/runners?per_page=100"); then
  idle_runners=$(jq --arg l "$EM_CI_LABEL" '[.runners[] | select(.status == "online" and (.busy | not) and ([.labels[].name] | index($l)))] | length' <<<"$runners_json")
  for r in $EM_CI_RUNNERS; do
    status=$(jq -r --arg n "$r" '[.runners[] | select(.name == $n) | .status][0] // "missing"' <<<"$runners_json")
    [ "$status" = online ] || add "runner:$r:$status" "runner $r is $status"
  done
else
  add "gh:runners" "cannot list runners via the GitHub API (token expired or lacks Administration:read?)"
fi

# --- GitHub: jobs queued on the em-ci label too long --------------------------
# Two runners take a 6-job run two at a time, so a busy PR alone keeps jobs
# queued past 20 minutes. "Stuck" therefore means queued >= EM_CI_QUEUE_MAX_MIN
# while an em-ci runner sits online and idle (GitHub is not dispatching), or
# queued >= EM_CI_BACKLOG_MAX_MIN regardless (backlog far beyond normal).
now=$(date +%s)
limit_min=$EM_CI_BACKLOG_MAX_MIN
[ "$idle_runners" -gt 0 ] && limit_min=$EM_CI_QUEUE_MAX_MIN
queue_ok=1
stuck=()
for st in queued in_progress; do
  if ! runs_json=$(gh_api "/repos/$EM_CI_REPO/actions/runs?status=$st&per_page=100"); then
    queue_ok=0; break
  fi
  for run_id in $(jq -r '.workflow_runs[].id' <<<"$runs_json"); do
    if ! jobs_json=$(gh_api "/repos/$EM_CI_REPO/actions/runs/$run_id/jobs?filter=latest&per_page=100"); then
      queue_ok=0; continue
    fi
    while IFS=$'\t' read -r name created url; do
      [ -n "$name" ] || continue
      age_min=$(( (now - $(date -d "$created" +%s)) / 60 ))
      if [ "$age_min" -ge "$limit_min" ]; then
        stuck+=("\"$name\" queued ${age_min} min ($url)")
      fi
    done < <(jq -r --arg l "$EM_CI_LABEL" \
      '.jobs[] | select(.status == "queued" and (.labels | index($l))) | [.name, .created_at, .html_url] | @tsv' \
      <<<"$jobs_json")
  done
done
[ "$queue_ok" = 1 ] || add "gh:jobs" "cannot list queued jobs via the GitHub API (token lacks Actions:read?)"
if [ "${#stuck[@]}" -gt 0 ]; then
  add "queue" "${#stuck[@]} em-ci job(s) queued >= ${limit_min} min (idle em-ci runners: $idle_runners): ${stuck[*]}"
fi

# --- Host: containers, watchdog, disk ------------------------------------------
for c in $EM_CI_CONTAINERS; do
  state=$(systemctl is-active "container@$c.service" || true)
  [ "$state" = active ] || add "container:$c" "container $c is $state"
done
if systemctl is-failed --quiet em-ci-disk-watchdog.service; then
  add "watchdog" "the disk watchdog fired (root disk was low; it stops the containers)"
fi
root_gb=$(( $(df --output=avail -k / | tail -n 1 | tr -d ' ') / 1024 / 1024 ))
[ "$root_gb" -ge "$EM_CI_ROOT_MIN_GB" ] || add "disk:root" "root disk has ${root_gb} GB free (alert below ${EM_CI_ROOT_MIN_GB} GB)"
if vol_kib=$(df --output=avail -k "$EM_CI_VOLUME" 2>/dev/null | tail -n 1 | tr -d ' '); then
  vol_gb=$(( vol_kib / 1024 / 1024 ))
  [ "$vol_gb" -ge "$EM_CI_VOLUME_MIN_GB" ] || add "disk:volume" "the em-ci Volume ($EM_CI_VOLUME) has ${vol_gb} GB free (alert below ${EM_CI_VOLUME_MIN_GB} GB)"
else
  add "disk:volume" "cannot read free space on $EM_CI_VOLUME"
fi

# --- Decide what to say ----------------------------------------------------------
state_file="${STATE_DIRECTORY:?}/last"
prev_sig=""; prev_at=0
if [ -f "$state_file" ]; then
  read -r prev_sig prev_at <"$state_file" || true
fi
prev_at=${prev_at:-0}

if [ "${#problems[@]}" -eq 0 ]; then
  sig=ok
else
  # Signature of the problem SET by stable key, so numbers that drift every
  # pass (minutes queued, GB free) do not re-announce a standing problem.
  sig=$(printf '%s\n' "${keys[@]}" | sort | sha256sum | cut -c1-16)
fi

msg=""
if [ "$sig" = ok ]; then
  if [ -n "$prev_sig" ] && [ "$prev_sig" != ok ]; then
    msg="em-ci (devbox CI runners): resolved, all checks OK again."
  fi
elif [ "$sig" != "$prev_sig" ] || [ $(( now - prev_at )) -ge $(( EM_CI_REMIND_H * 3600 )) ]; then
  head="em-ci (devbox CI runners): problem"
  [ "$sig" = "$prev_sig" ] && head="em-ci (devbox CI runners): STILL failing"
  msg="$head
$(printf -- '- %s\n' "${problems[@]}")
Runbook: $EM_CI_RUNBOOK (fallback: set repo variable FORCE_HOSTED=true)"
fi

if [ -n "$msg" ]; then
  if ! tg_send "$msg"; then
    hc_ping /fail "em-ci monitor could not deliver to Telegram: $msg"
    exit 1
  fi
  sent_at=$now
else
  sent_at=$prev_at
fi
dry || printf '%s %s\n' "$sig" "$sent_at" >"$state_file"

if [ "$sig" = ok ]; then
  hc_ping "" "ok"
else
  hc_ping "" "problems reported to Telegram: ${#problems[@]}"
fi
if dry && [ "${#problems[@]}" -gt 0 ]; then
  printf 'problems (%s):\n' "${#problems[@]}"; printf -- '- %s\n' "${problems[@]}"
fi
exit 0
