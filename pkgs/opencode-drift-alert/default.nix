# opencode-drift-alert: shared alert helper for the opencode canaries.
#
# EXTRACTED 2026-07-30 from hosts/cloudbox/configuration.nix so devbox can use
# the same battle-tested escalation logic. Devbox had the drift DETECTION half
# (frontdoor-canary) but not the escalation half, and on 2026-07-29/30 it
# repeated cloudbox's 2026-07-24 incident exactly: 1363 journal warnings over
# ~23h, all unread, while every session-scoped question/permission request
# 404'd through a stale front door. Two hosts, one script -- do not fork it.
#
# Shared alert helper for canaries (opencode-frontdoor-canary and serve pool canary).
#
# Context (2026-07-24 incident):
# On 2026-07-24, opencode-frontdoor ran stale code for ~70 minutes. The canary detected drift
# every minute (70 times), but journal logs went unread.
#
# This helper sends actionable plain-text notifications via Pigeon's HTTP alert endpoint
# (http://127.0.0.1:4731/alert). It uses a state file and signature to throttle repeat alerts
# during an ongoing drift episode, preventing 70-alert storms.
#
# ESCALATION (2026-07-27, second frontdoor incident):
# The flat 24h throttle above turned out to have a worse failure mode than the storm it
# prevented. On 2026-07-26 the frontdoor drift canary detected drift correctly on EVERY
# 60s pass from 10:14:07 to 22:53:00 -- ~760 consecutive detections, 12h39m of every
# mutating request failing -- and sent exactly ONE notification, at 10:15. The signature
# (running|execstart) never changed, so the 86400 TTL suppressed all 759 that followed.
# One page was missed, and the design then guaranteed nobody would be told again that day.
# Detection never failed; escalation did.
#
# So a repeat alert is now scheduled on EXPONENTIAL BACKOFF rather than a flat TTL, and the
# severity escalates once the condition proves persistent:
#
#   arg4 = INITIAL_INTERVAL (seconds before the 1st repeat), arg5 = MAX_INTERVAL (cap).
#   Nth repeat waits min(INITIAL * 2^(N-1), MAX). At 900/14400 an unresolved condition
#   pages at t=0, 15m, 45m, 1h45, 3h45, 7h45, 11h45 -- 7 times across that same 12h39m
#   window, instead of once. Steady state is one page per 4h, which is the right nag rate
#   for "every mutating request is failing" and cannot become a 70-alert storm because the
#   floor is 15 minutes.
#
# Severity escalates warning -> error on the 3rd alert (~45m at the default base), which
# Telegram renders as a distinct ❌ rather than ⚠️ so a persistent condition looks different
# from a fresh one in the notification list. NOTE: pigeon's /alert coerces any severity
# outside info|warning|error to "info" (packages/daemon/src/app.ts) -- escalating to
# "critical" would silently DOWNGRADE the alert. "error" is the ceiling; do not "raise" it.
#
# Passing arg4 <= 0 keeps the old suppress-while-signature-matches behaviour, which is what
# the daily relogin reminder wants (it date-stamps its signature to fire once per day).
#
# Safety invariants:
# 1. State file is written ONLY after a successful HTTP 2xx POST. A transient Pigeon
#    outage must not swallow the alert.
# 2. Under no circumstances does a failure here abort the calling script (`set -u` safe,
#    never exits non-zero).
# 3. Backoff state lives in the SAME file as the signature (line 2 = count, line 3 = epoch
#    of first alert). A pre-existing 1-line v1 state file is read as count=1, so an upgrade
#    mid-episode degrades to "repeat soon", never to "silent".
{ pkgs, lib ? pkgs.lib }:

