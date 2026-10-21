#!/usr/bin/env bash
# Hold the IdP session open with one authenticated read every hour.
#
# Why this exists alongside the refresh: the two sessions that matter
# have very different lifetimes. Google's session in the isolated profile is
# long-lived and carries most refreshes on its own. The IdP session has a 2-hour
# IDLE timeout and is needed only when Google decides to re-federate -- so a
# refresh every few hours cannot keep it warm, and a refresh that happens to need it
# would find it gone. One read every hour resets the idle clock.
#
# It cannot REVIVE a lapsed session. Any gap longer than the idle timeout (lid
# closed overnight, Chrome not running) needs a human to sign in at the IdP in
# the isolated Chrome. Saying so loudly is the entire point of the exit paths
# below.
#
# THE BUG THIS IS A REWRITE OF: the previous version exited 0 when the browser
# was unreachable and discarded the probe's output entirely. It therefore ran
# "successfully" on schedule against an empty cookie jar all night while the
# credential it was protecting was dead, and nothing anywhere said so. An
# automation whose failure mode is a green checkmark is worse than none, because
# the human stops checking.
#
# Required env (supplied by the launchd agent from Keychain):
#   IDP_ORIGIN, IDP_SESSION_PATH
# Optional:
#   REAUTH_CDP_URL, REAUTH_HARNESS_DIR, REAUTH_STATE_DIR, REAUTH_NODE

set -uo pipefail

ORIGIN="${IDP_ORIGIN:?set IDP_ORIGIN to the IdP origin}"
SESSION_PATH="${IDP_SESSION_PATH:?set IDP_SESSION_PATH to the IdP session endpoint path}"
CDP_URL="${REAUTH_CDP_URL:-http://127.0.0.1:9223}"
LIB="${REAUTH_HARNESS_DIR:-$HOME/.local/lib/gcloud-reauth}"
STATE="${REAUTH_STATE_DIR:-$HOME/.local/state/gcloud-reauth}"
NODE="${REAUTH_NODE:-node}"
LOG="$STATE/keepalive.jsonl"

# --- telling the human --------------------------------------------------------
# A MODAL ALERT, not a notification. `display notification` from osascript
# posts as Script Editor, which on this Mac has no Notification Center
# registration at all -- so every notification these scripts sent was silently
# dropped, with osascript exiting 0. Nobody saw 46 "sign in" notifications over
# 2026-10-17..21, and the credentials were kept alive by hand meanwhile. An
# alert needs no registration and stays on screen until answered.
#
# Runs in the background so this script carries on (or exits); the agents set
# AbandonProcessGroup so launchd does not kill it when they do. At most one is
# on screen at a time: a new one is skipped while the last is unanswered.
# "Open sign-in page" raises the IdP sign-in in the isolated Chrome. Unanswered
# alerts give up after 50 min, so the hourly runs re-ask rather than pile up.
# (Same as refresh.sh, which explains it.)
# Usage: alert_human <title> <message> [signin]
alert_human() {
  local title="$1" message="$2" signin="${3:-}" pidf="$STATE/alert.pid" pid
  pid="$(cat "$pidf" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "alert already on screen (pid $pid); not stacking another"
    return
  fi
  (
    if [ "$signin" = signin ]; then
      ans="$(/usr/bin/osascript \
        -e 'on run argv' \
        -e 'set r to display alert (item 1 of argv) message (item 2 of argv) as critical buttons {"Later", "Open sign-in page"} default button 2 giving up after 3000' \
        -e 'if gave up of r then return "gave up"' \
        -e 'return button returned of r' \
        -e 'end run' "$title" "$message" 2>&1)"
    else
      ans="$(/usr/bin/osascript \
        -e 'on run argv' \
        -e 'set r to display alert (item 1 of argv) message (item 2 of argv) as critical buttons {"OK"} default button 1 giving up after 3000' \
        -e 'if gave up of r then return "gave up"' \
        -e 'return button returned of r' \
        -e 'end run' "$title" "$message" 2>&1)"
    fi
    echo "$(date -u +%FT%TZ) alert [$title] answered: $ans"
    if [ "$ans" = "Open sign-in page" ]; then
      IDP_ORIGIN="${IDP_ORIGIN:-}" REAUTH_CDP_URL="$CDP_URL" \
        timeout 60 "$NODE" "$LIB/raise-signin.mjs"
    fi
  ) </dev/null >>"$STATE/alert.log" 2>&1 &
  echo $! > "$pidf"
}

mkdir -p "$STATE"

record() {
  local outcome="$1" detail="${2:-}" notify="${3:-no}"
  python3 - "$LOG" "$outcome" "$detail" <<'PY'
import json, sys, datetime
log, outcome, detail = sys.argv[1:4]
with open(log, "a") as f:
    f.write(json.dumps({
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "task": "keepalive",
        "outcome": outcome,
        "detail": detail or None,
    }) + "\n")
PY
  echo "outcome=$outcome ${detail:+detail=$detail}"
  if [ "$notify" = "yes" ]; then
    alert_human "gcloud reauth keepalive: $outcome" "$detail"
  fi
}

