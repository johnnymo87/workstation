#!/usr/bin/env bash
# Unit tests for oc-mcp-enable's pure helper + source guards on the production
# script. Mirrors the pkgs/opencode-launch/test.sh shape: the helper is copied
# here verbatim and a source-grep guard at the bottom keeps the copy honest.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of default.nix) ------------------------------

# build_permission_json <action> <server>...: emit a PermissionV1.Ruleset (JSON
# array of {permission, pattern, action}) covering the whole `<server>_*` tool
# family for each server. Pure (no network). Mirror of the production function
# in default.nix; kept in lockstep by the source-grep guard at the bottom.
build_permission_json() {
  local action="$1"
  shift
  printf '%s\n' "$@" | jq -R -s -c --arg action "$action" '
    split("\n")
    | map(select(. != ""))
    | unique
    | map({permission: (. + "_*"), pattern: "*", action: $action})'
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

# ---- build_permission_json --------------------------------------------------

assert_eq \
  '[{"permission":"slack_*","pattern":"*","action":"allow"}]' \
  "$(build_permission_json allow slack)" \
  "single server -> one allow rule with the _* family pattern"

# A hyphenated server name must keep its hyphen: opencode's sanitize() only
# rewrites characters outside [a-zA-Z0-9_-] (mcp/catalog.ts), so the real tool
# names are `slack-ro_channels_list` etc. Emitting `slack_ro_*` here would
# silently grant nothing.
assert_eq \
  '[{"permission":"slack-ro_*","pattern":"*","action":"allow"}]' \
  "$(build_permission_json allow slack-ro)" \
  "hyphenated server name is preserved (slack-ro_*, not slack_ro_*)"

assert_eq \
  '[{"permission":"atlassian_*","pattern":"*","action":"allow"},{"permission":"slack_*","pattern":"*","action":"allow"}]' \
  "$(build_permission_json allow slack atlassian)" \
  "multiple servers -> sorted, one rule each"

assert_eq \
  '[{"permission":"slack_*","pattern":"*","action":"allow"}]' \
  "$(build_permission_json allow slack slack)" \
  "duplicate servers are de-duplicated"

assert_eq \
  '[{"permission":"slack_*","pattern":"*","action":"deny"}]' \
  "$(build_permission_json deny slack)" \
  "--revoke path emits deny rules"

# pattern must be exactly "*": opencode's Permission.disabled() only strips a
# tool from the model's view when the last matching rule has pattern "*" AND
# action "deny". A narrower pattern would make --revoke a no-op at exposure time.
assert_eq \
  '*' \
  "$(build_permission_json deny slack | jq -r '.[0].pattern')" \
  "deny rule uses the wildcard pattern that Permission.disabled() requires"

# ---- production-source guards ------------------------------------------------

default_nix="$(dirname "$0")/default.nix"
if [ -f "$default_nix" ]; then
  # The helper copied above must still exist in production.
  if grep -q 'build_permission_json()' "$default_nix"; then
    printf 'PASS  source defines build_permission_json\n'
  else
    printf 'FAIL  source defines build_permission_json\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q 'permission: (. + "_\*")' "$default_nix"; then
    printf 'PASS  source builds the _* family pattern\n'
  else
    printf 'FAIL  source builds the _* family pattern\n        not found in: %s\n' "$default_nix"; exit 1
  fi

  # Both steps are load-bearing and neither substitutes for the other:
  # connect makes the tools VISIBLE, the PATCH makes them CALLABLE without an
  # interactive permission prompt (which a headless session can never answer).
  if grep -q '/mcp/\$srv/connect' "$default_nix"; then
    printf 'PASS  source connects via the session-scoped MCP route\n'
  else
    printf 'FAIL  source connects via the session-scoped MCP route\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  if grep -q -- '-X PATCH "\$FRONTDOOR_URL/session/\$session_id"' "$default_nix"; then
    printf 'PASS  source grants permissions via PATCH /session/<id>\n'
  else
    printf 'FAIL  source grants permissions via PATCH /session/<id>\n        not found in: %s\n' "$default_nix"; exit 1
  fi
  # Ordering: connect must precede the PATCH, so a failed connect (e.g. an
  # unconfigured server) never leaves a dangling allow rule behind.
  connect_line="$(grep -n '/mcp/\$srv/connect' "$default_nix" | head -1 | cut -d: -f1)"
  patch_line="$(grep -n -- '-X PATCH "\$FRONTDOOR_URL/session/\$session_id"' "$default_nix" | head -1 | cut -d: -f1)"
  if [ -n "$connect_line" ] && [ -n "$patch_line" ] && [ "$connect_line" -lt "$patch_line" ]; then
    printf 'PASS  connect precedes the permission PATCH (no orphan allow rule)\n'
  else
    printf 'FAIL  connect must precede the PATCH (connect@%s patch@%s)\n' "$connect_line" "$patch_line"; exit 1
  fi

  # No raw-serve fallback. Unlike opencode-launch (which may legitimately assume
  # the anchor for a session it just created there), this tool targets an
  # arbitrary already-running session that can live on any pool member; guessing
  # a serve would silently mutate the wrong process's state.
  if grep -q '127.0.0.1:409' "$default_nix"; then
    printf 'FAIL  source must not address a raw serve port directly\n'; exit 1
  else
    printf 'PASS  source addresses only the front door (no raw serve port)\n'
  fi

  # --revoke must not disconnect: the MCP connection is per-directory and shared
  # by every session in that directory on that serve.
  if grep -q '/disconnect' "$default_nix"; then
    printf 'FAIL  source must not disconnect (connection is shared per-directory)\n'; exit 1
  else
    printf 'PASS  --revoke does not disconnect the shared MCP client\n'
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

# ---- behaviour: the REAL script against a fake front door --------------------
#
# OC_MCP_ENABLE_BIN is the built package's binary (the flake check sets it; run
# locally with `OC_MCP_ENABLE_BIN=$(nix build --print-out-paths .#oc-mcp-enable)/bin/oc-mcp-enable`).
# The flake check also requires the "behaviour tests ran" line, so a check that
# silently skipped this section would fail.

if [ -n "${OC_MCP_ENABLE_BIN:-}" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  work="$(mktemp -d)"
  door_pid=""
  cleanup() { [ -n "$door_pid" ] && kill "$door_pid" 2>/dev/null; rm -rf "$work"; }
  trap cleanup EXIT

  # run_scenario <scenario> [server]: start a fake door, run `oc-mcp-enable ses_fake123
  # <server>` against it, and leave rc/stdout/stderr/patch-log in $work.
  run_scenario() {
    local scenario="$1"
    local srv="${2:-atlassian}"
    [ -n "$door_pid" ] && kill "$door_pid" 2>/dev/null && wait "$door_pid" 2>/dev/null || true
    rm -f "$work/port" "$work/patches"
    : >"$work/patches"
    SCENARIO="$scenario" PATCH_LOG="$work/patches" python3 "$here/fake-door.py" "$work/port" &
    door_pid=$!
    for _ in $(seq 1 100); do [ -s "$work/port" ] && break; sleep 0.05; done
    [ -s "$work/port" ] || { printf 'FAIL  fake door did not start (%s)\n' "$scenario"; exit 1; }
    set +e
    FRONTDOOR_URL="http://127.0.0.1:$(cat "$work/port")" \
      "$OC_MCP_ENABLE_BIN" ses_fake123 "$srv" >"$work/out" 2>"$work/err"
    rc=$?
    set -e
  }

  assert_contains() {
    local file="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" "$file"; then
      printf 'PASS  %s\n' "$msg"
    else
      printf 'FAIL  %s\n        %s does not contain: %s\n        ---\n%s\n' "$msg" "$file" "$needle" "$(cat "$file")"; exit 1
    fi
  }
  assert_not_contains() {
    local file="$1" needle="$2" msg="$3"
    if grep -qF -- "$needle" "$file"; then
      printf 'FAIL  %s\n        %s unexpectedly contains: %s\n' "$msg" "$file" "$needle"; exit 1
    else
      printf 'PASS  %s\n' "$msg"
    fi
  }
  no_grant() { assert_eq 0 "$(wc -l <"$work/patches")" "$1: no permission grant attempted"; }
  stop_footer() { assert_contains "$work/err" "Stop and report" "$1: tells the agent to stop and report, not work around"; }

  run_scenario ok
  assert_eq 0 "$rc" "ok: exits 0"
  assert_contains "$work/out" "Connected MCP server 'atlassian'" "ok: reports connected"
  assert_contains "$work/patches" '"atlassian_*"' "ok: grants atlassian_*"

  # The 2026-10-22 serve behaviour: 200 `true`, server ends `failed`.
  run_scenario failed-after-200
  assert_eq 1 "$rc" "failed-after-200: exits 1 despite HTTP 200"
  assert_not_contains "$work/out" "Connected" "failed-after-200: does not claim connected"
  assert_contains "$work/err" "status=failed (Failed to get tools)" "failed-after-200: surfaces the serve's status and error"
  no_grant failed-after-200
  stop_footer failed-after-200

  run_scenario needs-auth
  assert_eq 1 "$rc" "needs-auth: exits 1"
  assert_contains "$work/err" "status=needs_auth" "needs-auth: names the state"
  assert_contains "$work/err" "only the human can do" "needs-auth: says the human must re-auth"
  no_grant needs-auth

  # The 2026-10-22 symptom: door first-byte timeout, previously "pigeon down?".
  run_scenario door-timeout
  assert_eq 1 "$rc" "door-timeout: exits 1"
  assert_contains "$work/err" "first-byte timeout" "door-timeout: names the door's timeout"
  assert_contains "$work/err" "NOT that pigeon is down" "door-timeout: explicitly not pigeon"
  assert_not_contains "$work/err" "pigeon down?" "door-timeout: old misleading message is gone"
  no_grant door-timeout
  stop_footer door-timeout

  run_scenario pigeon-down
  assert_eq 1 "$rc" "pigeon-down: exits 1"
  assert_contains "$work/err" "pigeon is unavailable" "pigeon-down: a real pigeon 503 still says pigeon"
  no_grant pigeon-down

  run_scenario not-configured
  assert_eq 1 "$rc" "not-configured: exits 1"
  assert_contains "$work/err" "not configured on this host" "not-configured: says so"
  assert_contains "$work/err" "configured servers: slack-ro" "not-configured: lists configured servers when no match"
  assert_contains "$work/err" "caller error" "not-configured: says unknown name is caller error"
  assert_contains "$work/err" "calling the service's API directly" "not-configured: warns against direct API call"
  assert_not_contains "$work/err" "Stop and report" "not-configured: does not use the escalate footer"
  no_grant not-configured

  run_scenario did-you-mean chrome-devtools
  assert_eq 1 "$rc" "did-you-mean: exits 1"
  assert_contains "$work/err" "not configured on this host" "did-you-mean: says so"
  assert_contains "$work/err" "did you mean: chrome-devtools-9222, chrome-devtools-9223" "did-you-mean: suggests prefix/substring matches"
  assert_contains "$work/err" "caller error" "did-you-mean: says unknown name is caller error"
  assert_contains "$work/err" "calling the service's API directly" "did-you-mean: warns against direct API call"
  assert_not_contains "$work/err" "Stop and report" "did-you-mean: does not use the escalate footer"
  no_grant did-you-mean

  run_scenario not-configured-list-fails
  assert_eq 1 "$rc" "not-configured-list-fails: exits 1"
  assert_contains "$work/err" "not configured on this host" "not-configured-list-fails: says so"
  assert_not_contains "$work/err" "configured servers:" "not-configured-list-fails: no server list when fetch fails"
  assert_not_contains "$work/err" "did you mean:" "not-configured-list-fails: no suggestions when fetch fails"
  assert_not_contains "$work/err" "caller error" "not-configured-list-fails: no caller error footer when fetch fails"
  stop_footer not-configured-list-fails
  no_grant not-configured-list-fails

  # Could not READ the state: warn, do not claim connected, still grant (inert
  # if the tools do not exist). Distinct from a state that reads as failed.
  run_scenario status-unreadable
  assert_eq 0 "$rc" "status-unreadable: exits 0 (unknown is not failed)"
  assert_not_contains "$work/out" "Connected" "status-unreadable: does not claim connected"
  assert_contains "$work/err" "could not be read back" "status-unreadable: says the state is unknown"
  assert_contains "$work/patches" '"atlassian_*"' "status-unreadable: still grants"

  echo "oc-mcp-enable behaviour tests ran"
else
  printf 'SKIP  behaviour tests (OC_MCP_ENABLE_BIN unset)\n'
fi

echo "all oc-mcp-enable helper tests passed"
