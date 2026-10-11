# shellcheck shell=bash
# em-ci failover: one reconcile pass. Wrapped by writeShellApplication in
# em-ci-failover.nix (PATH + set -euo pipefail). Design:
# docs/plans/2026-10-11-em-ci-gamebox-design.md, "Failover reconciler".
#
# Keeps the em-ci label on devbox's runners ABSENT while gamebox's runners are
# online and PRESENT while they are offline, with EM_CI_TICKS of hysteresis.
# Labels gate assignment only, so removing one never touches an in-flight job.
# Writes only on drift: a re-registration resets labels to the configured set,
# so desired state is compared every pass, but DELETE of an absent label 404s.

cred() { cat "${CREDENTIALS_DIRECTORY:?}/$1"; }
now=${EM_CI_NOW:-$(date +%s)}
S=${STATE_DIRECTORY:?}

gh_api() { # $1 method, $2 path, [$3 json body]
  if [ -n "${EM_CI_GH_API_STUB:-}" ]; then "$EM_CI_GH_API_STUB" "$@"; return; fi
  local body=()
  [ -z "${3:-}" ] || body=(-H "Content-Type: application/json" --data-raw "$3")
  printf 'header = "Authorization: Bearer %s"\n' "$(cred gh_token)" |
    curl -fsS -m 30 --retry 2 -X "$1" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "${body[@]}" -K - "https://api.github.com$2"
}
tg_send() {
  if [ -n "${EM_CI_TG_STUB:-}" ]; then "$EM_CI_TG_STUB" "$1"; return; fi
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(cred tg_bot_token)" |
    curl -fsS -m 20 --retry 3 -o /dev/null \
      --data-urlencode "chat_id=$(cred tg_chat_id)" --data-urlencode "text=$1" -K - || true
}
# An empty file (crash mid-write before put became atomic, or a manual
# truncate) reads as the default, never as "" -- "" would wedge desired.
get() { local v; v=$(cat "$S/$1" 2>/dev/null || true); echo "${v:-$2}"; }
put() { printf '%s\n' "$2" >"$S/$1.tmp" && mv -f "$S/$1.tmp" "$S/$1"; }

desired=$(get desired present)
on=$(get on 0); off=$(get off 0); errors=$(get errors 0)
offline_since=$(get offline_since ""); offline_alerted=$(get offline_alerted 0)

if ! runners=$(gh_api GET "/repos/$EM_CI_REPO/actions/runners?per_page=100") ||
   ! jq -e '.runners | type == "array"' >/dev/null <<<"$runners"; then
  errors=$((errors + 1)); put errors "$errors"
  [ "$errors" -ne "$EM_CI_ERROR_ALERT" ] ||
    tg_send "em-ci failover (devbox): cannot reach the GitHub API for $errors passes; devbox runner labels frozen at '$desired'."
  exit 0
fi
put errors 0

if jq -e --arg p "$EM_CI_PRIMARY_PREFIX" \
     'any(.runners[]; (.name | startswith($p)) and .status == "online")' >/dev/null <<<"$runners"; then
  on=$((on + 1)); off=0; offline_since=""; offline_alerted=0
else
  off=$((off + 1)); on=0; [ -n "$offline_since" ] || offline_since=$now
fi

if [ "$desired" = present ] && [ "$on" -ge "$EM_CI_TICKS" ]; then
  desired=absent
  tg_send "em-ci failover: gamebox runners online; devbox runners stop taking em-ci jobs (label removed, in-flight jobs finish)."
elif [ "$desired" = absent ] && [ "$off" -ge "$EM_CI_TICKS" ]; then
  desired=present
  tg_send "em-ci failover: gamebox runners offline; devbox runners now take em-ci jobs."
fi

if [ -n "$offline_since" ] && [ "$offline_alerted" = 0 ] &&
   [ $((now - offline_since)) -ge $((EM_CI_PRIMARY_OFFLINE_ALERT_H * 3600)) ]; then
  tg_send "em-ci failover: gamebox runners offline for $(( (now - offline_since) / 3600 )) h (a streaming pause cannot last that long). devbox is carrying CI."
  offline_alerted=1
fi

for name in $EM_CI_FALLBACK_RUNNERS; do
  row=$(jq -c --arg n "$name" --arg l "$EM_CI_LABEL" \
    '[.runners[] | select(.name == $n) | {id, has: ([.labels[].name] | index($l) != null)}][0] // empty' <<<"$runners")
  [ -n "$row" ] || continue   # missing runner: em-ci-monitor reports it
  id=$(jq -r .id <<<"$row"); has=$(jq -r .has <<<"$row")
  if [ "$desired" = present ] && [ "$has" = false ]; then
    gh_api POST "/repos/$EM_CI_REPO/actions/runners/$id/labels" "{\"labels\":[\"$EM_CI_LABEL\"]}" >/dev/null || true
  elif [ "$desired" = absent ] && [ "$has" = true ]; then
    gh_api DELETE "/repos/$EM_CI_REPO/actions/runners/$id/labels/$EM_CI_LABEL" >/dev/null || true
  fi
done

put desired "$desired"; put on "$on"; put off "$off"
put offline_since "$offline_since"; put offline_alerted "$offline_alerted"
