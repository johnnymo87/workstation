# shellcheck shell=bash
# slack_send: post one message to #em-alerts (the devbox Slack workspace)
# through the em-alerts app's incoming webhook. Shared by em-ci-monitor.sh,
# em-ci-failover.sh and em-stack-monitor.sh: each .nix prepends this file to
# its script (see em-alerts.nix). It holds no pigeon credential; the webhook
# can post to that one channel and do nothing else.
#
#   $CREDENTIALS_DIRECTORY/slack_webhook  the webhook URL (sops em_alerts_slack_webhook)
#   PIGEON_SLACK_NOTIFY_OWNER             "1": every post @-mentions the owner, so
#                                         it pushes to his phone. Anything else:
#                                         no mention, no push (spec D7: no pushes
#                                         to start; he turns them on later).
#   EM_SLACK_OWNER_ID                     his user id in that workspace (used, and
#                                         required, only when the mention is on).
#
# $1: plain text. Returns non-zero when delivery failed (curl -f: Slack answers
# a revoked webhook or an archived channel with a 4xx), so each caller keeps
# its own healthchecks.io failure contract.
#
# The URL is a secret. It reaches curl only through a config on stdin (-K -,
# written by the printf builtin), never on a command line, where any host user
# could read it from /proc. It must be a hooks.slack.com webhook: the check
# keeps a mistyped secret from sending alert text anywhere else, and keeps a
# quote in it from breaking out of the curl config line.

slack_text() { # $1: plain text -> the Slack message text on stdout
  # Slack reads <...> as link/mention markup and & as an entity, so a monitor
  # line like "queued >= 20 min" must be escaped (Slack's documented three).
  local prefix=""
  if [ "${PIGEON_SLACK_NOTIFY_OWNER:-}" = 1 ]; then
    # Mention asked for but no usable id: refuse, rather than post an alert
    # that silently pushes to nobody.
    if ! [[ ${EM_SLACK_OWNER_ID:-} =~ ^[UW][A-Z0-9]+$ ]]; then
      echo "EM_SLACK_OWNER_ID is not a Slack user id; not sending" >&2
      return 1
    fi
    prefix="<@$EM_SLACK_OWNER_ID> "
  fi
  jq -rn --arg t "$1" --arg p "$prefix" \
    '$p + ($t | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;"))'
}

slack_send() { # $1: plain text. Non-zero when delivery failed.
  local url text payload
  url=$(cat "${CREDENTIALS_DIRECTORY:?}/slack_webhook") || return 1
  if ! [[ $url =~ ^https://hooks\.slack\.com/services/[A-Za-z0-9/]+$ ]]; then
    echo "slack_webhook credential is not a https://hooks.slack.com/services/ URL; not sending" >&2
    return 1
  fi
  text=$(slack_text "$1") || return 1
  payload=$(jq -cn --arg t "$text" '{text: $t, unfurl_links: false, unfurl_media: false}') || return 1
  printf 'url = "%s"\n' "$url" |
    curl -fsS -m 20 --retry 3 -o /dev/null \
      -H "Content-Type: application/json" --data-binary "$payload" -K -
}
