# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, localPkgs, devenv, assetsPath, isDarwin, isCloudbox, isCrostini, ... }:

let
  # Use devenv directly from cachix (no override, so cachix cache hits work)
  devenvPkg = devenv.packages.${pkgs.stdenv.hostPlatform.system}.default;

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
  # All 4 platforms built by the cached fork's CI
  opencode-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-bip7Rl1az9nbzD3GtY862ysH0AiRfsITiF2onsLzLgc=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-M0YiTRJuEiICzaPTGVlQCEyllOOeUFIez7yW4EnTINU=";
      isZip = true;
    };
    x86_64-linux = {
      asset = "opencode-linux-x64.tar.gz";
      hash = "sha256-ZIuNV3qu3vJV5sPWei/rVeLfy48F6khLDnS21ep8IfU=";
      isZip = false;
    };
    x86_64-darwin = {
      asset = "opencode-darwin-x64.zip";
      hash = "sha256-1/Mln9eq8CUCKqSQvc1KjH5w6X1lomMthTT8bWCwPNk=";
      isZip = true;
    };
  };

  opencode = let
    version = "1.2.14";
    platformInfo = opencode-platforms.${pkgs.stdenv.hostPlatform.system};
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
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # Self-packaged tools (in pkgs/, some auto-updated by CI)
    localPkgs.beads
    localPkgs.ccusage-opencode
    localPkgs.html2markdown
    opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Clipboard via tmux
    tcopy
    tpaste

    # GitHub CLI
    pkgs.gh

    # Other tools
    devenvPkg
  ]
  # Work tools (macOS + cloudbox only)
  ++ lib.optionals (isDarwin || isCloudbox) [
    localPkgs.acli
    localPkgs.datadog-mcp-cli
  ];

  # Bazel user config (~/.bazelrc)
  home.file.".bazelrc".text = lib.concatStringsSep "\n" ([
    "# Managed by home-manager — edits will be overwritten"
    ""
    "# Show test errors inline"
    "test --test_output errors"
    ""
    "# Local disk and repository caches"
    "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
  ] ++ lib.optionals pkgs.stdenv.isLinux [
    ""
    "# NixOS: explicit PATH for sandbox — forwarding alone doesn't cover all action types"
    "build --action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
    "build --host_action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
  ]);

  # Atlassian (non-secret; API token set per-platform via Keychain/sops)
  home.sessionVariables = {
    ATLASSIAN_EMAIL = "jmohrbacher@wonder.com";
    ATLASSIAN_CLOUD_ID = "70497edc-9c59-45b2-8e47-e46913d4c6cf";
  };

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
    publicKeys = lib.mkIf (!isCrostini) [
      {
        source = "${assetsPath}/gpg-signing-key.asc";
        trust = 5;  # ultimate (our own key)
      }
    ];
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
      require("user.sessions")    -- Session management for tmux-resurrect
      require("user.atlassian")   -- :FetchJiraTicket, :FetchConfluencePage
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

  # Nix binary caches (devenv uses its own nixpkgs, so cache avoids building from source)
  nix.package = pkgs.nix;
  nix.settings = {
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
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
