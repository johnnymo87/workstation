#!/usr/bin/env bash
# Durability tests for the session-state overlay-writer bundle. All assertions
# (and the reasoning) live in the shared runner, which every bundled plugin uses.
#
# Run: bash pkgs/session-state-plugin/test.sh
set -o errexit -o nounset -o pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/../opencode-plugin-bundle/test.sh" \
  session-state-plugin session-state
