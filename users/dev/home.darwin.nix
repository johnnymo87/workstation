# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
#
# GRADUAL MIGRATION STRATEGY:
# On Darwin, we disable programs that conflict with existing dotfiles.
# As we migrate each program to HM, remove the corresponding mkForce false.
# See: /tmp/research-nix-darwin-dotfiles-conflict-answer.md
{ config, pkgs, lib, assetsPath, isDarwin, ccrTunnel, pinentry-op, projects, ... }:

lib.mkIf isDarwin {
  # Dotfiles repository still hosts many legacy bash snippets on macOS.
  # We let HM own ~/.bashrc.d and bridge individual files via out-of-store symlinks
  # so snippets can migrate to workstation one-by-one.
  home.file = let
    dotfilesDir = "${config.home.homeDirectory}/Code/dotfiles";
    legacyBashrcFiles = [
      "asdf.bashrc"
      "base.bashrc"
      "chrome-debug.bashrc"
      "claude.bashrc"
      "copy-paste.bashrc"
      "cpp.bashrc"
      "direnv.bashrc"
      "docker.bashrc"
      "git.bashrc"
      "go.bashrc"
      "gpg.bashrc"
      "kubectl.bashrc"
      "mac.bashrc"
      "mcp.bashrc"
      "minecraft.bashrc"
      "mise.bashrc"
      "nix.bashrc"
      "nodenv.bashrc"
      "prompt.bashrc"
      "py.bashrc"
      "rb.bashrc"
      "rust.bashrc"
      "unknown-origin.bashrc"
    ];
  in
    lib.listToAttrs (map
      (name: {
        name = ".bashrc.d/${name}";
        value.source = config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/.bashrc.d/${name}";
      })
      legacyBashrcFiles)
    // {
      ".bashrc.d/home-manager.bashrc".text = ''
        # Home-manager bridge (Darwin)
        # Keep a stable alias while bash migration is in progress.
        alias ssdb='screenshot-to-devbox'
      '';

      # Darwin common.conf - empty (no special options needed locally)
      ".gnupg/common.conf".text = "";
    };

  # Screenshot-to-devbox script (macOS only, uses screencapture + pbcopy)
  # Note: No runtimeInputs for openssh - we want the system SSH which supports UseKeychain
  home.packages = [
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.cloudflared
    pinentry-op
    (pkgs.writeShellApplication {
      name = "pigeon-setup-secrets";
      runtimeInputs = [ pkgs._1password-cli ];
      text = ''
        echo "Populating macOS Keychain with pigeon secrets from 1Password..."
        echo "You may be prompted by 1Password for authentication."
        echo ""

        secrets=(
          "pigeon-ccr-api-key:op://Automation/ccr-secrets/CCR_API_KEY"
          "pigeon-telegram-bot-token:op://Automation/ccr-secrets/TELEGRAM_BOT_TOKEN"
          "pigeon-telegram-chat-id:op://Automation/ccr-secrets/TELEGRAM_CHAT_ID"
          "pigeon-telegram-webhook-secret:op://Automation/ccr-secrets/TELEGRAM_WEBHOOK_SECRET"
          "pigeon-telegram-webhook-path-secret:op://Automation/ccr-secrets/TELEGRAM_WEBHOOK_PATH_SECRET"
        )

        for entry in "''${secrets[@]}"; do
          name="''${entry%%:*}"
          ref="''${entry#*:}"
          echo "  Reading $name ..."
          value=$(op read "$ref")
          # Delete existing entry if present (ignore errors)
          security delete-generic-password -s "$name" 2>/dev/null || true
          security add-generic-password -a "$USER" -s "$name" -w "$value"
          echo "  Stored $name in Keychain"
        done

        echo ""
        echo "Done. You can now start the pigeon daemon:"
        echo "  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/org.nix-community.home.pigeon-daemon.plist"
      '';
    })
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

  # Pigeon daemon launchd agent — all secrets from macOS Keychain
  # Run `pigeon-setup-secrets` once in a terminal to populate Keychain from 1Password
  launchd.agents.pigeon-daemon = {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/sh" "-c"
        ''
          SEC="/usr/bin/security"
          export CCR_API_KEY="$($SEC find-generic-password -s pigeon-ccr-api-key -w)"
          export TELEGRAM_BOT_TOKEN="$($SEC find-generic-password -s pigeon-telegram-bot-token -w)"
          export TELEGRAM_CHAT_ID="$($SEC find-generic-password -s pigeon-telegram-chat-id -w)"
          export TELEGRAM_WEBHOOK_SECRET="$($SEC find-generic-password -s pigeon-telegram-webhook-secret -w)"
          export TELEGRAM_WEBHOOK_PATH_SECRET="$($SEC find-generic-password -s pigeon-telegram-webhook-path-secret -w)"
          cd "${config.home.homeDirectory}/Code/pigeon/packages/daemon"
          exec ${pkgs.nodejs}/bin/node \
            node_modules/tsx/dist/cli.mjs \
            src/index.ts
        ''
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
        NODE_ENV = "production";
        CCR_WORKER_URL = "https://ccr-router.jonathan-mohrbacher.workers.dev";
        CCR_MACHINE_ID = "macbook";
        PATH = lib.concatStringsSep ":" [
          "${pkgs.nodejs}/bin"
          "${pkgs.neovim}/bin"
          "/usr/bin"
          "/bin"
        ];
      };
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pigeon-daemon.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pigeon-daemon.err.log";
    };
  };

  # ============================================================
  # DISABLED PROGRAMS (using existing dotfiles instead)
  # Remove these overrides one-by-one as you migrate to HM
  # ============================================================

  # Bash is now managed by home-manager. Legacy snippets are sourced from ~/.bashrc.d.
  programs.bash = {
    initExtra = lib.mkAfter ''
      for file in ~/.bashrc.d/*.bashrc; do
        [ -r "$file" ] && source "$file"
      done
    '';
    shellAliases = {
      ssdb = "screenshot-to-devbox";
    };
  };

  # SSH: manages .ssh/config
  programs.ssh.enable = lib.mkForce false;

  # 1Password secret reference for GPG passphrase
  # pinentry-op fetches from this 1Password item using Touch ID
  home.sessionVariables = {
    OP_GPG_SECRET_REF = "op://Automation/gpg-passphrase/password";
    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    # These call mcp.exa.ai with no API key (free tier). If rate-limited (429),
    # obtain a free key at exa.ai and set OPENCODE_ENABLE_EXA=https://mcp.exa.ai/mcp?exaApiKey=<key>
    OPENCODE_ENABLE_EXA = "1";
  };

  # GPG: fully managed by home-manager on Darwin
  # Agent runs locally (auto-starts on demand), keys live here, forwarded to devbox via SSH
  #
  # Uses pinentry-op to fetch passphrase from 1Password (with Touch ID).
  # Set OP_GPG_SECRET_REF env var to your 1Password secret reference.
  # Falls back to pinentry-mac GUI if 1Password fails.
  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 86400;    # 24 hours
    maxCacheTtl = 86400;        # 24 hours
    enableExtraSocket = false;  # We set path manually in extraConfig
    grabKeyboardAndMouse = false;
    extraConfig = ''
      pinentry-program ${pinentry-op}/bin/pinentry-op
      # Pin extra-socket path for stable SSH RemoteForward config
      extra-socket ${config.home.homeDirectory}/.gnupg/S.gpg-agent.extra
    '';
  };

  # Disable home-manager's launchd socket-activated service (doesn't work with gpg-agent)
  # gpg-agent --supervised expects systemd-style LISTEN_FDS, not launchd's launch_activate_socket()
  # Instead, let GnuPG auto-start the agent on demand (upstream recommended approach)
  launchd.agents.gpg-agent.enable = lib.mkForce false;

  # Neovim: generates init.lua
  programs.neovim.enable = lib.mkForce false;

  # Disable recursive nvim/lua/user deployment from home.base.nix
  # On Darwin, dotfiles owns the user/ directory
  xdg.configFile."nvim/lua/user".enable = lib.mkForce false;

  # Deploy only specific lua files - user/ directory is managed entirely by dotfiles
  # on Darwin. Home-manager can't overlay files into a symlinked directory,
  # and creating the directory breaks the dotfiles symlink to user/*.lua modules.
  xdg.configFile."nvim/lua/user/sessions.lua".source = "${assetsPath}/nvim/lua/user/sessions.lua";

  # On Darwin, dotfiles creates symlinks that HM also wants to manage.
  # Remove dotfiles symlinks before HM tries to create its own.
  # Also clean up renamed/removed skills and commands.
  home.activation.ensureProjects = let
    mkLine = name: p: ''
      ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
    '';
    lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
  in lib.hm.dag.entryAfter ["writeBoundary"] ''
    ensure_repo() {
      local name="$1"
      local url="$2"
      local dir="${config.home.homeDirectory}/Code/$name"

      if [ -d "$dir/.git" ]; then
        return 0
      fi

      echo "Cloning $name to ~/Code ..."
      GIT_SSH_COMMAND="/usr/bin/ssh" ${pkgs.git}/bin/git clone --recursive "$url" "$dir"
    }

    mkdir -p "${config.home.homeDirectory}/Code"
    ${lines}

    # Post-clone: install pigeon dependencies
    if [ -d "${config.home.homeDirectory}/Code/pigeon" ] && [ ! -d "${config.home.homeDirectory}/Code/pigeon/node_modules" ]; then
      echo "Installing pigeon dependencies ..."
      (cd "${config.home.homeDirectory}/Code/pigeon" && ${pkgs.bun}/bin/bun install)
    fi

    # Check if pigeon Keychain secrets are populated
    if ! /usr/bin/security find-generic-password -s pigeon-ccr-api-key -w >/dev/null 2>&1; then
      echo ""
      echo "⚠ Pigeon Keychain secrets not found. Run: pigeon-setup-secrets"
      echo ""
    fi
  '';

  home.activation.prepareForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    if [ -L ~/.bashrc ]; then rm -f ~/.bashrc; fi
    if [ -L ~/.bash_profile ]; then rm -f ~/.bash_profile; fi
    if [ -L ~/.profile ]; then rm -f ~/.profile; fi
    if [ -L ~/.bashrc.d ]; then rm -f ~/.bashrc.d; fi
    rm -f ~/.gnupg/gpg.conf 2>/dev/null || true
    rm -f ~/.gnupg/gpg-agent.conf 2>/dev/null || true
    rm -f ~/.gnupg/dirmngr.conf 2>/dev/null || true
    rm -f ~/.gnupg/common.conf 2>/dev/null || true
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/pigeon.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/user/sessions.lua 2>/dev/null || true
    rm -f ~/.claude/hooks 2>/dev/null || true
  '';

  # Tmux extra config (disable if you have existing tmux config)
  # Uncomment if tmux conflicts:
  # xdg.configFile."tmux/extra.conf".enable = lib.mkForce false;

  # Auto-expire old home-manager generations (same as Linux)
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };
}
