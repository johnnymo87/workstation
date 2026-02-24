# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, llm-agents, devenv, assetsPath, ... }:

let
  # Packages from llm-agents.nix flake (use hostPlatform.system for idiomaticity)
  llmPkgs = llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  # Use the latest devenv tool directly from cachix, but override to skip tests
  # since they try to modify /nix/var/nix/profiles and fail in the sandbox
  devenvPkg = devenv.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
    doCheck = false;
  });

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

  # Patched opencode with improved Anthropic prompt caching (PR #5422)
  # https://github.com/johnnymo87/opencode-cached
  # Only available for aarch64-{linux,darwin}; falls back to upstream on x86_64
  opencode-cached-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-VsApVybxdCAMg6vvUymOp7u//+aLdObXxgiYOAh2e8c=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-n7YgEFHjLhCtzniZNtT5Phf/DIl3cWOuNSRSqUKWeEg=";
      isZip = true;
    };
  };

  opencode-cached = let
    version = "1.2.10";
    platformInfo = opencode-cached-platforms.${pkgs.stdenv.hostPlatform.system};
  in pkgs.stdenv.mkDerivation {
    pname = "opencode-cached";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/johnnymo87/opencode-cached/releases/download/v${version}-cached/${platformInfo.asset}";
      hash = platformInfo.hash;
    };
    nativeBuildInputs = [ pkgs.makeWrapper ]
      ++ lib.optionals platformInfo.isZip [ pkgs.unzip ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.autoPatchelfHook
      ];
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      pkgs.stdenv.cc.cc.lib
    ];
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    unpackPhase = ''
      runHook preUnpack
    '' + lib.optionalString platformInfo.isZip ''
      unzip $src
    '' + lib.optionalString (!platformInfo.isZip) ''
      tar -xzf $src
    '' + ''
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m755 bin/opencode $out/bin/opencode
      wrapProgram $out/bin/opencode \
        --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.ripgrep ]}
      runHook postInstall
    '';
    meta = {
      description = "OpenCode with improved Anthropic prompt caching";
      homepage = "https://github.com/johnnymo87/opencode-cached";
      mainProgram = "opencode";
    };
  };

  # Use cached fork where available, upstream otherwise (e.g. x86_64-linux)
  opencode = if builtins.hasAttr pkgs.stdenv.hostPlatform.system opencode-cached-platforms
    then opencode-cached
    else llmPkgs.opencode;
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # LLM tools from numtide/llm-agents.nix
    llmPkgs.ccusage
    llmPkgs.beads
    opencode
    llmPkgs.ccusage-opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Clipboard via tmux
    tcopy
    tpaste

    # GitHub CLI
    pkgs.gh

    # Other tools
    devenvPkg
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
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # User config modules from workstation assets
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

  # npm-global packages that can't be managed by Nix
  # (e.g. nixpkgs version is too old, or package not in nixpkgs)
  # Installed to ~/.npm-global which is already on sessionPath
  home.activation.installNpmGlobalPackages = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    export PATH="${pkgs.nodejs}/bin:$PATH"
    export npm_config_prefix="$HOME/.npm-global"

    # playwright-mcp: nixpkgs has 0.0.56, we need 0.0.68+ for devtools cap
    wanted="0.0.68"
    current="$(npm ls -g --prefix "$HOME/.npm-global" @playwright/mcp --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.dependencies["@playwright/mcp"].version // empty' 2>/dev/null || true)"
    if [[ "$current" != "$wanted" ]]; then
      echo "Installing @playwright/mcp@$wanted (have: ''${current:-none})"
      npm install -g "@playwright/mcp@$wanted" --prefix "$HOME/.npm-global" --no-fund --no-audit 2>&1 || true
    fi
  '';

}
