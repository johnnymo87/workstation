#!/usr/bin/env bash
# unwired-test(workstation-dimz): tautology, not live state -- it REDEFINES build_mcp_tools_json (:11-14) and asserts against its own copy, so wiring it would add a check that cannot fail. Production is pkgs/opencode-launch/default.nix:177-180, whose call site pkgs/opencode-launch/test.sh:346 already greps
# Unit tests for opencode-launch --mcp tools-JSON builder.
# Mirrors build_mcp_tools_json from pkgs/opencode-launch/default.nix:177-180.
# (This header used to name users/dev/home.base.nix, which contains no such
# function -- the claim was repeated as fact during the k7t4 audit before being
# checked. See the marker above: this file is a tautology and belongs to dimz.)
# Run: bash users/dev/test-opencode-launch-mcp.sh
set -o errexit -o nounset -o pipefail

# ---- helper under test (mirror of home.base.nix) ----------------------------
# Given server names as args, print a compact JSON object mapping each
# "<server>_*" -> true, de-duplicated and stable-ordered. No args -> {}.
build_mcp_tools_json() {
  printf '%s\n' "$@" | jq -R -s -c '
    split("\n") | map(select(. != "")) | unique | map({(. + "_*"): true}) | add // {}'
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
