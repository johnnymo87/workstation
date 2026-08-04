{ pkgs }:

# Sourceable bash library for the plugin-load canary (E2, bead workstation-5yox).
# writeText, not writeShellApplication: it is `source`d by a systemd oneshot, not
# executed. Same shape as pkgs/opencode-store-prefix-sh.
#
# Its tests run in `nix flake check` (flake.nix, check `plugin-canary`).
pkgs.writeText "opencode-plugin-canary.sh" (builtins.readFile ./opencode-plugin-canary.sh)
