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

# validate_tag <tag>: accept a manual oc-tags tag, reject anything that would be
# unsafe or meaningless as an argv element handed to `oc-tags set`. Mirror of the
# production function in default.nix; kept in lockstep by the source-grep guard
# at the bottom. Rules match pigeon's isValidTag (packages/worker/src/tag-command.ts,
# packages/daemon/src/worker/tag-ingest.ts), which is already shipped and reviewed:
#   - first character alphanumeric, which is what actually rules out the argument
#     -injection hazard (a tag named "--dir" that argparse would read as a flag);
#     shell metacharacters are NOT a hazard because we pass argv, never a string
#   - the rest from [A-Za-z0-9._:/-], max 64 characters total
#   - no "auto:" prefix (case-insensitive): oc-tags reserves that for its
#     directory-derived fallback and rejects it at write time anyway. Failing
#     here, before a session exists, beats a confusing failure after launch.
# LC_ALL=C is load-bearing: under the ambient en_US.UTF-8, [A-Za-z0-9] matches
# accented letters, so the charset promised by --help holds only under C.
validate_tag() {
  local t="$1"
  local LC_ALL=C
  [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,63}$ ]] || return 1
  case "$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')" in
    auto:*) return 1 ;;
  esac
  return 0
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
# prompt_async. An unregistered id (e.g. a bare 'claude-opus-5' missing the
# '@default' suffix the vertex-anthropic provider requires) returns HTTP 200
# and only dies later in the agent loop (Die(ProviderModelNotFoundError)) -- a
# silently dead session. resolve_model_id catches it up front: auto-correct a
# unique bare->@version match, signal NONE/AMBIGUOUS for a loud pre-launch
# error, and SKIP (degrade) when the catalog can't disambiguate. Needs jq.
if command -v jq >/dev/null 2>&1; then
  catalog='{"providers":[
    {"id":"google-vertex-anthropic","models":{"claude-opus-5@default":{},"claude-haiku-4-5@20251001":{},"claude-opus-4-7@default":{}}},
    {"id":"google-vertex","models":{"gemini-3.8-flash":{},"claude-haiku-4-5@20251001":{}}},
    {"id":"ambi","models":{"foo@v1":{},"foo@v2":{}}}
  ]}'
  assert_eq "claude-opus-5@default" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-opus-5@default)" \
    "resolve_model_id: exact qualified match -> unchanged"
  assert_eq "claude-opus-5@default" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-opus-5)" \
    "resolve_model_id: bare id -> unique @version expansion (the reported bug)"
  assert_eq "claude-haiku-4-5@20251001" \
    "$(resolve_model_id "$catalog" google-vertex-anthropic claude-haiku-4-5)" \
    "resolve_model_id: bare haiku -> @date expansion"
  assert_eq "gemini-3.8-flash" \
    "$(resolve_model_id "$catalog" google-vertex gemini-3.8-flash)" \
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
    "$(resolve_model_id "" google-vertex-anthropic claude-opus-5)" \
    "resolve_model_id: empty catalog -> __SKIP__ (degrade)"
  assert_eq "__SKIP__" \
    "$(resolve_model_id "not json" google-vertex-anthropic claude-opus-5)" \
    "resolve_model_id: non-JSON catalog -> __SKIP__ (degrade)"
else
  printf 'SKIP  resolve_model_id tests (jq not on PATH)\n'
fi

# ---- resolve_pigeon_auth tests ----------------------------------------------
#
resolve_pigeon_auth() {
  local token="${PIGEON_DAEMON_AUTH_TOKEN:-}"
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  if [ -z "$token" ]; then
    local token_file="${PIGEON_DAEMON_AUTH_TOKEN_FILE:-/run/secrets/pigeon_daemon_auth_token}"
    if [ -r "$token_file" ]; then
      token="$(cat "$token_file" 2>/dev/null || true)"
      token="$(printf '%s' "$token" | tr -d '[:space:]')"
    fi
  fi
  pigeon_auth=()
  if [ -n "$token" ]; then
    pigeon_auth=(-H "Authorization: Bearer $token")
  fi
}

# Test 1: env var set
PIGEON_DAEMON_AUTH_TOKEN="  token_env_1  "
resolve_pigeon_auth
assert_eq "2" "${#pigeon_auth[@]}" "resolve_pigeon_auth: env set yields auth array of length 2"
assert_eq "-H" "${pigeon_auth[0]}" "resolve_pigeon_auth: env set first element -H"
assert_eq "Authorization: Bearer token_env_1" "${pigeon_auth[1]}" "resolve_pigeon_auth: env set second element Bearer token"

# Test 2: env unset, token file present
unset PIGEON_DAEMON_AUTH_TOKEN
tf_launch="$(mktemp)"
printf "  token_file_1 \n" > "$tf_launch"
PIGEON_DAEMON_AUTH_TOKEN_FILE="$tf_launch"
resolve_pigeon_auth
rm -f "$tf_launch"
assert_eq "2" "${#pigeon_auth[@]}" "resolve_pigeon_auth: file fallback yields auth array of length 2"
assert_eq "Authorization: Bearer token_file_1" "${pigeon_auth[1]}" "resolve_pigeon_auth: file fallback token trimmed"

# Test 3: neither set
unset PIGEON_DAEMON_AUTH_TOKEN
PIGEON_DAEMON_AUTH_TOKEN_FILE="/nonexistent/pigeon_token_test"
resolve_pigeon_auth
assert_eq "0" "${#pigeon_auth[@]}" "resolve_pigeon_auth: neither set yields empty auth array"
unset PIGEON_DAEMON_AUTH_TOKEN_FILE

