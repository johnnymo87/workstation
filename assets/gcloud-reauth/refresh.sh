#!/usr/bin/env bash
# Refresh the REMOTE host's gcloud credentials, driven from this Mac.
#
# TWO CREDENTIALS, TWO LOGINS. The remote keeps two independent user
# credentials, and the org's session-control policy kills each separately:
#   cli  `gcloud auth login`                     -> ~/.config/gcloud/credentials.db
#   adc  `gcloud auth application-default login` -> application_default_credentials.json
# The gcloud CLI uses the first. Anything built on Google's client libraries --
# opencode's Vertex providers, most importantly -- uses the second. Refreshing
# only the CLI credential left every opencode session on the remote failing
# with invalid_grant/invalid_rapt (2026-10-15 ~02:40Z) while this job was green.
# Each credential gets its own login, its own verification, its own jsonl row
# and its own notification, so one can never hide the other.
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
# So each login runs on the remote host, holding its own PKCE state, and this
# Mac performs only the browser half. No credential crosses the link: what
# travels is a public auth URL one way, and a single-use authorization code
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

# Writing the code to fd 3 after the remote session has died would otherwise
# raise SIGPIPE and kill this script mid-flight -- silently, before it could log
# or notify. Ignore it so the write merely fails and we handle it below.
trap '' PIPE

REMOTE="${REAUTH_REMOTE:?set REAUTH_REMOTE to the remote ssh host alias}"
CDP_URL="${REAUTH_CDP_URL:-http://127.0.0.1:9223}"
LIB="${REAUTH_HARNESS_DIR:-$HOME/.local/lib/gcloud-reauth}"
STATE="${REAUTH_STATE_DIR:-$HOME/.local/state/gcloud-reauth}"
NODE="${REAUTH_NODE:-node}"
LOG="$STATE/refresh.jsonl"
WORK="$STATE/run"

mkdir -p "$STATE" "$WORK"

# The two agents' intervals (8h and 90m) share a period of exactly 24h, so once
# a day they fire in the same second. The refresh closes IdP tabs as it starts,
# which would make a concurrent keepalive probe report a session that is
# actually fine as missing -- a false "go and sign in" notification. mkdir is
# the atomic primitive here; macOS has no flock(1).
LOCK="$STATE/reauth.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # Stale lock from a killed run should not wedge the refresher forever.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || true
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The credentials this run is responsible for, in order. CLI first: it is the
# older flow and its failure modes are the better understood.
CREDENTIALS=(cli adc)

# --- logging and notification ----------------------------------------------
# Every credential this run is responsible for gets exactly one row, on every
# path -- "quietly did nothing" is not reachable. Any outcome other than
# `refreshed` also raises a notification of its own. The failure this replaces
# ran green on a timer for ~14 hours while the credential was dead, and then
# ran green again while the OTHER credential was dead.
record() {
  local cred="$1" outcome="$2" detail="${3:-}"
  python3 - "$LOG" "$started_at" "$cred" "$outcome" "$detail" <<'PY'
import json, sys, datetime
log, started, cred, outcome, detail = sys.argv[1:6]
with open(log, "a") as f:
    f.write(json.dumps({
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "started_at": started,
        "task": "refresh",
        "credential": cred,
        "outcome": outcome,
        "detail": detail or None,
    }) + "\n")
PY
  LAST_OUTCOME="$outcome"
  echo "credential=$cred outcome=$outcome ${detail:+detail=$detail}"
  if [ "$outcome" != refreshed ]; then
    notify "$cred" "$outcome" "$detail"
    failed=yes
  fi
}

notify() {
  local cred="$1" outcome="$2" detail="$3"
  # Through argv, not interpolated into the AppleScript source: a detail
  # containing a double quote would otherwise break the script and lose the
  # notification -- the one signal a human sees.
  # Do not swallow osascript's own failure: if notifications are denied this
  # is the only human-facing signal, and losing it silently is the bug.
  if ! /usr/bin/osascript \
      -e 'on run argv' \
      -e 'display notification (item 3 of argv) with title ("gcloud reauth needs you (" & item 1 of argv & ")") subtitle (item 2 of argv)' \
      -e 'end run' \
      "$cred" "$outcome" "$detail" \
      >/dev/null 2>"$STATE/osascript.err"; then
    echo "WARNING: could not post notification: $(cat "$STATE/osascript.err" 2>/dev/null)" >&2
  fi
}

