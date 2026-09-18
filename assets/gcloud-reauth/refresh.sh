#!/usr/bin/env bash
# Refresh the REMOTE host's gcloud CLI credential, driven from this Mac.
#
# DIRECTION IS THE WHOLE POINT. The remote host used to reach INTO this Mac over
# a reverse tunnel to Chrome's DevTools port and drive the browser itself, which
# left an unauthenticated remote-control handle on a browser holding a live SSO
# session permanently reachable from a machine that runs agents with shell
# access. Here the Mac initiates everything and nothing is forwarded remotely.
#
# WHY THE LOGIN STILL RUNS REMOTELY. Two tempting shortcuts are both wrong:
#   - Minting the credential here and copying it over would clobber a
#     credentials.db holding several accounts, including service accounts.
#   - The flow is PKCE. The code_verifier lives in whichever gcloud process
#     produced the auth URL, so a code obtained for a URL generated here cannot
#     be redeemed there.
# So `gcloud auth login` runs on the remote host, holding its own PKCE state,
# and this Mac performs only the browser half. No credential crosses the link:
# what travels is a public auth URL one way, and a single-use authorization code
# the other.
#
# Required env (supplied by the launchd agent from Keychain):
#   REAUTH_REMOTE        ssh host alias of the remote machine
# Optional:
#   REAUTH_CDP_URL       default http://127.0.0.1:9223 (loopback ONLY)
#   REAUTH_HARNESS_DIR   default ~/.local/lib/gcloud-reauth
#   REAUTH_STATE_DIR     default ~/.local/state/gcloud-reauth
#   REAUTH_NODE          node binary (default: node from PATH)

set -uo pipefail

REMOTE="${REAUTH_REMOTE:?set REAUTH_REMOTE to the remote ssh host alias}"
CDP_URL="${REAUTH_CDP_URL:-http://127.0.0.1:9223}"
LIB="${REAUTH_HARNESS_DIR:-$HOME/.local/lib/gcloud-reauth}"
STATE="${REAUTH_STATE_DIR:-$HOME/.local/state/gcloud-reauth}"
NODE="${REAUTH_NODE:-node}"
LOG="$STATE/refresh.jsonl"
WORK="$STATE/run"

mkdir -p "$STATE" "$WORK"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Every exit path lands here, so "quietly did nothing" is not reachable: each
# run appends exactly one row, and the human-actionable outcomes also raise a
# notification. The failure this replaces ran green on a timer for ~14 hours
# while the credential was dead.
finish() {
  local outcome="$1" detail="${2:-}" notify="${3:-no}"
  python3 - "$LOG" "$started_at" "$outcome" "$detail" <<'PY'
import json, sys, datetime
log, started, outcome, detail = sys.argv[1:5]
with open(log, "a") as f:
    f.write(json.dumps({
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "started_at": started,
        "task": "refresh",
        "outcome": outcome,
        "detail": detail or None,
    }) + "\n")
PY
  echo "outcome=$outcome ${detail:+detail=$detail}"
  if [ "$notify" = "yes" ]; then
    # Do not swallow osascript's own failure: if notifications are denied this
    # is the only human-facing signal, and losing it silently is the bug.
    if ! /usr/bin/osascript \
        -e "display notification \"$detail\" with title \"gcloud reauth needs you\" subtitle \"$outcome\"" \
        >/dev/null 2>"$STATE/osascript.err"; then
      echo "WARNING: could not post notification: $(cat "$STATE/osascript.err" 2>/dev/null)" >&2
    fi
  fi
  case "$outcome" in
    refreshed) exit 0 ;;
    *) exit 1 ;;
  esac
}

# --- preflight: the local browser ------------------------------------------
# A refresh cannot work without the isolated Chrome, and finding that out after
# starting a login on the remote host would leave a dangling flow there.
if ! timeout 10 curl -sf "$CDP_URL/json/version" -o /dev/null 2>/dev/null; then
  finish "cdp_unreachable" "Isolated Chrome is not listening on $CDP_URL; start it and re-run" yes
