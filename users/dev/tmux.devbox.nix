# Devbox-specific tmux configuration with plugins
# Uses /persist volume for tmux state (survives NixOS rebuilds)
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  # Keep a detached `main` session alive across reboots.
  #
  # Without this, a reboot leaves no tmux server at all, so
  # `mosh devbox -- tmux attach -t main` fails instantly and the mosh session
  # exits with it. That reads as "mosh is broken" rather than "the session is
  # gone", which is how it was reported after the 2026-08-25 reboot.
  #
  # Started through a LOGIN shell on purpose. home-manager's
  # ~/.config/environment.d/10-home-manager.conf does NOT export PATH, so a bare
  # ExecStart would hand the server systemd's minimal PATH and every pane would
  # inherit it. `bash -lc` sources the profile so the server gets the real one.
  #
  # Type=forking + KillMode=process: `tmux new-session -d` forks the server and
  # exits; without KillMode=process systemd would sweep the daemonized server
  # when that short-lived starter exits.
  #
  # `-A` makes it idempotent (attach-or-create), so restarting the unit while a
  # server is already up does not fail with "duplicate session".
  #
  # Deliberately NOT ordered on or bound to opencode-serve-pool: this must stay
  # out of that cgroup, or the 3 AM nightly restart of the pool would kill it.
  systemd.user.services.tmux-main = {
    Unit = {
      Description = "Detached tmux session 'main'";
    };
    Service = {
      Type = "forking";
      KillMode = "process";
      ExecStart = "${pkgs.bash}/bin/bash -lc '${config.programs.tmux.package}/bin/tmux new-session -A -d -s main'";
      ExecStop = "${config.programs.tmux.package}/bin/tmux kill-session -t main";
      # A crashed server should come back; an intentional `tmux kill-server`
      # exits 0 and is left alone.
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

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
