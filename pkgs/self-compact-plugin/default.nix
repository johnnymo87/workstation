# Builds the self-compact opencode plugin as a self-contained JavaScript
# bundle. See docs/plans/2026-04-21-self-compact-bundle-design.md for the
# original design and docs/plans/2026-06-22-durable-bun-fod-design.md for the
# content-addressed deps migration (workstation-g9fe).
#
# All mechanism (and the reasoning behind it) lives in
# pkgs/opencode-plugin-bundle/default.nix, shared with the other bundled
# opencode plugins.
{ lib
, stdenvNoCC
, bun
, nodejs
, importNpmLock
}:

import ../opencode-plugin-bundle {
  inherit lib stdenvNoCC bun nodejs importNpmLock;
  pname = "self-compact-plugin";
  entry = "self-compact";
  description = "Self-contained bundle for the OpenCode self-compact plugin";
}
