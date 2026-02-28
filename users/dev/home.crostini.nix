# Crostini (ChromeOS Linux) home-manager configuration
# Chromebook-specific settings: identity, sops secrets via HM module, pigeon daemon
{ config, pkgs, lib, isCrostini, ccrTunnel, projects, ... }:

lib.mkIf isCrostini {
  # Chromebook identity
  home.username = "livia";
  home.homeDirectory = "/home/livia";

  home.stateVersion = "25.11";

  # Packages
  home.packages = [
    pkgs.cloudflared
    pkgs._1password-cli
  ];

  # sops-nix home-manager secrets (decrypted during activation)
  # Age key must be placed at this path before first `home-manager switch`
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets/chromebook.yaml;
    secrets = {
      gemini_api_key = {};
      cloudflared_tunnel_token = {};
      op_service_account_token = {};
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
        "CCR_WORKER_URL=https://ccr-router.jonathan-mohrbacher.workers.dev"
        "CCR_MACHINE_ID=chromebook"
        "PATH=${lib.makeBinPath [ pkgs.nodejs pkgs.bash pkgs.coreutils pkgs.neovim ]}"
      ];
      ExecStart = "${pkgs.writeShellScript "pigeon-daemon-start" ''
        set -euo pipefail
        export OP_SERVICE_ACCOUNT_TOKEN="$(cat ${config.sops.secrets.op_service_account_token.path})"
        exec ${pkgs._1password-cli}/bin/op run \
          --env-file=${config.home.homeDirectory}/projects/pigeon/.env.1password -- \
          ${pkgs.nodejs}/bin/node \
          node_modules/tsx/dist/cli.mjs \
          src/index.ts
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
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
      (cd "${config.home.homeDirectory}/projects/pigeon" && ${pkgs.nodejs}/bin/npm install)
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
