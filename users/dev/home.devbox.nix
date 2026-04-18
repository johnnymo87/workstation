# Devbox-specific home-manager configuration
# Contains systemd services, sops secrets, and other devbox-only features
{ config, pkgs, lib, projects, isDevbox, ... }:

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

    # Personal Claude subscription token (not work account)
    # Enables headless/cron Claude Code without interactive OAuth
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

  # Mask GPG agent units for forwarding (systemd-specific)
  # Masks both sockets AND service to prevent any local agent from starting
  home.activation.maskGpgAgentUnits = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.config/systemd/user"
    for unit in gpg-agent.service gpg-agent.socket gpg-agent-extra.socket gpg-agent-browser.socket gpg-agent-ssh.socket; do
      ln -sf /dev/null "$HOME/.config/systemd/user/$unit"
    done
    ${pkgs.systemd}/bin/systemctl --user daemon-reload 2>/dev/null || true
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

  # Ensure GPG socket directory exists before SSH tries to bind RemoteForward
  systemd.user.tmpfiles.rules = [
    "d %t/gnupg 0700 - - -"
  ];

  # GPG common.conf for devbox: no-autostart prevents local agent from clobbering
  # the forwarded socket. Do NOT use use-keyboxd here (causes issues with no-autostart).
  home.file.".gnupg/common.conf".text = ''
    no-autostart
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