failed=no
LAST_OUTCOME=""

# A failure before any login starts applies to every credential: record it once
# per credential, so neither row stream ever has a silent gap, then stop.
fail_all() {
  local outcome="$1" detail="$2" cred
  for cred in "${CREDENTIALS[@]}"; do record "$cred" "$outcome" "$detail"; done
  exit 1
}

# --- preflight: the local browser ------------------------------------------
# A refresh cannot work without the isolated Chrome, and finding that out after
# starting a login on the remote host would leave a dangling flow there.
# Retried for ~90s: the gcloud-reauth-chrome agent respawns a dead browser within
# its 60s ThrottleInterval, and a timer that lands in that gap should wait it
# out rather than notify a human about a problem that is fixing itself.
cdp_up=no
for _ in 1 2 3 4 5 6; do
  if timeout 10 curl -sf "$CDP_URL/json/version" -o /dev/null 2>/dev/null; then
    cdp_up=yes; break
  fi
  sleep 15
done
if [ "$cdp_up" != yes ]; then
  fail_all "cdp_unreachable" "Isolated Chrome is not listening on $CDP_URL; check the gcloud-reauth-chrome agent (~/Library/Logs/gcloud-reauth-chrome.err.log)"
fi

# --- preflight: which account the browser should pick ----------------------
# Both logins are for the same user, and both pages show the same account
# chooser. Read once, before any remote login is started.
SPIKE_ACCOUNT="$(timeout 30 ssh -o ClearAllForwardings=yes "$REMOTE" \
  'gcloud config get-value account' 2>/dev/null | tr -d '\r')"
if [ -z "$SPIKE_ACCOUNT" ]; then
  fail_all "error" "Could not read the remote gcloud account"
fi

# --- the remote half of each login -----------------------------------------
# Both are run by the remote user's login shell. Single-quoted here: every $
# is the REMOTE's to expand.
LOGIN_CMD_CLI='gcloud auth login --no-launch-browser'

