{ pkgs }:

# Sourceable bash library for the home-manager stale-deploy gate (bead
# workstation-h0mp). writeText, not writeShellApplication: it is `source`d by a
# home-manager activation script, not executed. Same shape as
# pkgs/opencode-plugin-canary-sh and pkgs/opencode-store-prefix-sh.
#
# Its tests run in `nix flake check` (flake.nix, check `hm-deploy-gate`).
pkgs.writeText "hm-deploy-gate.sh" (builtins.readFile ./hm-deploy-gate.sh)