# ---- validate_tag tests ------------------------------------------------------
#
# --tag <tag> converts the launched session from its directory-derived "auto:"
# fallback to a manual oc-tags tag. The tag comes from a human on a command line
# and goes into another process's argv, so it is validated BEFORE anything is
# created: a bad tag must cost nothing, and must not surface as a confusing
# oc-tags error after a session is already live.
assert_tag_ok() {
  if validate_tag "$1"; then
    printf 'PASS  validate_tag accepts %s\n' "$2"
  else
    printf 'FAIL  validate_tag accepts %s\n        rejected: %s\n' "$2" "$1"; exit 1
  fi
}
assert_tag_rejected() {
  if validate_tag "$1"; then
    printf 'FAIL  validate_tag rejects %s\n        accepted: %s\n' "$2" "$1"; exit 1
  else
    printf 'PASS  validate_tag rejects %s\n' "$2"
  fi
}

assert_tag_ok "billing" "a plain tag"
assert_tag_ok "fbm-migration" "a hyphenated tag"
assert_tag_ok "team/infra" "a slash-namespaced tag"
assert_tag_ok "v1.2_x" "dots and underscores"
assert_tag_ok "epic:swarm" "an interior colon"
assert_tag_ok "9lives" "a leading digit"
assert_tag_ok "$(printf 'a%.0s' $(seq 1 64))" "a 64-character tag (max length)"

# Argument injection is the hazard, not shell metacharacters: we pass argv, never
# a command string. A leading "-" is what argparse would read as a flag.
assert_tag_rejected "--dir" "a tag that argparse would read as a flag"
assert_tag_rejected "-x" "a leading hyphen"
assert_tag_rejected "" "the empty tag"
assert_tag_rejected "auto:mono" "the reserved auto: prefix"
assert_tag_rejected "AUTO:mono" "the reserved prefix, upper case"
assert_tag_rejected "has space" "an embedded space"
assert_tag_rejected 'semi;colon' "a shell metacharacter (belt and braces)"
assert_tag_rejected '$(id)' "a command substitution shape"
assert_tag_rejected "$(printf 'a%.0s' $(seq 1 65))" "a 65-character tag (over max length)"
assert_tag_rejected "$(printf 'tag\nsecond')" "an embedded newline"

