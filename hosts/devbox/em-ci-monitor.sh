# shellcheck shell=bash
# em-ci monitor: one pass. Wrapped by writeShellApplication in em-ci-monitor.nix,
# which supplies PATH and `set -euo pipefail`.
#
# Credentials come from systemd LoadCredential ($CREDENTIALS_DIRECTORY):
#   gh_token        GitHub token: Actions read + Administration read on the repo
#   tg_bot_token    pigeon's Telegram bot token
#   tg_chat_id      the forum group's chat id (no thread id -> General topic)
#   hc_ping_url     healthchecks.io ping URL (the dead-man's switch)
# Secrets reach curl only through a config on stdin (`-K -`, written by the
# printf builtin), never on a command line, where any host user could read
# them from /proc.
#
# Configuration (environment, set by the unit):
#   EM_CI_REPO, EM_CI_RUNNERS (space-separated runner names),
#   EM_CI_CONTAINERS (space-separated container names), EM_CI_LABEL,
#   EM_CI_QUEUE_MAX_MIN, EM_CI_BACKLOG_MAX_MIN, EM_CI_SETUP_WINDOW_MIN,
#   EM_CI_ROOT_MIN_GB, EM_CI_VOLUME, EM_CI_VOLUME_MIN_GB, EM_CI_REMIND_H,
#   EM_CI_RUNBOOK, STATE_DIRECTORY.
#   EM_CI_MONITOR_DRY_RUN=1 prints instead of sending and pinging, and keeps
#   no state.
#
# Heartbeat contract. The healthchecks.io check measures the MONITOR: it gets a
# success ping when a pass observed everything and delivered every Telegram
# message it owed (a reported problem still earns a success ping). A pass that
# could not deliver, or that exits non-zero for any other reason, pings /fail.
# A pass that never runs (devbox down, unit cannot start, timer gone) sends
# nothing, and healthchecks.io reports it down after its grace period.

set -E
cred() { cat "${CREDENTIALS_DIRECTORY:?}/$1"; }
dry() { [ "${EM_CI_MONITOR_DRY_RUN:-0}" = 1 ]; }
failed_pinged=0

hc_ping() { # $1: "" for success, "/fail" for failure; $2: body
  if dry; then echo "[dry-run] hc ping${1:-/success}: $2"; return 0; fi
  printf 'url = "%s%s"\n' "$(cred hc_ping_url)" "$1" |
    curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$2" -K - || true
}

# shellcheck disable=SC2329  # invoked via the EXIT trap
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$failed_pinged" = 0 ]; then
    hc_ping /fail "em-ci monitor exited $rc; see journalctl -u em-ci-monitor on devbox"
  fi
}
trap on_exit EXIT

tg_send() { # $1: text. Returns non-zero when delivery failed.
  if dry; then printf '[dry-run] telegram:\n%s\n' "$1"; return 0; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cred tg_bot_token)" |
    curl -fsS -m 20 --retry 3 -o /dev/null \
      --data-urlencode "chat_id=$(cred tg_chat_id)" \
      --data-urlencode "text=$1" \
      --data-urlencode "disable_web_page_preview=true" \
      -K -
}

gh_api() { # $1: path. Prints JSON; non-zero on HTTP error.
  printf 'header = "Authorization: Bearer %s"\n' "$(cred gh_token)" |
    curl -fsS -m 30 --retry 2 \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -K - "https://api.github.com$1"
}

problems=()
keys=()
add() { keys+=("$1"); problems+=("$2"); } # $1: stable key, $2: text

