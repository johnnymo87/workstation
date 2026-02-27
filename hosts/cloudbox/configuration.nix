# NixOS system configuration for cloudbox (GCP ARM devbox)
#
# Differences from devbox (Hetzner):
#   - No /persist volume or bind mounts (single persistent boot disk)
#   - SSH via GCP OS Login (handled by google-compute-config.nix in hardware.nix)
#   - No my-podcasts consumer (personal project)
#   - No claude_personal_oauth_token (work machine)
#   - No R2/OpenAI secrets (not needed here)
#   - Pigeon uses CCR_MACHINE_ID=cloudbox
#   - Firewall disabled (google-compute-config defers to GCP firewall)
{ config, pkgs, lib, ccrTunnel, ... }:

{
  # Allow unfree packages (1password-cli for pigeon)
  nixpkgs.config.allowUnfree = true;

  # sops-nix configuration
  sops = {
    defaultSopsFile = ../../secrets/cloudbox.yaml;
    age = {
      # Age key lives on root disk (no separate /persist on GCP)
      keyFile = "/var/lib/sops-age-key.txt";
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
      # 1Password service account token (for pigeon secrets)
      op_service_account_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Google Gemini API key for OpenCode (direct API)
      gemini_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # GitHub API token (for gh CLI, GH_TOKEN)
      github_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Atlassian API token (for acli, nvim FetchJiraTicket/FetchConfluencePage)
      atlassian_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Slack MCP tokens (for OpenCode slack-mcp-server)
      slack_mcp_xoxc_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      slack_mcp_xoxd_token = {
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
        "CCR_MACHINE_ID=cloudbox"
      ];
      ExecStart = "${pkgs.writeShellScript "pigeon-daemon-start" ''
        set -euo pipefail
        export OP_SERVICE_ACCOUNT_TOKEN="$(cat /run/secrets/op_service_account_token)"
        exec ${pkgs._1password-cli}/bin/op run --env-file=/home/dev/projects/pigeon/.env.1password -- \
          ${pkgs.nodejs}/bin/node /home/dev/projects/pigeon/node_modules/tsx/dist/cli.mjs /home/dev/projects/pigeon/packages/daemon/src/index.ts
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Stack target to start/stop cloudflared + pigeon together
  systemd.targets.pigeon = {
    description = "Pigeon stack (cloudflared + daemon)";
    wants = [ "cloudflared-tunnel.service" "pigeon-daemon.service" ];
  };

  # System identity
  networking.hostName = "cloudbox";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Enable running dynamically linked binaries (needed for npm packages)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
  ];

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    auto-optimise-store = true;
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
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
    nodejs  # For pigeon
  ];

  # Docker (for testcontainers)
  virtualisation.docker.enable = true;

  # Disable Google OS Login (we manage users/keys declaratively via NixOS)
  security.googleOsLogin.enable = lib.mkForce false;
  users.mutableUsers = false;

  # SSH server
  # NOTE: google-compute-config.nix already enables openssh.
  # We add hardening overrides on top.
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    X11Forwarding = false;
    StreamLocalBindUnlink = "yes";  # GPG agent forwarding
  };

  # Firewall: disabled by google-compute-config.nix (defers to GCP firewall rules)
  # If you need to re-enable: networking.firewall.enable = true;

  # Directories for state (no /persist — all on root disk)
  systemd.tmpfiles.rules = [
    "d /home/dev/.ssh 0700 dev dev -"
    "d /home/dev/projects 0755 dev dev -"
  ];

  # User account with stable UID/GID
  users.groups.dev = { gid = 1000; };

  users.users.dev = {
    isNormalUser = true;
    uid = 1000;
    group = "dev";
    description = "Development user";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bashInteractive;
    linger = true;  # Allow user services to run without active login
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIjoX7P9gYCGqSbqoIvy/seqAbtzbLAdhaGCYRRVbDR2 johnnymo87@gmail.com"
    ];
  };

  # Root SSH key for bootstrap (google-compute-config.nix handles root separately)
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIjoX7P9gYCGqSbqoIvy/seqAbtzbLAdhaGCYRRVbDR2 johnnymo87@gmail.com"
  ];

  security.sudo.wheelNeedsPassword = false;

  # NOTE: Home-manager runs standalone, not as NixOS module
  # Run: home-manager switch --flake .#cloudbox

  system.stateVersion = "25.11";
}
