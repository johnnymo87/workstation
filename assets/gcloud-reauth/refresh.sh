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
# and its own alert, so one can never hide the other.
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
#   IDP_ORIGIN, IDP_SESSION_PATH
#                        enable the IdP session checks below (the agent sets
#                        both); without them every due run goes to the browser
#   REAUTH_REFRESH_AFTER_SECONDS   default 21600 (6h); see "which credentials"
#   REAUTH_HUMAN_WAIT_SECONDS      default 900; see "waiting for a human"
#
# Usage: gcloud-reauth-refresh [--force]
#   --force   refresh every credential now, however recently it was refreshed
#             ($STATE/refresh-requested, written by the keepalive's last-chance
#             check, has the same effect once)
#
# SCHEDULE. The agent fires hourly on a calendar interval, and this script
# decides whether anything is due. It used to fire on an 8h StartInterval, which
# on this Mac counts only AWAKE time and does not catch up after sleep: on
# 2026-10-15 a laptop that slept overnight and napped through the day went 16h
# without a run, the CLI credential died, and a human re-authed by hand. A
# calendar job does fire on wake (once, however many slots were missed), and an
# hourly check that usually says `not_due` costs one log row.

set -uo pipefail

# Writing the code to fd 3 after the remote session has died would otherwise
# raise SIGPIPE and kill this script mid-flight -- silently, before it could log
# or notify. Ignore it so the write merely fails and we handle it below.
trap '' PIPE
have_lock=no

REMOTE="${REAUTH_REMOTE:?set REAUTH_REMOTE to the remote ssh host alias}"
CDP_URL="${REAUTH_CDP_URL:-http://127.0.0.1:9223}"
LIB="${REAUTH_HARNESS_DIR:-$HOME/.local/lib/gcloud-reauth}"
STATE="${REAUTH_STATE_DIR:-$HOME/.local/state/gcloud-reauth}"
NODE="${REAUTH_NODE:-node}"
LOG="$STATE/refresh.jsonl"
WORK="$STATE/run"

mkdir -p "$STATE" "$WORK"

FORCE=no
[ "${1:-}" = --force ] && FORCE=yes
# A one-shot force requested by the keepalive's last-chance check (the IdP
# session is about to hit its hard cap). Consumed here so it fires once.
if [ -f "$STATE/refresh-requested" ]; then
  echo "last-chance refresh requested (IdP session expires $(cat "$STATE/refresh-requested" 2>/dev/null))"
  rm -f "$STATE/refresh-requested"
  FORCE=yes
fi

# --- wait out a dark wake ---------------------------------------------------
# A calendar job that comes due while the Mac sleeps fires on the next wake --
# and that may be a DarkWake (Power Nap): no display, network up for a few
# seconds, then sleep again with this process frozen mid-login. That would end
# in a dead ssh session and a spurious notification. So wait for a FULL wake,
# which the kernel reports as the graphics bit (2) in System Capabilities.
# While asleep this loop is frozen along with everything else, so in practice
# it resumes when the human opens the lid. Before the lock, deliberately: a
# run parked here must not block the keepalive or a manual run.
# Bounded at 24h of awake polling; an unreadable ioreg counts as awake.
# (Same block in keepalive.sh.)
full_wake() {
  local caps
  caps="$(/usr/sbin/ioreg -c IOPMrootDomain -r -d1 2>/dev/null \
    | sed -n 's/.*"System Capabilities" = \([0-9]*\).*/\1/p' | head -1)"
  [ -z "$caps" ] || [ $(( caps & 2 )) -ne 0 ]
}
for _ in $(seq 1 2880); do full_wake && break; sleep 30; done

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Every credential this job manages, in order. CLI first: it is the older flow
# and its failure modes are the better understood. CREDENTIALS, below, is the
# subset THIS run is responsible for.
ALL_CREDENTIALS=(cli adc)
CREDENTIALS=("${ALL_CREDENTIALS[@]}")