now=$(date +%s)
since_iso=$(date -u -d "@$(( now - 3 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)

idle_em_ci_runners() { # $1: runners JSON. Prints the count; fails on bad JSON.
  jq -e --arg l "$EM_CI_LABEL" \
    '[.runners[] | select(.status == "online" and (.busy | not) and ([.labels[].name] | index($l)))] | length' \
    <<<"$1"
}

# --- GitHub: runners online (first snapshot) ------------------------------------
idle1=0
if runners_json=$(gh_api "/repos/$EM_CI_REPO/actions/runners?per_page=100") &&
   idle1=$(idle_em_ci_runners "$runners_json"); then
  for r in $EM_CI_RUNNERS; do
    status=$(jq -r --arg n "$r" '[.runners[] | select(.name == $n) | .status][0] // "missing"' <<<"$runners_json")
    [ "$status" = online ] || add "runner:$r:$status" "runner $r is $status"
  done
else
  idle1=0
  add "gh:runners" "cannot list runners via the GitHub API (token expired or lacks Administration:read?)"
fi

# --- GitHub: collect the jobs of active and recent runs -------------------------
# Queued and in-progress runs (any age), plus runs created in the last 3 h for
# the setup-failure check. One page each; at two runners that is far more than
# can be active at once, and a full page is reported rather than ignored.
# Each em-ci job becomes at most one line, computed in jq so that bash never
# splits a row with empty fields (tab is IFS whitespace, so `read` would
# collapse them):  Q <tab> queued-minutes <tab> name: url
#                  S <tab> 0 <tab> name on runner: url   (setup failed recently)
# Coverage note: a rerun of a run created more than 3 h ago that starts and
# fails between two passes is not seen; it still shows as a red check.
job_lines=""
obs_ok=1
run_ids=""
for q in "status=queued" "status=in_progress" "created=%3E%3D$since_iso"; do
  if runs_json=$(gh_api "/repos/$EM_CI_REPO/actions/runs?$q&per_page=100") &&
     jq -e '.workflow_runs | type == "array"' >/dev/null <<<"$runs_json" &&
     ids=$(jq -r '.workflow_runs[].id' <<<"$runs_json"); then
    run_ids+="$ids"$'\n'
    [ "$(jq -r '.workflow_runs | length' <<<"$runs_json")" -lt 100 ] ||
      add "gh:page" "more than 100 runs match $q; the monitor saw only the first page"
  else
    obs_ok=0
  fi
done
while read -r run_id; do
  [ -n "$run_id" ] || continue
  if jobs_json=$(gh_api "/repos/$EM_CI_REPO/actions/runs/$run_id/jobs?filter=latest&per_page=100") &&
     jq -e '.jobs | type == "array"' >/dev/null <<<"$jobs_json" &&
     lines=$(jq -r --arg l "$EM_CI_LABEL" --argjson now "$now" --argjson win "$EM_CI_SETUP_WINDOW_MIN" '
       .jobs[]
       | select(.labels | index($l))
       | if .status == "queued" then
           ["Q", ((($now - (.created_at | fromdateiso8601)) / 60) | floor | tostring), "\(.name): \(.html_url)"]
         elif .status == "completed" and .conclusion == "failure" and .completed_at != null
              and ((.steps // []) | any(.name == "Run ./.github/ci/setup" and .conclusion == "failure"))
              and (($now - (.completed_at | fromdateiso8601)) / 60) < $win then
           ["S", "0", "\(.name) on \(.runner_name // "?"): \(.html_url)"]
         else empty end
       | @tsv' <<<"$jobs_json"); then
    [ -z "$lines" ] || job_lines+="$lines"$'\n'
  else
    obs_ok=0
  fi
done < <(sort -u <<<"$run_ids")
[ "$obs_ok" = 1 ] || add "gh:jobs" "cannot read workflow runs/jobs via the GitHub API (token lacks Actions:read, or an unexpected response)"

# --- Runners: second snapshot ------------------------------------------------------
# Two runners take a 6-job run two at a time, so a busy PR alone keeps jobs
# queued past 20 minutes. "Stuck" means queued >= EM_CI_QUEUE_MAX_MIN while an
# em-ci runner is idle in BOTH snapshots (taken the job scan apart, so a runner
# between two jobs does not count), or queued >= EM_CI_BACKLOG_MAX_MIN anyway.
idle2=0
if runners_json2=$(gh_api "/repos/$EM_CI_REPO/actions/runners?per_page=100"); then
  idle2=$(idle_em_ci_runners "$runners_json2") || idle2=0
fi
idle=$(( idle1 < idle2 ? idle1 : idle2 ))
limit_min=$EM_CI_BACKLOG_MAX_MIN
[ "$idle" -gt 0 ] && limit_min=$EM_CI_QUEUE_MAX_MIN

stuck_n=0; stuck_oldest=0; stuck_links=()
setup_n=0; setup_links=()
while IFS=$'\t' read -r kind age_min what; do
  case "$kind" in
    Q)
      if [ "$age_min" -ge "$limit_min" ]; then
        stuck_n=$(( stuck_n + 1 ))
        [ "$age_min" -le "$stuck_oldest" ] || stuck_oldest=$age_min
        [ "${#stuck_links[@]}" -ge 3 ] || stuck_links+=("$what")
      fi ;;
    S)
      setup_n=$(( setup_n + 1 ))
      [ "${#setup_links[@]}" -ge 3 ] || setup_links+=("$what") ;;
  esac
done <<<"$job_lines"

if [ "$stuck_n" -gt 0 ]; then
  add "queue" "$stuck_n em-ci job(s) queued >= $limit_min min (oldest $stuck_oldest min; idle em-ci runners: $idle). E.g. $(printf '%s; ' "${stuck_links[@]}")"
fi
if [ "$setup_n" -gt 0 ]; then
  add "setup" "$setup_n em-ci job(s) failed in ./.github/ci/setup in the last $EM_CI_SETUP_WINDOW_MIN min (runner dirty, a disk floor, or devenv). E.g. $(printf '%s; ' "${setup_links[@]}")"
fi

# --- Host: containers, watchdog, disk -----------------------------------------------
for c in $EM_CI_CONTAINERS; do
  state=$(systemctl is-active "container@$c.service" || true)
  [ "$state" = active ] || add "container:$c" "container $c is $state"
done
if systemctl is-failed --quiet em-ci-disk-watchdog.service; then
  add "watchdog" "the disk watchdog fired (root disk was low; it stops the containers)"
fi
root_kib=$(df --output=avail -k / | tail -n 1 | tr -d ' ')
root_gb=$(( root_kib / 1024 / 1024 ))
[ "$root_gb" -ge "$EM_CI_ROOT_MIN_GB" ] || add "disk:root" "root disk has $root_gb GB free (alert below $EM_CI_ROOT_MIN_GB GB)"
if vol_kib=$(df --output=avail -k "$EM_CI_VOLUME" | tail -n 1 | tr -d ' ') && [ -n "$vol_kib" ]; then
  vol_gb=$(( vol_kib / 1024 / 1024 ))
  [ "$vol_gb" -ge "$EM_CI_VOLUME_MIN_GB" ] || add "disk:volume" "the em-ci Volume ($EM_CI_VOLUME) has $vol_gb GB free (alert below $EM_CI_VOLUME_MIN_GB GB; jobs refuse to start below 5)"
else
  add "disk:volume" "cannot read free space on $EM_CI_VOLUME"
fi

# --- Decide what to say ------------------------------------------------------------
state_file="${STATE_DIRECTORY:?}/last"
prev_sig=""; prev_at=0
if [ -f "$state_file" ]; then
  read -r prev_sig prev_at <"$state_file" || true
fi
case "$prev_at" in ''|*[!0-9]*) prev_at=0 ;; esac

if [ "${#problems[@]}" -eq 0 ]; then
  sig=ok
else
  # Signature of the problem SET by stable key, so numbers that drift every
  # pass (minutes queued, GB free) do not re-announce a standing problem.
  sig=$(printf '%s\n' "${keys[@]}" | sort -u | sha256sum | cut -c1-16)
fi

msg=""
if [ "$sig" = ok ]; then
  if [ -n "$prev_sig" ] && [ "$prev_sig" != ok ]; then
    msg="em-ci (devbox CI runners): resolved, all checks OK again."
  fi
elif [ "$sig" != "$prev_sig" ] || [ $(( now - prev_at )) -ge $(( EM_CI_REMIND_H * 3600 )) ]; then
  head="em-ci (devbox CI runners): problem"
  [ "$sig" = "$prev_sig" ] && head="em-ci (devbox CI runners): STILL failing"
  body=$(printf -- '- %s\n' "${problems[@]}")
  # Telegram rejects messages over 4096 characters.
  [ "${#body}" -le 3500 ] || body="${body:0:3500}... (truncated; see the Actions tab)"
  msg="$head
$body
Runbook: $EM_CI_RUNBOOK (fallback: set repo variable FORCE_HOSTED=true)"
fi

if [ -n "$msg" ]; then
  if ! tg_send "$msg"; then
    hc_ping /fail "em-ci monitor could not deliver to Telegram: ${msg:0:1000}"
    failed_pinged=1
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