# The ADC file carries a quota_project_id, which the Vertex calls bill against.
# The login rewrites the whole file, and gcloud 537's `application-default
# login` has no --quota-project flag: left alone it GUESSES one from the CLI
# config (and silently writes none if the account lacks permission on it).
# Correct today, but nothing pins it. So: log in with --disable-quota-project,
# then put back exactly the value the file had before, and confirm it stuck.
#
# It also proves the login actually replaced the credential: a fingerprint of
# the refresh token before and after must differ. print-access-token alone
# succeeds just as well from an old credential that has not died YET, which is
# exactly the state this job exists to get ahead of; and a file mtime is
# satisfied by any unrelated rewrite (set-quota-project itself is one).
#
# Only marker lines reach this Mac; the project id and the token stay remote.
# Not exec'd: the steps after the login are the point.
# shellcheck disable=SC2016  # expanded by the remote shell, deliberately
LOGIN_CMD_ADC='f="$HOME/.config/gcloud/application_default_credentials.json"
fp() { jq -r ".refresh_token // empty" "$f" 2>/dev/null | sha256sum | cut -c1-16; }
qp="$(jq -r ".quota_project_id // empty" "$f" 2>/dev/null)"
before="$(fp)"
gcloud auth application-default login --no-launch-browser --disable-quota-project || exit $?
if [ "$(fp)" != "$before" ]; then echo "gcloud-reauth: rotated=yes"; else echo "gcloud-reauth: rotated=no"; fi
if [ -z "$qp" ]; then echo "gcloud-reauth: quota_project=none"; exit 0; fi
gcloud auth application-default set-quota-project "$qp" >/dev/null 2>&1
if [ "$(jq -r ".quota_project_id // empty" "$f" 2>/dev/null)" = "$qp" ]; then
  echo "gcloud-reauth: quota_project=kept"
else
  echo "gcloud-reauth: quota_project=lost"
fi'

# Verification runs a SEPARATE remote command, after the login process has
# exited, and asks gcloud to mint a token from what is now on disk. That is the
# only evidence that matters; the login's own exit code is not.
VERIFY_CMD_CLI='gcloud auth print-access-token >/dev/null 2>&1 && echo ok || echo token_failed'

# (That the ADC login really replaced the credential is proven by the login
# wrapper's own rotated= marker above, checked in step 5.)
VERIFY_CMD_ADC='gcloud auth application-default print-access-token >/dev/null 2>&1 && echo ok || echo token_failed'

# --- one credential, end to end --------------------------------------------
# Never exits: every path ends in exactly one `record` for $cred.
GPID=""
abort_remote() {
  [ -n "$GPID" ] && kill "$GPID" 2>/dev/null
  exec 3>&- 2>/dev/null
  [ -n "$GPID" ] && wait "$GPID" 2>/dev/null
  GPID=""
}

refresh_one() {
  local cred="$1" login_cmd verify_cmd dir answered=0 prompts node_rc reason verdict qp_mode
  case "$cred" in
    cli) login_cmd="$LOGIN_CMD_CLI"; verify_cmd="$VERIFY_CMD_CLI" ;;
    adc) login_cmd="$LOGIN_CMD_ADC"; verify_cmd="$VERIFY_CMD_ADC" ;;
    *) record "$cred" "error" "refresh.sh does not know credential '$cred'"; return ;;
  esac

  # Per-credential workdir, so the second flow cannot read the first one's
  # code, URL or result -- and both runs' artifacts survive for debugging.
  dir="$WORK/$cred"
  mkdir -p "$dir"
  rm -f "$dir"/authfifo "$dir"/authcode.txt "$dir"/gcloud-login.log "$dir"/e2e-url.txt "$dir"/e2e-result.json
  if ! mkfifo "$dir/authfifo"; then
    record "$cred" "error" "cannot create fifo in $dir"; return
  fi

  # 1. Start the remote login, holding stdin open. The fifo is what keeps the
  # remote gcloud alive between printing its URL and receiving the code. ssh
  # forwards our stdin to it; -T because no pty is needed (verified: the URL
  # still arrives promptly, ~5-13s).
  timeout 300 ssh -T -o ClearAllForwardings=yes "$REMOTE" "$login_cmd" \
    < "$dir/authfifo" > "$dir/gcloud-login.log" 2>&1 &
  GPID=$!
  exec 3>"$dir/authfifo"

  # 2. Answer confirmation prompts AS THEY APPEAR, then read the auth URL.
  # On a GCE VM both logins first ask "You are running on a Google Compute
  # Engine virtual machine ... Do you want to continue (Y/n)?" and print the
  # URL only once it is answered (observed 2026-10-15, gcloud 537.0.0; neither
  # asked an "already authenticated" question). Answering blind is wrong in
  # both directions: on a host that does not ask, a pre-sent "Y" sits in the
  # pipe and is read as the AUTH CODE, failing the flow. So reply only to a
  # prompt actually seen, and at most twice -- more than that is not the flow
  # this script knows, and it should stop rather than keep agreeing.
  local url_seen=no
  for _ in $(seq 1 60); do
    if grep -qo 'https://accounts.google.com[^ ]*' "$dir/gcloud-login.log" 2>/dev/null; then
      url_seen=yes; break
    fi
    prompts="$(grep -cF '(Y/n)?' "$dir/gcloud-login.log" 2>/dev/null)"
    if [ "${prompts:-0}" -gt "$answered" ] && [ "$answered" -lt 2 ]; then
      printf 'Y\n' >&3
      answered=$((answered + 1))
    fi
    sleep 1
  done
  grep -o 'https://accounts.google.com[^ ]*' "$dir/gcloud-login.log" | head -1 > "$dir/e2e-url.txt"
  if [ "$url_seen" != yes ] || [ ! -s "$dir/e2e-url.txt" ]; then
    abort_remote
    record "$cred" "no_auth_url" "Remote gcloud never printed an auth URL in 60s (answered $answered prompt(s)); see $dir/gcloud-login.log"
    return
  fi

  # 3. Drive the LOCAL browser. e2e.mjs validates the URL against THIS flow's
  # exact allowlist before navigating (untrusted: it came from the remote
  # host), clicks only account-selection and consent, and halts on any
  # credential prompt rather than answering it.
  REAUTH_FLOW="$cred" \
  SPIKE_ACCOUNT="$SPIKE_ACCOUNT" \
  REAUTH_WORKDIR="$dir" \
  REAUTH_CDP_URL="$CDP_URL" \
  REAUTH_SHOTS="$STATE/shots/$cred" \
  GCLOUD_REAUTH_PROBE_LOG="$STATE/reauth-probe.jsonl" \
    timeout 200 "$NODE" "$LIB/e2e.mjs" "$dir/e2e-url.txt"
  node_rc=$?

  # 4. Hand the code back to the SAME still-open remote session.
  if [ ! -s "$dir/authcode.txt" ]; then
    abort_remote
    case "$node_rc" in
      3) record "$cred" "url_rejected" "Remote offered an auth URL that failed validation; refused to navigate"; return ;;
      4) record "$cred" "error" "e2e.mjs refused to run: bad REAUTH_FLOW"; return ;;
    esac
    reason="$(python3 -c '