# The locale hole, asserted explicitly. Bash's [A-Za-z0-9] is collation-dependent:
# under the ambient en_US.UTF-8 (what cloudbox actually runs) it MATCHES "é", so
# without the function's own LC_ALL=C this tag would be accepted here and by
# oc-tags' normalise_tag while pigeon's TAG_RE rejected the identical string.
saved_lc="${LC_ALL-__unset__}"
LC_ALL=en_US.UTF-8
assert_tag_rejected "épic" "a non-ASCII letter (under a UTF-8 ambient locale)"
assert_tag_rejected "café/latte" "non-ASCII mid-tag (under a UTF-8 ambient locale)"
if [ "$saved_lc" = "__unset__" ]; then unset LC_ALL; else LC_ALL="$saved_lc"; fi

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
  if grep -q 'resolve_pigeon_auth()' "$default_nix"; then
    printf 'PASS  source defines resolve_pigeon_auth\n'
  else
    printf 'FAIL  source defines resolve_pigeon_auth\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q "pigeon_auth\[@\]" "$default_nix"; then
    printf 'PASS  source passes pigeon_auth array to curl\n'
  else
    printf 'FAIL  source passes pigeon_auth array to curl\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'PIGEON_DAEMON_URL' "$default_nix"; then
    printf 'PASS  source honors PIGEON_DAEMON_URL\n'
  else
    printf 'FAIL  source honors PIGEON_DAEMON_URL\n        not referenced in: %s\n' "$default_nix"; exit 1
  fi
  # Placement-at-create: must NOT contain POST /place on the client (the door places at create)
  if grep -q 'POST "\$PIGEON_DAEMON_URL/place"' "$default_nix"; then
    printf 'FAIL  source still places via pigeon POST /place\n        found in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source no longer contains client-side POST /place\n'
  fi
  # Discovery-via-route: must use GET /route?session_id= for read-only owner discovery
  if grep -q '/route?session_id=' "$default_nix"; then
    printf 'PASS  source uses GET /route?session_id= for discovery\n'
  else
    printf 'FAIL  source does not contain GET /route?session_id=\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # Front-door routing: create, health, and config/providers must route through FRONTDOOR_URL
  if grep -q 'FRONTDOOR_URL=' "$default_nix"; then
    printf 'PASS  source defines FRONTDOOR_URL\n'
  else
    printf 'FAIL  source defines FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'POST "\$FRONTDOOR_URL/session"' "$default_nix"; then
    printf 'PASS  source sends create to FRONTDOOR_URL\n'
  else
    printf 'FAIL  source sends create to FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '"\$FRONTDOOR_URL/global/health"' "$default_nix"; then
    printf 'PASS  source sends health check to FRONTDOOR_URL\n'
  else
    printf 'FAIL  source sends health check to FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q '"\$FRONTDOOR_URL/config/providers"' "$default_nix"; then
    printf 'PASS  source queries providers via FRONTDOOR_URL\n'
  else
    printf 'FAIL  source queries providers via FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The prompt and MCP-connect: prompt must route through FRONTDOOR_URL,
  # MCP-connect must target the resolved owner ($serve_url).
  if grep -q '"\$FRONTDOOR_URL/session/\$session_id/prompt_async"' "$default_nix"; then
    printf 'PASS  source sends prompt to FRONTDOOR_URL\n'
  else
    printf 'FAIL  source sends prompt to FRONTDOOR_URL\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # Degrade (fable M2 #2): the prompt must retry DIRECT against $serve_url when the
  # door rejects it (pigeon-outage 503), instead of hard-failing + orphaning the session.
  if grep -q '"\$serve_url/session/\$session_id/prompt_async"' "$default_nix"; then
    printf 'PASS  source retries the prompt direct to $serve_url on door failure\n'
  else
    printf 'FAIL  source retries the prompt direct to $serve_url on door failure\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # MCP-connect rides the front door on the SESSION-SCOPED route (Phase 9,
  # workstation-mlve.4). This assertion previously demanded the opposite --
  # 'source connects MCP on $serve_url (owning serve)' -- which was correct
  # when the door had no session-scoped MCP route and denied the bare one.
  # Phase 10 added POST /session/{sessionID}/mcp/{name}/connect (class
  # session-path, routes.classification.ts:216) and the TUI migrated to it,
  # at which point this test was pinning a stale direct-to-serve call as
  # correct. Verified 2026-07-26 that error semantics are unchanged: an
  # unknown server returns byte-identical 404 McpServerNotFoundError through
  # the door and direct to a serve, so the 404 branch in the source still
  # means exactly what it says.
  if grep -q '"\$FRONTDOOR_URL/session/\$session_id/mcp/\$srv/connect"' "$default_nix"; then
    printf 'PASS  source connects MCP through the front door (session-scoped)\n'
  else
    printf 'FAIL  source connects MCP through the front door (session-scoped)\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The bare direct-to-serve connect is PERMITTED, but ONLY as the 503 degrade.
  # History: this started as a blanket deny of "$serve_url/mcp/$srv/connect",
  # which was right when the door call had no fallback -- and it immediately
  # caught the degrade being added, correctly. But a blanket deny would have
  # forced the regression it was written to prevent: without a fallback, a pigeon
  # outage makes the door 503 every MCP connect (proxy.ts:741-745) and the
  # launcher exits 1, where the pre-Phase-9 code survived. So assert the
  # STRUCTURE instead of banning the string: door first, bare route only under a
  # 503 test.
  if grep -q 'if \[ "\$connect_code" = "503" \]; then' "$default_nix"; then
    printf 'PASS  source degrades MCP connect on 503 (pigeon-down survivability)\n'
  else
    printf 'FAIL  source degrades MCP connect on 503\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The bare connect must appear exactly once, and inside the 503 branch. Two
  # occurrences would mean the primary path regressed back to direct-to-serve.
  bare_connect_count="$(grep -c '"\$serve_url/mcp/\$srv/connect"' "$default_nix" || true)"
  if [ "$bare_connect_count" = "1" ]; then
    printf 'PASS  bare MCP connect appears exactly once (the degrade leg)\n'
  else
    printf 'FAIL  bare MCP connect appears %s time(s), expected exactly 1\n        in: %s\n' "$bare_connect_count" "$default_nix"; exit 1
  fi
  # Both connect legs must be time-bounded: a wedged serve otherwise parks the
  # launcher (reset-workspace documents a 6+ hour parked curl on this shape).
  if [ "$(grep -c -- '--max-time 20' "$default_nix" || true)" -ge 2 ]; then
    printf 'PASS  both MCP connect legs carry --max-time\n'
  else
    printf 'FAIL  both MCP connect legs carry --max-time\n        in: %s\n' "$default_nix"; exit 1
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
  # Launch-time question deny: a headless spawn has no attended user to
  # answer `question`, so the tools map handed to prompt_async must ALWAYS
  # carry "question": false -- unconditionally, not only when --mcp is used
  # -- and it must be merged into (not overwritten by) any --mcp tool
  # entries. Regression here reopens the 4-hour stuck-session incident.
  if grep -q "mcp_tools_json='{\"question\": false}'" "$default_nix"; then
    printf 'PASS  source seeds tools map with question:false unconditionally\n'
  else
    printf 'FAIL  source seeds tools map with question:false unconditionally\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'build_mcp_tools_json .*| jq -c .\+ {"question": false}' "$default_nix"; then
    printf 'PASS  source merges question:false into --mcp tool entries\n'
  else
    printf 'FAIL  source merges question:false into --mcp tool entries\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The tools map is now always non-empty, so it must always be attached to
  # prompt_payload (no more conditional length check that could drop it).
  if grep -q 'if (\$tools | length) > 0' "$default_nix"; then
    printf 'FAIL  source still conditionally attaches tools (could drop question:false)\n        in: %s\n' "$default_nix"; exit 1
  else
    printf 'PASS  source always attaches tools to prompt_payload\n'
  fi
  if grep -q 'tools: \$tools' "$default_nix"; then
    printf 'PASS  source attaches tools: $tools to prompt_payload\n'
  else
    printf 'FAIL  source attaches tools: $tools to prompt_payload\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # ---- Phase 3.5: --worktree launch integration (workstation-v03j.5) ----------
  #
  # --worktree <slug> lands a writable session in a fresh `work`-created worktree
  # instead of the passed directory, so the read-only-main guard is bypassed by
  # construction. The must-fixes from the adversarial review are encoded as
  # source guards here so a regression trips before deploy:
  #   M1a: worktree created AFTER health+model checks, JUST BEFORE session create.
  #   M1b: an EXIT trap removes the worktree+branch if the launch fails.
  #   loud-fail: work failure aborts the launch (no silent root fallback).
  if grep -q -- '--worktree)' "$default_nix"; then
    printf 'PASS  source parses --worktree flag\n'
  else
    printf 'FAIL  source parses --worktree flag\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # M1a: the work call must reassign $directory before the session is created.
  if grep -q 'work "\$worktree_slug"' "$default_nix"; then
    printf 'PASS  source runs work "$worktree_slug"\n'
  else
    printf 'FAIL  source runs work "$worktree_slug"\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # M1a ordering: the work call must appear BEFORE the POST /session create.
  work_line="$(grep -n 'work "\$worktree_slug"' "$default_nix" | head -1 | cut -d: -f1)"
  create_line="$(grep -n 'POST "\$FRONTDOOR_URL/session"' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$work_line" ] && [ -n "$create_line" ] && [ "$work_line" -lt "$create_line" ]; then
    printf 'PASS  worktree is created before the session (M1a: shrink failure window)\n'
  else
    printf 'FAIL  worktree must be created before session create (work@%s create@%s)\n' "$work_line" "$create_line"; exit 1
  fi
  # M1b: a cleanup trap on EXIT removes the worktree if the launch fails.
  if grep -q 'trap cleanup_worktree EXIT' "$default_nix"; then
    printf 'PASS  source arms cleanup_worktree on EXIT (M1b)\n'
  else
    printf 'FAIL  source arms cleanup_worktree on EXIT (M1b)\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'worktree remove --force' "$default_nix"; then
    printf 'PASS  cleanup removes the worktree (M1b)\n'
  else
    printf 'FAIL  cleanup removes the worktree (M1b)\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The trap must be disarmed only after the launch actually succeeds.
  if grep -q 'launch_ok=1' "$default_nix"; then
    printf 'PASS  source disarms cleanup only on success (launch_ok=1)\n'
  else
    printf 'FAIL  source disarms cleanup only on success (launch_ok=1)\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # pigeon-w36w: the launch prompt must be recorded with the pigeon daemon so
  # /mirror does not echo it into Telegram as if a human had typed it.
  if grep -q 'PIGEON_DAEMON_URL/injected-prompts' "$default_nix"; then
    printf 'PASS  source records the launch prompt with pigeon (w36w)\n'
  else
    printf 'FAIL  source records the launch prompt with pigeon (w36w)\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The record must carry the daemon bearer token, or it 401s and silently no-ops.
  if grep -A6 'PIGEON_DAEMON_URL/injected-prompts' "$default_nix" | grep -q 'pigeon_auth\[@\]' \
     || grep -B6 'PIGEON_DAEMON_URL/injected-prompts' "$default_nix" | grep -q 'pigeon_auth\[@\]'; then
    printf 'PASS  launch-prompt record sends pigeon auth (w36w)\n'
  else
    printf 'FAIL  launch-prompt record must send pigeon auth (w36w)\n'; exit 1
  fi
  # It must send the RAW prompt and let the daemon hash it: a hash computed here
  # would have to match sha256 byte-for-byte, and a mismatch fails silently.
  if grep -A6 'PIGEON_DAEMON_URL/injected-prompts' "$default_nix" | grep -q 'arg t "\$prompt"'; then
    printf 'PASS  launch-prompt record sends the raw prompt text (w36w)\n'
  else
    printf 'FAIL  launch-prompt record must send the raw prompt text (w36w)\n'; exit 1
  fi
  # Ordering: resolve_pigeon_auth populates the array the record call reads.
  # Under `set -u` an unset array expands to NOTHING rather than erroring, so a
  # record call above resolve_pigeon_auth would drop the header and 401 silently.
  auth_line="$(grep -n '^      resolve_pigeon_auth$' "$default_nix" | head -1 | cut -d: -f1)"
  first_record_line="$(grep -n '^      record_launch_prompt$' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$auth_line" ] && [ -n "$first_record_line" ] && [ "$auth_line" -lt "$first_record_line" ]; then
    printf 'PASS  launch-prompt record runs after resolve_pigeon_auth (w36w)\n'
  else
    printf 'FAIL  record must run after resolve_pigeon_auth (auth@%s record@%s)\n' "$auth_line" "$first_record_line"; exit 1
  fi
  # Ordering: record BEFORE the injection. prompt_async is non-idempotent and a
  # timeout may mean "processed", so a record after the response loses the race
  # to the mirror event it exists to suppress.
  prompt_line="$(grep -n 'FRONTDOOR_URL/session/\$session_id/prompt_async' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$first_record_line" ] && [ -n "$prompt_line" ] && [ "$first_record_line" -lt "$prompt_line" ]; then
    printf 'PASS  launch prompt is recorded before it is injected (w36w)\n'
  else
    printf 'FAIL  record must precede prompt_async (record@%s prompt@%s)\n' "$first_record_line" "$prompt_line"; exit 1
  fi
  # Both injection legs record: the retry leg is a second injection, and the
  # counted table exists precisely so retry-after-timeout does not echo.
  record_count="$(grep -c '^      record_launch_prompt$\|^        record_launch_prompt$' "$default_nix" || true)"
  if [ "$record_count" -ge 2 ]; then
    printf 'PASS  both prompt_async legs record the launch prompt (w36w)\n'
  else
    printf 'FAIL  retry leg must record too (found %s call sites, want 2)\n' "$record_count"; exit 1
  fi
  # Best-effort but not mute: a 404/401/400 is a real misconfiguration and must
  # not be swallowed the way a daemon-down 000 legitimately is.
  if grep -q 'may echo into Telegram' "$default_nix"; then
    printf 'PASS  launch-prompt record warns on unexpected HTTP status (w36w)\n'
  else
    printf 'FAIL  launch-prompt record must warn on unexpected HTTP status (w36w)\n'; exit 1
  fi
  # ---- --tag: launch-time oc-tags tagging (workstation-simy) -----------------
  #
  # A launched session knows what it was launched to DO; without --tag that
  # knowledge is thrown away and reconstructed by hand later. The invariants the
  # source must keep:
  #   - the flag is parsed and the tag validated BEFORE anything is created
  #   - the tag is applied only AFTER the launch has succeeded, so bookkeeping
  #     can never fail or delay the launch (tag lookup is retroactive at report
  #     time, so applying late costs nothing)
  #   - oc-tags argv order is `set <tag> <session-id>` (tag FIRST)
  #   - any oc-tags failure warns on stderr and returns 0
  if grep -q -- '--tag)' "$default_nix"; then
    printf 'PASS  source parses --tag flag\n'
  else
    printf 'FAIL  source parses --tag flag\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'validate_tag()' "$default_nix"; then
    printf 'PASS  source defines validate_tag\n'
  else
    printf 'FAIL  source defines validate_tag\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The mirror above is only worth anything if it is byte-identical to prod.
  tag_re='^[A-Za-z0-9][A-Za-z0-9._:/-]{0,63}$'
  if grep -qF "$tag_re" "$default_nix"; then
    printf 'PASS  source tag regex matches the mirror under test\n'
  else
    printf 'FAIL  source tag regex must match the mirror under test\n        want: %s\n' "$tag_re"; exit 1
  fi
  # The regex is only half the function. The auto: rejection must be
  # case-insensitive, and the whole match must run under LC_ALL=C or the
  # bracket expression silently widens to accented letters under en_US.UTF-8.
  if grep -A4 'validate_tag()' "$default_nix" | grep -q 'local LC_ALL=C'; then
    printf 'PASS  source validates the tag under LC_ALL=C\n'
  else
    printf 'FAIL  validate_tag must pin LC_ALL=C\n        in: %s\n' "$default_nix"; exit 1
  fi
  if grep -A10 'validate_tag()' "$default_nix" | grep -q "tr '\[:upper:\]' '\[:lower:\]'"; then
    printf 'PASS  source rejects the auto: prefix case-insensitively\n'
  else
    printf 'FAIL  auto: rejection must be case-insensitive\n        in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'apply_session_tag()' "$default_nix"; then
    printf 'PASS  source defines apply_session_tag\n'
  else
    printf 'FAIL  source defines apply_session_tag\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # argv order: oc-tags takes the TAG first and the session id second
  # (cmd_set/build_parser in pkgs/oc-tags/oc_tags.py). Reversed, it would try to
  # tag the session "ses_..." -- which oc-tags accepts, silently.
  if grep -q 'set -- "\$tag" "\$session_id"' "$default_nix"; then
    printf 'PASS  source calls oc-tags set <tag> <session-id> (tag first)\n'
  else
    printf 'FAIL  source must call oc-tags set <tag> <session-id>\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # Validation must happen before the session is created, so a typo costs nothing.
  validate_line="$(grep -n 'if ! validate_tag "\$tag"' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$validate_line" ] && [ -n "$create_line" ] && [ "$validate_line" -lt "$create_line" ]; then
    printf 'PASS  tag is validated before the session is created\n'
  else
    printf 'FAIL  tag must be validated before session create (validate@%s create@%s)\n' "$validate_line" "$create_line"; exit 1
  fi
  # Tagging must happen only after the launch succeeded (launch_ok=1). The launch
  # is the point; the tag is bookkeeping, and it must never sit in front of the
  # prompt where an oc-tags hang would delay or lose the launch.
  apply_line="$(grep -n '^ *apply_session_tag$' "$default_nix" | head -1 | cut -d: -f1)"
  ok_line="$(grep -n '^      launch_ok=1$' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$apply_line" ] && [ -n "$ok_line" ] && [ "$apply_line" -gt "$ok_line" ]; then
    printf 'PASS  tag is applied only after the launch succeeded\n'
  else
    printf 'FAIL  tag must be applied after launch_ok=1 (apply@%s launch_ok@%s)\n' "$apply_line" "$ok_line"; exit 1
  fi
  # ...and specifically after prompt_async, never before it.
  if [ -n "$apply_line" ] && [ -n "$prompt_line" ] && [ "$apply_line" -gt "$prompt_line" ]; then
    printf 'PASS  tag is applied after prompt_async (bookkeeping never delays the launch)\n'
  else
    printf 'FAIL  tag must be applied after prompt_async (apply@%s prompt@%s)\n' "$apply_line" "$prompt_line"; exit 1
  fi
  # The apply must be time-bounded and best-effort: a hung or broken oc-tags
  # warns and the launcher still reports a live, prompted session.
  if grep -A12 'apply_session_tag()' "$default_nix" | grep -q -- '--max-time\|timeout '; then
    printf 'PASS  oc-tags invocation is time-bounded\n'
  else
    printf 'FAIL  oc-tags invocation must be time-bounded\n        in: %s\n' "$default_nix"; exit 1
  fi
  if grep -A16 'apply_session_tag()' "$default_nix" | grep -q 'not applied'; then
    printf 'PASS  a failed tag warns on stderr instead of failing the launch\n'
  else
    printf 'FAIL  a failed tag must warn on stderr\n        in: %s\n' "$default_nix"; exit 1
  fi
  # oc-tags must be a runtimeInput, so `oc-tags` resolves under a minimal PATH
  # (a systemd unit) exactly the way git/coreutils do. Assert the actual
  # assignment line: a bare `grep -q oc-tags` also passes on a comment
  # mentioning it, which is exactly the state this guard exists to catch.
  if grep -q '^  runtimeInputs = .*oc-tags' "$default_nix"; then
    printf 'PASS  oc-tags is pinned in runtimeInputs\n'
  else
    printf 'FAIL  oc-tags must be pinned in runtimeInputs\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # The failure path must name a REASON. A `timeout` kill (rc 124) prints
  # nothing, so the naive "$out" degrades to an empty explanation precisely
  # when the launcher was held up longest.
  if grep -A24 'apply_session_tag()' "$default_nix" | grep -q 'rc" -eq 124'; then
    printf 'PASS  a timed-out oc-tags reports as a timeout, not an empty reason\n'
  else
    printf 'FAIL  timeout (rc 124) must be reported as such\n        in: %s\n' "$default_nix"; exit 1
  fi
  # oc-tags lowercases the tag (normalise_tag), so the launcher must print
  # oc-tags' own line rather than echoing back what the human typed -- otherwise
  # "--tag FBM-Migration" reports a tag the chart will never show.
  # (The suffix is empty for an explicit --tag; inherit_launcher_tag passes
  # " (inherited from <root>)", appended to oc-tags' line, not replacing it.)
  if grep -A30 'apply_session_tag()' "$default_nix" | grep -q "printf '%s%s\\\\n' \"\$out\" \"\$suffix\""; then
    printf 'PASS  success line comes from oc-tags, not from the launcher\n'
  else
    printf 'FAIL  success line must print oc-tags own output\n        in: %s\n' "$default_nix"; exit 1
  fi
  # --no-attach must exist as a flag AND be honoured at the call site. The
  # helper tests above exercise a MIRROR; without these the mirror could pass
  # while production still attaches unconditionally.
  if grep -q '^          --no-attach)' "$default_nix"; then
    printf 'PASS  --no-attach is parsed as a flag\n'
  else
    printf 'FAIL  --no-attach must be parsed\n        in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'if ! should_auto_attach "\$no_attach"' "$default_nix"; then
    printf 'PASS  the auto-attach call site is gated by should_auto_attach\n'
  else
    printf 'FAIL  auto-attach must be gated; an unparsed flag that changes nothing is worse than none\n        in: %s\n' "$default_nix"; exit 1
  fi
  # The env var is the half lgtm-run actually needs: it launches from the pigeon
  # daemon and cannot easily change its argv.
  if grep -q 'OPENCODE_LAUNCH_NO_ATTACH' "$default_nix"; then
    printf 'PASS  OPENCODE_LAUNCH_NO_ATTACH is read by the source\n'
  else
    printf 'FAIL  OPENCODE_LAUNCH_NO_ATTACH must be honoured\n        in: %s\n' "$default_nix"; exit 1
  fi
  # Lockstep: the production allowlist must match the mirror above. A bare
  # non-empty test would make =0 disable attaching everywhere.
  if grep -q '1|true|TRUE|yes|YES|on|ON) return 1' "$default_nix"; then
    printf 'PASS  production truthiness is an allowlist, matching the mirror\n'
  else
    printf 'FAIL  production must use the same allowlist as the mirror\n        in: %s\n' "$default_nix"; exit 1
  fi

  # loud-fail: a work failure must abort, never silently launch at the root.
  if grep -q 'failed to create worktree' "$default_nix"; then
    printf 'PASS  source fails loudly on work failure (no silent root fallback)\n'
  else
    printf 'FAIL  source fails loudly on work failure\n        not found in: %s\n' "$default_nix"; exit 1
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

