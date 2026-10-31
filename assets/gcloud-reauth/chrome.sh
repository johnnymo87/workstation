#!/usr/bin/env bash
# Keep the isolated Chrome that the gcloud reauth drives running on 127.0.0.1:9223.
#
# THE BUG THIS FIXES: refresh.sh and keepalive.sh both connect to this browser,
# but nothing ever started it. It was launched by hand once, died, and every
# refresh for two weeks logged cdp_unreachable while the remote credential
# lapsed. launchd now owns it (KeepAlive=true), so a reboot, crash or quit is
# repaired within one ThrottleInterval.
#
# WHY A WRAPPER RATHER THAN EXEC'ING CHROME DIRECTLY FROM THE PLIST: Chrome's
# profile singleton. If an instance already owns this --user-data-dir -- Chrome's
# own "Relaunch to update" re-execs through a helper that is reparented away from
# launchd, or someone started it by hand -- a second launch hands off to it and
# exits 0 ("Opening in existing browser session."). Under KeepAlive=true that is
# a respawn every ThrottleInterval, forever. KeepAlive={SuccessfulExit=false} is
# not the answer either: Cmd-Q and the managed updater's enforced quit also exit
# 0, so the agent would die for good on the next clean quit, which is the very
# silent-death this exists to remove. So: if something already serves CDP on the
# port, babysit it and fall through to a real launch when it goes away.
#
# STOPPING IT DELIBERATELY: Cmd-Q comes back within a minute, by design. Use
#   launchctl bootout "gui/$(id -u)/org.nix-community.home.gcloud-reauth-chrome"
# That stops Chrome only if launchd launched it. In the adopt branch it kills
# just this wrapper; quit the adopted Chrome yourself afterwards.
#
# SECURITY: the DevTools port binds loopback only, but any local process can
# drive this browser, which holds a live SSO session. That was already true of
# the hand-started instance; what changes is that it is now up from login. No
# cheap mitigation exists: --remote-allow-origins only gates websocket Origin
# headers, and --remote-debugging-pipe would break the two separate clients.
#
# Optional env:
#   REAUTH_CHROME        Chrome binary
#   REAUTH_CHROME_PROFILE  --user-data-dir
#   REAUTH_CDP_PORT      default 9223

CHROME="${REAUTH_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="${REAUTH_CHROME_PROFILE:-$HOME/Library/Application Support/Chrome-gcloud}"
PORT="${REAUTH_CDP_PORT:-9223}"

# Captured, then matched with a here-string rather than piped into grep -q: under
# pipefail an early-exiting grep can EPIPE the writer and turn a match into a
# miss, which here would mean launching a duplicate that hands off and exits --
# the respawn loop by another route.
cdp_is_chrome() {
  local out
  out="$(curl -sf --max-time 2 "http://127.0.0.1:$PORT/json/version" 2>/dev/null)" || return 1
  grep -q '"Browser": *"Chrome/' <<<"$out"
}

# --- a Chrome whose files an update deleted --------------------------------
# THE BUG THIS FIXES (2026-10-31, bead workstation-beho): Chrome updated its
# bundle on disk from 156.0.8078.48 to .80 and deleted Versions/156.0.8078.48
# in the same step, while this Chrome was still running .48. A running Chrome
# starts every renderer from the helper apps in its OWN version's directory, so
# from then on each new tab crashed (blank, sad-face icon), while CDP kept
# answering /json/version. Nothing here noticed. Every keepalive and refresh
# failed for 13h, until a human saw the tabs and the process was killed.
#
# WHY THIS SIGNAL AND NOT "RUNNING VERSION != INSTALLED VERSION": a restart
# costs the IdP session, which lives in a session cookie (10-30: restarted
# 18:24Z with a session live at 17:37Z; at 18:37Z there was none). A Chrome
# whose own version directory is still on disk can start renderers, so it is
# not broken and is left alone, even if a newer version is installed. Only a
# missing directory means it can't open a page. The restart waits for a
# second check, so a check that lands mid-update cannot cause one by itself.
#
# Override for tests only: REAUTH_CHROME_CHECK_SECONDS (default 60).
CHECK_SECONDS="${REAUTH_CHROME_CHECK_SECONDS:-60}"
# .../Foo.app/Contents/MacOS/Foo -> .../Foo.app/Contents/Frameworks
FRAMEWORKS="$(dirname "$(dirname "$CHROME")")/Frameworks"

