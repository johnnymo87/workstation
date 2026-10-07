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

while cdp_is_chrome; do
  sleep 60
done

if [ ! -x "$CHROME" ]; then
  echo "gcloud-reauth-chrome: $CHROME missing or not executable" >&2
  exit 1
fi

# --no-startup-window: no window (and no focus steal) at login or on respawn.
# Chrome stays alive windowless and serves CDP; e2e.mjs's newPage()+bringToFront
# still raises a window when a human is needed.
exec "$CHROME" \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$PORT" \
  --no-first-run \
  --no-default-browser-check \
  --no-startup-window \
  --hide-crash-restore-bubble
