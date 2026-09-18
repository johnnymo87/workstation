#!/usr/bin/env bash
# Hold the IdP session open with one authenticated read every ~90 min.
#
# Why this exists alongside the 8-hourly refresh: the two sessions that matter
# have very different lifetimes. Google's session in the isolated profile is
# long-lived and carries most refreshes on its own. The IdP session has a 2-hour
# IDLE timeout and is needed only when Google decides to re-federate -- so an
# 8-hourly refresh cannot keep it warm, and a refresh that happens to need it
# would find it gone. One read every 90 minutes resets the idle clock.
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
    if ! /usr/bin/osascript \
        -e "display notification \"$detail\" with title \"IdP session needs you\" subtitle \"$outcome\"" \
        >/dev/null 2>"$STATE/osascript.err"; then
      echo "WARNING: could not post notification: $(cat "$STATE/osascript.err" 2>/dev/null)" >&2
    fi
  fi
}

if ! timeout 10 curl -sf "$CDP_URL/json/version" -o /dev/null 2>/dev/null; then
  # The old version treated this as success. It is not: the isolated browser is
  # supposed to be running, and while it is not, the IdP session is silently
  # ageing out toward a state only a human can fix.
  record "cdp_unreachable" "Isolated Chrome is not listening on $CDP_URL; the IdP session is ageing out" yes
  exit 1
fi

# stdout only: the probe prints its JSON verdict there, and folding stderr in
# would hand unparseable noise to the reader below.
out="$(IDP_LOG="$STATE/idp-session.jsonl" IDP_SESSION_PATH="$SESSION_PATH" \
       REAUTH_CDP_URL="$CDP_URL" \
       timeout 120 "$NODE" "$LIB/idp-session-probe.mjs" "$ORIGIN" 2>/dev/null)"
probe_rc=$?

if [ "$probe_rc" -ne 0 ]; then
  record "probe_failed" "IdP session probe exited $probe_rc" yes
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
has = row.get("has_session")
secs = row.get("seconds_remaining")
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
    record "no_session" "No IdP session in the isolated browser. Sign in there; the reauth cannot run without it." yes
    exit 1
    ;;
  *)
    record "unparseable" "Could not read the probe's verdict" yes
    exit 1
    ;;
esac
