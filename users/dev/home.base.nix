# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, llm-agents, assetsPath, ... }:

let
  # Packages from llm-agents.nix flake (use hostPlatform.system for idiomaticity)
  llmPkgs = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  # Wrapper script for ccusage statusline with absolute path
  # This ensures the command works regardless of Claude's PATH
  claudeStatusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = [ llmPkgs.ccusage ];
    text = ''
      exec ccusage statusline --offline
    '';
  };

  # Managed settings fragment - only keys we want to control
  # Claude Code's runtime state (feedbackSurveyState, enabledPlugins, etc.) is preserved
  # On Darwin, we skip statusLine to preserve the custom dotfiles statusline.sh
  managedSettings = lib.optionalAttrs (!pkgs.stdenv.isDarwin) {
    statusLine = {
      type = "command";
      command = lib.getExe claudeStatusline;
    };
  };

  managedSettingsJson = pkgs.writeText "claude-settings.managed.json"
    (builtins.toJSON managedSettings);
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # LLM tools from numtide/llm-agents.nix
    llmPkgs.claude-code
    llmPkgs.ccusage
    llmPkgs.beads

    # Other tools
    pkgs.devenv
  ];

  # Git
  programs.git = {
    enable = true;
    signing.key = "0C0EF2DF7ADD5DD9";
    settings = {
      user.name = "Jonathan Mohrbacher";
      user.email = "jonathan.mohrbacher@gmail.com";
      init.defaultBranch = "main";
      push.autoSetupRemote = true;
      pull.rebase = true;
      commit.gpgsign = true;
      gpg.format = "openpgp";
      alias = {
        st = "status";
        co = "checkout";
        br = "branch";
        ci = "commit";
        lg = "log --oneline --graph --decorate";
      };
    };
  };

  # GPG
  programs.gpg = {
    enable = true;
    settings.no-autostart = true;
  };

  # Tmux
  programs.tmux = {
    enable = true;
    clock24 = true;
    terminal = "tmux-256color";
    historyLimit = 10000;
    extraConfig = ''
      set -g mouse on
      set -g base-index 1
      setw -g pane-base-index 1
      set -g renumber-windows on
      set -ag terminal-overrides ",xterm-256color:RGB"
      source-file ~/.config/tmux/extra.conf
    '';
  };

  # Tmux extra config (OSC 52 clipboard, etc.)
  xdg.configFile."tmux/extra.conf".source = "${assetsPath}/tmux/extra.conf";

  # Neovim
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  xdg.configFile."nvim/lua/user" = {
    source = "${assetsPath}/nvim/lua/user";
    recursive = true;
  };

  # Direnv
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      ".." = "cd ..";
      "..." = "cd ../..";
    };
    initExtra = ''
      export GPG_TTY=$(tty)
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend
    '';
  };

  # SSH
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;  # Silence deprecation warning; defaults mirror SSH's own
    extraConfig = ''
      Host github.com
        HostName github.com
        User git
        IdentityFile ~/.ssh/id_ed25519_github
        IdentitiesOnly yes
    '';
  };

  # FZF
  programs.fzf = {
    enable = true;
    enableBashIntegration = true;
  };

  # Session path
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.npm-global/bin"
  ];

  # Claude skills and commands - managed individually for gradual migration
  # As we migrate each skill/command from dotfiles to HM, add it here.
  # On Darwin, remove the corresponding dotfiles symlink after adding here.
  home.file.".claude/commands/ask-question.md".source = "${assetsPath}/claude/commands/ask-question.md";
  home.file.".claude/commands/beads.md".source = "${assetsPath}/claude/commands/beads.md";

  # Managed settings fragment (read-only, Nix store symlink)
  home.file.".claude/settings.managed.json".source = managedSettingsJson;

  # Merge managed settings into the real settings.json on each switch
  # This preserves Claude Code's runtime state while enforcing our config
  home.activation.mergeClaudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    runtime="$HOME/.claude/settings.json"
    managed="$HOME/.claude/settings.managed.json"

    # Ensure directory exists (handles fresh install)
    mkdir -p "$(dirname "$runtime")"

    # Treat missing/empty runtime file as {}
    if [[ -s "$runtime" ]]; then
      base="$runtime"
    else
      base="$(mktemp)"
      echo '{}' > "$base"
    fi

    tmp="$(mktemp "''${runtime}.tmp.XXXXXX")"

    # Merge strategy: runtime first, then managed => managed wins on conflicts,
    # but unmentioned runtime keys (feedbackSurveyState, etc.) are preserved
    ${pkgs.jq}/bin/jq -S -s '.[0] * .[1]' "$base" "$managed" > "$tmp"

    mv "$tmp" "$runtime"
    [[ "$base" == "$runtime" ]] || rm -f "$base"
  '';
}
