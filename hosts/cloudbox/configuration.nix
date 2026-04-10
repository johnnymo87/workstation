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
      # gclpr clipboard bridge private key (NaCl key for signed clipboard requests)
      gclpr_private_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
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
      # Slack MCP token (xoxp User OAuth via registered Slack app)
      slack_mcp_xoxp_token = {
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
      # Cap the always-on headless server so it can't monopolize RAM alone.
      MemoryMax = "10G";
      MemoryHigh = "8G";
      OOMScoreAdjust = "500";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # Daily 3 AM restart of leaky long-running services.
  # opencode-serve leaks from ~350 MB to 8-13 GB over days.
  systemd.services.nightly-restart-background = {
    description = "Restart long-running background services to reclaim leaked memory";
    serviceConfig.Type = "oneshot";
    script = ''
      /run/current-system/sw/bin/systemctl restart opencode-serve.service
    '';
  };

  systemd.timers.nightly-restart-background = {
    description = "Nightly restart of background services at 3 AM ET";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  # Reap stale opencode processes every 6 hours.
  # Two classes of opencode processes accumulate and leak memory:
  # 1. Headless sessions (opencode -s <id>): /launched from Telegram, often forgotten.
  #    Killed when the session's time_updated in the DB is >24h ago.
  # 2. Interactive sessions (bare opencode): started in tmux, left running.
  #    Killed when the process is >24h old.
  # opencode-serve is excluded (managed by nightly-restart-background).
  # SIGKILL is used directly because opencode ignores SIGTERM.
  systemd.services.reap-stale-opencode = {
    description = "Kill stale opencode processes (>24h idle or old)";
    path = [ pkgs.procps pkgs.gnugrep pkgs.coreutils pkgs.sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      THRESHOLD_SECONDS=86400  # 24 hours
      NOW=$(date +%s)
      NOW_MS=$((NOW * 1000))
      CUTOFF_MS=$(( (NOW - THRESHOLD_SECONDS) * 1000 ))
      DB="/home/dev/.local/share/opencode/opencode.db"
      KILLED=0

      HAS_DB=true
      if [ ! -f "$DB" ]; then
        echo "opencode DB not found at $DB, skipping DB-based detection"
        HAS_DB=false
      fi

      # Helper: check if process is older than threshold
      is_old_process() {
        local pid=$1
        local start_time
        start_time=$(stat -c %Y /proc/$pid 2>/dev/null) || return 1
        local age=$((NOW - start_time))
        if [ "$age" -gt "$THRESHOLD_SECONDS" ]; then
          echo $((age / 3600))
          return 0
        fi
        return 1
      }

      # Find all opencode processes
      for pid in $(pgrep -f 'opencode' -u dev || true); do
        # Read cmdline
        cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || continue)

        # Skip opencode serve
        if echo "$cmdline" | grep -qw 'serve'; then
          continue
        fi

        # Skip non-opencode processes (e.g. grep itself, earlyoom)
        if ! echo "$cmdline" | grep -q '/opencode'; then
          continue
        fi

        # Check if this is a headless session (has -s <session_id>)
        session_id=$(echo "$cmdline" | grep -oP '(?<=-s )\S+' || true)

        if [ -n "$session_id" ] && [ "$HAS_DB" = true ]; then
          # Headless session: check DB for session staleness
          last_updated=$(sqlite3 "$DB" \
            "SELECT time_updated FROM session WHERE id = '$session_id';" 2>/dev/null || echo "0")

          if [ -z "$last_updated" ] || [ "$last_updated" = "0" ]; then
            # Session not in DB — fall back to process age
            age_hours=$(is_old_process "$pid") && {
              echo "PID $pid: session $session_id not in DB, process ''${age_hours}h old, killing"
              kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
            } || echo "PID $pid: session $session_id not in DB but process is young, keeping"
          elif [ "$last_updated" -lt "$CUTOFF_MS" ]; then
            age_hours=$(( (NOW_MS - last_updated) / 1000 / 3600 ))
            echo "PID $pid: session $session_id last updated ''${age_hours}h ago, killing"
            kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
          else
            echo "PID $pid: session $session_id is recent, keeping"
          fi
        else
          # Interactive session (or headless without DB): check process age
          age_hours=$(is_old_process "$pid") && {
            echo "PID $pid: opencode process ''${age_hours}h old, killing"
            kill -9 "$pid" 2>/dev/null && KILLED=$((KILLED + 1))
          } || {
            start_time=$(stat -c %Y /proc/$pid 2>/dev/null || echo "$NOW")
            age_hours=$(( (NOW - start_time) / 3600 ))
            echo "PID $pid: opencode process ''${age_hours}h old, keeping"
          }
        fi
      done

      echo "Reaped $KILLED stale opencode processes"
    '';
  };

  systemd.timers.reap-stale-opencode = {
    description = "Reap stale opencode processes every 6 hours";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:30:00";  # Every 6h at :30 past (offset from nightly-restart at :00)
      Persistent = true;
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
    max-jobs = 2;   # Half of 4 cores — leave capacity for interactive work
    cores = 2;      # Max 2 cores per individual build derivation
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Nix daemon scheduling — treat builds as batch work so interactive
  # sessions (mosh, tmux, opencode) always get CPU/IO priority.
  nix.daemonCPUSchedPolicy = "batch";
  nix.daemonIOSchedClass = "idle";

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
      TasksMax = 4096;      # Enough for Bazel's symlink-forest threads; still caps runaway fan-out
    };
  };

  # Protect sshd from OOM killer — always the last thing to die.
  # CPUWeight > default (100) ensures SSH remains responsive under load.
  systemd.services.sshd.serviceConfig = {
    OOMScoreAdjust = "-1000";
    CPUWeight = 200;
  };

  # earlyoom: last-resort killer when memory is critically low.
  # Swap threshold set to 100% (always true) so earlyoom triggers on
  # RAM alone — our failure mode exhausts RAM while swap has headroom.
  # Kill order: opencode/bazel/java/node first (--prefer, +100 oom_score),
  # then everything else by RSS, then sshd/systemd
  # last (--avoid, -100 oom_score, plus OOMScoreAdjust=-1000).
  # opencode is in --prefer because it's the known memory leak leader
  # and has OOMScoreAdjust=500 + cgroup caps as additional backstops.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 10;       # SIGTERM when <10% RAM free (~3.2 GB)
    freeSwapThreshold = 100;     # Always true — trigger on RAM alone
    freeMemKillThreshold = 5;    # SIGKILL when <5% RAM free (~1.6 GB)
    freeSwapKillThreshold = 100; # Always true — trigger on RAM alone
    reportInterval = 15;
    extraArgs = [
      "--prefer" "(^|/)(\\.opencode-wrapp|node|bun|bazel|java|kotlin-language-server|docker)$"
      "--avoid" "(^|/)(sshd|systemd|systemd-journald|systemd-logind|dbus-daemon|agetty|dhcpcd)$"
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
