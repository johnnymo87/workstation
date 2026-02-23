# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.devbox.nix
    ./home.crostini.nix
    ./home.darwin.nix
    ./claude-skills.nix
    ./claude-hooks.nix
    ./opencode-config.nix
    ./tmux.devbox.nix
    ./tmux.crostini.nix
    ./tmux.darwin.nix
  ];
}
