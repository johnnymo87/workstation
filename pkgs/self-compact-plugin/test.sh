#!/usr/bin/env bash
# Durability tests for the self-compact bundle. All assertions (and the
# reasoning) live in the shared runner, which every bundled plugin uses.
#
# Run: bash pkgs/self-compact-plugin/test.sh
set -o errexit -o nounset -o pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/../opencode-plugin-bundle/test.sh" \
  self-compact-plugin self-compact