# --- logging and alerting --------------------------------------------------
# Every credential gets a row on every run, on every path -- "quietly did
# nothing" is not reachable, and that includes `not_due`. (A run that waits for
# a human and retries writes a second row for what it retried.) Any outcome
# other than the quiet ones below raises an alert. The failure this replaces
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
  case "$outcome" in
    refreshed|not_due|skipped) ;;
    # Already alerted when the failure happened; it retries by itself.
    backing_off) failed=yes ;;
    # The alert for these is raised once per run by the caller, not per row:
    # both credentials share one sign-in.
    human_required|waiting_for_human) failed=yes ;;
    *) alert_human "gcloud reauth failed ($cred): $outcome" "$detail"; failed=yes ;;
  esac
}

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
# on screen per kind (sign-in / other) at a time; a new one is skipped while
# the last of its kind is unanswered.
# "Open sign-in page" raises the IdP sign-in in the isolated Chrome. Unanswered
# alerts give up after 50 min, so the hourly runs re-ask rather than pile up.
# REAUTH_OSASCRIPT overrides osascript, for tests only.
# Usage: alert_human <title> <message> [signin|ok]
# Process start time, whitespace-normalised: ps pads lstart with trailing
# spaces, which `read` would strip from the stored copy.
started_at_of() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/ $//'; }

alert_human() {
  local title="$1" message="$2" kind="${3:-ok}" pidf pid start buttons
  [ "$kind" = signin ] || kind=ok
  # One slot per kind, so a routine failure alert can never hide the sign-in
  # prompt (or the reverse). The pid file stores pid AND start time: a pid
  # alone is reused within the hour on this Mac, and a stale file pointing at
  # some unrelated live process would suppress every alert, silently.
  pidf="$STATE/alert-$kind.pid"
  read -r pid start 2>/dev/null < "$pidf" || true
  if [ -n "${pid:-}" ] && [ "$(started_at_of "$pid")" = "${start:-}" ]; then
    echo "a $kind alert is already on screen (pid $pid); not stacking another"
    return
  fi
  if [ "$kind" = signin ]; then
    # No default and no cancel button: the alert takes keyboard focus when it
    # appears, and a Return or Esc meant for whatever the human was typing must
    # not answer it.
    buttons='{"Later", "Open sign-in page"}'
  else
    buttons='{"OK"} default button 1'
  fi
  (
    # osascript runs as a direct, recorded child so dismiss_signin_alert can
    # take exactly this alert down (a $(...) would hide it a level deeper).
    out="$(mktemp "$STATE/alert.XXXXXX")"
    "${REAUTH_OSASCRIPT:-/usr/bin/osascript}" \
      -e 'on run argv' \
      -e "set r to display alert (item 1 of argv) message (item 2 of argv) as critical buttons $buttons giving up after 3000" \
      -e 'if gave up of r then return "gave up"' \
      -e 'return button returned of r' \
      -e 'end run' "$title" "$message" > "$out" 2>&1 &
    opid=$!
    echo "$opid $(started_at_of "$opid")" > "$pidf"
    wait "$opid"
    ans="$(cat "$out")"; rm -f "$out"
    echo "$(date -u +%FT%TZ) alert [$title] answered: $ans"
    # Only clear the slot if it is still ours.
    read -r cur _ 2>/dev/null < "$pidf" && [ "$cur" = "$opid" ] && rm -f "$pidf"
    if [ "$ans" = "Open sign-in page" ]; then
      IDP_ORIGIN="${IDP_ORIGIN:-}" REAUTH_CDP_URL="$CDP_URL" \
        timeout 60 "$NODE" "$LIB/raise-signin.mjs"
    fi
  ) </dev/null >>"$STATE/alert.log" 2>&1 &
  # Claim the slot at once (the subshell re-records it as osascript's pid), so
  # two alerts raised back to back cannot both get through.
  pid=$!
  echo "$pid $(started_at_of "$pid")" > "$pidf"
}

# Take down a sign-in prompt that is no longer true (the refresh succeeded).
dismiss_signin_alert() {
  local pidf="$STATE/alert-signin.pid" pid start
  read -r pid start 2>/dev/null < "$pidf" || return 0
  if [ -n "${pid:-}" ] && [ "$(started_at_of "$pid")" = "${start:-}" ]; then
    kill "$pid" 2>/dev/null
  fi
  rm -f "$pidf"
}

failed=no
LAST_OUTCOME=""

