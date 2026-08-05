#!/usr/bin/env bash
# unwired-test(workstation-k7t4): probes live host state (systemd/tmux/sockets); needs fixture injection to be hermetic
# Source-guard tests for the front-door disposition of the lgtm-sessions inline
# home.base.nix client, plus the Phase 7.8 infra/control-plane exemptions.
#
# Authoritative table: docs/plans/2026-07-26-phase9-consumer-disposition.md.
# These greps are that table's enforcement for the two files below.
#
# (opencode-send was removed — swarm messaging now uses the swarm_send/
# swarm_read/swarm_list plugin tools — so its source guards are gone.)
#
# The parse_serve_url unit tests that used to live here were removed in Phase 9
# along with the helper's last use in home.base.nix. No coverage was lost: the
# helper is still exercised where it is still used, by
# pkgs/opencode-launch/test.sh:68-85 and pkgs/oc-pool-attach/test.sh:120-127.
#
# Run: bash users/dev/test-pool-route-clients.sh
set -o errexit -o nounset -o pipefail

fail=0
want_grep() { # want_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in $3: $2"; fail=1; fi
}

deny_grep() { # deny_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then
    echo "FAIL: $1"; echo "  unexpectedly present in $3: $2"; fail=1; else
    echo "ok: $1"; fi
}

# ---- source guards (home.base.nix) ------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hb="$script_dir/home.base.nix"
if [ ! -f "$hb" ]; then
  echo "SKIP: source guards (home.base.nix not next to test)"
  [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
fi

# lgtm-sessions attach hint: through the FRONT DOOR (Phase 9, mlve.4).
#
# HISTORY — this block previously asserted the OPPOSITE, requiring the hint to
# resolve the owning serve via pigeon /route and emit `opencode attach
# $serve_url`. That was correct for mn9r M7 and became wrong when Phase 8/9
# landed (f878865) and the interactive TUI started riding the door. Because the
# test pinned the stale behaviour as CORRECT, it actively protected the last
# direct-to-serve data-plane call site from being fixed for two phases. Rewritten
# rather than deleted: it is the guard that keeps the fix fixed.
#
# Why the door is better than a resolved serve URL here, not merely equivalent:
# a hint is pasted by a human minutes later, by which time the session may have
# migrated to another serve. `$FRONTDOOR_URL` re-resolves on every request; a
# baked serve URL goes stale silently.
want_grep "lgtm-sessions attach hint rides the front door" 'opencode attach $FRONTDOOR_URL --session $sid' "$hb"
deny_grep "lgtm-sessions attach hint is NOT direct-to-serve" 'opencode attach $serve_url --session $sid' "$hb"
deny_grep "lgtm-sessions no longer resolves via pigeon /route" '/route?session_id=$sid'               "$hb"
deny_grep "lgtm-sessions drops the now-dead parse_serve_url"   'parse_serve_url() {'                  "$hb"
deny_grep "lgtm-sessions drops the hardwired generic hint" 'opencode attach $OPENCODE_URL --session <ID>' "$hb"

# front-door cutover (Phase 7.5 + Phase 9): health check, session LIST and the
# attach hint are all data-plane and all ride the front door. OPENCODE_URL
# survives in this script only as a raw-anchor default, never as a target.
want_grep "lgtm-sessions defines FRONTDOOR_URL"            'FRONTDOOR_URL="'                     "$hb"
want_grep "lgtm-sessions health-checks the front door"     '"$FRONTDOOR_URL/global/health"'      "$hb"
want_grep "lgtm-sessions lists sessions via the front door" '"$FRONTDOOR_URL/session"'           "$hb"
deny_grep "lgtm-sessions no longer health-checks the anchor" '"$OPENCODE_URL/global/health"'     "$hb"
deny_grep "lgtm-sessions no longer lists via the anchor"   '"$OPENCODE_URL/session"'             "$hb"

# ---- Phase 7.8 infra-/control-plane exemption guards ------------------------
# "Everything through the front door" applies to DATA-PLANE clients only. The
# control plane (pigeon) and the door's own watchdogs must NOT be repointed at
# the front door: pigeon is the router the door depends on (routing it through
# the door is a circular control->data dependency + a startup cycle), and the
# canaries must diagnose the door/pool directly. Guard the cloudbox system
# config so a future edit that "helpfully" repoints pigeon at :4700 trips here.
cfg="$script_dir/../../hosts/cloudbox/configuration.nix"
if [ ! -f "$cfg" ]; then
  echo "SKIP: infra-plane exemption guards (configuration.nix not found at $cfg)"
else
  want_grep "pigeon-daemon keeps the raw anchor (control-plane exemption)" 'export OPENCODE_URL="http://127.0.0.1:4096"' "$cfg"
  deny_grep "pigeon-daemon is NOT repointed at the front door"             'export OPENCODE_URL="http://127.0.0.1:4700"' "$cfg"
  want_grep "front door degrades to the raw anchor, not itself"           'OPENCODE_ANCHOR_URL=http://127.0.0.1:4096'   "$cfg"
  want_grep "frontdoor canary watches the door port directly"             'PORT=4700'                                   "$cfg"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
