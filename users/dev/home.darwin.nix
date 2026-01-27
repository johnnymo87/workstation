# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
#
# GRADUAL MIGRATION STRATEGY:
# On Darwin, we disable programs that conflict with existing dotfiles.
# As we migrate each program to HM, remove the corresponding mkForce false.
# See: /tmp/research-nix-darwin-dotfiles-conflict-answer.md
{ config, pkgs, lib, assetsPath, isDarwin, ccrTunnel, ... }:

lib.mkIf isDarwin {
  # Screenshot-to-devbox script (macOS only, uses screencapture + pbcopy)
  # Note: No runtimeInputs for openssh - we want the system SSH which supports UseKeychain
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.cloudflared
  ];

  # Cloudflare Tunnel launchd agent with Keychain-sourced token
  launchd.agents.cloudflared-ccr = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh" "-c"
        ''
          TUNNEL_TOKEN="$(/usr/bin/security find-generic-password -s cloudflared-tunnel-token -w)"
          exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
        ''
      ];
      RunAtLoad = false;  # Start manually, not at login
      KeepAlive = false;  # Don't auto-restart
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.err.log";
    };
  };

  # ============================================================
  # DISABLED PROGRAMS (using existing dotfiles instead)
  # Remove these overrides one-by-one as you migrate to HM
  # ============================================================

  # Bash: manages .bashrc, .bash_profile, .profile
  # Note: ssdb alias won't work until bash is migrated - use full command instead
  programs.bash.enable = lib.mkForce false;

  # SSH: manages .ssh/config
  programs.ssh.enable = lib.mkForce false;

  # GPG: fully managed by home-manager on Darwin
  # Agent runs locally (auto-starts on demand), keys live here, forwarded to devbox via SSH
  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 600;      # 10 minutes
    maxCacheTtl = 7200;         # 2 hours
    enableExtraSocket = false;  # We set path manually in extraConfig
    grabKeyboardAndMouse = false;  # Not needed for pinentry-mac (X11-only feature)
    pinentry.package = pkgs.pinentry_mac;
    extraConfig = ''
      # Pin extra-socket path for stable SSH RemoteForward config
      extra-socket ${config.home.homeDirectory}/.gnupg/S.gpg-agent.extra
    '';
  };

  # Disable home-manager's launchd socket-activated service (doesn't work with gpg-agent)
  # gpg-agent --supervised expects systemd-style LISTEN_FDS, not launchd's launch_activate_socket()
  # Instead, let GnuPG auto-start the agent on demand (upstream recommended approach)
  launchd.agents.gpg-agent.enable = lib.mkForce false;

  # Darwin common.conf - empty (no special options needed locally)
  home.file.".gnupg/common.conf".text = "";

  # Neovim: generates init.lua
  programs.neovim.enable = lib.mkForce false;

  # Disable recursive nvim/lua deployment from home.base.nix
  # On Darwin, dotfiles owns the user/ directory
  xdg.configFile."nvim/lua".enable = lib.mkForce false;

  # Deploy only ccremote.lua - user/ directory is managed entirely by dotfiles
  # on Darwin. Home-manager can't overlay files into a symlinked directory,
  # and creating the directory breaks the dotfiles symlink to user/*.lua modules.
  xdg.configFile."nvim/lua/ccremote.lua".source = "${assetsPath}/nvim/lua/ccremote.lua";

  # On Darwin, dotfiles creates symlinks that HM also wants to manage.
  # Remove dotfiles symlinks before HM tries to create its own.
  # Also clean up renamed/removed skills and commands.
  home.activation.prepareForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    rm -f ~/.gnupg/gpg.conf 2>/dev/null || true
    rm -f ~/.gnupg/gpg-agent.conf 2>/dev/null || true
    rm -f ~/.gnupg/dirmngr.conf 2>/dev/null || true
    rm -f ~/.gnupg/common.conf 2>/dev/null || true
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.claude/commands/ask-question.md 2>/dev/null || true
    rm -f ~/.claude/commands/beads.md 2>/dev/null || true
    rm -f ~/.claude/commands/notify-telegram.md 2>/dev/null || true
    rm -rf ~/.claude/skills/ask-question 2>/dev/null || true
    rm -rf ~/.claude/skills/using-telegram-notifications 2>/dev/null || true
    rm -rf ~/.claude/skills/using-beads-for-issue-tracking 2>/dev/null || true
    rm -f ~/.claude/hooks/on-session-start.sh 2>/dev/null || true
    rm -f ~/.claude/hooks/on-stop.sh 2>/dev/null || true
    rm -f ~/.claude/statusline.sh 2>/dev/null || true
  '';

  # Tmux extra config (disable if you have existing tmux config)
  # Uncomment if tmux conflicts:
  # xdg.configFile."tmux/extra.conf".enable = lib.mkForce false;
}
