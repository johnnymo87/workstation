# Cross-platform home-manager configuration
# Platform-specific code lives in home.linux.nix and home.darwin.nix
{ config, pkgs, lib, localPkgs, assetsPath, isDarwin, isCloudbox, isCrostini, ... }:

let

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

  opencode-launch = pkgs.writeShellApplication {
    name = "opencode-launch";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

      usage() {
        echo "Usage: opencode-launch [directory] <prompt>"
        echo ""
        echo "Launch a headless opencode session."
        echo ""
        echo "  opencode-launch ~/projects/pigeon \"fix the test\""
        echo "  opencode-launch \"fix the test\"  # uses current directory"
        exit 1
      }

      if [ $# -eq 0 ]; then
        usage
      elif [ $# -eq 1 ]; then
        directory="$PWD"
        prompt="$1"
      else
        directory="$1"
        shift
        prompt="$*"
      fi

      # Resolve ~ to $HOME
      directory="''${directory/#\~/$HOME}"

      # Health check
      if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        echo "Error: opencode serve is not reachable at $OPENCODE_URL" >&2
        echo "Check: systemctl status opencode-serve (Linux) or launchctl list | grep opencode (macOS)" >&2
        exit 1
      fi

      # Create session
      session_response=$(curl -sf -X POST "$OPENCODE_URL/session" \
        -H "x-opencode-directory: $directory") || {
        echo "Error: failed to create session" >&2
        exit 1
      }

      session_id=$(echo "$session_response" | jq -r '.id')
      if [ -z "$session_id" ] || [ "$session_id" = "null" ]; then
        echo "Error: no session ID in response: $session_response" >&2
        exit 1
      fi

      # Send prompt
      curl -sf -X POST "$OPENCODE_URL/session/$session_id/prompt_async" \
        -H "x-opencode-directory: $directory" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg p "$prompt" '{parts: [{type: "text", text: $p}]}')" >/dev/null || {
        echo "Error: failed to send prompt to session $session_id" >&2
        exit 1
      }

      echo "Session launched: $session_id"
      echo "Directory: $directory"
      echo ""
      echo "Attach:  opencode attach $OPENCODE_URL --session $session_id"
      echo "Kill:    curl -sf -X DELETE $OPENCODE_URL/session/$session_id"
    '';
  };

  # Patched opencode with improved Anthropic prompt caching (PR #5422)
  # https://github.com/johnnymo87/opencode-cached
  # All 4 platforms built by the cached fork's CI
  opencode-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-muLNqGAVOldysQ9iAPMcI303XntCeA/Krbw85cWfDJA=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-v4Cs+zoOagKwaCJHmtuUvO/qJAaciq7P7Tgj0RsQI+I=";
      isZip = true;
    };
    x86_64-linux = {
      asset = "opencode-linux-x64.tar.gz";
      hash = "sha256-TbYuXKI94ykUQqxiQcU8fdaZguXywuPMS08gTeP4Ji8=";
      isZip = false;
    };
    x86_64-darwin = {
      asset = "opencode-darwin-x64.zip";
      hash = "sha256-aKzc9hErPZ8Doc0N9280lXewa5oBhK+6B4uz5El6Q+A=";
      isZip = true;
    };
  };

  opencode = let
    version = "1.2.25";
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

  # Azure CLI with msal 1.34.0 patch and azure-devops extension (work machines)
  # NOTE: azure-cli 2.79.0 ships msal 1.33.0 which has a bug where
  # `az login --use-device-code` crashes with "Session.request() got
  # an unexpected keyword argument 'claims_challenge'". Fixed in msal 1.34.0.
  # Remove this block when nixpkgs bumps azure-cli to >= 2.83.0.
  azureCliPatched = let
    msal134 = pkgs.python3Packages.msal.overridePythonAttrs (old: rec {
      version = "1.34.0";
      src = pkgs.python3Packages.fetchPypi {
        inherit (old) pname;
        inherit version;
        hash = "sha256-drqDtxbqWm11sCecCsNToOBbggyh9mgsDrf0UZDEPC8=";
      };
    });
    msal134Path = "${msal134}/${pkgs.python3.sitePackages}";
    msal133 = pkgs.python3Packages.msal;
    msal133Path = "${msal133}/${pkgs.python3.sitePackages}";
    azWithExts = pkgs.azure-cli.withExtensions (with pkgs.azure-cli.extensions; [
      azure-devops
    ]);
  in azWithExts.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      for f in $out/bin/az $out/bin/.az-wrapped $out/bin/.az-wrapped_; do
        if [ -f "$f" ]; then
          substituteInPlace "$f" \
            --replace-quiet "${msal133Path}" "${msal134Path}"
        fi
      done
    '';
  });