# Wait for a FULL wake before touching the browser: a calendar job missed
# during sleep fires on the next wake, which may be a DarkWake (Power Nap) with
# no display and seconds of network. Same block as refresh.sh, which explains it.
full_wake() {
  local caps
  caps="$(/usr/sbin/ioreg -c IOPMrootDomain -r -d1 2>/dev/null \
    | sed -n 's/.*"System Capabilities" = \([0-9]*\).*/\1/p' | head -1)"
  [ -z "$caps" ] || [ $(( caps & 2 )) -ne 0 ]
}
for _ in $(seq 1 2880); do full_wake && break; sleep 30; done

# Defer to a refresh in progress: it drives the same browser and closes IdP
# tabs, and it pokes the IdP session itself, so skipping is correct rather than
# merely safe -- but only once it has had a chance to finish. TAKE the lock
# rather than only checking for it: both agents fire together on wake, and a
# check-then-probe would race the refresh's tab cleanup. Wait up to 5 min first:
# a browser refresh takes ~80s and usually never touches the IdP, so skipping
# on sight would cost this run's slot, and after a 1-2h lid-closed gap that is
# the difference between a warm session and a dead one. A refresh still
# holding it after 5 min is in its wait-for-sign-in loop, which probes the IdP
# every 20s itself.
LOCK="$STATE/reauth.lock"
have_lock=no
for _ in $(seq 1 60); do
  if mkdir "$LOCK" 2>/dev/null; then have_lock=yes; break; fi
  sleep 5
done
if [ "$have_lock" != yes ]; then
  record "skipped" "A refresh has held the lock for 5 min (waiting for a sign-in); it probes the IdP session itself meanwhile"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Retried for ~90s to ride out the gcloud-reauth-chrome agent's respawn gap
# (60s ThrottleInterval); see refresh.sh.
cdp_up=no
for _ in 1 2 3 4 5 6; do
  if timeout 10 curl -sf "$CDP_URL/json/version" -o /dev/null 2>/dev/null; then
    cdp_up=yes; break
  fi
  sleep 15
done
if [ "$cdp_up" != yes ]; then
  # The old version treated this as success. It is not: the isolated browser is
  # supposed to be running, and while it is not, the IdP session is silently
  # ageing out toward a state only a human can fix.
  record "cdp_unreachable" "Isolated Chrome is not listening on $CDP_URL; the IdP session is ageing out" yes
  exit 1
fi

# stdout only: the probe prints its JSON verdict there, and folding stderr in
# would hand unparseable noise to the reader below. stderr goes to a file rather
# than /dev/null so a crash that never reaches the verdict -- a missing harness
# file, a puppeteer/Chrome mismatch -- is diagnosable. Discarding it produced a
# bare "exited 1" with no clue that the cause was ERR_MODULE_NOT_FOUND.
probe_err="$STATE/probe.err"
out="$(IDP_LOG="$STATE/idp-session.jsonl" IDP_SESSION_PATH="$SESSION_PATH" \
       REAUTH_CDP_URL="$CDP_URL" \
       timeout 120 "$NODE" "$LIB/idp-session-probe.mjs" "$ORIGIN" 2>"$probe_err")"
probe_rc=$?

if [ "$probe_rc" -ne 0 ]; then
  why="$(tail -1 "$probe_err" 2>/dev/null)"
  record "probe_failed" "IdP session probe exited $probe_rc${why:+: $why}" yes
  exit 1
fi

# Read the probe's own verdict rather than inferring health from its exit code.
verdict="$(python3 - <<'PY' "$out"
import json, sys
try:
    row = json.loads(sys.argv[1])
except Exception:
    print("unparseable|")
    raise SystemExit
# An exception inside the probe leaves has_session null with an error set.
# Mapping that to "no_session" would tell the human to go and sign in when the
# real problem was a navigation timeout -- a wrong instruction is worse than a
# vague one, because it burns the trust the notification depends on.
err = row.get("error")
has = row.get("has_session")
secs = row.get("seconds_remaining")
if err or has is None:
    print(f"probe_error|{err or 'probe returned no verdict'}")
else:
    print(f"{'ok' if has else 'no_session'}|{secs if secs is not None else ''}")
PY
)"
state="${verdict%%|*}"
secs="${verdict##*|}"

case "$state" in
  ok)
    record "held" "IdP session live${secs:+, ${secs}s remaining}"
    ;;
  no_session)
    # Quiet: the refresh asks for the sign-in, with an alert, when a refresh is
    # actually due and needs it. Asking here too would be a second, hourly
    # prompt for the same thing -- and usually hours before it matters.
    record "no_session" "No IdP session in the isolated browser; the refresh will ask for a sign-in when it needs one."
    exit 1
    ;;
  probe_error)
    record "probe_error" "Could not read the IdP session: $secs" yes
    exit 1
    ;;
  *)
    record "unparseable" "Could not read the probe's verdict" yes
    exit 1
    ;;
esac
