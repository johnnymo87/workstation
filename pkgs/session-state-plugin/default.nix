# Builds the session-state overlay writer as a self-contained JavaScript bundle.
# See docs/plans/2026-07-12-opencode-session-switcher-design.md (Task 3).
#
# This plugin is TWO files -- session-state.ts (the factory) and
# session-state-impl.ts (pure helpers) -- which is exactly the case that cannot
# be deployed as per-file xdg.configFile entries. The header of
# pkgs/opencode-plugin-bundle/default.nix explains why, and holds all the
# mechanism shared with the other bundled opencode plugins.
{ lib
, stdenvNoCC
, bun
, nodejs
, importNpmLock
}:

import ../opencode-plugin-bundle {
  inherit lib stdenvNoCC bun nodejs importNpmLock;
  pname = "session-state-plugin";
  entry = "session-state";
  description = "Self-contained bundle for the OpenCode session-state overlay writer";
}