# Exit 0 = the running Chrome's own version directory is gone. Anything it
# cannot establish (CDP down, a layout it does not recognise) is "not stale":
# acting on a guess would cost the IdP session for nothing.
running_files_gone() {
  local out ver dirs
  out="$(curl -sf --max-time 2 "http://127.0.0.1:$PORT/json/version" 2>/dev/null)" || return 1
  ver="$(sed -n 's/.*"Browser": *"Chrome\/\([0-9.]*\)".*/\1/p' <<<"$out" | head -1)"
  [ -n "$ver" ] || return 1
  # The layout must be recognisable -- at least one */Versions dir -- before
  # a missing one counts as evidence.
  dirs="$(find "$FRAMEWORKS" -mindepth 2 -maxdepth 2 -type d -name Versions 2>/dev/null || true)"
  [ -n "$dirs" ] || return 1
  while IFS= read -r d; do
    [ -d "$d/$ver" ] && return 1
  done <<<"$dirs"
  STALE_VERSION="$ver"
  return 0
}

# The pid of whatever listens on the port, only if it is our Chrome: a Chrome
# with this port on its command line. Used for an instance we adopted.
listener_pid() {
  local pid cmd
  pid="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  [ -n "$pid" ] || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  case "$cmd" in
    *"--remote-debugging-port=$PORT"*) echo "$pid" ;;
    *) return 1 ;;
  esac
}

# Sleep in the background and wait: bash runs a trap only between commands,
# so a foreground `sleep 60` would hold off launchd's SIGTERM for up to 60s.
nap() { sleep "$1" & wait $!; }

# Watch Chrome (pid $1) until it exits, or until its files are found gone,
# in which case quit it. Returns once it is gone either way.
watch_chrome() {
  local pid="$1" strikes=0
  while kill -0 "$pid" 2>/dev/null; do
    nap "$CHECK_SECONDS"
    kill -0 "$pid" 2>/dev/null || break
    if running_files_gone; then
      strikes=$((strikes + 1))
      if [ "$strikes" -ge 2 ]; then
        echo "gcloud-reauth-chrome: $(date -u +%FT%TZ) running Chrome $STALE_VERSION has no files on disk (an update removed them); every new tab would crash. Quitting pid $pid so a fresh one starts." >&2
        # `|| true`: writeShellApplication runs this under errexit, and a kill
        # of a process that has just exited by itself fails.
        kill -TERM "$pid" 2>/dev/null || true
        # Chrome exits within seconds on TERM; KILL only one that does not.
        for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; nap 1; done
        kill -KILL "$pid" 2>/dev/null || true
        break
      fi
    else
      strikes=0
    fi
  done
}

# --- adopt a Chrome already serving the port --------------------------------
# Once it is gone -- by itself, or quit by watch_chrome -- fall through and
# launch a fresh one, as before.
while cdp_is_chrome; do
  pid="$(listener_pid)" || { nap "$CHECK_SECONDS"; continue; }
  watch_chrome "$pid"
done

if [ ! -x "$CHROME" ]; then
  echo "gcloud-reauth-chrome: $CHROME missing or not executable" >&2
  exit 1
fi

# --- launch, and stay to watch it ------------------------------------------
# A CHILD, NOT exec. This used to exec Chrome, so the watching above existed
# only for an adopted instance -- and the 2026-10-31 Chrome was launchd's own.
# The wrapper now stays as launchd's process. It passes launchd's TERM on to
# Chrome (bootout), and exits with Chrome's status, so KeepAlive behaves as
# before: Cmd-Q, a crash or a quit below all come back after ThrottleInterval.
#
# --no-startup-window: no window (and no focus steal) at login or on respawn.
# Chrome stays alive windowless and serves CDP. The reauth works in background
# tabs; raise-signin.mjs brings a window forward only when the human asks.
"$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$PORT" \
  --no-first-run \
  --no-default-browser-check \
  --no-startup-window \
  --hide-crash-restore-bubble &
chrome_pid=$!
trap 'kill -TERM "$chrome_pid" 2>/dev/null; wait "$chrome_pid"; exit 143' TERM INT
watch_chrome "$chrome_pid"
wait "$chrome_pid"
