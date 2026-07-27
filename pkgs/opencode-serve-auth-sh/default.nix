{ pkgs }:

pkgs.writeText "opencode-serve-auth.sh" (builtins.readFile ./opencode-serve-auth.sh)