in
{
  # NOTE: home.username and home.homeDirectory are set per-host
  # (in flake.nix for Darwin, in home.linux.nix for NixOS devbox)

  # User packages
  home.packages = [
    # Self-packaged tools (in pkgs/, some auto-updated by CI)
    localPkgs.beads
    localPkgs.ccusage-opencode
    pkgs.pandoc
    opencode

    # Cloudflare Workers CLI
    pkgs.wrangler

    # Clipboard via tmux
    tcopy
    tpaste

    # Headless opencode session launcher
    opencode-launch

    # GitHub CLI
    pkgs.gh

    # Google Workspace CLI
    localPkgs.gws

    # Other tools
    pkgs.devenv

    # JavaScript runtime (used by pigeon and other projects)
    pkgs.bun
  ]
  # Work tools (macOS + cloudbox only)
  ++ lib.optionals (isDarwin || isCloudbox) [
    localPkgs.acli
    localPkgs.datadog-mcp-cli
    # Bazel mono repo needs zip at build time and java for ktlint execution.
    # rules_kotlin <2.3.0 falls back to system PATH for java:
    # https://github.com/bazelbuild/rules_kotlin/pull/1452
    pkgs.zip
    pkgs.jdk21
    # Cloud / Kubernetes
    azureCliPatched
    pkgs.awscli2       # AWS CLI (EKS kubeconfig credential plugin, ba exec SSO)
    pkgs.kubelogin     # Azure AD credential plugin for kubectl
    pkgs.kubectl       # Kubernetes CLI (for AKS clusters)
  ];

  # Bazel user config (~/.bazelrc) — work machines only
  home.file.".bazelrc" = lib.mkIf (isDarwin || isCloudbox) {
    text = lib.concatStringsSep "\n" ([
      "# Managed by home-manager — edits will be overwritten"
      ""
      "# Show test errors inline"
      "test --test_output errors"
      ""
      "# Local disk and repository caches"
      "common --disk_cache ~/bazel-diskcache --repository_cache ~/bazel-cache/repository"
      ""
      "# Reap idle Bazel servers after 15 min (default 3h) to free RAM across worktrees"
      "startup --max_idle_secs=900"
      ""
      "# Cap Kotlin persistent workers to 1 per worktree (default can spawn 2-3)"
      "build --worker_max_instances=KotlinCompile=1"
      "test  --worker_max_instances=KotlinCompile=1"
      ""
      "# Evict idle workers if they collectively exceed 2.5 GB"
      "build --experimental_total_worker_memory_limit_mb=2500"
      "build --experimental_shrink_worker_pool"
      "test  --experimental_total_worker_memory_limit_mb=2500"
      "test  --experimental_shrink_worker_pool"
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      ""
      "# NixOS: explicit PATH for sandbox — forwarding alone doesn't cover all action types"
      "build --action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      "build --host_action_env=PATH=/home/dev/.nix-profile/bin:/etc/profiles/per-user/dev/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"
      ""
      "# Auto-shutdown server when system is low on memory"
      "startup --shutdown_on_low_sys_mem"
    ]);
  };

  # Azure DevOps npm registry auth (~/.npmrc) — work machines only
  # Uses npm's native ${ENV_VAR} interpolation; ADO_NPM_PAT_B64 is exported
  # in platform-specific bash init (home.cloudbox.nix / home.darwin.nix).
  # We generate the file at activation time to avoid hardcoding the ADO registry URL
  # (which contains the employer org/project name) in the Nix config.
  home.activation.generateNpmrc = lib.mkIf (isDarwin || isCloudbox) (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    NPMRC_PATH="$HOME/.npmrc"
    rm -f "$NPMRC_PATH"
    REGISTRY_URL=""

    ${if isCloudbox then ''
      SECRET_PATH="/run/secrets/ado_npm_registry_url"
      if [ -f "$SECRET_PATH" ]; then
        REGISTRY_URL=$(cat "$SECRET_PATH")
      else
        echo "Warning: ADO npm registry secret not found at $SECRET_PATH"
      fi
    '' else ''
      if /usr/bin/security find-generic-password -s ado-npm-registry-url -w >/dev/null 2>&1; then
        REGISTRY_URL=$(/usr/bin/security find-generic-password -s ado-npm-registry-url -w)
      else
        echo "Warning: ADO npm registry URL not found in macOS Keychain (ado-npm-registry-url)"
      fi
    ''}

    if [ -n "$REGISTRY_URL" ]; then
      ORG_NAME=$(echo "$REGISTRY_URL" | cut -d/ -f4)
      cat > "$NPMRC_PATH" <<EOF
; begin auth token
$REGISTRY_URL/registry/:username=$ORG_NAME
$REGISTRY_URL/registry/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/registry/:email=npm requires email to be set but doesn't use the value
$REGISTRY_URL/:username=$ORG_NAME
$REGISTRY_URL/:_password=\''${ADO_NPM_PAT_B64}
$REGISTRY_URL/:email=npm requires email to be set but doesn't use the value
; end auth token
EOF
    else
      cat > "$NPMRC_PATH" <<EOF
; ADO npm registry URL secret not found during activation
; Add it to sops (Cloudbox) or Keychain (Darwin) and run rebuild
EOF
    fi
  '');

  # Install/update ba CLI from private GitHub release (work machines)
  # Downloads platform-appropriate binary, caches by version in ~/.local/bin
  # macOS: reads ba_cli_repo from Keychain, GH token from gh CLI auth
  # Cloudbox: reads both from sops-nix secrets at /run/secrets/
  home.activation.installBaCli = lib.mkIf (isDarwin || isCloudbox) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] (let
      platform = if isDarwin then "darwin" else "linux";
      asset = "ba-${platform}-arm64.tar.gz";
    in ''
      ba_repo=""
      ${if isCloudbox then ''
        if [ -r /run/secrets/ba_cli_repo ]; then
          ba_repo="$(cat /run/secrets/ba_cli_repo)"
        fi
      '' else ''
        ba_repo="$(/usr/bin/security find-generic-password -s ba-cli-repo -w 2>/dev/null || true)"
      ''}

      if [ -z "$ba_repo" ]; then
        echo "installBaCli: skipping (ba_cli_repo not available)"
      else
        gh_token=""
        ${if isCloudbox then ''
          if [ -r /run/secrets/github_api_token ]; then
            gh_token="$(cat /run/secrets/github_api_token)"
          fi
        '' else ''
          gh_token="$(${pkgs.gh}/bin/gh auth token 2>/dev/null || true)"
        ''}

        if [ -z "$gh_token" ]; then
          echo "installBaCli: skipping (GitHub token not available)"
        else
          latest=$(GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh api \
            "repos/$ba_repo/releases/latest" --jq .tag_name 2>/dev/null || true)

          if [ -z "$latest" ]; then
            echo "installBaCli: WARNING: could not fetch latest release"
          else
            current=""
            if [ -x "$HOME/.local/bin/ba" ]; then
              current=$("$HOME/.local/bin/ba" --version 2>/dev/null \
                | ${pkgs.gnugrep}/bin/grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' \
                | head -1 || true)
            fi

            if [ "$current" = "$latest" ]; then
              echo "installBaCli: ba $latest already installed"
            else
              echo "installBaCli: installing ba $latest (was: ''${current:-not installed})..."
              ${pkgs.coreutils}/bin/mkdir -p "$HOME/.local/bin"
              tmpdir=$(${pkgs.coreutils}/bin/mktemp -d)
              if GH_TOKEN="$gh_token" ${pkgs.gh}/bin/gh release download "$latest" \
                   --repo "$ba_repo" \
                   -p '${asset}' \
                   -D "$tmpdir" 2>/dev/null; then
                ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -xf "$tmpdir/${asset}" -C "$tmpdir"
                ${pkgs.coreutils}/bin/install -m 755 "$tmpdir/ba" "$HOME/.local/bin/ba"
                echo "installBaCli: ba $latest installed"
              else
                echo "installBaCli: WARNING: download failed"
              fi
              ${pkgs.coreutils}/bin/rm -rf "$tmpdir"
            fi
          fi
        fi
      fi
    ''));

  # Cap JetBrains kotlin-lsp JVM heap — each OpenCode session spawns its
  # own instance; without a cap they grow to ~1.5 GB each.
  # IJ_JAVA_OPTIONS is read by JetBrains tools only (not generic JVMs).
  home.sessionVariables = lib.mkIf (isDarwin || isCloudbox) {
    IJ_JAVA_OPTIONS = "-Xms128m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC";
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
    shell = "${pkgs.bash}/bin/bash";  # Explicit: macOS defaults to zsh, but our config is all bash
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

    plugins = with pkgs.vimPlugins; [
      vim-obsession
      tabby-nvim
      goyo-vim
      mini-align
      plenary-nvim
      telescope-fzy-native-nvim
      telescope-nvim
      (nvim-treesitter.withPlugins (p: with p; [
        bash c comment css csv diff dockerfile
        editorconfig git_config gitcommit gitignore go
        html http javascript json json5 lua luadoc
        make markdown markdown_inline nix python
        regex ruby sql ssh_config tmux toml
        typescript vimdoc xml yaml
      ]))
      (pkgs.vimUtils.buildVimPlugin {
        pname = "vim-ripgrep";
        version = "unstable-2026-01-13";
        src = pkgs.fetchFromGitHub {
          owner = "jremmen";
          repo = "vim-ripgrep";
          rev = "2bb2425387b449a0cd65a54ceb85e123d7a320b8";
          hash = "sha256-OvQPTEiXOHI0uz0+6AVTxyJ/TUMg6kd3BYTAbnCI7W8=";
        };
      })
    ];

    extraPackages = [ pkgs.ripgrep ];

    extraLuaConfig = ''
      require("user.settings")
      require("user.mappings")
      require("user.sessions")          -- tmux-resurrect session management
      require("user.tabby")             -- OpenCode session tab labels
      require("user.cursor_highlight")  -- Ctrl+K cursor crosshair toggle
      require("user.telescope")         -- treesitter + telescope + keymaps
      require("mini.align").setup()     -- text alignment (ga/gA)
    '' + lib.optionalString (isDarwin || isCloudbox) ''
      require("user.atlassian")         -- :FetchJiraTicket, :FetchConfluencePage
    '';
  };

  # Neovim Lua config files (kept separate from HM-managed init.vim)
  # User config modules from workstation assets
  xdg.configFile."nvim/lua/user" = {
    source = "${assetsPath}/nvim/lua/user";
    recursive = true;
  };

  # Home Manager (standalone command on PATH for all platforms)
  programs.home-manager.enable = true;

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
      # Vertex AI: Gemini 3.x models require the "global" endpoint.
      # Without this, OpenCode defaults to "us-east5" which 404s on newer models.
      export GOOGLE_CLOUD_LOCATION="global"

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

  # Nix binary caches (devenv projects use their own flake inputs, cachix avoids rebuilds)
  # mkDefault: in module mode (nix-darwin/NixOS), home-manager's nixos/common.nix
  # forwards the system nix.package into each user, causing a duplicate definition
  # error. mkDefault lets the system's value win. In standalone mode (devbox),
  # this provides the required package for nix.settings below. (HM #5870)
  nix.package = lib.mkDefault pkgs.nix;
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
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
