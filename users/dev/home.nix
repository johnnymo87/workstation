# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.devbox.nix
    ./home.cloudbox.nix
    ./disk-cleanup.nix
    ./opencode-llm-audit.nix
    ./home.darwin.nix
    ./codex-lb.nix
    ./opencode-config.nix
    ./opencode-skills.nix
    ./tmux.devbox.nix
    ./tmux.cloudbox.nix
    ./tmux.darwin.nix
  ];
}
