# NixOS system configuration for devbox
{ config, pkgs, lib, ccrTunnel, ... }:

{
  # sops-nix configuration
  sops = {
    defaultSopsFile = ../../secrets/devbox.yaml;
    age = {
      # Key will be at this path on the devbox
      keyFile = "/persist/sops-age-key.txt";
      generateKey = false;
    };
    secrets = {
      github_ssh_key = {
        owner = "dev";
        group = "dev";
        mode = "0600";
        path = "/home/dev/.ssh/id_ed25519_github";
      };
      cloudflared_tunnel_token = {
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
      };
      cloudflare_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # 1Password service account token (bootstrap for CCR and other app secrets)
      op_service_account_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Personal Claude subscription token (not work account)
      # For headless/cron Claude Code usage on devbox
      claude_personal_oauth_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      openai_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      r2_account_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      r2_access_key_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      r2_secret_access_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
    };

  };

  # cloudflared service user
  users.groups.cloudflared = {};
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    description = "Cloudflare Tunnel daemon user";
  };

  # Cloudflare Tunnel for CCR webhooks (dashboard-managed with token)
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel for CCR webhooks";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      User = "cloudflared";
      Group = "cloudflared";
      ExecStart = "${pkgs.writeShellScript "cloudflared-run" ''
        exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run \
          --token "$(cat ${config.sops.secrets.cloudflared_tunnel_token.path})"
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Pigeon daemon service (depends on cloudflared)
  systemd.services.pigeon-daemon = {
    description = "Pigeon daemon service";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "cloudflared-tunnel.service" ];
    requires = [ "cloudflared-tunnel.service" ];

    path = [ pkgs.nodejs pkgs.bash pkgs.coreutils pkgs.neovim ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/pigeon/packages/daemon";
      Environment = [
        "HOME=/home/dev"
        "NODE_ENV=production"
        "CCR_WORKER_URL=https://ccr-router.jonathan-mohrbacher.workers.dev"
        "CCR_MACHINE_ID=devbox"
      ];
      ExecStart = "${pkgs.writeShellScript "pigeon-daemon-start" ''
        set -euo pipefail
        export OP_SERVICE_ACCOUNT_TOKEN="$(cat /run/secrets/op_service_account_token)"
        exec /nix/store/2cxyi2vivwqkw6fc46ssfmz1ch4z041s-1password-cli-2.32.0/bin/op run --env-file=/home/dev/projects/pigeon/.env.1password -- \
          ${pkgs.nodejs}/bin/node /home/dev/projects/pigeon/packages/daemon/node_modules/tsx/dist/cli.mjs /home/dev/projects/pigeon/packages/daemon/src/index.ts
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Optional: Stack target to start/stop both together
  systemd.targets.pigeon = {
    description = "Pigeon stack (cloudflared + daemon)";
    wants = [ "cloudflared-tunnel.service" "pigeon-daemon.service" ];
  };

  systemd.services.my-podcasts-consumer = {
    description = "My Podcasts queue consumer";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    path = [ pkgs.python314 pkgs.ffmpeg pkgs.uv pkgs.bash pkgs.coreutils ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/my-podcasts";
      Environment = [
        "HOME=/home/dev"
        "CLOUDFLARE_QUEUE_ID=fb2d616c57034fed8e6505a4ccd315b9"
        "NLTK_DATA=/persist/my-podcasts/nltk_data"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      ExecStartPre = "${pkgs.writeShellScript "my-podcasts-consumer-setup" ''
        set -euo pipefail
        cd /home/dev/projects/my-podcasts
        ${pkgs.uv}/bin/uv sync --frozen
        ${pkgs.uv}/bin/uv run python -c "import pathlib, ssl, certifi, nltk; pathlib.Path('/persist/my-podcasts/nltk_data').mkdir(parents=True, exist_ok=True); ssl._create_default_https_context=lambda: ssl.create_default_context(cafile=certifi.where()); nltk.download('punkt_tab', download_dir='/persist/my-podcasts/nltk_data', quiet=True)"
      ''}";
      ExecStart = "${pkgs.writeShellScript "my-podcasts-consumer-start" ''
        set -euo pipefail
        export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
        export R2_ACCOUNT_ID="$(cat /run/secrets/r2_account_id)"
        export R2_ACCESS_KEY_ID="$(cat /run/secrets/r2_access_key_id)"
        export R2_SECRET_ACCESS_KEY="$(cat /run/secrets/r2_secret_access_key)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        cd /home/dev/projects/my-podcasts
        exec ${pkgs.uv}/bin/uv run python -m pipeline consume
      ''}";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  # System identity
  networking.hostName = "devbox";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable running dynamically linked binaries (needed for npm packages)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Common libraries for npm native binaries
    stdenv.cc.cc.lib
  ];

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    auto-optimise-store = true;
    extra-substituters = [
      "https://cache.numtide.com"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # System packages
  environment.systemPackages = with pkgs; [
    git curl wget htop jq unzip
    ripgrep fd fzf
    gnumake gcc
    tmux direnv neovim
    gh gnupg pinentry-curses
    python314 ffmpeg uv
  ];

  # SSH server
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ "dev" ];
      X11Forwarding = false;
      StreamLocalBindUnlink = "yes";
    };
  };

  networking.firewall.enable = true;

  # Persistent volume for state that survives rebuilds
  fileSystems."/persist" = {
    device = "/dev/disk/by-id/scsi-0HC_Volume_104378953";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  # Bind mount projects from persistent volume
  fileSystems."/home/dev/projects" = {
    device = "/persist/projects";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/persist" ];
  };

  systemd.tmpfiles.rules = [
    # Claude state
    "d /persist/claude 0700 dev dev -"
    "L+ /home/dev/.claude - - - - /persist/claude"
    # Projects directory on persistent volume
    "d /persist/projects 0755 dev dev -"
    # SSH directory on persistent volume (for devbox key)
    "d /persist/ssh 0700 dev dev -"
    "L+ /home/dev/.ssh - - - - /persist/ssh"
    # Tmux resurrect data on persistent volume
    "d /persist/tmux 0755 dev dev -"
    "d /persist/tmux/dev 0700 dev dev -"
    # My Podcasts persistent state
    "d /persist/my-podcasts 0755 dev dev -"
  ];

  # User account with stable UID/GID for persistent volume ownership
  users.groups.dev = { gid = 1000; };

  users.users.dev = {
    isNormalUser = true;
    uid = 1000;
    group = "dev";
    description = "Development user";
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    linger = true;  # Allow user services to run without active login
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIjoX7P9gYCGqSbqoIvy/seqAbtzbLAdhaGCYRRVbDR2 johnnymo87@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # NOTE: Home-manager runs standalone, not as NixOS module
  # Run: home-manager switch --flake .#dev

  system.stateVersion = "25.11";
}
