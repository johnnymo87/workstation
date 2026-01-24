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

  # GPG: manages .gnupg/gpg.conf
  programs.gpg.enable = lib.mkForce false;

  # Neovim: generates init.lua
  programs.neovim.enable = lib.mkForce false;

  # Disable the entire nvim/lua recursive deployment from base config
  # (it conflicts with dotfiles-managed nvim config)
  xdg.configFile."nvim/lua".enable = lib.mkForce false;

  # Deploy only ccremote.lua (dotfiles init.lua already loads it)
  xdg.configFile."nvim/lua/ccremote.lua".source = "${assetsPath}/nvim/lua/ccremote.lua";

  # On Darwin, dotfiles creates symlinks that HM also wants to manage.
  # Remove dotfiles symlinks before HM tries to create its own.
  # Also clean up renamed/removed skills and commands.
  home.activation.prepareForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.claude/commands/ask-question.md 2>/dev/null || true
    rm -f ~/.claude/commands/beads.md 2>/dev/null || true
    rm -f ~/.claude/commands/notify-telegram.md 2>/dev/null || true
    rm -rf ~/.claude/skills/ask-question 2>/dev/null || true
    rm -rf ~/.claude/skills/using-telegram-notifications 2>/dev/null || true
    rm -rf ~/.claude/skills/using-beads-for-issue-tracking 2>/dev/null || true
    rm -f ~/.claude/hooks/on-session-start.sh 2>/dev/null || true
    rm -f ~/.claude/hooks/on-stop.sh 2>/dev/null || true
  '';

  # Tmux extra config (disable if you have existing tmux config)
  # Uncomment if tmux conflicts:
  # xdg.configFile."tmux/extra.conf".enable = lib.mkForce false;
}
