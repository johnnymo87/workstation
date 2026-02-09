# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, llm-agents, assetsPath, ... }:

let
  # Packages from llm-agents.nix flake (use hostPlatform.system for idiomaticity)
  llmPkgs = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  # Linux: simple ccusage statusline
  linuxStatusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = [ llmPkgs.ccusage ];
    text = ''
      exec ccusage statusline --offline
    '';
  };

  # Darwin: custom statusline with context tracking, git branch, and cost info
  darwinStatusline = pkgs.writeShellApplication {
    name = "claude-statusline";
    runtimeInputs = [ pkgs.jq pkgs.git pkgs.bc pkgs.coreutils ];
    text = builtins.readFile "${assetsPath}/scripts/statusline.sh";
  };

  # Pick the right statusline for the platform
  claudeStatusline = if pkgs.stdenv.isDarwin then darwinStatusline else linuxStatusline;

  # Clipboard commands via tmux (work over SSH, inside tmux sessions)
  tcopy = pkgs.writeShellApplication {
    name = "tcopy";
    runtimeInputs = [ pkgs.tmux ];
    text = builtins.readFile "${assetsPath}/scripts/tcopy.bash";
  };

  tpaste = pkgs.writeShellApplication {
    name = "tpaste";
    runtimeInputs = [ pkgs.tmux ];
    text = builtins.readFile "${assetsPath}/scripts/tpaste.bash";
  };

  # Managed settings fragment - only keys we want to control
  # Claude Code's runtime state (feedbackSurveyState, enabledPlugins, etc.) is preserved
  managedSettings = {
    hooks = {
      SessionStart = [{
        matcher = "compact|startup|resume";
        hooks = [{
          type = "command";
          command = config.claude.hooks.sessionStartPath;
        }];
      }];
      Stop = [{
        hooks = [{
          type = "command";
          command = config.claude.hooks.stopPath;
        }];
      }];
    };
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
    llmPkgs.opencode
    llmPkgs.ccusage-opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Clipboard via tmux
    tcopy
    tpaste

    # Other tools
    pkgs.devenv
  ];

  # Git
  programs.git = {
    enable = true;
    signing.key = "0C0EF2DF7ADD5DD9";
    ignores = [
      "Session.vim"  # vim-obsession session files (for tmux-resurrect)
    ];
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

  # GPG - shared settings (both platforms)
  programs.gpg = {
    enable = true;
    package = pkgs.gnupg;  # Use nixpkgs GPG for consistency
    settings = {
      auto-key-retrieve = true;
      no-emit-version = true;
      # NOTE: no-autostart is NOT here - it's Linux-only (see home.linux.nix)
    };
  };

  # Dirmngr config (keyserver) - manual file since dirmngrSettings not in our HM version
  home.file.".gnupg/dirmngr.conf".text = ''
    keyserver hkps://keys.openpgp.org
  '';

  # common.conf is platform-specific - see home.linux.nix and home.darwin.nix

  # Tmux
  programs.tmux = {
    enable = true;
    clock24 = true;
    terminal = "tmux-256color";
    historyLimit = 50000;  # Generous scrollback for long build logs
    extraConfig = ''
      # Prefix key: Ctrl-a (easier to reach than Ctrl-b)
      unbind C-b
      set -g prefix C-a
      bind C-a send-prefix    # Press C-a twice to send C-a to nested tmux/app

      # Usability
      set -g mouse on
      set -g renumber-windows on
      set -g allow-rename off     # Don't let programs rename windows via escape sequences
      set -g automatic-rename off # Don't auto-rename based on running command; manual names stick

      # Vi keybindings
      set -g status-keys vi      # Vi keys in command prompt (prefix + :)
      set -g mode-keys vi        # Vi keys in copy mode

      # Modern terminal integration
      set -g focus-events on     # Pass focus events to apps (neovim FocusGained/Lost)
      set -s escape-time 10      # Responsive Esc (tmux 3.5+ default is 10ms)

      # Truecolor support
      set -ag terminal-overrides ",xterm-256color:RGB"

      # Load extra config if it exists (safe during partial migration)
      if-shell -b '[ -f ~/.config/tmux/extra.conf ]' 'source-file ~/.config/tmux/extra.conf'
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

    # Session management for tmux-resurrect integration
    plugins = with pkgs.vimPlugins; [
      vim-obsession
    ];

    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.sessions")  -- Session management for tmux-resurrect
      require("ccremote").setup()
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # Deploys entire lua/ directory to support both user/ configs and top-level modules like ccremote
  xdg.configFile."nvim/lua" = {
    source = "${assetsPath}/nvim/lua";
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
      # GPG TTY - tmux-aware (from deprecated-dotfiles)
      if [ -n "$TMUX" ]; then
          export GPG_TTY=$(tmux display-message -p '#{pane_tty}')
      else
          export GPG_TTY=$(tty)
      fi
      export HISTSIZE=10000
      export HISTFILESIZE=20000
      export HISTCONTROL=ignoredups:erasedups
      shopt -s histappend

      # Claude Code Remote helpers
      ${builtins.readFile "${assetsPath}/bash/claude.bash"}
    '';
  };

  # SSH
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;  # Silence deprecation warning; defaults mirror SSH's own
    matchBlocks."github.com" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_github";
      identitiesOnly = true;
    };
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
