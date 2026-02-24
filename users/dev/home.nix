# Home-manager entry point
# Imports all modules - platform-specific ones use mkIf internally
{ pkgs, lib, ... }:

{
  imports = [
    ./home.base.nix
    ./home.devbox.nix
    ./home.crostini.nix
    ./home.darwin.nix
    ./opencode-config.nix
    ./opencode-skills.nix
    ./tmux.devbox.nix
    ./tmux.crostini.nix
    ./tmux.darwin.nix
  ];
}
