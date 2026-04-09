# Devbox-specific tmux configuration with plugins
# Uses /persist volume for tmux state (survives NixOS rebuilds)
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  programs.tmux = {
    plugins = with pkgs.tmuxPlugins; [
      # Theme: Catppuccin
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"

          # Window tabs: show window name (#W) so manual renames work
          set -g @catppuccin_window_text " #W"
          set -g @catppuccin_window_current_text " #W"

          # Right status: two pills with different colors (date darker, time lighter)
          # Using Catppuccin mocha colors: surface0 (#313244) and surface1 (#45475a)
          set -g status-right "#[fg=#cdd6f4,bg=#313244] %d/%m #[fg=#cdd6f4,bg=#45475a] %H:%M:%S "
        '';
      }
    ];
  };
}
