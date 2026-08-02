{ pkgs }:

pkgs.writeText "opencode-store-prefix.sh" (builtins.readFile ./opencode-store-prefix.sh)
