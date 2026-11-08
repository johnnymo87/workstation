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
    ./em-skill-curator.nix
    ./hm-deploy-gate.nix
    ./opencode-llm-audit.nix
    ./home.darwin.nix
    ./codex-lb.nix
    ./oc-tags-serve.nix
    ./agents-instructions.nix
    ./opencode-config.nix
    ./opencode-skills.nix
    ./goose-roles.nix
    ./goose-config.nix
    ./tmux.devbox.nix
    ./tmux.cloudbox.nix
    ./tmux.darwin.nix
  ];
}
