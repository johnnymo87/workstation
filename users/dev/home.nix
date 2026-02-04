# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.linux.nix
    ./home.darwin.nix
    ./claude-skills.nix
    ./claude-hooks.nix
    ./opencode-config.nix
    ./tmux.linux.nix
    ./tmux.darwin.nix
  ];
}
