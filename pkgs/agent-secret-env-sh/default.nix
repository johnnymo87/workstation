{ pkgs }:

# Sourceable bash: exports sops-derived CLI/tool credentials for agent shells
# that have no opencode shell-env plugin (goose-serve). See the header of
# agent-secret-env.sh; the test asserts parity with shell-env.ts.
pkgs.writeText "agent-secret-env.sh" (builtins.readFile ./agent-secret-env.sh)
