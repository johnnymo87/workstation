#!/usr/bin/env bash
# Unit tests for opencode-launch --mcp tools-JSON builder.
# Mirrors build_mcp_tools_json from users/dev/home.base.nix.
# Run: bash users/dev/test-opencode-launch-mcp.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of home.base.nix) ----------------------------
# Given server names as args, print a compact JSON object mapping each
# "<server>_*" -> true, de-duplicated and stable-ordered. No args -> {}.
build_mcp_tools_json() {
  local tools_json='{}'
  local srv
  for srv in $(printf '%s\n' "$@" | awk 'NF' | sort -u); do
    tools_json=$(jq -c --arg k "${srv}_*" '. + {($k): true}' <<<"$tools_json")
  done
  printf '%s\n' "$tools_json"
}

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=1; fi
}

check "no servers -> {}" '{}' "$(build_mcp_tools_json)"
check "slack -> slack_*"  '{"slack_*":true}' "$(build_mcp_tools_json slack)"
check "two servers"       '{"atlassian_*":true,"slack_*":true}' \
  "$(build_mcp_tools_json slack atlassian)"
check "dedup"             '{"slack_*":true}' "$(build_mcp_tools_json slack slack)"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME TESTS FAILED"; exit 1; }