# --- which credentials are due ----------------------------------------------
# Due = no `refreshed` row in the last REAUTH_REFRESH_AFTER_SECONDS. The
# session-control policy has killed these credentials ~16h after minting.
# 6h is a trade, not a derivation: each refresh drives a background tab for
# ~30s and is a chance to stop for a human; while the Mac is awake 6h gives two retries inside one lifetime. Across
# a night it cannot help -- a credential up to 6h old at lid-close dies after
# ~10h of sleep, and the morning run needs a human at the IdP anyway. A
# smaller value only moves that overnight death later, at the cost of more
# focus steals by day.
# Per credential: if ADC failed and CLI did not, the next run retries only ADC.
# Rows written before credentials were split out count as cli.
#
# BACKOFF. A failure that is not a human stop (verify_failed, no_authcode, a
# changed consent page...) usually fails the same way again, and each attempt
# steals focus and alerts. So after one, wait RETRY_AFTER before the next.
# Human stops are handled by the waiting gate below instead.
REFRESH_AFTER="${REAUTH_REFRESH_AFTER_SECONDS:-21600}"
RETRY_AFTER="${REAUTH_RETRY_AFTER_SECONDS:-7200}"
# Prints, per credential:
#   "<cred> <due|fresh|backoff> <age-seconds|never> <last-outcome> <since-last-attempt-seconds>"
cred_status() {
  python3 - "$LOG" "$REFRESH_AFTER" "$RETRY_AFTER" "${ALL_CREDENTIALS[@]}" <<'PY'
import json, sys, datetime
log, after, retry, creds = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
QUIET = ("not_due", "skipped", "backing_off")
HUMAN = ("human_required", "waiting_for_human")
last_ok, last_outcome, last_attempt = {}, {}, {}
parse = datetime.datetime.fromisoformat
try:
    lines = open(log).read().splitlines()
except FileNotFoundError:
    lines = []
for line in lines:
    # One bad row must not take the whole history down with it: that would
    # make everything look due, forever.
    try:
        r = json.loads(line)
        c = r.get("credential") or "cli"
        o = r.get("outcome")
        ts = parse(r["ts"])
        if o == "refreshed":
            last_ok[c] = ts
        if o not in QUIET:
            last_outcome[c] = o
            last_attempt[c] = ts
    except Exception:
        continue
now = datetime.datetime.now(datetime.timezone.utc)
for c in creds:
    ok = last_ok.get(c)
    age = int((now - ok).total_seconds()) if ok else None
    o = last_outcome.get(c) or "none"
    since = int((now - last_attempt[c]).total_seconds()) if c in last_attempt else 10**9
    if age is not None and age < after:
        state = "fresh"
    elif o not in ("refreshed", "none") + HUMAN and since < retry:
        state = "backoff"
    else:
        state = "due"
    print(c, state, "never" if age is None else age, o, since)
PY
}

CREDENTIALS=()
waiting_on_human=yes
status="$(cred_status)"
if [ "$(grep -c . <<<"$status")" -ne "${#ALL_CREDENTIALS[@]}" ]; then
  # Cannot tell what is due: treat everything as due rather than exit rowless.
  echo "WARNING: could not read refresh history from $LOG; refreshing everything" >&2
  status="$(printf '%s due never unknown 0\n' "${ALL_CREDENTIALS[@]}")"
fi
while read -r cred due age last since; do
  if [ "$FORCE" = yes ] || [ "$due" = due ]; then
    CREDENTIALS+=("$cred")
    case "$last" in human_required|waiting_for_human) ;; *) waiting_on_human=no ;; esac
  elif [ "$due" = backoff ]; then
    record "$cred" "backing_off" "Last attempt failed ($last) $((since / 60)) min ago; next try after $((RETRY_AFTER / 60)) min, or run gcloud-reauth-refresh --force"
  else
    record "$cred" "not_due" "Refreshed $((age / 60)) min ago; due after $((REFRESH_AFTER / 60)) min"
  fi
done <<<"$status"
if [ "${#CREDENTIALS[@]}" -eq 0 ]; then
  [ "$failed" = no ] && exit 0   # backing_off is not "fine"
  exit 1
fi

# --- one run at a time ------------------------------------------------------
# This run and the keepalive drive the same browser, and this one closes IdP
# tabs as it starts, which would make a concurrent keepalive probe report a
# session that is actually fine as missing -- a false "go and sign in"
# notification. Both agents fire on wake, so they DO start together. mkdir is
# the atomic primitive here; macOS has no flock(1). The keepalive holds the
# lock for seconds, so wait for it rather than skip. Taken only once something
# is due: a `not_due` run must not make the keepalive wait on it.
LOCK="$STATE/reauth.lock"
for _ in $(seq 1 36); do
  if mkdir "$LOCK" 2>/dev/null; then have_lock=yes; break; fi
  # Stale lock from a killed run should not wedge the refresher forever.
  # 60, not 30: a run that waits for a sign-in twice can legitimately hold
  # the lock ~40 min.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
    continue
  fi
  sleep 5
done
# Release only a lock we took: removing another run's would let a third start.
trap '[ "$have_lock" = yes ] && rmdir "$LOCK" 2>/dev/null' EXIT