# ---- should_auto_attach (bead workstation-o5s1.14) --------------------------
#
# Every launched session used to get an `opencode attach` TUI unconditionally,
# at ~240 MB, in a tmux scope with no memory cap, and nothing reaped it. On
# 2026-09-15 a 34-session spin-up in five minutes created ~7-8 GB of new anon
# that way and drove the host 11.43 GB into swap. Automation that never reads a
# TUI should not create one.
#
# Mirror of the production helper; kept in lockstep by the source grep below.
# (That lockstep is one-directional: the grep pins production against this
# mirror, but the mirror can still drift. A shared sourced helper is the real
# fix and is out of scope here.)
should_auto_attach() { # <no_attach_flag> <env_value> -> 0 = attach, 1 = skip
  local flag="$1" env="${2:-}"
  [ "$flag" = "1" ] && return 1
  case "$env" in
    1|true|TRUE|yes|YES|on|ON) return 1 ;;
  esac
  return 0
}

check_attach() { # <desc> <expected: attach|skip> <flag> <env>
  local desc="$1" want="$2" flag="$3" env="${4:-}" got
  if should_auto_attach "$flag" "$env"; then got=attach; else got=skip; fi
  if [ "$got" = "$want" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    printf 'FAIL  %s\n        want %s, got %s (flag=%s env=%s)\n' "$desc" "$want" "$got" "$flag" "$env"
    exit 1
  fi
}

check_attach "default launch still attaches"                 attach 0 ""
check_attach "--no-attach skips the TUI"                     skip   1 ""
check_attach "env OPENCODE_LAUNCH_NO_ATTACH=1 skips"         skip   0 "1"
check_attach "env =true skips"                               skip   0 "true"
check_attach "env =yes skips"                                skip   0 "yes"
check_attach "env =on skips"                                 skip   0 "on"
# The negative cases matter more than the positive ones: an env var that is set
# but not truthy must NOT silently disable attaching for every launch on the
# box, which is the failure mode of a naive `[ -n "$VAR" ]` test.
check_attach "env =0 still attaches"                         attach 0 "0"
check_attach "env =false still attaches"                     attach 0 "false"
check_attach "env empty still attaches"                      attach 0 ""
check_attach "env =no still attaches"                        attach 0 "no"
check_attach "flag wins even when env is falsey"             skip   1 "0"

# ---- launch tag inheritance (docs/plans/2026-09-23-launch-tag-inheritance-design.md)
#
# Unlike the mirrors above, these run the PRODUCTION functions: each one is cut
# out of default.nix and nix-unescaped (''${ -> ${), so there is no mirror to
# drift. oc-tags and oc-auto-attach are fakes that log their argv/env.
#
# Rules under test: only an explicit SESSION tag (which column 4 == session)
# is inherited; an explicit --tag wins with no lookup; `--tag auto` opts out;
# every failure path is a Note on stderr and a 0 return, never a failed launch.
if [ ! -f "$default_nix" ]; then
  printf 'SKIP  tag inheritance tests (default.nix not next to test)\n'
  echo "all opencode-launch helper tests passed"
  exit 0
fi

extract_fn() { # <name>: print the function's source from default.nix, nix-unescaped
  awk -v start="      $1() {" '$0 == start { p = 1 } p { print } p && $0 == "      }" { exit }' "$default_nix" \
    | sed "s/''\\\${/\${/g"
}

for fn in validate_tag apply_session_tag is_inherit_optout inherit_launcher_tag tag_launched_session spawn_auto_attach; do
  src="$(extract_fn "$fn")"
  if [ -z "$src" ] || ! grep -q "^      }$" <<<"$src"; then
    printf 'FAIL  extract %s() from default.nix\n' "$fn"; exit 1
  fi
  if grep -q "''" <<<"$src"; then
    printf 'FAIL  %s() still carries a nix escape after unescaping\n' "$fn"; exit 1
  fi
  if [ "$fn" = spawn_auto_attach ]; then
    # Keep the test's attach log out of the real /tmp (and the nix sandbox,
    # which has no /tmp at all).
    spawn_src="$src"
    continue
  fi
  eval "$src"
  printf 'PASS  extracted production %s() from default.nix\n' "$fn"
done

inh_tmp="$(mktemp -d)"
trap 'rm -rf "$inh_tmp"' EXIT
bash_bin="$(command -v bash)"
export FAKE_LOG="$inh_tmp/oc-tags.log" FAKE_WHICH=""
cat >"$inh_tmp/fake-oc-tags" <<EOF
#!$bash_bin
printf '%s\n' "\$*" >>"\$FAKE_LOG"
case "\$1" in
  which)
    case "\$FAKE_WHICH" in
      hang) exec sleep 30 ;;
      fail) exit 3 ;;
      *) printf '%b\n' "\$FAKE_WHICH" ;;
    esac ;;
  set) printf "Tagged session '%s' as '%s'\n" "\$4" "\$3" ;;
