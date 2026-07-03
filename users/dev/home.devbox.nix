# Devbox-specific home-manager configuration
# Contains systemd services, sops secrets, and other devbox-only features
{ config, pkgs, lib, localPkgs, projects, isDevbox, ... }:

let
  # mn9r M5: serve-pool descriptor (single source of truth in serve-pool.nix).
  # devbox = K=2 on ports 4096/4097, serve-0 == :4096. routingDbPath is the file
  # BOTH the serves (OPENCODE_ROUTING_DB) and pigeon (PIGEON_DAEMON_DB_PATH) open
  # for the session-lease CAS (DM5-1). It is pigeon's EXISTING unified daemon DB
  # (the devbox pigeon system service's WorkingDirectory/data/pigeon-daemon.db
  # default — verified present on devbox), which holds pigeon's swarm/outbox
  # state AND the routing tables in ONE file; pointing both env vars at a fresh
  # path would orphan that state. pigeon already created the routing schema there
  # (checksum e5c8e409..., version 1), so serves boot-assert clean.
  servePool = (import ./serve-pool.nix).forHost.devbox;
  routingDbPath = "${config.home.homeDirectory}/projects/pigeon/packages/daemon/data/pigeon-daemon.db";
  # port -> OPENCODE_SERVE_ID lookup for the templated unit's ExecStart, where
  # the systemd instance specifier %i is the port. Generated from the same list
  # as PIGEON_SERVE_ENDPOINTS (devbox pigeon config) so serve-<i> can never drift
  # from endpoint i.
  serveIdCase = lib.concatStringsSep "\n" (lib.imap0
    (i: port: "          ${toString port}) export OPENCODE_SERVE_ID=serve-${toString i} ;;")
    servePool.ports);
