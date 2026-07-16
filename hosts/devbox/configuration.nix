# NixOS system configuration for devbox
{ config, pkgs, lib, ... }:

let
  # mn9r M5: serve-pool descriptor (single source of truth in
  # users/dev/serve-pool.nix). devbox = K=2 on ports 4096/4097, serve-0 == :4096.
  # routingDbPath is the file BOTH the serves (OPENCODE_ROUTING_DB, set in the
  # systemd.user opencode-serve@ pool in users/dev/home.devbox.nix) and pigeon
  # (PIGEON_DAEMON_DB_PATH, below) open for the session-lease CAS (DM5-1). It is
  # pigeon's EXISTING unified daemon DB (this service's WorkingDirectory/data/
  # pigeon-daemon.db default — verified present), which holds pigeon's swarm/
  # outbox state AND the routing tables in one file; a fresh path would orphan
  # that state. pigeon already created the routing schema there (checksum
  # e5c8e409..., version 1) so serves boot-assert clean.
  servePool = (import ../../users/dev/serve-pool.nix).forHost.devbox;
  routingDbPath = "/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db";
in
{
  # Guard: abort activation if applying the wrong host's config.
  # Devbox and cloudbox share arch and user — applying the wrong flake target
  # overwrites system identity, secrets paths, and service configs.
  # Skipped when /etc/hostname doesn't exist yet (fresh nixos-anywhere install).
  system.activationScripts.assertHostname = ''
    expected="devbox"
    current="$(cat /etc/hostname 2>/dev/null || echo "")"
    if [ -n "$current" ] && [ "$current" != "$expected" ]; then
      echo "FATAL: flake target #$expected is being applied on host '$current'." >&2
      echo "This would overwrite $current's system config with $expected's." >&2
      echo "Use: sudo nixos-rebuild switch --flake .#$current" >&2
      exit 1
    fi
  '';

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
      # DoltHub credential (Ed25519 JWK keypair) used by `bd dolt push/pull`
      # to back up the git-free beads issue DB to DoltHub. The same keypair is
      # shared across all hosts; home.activation.deployDoltCreds materializes it
      # at ~/.dolt/creds/<keyid>.jwk and points config_global.json at it.
      dolthub_jwk = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # DoltHub REST API token (distinct from the dolthub_jwk push/pull cred):
      # authenticates the v1alpha1 REST API used to *create* DoltHub databases
      # (POST /api/v1alpha1/database). Exported as DOLTHUB_API_TOKEN.
      dolthub_api_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
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
      # Personal Anthropic subscription token. Despite the env-var-style name
      # of the secret (which mirrors the historical CLAUDE_CODE_OAUTH_TOKEN
      # convention used by the @ex-machina/opencode-anthropic-auth opencode
      # plugin), Claude Code itself is not installed on devbox -- this token is
      # consumed by the opencode plugin to authenticate as the personal
      # Anthropic subscription when opencode-serve makes anthropic/claude-*
      # requests.
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
        # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
        # sessionVariables for full rationale). pigeon revive spawns opencode
        # that must hit the same DB; a system service doesn't source ~/.profile.
        "OPENCODE_DB=/home/dev/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
        # mn9r M5: the K serve endpoints in port order (index i -> serve-<i>, so
        # this MUST match servePool.ports ordering — both come from
        # users/dev/serve-pool.nix). PIGEON_SERVE_LIVENESS=self flips pigeon off
        # its HTTP health-poller onto the serves' own heartbeats (M4 D1a), and
        # PIGEON_DAEMON_DB_PATH pins the routing DB to the same file the serves
        # open as OPENCODE_ROUTING_DB (DM5-1). Mirrors the cloudbox pigeon config.
        "PIGEON_SERVE_ENDPOINTS=${servePool.endpointsCsv}"
        "PIGEON_SERVE_LIVENESS=self"
        "PIGEON_DAEMON_DB_PATH=${routingDbPath}"
        # workstation-debug: widen the heartbeat-staleness window before a serve
        # is flagged "dead". opencode serve is single-threaded; a CPU-heavy turn
        # (or GC/swap stall) blocks its event loop and starves the 5s heartbeat
        # fiber, so the default 15s falsely declares a live, busy serve dead and
        # ServeHealthPoller.sweepStale → reassignFromDeadServe migrates its
        # sessions (churn + historically killed in-flight runs). The real fix is
        # pigeon-side (reassignFromDeadServe now skips sessions whose lease is
        # still valid); this is defense-in-depth churn reduction. CEILING: keep
        # <= serveLeaseTtl(30s) − serveRenewInterval(10s) = 20s, else a dead serve
        # can linger in listHealthy past its lease expiry and get re-picked.
        "PIGEON_SERVE_STALE_MS=20000"
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

  # opencode-serve now runs as a systemd USER service (under user@1000.service),
  # NOT a system service. It was moved so that sessions it spawns are already
  # inside the user manager's cgroup, which lets
  # ~/projects/eternal-machinery/bin/devenv-up place devenv into dev-daemons.slice
  # via `systemd-run --user --scope` (its "Context B" branch) instead of trying
  # to cross from a system service into the dev@ user bus via
  # `--machine=dev@.host` (which fails with "Permission denied"). mn9r M5: serve
  # is now a K-instance pool (templated systemd.user.services."opencode-serve@"
  # behind systemd.user.targets.opencode-serve-pool) defined in
  # users/dev/home.devbox.nix. Linger (users.users.dev.linger below) keeps
  # user@1000.service up at boot so the pool starts without a login.

  # Daily 3 AM workspace reset (cloudbox parity). reset-workspace snapshots
  # live opencode TUIs in the `main` tmux session, SIGKILLs all nvims,
  # restarts the opencode-serve-pool.target (each serve leaks ~350 MB -> 8-13 GB
  # over days), and spawns a headless recommendation session that Telegrams
  # which sessions to reopen.
  # devbox nvim is disposable (an opencode-tab host only), so the SIGKILL is
  # safe. Every opencode TUI is hosted under nvim (directly or via an nvim
  # :terminal bash), so the SIGKILL reaps them all via PTY hangup; this is the
  # sole cleanup mechanism (the old age-based reap-stale-opencode timer, which
  # surprise-killed live interactive sessions, has been removed).
  #
  # Runs as User=dev so reset-workspace's `systemd-run --user --scope` re-exec
  # and `systemctl --user restart opencode-serve-pool.target` work (the pool is
  # a USER target on devbox; linger keeps user@1000 up). pigeon-daemon (a SYSTEM unit) is
  # restarted FIRST via passwordless sudo so the recommendation session, spawned
  # last inside reset-workspace, registers with a fresh daemon.
  systemd.services.nightly-restart-background = {
    description = "Nightly workspace reset (kill nvims, restart opencode-serve-pool, recommend)";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      Environment = [
        "TMUX_TMPDIR=/tmp"
        "PATH=/run/current-system/sw/bin:/home/dev/.nix-profile/bin"
        # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
        # sessionVariables for rationale). reset-workspace spawns a headless
        # recommendation opencode session that must hit the same DB.
        "OPENCODE_DB=/home/dev/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
        # This oneshot already runs in its own system-slice cgroup, so it does
        # NOT need reset-workspace's `systemd-run --user --scope` survival
        # re-exec. Skipping it also removes a failure mode: a full runtime tmpfs
        # (/run/user/1000) makes every `systemd-run --user` fail with ENOSPC,
        # which previously hard-exited the whole nightly run before any reset
        # work happened (2026-07 devbox outage). See pkgs/reset-workspace.
        "RESET_WORKSPACE_NO_DETACH=1"
        # With NO_DETACH set (above), reset-workspace no longer re-execs via
        # `systemd-run --user --scope`, which was the only thing that provided
        # XDG_RUNTIME_DIR. Running in-place in this system service's clean env,
        # `systemctl --user` (used by pool_scope() to detect the devbox USER
        # pool target) can't reach the user manager and misdetects "system",
        # then dies restarting a nonexistent system target. Supply the runtime
        # dir explicitly so pool_scope() correctly returns "user". (dev = uid
        # 1000; linger keeps /run/user/1000 up.) Regression from 6bd6575.
        "XDG_RUNTIME_DIR=/run/user/1000"
      ];
    };
    script = ''
      /run/wrappers/bin/sudo systemctl restart pigeon-daemon.service
      /home/dev/.nix-profile/bin/reset-workspace --yes
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
    # opencode-serve is a USER service now (see users/dev/home.devbox.nix); a
    # system service cannot order against a user unit, so the dependency is
    # dropped. fp-digest reaches opencode over its HTTP port (127.0.0.1:4096),
    # which is up continuously thanks to linger + Restart=always on the user
    # service — so the explicit ordering is no longer needed.
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
    description = "Run FP Digest daily at 4:30 AM ET Mon-Fri";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 04:30:00";
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
    description = "Run The Rundown daily at 4:30 AM ET Mon-Fri";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Mon..Fri *-*-* 04:30:00";
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
    description = "Sync source caches twice daily (4:00 AM and 8:00 PM ET)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 04:00 ET: final catch-up just before the daily podcast jobs run.
      # 20:00 ET: capture Semafor's daytime publishing so the next morning's
      # lookback window has a full prior-day corpus to draw from.
      OnCalendar = [
        "*-*-* 04:00:00"
        "*-*-* 20:00:00"
      ];
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
  };

  # System identity
  networking.hostName = "devbox";
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Default editor: nvim, not nano.
  #
  # nixpkgs' programs/environment.nix sets `environment.variables.EDITOR =
  # lib.mkDefault "nano"`, which renders into /etc/set-environment (sourced by
  # /etc/profile). Anything that sources /etc/profile but NOT the user's
  # ~/.profile -- notably the tmux server when it's first started outside an
  # interactive login shell -- inherits EDITOR=nano. That leaks into the
  # `opencode attach` TUIs that oc-auto-attach spawns inside tmux/nvim, so
  # ctrl+x x / `/export` (which resolve `process.env.VISUAL || EDITOR`) opened
  # nano. A plain assignment (priority 100) overrides the mkDefault (1000)
  # without mkForce. NOTE: takes effect for tmux servers started AFTER the next
  # `nixos-rebuild switch` + tmux-server restart; the nvims wrapper
  # (pkgs/nvims) also forces EDITOR/VISUAL=nvim as a cross-platform, restart-
  # free belt-and-suspenders for the auto-attach path.
  environment.variables.EDITOR = "nvim";

  # Enable running dynamically linked binaries (needed for npm packages).
  #
  # The library set below is the Electron/Chromium runtime closure required by
  # the prebuilt npm Cypress binary (bundled Electron) so it can run headless
  # browser e2e tests on NixOS (e.g. internal-frontends Cypress suites).
  # Without it the prebuilt binary dies with
  #   "error while loading shared libraries: libglib-2.0.so.0 ..."
  # (glib is just the first of the full Electron runtime set).
  # The list mirrors nixpkgs' own `cypress` derivation buildInputs/
  # runtimeDependencies plus the standard Electron deps. nix-ld feeds these
  # through `lib.makeLibraryPath`/`getLib`, so plain package names resolve to
  # the correct lib output. Paired with `xorg.xvfb` in environment.systemPackages
  # below — Cypress spawns `Xvfb` directly for its virtual display.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Common libraries for npm native binaries
    stdenv.cc.cc.lib
    # Electron / Chromium runtime libraries (prebuilt Cypress binary)
    glib nss nspr atk at-spi2-atk at-spi2-core cups dbus gtk3
    gdk-pixbuf pango cairo expat libdrm libgbm libxkbcommon
    alsa-lib libnotify libsecret udev libGL fontconfig freetype
    xorg.libX11 xorg.libXcomposite xorg.libXdamage xorg.libXext
    xorg.libXfixes xorg.libXrandr xorg.libxcb xorg.libXScrnSaver
    xorg.libXtst xorg.libxshmfence xorg.libXrender xorg.libXi
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
    tmux direnv
    # NOTE: neovim intentionally NOT here. The dev user gets nvim via
    # home-manager (programs.neovim with the full plugin set, including
    # nvim-treesitter). Putting bare `neovim` on the system path shadowed
    # the home-manager wrapper in non-login shells (system-path beats
    # ~/.nix-profile in PATH order), causing init.lua to fail with
    # `module 'nvim-treesitter.configs' not found` and breaking
    # :FetchJiraTicket / oc-auto-attach. Pigeon's systemd `path` still
    # references pkgs.neovim explicitly for its `nvim --server` RPC client,
    # which doesn't need the plugin set.
    gh gnupg pinentry-curses
    python314 ffmpeg uv
    xorg.xvfb  # Provides `Xvfb`; prebuilt Cypress spawns it for headless e2e
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
      # Detect dead clients so stale sessions don't hold remote-forwarded
      # ports (gclpr 2850, CDP 9222/9223, etc.) after a VPN cycle or
      # network drop.  Without this, orphaned sshd sessions linger
      # indefinitely and block new tunnel connections from binding.
      ClientAliveInterval = 30;
      ClientAliveCountMax = 3;
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

  # P4: Aggregate cap on user slice — throttle (not kill) when the dev
  # workload exceeds the soft ceiling.  Sized 2026-07-03 (workstation-94g8)
  # for the CURRENT 30G host (the old 12G value dated from the 16G box):
  # 20G leaves ~10G for system/kernel/buffers and comfortably contains the
  # opencode serve pool worst case (K=2 x MemoryMax=6G, users/dev/
  # home.devbox.nix) plus editors/BEAM/tools.  Slice-level High is kept (unlike
  # the per-serve units, which are Max-only after the 2026-07-03 wedge)
  # because at slice scope there is plenty of reclaimable page cache spread
  # across many processes, and earlyoom (P0) backstops the kill path.
  # Also cap user swap usage so the zram device doesn't saturate.
  systemd.slices."user-1000" = {
    description = "User slice for UID 1000 (dev)";
    sliceConfig = {
      MemoryHigh = "20G";
      MemorySwapMax = "6G";
      # TasksMax bumped from 512 -> 2048 after evidence (eternal-machinery
      # bead hedl, 2026-04-18) that 512 was too low for the real dev
      # workload: main BEAM (~48 threads) + Letta (~40) + tec-mcp (~20) +
      # Codex (~15) + editor + elixir-ls (~20) + concurrent opencode agents
      # routinely hit 475+/512, and starting a second BEAM (./bin/parlor)
      # failed with EAGAIN mid-boot. Kernel cgroup pids.events at
      # user-1000.slice showed 1422 historical fork denials on this cap.
      # 2048 still provides the "prevent runaway subagent fan-out" safety
      # property (it is ~18x smaller than systemd's own default per-unit
      # cap of ~37458 on this box), but leaves real headroom for legitimate
      # work. Follow-up: move agent processes into a sibling agents.slice
      # with its own tighter cap so fan-out is fenced, not starving dev
      # daemons. See docs/plans/research/2026-04-18-devbox-taskmax-devenv-vs-docker-answer.md
      # in the eternal-machinery repo for full analysis.
      TasksMax = 2048;
    };
  };

  # NOTE: Home-manager runs standalone, not as NixOS module
  # Run: home-manager switch --flake .#dev

  system.stateVersion = "25.11";
}
