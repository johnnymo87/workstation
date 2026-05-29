# NixOS system configuration for cloudbox (GCP ARM devbox)
#
# Differences from devbox (Hetzner):
#   - No /persist volume or bind mounts (single persistent boot disk)
#   - SSH via GCP OS Login (handled by google-compute-config.nix in hardware.nix)
#   - No my-podcasts consumer (personal project)
#   - claude_personal_oauth_token IS present (mirrors devbox so opencode-serve
#     can authenticate as the personal Anthropic subscription via the
#     @ex-machina/opencode-anthropic-auth opencode plugin; Claude Code itself
#     is not installed)
#   - No R2/OpenAI secrets (not needed here)
#   - Pigeon uses CCR_MACHINE_ID=cloudbox
#   - Firewall disabled (google-compute-config defers to GCP firewall)
{ config, pkgs, lib, ... }:

let
  enableLgtm = true;  # AI-powered PR review daemon (flip to true to activate)

  # oc-auto-attach is a self-packaged shell tool (pkgs/oc-auto-attach) that the
  # pigeon daemon shells out to after a `/launch` telegram command, to open the
  # new session in the right tmux+nvim window. We pin its absolute path here
  # because the daemon runs under systemd with a locked-down PATH that does NOT
  # include ~/.nix-profile/bin (where home-manager installs it for the user).
  # Without this, the spawn returns ENOENT and is silently swallowed — sessions
  # launched from telegram never auto-attach. The same package is *also*
  # installed into the user's profile via users/dev/home.base.nix, so the CLI
  # `opencode-launch` keeps working as before.
  oc-auto-attach = pkgs.callPackage ../../pkgs/oc-auto-attach { };

  # nvims is the nvim launcher (pkgs/nvims) that oc-auto-attach spawns when it
  # needs to create a new tmux window for a launched session. Same locked-down
  # PATH problem as oc-auto-attach above: without an absolute path injected
  # into the pigeon-daemon service env, `command -v nvims` returns empty and
  # the script's "tmux new-window -- nvims" branch silently skips. End result:
  # /launch into a project with no existing nvim pane runs headlessly inside
  # opencode-serve with no plugin loaded, completes with no Telegram
  # notification, and the user is left hanging. See workstation-1lp.
  nvims = pkgs.callPackage ../../pkgs/nvims { };
