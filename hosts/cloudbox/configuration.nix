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
{ config, pkgs, lib, ... }:

{
  # Allow unfree packages
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
      # Pigeon daemon secrets
      ccr_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      telegram_bot_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      telegram_chat_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Pigeon daemon secrets (replaces 1Password op run)
      ccr_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      telegram_bot_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      telegram_chat_id = {
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
      # Atlassian org config (non-secret but org-identifying)
      atlassian_site = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_email = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_cloud_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Alt Atlassian instance (for switch-atlassian alt)
      atlassian_alt_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_alt_site = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_alt_email = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      atlassian_alt_cloud_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Azure DevOps PAT (for private Maven/artifact registry)
      azure_devops_pat = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Datadog API keys (for Datadog MCP proxy)
      dd_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      dd_app_key = {
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
      # GCP project name (org-identifying)
      google_cloud_project = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # ba CLI GitHub repo path (org/repo, org-identifying)
      ba_cli_repo = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Jenkins credentials (for ba login)
      jenkins_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      jenkins_user = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Google Workspace CLI (gws) OAuth credentials
      gws_client_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_client_secret = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_refresh_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # CCR Worker URL for Pigeon daemon
      ccr_worker_url = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Azure DevOps npm registry URL (org-identifying)
      ado_npm_registry_url = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Bundler private gem source credentials
      bundle_gem_fury_io = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      bundle_enterprise_contribsys_com = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      bundle_gems_graphql_pro = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      bundle_fury_freshrealm_com = {
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
    after = [ "network-online.target" "sops-nix.service" "cloudflared-tunnel.service" ];
    requires = [ "sops-nix.service" "cloudflared-tunnel.service" ];

    path = [ pkgs.nodejs pkgs.bash pkgs.coreutils pkgs.neovim ];

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/pigeon/packages/daemon";
      Environment = [
        "HOME=/home/dev"
        "NODE_ENV=production"
        "CCR_MACHINE_ID=cloudbox"
      ];
      ExecStart = "${pkgs.writeShellScript "pigeon-daemon-start" ''
        set -euo pipefail
        export CCR_WORKER_URL="$(cat /run/secrets/ccr_worker_url)"
        export CCR_API_KEY="$(cat /run/secrets/ccr_api_key)"
        export TELEGRAM_BOT_TOKEN="$(cat /run/secrets/telegram_bot_token)"
        export TELEGRAM_CHAT_ID="$(cat /run/secrets/telegram_chat_id)"
        export OPENCODE_URL="http://127.0.0.1:4096"
        exec ${pkgs.nodejs}/bin/node /home/dev/projects/pigeon/node_modules/tsx/dist/cli.mjs /home/dev/projects/pigeon/packages/daemon/src/index.ts
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

  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sops-nix.service" ];
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        if [ -r /run/secrets/google_cloud_project ]; then
          export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
        fi
        export GOOGLE_APPLICATION_CREDENTIALS="/home/dev/.config/gcloud/application_default_credentials.json"
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
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

  # Pin GCP metadata server route to eth0 so Docker bridge networks
  # can't steal the 169.254.0.0/16 link-local route and break DNS.
  # Without this, testcontainers' bridge network creates a veth that
  # captures traffic to 169.254.169.254 (GCP's DNS/metadata endpoint).
  networking.interfaces.eth0.ipv4.routes = [
    { address = "169.254.169.254"; prefixLength = 32; }
  ];

  # Disable Google OS Login (we manage users/keys declaratively via NixOS)
  security.googleOsLogin.enable = lib.mkForce false;
  users.mutableUsers = false;

  # ---------------------------------------------------------------------------
  # Memory protection — prevent OOM lockups that require hard reset
  # ---------------------------------------------------------------------------

  # Kernel reserves: keep memory available for SSH/kernel even under pressure
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 262144;        # 256 MiB — kernel allocation reserve
    "vm.admin_reserve_kbytes" = 262144;   # 256 MiB — root/admin recovery reserve
    "vm.user_reserve_kbytes" = 131072;    # 128 MiB — user recovery reserve
  };

  # Soft memory limit on user slice: throttle (not kill) when dev workload
  # exceeds 30 GB. Leaves ~2 GB for system/kernel/buffers. Also cap user
  # swap usage so system services always have swap headroom.
  systemd.slices."user-1000" = {
    description = "User slice for UID 1000 (dev)";
    sliceConfig = {
      MemoryHigh = "30G";
      MemorySwapMax = "12G";
    };
  };

  # Protect sshd from OOM killer — always the last thing to die
  systemd.services.sshd.serviceConfig = {
    OOMScoreAdjust = "-1000";
  };

  # earlyoom: last-resort killer when RAM+swap are nearly exhausted.
  # Sends SIGTERM at 5%/5%, SIGKILL at 2%/2%.
  # Kill order: bazel/java/node first (--prefer), then other processes,
  # then opencode last (--avoid). sshd is also --avoid but has
  # OOMScoreAdjust=-1000 so it's effectively unkillable.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 5;
    freeMemKillThreshold = 2;
    freeSwapKillThreshold = 2;
    reportInterval = 15;
    extraArgs = [
      "--prefer" "(^|/)(node|bun|bazel|java|kotlin-language-server|docker)$"
      "--avoid" "(^|/)(sshd|systemd|systemd-journald|systemd-logind|dbus-daemon|opencode)$"
    ];
  };

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
