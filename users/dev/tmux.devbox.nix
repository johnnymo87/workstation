# Devbox-specific tmux configuration with plugins
# Includes session persistence (resurrect/continuum) and Catppuccin theme
# Uses /persist volume for resurrect data (survives NixOS rebuilds)
#
# Plugin ordering is CRITICAL:
# 1. resurrect - must load before continuum
# 2. catppuccin - theme must load before continuum to avoid status-right conflicts
# 3. continuum - MUST BE LAST (uses status-right hook for autosave)
#
# WARNING: Do NOT set status-right in extraConfig - it will clobber continuum's autosave hook
{ config, pkgs, lib, isDevbox, ... }:

let
  resurrectDir = "/persist/tmux/${config.home.username}/resurrect";
in
lib.mkIf isDevbox {
  programs.tmux = {
    # Plugin ordering is CRITICAL - see module header comment
    plugins = with pkgs.tmuxPlugins; [
      # 1. Resurrect: save/restore sessions
      {
        plugin = resurrect;
        extraConfig = ''
          # Persist resurrect data to survive NixOS rebuilds
          set -g @resurrect-dir '${resurrectDir}'
          # Restore neovim sessions (requires Session.vim in nvim)
          set -g @resurrect-strategy-nvim 'session'
          # Match nvim anywhere in command (tilde), restore as plain nvim (arrow)
          # Nix wraps nvim with complex --cmd flags that break session restore
          # NOTE: Escape the > to prevent shell redirect during resurrect's eval
          set -g @resurrect-processes '"~nvim->nvim"'
        '';
      }

      # 2. Theme: Catppuccin (before continuum to avoid status-right conflicts)
      {
        plugin = catppuccin;
        extraConfig = ''
          set -g @catppuccin_flavor "mocha"

          # Window tabs: show window name (#W) so manual renames work
          set -g @catppuccin_window_text " #W"
          set -g @catppuccin_window_current_text " #W"

          # Right status: two pills with different colors (date darker, time lighter)
          # Using Catppuccin mocha colors: surface0 (#313244) and surface1 (#45475a)
          # Continuum will prepend its hook after this
          set -g status-right "#[fg=#cdd6f4,bg=#313244] %d/%m #[fg=#cdd6f4,bg=#45475a] %H:%M:%S "
        '';
      }

      # 3. Continuum: auto-save/restore (MUST BE LAST - uses status-right hook)
      {
        plugin = continuum;
        extraConfig = ''
          # Auto-restore session when tmux server starts
          set -g @continuum-restore 'on'
          # Auto-save every 15 minutes
          set -g @continuum-save-interval '15'
          # Skip boot options (irrelevant for headless server, use systemd instead)
        '';
      }
    ];
  };

  # Ensure resurrect directory exists on persistent volume
  home.activation.ensureTmuxResurrectDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p '${resurrectDir}'
      chmod 700 '${resurrectDir}'
    '';
}