in
lib.mkIf isDevbox {
  # Linux devbox identity
  home.username = "dev";
  home.homeDirectory = "/home/dev";

  # home.stateVersion for this platform
  home.stateVersion = "25.11";

  # Constrain vitest worker count — default uses all cores, which starves
  # opencode sessions and devenv services when tests run in watch mode.
  home.sessionVariables.VITEST_MAX_WORKERS = "4";  # 16-core box, keep 75% free

  # Guard: abort activation if running on the wrong machine.
  # Devbox and cloudbox share arch, user, and home dir -- applying the wrong
  # flake target silently deploys incorrect config (wrong secrets, /persist
  # assumptions, wrong pull-workstation target) and is hard to diagnose.
  home.activation.assertPlatform =
    lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      current="$(cat /etc/hostname 2>/dev/null || echo unknown)"
      if [ "$current" != "devbox" ]; then
        echo "FATAL: flake target #dev is for devbox, but running on $current." >&2
        echo "Use --flake .#$current (or the correct target) instead." >&2
        exit 1
      fi
    '';

  # Cloudflare API token for wrangler (from sops-nix secret)
  programs.bash.initExtra = lib.mkAfter ''
    # GitHub API token for gh CLI
    if [ -r /run/secrets/github_api_token ]; then
      export GH_TOKEN="$(cat /run/secrets/github_api_token)"
    fi

    if [ -r /run/secrets/cloudflare_api_token ]; then
      export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
    fi

    # DoltHub REST API token for creating DoltHub databases (v1alpha1 API)
    if [ -r /run/secrets/dolthub_api_token ]; then
      export DOLTHUB_API_TOKEN="$(cat /run/secrets/dolthub_api_token)"
    fi

    # Personal Anthropic subscription token. Consumed by the
    # @ex-machina/opencode-anthropic-auth opencode plugin (in ad-hoc CLI
    # opencode runs from this shell; opencode-serve gets its own copy in
    # hosts/devbox/configuration.nix). Claude Code is not installed -- the
    # env var name is what the plugin requires, not what consumes it.
    if [ -r /run/secrets/claude_personal_oauth_token ]; then
      export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
    fi

    # Gemini API key for OpenCode's @ai-sdk/google provider (direct API)
    if [ -r /run/secrets/gemini_api_key ]; then
      export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
    fi

    # OpenAI API key (for tec-codex embeddings via text-embedding-3-small)
    if [ -r /run/secrets/openai_api_key ]; then
      export OPENAI_API_KEY="$(cat /run/secrets/openai_api_key)"
    fi

    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    # These call mcp.exa.ai with no API key (free tier). If rate-limited (429),
    # obtain a free key at exa.ai and set OPENCODE_ENABLE_EXA=https://mcp.exa.ai/mcp?exaApiKey=<key>
    export OPENCODE_ENABLE_EXA=1

    # Google Workspace CLI: default to jonathan.mohrbacher@gmail.com
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws"

    switch-gws() {
      case "''${1:-}" in
        default)
          export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws"
          echo "Switched to default gws account (jonathan.mohrbacher@gmail.com)"
          ;;
        alt)
          export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws-alt"
          echo "Switched to alt gws account (johnnymo87@gmail.com)"
          ;;
        *)
          echo "Usage: switch-gws default|alt"
          echo "Current: $GOOGLE_WORKSPACE_CLI_CONFIG_DIR"
          return 1
          ;;
      esac
    }
  '';

  # Assemble gws config files from sops secrets at activation time.
  # Creates two config directories for multi-account support:
  #   ~/.config/gws/         (jonathan.mohrbacher@gmail.com)
  #   ~/.config/gws-alt/     (johnnymo87@gmail.com)
  # Use switch-gws default|alt to swap between accounts.
  home.activation.assembleGwsCredentials = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    assemble_gws_account() {
      local dir="$1"
      local client_id="$2"
      local client_secret="$3"
      local refresh_token="$4"
      local project_id="''${5:-}"

      mkdir -p "$dir"

      # Assemble client_secret.json (OAuth client config for re-auth / token refresh)
      local tmp
      tmp="$(mktemp "''${dir}/client_secret.json.tmp.XXXXXX")"
      if [ -n "$project_id" ]; then
        ${pkgs.jq}/bin/jq -n \
          --arg cid "$client_id" \
          --arg cs "$client_secret" \
          --arg pid "$project_id" \
          '{
            installed: {
              client_id: $cid,
              project_id: $pid,
              auth_uri: "https://accounts.google.com/o/oauth2/auth",
              token_uri: "https://oauth2.googleapis.com/token",
              auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs",
              client_secret: $cs,
              redirect_uris: ["http://localhost"]
            }
          }' > "$tmp"
      else
        ${pkgs.jq}/bin/jq -n \
          --arg cid "$client_id" \
          --arg cs "$client_secret" \
          '{
            installed: {
              client_id: $cid,
              auth_uri: "https://accounts.google.com/o/oauth2/auth",
              token_uri: "https://oauth2.googleapis.com/token",
              auth_provider_x509_cert_url: "https://www.googleapis.com/oauth2/v1/certs",
              client_secret: $cs,
              redirect_uris: ["http://localhost"]
            }
          }' > "$tmp"
      fi
      mv "$tmp" "$dir/client_secret.json"
      chmod 600 "$dir/client_secret.json"

      # Assemble credentials.json (authorized_user tokens for API access)
      tmp="$(mktemp "''${dir}/credentials.json.tmp.XXXXXX")"
      ${pkgs.jq}/bin/jq -n \
        --arg cid "$client_id" \
        --arg cs "$client_secret" \
        --arg rt "$refresh_token" \
        '{
          type: "authorized_user",
          client_id: $cid,
          client_secret: $cs,
          refresh_token: $rt
        }' > "$tmp"
      mv "$tmp" "$dir/credentials.json"
      chmod 600 "$dir/credentials.json"
    }

    # Read default account secrets
    def_cid="" def_cs="" def_rt="" def_pid=""
    [ -r /run/secrets/gws_default_client_id ] && def_cid="$(cat /run/secrets/gws_default_client_id)"
    [ -r /run/secrets/gws_default_client_secret ] && def_cs="$(cat /run/secrets/gws_default_client_secret)"
    [ -r /run/secrets/gws_default_refresh_token ] && def_rt="$(cat /run/secrets/gws_default_refresh_token)"
    [ -r /run/secrets/gws_default_project_id ] && def_pid="$(cat /run/secrets/gws_default_project_id)"

    if [ -n "$def_cid" ] && [ -n "$def_cs" ] && [ -n "$def_rt" ]; then
      assemble_gws_account "$HOME/.config/gws" "$def_cid" "$def_cs" "$def_rt" "$def_pid"
      echo "assembleGwsCredentials: gws assembled"
    else
      echo "assembleGwsCredentials: skipping gws (secrets not available)"
    fi

    # Read alt account secrets
    alt_cid="" alt_cs="" alt_rt="" alt_pid=""
    [ -r /run/secrets/gws_alt_client_id ] && alt_cid="$(cat /run/secrets/gws_alt_client_id)"
    [ -r /run/secrets/gws_alt_client_secret ] && alt_cs="$(cat /run/secrets/gws_alt_client_secret)"
    [ -r /run/secrets/gws_alt_refresh_token ] && alt_rt="$(cat /run/secrets/gws_alt_refresh_token)"
    [ -r /run/secrets/gws_alt_project_id ] && alt_pid="$(cat /run/secrets/gws_alt_project_id)"

    if [ -n "$alt_cid" ] && [ -n "$alt_cs" ] && [ -n "$alt_rt" ]; then
      assemble_gws_account "$HOME/.config/gws-alt" "$alt_cid" "$alt_cs" "$alt_rt" "$alt_pid"
      echo "assembleGwsCredentials: gws-alt assembled"
    else
      echo "assembleGwsCredentials: skipping gws-alt (secrets not available)"
    fi
  '';

  # Deploy the shared DoltHub credential used by `bd dolt push/pull` to back up
  # the git-free beads issue DB (remote configured in .beads/config.yaml). The
  # Ed25519 JWK keypair lives in sops; we materialize it as a real 0600 file at
  # ~/.dolt/creds/<keyid>.jwk and point ~/.dolt/config_global.json at it via the
  # "user.creds" key (merged, not clobbered). The keyid is derived from the
  # public key and is therefore stable/known up front, identical on every host.
  home.activation.deployDoltCreds = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    keyid="6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve"
    secret="/run/secrets/dolthub_jwk"

    if [ ! -r "$secret" ]; then
      echo "deployDoltCreds: skipping (sops secret not available)"
    else
      creds_dir="$HOME/.dolt/creds"
      mkdir -p "$creds_dir"

      tmp="$(mktemp "$creds_dir/$keyid.jwk.tmp.XXXXXX")"
      cat "$secret" > "$tmp"
      mv "$tmp" "$creds_dir/$keyid.jwk"
      chmod 600 "$creds_dir/$keyid.jwk"

      # Point dolt at this credential without dropping any other config keys.
      cfg="$HOME/.dolt/config_global.json"
      existing="{}"
      [ -f "$cfg" ] && existing="$(cat "$cfg")"
      ctmp="$(mktemp "$HOME/.dolt/config_global.json.tmp.XXXXXX")"
      printf '%s' "$existing" | ${pkgs.jq}/bin/jq --arg k "$keyid" '.["user.creds"] = $k' > "$ctmp"
      mv "$ctmp" "$cfg"

      echo "deployDoltCreds: dolt credential deployed"
    fi
  '';

  # Backup /persist to a local tarball (cloud volume not included in Hetzner snapshots)
  home.file.".local/bin/backup-persist" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      timestamp=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
      dest="$HOME/persist-backup-$timestamp.tar.gz"

      echo "Backing up /persist to $dest ..."
      sudo ${pkgs.gnutar}/bin/tar czf "$dest" \
        --exclude='persist/lost+found' \
        -C / persist
      sudo chown dev:dev "$dest"
      echo "Backup complete: $dest ($(${pkgs.coreutils}/bin/du -h "$dest" | cut -f1))"
    '';
  };

  # Generate ensure-projects script from declarative manifest
  home.file.".local/bin/ensure-projects" = {
    executable = true;
    text = let
      mkLine = name: p: ''
        ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
      '';
      lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
    in ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Verify SSH key exists
      if [ ! -f "$HOME/.ssh/id_ed25519_github" ]; then
        echo "ERROR: GitHub SSH key not found at ~/.ssh/id_ed25519_github"
        echo "Run: sudo nixos-rebuild switch --flake .#devbox"
        exit 1
      fi

      base="$HOME/projects"

      ensure_repo() {
        local name="$1"
        local url="$2"
        local dir="$base/$name"

        if [ -d "$dir/.git" ]; then
          echo "OK: $name exists"
          return 0
        fi

        echo "Cloning $name ..."
        ${pkgs.git}/bin/git clone --recursive "$url" "$dir"
      }

      ${lines}

      echo "All projects ready."
    '';
  };

  # Systemd user service to ensure projects on login
  systemd.user.services.ensure-projects = {
    Unit = {
      Description = "Ensure declared dev projects are present in ~/projects";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/ensure-projects";
      StandardOutput = "journal";
      StandardError = "journal";
      Environment = [
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh"
        "HOME=%h"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Auto-expire old home-manager generations
  # System nix.gc runs weekly; this cleans up HM generations daily
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;  # Also run nix-collect-garbage for user store
  };

  # Git SSH wrapper for systemd services (avoids Environment= quoting issues)
  home.file.".local/bin/git-ssh-github" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      exec ${pkgs.openssh}/bin/ssh \
        -i "$HOME/.ssh/id_ed25519_github" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        "$@"
    '';
  };

  # Script to pull workstation updates and apply home-manager
  home.file.".local/bin/pull-workstation" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      export GIT_SSH_COMMAND="$HOME/.local/bin/git-ssh-github"

      repo="$HOME/projects/workstation"
      lock_dir="''${XDG_RUNTIME_DIR:-/tmp}"
      lock="$lock_dir/pull-workstation.lock"

      # Prevent concurrent runs
      exec 9>"$lock"
      ${pkgs.util-linux}/bin/flock -n 9 || { echo "Already running"; exit 0; }

      cd "$repo"

      # Fail if working tree is dirty
      if [[ -n "$(${pkgs.git}/bin/git status --porcelain)" ]]; then
        echo "Working tree not clean; skipping auto-pull"
        exit 0
      fi

      # Fetch and pull if there are updates
      ${pkgs.git}/bin/git fetch origin

      local_rev=$(${pkgs.git}/bin/git rev-parse HEAD)
      remote_rev=$(${pkgs.git}/bin/git rev-parse origin/main)

      if [[ "$local_rev" != "$remote_rev" ]]; then
        echo "Pulling updates..."
        # Fast-forward only (fail if diverged)
        ${pkgs.git}/bin/git pull --ff-only origin main
      else
        echo "Git already up to date"
      fi

      # Always attempt switch (handles retry after failed switch)
      echo "Applying home-manager..."
      ${pkgs.nix}/bin/nix run github:nix-community/home-manager/release-25.11 -- switch --flake "$repo#dev"

      echo "Update complete"
    '';
  };

  # Systemd service to pull and apply workstation updates
  systemd.user.services.pull-workstation = {
    Unit = {
      Description = "Pull workstation updates and apply home-manager";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/pull-workstation";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 15;                          # Low scheduling priority
      CPUQuota = "200%";                  # Hard cap at 2 cores (of 16)
      IOSchedulingClass = "idle";         # Yield IO to interactive work
      Environment = [
        "HOME=%h"
        "PATH=${pkgs.nix}/bin:${pkgs.git}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
      ];
    };
  };

  # Timer: run at startup + every 4 hours
  systemd.user.timers.pull-workstation = {
    Unit = {
      Description = "Pull workstation updates periodically";
    };
    Timer = {
      OnStartupSec = "10min";        # Run 10min after boot/login
      OnUnitInactiveSec = "4h";       # Then every 4h after last run
      RandomizedDelaySec = "15min";   # Jitter to avoid thundering herd
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # OpenCode headless serve POOL — K=2 templated user units (instance %i = port)
  # in the USER manager (user@1000.service), NOT system services. User-manager
  # placement is deliberate: sessions opencode spawns then live in a cgroup under
  # /user.slice/.../user@1000.service/..., so ~/projects/eternal-machinery/bin/
  # devenv-up takes its "Context B" branch (plain `systemd-run --user --scope`,
  # no `--machine=dev@.host`) and can place devenv into dev-daemons.slice. A
  # SYSTEM service cannot reach the dev@ user bus via `--machine=dev@.host` (it
  # fails with "Permission denied" / "Transport endpoint is not connected"),
  # which is why this lives here and not hosts/devbox/configuration.nix. Requires
  # linger (users.users.dev.linger = true in the devbox system config) so
  # user@1000.service is up at boot. Mirrors the crostini user service.
  #
  # mn9r M5: serve-0 binds 4096, the permanent anchor — clients create new
  # sessions on it and fall back to it, while M7 routes session-targeted traffic
  # to the owning serve via pigeon /route (opencode-launch/-send, reset-workspace,
  # opencode-llm-audit, my-podcasts, the telegram launch path). The hand-typed
  # `opencode attach` TUI still resolves :4096 directly (tracked in 7zr7); lgtm
  # run-mode is disabled. Setting OPENCODE_ROUTING_DB (Environment below)
  # activates the dormant M4 serve-side per-session lease CAS against pigeon's
  # routing DB. The cloudbox analog is the system templated `opencode-serve@` in
  # hosts/cloudbox/configuration.nix.
  systemd.user.services."opencode-serve@" = {
    Unit = {
      Description = "OpenCode headless serve (pool instance, port %i)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # M5.8/M6 fan-out: a target's Wants= does NOT propagate restart to its
      # units, so `systemctl --user restart opencode-serve-pool.target` alone is
      # a no-op on the serves. PartOf makes the target propagate stop/restart
      # down to every instance, so ONE target restart bounces all K serves (and
      # a target stop drains the pool). Start is still via the target's Wants=.
      PartOf = [ "opencode-serve-pool.target" ];
      # DM5-2: devbox pigeon is a SYSTEM unit, so this USER unit cannot order
      # After= it. A serve fails closed until pigeon has seeded the routing
      # schema (pigeon creates it when it inits the router); Restart=always
      # (below) just retries a too-early serve until the schema is up.
      # DM5-7: do NOT bounce the pool on routine `home-manager switch` (that
      # would kill all K serves + their live sessions). NixOS `restartIfChanged
      # = false` has no home-manager analog; sd-switch's X-SwitchMethod=keep-old
      # is the equivalent (honored by the default systemd.user.startServices=
      # sd-switch) — it leaves a running instance untouched on switch. Restarts
      # happen only via the explicit opencode-serve-pool.target fan-out (M5.8
      # hooks / M6 cutover).
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "OPENCODE_ENABLE_EXA=1"
        # Raise opencode's default output-token cap from 32k to 64k to match
        # Anthropic's recommendation for opus 4.7/4.8 at xhigh/high effort. The
        # home.sessionVariables entry in home.base.nix only covers interactive
        # shells; a systemd service needs it set explicitly.
        "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=65536"
        # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
        # sessionVariables for full rationale). Required by the K-serve pool —
        # every serve must share one DB. A user service does not source
        # ~/.profile, so the sessionVariables copy doesn't reach it.
        "OPENCODE_DB=${config.home.homeDirectory}/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
        # mn9r M5/M4 activation: each serve runs the per-session lease CAS against
        # pigeon's routing DB (the SAME file as pigeon's PIGEON_DAEMON_DB_PATH,
        # DM5-1). Until this var was set the M4 serve-lease code in the binary
        # stayed dormant.
        "OPENCODE_ROUTING_DB=${routingDbPath}"
        # opencode shells out to git/gh/node/rg/etc.; a user service does not
        # inherit the interactive login PATH, so set it explicitly. Order mirrors
        # the previous system service's
        #   path = [ "/run/wrappers" config.system.path "/home/dev/.nix-profile" ];
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        PORT="$1"
        # DM5-4: the serve id must match pigeon's seedServes order (endpoint i ->
        # serve-<i>). Generated from servePool.ports so it cannot drift.
        case "$PORT" in
${serveIdCase}
          *) echo "opencode-serve@: port $PORT not in serve-pool.nix"; exit 1 ;;
        esac
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        exec ${config.home.homeDirectory}/.nix-profile/bin/opencode serve --port "$PORT" --hostname 127.0.0.1
      ''} %i";
      # DM5-5 (revised 2026-07-03, workstation-94g8): PER-INSTANCE memory cap.
      # MemoryHigh is deliberately ABSENT. The old 4G-high/5G-max split put the
      # serve in a 1G-wide "throttled but never killed" band: memory.high
      # reclaim clamps usage at the soft ceiling forever, so MemoryMax/OOM/
      # Restart=always never fire, and a serve pinned there can freeze its
      # main JS event loop for minutes (memory.high direct-reclaim penalty on
      # the allocating thread) while worker-thread heartbeats keep it looking
      # healthy — the 2026-07-03 :4096 wedge (SIGTERM timeout -> SIGKILL at
      # the nightly reset). See docs/investigations/2026-07-03-serve-4096-wedge.md.
      # With Max-only, a ballooned serve OOM-kills fast and Restart=always
      # recovers it in ~10s (sessions persist in the shared DB; TUIs reconnect).
      # Budget: 6G/serve, K=2 -> 12G worst case, inside the user-1000.slice
      # MemoryHigh=20G (hosts/devbox/configuration.nix) on the 30G host.
      MemoryMax = "6G";
      OOMScoreAdjust = 500;
      Restart = "always";
      RestartSec = 10;
      # A wedged serve's SIGTERM handler is a JS-level process.once — a frozen
      # main loop provably never runs it (workstation-94g8), so waiting the
      # default 90s just stalls the nightly reset. 15s is generous for the
      # healthy graceful path (observed clean stops take 1-2s).
      TimeoutStopSec = 15;
    };
    # NOTE: no Install.WantedBy — a template unit cannot be enabled directly. The
    # opencode-serve-pool.target (below) Wants each instance and is itself
    # WantedBy default.target, so it pulls the K serves in on login/boot.
  };

  # mn9r M5: the serve-pool target. WantedBy default.target so the pool boots; it
  # Wants each templated instance (opencode-serve@<port>.service) so starting the
  # target pulls them all in, and PartOf on the instances (above) makes ONE
  # `systemctl --user restart opencode-serve-pool.target` fan out to all K (the
  # M5.8 restart-hook and M6 cutover both bounce the pool through this target).
  # keep-old keeps the target itself from being restarted on routine switches.
  systemd.user.targets.opencode-serve-pool = {
    Unit = {
      Description = "OpenCode serve pool (K warm serves on one opencode.db)";
      Wants = map (p: "opencode-serve@${toString p}.service") servePool.ports;
      X-SwitchMethod = "keep-old";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Serve-pool liveness canary (workstation-94g8, 2026-07-03 :4096 wedge).
  # A serve can be "alive but frozen": main JS event loop stalled (so
  # /global/health and even the JS-level SIGTERM handler are dead) while the
  # serve-lease worker-thread heartbeat keeps pigeon's health_state green and
  # Restart=always never fires (no OOM — see the MemoryMax-only rationale on
  # the serve unit above). Nothing watched for that state; the 2026-07-03
  # wedge sat invisible for >=93s until the nightly reset SIGKILLed it.
  # This timer probes each pool member's /global/health (3s timeout) once a
  # minute; after 3 consecutive failures it dumps cheap owner-readable
  # forensics (/proc status/wchan/syscall + cgroup memory.*) to
  # /tmp/opencode-serve-canary/ and restarts that one instance. Design notes
  # in .opencode/skills/monitoring-serve-pool/SKILL.md; full post-mortem in
  # docs/investigations/2026-07-03-serve-4096-wedge.md.
  systemd.user.services.opencode-serve-canary = {
    Unit.Description = "OpenCode serve pool liveness canary (restart wedged serves)";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "opencode-serve-canary" ''
        set -u
        # User-service PATH is minimal (no coreutils/systemctl) — be explicit.
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.util-linux pkgs.curl pkgs.elfutils pkgs.sudo ]}
        STATE=/tmp/opencode-serve-canary
        mkdir -p "$STATE"
        THRESHOLD=3

        # Don't fight an in-flight reset-workspace (it stops/starts the pool
        # deliberately). Shared, non-blocking probe of its lock. fd-based form:
        # `flock <file> <cmd>` execvp()s the command, which fails on the
        # minimal service PATH and misreads as "lock held".
        if [ -e /tmp/reset-workspace.lock ]; then
          exec 9< /tmp/reset-workspace.lock
          if ! flock -n -s 9; then
            echo "reset-workspace in progress; skipping this run"
            exit 0
          fi
          exec 9<&-
        fi

        for PORT in ${lib.concatMapStringsSep " " toString servePool.ports}; do
          UNIT="opencode-serve@$PORT.service"
          FAILFILE="$STATE/$PORT.fails"

          # Only police units that are supposed to be up. Intentional stops,
          # crash-loop backoff, etc. reset the counter.
          if [ "$(systemctl --user is-active "$UNIT")" != "active" ]; then
            rm -f "$FAILFILE"
            continue
          fi

          if curl -sf --max-time 3 --connect-timeout 3 \
               "http://127.0.0.1:$PORT/global/health" >/dev/null 2>&1; then
            rm -f "$FAILFILE"
            continue
          fi

          FAILS=$(( $(cat "$FAILFILE" 2>/dev/null || echo 0) + 1 ))
          echo "$FAILS" > "$FAILFILE"
          echo "WARNING: $UNIT failed /global/health ($FAILS/$THRESHOLD consecutive)"
          [ "$FAILS" -lt "$THRESHOLD" ] && continue

          # Wedged. Capture cheap forensics BEFORE the kill destroys them
          # (the 2026-07-03 wedge left no stacks/PSI behind).
          TS=$(date +%Y%m%dT%H%M%S)
          DUMP="$STATE/wedge-$TS-$PORT"
          mkdir -p "$DUMP"
          PID=$(systemctl --user show "$UNIT" -p MainPID --value)
          CG=$(systemctl --user show "$UNIT" -p ControlGroup --value)
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            for f in status wchan syscall; do
              cat "/proc/$PID/$f" > "$DUMP/$f" 2>/dev/null || true
            done
            # Per-thread kernel wait channels (owner-readable, unlike /proc/pid/stack).
            for t in /proc/$PID/task/*/; do
              tid=$(basename "$t")
              printf '%s %s %s\n' "$tid" "$(cat "$t/wchan" 2>/dev/null)" \
                "$(cat "$t/comm" 2>/dev/null)" >> "$DUMP/threads" 2>/dev/null || true
            done
          fi
          if [ -n "$CG" ]; then
            for f in memory.current memory.peak memory.max memory.stat memory.pressure cpu.pressure cgroup.procs; do
              cat "/sys/fs/cgroup$CG/$f" > "$DUMP/$f" 2>/dev/null || true
            done
          fi
          # Deep forensics (workstation-g3iy): today's wedges spin in USERSPACE
          # at ~2G with zero memory pressure, so cheap /proc dumps can't tell
          # GC-thrash from a synchronous bun:sqlite scan. Capture:
          #  - utime/stime split over 2s (pure utime = JS/GC spin; stime = syscall/IO)
          #  - /proc io before/after (read_bytes growth = sqlite paging)
          #  - 3x native thread stacks via eu-stack (needs sudo: yama
          #    ptrace_scope=1 blocks non-ancestor same-uid ptrace). The bun
          #    binary is non-PIE ET_EXEC so raw addresses are STABLE across
          #    runs/wedges: identical frames across samples = tight-loop
          #    fingerprint even without symbols.
          # All best-effort; a truly frozen loop can't get worse from a brief
          # ptrace stop, and the restart follows immediately anyway.
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            {
              awk '{print "utime="$14, "stime="$15}' "/proc/$PID/stat" 2>/dev/null
              cat "/proc/$PID/io" 2>/dev/null
              sleep 2
              awk '{print "utime="$14, "stime="$15}' "/proc/$PID/stat" 2>/dev/null
              cat "/proc/$PID/io" 2>/dev/null
              echo "clk_tck=100 interval=2s"
            } > "$DUMP/cpu-io-split" 2>/dev/null || true
            for i in 1 2 3; do
              sudo -n timeout 10 eu-stack -p "$PID" > "$DUMP/eu-stack.$i" 2>&1 || true
              sleep 1
            done
          fi
          echo "RESTARTING wedged $UNIT (pid=$PID); forensics in $DUMP"
          systemctl --user restart "$UNIT"
          rm -f "$FAILFILE"
        done
      ''}";
    };
  };
  systemd.user.timers.opencode-serve-canary = {
    Unit.Description = "Minutely OpenCode serve pool liveness canary";
    Timer = {
      OnCalendar = "minutely";
      AccuracySec = "15s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Phantom-busy sweeper (workstation-utnw, 2026-07-03). When a serve dies
  # uncleanly (canary SIGKILL, OOM, hard reboot) its in-flight assistant
  # messages are never finalized: `time.completed` stays NULL in the message
  # row, so every TUI that (re)loads the session renders the "working"
  # animation forever — observed burning ~1 CPU core per TUI in a GC storm
  # for hours. This timer finalizes provably-orphaned in-flight messages:
  # role=assistant, no time.completed, no error, AND the row untouched for
  # >30min (a streaming turn bumps time_updated on every part append; the
  # 30min gate leaves headroom for long silent tool calls — and even a
  # false positive is self-healing, since the owning serve's own completion
  # write lands last). Writes the canonical MessageAbortedError shape so
  # clients treat it exactly like a user abort. Safe against live serves:
  # WAL mode, single short transaction, busy_timeout.
  systemd.user.services.opencode-phantom-busy-sweeper = {
    Unit.Description = "Finalize orphaned in-flight opencode messages (phantom busy)";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "opencode-phantom-busy-sweeper" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.sqlite ]}
        DB="$HOME/.local/share/opencode/opencode.db"
        [ -f "$DB" ] || exit 0
        sqlite3 "$DB" "
          PRAGMA busy_timeout=10000;
          UPDATE message SET data = json_set(data,
              '\$.time.completed', CAST(strftime('%s','now') AS INTEGER)*1000,
              '\$.error', json('{\"name\":\"MessageAbortedError\",\"data\":{\"message\":\"Aborted (phantom-busy sweeper: serve died mid-turn)\"}}'))
          WHERE json_extract(data, '\$.role') = 'assistant'
            AND json_extract(data, '\$.time.completed') IS NULL
            AND json_extract(data, '\$.error') IS NULL
            AND time_updated < (strftime('%s','now') - 1800) * 1000;
          SELECT 'finalized ' || changes() || ' orphaned message(s)';
        "
      ''}";
    };
  };
  systemd.user.timers.opencode-phantom-busy-sweeper = {
    Unit.Description = "Periodic phantom-busy message finalization";
    Timer = {
      OnCalendar = "*:0/5";
      AccuracySec = "30s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # TeamClaude CLI on PATH so the interactive seed flow works:
  #   teamclaude login        # PKCE OAuth, one per Max account (needs TTY+browser)
  #   teamclaude accounts     # verify
  #   teamclaude probe 90     # enable the proactive usage probe (reads
  #                           # /api/oauth/usage every 90s; no quota spend). This
  #                           # is what populates scoped weekly limits (Opus/Sonnet)
  #                           # so the opus-aware failover routes proactively.
  # NOTE: `probe` persists quotaProbeSeconds into the writable runtime config
  # (~/.config/teamclaude.json), so it survives restarts but is LOST on a full
  # reseed — re-run it as part of any from-scratch seed (alongside `login`).
  # Nix-packaged (pkgs/teamclaude) — pulled + installed by home-manager, no checkout.
  home.packages = [ localPkgs.teamclaude ];

  # TeamClaude: multi-account Claude Max rotator. A local Anthropic-API proxy on
  # 127.0.0.1:3456 that rotates across personal Max accounts and injects the
  # active account's OAuth token. devbox is the "play" box (no Vertex/aigateway),
  # so this is the personal-Claude analog of cloudbox's cfp router — minus the
  # budget gating, which is meaningless without Vertex spend to cap. opencode is
  # pointed at it by `injectTeamclaudeBaseUrl` in opencode-config.nix (gated on
  # this unit being active, with auto-fallback to direct Anthropic).
  #
  # CONFIG IS RUNTIME STATE (NOT nix-managed): teamclaude reads + REWRITES
  # ~/.config/teamclaude.json (OAuth tokens auto-refresh + persist), so it must
  # stay writable + persistent. Accounts are added out-of-band via the
  # interactive `teamclaude login` (PKCE OAuth, needs a TTY + browser); this unit
  # only RUNS an already-seeded config.
  #
  # SEED-FIRST: with zero accounts the server exits 1 ("No accounts configured")
  # and Restart=always would crash-loop. ConditionPathExists gates the unit on
  # the config file so it stays inactive (not failed) until you've logged in; the
  # StartLimit caps any residual loop (e.g. config present but empty). After
  # `teamclaude login`, run `systemctl --user enable --now teamclaude`.
  #
  # BIND + AUTH: index.js listens on all interfaces (can't pass a host without
  # patching the checkout), but two backstops keep :3456 private — (1) devbox's
  # NixOS firewall does NOT open TCP 3456, and (2) the proxy's own auth gate
  # requires x-api-key for non-localhost clients. opencode connects via 127.0.0.1
  # (localhost-exempt), so no key is needed locally.
  #
  # PLUGIN REQUIRED (do NOT remove @ex-machina/opencode-anthropic-auth):
  # TeamClaude only swaps the OAuth bearer token — it does NOT shape the request.
  # Claude Max OAuth needs a Claude-Code-shaped request (anthropic-beta:
  # oauth-2025-04-20, ?beta=true, a "You are Claude Code" system identity, mcp_
  # tool prefixes) or Anthropic 429s opus/sonnet and TeamClaude retry-loops
  # forever (opencode hangs). That shaping comes from the opencode plugin.
  # `injectTeamclaudeBaseUrl` (opencode-config.nix) keeps the plugin shape-only by
  # seeding a non-expiring dummy oauth credential so it shapes requests without
  # refreshing tokens (a refresh would rotate the shared Claude-Code client_id
  # grant and break TeamClaude's tokens with invalid_grant). See that activation's
  # header comment for the full rationale.
  systemd.user.services.teamclaude = {
    Unit = {
      Description = "TeamClaude (multi-account Claude Max rotator)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      ConditionPathExists = "%h/.config/teamclaude.json";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        # Pin the config path so it never depends on XDG_CONFIG_HOME.
        "TEAMCLAUDE_CONFIG=${config.home.homeDirectory}/.config/teamclaude.json"
        # A user service does not inherit the interactive login PATH; node is
        # already baked into the wrapper, but keep the standard set for parity.
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin"
      ];
      ExecStart = "${localPkgs.teamclaude}/bin/teamclaude server --headless";
      Restart = "always";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # Sibling slices under user@1000.service for explicit placement of
  # agent workloads and devenv stacks. Processes do NOT land here
  # automatically — they're reached via systemd-run --user --scope
  # --slice=agents.slice ... (see bin/agent-run, bin/devenv-up in the
  # eternal-machinery repo).
  #
  # PIDs-only for phase 1 per the design doc. No memory or CPU caps;
  # the parent user-1000.slice already has MemoryHigh=12G and
  # MemorySwapMax=6G, which is sufficient.
  #
  # See docs/plans/2026-04-18-agents-slice-hierarchy-design.md (Phase 0)
  # in the eternal-machinery repo.
  systemd.user.slices = {
    agents = {
      Unit.Description = "AI agent workloads (fan-out fence)";
      Slice = {
        TasksMax = 512;
      };
    };

    dev-daemons = {
      Unit.Description = "Interactive dev daemons (devenv stacks)";
      Slice = {
        TasksMax = 1536;
      };
    };
  };
}
