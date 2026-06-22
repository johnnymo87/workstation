#!/usr/bin/env bash
# Unit tests for opencode-launch helper functions + pool-aware source guards.
# Mirror the helpers from default.nix and exercise them directly.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# ---- helpers under test (mirror of default.nix) -----------------------------

# parse_serve_url <route-json-body> <fallback-url>: extract .apiBase from a
# pigeon GET /route JSON body and print it. Falls back to <fallback-url> when
# the body is empty, not JSON, or .apiBase is absent/null/empty. Pure (no
# network) so the production caller does the curl and hands the body in.
# Mirror of the production function in default.nix; kept in lockstep by the
# source-grep guard at the bottom.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
}

# ---- test infrastructure ----------------------------------------------------

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

# ---- parse_serve_url tests --------------------------------------------------
#
# Pool-aware serve resolution: opencode-launch creates the session on serve-0,
# then asks pigeon's GET /route which serve OWNS it (rendezvous hash on the
# sid), and sends the MCP-connect + prompt to that owner. parse_serve_url is
# the pure parse+fallback core. Any malformed/absent response degrades to the
# caller's fallback (today's :4096), so the fix can never be worse than the
# pre-pool behavior. Needs jq (a runtimeInput of the package); SKIP if absent.
fallback_url="http://127.0.0.1:4096"
if command -v jq >/dev/null 2>&1; then
  route_body='{"sessionId":"ses_x","serveId":"serve-1","apiBase":"http://127.0.0.1:4097","eventUrl":"http://127.0.0.1:4097/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4097" "$(parse_serve_url "$route_body" "$fallback_url")" \
    "parse_serve_url: valid route body -> apiBase (owning serve)"
  assert_eq "$fallback_url" "$(parse_serve_url "" "$fallback_url")" \
    "parse_serve_url: empty body -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url "not json at all" "$fallback_url")" \
    "parse_serve_url: non-JSON body -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"sessionId":"ses_x"}' "$fallback_url")" \
    "parse_serve_url: JSON without apiBase -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":null}' "$fallback_url")" \
    "parse_serve_url: apiBase null -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":""}' "$fallback_url")" \
    "parse_serve_url: apiBase empty string -> fallback"
else
  printf 'SKIP  parse_serve_url tests (jq not on PATH)\n'
fi

# ---- production-source check (default.nix) -----------------------------------
#
# Grep default.nix directly so a source-level regression trips immediately,
# before deploy, and so the mirror above can't silently diverge from prod.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  # The pool-aware resolution must be present: the parse_serve_url helper, the
  # PIGEON_DAEMON_URL env, and the /route query.
  if grep -q 'parse_serve_url()' "$default_nix"; then
    printf 'PASS  source defines parse_serve_url\n'
  else
    printf 'FAIL  source defines parse_serve_url\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'PIGEON_DAEMON_URL' "$default_nix"; then
    printf 'PASS  source honors PIGEON_DAEMON_URL\n'
  else
    printf 'FAIL  source honors PIGEON_DAEMON_URL\n        not referenced in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '/route?session_id=' "$default_nix"; then
    printf 'PASS  source queries pigeon /route?session_id=\n'
  else
    printf 'FAIL  source queries pigeon /route?session_id=\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The prompt and MCP-connect must target the resolved owner ($serve_url),
  # NOT the hardwired $OPENCODE_URL.
  if grep -q '"\$serve_url/session/\$session_id/prompt_async"' "$default_nix"; then
    printf 'PASS  source sends prompt to $serve_url (owning serve)\n'
  else
    printf 'FAIL  source sends prompt to $serve_url\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '"\$serve_url/mcp/\$srv/connect"' "$default_nix"; then
    printf 'PASS  source connects MCP on $serve_url (owning serve)\n'
  else
    printf 'FAIL  source connects MCP on $serve_url\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # Guard against regression: prompt/MCP must NOT use the hardwired serve-0 URL.
  if grep -q '"\$OPENCODE_URL/session/\$session_id/prompt_async"' "$default_nix"; then
    printf 'FAIL  source still sends prompt to hardwired $OPENCODE_URL\n        in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source no longer sends prompt to hardwired $OPENCODE_URL\n'
  fi
  if grep -q '"\$OPENCODE_URL/mcp/\$srv/connect"' "$default_nix"; then
    printf 'FAIL  source still connects MCP on hardwired $OPENCODE_URL\n        in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source no longer connects MCP on hardwired $OPENCODE_URL\n'
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

echo "all opencode-launch helper tests passed"
