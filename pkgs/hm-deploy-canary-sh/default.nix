{ pkgs }:

# Sourceable bash library for the home-manager drift canary (workstation-4ze8).
# writeText, not writeShellApplication: it is `source`d by the canary unit's
# script alongside pkgs/hm-deploy-gate-sh, not executed. Same shape as
# pkgs/hm-deploy-gate-sh and pkgs/opencode-plugin-canary-sh.
#
# Its tests run in `nix flake check` (flake.nix, check `hm-deploy-canary`).
pkgs.writeText "hm-deploy-canary.sh" (builtins.readFile ./hm-deploy-canary.sh)