esac
EOF
chmod +x "$inh_tmp/fake-oc-tags"

# run_tag <desc>: run tag_launched_session with the caller's globals; capture
# stdout (out), stderr (err), return code, and what the fake oc-tags saw (calls).
run_tag() {
  local rc=0
  : >"$FAKE_LOG"
  out="$(tag_launched_session 2>"$inh_tmp/err")" || rc=$?
  err="$(cat "$inh_tmp/err")"
  calls="$(cat "$FAKE_LOG")"
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL  %s: tag_launched_session returned %s (must never fail a launch)\n' "$1" "$rc"; exit 1
  fi
}
expect_no_set() { # <desc>
  if grep -q '^set ' <<<"$calls"; then
    printf 'FAIL  %s: oc-tags set was called\n        calls: %s\n' "$1" "$calls"; exit 1
  fi
  printf 'PASS  %s\n' "$1"
}
expect_note() { # <desc> <substring>
  if grep -q '^Note: tag not inherited' <<<"$err" && grep -qF -- "$2" <<<"$err"; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n        stderr: %s\n' "$1" "$err"; exit 1
  fi
}

OC_TAGS_BIN="$inh_tmp/fake-oc-tags"
session_id="ses_child"
tag=""
no_inherit=0
export OPENCODE_SESSION_ID="ses_parent"

