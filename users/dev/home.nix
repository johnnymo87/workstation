# Home-manager configuration for dev user
{ config, pkgs, lib, self, llm-agents, assetsPath, projects, ... }:

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
  managedSettings = {
    statusLine = {
      type = "command";
      command = lib.getExe claudeStatusline;
    };
  };

  managedSettingsJson = pkgs.writeText "claude-settings.managed.json"
    (builtins.toJSON managedSettings);
in
{
  home.username = "dev";
  home.homeDirectory = "/home/dev";

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

  # Claude skills from assets
  home.file.".claude/skills" = {
    source = "${assetsPath}/claude/skills";
    recursive = true;
  };

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

  # Mask GPG agent sockets for forwarding
  home.activation.maskGpgAgentSockets = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/systemd/user"
    for socket in gpg-agent.socket gpg-agent-extra.socket gpg-agent-browser.socket gpg-agent-ssh.socket; do
      ln -sf /dev/null "$HOME/.config/systemd/user/$socket"
    done
    ${pkgs.systemd}/bin/systemctl --user daemon-reload 2>/dev/null || true
  '';

  # Generate ensure-projects script from declarative manifest
  home.file.".local/bin/ensure-projects" = {
    executable = true;
    text = let
      mkLine = name: p: ''
        ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
      '';
      lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
    in ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Refuse to run if /persist isn't mounted
      if ! ${pkgs.util-linux}/bin/findmnt -rn /persist >/dev/null; then
        echo "ERROR: /persist is not mounted; refusing to clone."
        exit 1
      fi

      # Verify SSH key exists
      if [ ! -f "$HOME/.ssh/id_ed25519_github" ]; then
        echo "ERROR: GitHub SSH key not found at ~/.ssh/id_ed25519_github"
        echo "Run: sudo nixos-rebuild switch --flake .#devbox"
        exit 1
      fi

      base="$HOME/projects"

      ensure_repo() {
        local name="$1"
        local url="$2"
        local dir="$base/$name"

        if [ -d "$dir/.git" ]; then
          echo "OK: $name exists"
          return 0
        fi

        echo "Cloning $name ..."
        ${pkgs.git}/bin/git clone --recursive "$url" "$dir"
      }

      ${lines}

      echo "All projects ready."
    '';
  };

  # Systemd user service to ensure projects on login
  systemd.user.services.ensure-projects = {
    Unit = {
      Description = "Ensure declared dev projects are present in ~/projects";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/ensure-projects";
      StandardOutput = "journal";
      StandardError = "journal";
      Environment = [
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh"
        "HOME=%h"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  home.stateVersion = "25.11";
}
