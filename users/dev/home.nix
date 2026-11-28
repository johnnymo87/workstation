# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.devbox.nix
    ./home.cloudbox.nix
    ./gnome-keyring.nix
    ./disk-cleanup.nix
    ./em-drift-detector.nix
    ./quota-telemetry.nix
    ./em-test-postgres.nix
    ./tec-codex-bot.nix
    ./tec-codex-wiki-scrape.nix
    ./tec-codex-forum-scrape.nix
    ./em-skill-curator.nix
    ./em-journal-curator.nix
    ./hm-deploy-gate.nix
    ./hm-atomic-profile.nix
    ./opencode-llm-audit.nix
    ./home.darwin.nix
    ./codex-lb.nix
    ./oc-tags-serve.nix
    ./agents-instructions.nix
    ./opencode-config.nix
    ./opencode-skills.nix
    ./goose-roles.nix
    ./goose-config.nix
    ./goose-providers.nix
    ./goose-agent.nix
    ./tmux.devbox.nix
    ./tmux.cloudbox.nix
    ./tmux.darwin.nix
  ];
}