FAKE_WHICH='billing\tmanual\tses_root\tsession'
run_tag "session kind"
assert_eq "Tagged session 'ses_child' as 'billing' (inherited from ses_root)" "$out" \
  "inherit: kind=session -> tag copied, loud line names the root it came from"
assert_eq "$(printf 'which -- ses_parent\nset -- billing ses_child')" "$calls" \
  "inherit: which is asked about the LAUNCHER, set targets the CHILD (tag first)"
assert_eq "" "$err" "inherit: kind=session success is quiet on stderr"

FAKE_WHICH='mono-wt\tmanual\tses_root\tdir'
run_tag "dir kind"
assert_eq "" "$out$err" "inherit: kind=dir -> silent"
expect_no_set "inherit: kind=dir (a glob describes a place) -> not inherited"

FAKE_WHICH='auto:mono\tauto\tses_root\tauto'
run_tag "auto kind"
assert_eq "" "$out$err" "inherit: kind=auto -> silent"
expect_no_set "inherit: kind=auto (fallback) -> not inherited"

FAKE_WHICH='billing\tmanual\tses_root'
run_tag "3 columns"
expect_no_set "inherit: 3-column which (old oc-tags) -> not inherited"
expect_note "inherit: 3-column which -> Note" "no kind column"

FAKE_WHICH='billing\tmanual\tses_root\tsession\tfuture'
run_tag "5 columns"
assert_eq "Tagged session 'ses_child' as 'billing' (inherited from ses_root)" "$out" \
  "inherit: a trailing extra column is tolerated"