if [ "$have_lock" != yes ]; then
  for cred in "${CREDENTIALS[@]}"; do
    record "$cred" "skipped" "Another reauth run has held $LOCK for over 3 minutes"
  done
  exit 0
fi

# --- the IdP session ----------------------------------------------------------
# Read through the same background-tab probe the keepalive uses: no focus
# steal, no credential touched. In 2026-09/10 history a refresh succeeded every
# time the keepalive had last seen a live IdP session, and stopped at the IdP
# sign-in every time it had not.
# Prints yes | no | unknown. Unknown (probe crashed, no IDP_* env) never blocks.
idp_session() {
  if [ -z "${IDP_ORIGIN:-}" ] || [ -z "${IDP_SESSION_PATH:-}" ]; then
    echo unknown; return
  fi
  local out
  out="$(IDP_LOG="$STATE/idp-session.jsonl" IDP_SESSION_PATH="$IDP_SESSION_PATH" \
         REAUTH_CDP_URL="$CDP_URL" \
         timeout 120 "$NODE" "$LIB/idp-session-probe.mjs" "$IDP_ORIGIN" 2>/dev/null)"
  python3 -c '
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print("unknown"); raise SystemExit
h = r.get("has_session")
print("unknown" if r.get("error") or h is None else ("yes" if h else "no"))' "$out"
}

# Already stopped for a human, and the IdP session is still absent: do not run
# the browser flow again (it would only stop at the same page). Ask again with
# an alert -- one per hourly run, never stacked -- then give the human the same
# window as a fresh stop does: if they sign in, carry straight on.
# Only when the probe positively says "no session"; a forced run always tries.
SIGNIN_MSG="Your IdP session in the isolated gcloud-reauth Chrome has expired, so the remote gcloud credentials cannot be refreshed. Click Open sign-in page and sign in there; the refresh then finishes by itself."
if [ "$waiting_on_human" = yes ] && [ "$FORCE" = no ] && [ "$(idp_session)" = no ]; then
  alert_human "gcloud reauth needs you to sign in" "$SIGNIN_MSG" signin
  wait_deadline=$(( $(date +%s) + ${REAUTH_HUMAN_WAIT_SECONDS:-900} ))
  came_back=no
  while [ "$(date +%s)" -lt "$wait_deadline" ]; do
    sleep 20
    if [ "$(idp_session)" = yes ]; then came_back=yes; break; fi
  done
  if [ "$came_back" != yes ]; then
    for cred in "${CREDENTIALS[@]}"; do
      record "$cred" "waiting_for_human" "Still no IdP session in the isolated Chrome; an alert is up asking for a sign-in, and the next hourly run asks again"
    done
    exit 1
  fi
  echo "IdP session is back; refreshing"
  sleep 10   # let the human's tab finish its redirect before a flow closes it
fi

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
# The value to restore is also pinned in a remote sidecar, written only when
# non-empty. Read only from the file being rewritten, one failed restore would
# be reported once and then become the new normal: the next run would find no
# quota project, have nothing to preserve, and call that `refreshed` forever.
# HUP/PIPE are ignored so that losing the ssh channel after the login wrote the
# file cannot skip the restore.
#
# Only marker lines reach this Mac; the project id and the token stay remote.
# Not exec'd: the steps after the login are the point.
# shellcheck disable=SC2016  # expanded by the remote shell, deliberately
LOGIN_CMD_ADC='trap "" HUP PIPE
f="$HOME/.config/gcloud/application_default_credentials.json"
pin="$HOME/.local/state/gcloud-reauth/adc-quota-project"
fp() { jq -r ".refresh_token // empty" "$f" 2>/dev/null | sha256sum | cut -c1-16; }
qp="$(jq -r ".quota_project_id // empty" "$f" 2>/dev/null)"
[ -n "$qp" ] || qp="$(cat "$pin" 2>/dev/null)"
if [ -n "$qp" ]; then mkdir -p "${pin%/*}" && printf "%s\n" "$qp" > "$pin"; fi
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
  # Closing an already-closed fd is not an error. Do NOT add 2>/dev/null here:
  # on a bare `exec` it would redirect the shell's stderr for the rest of the
  # run, swallowing the next flow's errors and osascript's warning.
  exec 3>&-
  [ -n "$GPID" ] && wait "$GPID" 2>/dev/null
  GPID=""
}

