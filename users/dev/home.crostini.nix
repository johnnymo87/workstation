# Crostini (ChromeOS Linux) home-manager configuration
# Chromebook-specific settings: identity, sops secrets via HM module, pigeon daemon
{ config, pkgs, lib, isCrostini, projects, ... }:

lib.mkIf isCrostini {
  # Chromebook identity
  home.username = "livia";
  home.homeDirectory = "/home/livia";

  home.stateVersion = "25.11";

  # Packages
  home.packages = [
    pkgs.cloudflared
  ];

  # sops-nix home-manager secrets (decrypted during activation)
  # Age key must be placed at this path before first `home-manager switch`
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets/chromebook.yaml;
    secrets = {
      gemini_api_key = {};
      cloudflared_tunnel_token = {};
      ccr_worker_url = {};
      # Pigeon daemon secrets
      ccr_api_key = {};
      telegram_bot_token = {};
      telegram_chat_id = {};
      # DoltHub credential (Ed25519 JWK) for `bd dolt push/pull` beads backup.
      # Lands at config.sops.secrets.dolthub_jwk.path; symlinked into dolt's
      # creds dir by home.activation.deployDoltCreds below.
      dolthub_jwk = {};
      # DoltHub REST API token for creating DoltHub databases (v1alpha1 API)
      dolthub_api_token = {};
    };
  };

  # Crostini (Debian) tmux fix: re-source Nix profile from .bashrc
  #
  # Problem: tmux starts a login shell which re-runs /etc/profile (resetting
  # PATH to just system dirs). Normally /etc/profile.d/nix.sh restores Nix
  # paths, but nix-daemon.sh has a once-per-shell guard (__ETC_PROFILE_NIX_SOURCED)
  # that's inherited from the parent shell, so the script exits immediately
  # without re-adding Nix to PATH.
  #
  # Fix: unset the guard and re-source nix-daemon.sh from .bashrc, which runs
  # after /etc/profile has clobbered PATH.
  programs.bash.initExtra = lib.mkAfter ''
    # Re-source Nix and HM profiles (tmux login shell fix — see comment above)
    # Both scripts have once-per-shell guards inherited from the parent env.
    unset __ETC_PROFILE_NIX_SOURCED
    if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
      . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
    fi

    unset __HM_SESS_VARS_SOURCED
    if [ -e "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
      . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
    fi

    if [ -r "${config.sops.secrets.gemini_api_key.path}" ]; then
      export GOOGLE_GENERATIVE_AI_API_KEY="$(cat "${config.sops.secrets.gemini_api_key.path}")"
    fi

    # DoltHub REST API token for creating DoltHub databases (v1alpha1 API)
    if [ -r "${config.sops.secrets.dolthub_api_token.path}" ]; then
      export DOLTHUB_API_TOKEN="$(cat "${config.sops.secrets.dolthub_api_token.path}")"
    fi
  '';

  # Cloudflare Tunnel for pigeon webhooks (systemd user service)
  systemd.user.services.cloudflared-tunnel = {
    Unit = {
      Description = "Cloudflare Tunnel for pigeon webhooks";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.writeShellScript "cloudflared-run" ''
        exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run \
          --token "$(cat ${config.sops.secrets.cloudflared_tunnel_token.path})"
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Pigeon daemon (systemd user service, depends on cloudflared)
  systemd.user.services.pigeon-daemon = {
    Unit = {
      Description = "Pigeon daemon service";
      After = [ "network-online.target" "cloudflared-tunnel.service" ];
      Wants = [ "network-online.target" ];
      Requires = [ "cloudflared-tunnel.service" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = "${config.home.homeDirectory}/projects/pigeon/packages/daemon";
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "NODE_ENV=production"
        "CCR_MACHINE_ID=chromebook"
        "PATH=${lib.makeBinPath [ pkgs.nodejs pkgs.bash pkgs.coreutils pkgs.neovim ]}"
      ];
      ExecStart = "${pkgs.writeShellScript "pigeon-daemon-start" ''
        set -euo pipefail
        export CCR_WORKER_URL="$(cat ${config.sops.secrets.ccr_worker_url.path})"
        export CCR_API_KEY="$(cat ${config.sops.secrets.ccr_api_key.path})"
        export TELEGRAM_BOT_TOKEN="$(cat ${config.sops.secrets.telegram_bot_token.path})"
        export TELEGRAM_CHAT_ID="$(cat ${config.sops.secrets.telegram_chat_id.path})"
        export OPENCODE_URL="http://127.0.0.1:4096"
        exec ${pkgs.nodejs}/bin/node \
          ${config.home.homeDirectory}/projects/pigeon/node_modules/tsx/dist/cli.mjs \
          ${config.home.homeDirectory}/projects/pigeon/packages/daemon/src/index.ts
      ''}";
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # OpenCode headless serve (for launching sessions from CLI or Telegram)
  systemd.user.services.opencode-serve = {
    Unit = {
      Description = "OpenCode headless serve";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "PATH=${lib.makeBinPath [
          pkgs.git pkgs.openssh pkgs.fzf pkgs.ripgrep pkgs.gh pkgs.bun
          pkgs.nodejs pkgs.curl pkgs.wget pkgs.jq pkgs.fd pkgs.unzip
          pkgs.gnumake pkgs.gcc
          pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused
        ]}:${config.home.homeDirectory}/.nix-profile/bin"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        if [ -r "${config.sops.secrets.gemini_api_key.path}" ]; then
          export GOOGLE_GENERATIVE_AI_API_KEY="$(cat "${config.sops.secrets.gemini_api_key.path}")"
        fi
        exec ${config.home.homeDirectory}/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Override git identity from home.base.nix
  # Livia has her own GitHub account; disable GPG signing (no key on this machine)
  programs.git = {
    signing.key = lib.mkForce null;
    settings = {
      user.name = lib.mkForce "Livia Delacroix";
      user.email = lib.mkForce "delacroix.livialou@gmail.com";
      commit.gpgsign = lib.mkForce false;
    };
  };

  # Deploy the shared DoltHub credential used by `bd dolt push/pull` to back up
  # the git-free beads issue DB (remote configured in .beads/config.yaml). The
  # home-manager sops module decrypts secrets asynchronously (systemd user
  # service), so we do NOT read the secret content at activation time. Instead we
  # symlink dolt's creds path to the sops-managed secret (resolved lazily when
  # dolt reads it) and write the non-secret config_global.json pointer
  # deterministically. The keyid is stable and identical on every host.
  home.activation.deployDoltCreds = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail

    keyid="6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve"
    creds_dir="$HOME/.dolt/creds"
    mkdir -p "$creds_dir"

    # Dangling-safe: the target is populated by the sops-nix user service.
    ln -sfn "${config.sops.secrets.dolthub_jwk.path}" "$creds_dir/$keyid.jwk"

    # Point dolt at this credential without dropping any other config keys.
    cfg="$HOME/.dolt/config_global.json"
    existing="{}"
    [ -f "$cfg" ] && existing="$(cat "$cfg")"
    ctmp="$(mktemp "$HOME/.dolt/config_global.json.tmp.XXXXXX")"
    printf '%s' "$existing" | ${pkgs.jq}/bin/jq --arg k "$keyid" '.["user.creds"] = $k' > "$ctmp"
    mv "$ctmp" "$cfg"

    echo "deployDoltCreds: dolt credential symlinked + configured"
  '';

  # Ensure declared projects are cloned (runs during home-manager switch)
  home.activation.ensureProjects = let
    mkLine = name: p: ''
      ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
    '';
    lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
  in lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ensure_repo() {
      local name="$1"
      local url="$2"
      local dir="${config.home.homeDirectory}/projects/$name"

      if [ -d "$dir/.git" ]; then
        return 0
      fi

      echo "Cloning $name ..."
      GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh" ${pkgs.git}/bin/git clone --recursive "$url" "$dir" || echo "WARNING: Failed to clone $name (check SSH access)"
    }

    mkdir -p "${config.home.homeDirectory}/projects"
    ${lines}

    # Post-clone: install pigeon dependencies
    if [ -d "${config.home.homeDirectory}/projects/pigeon" ] && [ ! -d "${config.home.homeDirectory}/projects/pigeon/node_modules" ]; then
      echo "Installing pigeon dependencies ..."
      (cd "${config.home.homeDirectory}/projects/pigeon" && PATH="${pkgs.nodejs}/bin:$PATH" ${pkgs.nodejs}/bin/npm install)
    fi
  '';

  # Auto-expire old home-manager generations
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };
}
