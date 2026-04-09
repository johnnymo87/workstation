# NixOS system configuration for devbox
{ config, pkgs, lib, ... }:

{
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # sops-nix configuration
  sops = {
    defaultSopsFile = ../../secrets/devbox.yaml;
    age = {
      # Key will be at this path on the devbox
      keyFile = "/persist/sops-age-key.txt";
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
      # Google Gemini API key for OpenCode (direct API, not enterprise/Code Assist)
      gemini_api_key = {
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
      # GitHub API token (for gh CLI, GH_TOKEN)
      github_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Exa API key (for web search in Things Happen digest)
      exa_api_key = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # CCR worker URL (used by pigeon-daemon)
      ccr_worker_url = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Pigeon daemon secrets (replaces op run)
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
      # Cloudflare Queue ID (used by my-podcasts-consumer)
      cloudflare_queue_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Google Workspace CLI - default account (jonathan.mohrbacher@gmail.com)
      gws_default_client_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_default_client_secret = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_default_refresh_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_default_project_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Google Workspace CLI - alt account (johnnymo87@gmail.com)
      gws_alt_client_id = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_alt_client_secret = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_alt_refresh_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      gws_alt_project_id = {
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
      OOMScoreAdjust = "500";
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
      OOMScoreAdjust = "500";
      WorkingDirectory = "/home/dev/projects/pigeon/packages/daemon";
      Environment = [
        "HOME=/home/dev"
        "NODE_ENV=production"
        "CCR_MACHINE_ID=devbox"
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

  # Optional: Stack target to start/stop both together
  systemd.targets.pigeon = {
    description = "Pigeon stack (cloudflared + daemon)";
    wants = [ "cloudflared-tunnel.service" "pigeon-daemon.service" ];
  };

  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sops-nix.service" ];
    path = [ "/run/wrappers" config.system.path "/home/dev/.nix-profile" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
        "OPENCODE_ENABLE_EXA=1"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      # P3: Cap the always-on headless server so it can't monopolize RAM alone.
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
      /run/current-system/sw/bin/systemctl restart pigeon-daemon.service
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
      OOMScoreAdjust = "500";
      WorkingDirectory = "/home/dev/projects/my-podcasts";
      Environment = [
        "HOME=/home/dev"
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
        export PYTHONUNBUFFERED=1
        export CLOUDFLARE_QUEUE_ID="$(cat /run/secrets/cloudflare_queue_id)"
        export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
        export R2_ACCOUNT_ID="$(cat /run/secrets/r2_account_id)"
        export R2_ACCESS_KEY_ID="$(cat /run/secrets/r2_access_key_id)"
        export R2_SECRET_ACCESS_KEY="$(cat /run/secrets/r2_secret_access_key)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export EXA_API_KEY="$(cat /run/secrets/exa_api_key)"
        export GEMINI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        cd /home/dev/projects/my-podcasts
        exec ${pkgs.uv}/bin/uv run python -m pipeline consume
      ''}";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  systemd.services.fp-digest = {
    description = "Foreign Policy Digest daily podcast generation";
    wants = [ "network-online.target" "opencode-serve.service" ];
    after = [ "network-online.target" "opencode-serve.service" ];

    path = [ pkgs.python314 pkgs.ffmpeg pkgs.uv pkgs.bash pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/my-podcasts";
      Environment = [
        "HOME=/home/dev"
        "NLTK_DATA=/persist/my-podcasts/nltk_data"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      ExecStart = "${pkgs.writeShellScript "fp-digest-start" ''
        set -euo pipefail
        export PYTHONUNBUFFERED=1
        export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
        export GEMINI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        export EXA_API_KEY="$(cat /run/secrets/exa_api_key)"
        export R2_ACCOUNT_ID="$(cat /run/secrets/r2_account_id)"
        export R2_ACCESS_KEY_ID="$(cat /run/secrets/r2_access_key_id)"
        export R2_SECRET_ACCESS_KEY="$(cat /run/secrets/r2_secret_access_key)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        cd /home/dev/projects/my-podcasts
        exec ${pkgs.uv}/bin/uv run python -m pipeline fp-digest
      ''}";
      TimeoutStartSec = 600;
    };
  };

  systemd.timers.fp-digest = {
    description = "Run FP Digest daily at 5 PM";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 17:00:00";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  systemd.services.the-rundown = {
    description = "The Rundown daily podcast generation";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    path = [ pkgs.python314 pkgs.ffmpeg pkgs.uv pkgs.bash pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/my-podcasts";
      Environment = [
        "HOME=/home/dev"
        "NLTK_DATA=/persist/my-podcasts/nltk_data"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      ExecStart = "${pkgs.writeShellScript "the-rundown-start" ''
        set -euo pipefail
        export PYTHONUNBUFFERED=1
        export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
        export GEMINI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        export EXA_API_KEY="$(cat /run/secrets/exa_api_key)"
        export R2_ACCOUNT_ID="$(cat /run/secrets/r2_account_id)"
        export R2_ACCESS_KEY_ID="$(cat /run/secrets/r2_access_key_id)"
        export R2_SECRET_ACCESS_KEY="$(cat /run/secrets/r2_secret_access_key)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        cd /home/dev/projects/my-podcasts
        exec ${pkgs.uv}/bin/uv run python -m pipeline the-rundown
      ''}";
      TimeoutStartSec = 600;
    };
  };

  systemd.timers.the-rundown = {
    description = "Run The Rundown daily at 5 PM ET Mon-Fri";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 17:00:00";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  systemd.services.sync-sources = {
    description = "Sync podcast source caches (Zvi, Semafor, Antiwar)";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    path = [ pkgs.python314 pkgs.uv pkgs.bash pkgs.coreutils ];

    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/my-podcasts";
      Environment = [
        "HOME=/home/dev"
        "NLTK_DATA=/persist/my-podcasts/nltk_data"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      ExecStart = "${pkgs.writeShellScript "sync-sources-start" ''
        set -euo pipefail
        export PYTHONUNBUFFERED=1
        export GEMINI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        cd /home/dev/projects/my-podcasts
        exec ${pkgs.uv}/bin/uv run python -m pipeline sync-sources
      ''}";
      TimeoutStartSec = 300;
    };
  };

  systemd.timers.sync-sources = {
    description = "Sync source caches daily at 4:30 PM ET (before podcasts)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 16:30:00";
      Persistent = true;
      RandomizedDelaySec = "5min";
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
    max-jobs = 8;   # Half of 16 cores — leave capacity for interactive work
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
  # Mosh (mobile shell) uses UDP for its stateful transport.
  # Range is generous; each session uses one port.
  networking.firewall.allowedUDPPortRanges = [{ from = 60000; to = 61000; }];

  # Persistent volume for state that survives rebuilds
  fileSystems."/persist" = {
    device = "/dev/disk/by-id/scsi-0HC_Volume_104378953";
    fsType = "ext4";
    options = [ "nofail" ];
    neededForBoot = true;  # Mount in initrd, before sops-nix decrypts secrets using /persist/sops-age-key.txt
  };

  systemd.tmpfiles.rules = [
    # Claude state
    "d /persist/claude 0700 dev dev -"
    "L+ /home/dev/.claude - - - - /persist/claude"
    # Projects directory on local SSD (not cloud volume)
    "d /home/dev/projects 0755 dev dev -"
    # SSH directory on persistent volume (for devbox key)
    "d /persist/ssh 0700 dev dev -"
    "L+ /home/dev/.ssh - - - - /persist/ssh"
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
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZW/G8i9mAYOB7ls4p16j5HiaGe+XXHmsOW73eDsmf1 delacroix.livialou@gmail.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # --- OOM mitigation (P0-P4) ---
  # Context: 16 GB RAM + 7.6 GB zram, opencode sessions leak to 8-13 GB,
  # triggering global OOM kills that cascade into user@1000.service collapse.

  # P0: earlyoom — kill the fattest process before the kernel OOM killer fires.
  # Prevents the cascade that tears down the entire user session.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 10;        # SIGTERM when <10% RAM free (~1.6 GB)
    freeSwapThreshold = 100;      # Trigger on RAM alone (ignore swap)
    freeMemKillThreshold = 5;     # SIGKILL when <5% RAM free (~800 MB)
    freeSwapKillThreshold = 100;
    reportInterval = 15;
    extraArgs = [
      "--prefer" "(^|/)(\\.opencode-wrapp|node|bun|headless_shell|nix-build)$"
      "--avoid" "(^|/)(sshd|systemd|systemd-journald|systemd-logind|dbus-daemon|agetty|dhcpcd|cloudflared)$"
    ];
  };

  # P1: Protect sshd from OOM killer — always the last thing to die.
  # CPUWeight > default (100) ensures SSH remains responsive under load.
  systemd.services.sshd.serviceConfig = {
    OOMScoreAdjust = "-1000";
    CPUWeight = 200;
  };

  # P2: Kernel memory reserves — keep enough free for root recovery.
  boot.kernel.sysctl = {
    "vm.min_free_kbytes" = 131072;        # 128 MiB — kernel allocation reserve
    "vm.admin_reserve_kbytes" = 131072;   # 128 MiB — root/admin recovery reserve
    "vm.user_reserve_kbytes" = 65536;     # 64 MiB — user recovery reserve
  };

  # P4: Aggregate cap on user slice — throttle (not kill) when dev workload
  # exceeds 12 GB.  Leaves ~4 GB for system/kernel/buffers.  Also cap user
  # swap usage so the zram device doesn't saturate.
  systemd.slices."user-1000" = {
    description = "User slice for UID 1000 (dev)";
    sliceConfig = {
      MemoryHigh = "12G";
      MemorySwapMax = "6G";
      TasksMax = 512;       # Prevent runaway process fan-out from subagents
    };
  };

  # NOTE: Home-manager runs standalone, not as NixOS module
  # Run: home-manager switch --flake .#dev

  system.stateVersion = "25.11";
}