refresh_one() {
  local cred="$1" login_cmd verify_cmd dir answered=0 prompts node_rc reason verdict qp_mode login_rc
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
        record "$cred" "human_required" "Browser flow stopped at: $reason. The sign-in page is open in the isolated Chrome (the alert brings it forward); sign in there and this run retries by itself." ;;
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
  login_rc=$?
  GPID=""

  # 5. Verify, rather than trust the exit code -- but do not ignore it either.
  # A failed code exchange leaves the OLD credential in place, and an old
  # credential that has not died yet still mints a token, so a token check
  # alone would call that `refreshed`. Exit status comes from the remote
  # command through ssh (124 if the local timeout fired).
  if [ "$login_rc" -ne 0 ]; then
    record "$cred" "verify_failed" "Remote $cred login exited $login_rc after the code was delivered; the old credential may still be in place. See $dir/gcloud-login.log"
    return
  fi
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

# --- run the due credentials -----------------------------------------------
# All run even when one fails: they are independent credentials with
# independent failure modes, and a CLI fault must not leave ADC unattempted.
# The one exception is a stop for a human at the shared IdP sign-in. A later
# flow would hit the same page in the same browser, and its first act is to
# close stale IdP tabs -- the very tab just left open for the human, possibly
# mid-typing. It still gets its own row and its own notification.
rm -f "$WORK"/authfifo "$WORK"/authcode.txt   # pre-ADC single-workdir layout
attempt() {
  local cred handed_off=no
  PENDING=()
  for cred in "$@"; do
    if [ "$handed_off" = yes ]; then
      record "$cred" "human_required" "Not attempted: an earlier login is waiting at the IdP sign-in. Sign in there; this run waits ${HUMAN_WAIT}s, then the next hourly run takes over."
      PENDING+=("$cred")
      continue
    fi
    refresh_one "$cred"
    [ "$LAST_OUTCOME" = refreshed ] || PENDING+=("$cred")
    # Keyed on what the browser actually did (a tab left open for the human), not
    # on the mapped outcome: e2e.mjs can raise the tab and then still end in
    # `error`, which maps to no_authcode.
    if [ "$LAST_OUTCOME" = human_required ] || python3 -c '
import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get("awaiting_human") else 1)' "$WORK/$cred/e2e-result.json" 2>/dev/null; then
      handed_off=yes
      HANDOFF_REASON="$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1])).get("outcome") or "unknown")' "$WORK/$cred/e2e-result.json" 2>/dev/null)"
    fi
  done
  HANDED_OFF="$handed_off"
}
HANDOFF_REASON=""

HUMAN_WAIT="${REAUTH_HUMAN_WAIT_SECONDS:-900}"
attempt "${CREDENTIALS[@]}"
if [ "$HANDED_OFF" = yes ]; then
  if [ "$HANDOFF_REASON" = idp_login_required ]; then
    alert_human "gcloud reauth needs you to sign in" "$SIGNIN_MSG" signin
  else
    alert_human "gcloud reauth needs you" "Google stopped the sign-in at: ${HANDOFF_REASON:-unknown}. The page is open in the isolated gcloud-reauth Chrome; finish it there, then run gcloud-reauth-refresh." signin
  fi
fi

# --- waiting for a human ------------------------------------------------------
# The notification just told the human to sign in, and they usually do within a
# minute or two. Watch for it rather than leaving the credentials dead until the
# next hourly run: poll the IdP session (background tab; the sign-in tab left for the human
# is left alone) and, once it is live, retry what is still pending. Exactly one
# retry -- a second stop means something other than a missing sign-in.
#
# Only for a stop at the IdP's sign-in form. A Google-side stop (password, MFA,
# bot check) happens WITH a live IdP session, so the first poll would say yes
# and the retry would close the very tab the human is typing in. And a "yes"
# counts only after a "no" has been seen, i.e. after the session state actually
# changed, for the same reason.
if [ "$HANDED_OFF" = yes ] && [ "$HANDOFF_REASON" = idp_login_required ] \
   && [ "${#PENDING[@]}" -gt 0 ] && [ "$HUMAN_WAIT" -gt 0 ]; then
  echo "waiting up to ${HUMAN_WAIT}s for an IdP sign-in"
  deadline=$(( $(date +%s) + HUMAN_WAIT ))
  signed_in=no
  seen_no=no
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 20
    case "$(idp_session)" in
      no) seen_no=yes ;;
      yes) [ "$seen_no" = yes ] && { signed_in=yes; break; } ;;
    esac
  done
  if [ "$signed_in" = yes ]; then
    # Let the human's tab finish its redirect before the retry closes it.
    sleep 10
    failed=no   # the retry's rows decide this run's exit status
    attempt "${PENDING[@]}"
  fi
fi

if [ "$failed" = no ]; then
  dismiss_signin_alert
  exit 0
fi
exit 1