pkgs.writeShellScript "opencode-drift-alert" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq ]}

    STATE_FILE="''${1:-}"
    SIGNATURE="''${2:-}"
    TEXT="''${3:-}"
    TTL_SECONDS="''${4:-0}"
    MAX_INTERVAL="''${5:-14400}"

    if [ -z "$STATE_FILE" ] || [ -z "$SIGNATURE" ] || [ -z "$TEXT" ]; then
      echo "WARNING: opencode-drift-alert called with missing arguments"
      exit 0
    fi

    NOW=$(date +%s)
    ALERT_COUNT=0
    FIRST_ALERT="$NOW"

    # Deduplication + backoff. Only line 1 is the signature; a v1 file has just that line.
    if [ -f "$STATE_FILE" ]; then
      # Read all three lines with bash builtins. NOT sed/awk: this script's PATH is pinned to
      # coreutils+curl+jq, and `sed` is NOT in coreutils -- an earlier revision used `sed -n 2p`
      # here, which silently failed, pinned the count at 1 forever, and degraded the backoff to
      # a flat 15-minute nag that never escalated severity. Caught only by replaying the
      # incident against the built artifact.
      CURRENT_SIG=""; PREV_COUNT=""; PREV_FIRST=""
      { read -r CURRENT_SIG; read -r PREV_COUNT; read -r PREV_FIRST; } < "$STATE_FILE" 2>/dev/null || true
      if [ "$CURRENT_SIG" = "$SIGNATURE" ]; then
        case "$PREV_COUNT" in ""|*[!0-9]*) PREV_COUNT=1 ;; esac
        FILE_MTIME=$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)
        case "$PREV_FIRST" in ""|*[!0-9]*) PREV_FIRST="$FILE_MTIME" ;; esac
        ALERT_COUNT="$PREV_COUNT"
        FIRST_ALERT="$PREV_FIRST"

        if [ -n "$TTL_SECONDS" ] && [ "$TTL_SECONDS" -gt 0 ] 2>/dev/null; then
          # Required gap before repeat N+1: INITIAL * 2^(N-1), capped at MAX_INTERVAL.
          INTERVAL="$TTL_SECONDS"
          STEP=1
          while [ "$STEP" -lt "$ALERT_COUNT" ]; do
            INTERVAL=$((INTERVAL * 2))
            if [ "$INTERVAL" -ge "$MAX_INTERVAL" ]; then
              INTERVAL="$MAX_INTERVAL"
              break
            fi
            STEP=$((STEP + 1))
          done
          AGE=$((NOW - FILE_MTIME))
          if [ "$AGE" -lt "$INTERVAL" ]; then
            exit 0
          fi
        else
          # arg4 <= 0: legacy suppress-forever-while-signature-matches.
          exit 0
        fi
      fi
    fi

    NEXT_COUNT=$((ALERT_COUNT + 1))

    # Escalate once the condition has survived a couple of repeats. "error" is pigeon's
    # highest accepted severity -- see the note above before changing this string.
    if [ "$NEXT_COUNT" -ge 3 ]; then
      SEVERITY="error"
    else
      SEVERITY="warning"
    fi

    # Make persistence legible in the notification itself, so the reader can tell a fresh
    # page from one that has been shouting for four hours without opening a terminal.
    if [ "$NEXT_COUNT" -gt 1 ]; then
      ELAPSED=$((NOW - FIRST_ALERT))
      [ "$ELAPSED" -lt 0 ] && ELAPSED=0
      E_H=$((ELAPSED / 3600))
      E_M=$(((ELAPSED % 3600) / 60))
      # Built with printf rather than an embedded literal newline: a column-0 line inside a
      # Nix indented-string would drop common-indentation stripping for the WHOLE script.
      SUFFIX="STILL UNRESOLVED: alert #$NEXT_COUNT, first reported ''${E_H}h''${E_M}m ago. This condition has persisted across $NEXT_COUNT notifications and is not self-healing."
      TEXT="$(printf '%s\n\n%s' "$TEXT" "$SUFFIX")"
    fi

    # Construct JSON payload safely using jq (handles store paths, quotes, and newlines).
    # Prefix text with [hostname] so Telegram alerts identify the originating host.
    FULL_TEXT="[$(uname -n)] $TEXT"
    PAYLOAD=$(jq -n --arg txt "$FULL_TEXT" --arg sev "$SEVERITY" '{"text": $txt, "severity": $sev}')

    PIGEON_TOKEN="''${PIGEON_DAEMON_AUTH_TOKEN:-}"
    PIGEON_TOKEN="$(printf '%s' "$PIGEON_TOKEN" | tr -d '[:space:]')"
    if [ -z "$PIGEON_TOKEN" ]; then
      TOKEN_FILE="''${PIGEON_DAEMON_AUTH_TOKEN_FILE:-/run/secrets/pigeon_daemon_auth_token}"
      if [ -r "$TOKEN_FILE" ]; then
        PIGEON_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
        PIGEON_TOKEN="$(printf '%s' "$PIGEON_TOKEN" | tr -d '[:space:]')"
      fi
    fi
    AUTH_HEADER=()
    if [ -n "$PIGEON_TOKEN" ]; then
      AUTH_HEADER=(-H "Authorization: Bearer $PIGEON_TOKEN")
    fi

    # Security / Architecture note (roadmap item 9.2 / dx8p Stage 1):
    # Call-time token resolution resolves PIGEON_DAEMON_AUTH_TOKEN / PIGEON_DAEMON_AUTH_TOKEN_FILE
    # and sends Bearer auth if available. A 401 Unauthorized response indicates a misconfigured
    # or missing token and is explicitly logged as an ERROR to stderr.

    HTTP_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
      -X POST http://127.0.0.1:4731/alert \
      -H 'content-type: application/json' \
      ''${AUTH_HEADER[@]+"''${AUTH_HEADER[@]}"} \
      -d "$PAYLOAD")
    CURL_EXIT=$?

    case "$HTTP_STATUS" in
      2*)
        mkdir -p "$(dirname "$STATE_FILE")"
        # v2 state: signature, alerts-sent-this-episode, epoch of the first alert. Rewriting
        # resets mtime, which is what the next backoff interval is measured from.
        printf '%s\n%s\n%s\n' "$SIGNATURE" "$NEXT_COUNT" "$FIRST_ALERT" > "$STATE_FILE"
        ;;
      401)
        echo "ERROR: opencode-drift-alert: 401 Unauthorized from pigeon /alert (token missing or rejected)" >&2
        ;;
      *)
        echo "WARNING: opencode-drift-alert: failed to send alert to pigeon (curl_exit=$CURL_EXIT, http_status=$HTTP_STATUS)" >&2
        ;;
    esac

    exit 0
''