FAKE_WHICH='billing\tmanual\tses_root\tbogus'
run_tag "unknown kind"
expect_no_set "inherit: unknown kind -> not inherited"
expect_note "inherit: unknown kind -> Note" "unknown tag kind 'bogus'"

FAKE_WHICH=''
run_tag "empty output"
expect_no_set "inherit: empty which output -> not inherited"
expect_note "inherit: empty which output -> Note" "no kind column"

FAKE_WHICH='fail'
run_tag "which fails"
expect_no_set "inherit: which exits non-zero -> launch ok, nothing set"
expect_note "inherit: which exits non-zero -> Note with the exit code" "exit 3"

FAKE_WHICH='hang'
export OPENCODE_LAUNCH_TAG_WHICH_TIMEOUT=1
t0=$SECONDS
run_tag "which hangs"
elapsed=$((SECONDS - t0))
unset OPENCODE_LAUNCH_TAG_WHICH_TIMEOUT
expect_no_set "inherit: which hangs -> launch ok, nothing set"
expect_note "inherit: which hangs -> Note names the timeout" "timed out after 1s"
if [ "$elapsed" -le 5 ]; then
  printf 'PASS  inherit: a hung which is bounded by the timeout (%ss)\n' "$elapsed"
else
  printf 'FAIL  inherit: a hung which took %ss (timeout 1s)\n' "$elapsed"; exit 1
fi

FAKE_WHICH='-evil\tmanual\tses_root\tsession'
run_tag "invalid inherited tag"
expect_no_set "inherit: tag failing validate_tag -> not applied"
expect_note "inherit: tag failing validate_tag -> Note" "not a valid launch tag"