import json,sys
try:
    print(json.load(open(sys.argv[1])).get("outcome") or "unknown")
except Exception:
    print("unknown")' "$dir/e2e-result.json" 2>/dev/null)"
    case "$reason" in
      idp_login_required|password_demanded|mfa_demanded|bot_blocked)
        record "$cred" "human_required" "Browser flow stopped at: $reason. The sign-in page is open and raised." ;;
      *)
        record "$cred" "no_authcode" "Browser flow ended without a code (outcome: $reason)" ;;
    esac
    return
  fi
  if ! { cat "$dir/authcode.txt" >&3 && echo "" >&3; }; then
    abort_remote
    record "$cred" "code_delivery_failed" "Obtained a code but the remote session was gone before it could be delivered"
    return
  fi
  # The code is single-use and now spent; do not leave it lying around.
  rm -f "$dir/authcode.txt"
  exec 3>&-
  wait "$GPID" 2>/dev/null
  GPID=""

  # 5. Verify, rather than trust the exit code.
  verdict="$(timeout 60 ssh -o ClearAllForwardings=yes "$REMOTE" "$verify_cmd" \
    2>/dev/null | tr -d '\r' | tail -1)"
  if [ "$cred" = adc ] && [ "$verdict" = ok ]; then
    grep -q '^gcloud-reauth: rotated=yes' "$dir/gcloud-login.log" || verdict=file_not_rewritten
  fi
  if [ "$cred" = adc ] && [ "$verdict" = ok ]; then
    qp_mode="$(grep -o 'gcloud-reauth: quota_project=[a-z]*' "$dir/gcloud-login.log" | tail -1 | sed 's/.*=//')"
    case "$qp_mode" in
      kept|none) ;;
      lost) verdict=quota_project_lost ;;
      *) verdict=quota_project_unknown ;;
    esac
  fi
  case "$verdict" in
    ok) record "$cred" "refreshed" "Remote $cred credential is live and freshly minted" ;;
    file_not_rewritten)
      record "$cred" "verify_failed" "Login reported no error but the remote ADC refresh token did not change; see $dir/gcloud-login.log" ;;
    quota_project_lost)
      record "$cred" "verify_failed" "ADC is live but its previous quota_project_id could not be restored; Vertex calls may bill elsewhere or be refused. Run: gcloud auth application-default set-quota-project <project> on the remote" ;;
    quota_project_unknown)
      record "$cred" "verify_failed" "ADC is live but the remote login wrapper never reported its quota project step; see $dir/gcloud-login.log" ;;
    *)
      record "$cred" "verify_failed" "Login reported no error but the remote still cannot mint a $cred token (verdict: ${verdict:-none}); see $dir/gcloud-login.log" ;;
  esac
}

# --- run every credential ---------------------------------------------------
# Both run even when the first fails: they are independent credentials with
# independent failure modes, and a CLI fault must not leave ADC unattempted.
# The one exception is a stop for a human at the shared IdP sign-in. The ADC
# flow would hit the same page in the same browser, and its first act is to
# close stale IdP tabs -- the very tab just raised for the human, possibly
# mid-typing. It still gets its own row and its own notification.
rm -f "$WORK"/authfifo "$WORK"/authcode.txt   # pre-ADC single-workdir layout
cli_outcome=""
for cred in "${CREDENTIALS[@]}"; do
  if [ "$cred" != cli ] && [ "$cli_outcome" = human_required ]; then
    record "$cred" "human_required" "Not attempted: the CLI login is waiting at the IdP sign-in. Sign in there, then run gcloud-reauth-refresh."
    continue
  fi
  refresh_one "$cred"
  if [ "$cred" = cli ]; then
    cli_outcome="$LAST_OUTCOME"
  fi
done

[ "$failed" = no ] && exit 0
exit 1