in
{
  # Guard: abort activation if applying the wrong host's config.
  # Devbox and cloudbox share arch and user — applying the wrong flake target
  # overwrites system identity, secrets paths, and service configs.
  # Skipped when /etc/hostname doesn't exist yet (fresh nixos-anywhere install).
  system.activationScripts.assertHostname = ''
    expected="cloudbox"
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
      # Personal Anthropic subscription token. Consumed by the
      # @ex-machina/opencode-anthropic-auth opencode plugin (loaded by
      # opencode-serve below) to authenticate against the Anthropic API as
      # the personal subscription. Despite the secret name and the
      # CLAUDE_CODE_OAUTH_TOKEN env-var name (which the plugin requires
      # verbatim), Claude Code itself is not installed.
      claude_personal_oauth_token = {
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
      # BuildBuddy host + org API key (read-only). Used by `bb` CLI and the
      # bb-test-log helper to fetch raw test logs from the BuildBuddy
      # enterprise API. See assets/opencode/skills/using-buildbuddy.
      buildbuddy_host = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      buildbuddy_api_key = {
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
      # PagerDuty MCP User API token
      pagerduty_user_api_key = {
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
      # aigateway dev-checkout path (org-identifying directory name, treated as a secret to keep it out of public source)
      aigateway_dir = {
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
      # Generic-named per scrubbing-company-references skill: the host name
      # (which encodes the vendor) is itself stored as a separate secret and
      # composed at activation time into the Bundler-required env var name.
      bundle_source_host = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      bundle_source_token = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Bazel remote cache URL — the bucket name encodes the GCP project,
      # so it lives in sops and is templated into ~/.bazelrc at activation.
      bazel_remote_cache_url = {
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
        # Absolute path to oc-auto-attach so launch-ingest.ts can find it
        # despite the locked-down systemd PATH. See let-binding above.
        "OC_AUTO_ATTACH_BIN=${oc-auto-attach}/bin/oc-auto-attach"
        # Absolute path to nvims so oc-auto-attach can spawn it when it has
        # to create a fresh tmux window. Same locked-down-PATH reasoning.
        "OC_NVIMS_BIN=${nvims}/bin/nvims"
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

  # LGTM v2 — context-aware AI PR review via OpenCode
  # Gated behind enableLgtm flag (default: false). Flip the let-binding
  # at the top of this file to activate. The service exists in the config
  # only when enabled, so flake evaluation is unaffected when disabled.
  systemd.services.lgtm-run = lib.mkIf enableLgtm {
    description = "LGTM PR review cycle";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "opencode-serve.service" ];
    # `openssh` is defense-in-depth: lgtm's `git fetch` passes
    # `--recurse-submodules=no` so submodule recursion never invokes
    # ssh, but if any other code path (or a future regression) tries
    # to ssh, this at least keeps the binary discoverable. Without it
    # git fails with `cannot run ssh: No such file or directory` and
    # surfacing that error is harder to debug than an auth failure.
    # Real-world trigger: food-truck/mono#2841, where a submodule
    # gitlink + missing ssh broke every cycle on 2026-04-23.
    path = [ pkgs.nodejs pkgs.git pkgs.gh pkgs.jq pkgs.curl pkgs.coreutils pkgs.bash pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/lgtm";
      Environment = [
        "HOME=/home/dev"
        "OPENCODE_URL=http://127.0.0.1:4096"
        "LGTM_PROJECTS_DIR=/home/dev/projects"
        # When the agent submits APPROVE on a PR by one of these authors,
        # Phase 4 of the review prompt instructs it to immediately enable
        # GitHub auto-merge (gh pr merge --auto --squash) so dependency
        # bumps don't sit approved-but-unmerged. Dependabot doesn't
        # auto-merge itself; renovate is listed defensively in case scope
        # expands. Mirror this list with lgtm.yml's `authors` allowlist.
        "LGTM_AUTO_APPROVE_AUTHORS=dependabot[bot],renovate[bot]"
      ];
      ExecStart = "${pkgs.writeShellScript "lgtm-run" ''
        set -euo pipefail
        export PATH="/home/dev/.nix-profile/bin:/home/dev/.local/bin:$PATH"
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        # Atlassian credentials for buildContextPacket's Jira/Confluence fetch
        # (lgtm-wa9). The pure-TS path early-exits when ATLASSIAN_API_TOKEN is
        # absent, so the daemon still runs degraded; these exports are what
        # turn the feature on. Mirrors opencode-serve.service's pattern above.
        # Secrets are already declared in sops.secrets; this just plumbs them in.
        if [ -r /run/secrets/atlassian_api_token ]; then
          export ATLASSIAN_API_TOKEN="$(cat /run/secrets/atlassian_api_token)"
        fi
        if [ -r /run/secrets/atlassian_site ]; then
          export ATLASSIAN_SITE="$(cat /run/secrets/atlassian_site)"
        fi
        if [ -r /run/secrets/atlassian_email ]; then
          export ATLASSIAN_EMAIL="$(cat /run/secrets/atlassian_email)"
        fi
        if [ -r /run/secrets/atlassian_cloud_id ]; then
          export ATLASSIAN_CLOUD_ID="$(cat /run/secrets/atlassian_cloud_id)"
        fi
        if [ ! -d /home/dev/projects/lgtm/node_modules ]; then
          cd /home/dev/projects/lgtm
          ${pkgs.nodejs}/bin/npm install
        fi
        exec ${pkgs.nodejs}/bin/node \
          /home/dev/projects/lgtm/node_modules/tsx/dist/cli.mjs \
          /home/dev/projects/lgtm/src/index.ts
      ''}";
    };
  };

  systemd.timers.lgtm-run = lib.mkIf enableLgtm {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      Persistent = true;
    };
  };

  systemd.services.opencode-serve = {
    description = "OpenCode headless serve";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "sops-nix.service" "aigateway.service" ];
    wants = [ "aigateway.service" ];
    # NOTE: NixOS treats each `path` entry as a package directory and
    # auto-appends `/bin` and `/sbin` when composing PATH. So pass
    # `/home/dev/.local` (NOT `/home/dev/.local/bin`) — it expands to
    # `/home/dev/.local/bin` and `/home/dev/.local/sbin`. Appended LAST
    # so nix-managed binaries always win on name collisions (e.g. a
    # misbehaving `gh` dropped in ~/.local/bin would not shadow the nix
    # one). Required by the lgtm multi-reviewer feature: dispatched
    # review sessions invoke `lgtm-gh` (a stub wrapper at
    # ~/.local/bin/lgtm-gh until the production wrapper ships
    # nix-managed) for state-changing GitHub operations. See lgtm:
    # docs/plans/2026-04-30-multi-reviewer-identity-design.md.
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" "/home/dev/.local" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
        # Vertex AI: Gemini 3.x preview models (incl. gemini-3.1-pro-preview used
        # by subagents on cloudbox) are only deployed to the "global" location.
        # Without this, the @ai-sdk/google-vertex provider defaults to a regional
        # endpoint (us-central1) which 404s. Mirrors the bash export in
        # users/dev/home.base.nix:1358 — that one only covers interactive shells,
        # systemd services need it set explicitly. See error:
        #   "Publisher Model projects/<proj>/locations/us-central1/publishers/
        #    google/models/gemini-3.1-pro-preview was not found ..."
        "GOOGLE_CLOUD_LOCATION=global"
        # Raise opencode's default output-token cap from 32k to 64k to match
        # Anthropic's recommendation for opus 4.7/4.8 at xhigh effort. Mirrors
        # the home.sessionVariables entry in users/dev/home.base.nix — that one
        # only covers interactive shells, opencode-serve needs it set
        # explicitly. See full rationale there.
        "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=65536"
      ];
      ExecStart = "${pkgs.writeShellScript "opencode-serve-start" ''
        set -euo pipefail
        export GH_TOKEN="$(cat /run/secrets/github_api_token)"
        export CLOUDFLARE_API_TOKEN="$(cat /run/secrets/cloudflare_api_token)"
        # Personal Anthropic subscription auth for the
        # @ex-machina/opencode-anthropic-auth opencode plugin. Lets opencode
        # call Anthropic directly (anthropic/claude-*) using the personal
        # subscription instead of going through google-vertex-anthropic. The
        # default model is still set by opencodeOverlay in
        # users/dev/opencode-config.nix; this just makes the anthropic
        # provider work when the user (or a subagent) selects it. The plugin
        # requires the env var to be named CLAUDE_CODE_OAUTH_TOKEN exactly --
        # don't rename it.
        if [ -r /run/secrets/claude_personal_oauth_token ]; then
          export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/claude_personal_oauth_token)"
        fi
        export GOOGLE_GENERATIVE_AI_API_KEY="$(cat /run/secrets/gemini_api_key)"
        if [ -r /run/secrets/google_cloud_project ]; then
          export GOOGLE_CLOUD_PROJECT="$(cat /run/secrets/google_cloud_project)"
        fi
        export GOOGLE_APPLICATION_CREDENTIALS="/home/dev/.config/gcloud/application_default_credentials.json"
        # Atlassian credentials for any opencode-serve-spawned subprocess that
        # needs Jira/Confluence (e.g. lgtm's nvim atlassian fetch in
        # buildContextPacket -- see lgtm-wa9). Mirrors the interactive-shell
        # exports in users/dev/home.cloudbox.nix:77-91; systemd services don't
        # source ~/.bashrc so they need their own copy. The four secrets are
        # already declared in sops.secrets above; this just plumbs them into
        # the service environment.
        if [ -r /run/secrets/atlassian_api_token ]; then
          export ATLASSIAN_API_TOKEN="$(cat /run/secrets/atlassian_api_token)"
        fi
        if [ -r /run/secrets/atlassian_site ]; then
          export ATLASSIAN_SITE="$(cat /run/secrets/atlassian_site)"
        fi
        if [ -r /run/secrets/atlassian_email ]; then
          export ATLASSIAN_EMAIL="$(cat /run/secrets/atlassian_email)"
        fi
        if [ -r /run/secrets/atlassian_cloud_id ]; then
          export ATLASSIAN_CLOUD_ID="$(cat /run/secrets/atlassian_cloud_id)"
        fi
        # BuildBuddy credentials for `bb-test-log` and API helpers launched
        # from OpenCode sessions. Mirrors the interactive-shell exports in
        # users/dev/home.cloudbox.nix; systemd services don't source ~/.bashrc.
        if [ -r /run/secrets/buildbuddy_host ]; then
          export BUILDBUDDY_HOST="$(cat /run/secrets/buildbuddy_host)"
        fi
        if [ -r /run/secrets/buildbuddy_api_key ]; then
          export BUILDBUDDY_API_KEY="$(cat /run/secrets/buildbuddy_api_key)"
        fi
        # Datadog credentials for `dd-cli` launched from OpenCode sessions.
        # Mirrors the interactive-shell exports in users/dev/home.cloudbox.nix;
        # systemd services don't source ~/.bashrc.
        export DD_SITE="us3.datadoghq.com"
        if [ -r /run/secrets/dd_api_key ]; then
          export DD_API_KEY="$(cat /run/secrets/dd_api_key)"
        fi
        if [ -r /run/secrets/dd_app_key ]; then
          export DD_APP_KEY="$(cat /run/secrets/dd_app_key)"
        fi
        exec /home/dev/.nix-profile/bin/opencode serve --port 4096 --hostname 127.0.0.1
      ''}";
      # Cap the always-on headless server so it can't monopolize RAM alone.
      MemoryMax = "24G";
      MemoryHigh = "20G";
      OOMScoreAdjust = "500";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # Aigateway: local Anthropic-on-Vertex proxy that captures per-request
  # attribution to a Postgres ledger. The path to the dev checkout is held
  # in the `aigateway_dir` sops secret; the start.sh script in that dir
  # (1) bazel-builds the server.jar + migrate.jar then (2) brings up
  # Docker Compose (Postgres + Redis + Spring Boot on :8080).
  #
  # First boot: ~2 min for the Bazel build on a clean cache. Subsequent
  # boots: ~10 sec.
  #
  # Disabled by default — enable with `sudo systemctl enable --now
  # aigateway.service`. The home-manager activation
  # `injectAigatewayBaseUrl` keys off this unit's `is-enabled` state to
  # decide whether to point opencode at the gateway.
  systemd.services.aigateway = {
    description = "AI Gateway (local Anthropic-on-Vertex proxy)";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "docker.service" ];
    # Disabled by default — operator opts in.
    wantedBy = [ ];

    # Path to the dev checkout (org-identifying directory name) lives in
    # the aigateway_dir sops secret; the bash shim resolves it at runtime.
    # Drop AssertFileIsExecutable — it requires a literal path, which we
    # can't have. The bash `cd` in ExecStart fails loudly if the path is
    # missing or the secret is unavailable.

    # bazel lives at /home/dev/.local/bin/bazel (symlink into ~/.nix-profile),
    # docker is in system path, coreutils via system path. Same recipe as
    # opencode-serve.
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" "/home/dev/.local" ];

    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      # No WorkingDirectory — handled by `cd` in the shim.
      # `start.sh -d` runs the bazel build in foreground then `docker
      # compose up -d`. After detach, the service "succeeds" — but we
      # need the unit to stay active so `is-enabled`/`is-active` reflect
      # operator intent. Type=oneshot + RemainAfterExit handles that.
      RemainAfterExit = true;
      # `cd "$(cat ...)"` resolves at every start. exec replaces the bash
      # process so systemd tracks start.sh's PID, not the bash wrapper.
      ExecStart = "${pkgs.bash}/bin/bash -c 'cd \"$(cat /run/secrets/aigateway_dir)\" && exec ./start.sh -d'";
      ExecStop = "${pkgs.bash}/bin/bash -c 'cd \"$(cat /run/secrets/aigateway_dir)\" && exec ${pkgs.docker}/bin/docker compose down'";
      # Bazel + Docker Compose can take a while on first boot.
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  # Nightly workspace reset (3 AM). Replaces the previous serve-only
  # restart with a full workspace reset (kill nvims, clear opencode
  # sessions, restart opencode-serve, respawn nvims). The serve restart
  # still happens — that was the original purpose (memory hygiene) — but
  # now it's bundled with the rest of the reset.
  #
  # Runs as user `dev` so it can drive the user's tmux server.
  # Passwordless `sudo systemctl restart opencode-serve` works because
  # `dev` is in the `wheel` group and `security.sudo.wheelNeedsPassword`
  # is false (set elsewhere in this file).
  systemd.services.nightly-restart-background = {
    description = "Nightly workspace reset (kill nvims, restart opencode-serve, respawn)";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      Environment = [
        "TMUX_TMPDIR=/tmp"
        "PATH=/run/current-system/sw/bin:/home/dev/.nix-profile/bin"
      ];
    };
    script = ''
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
    max-jobs = 8;   # Half of 16 cores — leave capacity for interactive work
    cores = 4;      # Max 4 cores per individual build derivation
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
  # exceeds 56 GB. Leaves ~6 GB for system/kernel/buffers on the 64 GB box.
  # Also cap user swap usage so system services always have swap headroom.
  systemd.slices."user-1000" = {
    description = "User slice for UID 1000 (dev)";
    sliceConfig = {
      MemoryHigh = "56G";
      MemorySwapMax = "24G";
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
    # Detect dead clients so stale sessions don't hold remote-forwarded
    # ports (gclpr 2850, CDP 9222/9223, etc.) after a VPN cycle or
    # network drop.  Without this, orphaned sshd sessions linger
    # indefinitely and block new tunnel connections from binding.
    ClientAliveInterval = 30;
    ClientAliveCountMax = 3;
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
