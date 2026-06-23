#!/usr/bin/env bash
# Unit + source-guard tests for the mn9r M7 pool-aware /route migration of the
# lgtm-sessions inline home.base.nix client (attach hint).
#
# (opencode-send was removed — swarm messaging now uses the swarm_send/
# swarm_read/swarm_list plugin tools — so its source guards are gone.)
#
# Mirrors the pure parse_serve_url helper and exercises it directly, then
# greps users/dev/home.base.nix so a source-level regression trips before
# deploy. Mirror of the convention in pkgs/opencode-launch/test.sh.
#
# Run: bash users/dev/test-pool-route-clients.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of home.base.nix lgtm-sessions) --------------
# parse_serve_url <route-json-body> <fallback-url>: extract .apiBase from a
# pigeon GET /route JSON body and print it. Falls back to <fallback-url> when
# the body is empty, not JSON, or .apiBase is absent/null/empty. Pure (no
# network) so the production caller does the curl and hands the body in.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=1; fi
}

want_grep() { # want_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in $3: $2"; fail=1; fi
}

deny_grep() { # deny_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then
    echo "FAIL: $1"; echo "  unexpectedly present in $3: $2"; fail=1; else
    echo "ok: $1"; fi
}

# ---- parse_serve_url unit tests ---------------------------------------------
fb="http://127.0.0.1:4096"
if command -v jq >/dev/null 2>&1; then
  body='{"sessionId":"ses_x","serveId":"serve-1","apiBase":"http://127.0.0.1:4097"}'
  check "valid route body -> apiBase" "http://127.0.0.1:4097" "$(parse_serve_url "$body" "$fb")"
  check "empty body -> fallback"      "$fb" "$(parse_serve_url "" "$fb")"
  check "non-JSON -> fallback"        "$fb" "$(parse_serve_url "garbage" "$fb")"
  check "no apiBase -> fallback"      "$fb" "$(parse_serve_url '{"sessionId":"x"}' "$fb")"
  check "apiBase null -> fallback"    "$fb" "$(parse_serve_url '{"apiBase":null}' "$fb")"
  check "apiBase empty -> fallback"   "$fb" "$(parse_serve_url '{"apiBase":""}' "$fb")"
else
  echo "SKIP: parse_serve_url unit tests (jq not on PATH)"
fi

# ---- source guards (home.base.nix) ------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hb="$script_dir/home.base.nix"
if [ ! -f "$hb" ]; then
  echo "SKIP: source guards (home.base.nix not next to test)"
  [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
fi

# lgtm-sessions: attach hint must route per-session via pigeon /route, not the
# single hardwired serve-0 URL.
want_grep "lgtm-sessions defines parse_serve_url"          'parse_serve_url() {'                 "$hb"
want_grep "lgtm-sessions honors PIGEON_DAEMON_URL"         'PIGEON_DAEMON_URL'                    "$hb"
want_grep "lgtm-sessions queries pigeon /route"            '/route?session_id=$sid'              "$hb"
want_grep "lgtm-sessions attach hint uses resolved serve"  'opencode attach $serve_url --session $sid' "$hb"
deny_grep "lgtm-sessions drops the hardwired generic hint" 'opencode attach $OPENCODE_URL --session <ID>' "$hb"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