OC_TAGS_BIN="$inh_tmp/no-such-oc-tags"
FAKE_WHICH='billing\tmanual\tses_root\tsession'
run_tag "binary missing"
expect_note "inherit: oc-tags binary missing -> Note" "not found on PATH"
OC_TAGS_BIN="$inh_tmp/fake-oc-tags"

tag="explicit"
run_tag "explicit tag"
assert_eq "set -- explicit ses_child" "$calls" "explicit --tag wins: set called, which NEVER called"
assert_eq "Tagged session 'ses_child' as 'explicit'" "$out" "explicit --tag: no inheritance suffix"
tag=""

no_inherit=1
run_tag "--tag auto"
assert_eq "" "$calls" "--tag auto: which never called, nothing tagged"
no_inherit=0

unset OPENCODE_SESSION_ID
run_tag "no launcher"
assert_eq "" "$calls" "no OPENCODE_SESSION_ID: which never called"
export OPENCODE_SESSION_ID=""
run_tag "empty launcher"
assert_eq "" "$calls" "empty OPENCODE_SESSION_ID: which never called"
export OPENCODE_SESSION_ID="ses_parent"

check_optout() { # <arg> <want: yes|no>
  local got=no
  if is_inherit_optout "$1"; then got=yes; fi
  assert_eq "$2" "$got" "is_inherit_optout '$1' -> $2"
}
check_optout auto yes
check_optout AUTO yes
check_optout Auto yes
check_optout "auto:mono" no
check_optout autox no
check_optout billing no
check_optout "" no

# The opt-out must be consumed before validate_tag runs on the argument, and
# inheritance must run from the same post-prompt point as the explicit tag.
optout_line="$(grep -n 'is_inherit_optout "\$tag"' "$default_nix" | head -1 | cut -d: -f1)"
if [ -n "$optout_line" ] && [ -n "$validate_line" ] && [ "$optout_line" -lt "$validate_line" ]; then
  printf 'PASS  --tag auto is consumed before validate_tag\n'
else
  printf 'FAIL  --tag auto must be handled before validate_tag (optout@%s validate@%s)\n' "$optout_line" "$validate_line"; exit 1
fi
call_line="$(grep -n '^      tag_launched_session$' "$default_nix" | head -1 | cut -d: -f1)"
if [ -n "$call_line" ] && [ "$call_line" -gt "$ok_line" ] && [ "$call_line" -gt "$prompt_line" ]; then
  printf 'PASS  tagging/inheritance runs after launch_ok=1 and prompt_async\n'
else
  printf 'FAIL  tag_launched_session must run after launch_ok and the prompt (call@%s)\n' "$call_line"; exit 1
fi
if grep -q 'timeout "\$secs" "\$bin" which -- "\$launcher"' "$default_nix"; then
  printf 'PASS  which is time-bounded and guards the id with --\n'
else
  printf 'FAIL  which must be called as timeout "$secs" "$bin" which -- "$launcher"\n'; exit 1
fi

# ---- oc-auto-attach spawn scrubs the launcher's OPENCODE_SESSION_ID ---------
#
# The first attach after a tmux server restart starts the server, and tmux
# copies the spawning env into its GLOBAL env. Every later pane would then
# carry a dead session's id and silently inherit its tag.
if [ "$(grep -c 'oc-auto-attach ' "$default_nix" | tr -d ' ')" -ge 1 ] \
   && ! grep -E 'setsid nohup +oc-auto-attach' "$default_nix" >/dev/null; then
  printf 'PASS  no unscrubbed setsid nohup oc-auto-attach spawn remains\n'
else
  printf 'FAIL  an oc-auto-attach spawn without env -u OPENCODE_SESSION_ID remains\n'; exit 1
fi
mkdir -p "$inh_tmp/bin"
cat >"$inh_tmp/bin/oc-auto-attach" <<EOF
#!$bash_bin
env >"$inh_tmp/attach.env.tmp"
printf '%s\n' "\$*" >"$inh_tmp/attach.args"
mv "$inh_tmp/attach.env.tmp" "$inh_tmp/attach.env"
EOF
chmod +x "$inh_tmp/bin/oc-auto-attach"
att_log="$inh_tmp/attach.log"
eval "${spawn_src//\/tmp\/oc-auto-attach.log/$att_log}"
printf 'PASS  extracted production spawn_auto_attach() from default.nix\n'
if command -v setsid >/dev/null 2>&1; then
  export INHERIT_TEST_MARK=present
  oc_attach_args=(--tmux-session main)
  PATH="$inh_tmp/bin:$PATH" spawn_auto_attach
  for _ in $(seq 1 100); do
    [ -f "$inh_tmp/attach.env" ] && break
    sleep 0.1
  done
  attach_env="$(cat "$inh_tmp/attach.env" 2>/dev/null || true)"
  if grep -q '^INHERIT_TEST_MARK=present$' <<<"$attach_env"; then
    printf 'PASS  spawned oc-auto-attach env was captured (positive control)\n'
  else
    printf 'FAIL  spawned oc-auto-attach did not run or env not captured\n'; exit 1
  fi
  if grep -q '^OPENCODE_SESSION_ID=' <<<"$attach_env"; then
    printf 'FAIL  oc-auto-attach spawn env still carries OPENCODE_SESSION_ID\n'; exit 1
  else
    printf 'PASS  oc-auto-attach spawn env lacks OPENCODE_SESSION_ID\n'
  fi
  assert_eq "--tmux-session main ses_child" "$(cat "$inh_tmp/attach.args")" \
    "oc-auto-attach still gets its args and the CHILD session id"
  unset INHERIT_TEST_MARK
else
  printf 'FAIL  setsid not on PATH; the spawn test cannot run\n'; exit 1
fi

echo "all opencode-launch helper tests passed"
