#!/usr/bin/env bash
# Unit tests for opencode-launch helper functions + pool-aware source guards.
# Mirror the helpers from default.nix and exercise them directly.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# ---- helpers under test (mirror of default.nix) -----------------------------

# parse_serve_url <place-or-route-json-body> <fallback-url>: extract the owning
# serve's base URL from a pigeon routing JSON body and print it. Accepts BOTH
# `POST /place` (.api_base, snake_case) and `GET /route` (.apiBase, camelCase).
# Falls back to <fallback-url> when the body is empty, not JSON, or the field is
# absent/null/empty. Pure (no network) so the production caller does the curl
# and hands the body in. Mirror of the production function in default.nix; kept
# in lockstep by the source-grep guard at the bottom.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.api_base // .apiBase // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
}

# resolve_model_id <catalog-json> <provider> <model-id>: resolve a (possibly
# bare) model id against a GET /config/providers catalog body. Prints one of:
#   - the resolved, fully-qualified model id (exact match, or a unique
#     bare -> @version expansion) on success
#   - "__SKIP__"      catalog empty/unparseable or provider absent -> caller
#                     proceeds with the id as-given (degrade, never worse)
#   - "__NONE__"      provider known but no model matches
#   - "__AMBIGUOUS__:a@x,a@y"  a bare id maps to several @versions
# Pure (no network): the production caller does the curl and hands the body in.
# Mirror of the production function in default.nix; kept in lockstep by the
# source-grep guard at the bottom.
resolve_model_id() {
  local catalog="$1" provider="$2" model="$3"
  # Empty body (the common degrade path: /config/providers unreachable) makes
  # jq exit 0 with no output, not an error -- guard it so it maps to __SKIP__.
  [ -n "$catalog" ] || { printf '__SKIP__\n'; return 0; }
  printf '%s' "$catalog" | jq -r --arg prov "$provider" --arg m "$model" '
    ([.providers[]? | select(.id == $prov)] | first) as $p
    | if $p == null then "__SKIP__"
      else ($p.models | keys) as $keys
        | if ($keys | index($m)) then $m
          else [ $keys[] | select((. | sub("@.*"; "")) == $m) ] as $c
            | if   ($c | length) == 0 then "__NONE__"
              elif ($c | length) == 1 then $c[0]
              else "__AMBIGUOUS__:" + ($c | join(",")) end
          end
      end' 2>/dev/null || printf '__SKIP__\n'
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
    "parse_serve_url: valid GET /route body -> apiBase (owning serve)"
  place_body='{"ok":true,"session_id":"ses_x","serve_id":"serve-2","api_base":"http://127.0.0.1:4098","event_url":"http://127.0.0.1:4098/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4098" "$(parse_serve_url "$place_body" "$fallback_url")" \
    "parse_serve_url: valid POST /place body -> api_base (owning serve)"
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":null}' "$fallback_url")" \
    "parse_serve_url: api_base null -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":""}' "$fallback_url")" \
    "parse_serve_url: api_base empty string -> fallback"
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

# ---- resolve_model_id tests -------------------------------------------------
#
# The launch-time model footgun: --model passes modelID verbatim to the async
# prompt_async. An unregistered id (e.g. a bare 'claude-opus-4-8' missing the
# '@default' suffix the vertex-anthropic provider requires) returns HTTP 200
# and only dies later in the agent loop (Die(ProviderModelNotFoundError)) -- a
# silently dead session. resolve_model_id catches it up front: auto-correct a
# unique bare->@version match, signal NONE/AMBIGUOUS for a loud pre-launch
# error, and SKIP (degrade) when the catalog can't disambiguate. Needs jq.
if command -v jq >/dev/null 2>&1; then
  catalog='{"providers":[
    {"id":"google-vertex-anthropic","models":{"claude-opus-4-8@default":{},"claude-haiku-4-5@20251001":{},"claude-opus-4-7@default":{}}},
    {"id":"google-vertex","models":{"gemini-3.5-flash":{},"claude-haiku-4-5@20251001":{}}},
    {"id":"ambi","models":{"foo@v1":{},"foo@v2":{}}}
  ]}'
  assert_eq "claude-opus-4-8@default" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-opus-4-8@default)" \
    "resolve_model_id: exact qualified match -> unchanged"
  assert_eq "claude-opus-4-8@default" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-opus-4-8)" \
    "resolve_model_id: bare id -> unique @version expansion (the reported bug)"
  assert_eq "claude-haiku-4-5@20251001" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-haiku-4-5)" \
    "resolve_model_id: bare haiku -> @date expansion"
  assert_eq "gemini-3.5-flash" \
    "$(resolve_model_id "$catalog" google-vertex gemini-3.5-flash)" \
    "resolve_model_id: suffix-less registered id -> unchanged"
  assert_eq "__NONE__" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-bogus-9)" \
    "resolve_model_id: provider known, no match -> __NONE__"
  assert_eq "__AMBIGUOUS__:foo@v1,foo@v2" \
    "$(resolve_model_id "$catalog" ambi foo)" \
    "resolve_model_id: bare id with multiple @versions -> __AMBIGUOUS__"
  assert_eq "__SKIP__" \
    "$(resolve_model_id "$catalog" no-such-provider whatever)" \
    "resolve_model_id: provider absent -> __SKIP__ (degrade)"
  assert_eq "__SKIP__" \
    "$(resolve_model_id "" google-vertex-anthropic claude-opus-4-8)" \
    "resolve_model_id: empty catalog -> __SKIP__ (degrade)"
  assert_eq "__SKIP__" \
    "$(resolve_model_id "not json" google-vertex-anthropic claude-opus-4-8)" \
    "resolve_model_id: non-JSON catalog -> __SKIP__ (degrade)"
else
  printf 'SKIP  resolve_model_id tests (jq not on PATH)\n'
fi

# ---- production-source check (default.nix) -----------------------------------
#
# Grep default.nix directly so a source-level regression trips immediately,
# before deploy, and so the mirror above can't silently diverge from prod.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  # The pool-aware resolution must be present: the parse_serve_url helper, the
  # PIGEON_DAEMON_URL env, and the POST /place placement call.
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
  # Placement-at-create: must POST /place (active placement), NOT the old passive
  # read-only GET /route (which 404s pre-placement and concentrated load on serve-0).
  if grep -q 'POST "\$PIGEON_DAEMON_URL/place"' "$default_nix"; then
    printf 'PASS  source places via pigeon POST /place\n'
  else
    printf 'FAIL  source places via pigeon POST /place\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '/route?session_id=' "$default_nix"; then
    printf 'FAIL  source still uses passive GET /route?session_id= (should POST /place)\n        in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source no longer uses passive GET /route for placement\n'
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
  # The launch-time model resolver must be present: the resolve_model_id helper
  # and the /config/providers catalog query that feeds it. Guards against a
  # regression that would reintroduce the silent dead-session footgun.
  if grep -q 'resolve_model_id()' "$default_nix"; then
    printf 'PASS  source defines resolve_model_id\n'
  else
    printf 'FAIL  source defines resolve_model_id\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '/config/providers' "$default_nix"; then
    printf 'PASS  source queries /config/providers catalog\n'
  else
    printf 'FAIL  source queries /config/providers catalog\n        not found in: %s\n' "$default_nix"; exit 1
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

echo "all opencode-launch helper tests passed"