fi

# --- 1. start the remote login, holding stdin open --------------------------
# The fifo is what keeps the remote gcloud alive between printing its URL and
# receiving the code. ssh forwards our stdin to it; -T because no pty is needed
# (verified: the URL still arrives promptly, ~13s).
cd "$WORK" || finish "error" "cannot enter $WORK"
rm -f authfifo authcode.txt gcloud-login.log e2e-url.txt e2e-result.json
mkfifo authfifo || finish "error" "cannot create fifo"

timeout 300 ssh -T -o ClearAllForwardings=yes "$REMOTE" \
  'gcloud auth login --no-launch-browser' < authfifo > gcloud-login.log 2>&1 &
GPID=$!
exec 3>authfifo
printf 'Y\n' >&3     # answers "You are already authenticated ... continue (Y/n)?"

abort_remote() {
  kill "$GPID" 2>/dev/null
  exec 3>&- 2>/dev/null
  wait "$GPID" 2>/dev/null
}

# --- 2. read the auth URL off the remote session ----------------------------
for _ in $(seq 1 60); do
  grep -qo 'https://accounts.google.com[^ ]*' gcloud-login.log 2>/dev/null && break
  sleep 1
done
grep -o 'https://accounts.google.com[^ ]*' gcloud-login.log | head -1 > e2e-url.txt
if [ ! -s e2e-url.txt ]; then
  abort_remote
  finish "no_auth_url" "Remote gcloud never printed an auth URL in 60s" yes
fi

# --- 3. drive the LOCAL browser ---------------------------------------------
# e2e.mjs validates the URL before navigating (untrusted: it came from the
# remote host), clicks only account-selection and consent, and halts on any
# credential prompt rather than answering it.
SPIKE_ACCOUNT="$(timeout 30 ssh -o ClearAllForwardings=yes "$REMOTE" \
  'gcloud config get-value account' 2>/dev/null | tr -d '\r')"
if [ -z "$SPIKE_ACCOUNT" ]; then
  abort_remote
  finish "error" "Could not read the remote gcloud account" yes
fi

SPIKE_ACCOUNT="$SPIKE_ACCOUNT" \
REAUTH_WORKDIR="$WORK" \
REAUTH_CDP_URL="$CDP_URL" \
REAUTH_SHOTS="$STATE/shots" \
GCLOUD_REAUTH_PROBE_LOG="$STATE/reauth-probe.jsonl" \
  timeout 200 "$NODE" "$LIB/e2e.mjs" "$WORK/e2e-url.txt"
NODE_RC=$?

# --- 4. hand the code back to the SAME still-open remote session ------------
if [ -s authcode.txt ]; then
  cat authcode.txt >&3
  echo "" >&3
  exec 3>&-
  wait "$GPID" 2>/dev/null
else
  abort_remote
  case "$NODE_RC" in
    3) finish "url_rejected" "Remote offered an auth URL that failed validation; refused to navigate" yes ;;
  esac
  reason="$(python3 -c '
import json,sys
try:
    print(json.load(open(sys.argv[1])).get("outcome") or "unknown")
except Exception:
    print("unknown")' "$WORK/e2e-result.json" 2>/dev/null)"
  case "$reason" in
    idp_login_required|password_demanded|mfa_demanded|bot_blocked)
      finish "human_required" "Browser flow stopped at: $reason. The sign-in page is open and raised." yes ;;
    *)
      finish "no_authcode" "Browser flow ended without a code (outcome: $reason)" yes ;;
  esac
fi

# --- 5. verify, rather than trust the exit code -----------------------------
if timeout 60 ssh -o ClearAllForwardings=yes "$REMOTE" \
     'gcloud auth print-access-token' >/dev/null 2>&1; then
  finish "refreshed" "Remote credential is live"
fi
finish "verify_failed" "Login reported no error but the remote still cannot mint a token" yes
