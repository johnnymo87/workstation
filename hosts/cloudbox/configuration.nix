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

  # claude-failover-proxy (cfp): the budget-gated Vertex->Max failover router
  # (8fe.14 / T13). Packaged from the private GitHub release asset; see
  # pkgs/claude-failover-proxy/default.nix. NixOS configs don't receive the
  # flake's localPkgs, so callPackage it directly here for the systemd service.
  claude-failover-proxy = pkgs.callPackage ../../pkgs/claude-failover-proxy { };

  # teamclaude: the personal Claude Max rotator (johnnymo87/teamclaude fork,
  # opus-aware). Same rationale as above — NixOS configs don't receive the
  # flake's localPkgs, so callPackage pkgs/teamclaude directly for the service.
  teamclaude = pkgs.callPackage ../../pkgs/teamclaude { };

  # mn9r M5: serve-pool descriptor (single source of truth in
  # users/dev/serve-pool.nix). cloudbox = K=4 on ports 4096..4099, serve-0 ==
  # :4096. routingDbPath is the file BOTH the serves (OPENCODE_ROUTING_DB) and
  # pigeon (PIGEON_DAEMON_DB_PATH) open for the session-lease CAS (DM5-1). It is
  # pigeon's EXISTING unified daemon DB (the pigeon service's
  # WorkingDirectory/data/pigeon-daemon.db default) — that single file holds
  # pigeon's swarm/outbox state AND the routing tables, so we point both env
  # vars at it rather than a fresh path (a fresh path would orphan pigeon's
  # swarm/outbox state and force a re-seed). pigeon already created the routing
  # schema there (checksum e5c8e409..., version 1), so serves boot-assert clean.
  servePool = (import ../../users/dev/serve-pool.nix).forHost.cloudbox;
  routingDbPath = "/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db";
  # port -> OPENCODE_SERVE_ID lookup for the templated unit's ExecStart, where
  # the systemd instance specifier %i is the port. Generated from the same list
  # as PIGEON_SERVE_ENDPOINTS so serve-<i> can never drift from endpoint i.
  serveIdCase = lib.concatStringsSep "\n" (lib.imap0
    (i: port: "          ${toString port}) export OPENCODE_SERVE_ID=serve-${toString i} ;;")
    servePool.ports);
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
      # TeamClaude proxy.apiKey. This is a COPY of proxy.apiKey in the
      # writable runtime config at /home/dev/.config/teamclaude.json (which
      # TeamClaude owns and rewrites on OAuth-token refresh). The two MUST
      # match. The teamclaude.service reads its apiKey from that config file,
      # NOT from here — this secret exists so (a) the verification curl can
      # authenticate and (b) the claude-failover-proxy router can send it as
      # CFP_TEAMCLAUDE_API_KEY (8fe.14 / T13). Rotating means regenerating in
      # both places.
      teamclaude_api_key = {
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
      # Rollbar MCP project access token (read scope)
      rollbar_access_token = {
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
        # open as OPENCODE_ROUTING_DB (DM5-1).
        "PIGEON_SERVE_ENDPOINTS=${servePool.endpointsCsv}"
        "PIGEON_SERVE_LIVENESS=self"
        "PIGEON_DAEMON_DB_PATH=${routingDbPath}"
        # /model provider allowlist. cloudbox has Vertex creds connected, so opt
        # this machine into the two Vertex families on top of the anthropic/openai
        # default. (devbox has no Vertex creds and keeps the default.) Parsed by
        # packages/daemon/src/config.ts.
        "PIGEON_ALLOWED_PROVIDERS=anthropic,openai,google-vertex,google-vertex-anthropic"
        # Absolute path to oc-auto-attach so launch-ingest.ts can find it
        # despite the locked-down systemd PATH. See let-binding above.
        "OC_AUTO_ATTACH_BIN=${oc-auto-attach}/bin/oc-auto-attach"
        # Absolute path to nvims so oc-auto-attach can spawn it when it has
        # to create a fresh tmux window. Same locked-down-PATH reasoning.
        "OC_NVIMS_BIN=${nvims}/bin/nvims"
        # Absolute paths to tmux/pgrep so the /current-state command's
        # main-session enumeration (main-session-allowlist.ts) can shell out
        # to them despite the locked-down systemd PATH. Same reasoning as
        # OC_AUTO_ATTACH_BIN above. The daemon shares the host /tmp
        # (PrivateTmp=no) and runs as dev (uid 1000) with no TMUX_TMPDIR
        # override, so it reaches the user's default tmux socket at
        # /tmp/tmux-1000/default where the `main` session lives.
        "TMUX_BIN=${pkgs.tmux}/bin/tmux"
        "PGREP_BIN=${pkgs.procps}/bin/pgrep"
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
    after = [ "network-online.target" "opencode-serve-pool.target" ];
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
      # lgtm run mode (LGTM_DISPATCH_MODE=run) spawns detached `opencode run`
      # children that must OUTLIVE the cycle's ExecStart — the watchdog reaps
      # their completion on a later cycle. The default KillMode=control-group
      # SIGKILLs the entire service cgroup when ExecStart exits, and a detached
      # child (new process group via spawn's {detached:true}) does NOT escape the
      # cgroup, so it gets killed one event in (observed: food-truck/mono#3569
      # died right after step_start). KillMode=process kills only the main
      # process on deactivation, leaving the detached review/assist children
      # alive to finish and self-reap. Harmless for serve mode (no children).
      KillMode = "process";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/lgtm";
      Environment = [
        "HOME=/home/dev"
        "OPENCODE_URL=http://127.0.0.1:4096"
        "LGTM_PROJECTS_DIR=/home/dev/projects"
        # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
        # sessionVariables for rationale). lgtm run-mode spawns detached
        # `opencode run` children that inherit this env and must hit the same DB.
        "OPENCODE_DB=/home/dev/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
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

  # mn9r M5: K-serve pool. Templated unit (instance %i = port) so one restart of
  # opencode-serve-pool.target fans out to all K serves. serve-0 binds 4096, so
  # the existing :4096 consumers (pigeon OPENCODE_URL, lgtm, TUIs) keep working
  # until M7. Setting OPENCODE_ROUTING_DB (in Environment below) activates the
  # dormant M4 serve-side session-lease path.
  systemd.services."opencode-serve@" = {
    description = "OpenCode headless serve (pool instance, port %i)";
    after = [ "network.target" "sops-nix.service" "aigateway.service" "pigeon-daemon.service" ];
    # DM5-2: a serve fails closed until pigeon has seeded the routing schema
    # (pigeon creates it when it inits the router). Order after pigeon and lean
    # on Restart=always so a too-early serve just retries until the schema is up.
    wants = [ "aigateway.service" "pigeon-daemon.service" ];
    # DM5-7: do NOT bounce the pool on routine home/system rebuilds (that would
    # kill all K serves and their live sessions). Restarts happen only via the
    # explicit opencode-serve-pool.target fan-out (M5.8 hooks / M6 cutover).
    restartIfChanged = false;
    # M5.8/M6 fan-out: a systemd target's Wants= does NOT propagate restart to
    # its units, so `systemctl restart opencode-serve-pool.target` alone is a
    # no-op on the serves. PartOf makes the target propagate stop/restart down
    # to every instance, so ONE target restart bounces all K serves (and a
    # target stop drains the pool). Start is still via the target's Wants=.
    partOf = [ "opencode-serve-pool.target" ];
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
        # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
        # sessionVariables for full rationale). Required by the K-serve pool —
        # every serve must share one DB. A system service doesn't source
        # ~/.profile, so the sessionVariables copy doesn't reach it.
        "OPENCODE_DB=/home/dev/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
        # mn9r M5/M4 activation: each serve participates in the per-session lease
        # CAS against pigeon's routing DB (the SAME file as the pigeon-daemon's
        # PIGEON_DAEMON_DB_PATH, DM5-1). Until this var was set the M4 serve-lease
        # code shipped in the binary stayed dormant.
        "OPENCODE_ROUTING_DB=${routingDbPath}"
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
        exec /home/dev/.nix-profile/bin/opencode serve --port "$PORT" --hostname 127.0.0.1
      ''} %i";
      # DM5-5: PER-INSTANCE memory cap. The old single serve was capped at
      # 40G/32G for the whole serve cgroup (~29 GiB observed working set across
      # 15+ attached sessions). Under K=4 the load spreads across 4 cgroups, so
      # cap each instance at 9G max / 7G high: aggregate 4x9=36G max, 4x7=28G
      # high stays under the old 40G ceiling with burst headroom on this 62 GiB
      # box, and OOMScoreAdjust=500 still sacrifices a serve first if the whole
      # system runs out.
      MemoryMax = "9G";
      MemoryHigh = "7G";
      OOMScoreAdjust = "500";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # mn9r M5: the serve-pool target. wantedBy multi-user so the pool boots; it
  # `wants` each templated instance (opencode-serve@<port>.service) so starting
  # the target pulls them all in, and ONE `systemctl restart
  # opencode-serve-pool.target` fans out to all K serves (the M5.8 restart-hook
  # and M6 cutover both bounce the pool through this target).
  systemd.targets.opencode-serve-pool = {
    description = "OpenCode serve pool (K warm serves on one opencode.db)";
    wantedBy = [ "multi-user.target" ];
    after = [ "pigeon-daemon.service" ];
    wants = map (p: "opencode-serve@${toString p}.service") servePool.ports;
  };

  # TeamClaude: personal Claude Max rotator that the claude-failover-proxy
  # router forwards to when work Claude-on-Vertex spend is over budget
  # (8fe.15 PREREQ). Runs the johnnymo87/teamclaude fork (opus-aware, zero-dep
  # Node) from the nix package (pkgs/teamclaude), not a ~/projects checkout.
  #
  # CONFIG IS RUNTIME STATE, NOT NIX-MANAGED. TeamClaude reads + REWRITES
  # /home/dev/.config/teamclaude.json (OAuth access/refresh tokens auto-refresh
  # and are written back), so the config must be writable + persistent — it is
  # NOT in the nix store and NOT a read-only sops mount. The OAuth accounts are
  # added out-of-band via the interactive `teamclaude login` flow (see
  # claude-failover-proxy docs/plans/2026-06-19-teamclaude-cloudbox-deploy.md);
  # this unit only RUNS the already-seeded config. With zero accounts the server
  # exits 1 ("No accounts configured") and Restart=always would crash-loop, so
  # accounts must exist before this unit is (re)started.
  #
  # PROACTIVE PROBE (opus-aware scoped limits): the per-model scoped weekly-limit
  # awareness only populates PROACTIVELY when the background quota probe is on
  # (the reactive 429/SSE backstop is always armed). It is runtime opt-in and
  # also NOT nix-managed (lives as quotaProbeSeconds in the same writable config).
  # After seeding, enable it to match devbox:
  #   TEAMCLAUDE_CONFIG=/home/dev/.config/teamclaude.json \
  #     teamclaude probe 90   # reads /api/oauth/usage every 90s; spends NO quota
  #
  # BIND + AUTH: index.js calls server.listen(port) with no host, so it binds
  # all interfaces (not 127.0.0.1 — the fork does not yet take a bind host).
  # Two backstops keep :3456 private: (1) cloudbox runs NO NixOS
  # firewall and relies on GCP's default-deny ingress (3456 is not opened), and
  # (2) TeamClaude's own auth gate (server.js) requires x-api-key === the config
  # proxy.apiKey for any NON-localhost client. The router connects via
  # 127.0.0.1 (localhost-exempt) but sends the key anyway.
  #
  # Auto-starts on boot (wantedBy multi-user.target) per the deploy decision.
  systemd.services.teamclaude = {
    description = "TeamClaude (personal Claude Max rotator for failover)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ config.system.path "/run/wrappers" "/home/dev/.nix-profile" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev";
      Environment = [
        "HOME=/home/dev"
        # Pin the config path explicitly so it never depends on XDG_CONFIG_HOME.
        # Matches the default getConfigPath() resolution for the dev user.
        "TEAMCLAUDE_CONFIG=/home/dev/.config/teamclaude.json"
      ];
      ExecStart = "${pkgs.writeShellScript "teamclaude-start" ''
        set -euo pipefail
        if [ ! -f /home/dev/.config/teamclaude.json ]; then
          echo "teamclaude config missing at ~/.config/teamclaude.json (seed + login first)" >&2
          exit 1
        fi
        exec ${teamclaude}/bin/teamclaude server --headless
      ''}";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # Aigateway: local Anthropic-on-Vertex proxy that captures per-request
  # attribution to a Postgres ledger. The path to the dev checkout is held
  # in the `aigateway_dir` sops secret; that dir holds the docker-compose.yml
  # plus the staged server.jar / migrate.jar (Postgres + Redis + Spring Boot
  # on :8080).
  #
  # LIFECYCLE-ONLY, NOT A FROM-SCRATCH BOOTSTRAP. The unit starts/stops the
  # already-deployed stack; it does NOT build code. Initial deploy and code
  # rollouts are the manual `bazel build` + `cp jars` + `docker compose up -d
  # --build` flow documented in the operating-aigateway skill. This unit used
  # to `exec ./start.sh -d` (bazel build then compose up), but start.sh is
  # only tracked on mono `origin/main`; when the working tree sits on any
  # other branch the script vanishes and the unit can't start — so we drive
  # `docker compose` directly instead (no monorepo-branch dependency).
  #
  # LEDGER IS EPHEMERAL: dev-postgres-1 has no named volume, so the
  # gateway_request_log lives only in the container's writable layer.
  # Therefore:
  #   - ExecStop is `docker compose stop` (NEVER `down` — down removes the
  #     container and destroys the ledger).
  #   - ExecStart is `up -d --no-recreate` so a restart/boot never recreates
  #     (and thus never wipes) the postgres container.
  #   - restartIfChanged = false so `nixos-rebuild switch` deploys a changed
  #     unit definition WITHOUT bouncing the live stateful stack; the new
  #     definition takes effect on the next reboot or manual restart.
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

    # Never let `nixos-rebuild switch` restart this unit on a config change:
    # a restart would (a) briefly drop gemini's global-default route and
    # (b) — with the historical ExecStop=down — destroy the ephemeral ledger.
    # The new definition applies on the next reboot or explicit
    # `systemctl restart aigateway`.
    restartIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      # No WorkingDirectory — handled by `cd` in the shim.
      # `docker compose up -d` returns once the stack is detached. The unit
      # then "succeeds" — but we need it to stay active so `is-enabled` /
      # `is-active` reflect operator intent. Type=oneshot + RemainAfterExit
      # handles that.
      RemainAfterExit = true;
      # `cd "$(cat ...)"` resolves the compose dir at every start; the cd
      # fails loudly if the secret/path is missing. `--no-recreate` makes
      # this idempotent and ledger-safe: it creates containers on first boot
      # but only STARTS existing (stopped) ones afterward, never recreating
      # the volume-less postgres. exec replaces bash so systemd tracks docker.
      ExecStart = "${pkgs.bash}/bin/bash -c 'cd \"$(cat /run/secrets/aigateway_dir)\" && exec ${pkgs.docker}/bin/docker compose up -d --no-recreate'";
      # `stop`, NOT `down`: down removes containers and the ephemeral ledger
      # dies with them. stop leaves the stopped containers intact for the
      # next `up -d --no-recreate` to restart in place.
      ExecStop = "${pkgs.bash}/bin/bash -c 'cd \"$(cat /run/secrets/aigateway_dir)\" && exec ${pkgs.docker}/bin/docker compose stop'";
      # Pulling base images on first boot can take a while.
      TimeoutStartSec = "10min";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };

  # claude-failover-proxy (cfp) — the budget-gated failover ROUTER that sits in
  # front of the work aigateway (under-budget -> Vertex) and TeamClaude
  # (over-budget -> personal Claude Max), session-sticky with idle migration
  # (8fe.14 / T13a). Listens on :8789. opencode's google-vertex-anthropic
  # baseURL is flipped to this in T13b; until then nothing points at it, so it
  # is safe to run. Like teamclaude it binds all interfaces; :8789 stays private
  # via GCP's default-deny ingress (no NixOS firewall on cloudbox) — it is NOT
  # in the GCP-opened port set. Startup is network-tolerant: index.ts binds the
  # port and logs the listening line before any upstream call (the TeamClaude
  # availability probe runs voided in a 60s interval), so the unit stays up even
  # if aigateway/teamclaude are momentarily down.
  #
  # Auto-starts on boot (wantedBy multi-user.target).
  systemd.services.claude-failover-proxy = {
    description = "claude-failover-proxy (budget-gated Vertex->Max failover router)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "teamclaude.service" ];
    wants = [ "teamclaude.service" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      # Creates/owns /var/lib/claude-failover-proxy for the spend ledger.
      StateDirectory = "claude-failover-proxy";
      Environment = [
        "CFP_LISTEN_PORT=8789"
        "CFP_AIGATEWAY_URL=http://127.0.0.1:8080"
        "CFP_TEAMCLAUDE_URL=http://127.0.0.1:3456"
        "CFP_BUDGET_DOLLARS=100"
        "CFP_IDLE_MIGRATE_SECONDS=300"
        "CFP_RESET_HOUR=0"
        # Budget rolls over at local midnight; ET matches the system tz and the
        # 3 AM ET nightly-reset convention. Set explicitly so it never falls
        # back to UTC under systemd.
        "CFP_TZ=America/New_York"
        "CFP_STATE_PATH=/var/lib/claude-failover-proxy/spend.json"
      ];
      # CFP_TEAMCLAUDE_API_KEY is a RAW value (not KEY=VALUE) so it can't go via
      # EnvironmentFile; export it from the sops secret in a shell shim (same
      # pattern as aigateway). set -e makes a missing/unreadable secret fail loud.
      ExecStart = "${pkgs.writeShellScript "claude-failover-proxy-start" ''
        set -euo pipefail
        export CFP_TEAMCLAUDE_API_KEY="$(${pkgs.coreutils}/bin/cat /run/secrets/teamclaude_api_key)"
        exec ${claude-failover-proxy}/bin/claude-failover-proxy
      ''}";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  # Nightly workspace reset (3 AM). Replaces the previous serve-only
  # restart with a full workspace reset (kill nvims, clear opencode
  # sessions, restart the opencode-serve-pool.target, respawn nvims). The
  # serve restart still happens — that was the original purpose (memory
  # hygiene, now across all K pooled serves) — but now it's bundled with
  # the rest of the reset.
  #
  # Runs as user `dev` so it can drive the user's tmux server.
  # Passwordless `sudo systemctl restart opencode-serve-pool.target` works
  # because `dev` is in the `wheel` group and `security.sudo.wheelNeedsPassword`
  # is false (set elsewhere in this file).
  systemd.services.nightly-restart-background = {
    description = "Nightly workspace reset (kill nvims, restart opencode-serve-pool, respawn)";
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
      ];
    };
    script = ''
      # Restart pigeon-daemon (system unit) FIRST so the recommendation
      # session spawned inside reset-workspace registers with a fresh daemon.
      # Symmetric with devbox (hosts/devbox/configuration.nix).
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

  # System identity
  networking.hostName = "cloudbox";
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

  # Feed a GitHub token into the nix-daemon's environment so fixed-output
  # derivations that fetch PRIVATE GitHub release assets can authenticate
  # (pkgs/claude-failover-proxy uses netrcImpureEnvVars = [ "GITHUB_TOKEN" ]).
  # impureEnvVars are read from the BUILDER's env = the nix-daemon process (NOT
  # the invoking shell), so the token must live in the daemon env. We REUSE the
  # existing github_api_token secret (verified: it reads the private cfp release
  # asset, HTTP 200) rather than minting a second PAT; a sops template wraps its
  # raw value in the KEY=VALUE form EnvironmentFile requires. The '-' prefix
  # makes the file optional so the daemon still starts if sops hasn't rendered it
  # yet (early boot); restartUnits bounces the daemon once it's (re)rendered.
  sops.templates."nix-daemon-github-token" = {
    content = "GITHUB_TOKEN=${config.sops.placeholder.github_api_token}";
    restartUnits = [ "nix-daemon.service" ];
  };
  systemd.services.nix-daemon.serviceConfig.EnvironmentFile =
    [ "-${config.sops.templates."nix-daemon-github-token".path}" ];

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
    xorg.xvfb  # Provides `Xvfb`; prebuilt Cypress spawns it for headless e2e
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
