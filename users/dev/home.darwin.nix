# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
#
# GRADUAL MIGRATION STRATEGY:
# On Darwin, we disable programs that conflict with existing dotfiles.
# As we migrate each program to HM, remove the corresponding mkForce false.
# See: /tmp/research-nix-darwin-dotfiles-conflict-answer.md
{ config, pkgs, lib, assetsPath, isDarwin, ... }:

lib.mkIf isDarwin {
  # Screenshot-to-devbox script (macOS only, uses screencapture + pbcopy)
  # Note: No runtimeInputs for openssh - we want the system SSH which supports UseKeychain
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
  ];

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

  # Disable nvim lua user/ files from assets (conflicts with existing dotfiles nvim config)
  xdg.configFile."nvim/lua/user".enable = lib.mkForce false;

  # On Darwin, dotfiles symlinks ccremote.lua but we want HM to manage it.
  # Remove the dotfiles symlink before HM tries to create its own.
  home.activation.prepareNvimForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
  '';

  # Tmux extra config (disable if you have existing tmux config)
  # Uncomment if tmux conflicts:
  # xdg.configFile."tmux/extra.conf".enable = lib.mkForce false;
}
