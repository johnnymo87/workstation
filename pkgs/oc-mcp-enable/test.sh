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

echo "all oc-mcp-enable helper tests passed"
