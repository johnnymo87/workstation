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

  # teamclaude: the personal Claude Max rotator (upstream KarpelesLab/teamclaude,
  # tagged release). Same rationale as above — NixOS configs don't receive the
  # flake's localPkgs, so callPackage pkgs/teamclaude directly for the service.
  teamclaude = pkgs.callPackage ../../pkgs/teamclaude { };

  # opencode-frontdoor: the opaque single-port reverse proxy for the serve pool.
  # Same rationale as above — callPackage pkgs/opencode-frontdoor directly here.
  opencode-frontdoor = pkgs.callPackage ../../pkgs/opencode-frontdoor { };

  # Shared shell resolver for the opencode serve HTTP Basic credential
  # (workstation-km5f). Sourced by the serve canary and the frontdoor canary so
  # both probe the serves with the same credential the real clients use, and so
  # all callers obey one canonical resolution rule (env -> *_FILE ->
  # /run/secrets/opencode_server_password, trimmed, empty == auth off).
  opencode-serve-auth-sh = pkgs.callPackage ../../pkgs/opencode-serve-auth-sh { };

  # Store-path reduction for the serve-canary's staleness comparison. Extracted
  # 2026-08-01 (workstation-jj5x) so the comparison is unit-testable: the logic
  # was correct but untested, and an untested comparison is one refactor away
  # from the full-path form that reports STALE unconditionally.
  # See pkgs/opencode-store-prefix-sh/test.sh.
  opencode-store-prefix-sh = pkgs.callPackage ../../pkgs/opencode-store-prefix-sh { };

  # Windowing/rotation/partial-line/probe-table logic for the plugin-load canary
  # (E2, workstation-5yox). Extracted for the same reason as the library above:
  # byte-offset arithmetic over a shared 668MB log cannot be verified by looking
  # at a green timer. See pkgs/opencode-plugin-canary-sh/test.sh, wired into
  # `nix flake check`.
  opencode-plugin-canary-sh = pkgs.callPackage ../../pkgs/opencode-plugin-canary-sh { };

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

  # Shared alert helper for canaries (opencode-frontdoor-canary and serve pool canary).
  # Extracted to pkgs/opencode-drift-alert so devbox's frontdoor-canary uses the SAME
  # escalation logic instead of a fork -- devbox had detection without escalation and
  # repeated this host's 2026-07-24 incident on 2026-07-29/30. The full incident history
  # and the backoff/severity rationale now live in that package's header comment.
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
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
      # Anthropic enterprise (Developer Platform / api_team org) API key. The
      # claude-failover-proxy exports it as CFP_ENTERPRISE_API_KEY to enable the
      # opt-in enterprise failover tier (vertex -> enterprise -> max). Empty/unset
      # => tier disabled. Rotating means regenerating the key in the Anthropic
      # console and re-encrypting anthropic_enterprise_api_key in secrets/cloudbox.yaml.
      anthropic_enterprise_api_key = {
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
        # dx8p Stage 1: the pigeon bearer token. owner=dev is LOAD-BEARING, not
        # boilerplate -- sops-nix defaults to root:0400, but pigeon, the four
        # serves, and the front door all run as dev and read this file at CALL
        # TIME (see docs/plans/2026-07-26-dx8p-stage1-pigeon-token.md). If this
        # is root-only, every client silently falls back to sending no header
        # and 401s against an armed pigeon.
        pigeon_daemon_auth_token = {
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
      # lgtm multi-reviewer PATs (classic, repo + read:org, SSO-authorized),
      # one per reviewer GitHub login. Decrypted to /run/secrets and then
      # materialized to ~/.config/lgtm/tokens/<login>.pat (chmod 600, owner
      # dev) by home.activation.deployLgtmTokens, where the nix-managed
      # `lgtm-gh` wrapper reads them. The wrapper resolves the login from a
      # worktree's .lgtm-reviewer and execs `gh` with GH_TOKEN set so a review
      # posts under that identity. See lgtm:
      # docs/plans/2026-04-30-multi-reviewer-identity-design.md and the
      # workstation managing-secrets skill. Rotating a token: re-run
      # `sops set secrets/cloudbox.yaml '["lgtm_token_<login>"]' '"<pat>"'`
      # then a home-manager switch re-materializes the file.
      lgtm_token_johnnymo87 = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      lgtm_token_Krosantos = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      lgtm_token_jamesvec = {
        owner = "dev";
        group = "dev";
        mode = "0400";
      };
      # Atlassian API token (for nvim FetchJiraTicket/FetchConfluencePage)
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
      # Datadog Personal Access Token (Bearer auth for dd-cli / MCP).
      dd_pat = {
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

    # NO neovim here, deliberately -- see NVIM_BIN below.
    #
    # This list does not stay inside the daemon. oc-auto-attach spawns tmux
    # panes on pigeon's behalf, and tmux stamps the spawning process's PATH
    # into every pane it creates, so anything here becomes what the user's
    # editor pane resolves. A bare pkgs.neovim used to sit in this list (for
    # the daemon's own `nvim --server` RPC client) and consequently shadowed
    # the home-manager-wrapped nvim in that pane, failing at startup with
    # `module 'nvim-treesitter.configs' not found` -- the same landmine the
    # note on environment.systemPackages below already warned about, re-trodden
    # one layer down. Treat this list as user-visible, not unit-private.
    #
    # This is the systemd half of workstation-v8t5; the PATH half lives in
    # pkgs/oc-auto-attach/canonical-path.sh.
    path = [ pkgs.nodejs pkgs.bash pkgs.coreutils ];

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
        # frontdoor-exempt(C9): pigeon's data-plane fan-out; it must address every serve to route and reconcile them
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
        # Absolute path to a BARE neovim for the daemon's own `nvim --server`
        # RPC client (adapters/nvim-rpc.ts, honored since pigeon-d45j). Pinned
        # here rather than placed on `path` above precisely so it cannot leak
        # into the tmux panes oc-auto-attach creates and shadow the user's
        # plugin-wrapped nvim (workstation-v8t5).
        #
        # Bare is correct, not a compromise: `nvim --headless --server X
        # --remote-expr` does not source init.lua, so the RPC client never
        # needs the plugin set.
        "NVIM_BIN=${pkgs.neovim}/bin/nvim"
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
          # dx8p Stage 1: ARMS pigeon's auth. Until this line exists, checkAuth's
          # falsy-token branch keeps every route anonymous (back-compat). Once it
          # exists, EVERY route except GET /health requires a bearer.
          #
          # This is the ONLY line in the rollout that changes live behaviour. Every
          # client-side change (the door, opencode-launch, oc-*-attach, the drift
          # alert, the pigeon plugin, lgtm) already landed and is a no-op until now,
          # and each resolves the token at CALL TIME -- so no pool bounce and no
          # door restart are needed, which is what keeps ~20 live SSE legs intact.
          #
          # ROLLBACK: delete this line, `nixos-rebuild switch`, restart pigeon.
          # Anonymous service resumes immediately and every client's header
          # becomes a harmless no-op again.
          export PIGEON_DAEMON_AUTH_TOKEN="$(cat /run/secrets/pigeon_daemon_auth_token)"
        # front-door INFRA/CONTROL-PLANE EXEMPTION (Phase 7.8): pigeon is the
        # session-aware router the front door DEPENDS ON. Its own opencode
        # reads/fallbacks must hit the raw anchor (:4096), NOT the front door
        # (:4700) — routing the control plane through the data plane it feeds
        # is a circular dependency + a startup cycle. Do NOT repoint this to
        # FRONTDOOR_URL. Enforced by the test-pool-route-clients grep-guard.
        # frontdoor-exempt(C1): pigeon is the router the door DEPENDS on; door->pigeon->door is a startup cycle
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
      # NB: default KillMode=control-group is correct here. The old
      # KillMode=process was a run-mode artifact (lgtm-a3r removed run mode):
      # it kept systemd from SIGKILLing detached `opencode run` review children
      # when the oneshot ExecStart exited. Serve mode spawns no such children —
      # opencode-launch is pure HTTP to the serve pool and the sessions run in
      # opencode-serve-pool.target's own cgroup — so nothing needs to outlive
      # the cycle. (lgtm-j6k)
      User = "dev";
      Group = "dev";
      WorkingDirectory = "/home/dev/projects/lgtm";
      Environment = [
        "HOME=/home/dev"
        # front-door cutover (Phase 7.1, corrected per fable M2 #5): lgtm-run's
        # children (opencode-launch et al.) treat $OPENCODE_URL as the raw-anchor
        # DEGRADE FALLBACK for serve_url, so it MUST stay :4096 — setting it to
        # the door poisons that fallback (a pigeon hiccup would degrade to :4700,
        # where MCP-connect is denied and attach hints point at the door). The
        # children reach the door via their own FRONTDOOR_URL default; we export
        # FRONTDOOR_URL/OPENCODE_ANCHOR_URL here explicitly for clarity. The lgtm
        # daemon's own session reads hit the anchor directly (a shared-db read;
        # this unit is gated off via enableLgtm=false, and the out-of-repo daemon
        # is repointed in the Phase 9 consumer audit).
        # frontdoor-exempt(C2): children read this as their raw-anchor degrade fallback; the door would poison it
        "OPENCODE_URL=http://127.0.0.1:4096"
        "FRONTDOOR_URL=http://127.0.0.1:4700"
        # frontdoor-exempt(C3): the door's own upstream; it cannot proxy through itself
        "OPENCODE_ANCHOR_URL=http://127.0.0.1:4096"
        "LGTM_PROJECTS_DIR=/home/dev/projects"
        # NB: OPENCODE_DB / OPENCODE_DISABLE_CHANNEL_DB intentionally omitted
        # (lgtm-j6k). Those pinned the shared opencode.db for the run-era
        # detached `opencode run` children this service used to spawn. lgtm-a3r
        # removed run mode: the daemon (tsx src/index.ts) only reads sessions
        # over HTTP via OPENCODE_URL and opencode-launch is pure curl/jq — no
        # local opencode process inherits this env. The serve pool owns the DB
        # pin (see opencode-serve-pool env).
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
  # opencode-serve-pool.target fans out to all K serves. serve-0 binds 4096, the
  # permanent anchor: clients create new sessions on it and fall back to it, while
  # M7 routes session-targeted traffic to the owning serve via pigeon /route
  # (opencode-launch/-send, reset-workspace, opencode-llm-audit, my-podcasts, the
  # telegram launch path). The hand-typed `opencode attach` TUI still resolves
  # :4096 directly (tracked in 7zr7); lgtm run-mode is disabled. Setting
  # OPENCODE_ROUTING_DB (in Environment below) activates the dormant M4 serve-side
  # session-lease path.
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
    # so nix-managed binaries always win on name collisions.
    #
    # `~/.local/bin` is KEPT (not the temporary lgtm-gh stub workaround it was
    # originally added for in aafe051 — lgtm-gh now ships nix-managed to
    # ~/.nix-profile/bin, already on this PATH via the /home/dev/.nix-profile
    # entry). It stays because several user-bin tools are deployed there *only*
     # (via home.file, never into the nix profile) and headless sessions running
     # inside this serve legitimately invoke them — notably `oc-search`,
     # `lgtm-sessions`, and `ba`. (Swarm messaging no longer uses CLIs: it goes
     # through the swarm_send/swarm_read/swarm_list plugin tools.) Removing it
     # would silently ENOENT those from dispatched/launched
    # sessions; keeping it just mirrors the interactive-shell PATH and is
    # collision-safe (appended last). See workstation-4hm for the rationale.
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
        # Anthropic's recommendation for high-effort Opus runs. Mirrors
        # the home.sessionVariables entry in users/dev/home.base.nix — that one
        # only covers interactive shells, opencode-serve needs it set
        # explicitly. See full rationale there.
        "OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=65536"
        # Tell auth plugins there is no local browser. opencode-gemini-auth
        # (installed, v1.3.11) picks its OAuth flow from
        #   !!(SSH_CONNECTION || SSH_CLIENT || SSH_TTY || OPENCODE_HEADLESS)
        # in src/plugin/oauth-authorize.ts:64-69. A systemd unit inherits none
        # of the SSH_* vars, so without this the serve believes it is on a
        # desktop, takes the `method: "auto"` branch, and binds
        # http://localhost:8085/oauth2callback (src/constants.ts:23,
        # src/plugin/server.ts:220) for a redirect that would have to resolve in
        # the USER'S laptop browser — not on cloudbox. It can never complete: it
        # blocks for 5 minutes and fails. With this set, the plugin binds nothing
        # and returns the paste-back `method: "code"` flow, which works remotely.
        #
        # Blast radius is exactly this one plugin: `git grep OPENCODE_HEADLESS`
        # in opencode v1.17.13 core returns zero hits, and no other plugin in the
        # cache reads it. Found during the D4 route audit (workstation-mlve.11);
        # unrelated to the front door, which cannot fix it.
        #
        # NOT live until each serve restarts — restartIfChanged = false above
        # means `nixos-rebuild switch` deploys this WITHOUT bouncing the pool
        # (deliberate: a bounce would kill every live session). The nightly reset
        # picks it up. Do not verify same-day and conclude it failed.
        "OPENCODE_HEADLESS=1"
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
        # REGISTRY PORT FENCE (bead pigeon-13p). Declares which TCP port this slot
        # is supposed to hold. The serve compares it against the port it ACTUALLY
        # bound and refuses to register (exit 20) if they disagree.
        #
        # The value is just "$PORT", but the fence is NOT vacuous: its power comes
        # from being EXPORTED, so it is inherited by every child process. A throwaway
        # `opencode serve` spawned from inside a session hosted by this serve carries
        # this slot's declared port while binding its own random one -- which is
        # exactly the 2026-07-25 hijack signature (slot repointed at :47037, and
        # again at :44407 by a test harness). Comparing against this process's own
        # --port instead would catch nothing, because the throwaway binds the port
        # it asked for.
        #
        # Unset = fence unarmed (serve logs a warning and registers as before), so
        # the opencode-patched release and this rebuild can land in either order.
        export OPENCODE_SERVE_EXPECTED_PORT="$PORT"
        # REGISTRY PID FENCE (bead workstation-4b1q). The port fence above is
        # port-ONLY: it has no interface check, so a nested
        # `opencode serve --hostname ::1 --port $PORT` binds alongside the real
        # serve on 127.0.0.1:$PORT, passes the port fence, and claims the slot.
        # $$ closes that (and the socket/host variants) at once: a child inherits
        # this VARIABLE but can never inherit this PID.
        #
        # LOAD-BEARING: `exec` below. It makes the serve REPLACE this shell, so
        # the serve's own pid IS $$. Drop the `exec` and the serve becomes a
        # child with a different pid and refuses to register (exit 21). That is
        # not a comment you may trust -- users/dev/test-serve-pid-fence.sh
        # asserts it at build time via `nix flake check`.
        #
        # Unset = fence unarmed (serve logs a warning and behaves as before), so
        # the opencode-patched release and this rebuild can land in either order.
        export OPENCODE_SERVE_EXPECTED_PID=$$
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
        # systemd services don't source ~/.bashrc. Personal Access Token
        # (DD_PAT, Bearer auth).
        export DD_SITE="us3.datadoghq.com"
        if [ -r /run/secrets/dd_pat ]; then
          export DD_PAT="$(cat /run/secrets/dd_pat)"
        fi
        exec /home/dev/.nix-profile/bin/opencode serve --port "$PORT" --hostname 127.0.0.1
      ''} %i";
      # h1y6 step 2: MAX-ONLY, no MemoryHigh. Deliberately NOT the old
      # 9G-max/7G-high band. `memory.high` does not kill -- it throttles, by
      # putting every allocating thread to sleep in mem_cgroup_handle_over_high
      # for as long as the cgroup stays over the line. Measured on this host
      # 2026-08-02: serve 4099 sat pinned at EXACTLY 7.00G for 13 minutes,
      # pushing 22.4 GiB into zram, 8.1 minutes of it with PSI `full` (every
      # task stopped) -- and the liveness canary passed every single minute
      # while the front door served 4% 503s off that member. `memory.events`
      # across the pool: high=1064918, max=0, oom=0. In other words the band
      # fires constantly and the cap has never once been reached. That is the
      # wedge; a fast kill + 10s restart is strictly better than a silent
      # 13-minute stall that our own detector cannot see.
      #
      # 14G, not 9G, because 9G would kill far more than the pathology. Of the
      # four cap-crossings in a 20.6h sample, three peaked at 9.5-10.8G and
      # were completely clean at the door (zero 5xx, p95 in the tens of ms);
      # only 4099's 28.5G runaway caused user-visible harm. 14G sits above the
      # highest observed benign peak (12.47G) and far below the runaway, so it
      # kills the pathology and leaves the routine bursts alone. The cost
      # asymmetry drives this: a wrong kill orphans ~45 sessions until the
      # 03:00 sweeper (workstation-63wo is still open), while a wrong non-kill
      # costs about a minute of latency before the cap catches it anyway.
      #
      # MemorySwapMax=1G is what makes the cap mean anything. Unbounded, the
      # cgroup relieves cap pressure into 31.3G of zram instead of dying, and
      # the stall simply relocates. It is 1G rather than 0 so that (a) global
      # reclaim can still page out genuinely cold pages -- with 0, a serve
      # could be OOM-killed while the box has free RAM -- and (b) a small
      # overshoot of the cap is absorbed rather than instantly fatal. 1G is far
      # too little to sustain a 22G runaway.
      #
      # NOTE: bash tools spawned by sessions live in the serve's cgroup, so the
      # OOM killer may pick a fat child (a build, an nvim) rather than the serve
      # itself. OOMPolicy=stop stops the whole unit on any kill in its cgroup,
      # and Restart=always brings it back, so the outcome is the same either
      # way -- but it does mean one session's runaway subprocess can restart the
      # serve for everyone on that member.
      MemoryMax = "14G";
      MemorySwapMax = "1G";
      OOMScoreAdjust = "500";
      Restart = "always";
      RestartSec = 10;
      # A wedged serve's SIGTERM handler is a JS-level `process.once` that a
      # frozen event loop provably never runs (workstation-94g8), so the
      # default 90s stop timeout is 90s of dead waiting on every stop of a
      # wedged serve -- including inside the nightly reset. A healthy serve
      # exits in well under a second, so this only ever shortens the SIGKILL
      # wait. Matches devbox.
      TimeoutStopSec = 15;
      # Aggregate cap (workstation-le0a). The four per-serve MemoryMax values sum
      # to more than the host has, so this slice is what stops the pool as a
      # WHOLE from taking the machine down while each member individually looks
      # well-behaved.
      #
      # THIS LINE IS DEPLOY-ORDER SENSITIVE AND HAS ALREADY CAUSED THE EXACT
      # FAILURE IT EXISTS TO PREVENT. Read before touching it.
      #
      # The units carry restartIfChanged = false (above) so routine rebuilds do
      # not kill live sessions. That makes deploying this a TWO-step operation,
      # and the gap between the steps is the hazard: on 2026-08-02 a plain
      # `nixos-rebuild switch` re-realized the units as members of the new slice
      # while the PROCESSES stayed in the old one, which dropped `memory` from
      # the old slice's cgroup.subtree_control. The per-serve
      # memory.max/high/swap.max files then ceased to exist and all four serves
      # ran with NO memory limit at all -- while `systemctl show` reported the
      # new values perfectly, so every instrument said it had worked. Reverted in
      # PR #264.
      #
      # So this may only ship in a deploy that bounces the pool IN THE SAME STEP:
      #     nixos-rebuild switch ... && systemctl restart opencode-serve-pool.target
      # (the target's PartOf, set above, is what propagates the restart to every
      # instance -- a target restart without it is a no-op on the serves).
      #
      # AFTERWARDS, VERIFY ON CGROUPFS, NEVER `systemctl show`: the failure mode
      # is a MISSING FILE, and systemctl show cannot see a missing file -- it
      # will happily print the configured value for a limit that is not being
      # enforced. Check that
      #   /sys/fs/cgroup/system.slice/opencode-serve.slice/opencode-serve@<port>.service/memory.max
      # exists and holds the expected value for all four ports, and that `memory`
      # appears in the slice's cgroup.subtree_control.
      Slice = "opencode-serve.slice";
    };
  };

  # h1y6 step 2: aggregate backstop for the serve pool. ATTACHED as of
  # workstation-le0a -- the serve units now carry `Slice = "opencode-serve.slice"`
  # (see the deploy-order warning on the unit above, which still applies to any
  # future change of that line).
  #
  # Per-instance MemoryMax is 14G and there are four of them, so an unbounded
  # parent would permit 56G on a 62 GiB box. This caps the whole pool at 32G
  # (~half the box), comfortably above the observed concurrent pool maximum of
  # 15.5G, and only engages if two members run away at once -- a single runaway
  # is already bounded at 14G by its own cap and cannot reach 32G alone.
  systemd.slices.opencode-serve = {
    description = "OpenCode serve pool (aggregate memory backstop)";
    sliceConfig = {
      MemoryMax = "32G";
      MemorySwapMax = "4G";
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

  # Ported from devbox (users/dev/home.devbox.nix) to cloudbox as SYSTEM units.
  # This timer probes each pool member's /global/health (3s timeout) once a
  # minute; after 7 consecutive failures it dumps cheap root-readable forensics
  # (/proc status/wchan/syscall + cgroup memory.*) to /var/lib/opencode-serve-canary/
  # and restarts that one instance. Runs as root (system service), so no privilege elevation helper is needed.
  # Design notes in .opencode/skills/monitoring-serve-pool/SKILL.md;
  # full post-mortem in docs/investigations/2026-07-03-serve-4096-wedge.md.
  systemd.services.opencode-serve-canary = {
    description = "OpenCode serve pool liveness canary (restart wedged serves)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "opencode-serve-canary";
      ExecStart = "${pkgs.writeShellScript "opencode-serve-canary" ''
        set -u
        # System-service PATH is minimal — be explicit.
        # gawk: awk is NOT in coreutils (first live wedge lost utime/stime silently).
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.util-linux pkgs.curl pkgs.elfutils pkgs.gawk pkgs.findutils ]}

        # Serve HTTP Basic credentials (workstation-km5f). Runs as root, so the
        # sops secret is readable. The resolver reads env then the secret file at
        # CALL time, so a rotated password is picked up without restarting this
        # unit. It deliberately uses bash builtins only -- note the PATH above has
        # no gnused, and a sed-based trim would silently yield an empty password
        # here (see pkgs/opencode-serve-auth-sh/test.sh case 6).
        source "${opencode-serve-auth-sh}"
        serve_auth_load

        # Store-path reduction + reference shape gate for the staleness
        # comparison below. Pure bash, so the minimal PATH above is irrelevant.
        source "${opencode-store-prefix-sh}"

        STATE=/var/lib/opencode-serve-canary
        # Note: /var/lib/opencode-serve-canary is root-owned via StateDirectory
        # (eliminating any /tmp symlink/TOCTOU hazard) and persists across reboots.
        # It's world-readable for human inspection via root umask 022; dev can
        # read forensics but not delete them.
        # workstation-g3iy: 7 (was 2) — the post-boot catalog/credential burn
        # runs ~5-6 min and COMPLETES, leaving a warm stable instance. A
        # threshold-2 (~2-3 min) restart kills the instance mid-burn, the TUI
        # reconnects, re-creates the instance, and re-triggers the burn =
        # restart<->burn thrash loop. 7 (~7-8 min) outlasts one clean burn
        # while still catching permanent wedges.
        # F8b (Phase 7): re-justified for cloudbox. The burn is a property of the
        # opencode binary (catalog/credential load), not the host, so the g3iy
        # rationale carries over from devbox; 7 (~7-8 min) keeps ample margin on
        # cloudbox's aarch64/GCP too. Left at 7.
        THRESHOLD=7

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

        # Compute installed/reference store path prefix ONCE per canary run from
        # the user's profile symlink.
        #
        # WHY profile symlink rather than ExecStart:
        # ExecStart points to opencode-serve-start, a wrapper shell script whose nix hash
        # is independent of the opencode package. The wrapper's final line is:
        # `exec /home/dev/.nix-profile/bin/opencode serve ...`
        # So /home/dev/.nix-profile/bin/opencode is the true reference for what binary
        # would run if the serve instance were restarted right now.
        # INCIDENT 2026-07-25 (bead workstation-bcmi): a non-empty check is NOT enough.
        # `readlink -f` resolves PARENT directories and returns the path even when the
        # FINAL COMPONENT DOES NOT EXIST. During a home-manager switch there is a window
        # where ~/.nix-profile/bin/opencode is missing, so REF_EXE came back as
        # `/nix/store/<hash>-profile/bin/opencode` — non-empty, but pointing at the
        # PROFILE instead of through to the opencode package. Prefix reduction then
        # yielded `…-profile` as REF_PREFIX, which cannot equal any serve's real prefix,
        # so ALL FOUR serves were reported as drifted and escalated to "dangerous …
        # pending alert". The serves were correct; the canary was wrong.
        #
        # Only the 2-consecutive-pass dampening stopped that becoming a false Telegram
        # page. That is a thin margin: a switch straddling two passes would page with a
        # bogus pool-wide "dangerous drift", and the documented consequence is worse than
        # a missed alert — it teaches the operator to ignore the channel, after which the
        # throttle SUPPRESSES the alert when drift turns genuinely dangerous.
        #
        # So classify anything that is not a *verified* opencode package path as UNKNOWN
        # (REF_PREFIX=""), which the logic below already handles correctly: never alert,
        # never clear throttle state. "Unknown" was previously modelled as "empty"; this
        # failure mode is unknown-but-not-empty.
        # Structural sanity lives in opencode_reference_prefix: the reference MUST be a
        # verified opencode package, not a profile, a wrapper, or anything else a future
        # refactor might resolve to. Anything else yields "" (UNKNOWN) plus a NOTICE on
        # stderr. That gate is load-bearing, not decorative -- see workstation-bcmi above
        # -- and is locked by pkgs/opencode-store-prefix-sh/test.sh.
        REF_EXE=$(readlink -f /home/dev/.nix-profile/bin/opencode 2>/dev/null || true)
        REF_PREFIX=$(opencode_reference_prefix "$REF_EXE")

        # Track drifting ports across the pool to issue ONE aggregated alert per canary pass.
        #
        # WHY pool-level aggregation over per-port alerting:
        # On 2026-07-24, a home-manager switch updated the opencode package system-wide.
        # All K serves became stale simultaneously. Per-port alerting would emit K alerts
        # for a single logical event (4-message alert storm).
        DOOR_ACTIVE=$(systemctl is-active opencode-frontdoor.service 2>/dev/null || echo "inactive")
        DOOR_START_MONOTONIC=$(systemctl show opencode-frontdoor.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo "0")

        DRIFT_PORTS=""
        DRIFT_DETAILS=""
        VERIFIED_COUNT=0
        HAS_SKEW_DRIFT=0
        NOW=$(date +%s)

        # Credential/status drift accumulators (workstation-km5f), aggregated
        # across the pool so one bad password sends ONE alert, not one per port
        # — same rationale as DRIFT_PORTS above (a pool-wide cause produces a
        # pool-wide symptom; per-port alerting turns it into an alert storm).
        # Initialised here because `set -u` is on and they are read after the loop.
        AUTH_DRIFT_PORTS=""
        ODD_STATUS_PORTS=""
        # Count of serves that actually answered something this pass. Used to
        # distinguish "no credential problem" from "we learned nothing" (whole
        # pool stopped, all timing out) before clearing alert state — the same
        # distinction the binary-drift block below draws with VERIFIED_COUNT,
        # for the same reason: clearing throttle state on an uninformative pass
        # re-arms the alert and produces duplicate notifications.
        PROBED_COUNT=0

        for PORT in ${lib.concatMapStringsSep " " toString servePool.ports}; do
          UNIT="opencode-serve@$PORT.service"
          FAILFILE="$STATE/$PORT.fails"

          # Only police units that are supposed to be up. Intentional stops,
          # crash-loop backoff, etc. reset the counter.
          if [ "$(systemctl is-active "$UNIT")" != "active" ]; then
            rm -f "$FAILFILE"
            continue
          fi

          # Liveness is graded by STATUS, not by curl's exit code, and liveness
          # means "the event loop answered", NOT "the credential was right".
          #
          # WHY (workstation-km5f): once serves require HTTP Basic, a bare
          # `curl -sf` treats 401 as failure. With THRESHOLD consecutive failures
          # triggering `systemctl restart`, a missing or stale password would
          # restart all ${toString (builtins.length servePool.ports)} serves every
          # ~$((THRESHOLD + 1)) minutes, forever, while doing nothing to fix the
          # actual problem. A restart storm is a far worse outcome than a missed
          # wedge, so anything that proves the HTTP server is answering counts as
          # alive. Credentials are still sent (so 200 remains the normal case);
          # 401 is reported loudly instead of acted on destructively.
          #
          # This does NOT weaken wedge detection. The wedge mode this canary
          # exists for presents as NO response, not a fast 401: auth runs inside
          # the same single-threaded event loop, and the 2026-07-03 wedge failed
          # to answer /global/health within the 3s probe at all
          # (docs/investigations/2026-07-03-serve-4096-wedge.md:43). A timeout or
          # refused connection still reads as dead below.
          #
          # Mirrors the status-grading idiom the frontdoor canary in this same
          # file already uses (search: 'unexpected status'), including its
          # "unknown status -> loop alive, do not restart" bias.
          HEALTH_CODE=$(curl -s --max-time 3 --connect-timeout 3 \
                             -o /dev/null -w "%{http_code}" \
                             ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
                             "http://127.0.0.1:$PORT/global/health" 2>/dev/null)

          # NOTE: no `|| echo 000` here. curl writes %{http_code} (as "000") even
          # when it fails, so an `|| echo` fallback would concatenate and yield
          # "000000". Non-numeric/empty is handled explicitly below instead.
          SERVE_ALIVE=1
          case "$HEALTH_CODE" in
            200)
              ;;
            401)
              # Answering => alive. But the credential is wrong/missing, which
              # after this change nothing else on the box would notice.
              AUTH_DRIFT_PORTS="''${AUTH_DRIFT_PORTS:+$AUTH_DRIFT_PORTS }$PORT"
              echo "WARNING: $UNIT returned 401 on /global/health: serve is alive but the canary's credential was rejected (not restarting)"
              ;;
            ""|000)
              # No HTTP response at all: refused, timed out, or wedged.
              SERVE_ALIVE=0
              ;;
            *)
              ODD_STATUS_PORTS="''${ODD_STATUS_PORTS:+$ODD_STATUS_PORTS }$PORT:$HEALTH_CODE"
              echo "WARNING: $UNIT returned unexpected status $HEALTH_CODE on /global/health: serve is alive (not restarting)"
              ;;
          esac

          if [ "$SERVE_ALIVE" -eq 1 ]; then
            rm -f "$FAILFILE"
            PROBED_COUNT=$((PROBED_COUNT + 1))

            # Stale-binary drift detection for LIVE serves (2026-07-24 incident recovery).
            #
            # Deliberately keyed on SERVE_ALIVE, not on HTTP 200: drift is read
            # from /proc/<pid>/exe, never from the health payload, so a 401 (or
            # any other answered status) carries exactly the same evidence. If
            # this were left inside a 200-only branch, arming auth with a stale
            # credential would silently disable stale-binary detection -- the
            # precise regression the 2026-07-24 incident block below exists to
            # catch.
            #
            # Store-path comparison invariant:
            # /global/health's self-reported "version" field returns upstream semver ("1.17.13"),
            # which remains identical across patched revision builds (patched.1/.2/.3).
            # Comparing store path prefixes (first 4 slash-separated fields) detects patch drift.
            #
            # INVARIANT: This check works because `bin/opencode` execs `bin/.opencode-wrapped` inside
            # the EXACT SAME store path prefix (/nix/store/<hash>-opencode-patched-...).
            # If opencode-patched packaging ever changes to exec a wrapper or binary residing in a
            # DIFFERENT store path (e.g. `exec ''${bun}/bin/bun ...`), readlink /proc/<pid>/exe will
            # resolve to that external store path, causing false-positive drift detection on EVERY serve pass!
            # Next packager: preserve the same store path for the exec target or update this comparison.
            #
            # WHY unknown != drift:
            # If REF_PREFIX is empty (profile symlink briefly missing during home-manager switch)
            # or MainPID /proc/<pid>/exe is missing/unreadable (process died/restarting),
            # opencode_drift_verdict returns UNKNOWN and we skip the check. False-positive
            # alerts during transient state train users to ignore alerts.
            #
            # The `[ -n "$REF_PREFIX" ]` test below is an optimisation (it avoids a
            # `systemctl show` per port), NOT the safety gate: opencode_drift_verdict
            # re-checks it. Deleting this `if` may waste a syscall; it cannot resurrect
            # the workstation-bcmi false-drift storm.
            if [ -n "$REF_PREFIX" ]; then
              PID=$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null || true)
              if [ -n "$PID" ] && [ "$PID" != "0" ]; then
                RUN_EXE=$(readlink "/proc/$PID/exe" 2>/dev/null || true)
                if [ -n "$RUN_EXE" ]; then
                  # The verdict MUST come from a store-path PREFIX comparison, never from
                  # $RUN_EXE vs $REF_EXE: bin/opencode execs bin/.opencode-wrapped, so the
                  # raw paths differ even when the serve is fresh, and full-path equality
                  # would report STALE on every pass, forever. RUN_PREFIX is derived only
                  # for the alert text. Locked by pkgs/opencode-store-prefix-sh/test.sh.
                  RUN_PREFIX=$(opencode_store_prefix "$RUN_EXE")
                  DRIFT_VERDICT=$(opencode_drift_verdict "$REF_PREFIX" "$RUN_EXE")
                  if [ "$DRIFT_VERDICT" != "UNKNOWN" ]; then
                    VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
                    if [ "$DRIFT_VERDICT" = "STALE" ]; then
                      echo "WARNING: $UNIT binary drift: running=$RUN_PREFIX installed=$REF_PREFIX"
                      DRIFT_PORTS="''${DRIFT_PORTS:+$DRIFT_PORTS }$PORT"
                      DRIFT_DETAILS="''${DRIFT_DETAILS}  - port $PORT: $RUN_PREFIX
"
                      SERVE_START_MONOTONIC=$(systemctl show "$UNIT" -p ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
                      if [ "$DOOR_ACTIVE" = "active" ] && [ -n "$DOOR_START_MONOTONIC" ] && [ "$DOOR_START_MONOTONIC" -gt 0 ] 2>/dev/null && [ -n "$SERVE_START_MONOTONIC" ] && [ "$SERVE_START_MONOTONIC" -gt 0 ] 2>/dev/null; then
                        if [ "$SERVE_START_MONOTONIC" -lt "$DOOR_START_MONOTONIC" ]; then
                          HAS_SKEW_DRIFT=1
                        fi
                      fi
                    fi
                  fi
                fi
              fi
            fi

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

          # Bound persistent forensics: keep only the 10 newest wedge dumps.
          # lbe2: this needs `xargs`, which is why findutils is on the PATH above
          # -- it was absent, so the whole prune was a silent no-op, and the
          # `|| true` that used to be here hid it. Report failure instead of
          # swallowing it; `set -e` is not on, so a warning cannot abort the
          # forensics capture below.
          if ! ls -dt "$STATE"/wedge-* 2>/dev/null | tail -n +11 | xargs -r rm -rf; then
            echo "canary: WARNING forensics retention prune failed (dumps accumulate)" >&2
          fi

          PID=$(systemctl show "$UNIT" -p MainPID --value)
          CG=$(systemctl show "$UNIT" -p ControlGroup --value)
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            for f in status wchan syscall; do
              cat "/proc/$PID/$f" > "$DUMP/$f" 2>/dev/null || true
            done
            # Per-thread kernel wait channels.
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
          #  - 3x native thread stacks via eu-stack (as root, no extra privilege needed).
          #    The bun binary is non-PIE ET_EXEC so raw addresses are STABLE across
          #    runs/wedges: identical frames across samples = tight-loop
          #    fingerprint even without symbols.
          #    F8c (Phase 7) VERIFIED on cloudbox: `readelf -h $(readlink -f $(command -v bun))`
          #    reports `Type: EXEC` on AArch64 (not just x86 devbox) — the stable-address
          #    assumption holds here too.
          # All best-effort; a truly frozen loop can't get worse from a brief
          # ptrace stop, and the restart follows immediately anyway.
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            {
              wchan_t0=$(date +%s.%N)
              awk '{print "utime="$14, "stime="$15}' "/proc/$PID/stat" 2>/dev/null
              cat "/proc/$PID/io" 2>/dev/null
              # Main-thread wait-channel TIME SERIES, sampled across the same 2s
              # window this sleep already spent (so it costs nothing).
              #
              # A single /proc/PID/wchan snapshot is captured above, but a
              # snapshot cannot discriminate: sampling a healthy serve by hand
              # returns "0" (running) or "do_epoll_wait" depending on when you
              # look. What discriminates is whether the loop EVER returns to
              # epoll across the window:
              #   do_epoll_wait ....... event loop free; an HTTP stall here is
              #                         request serialization, NOT a blocked loop
              #   hrtimer_nanosleep ... solid, never returning to epoll = the
              #                         SQLite busy handler spinning
              #
              # Why that second case matters: bun:sqlite's busy-wait runs on the
              # serve's MAIN JS THREAD, so busy_timeout=5000 means a contended
              # write freezes the event loop for up to 5s. That is not merely
              # similar to the "alive but frozen" wedge signature -- it is a
              # mechanism that produces it exactly. Measured by a peer session
              # (W2a): hrtimer_nanosleep continuously from 0.2s to 3.4s of a 4s
              # contended write, never once back to epoll.
              #
              # /proc/<tid>/syscall would be richer, but yama ptrace_scope=1 is
              # set on this host, so it is unreadable; wchan is not. Plain shell
              # counter rather than `seq` -- coreutils is on the PATH above, but
              # lbe2 was a silent no-op from exactly one assumed-present binary.
              wchan_i=0
              while [ "$wchan_i" -lt 20 ]; do
                printf '%s\n' "$(cat "/proc/$PID/wchan" 2>/dev/null)" \
                  >> "$DUMP/wchan-series" 2>/dev/null || true
                wchan_i=$((wchan_i + 1))
                sleep 0.1
              done
              awk '{print "utime="$14, "stime="$15}' "/proc/$PID/stat" 2>/dev/null
              cat "/proc/$PID/io" 2>/dev/null
              # Report the interval MEASURED, not the 2s it used to assert: the
              # sampling loop above costs a little more than its sleeps, and the
              # utime/stime delta is divided by this number.
              echo "clk_tck=100 interval=$(awk -v a="$wchan_t0" -v b="$(date +%s.%N)" \
                'BEGIN{printf "%.2f", b-a}')s"
            } > "$DUMP/cpu-io-split" 2>/dev/null || true
            for i in 1 2 3; do
              timeout 10 ${pkgs.elfutils}/bin/eu-stack -p "$PID" > "$DUMP/eu-stack.$i" 2>&1 || true
              sleep 1
            done
          fi
          echo "RESTARTING wedged $UNIT (pid=$PID); forensics in $DUMP"
          systemctl restart "$UNIT"
          rm -f "$FAILFILE"
        done

        # Credential drift (workstation-km5f). Deliberately alert-only: a 401 is
        # never a reason to restart a serve (restarting cannot fix a password),
        # and treating it as one is exactly the storm this design avoids.
        #
        # This alert is load-bearing. Once 401 counts as alive, NOTHING else on
        # this box notices a wrong or missing serve password: the serves
        # themselves never log 401s (disableLogger on both transports; the
        # rejection is a silent Effect.succeed), so without this the failure is
        # completely invisible until a human notices clients misbehaving.
        if [ -n "$AUTH_DRIFT_PORTS" ]; then
          AUTH_TEXT=$(cat <<EOF
OpenCode serve rejected the canary's credential (HTTP 401) on port(s): $AUTH_DRIFT_PORTS

The serves are ALIVE and have NOT been restarted — restarting cannot fix a
credential mismatch. But every client using the same credential is being
rejected too, and serves do not log 401s, so this alert is the only signal.

Likely causes:
  - /run/secrets/opencode_server_password missing, unreadable, or empty
  - the secret was rotated but a consumer unit was not restarted
  - OPENCODE_SERVER_PASSWORD armed on the serves but not where clients read it

Check:
  systemctl show opencode-serve@PORT.service -p Environment | tr ' ' '\n' | grep -c OPENCODE_SERVER_PASSWORD
  curl -s -o /dev/null -w '%{http_code}\n' -u "opencode:\$(cat /run/secrets/opencode_server_password)" http://127.0.0.1:PORT/global/health
EOF
)
          ${driftAlert} "$STATE/auth-drift-alerted" "$AUTH_DRIFT_PORTS" "$AUTH_TEXT" 900 14400
        elif [ "$PROBED_COUNT" -gt 0 ]; then
          # At least one serve answered and none rejected us: genuinely resolved.
          rm -f "$STATE/auth-drift-alerted"
        fi

        if [ -n "$ODD_STATUS_PORTS" ]; then
          echo "WARNING: unexpected /global/health status(es) from serve pool: $ODD_STATUS_PORTS (treated as alive; no restart)"
        fi

        if [ -n "$DRIFT_PORTS" ]; then
          if [ -f "$STATE/drift-first-seen" ]; then
            FIRST_SEEN=$(cat "$STATE/drift-first-seen" 2>/dev/null || echo "$NOW")
          else
            FIRST_SEEN="$NOW"
            echo "$FIRST_SEEN" > "$STATE/drift-first-seen"
          fi
          EPISODE_AGE=$((NOW - FIRST_SEEN))

          IS_DANGEROUS=0
          DANGER_REASONS=""
          if [ "$HAS_SKEW_DRIFT" -eq 1 ]; then
            IS_DANGEROUS=1
            DANGER_REASONS="''${DANGER_REASONS}  - Skew shape: drifting serve(s) started before current front door (door restarted after serve) — risk of frozen TUIs / 404s
"
          fi
          if [ "$EPISODE_AGE" -ge 86400 ]; then
            IS_DANGEROUS=1
            AGE_HOURS=$((EPISODE_AGE / 3600))
            DANGER_REASONS="''${DANGER_REASONS}  - Stale across reset: drift persisted ''${AGE_HOURS}h (>24h) — survived nightly 03:00 reset
"
          fi

          if [ "$IS_DANGEROUS" -eq 1 ]; then
            DRIFT_PENDING=$(( $(cat "$STATE/drift-pending" 2>/dev/null || echo 0) + 1 ))
            echo "$DRIFT_PENDING" > "$STATE/drift-pending"

            if [ "$DRIFT_PENDING" -ge 2 ]; then
              DRIFT_TEXT=$(cat <<EOF
OpenCode serve pool is running stale code on port(s): $DRIFT_PORTS

DANGEROUS CONDITION DETECTED:
$DANGER_REASONS
To fix, run:
sudo systemctl restart opencode-serve-pool.target

Running store path(s):
$DRIFT_DETAILS
Installed store path:
$REF_PREFIX

Note: Restarting the serve pool terminates live OpenCode sessions. Pick an appropriate moment to restart.
EOF
)
              # Backoff base 15m, cap 4h (was a flat 86400, which sent one page per episode).
              ${driftAlert} "$STATE/drift-alerted" "$REF_PREFIX|$DOOR_START_MONOTONIC" "$DRIFT_TEXT" 900 14400
            else
              echo "WARNING: dangerous serve pool binary drift detected on port(s): $DRIFT_PORTS ($DRIFT_PENDING/2 consecutive passes) — pending alert"
            fi
          else
            rm -f "$STATE/drift-pending"
            BENIGN_REASON="door predates serves, episode <24h"
            if [ "$DOOR_ACTIVE" != "active" ] || [ -z "$DOOR_START_MONOTONIC" ] || [ "$DOOR_START_MONOTONIC" -eq 0 ] 2>/dev/null; then
              BENIGN_REASON="door inactive/timestamp missing, episode <24h"
            fi
            echo "WARNING: serve pool binary drift detected on port(s): $DRIFT_PORTS (benign: $BENIGN_REASON; nightly reset will reconcile) — no alert sent"
          fi
        elif [ -n "$REF_PREFIX" ] && [ "$VERIFIED_COUNT" -gt 0 ]; then
          # Clear throttle file and state ONLY on confirmed resolution (at least one serve verified and no drift found).
          # Do NOT clear on unverifiable passes (e.g. REF_PREFIX="" mid-home-manager-switch or all serves down),
          # as clearing on unknown state would re-arm the alert and cause duplicate notifications.
          rm -f "$STATE/drift-alerted" "$STATE/drift-pending" "$STATE/drift-first-seen"
        fi
      ''}";
    };
  };

  systemd.timers.opencode-serve-canary = {
    description = "Minutely OpenCode serve pool liveness canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "15s";
    };
  };

  # ---------------------------------------------------------------------------
  # Plugin-load canary (E2). Bead workstation-5yox, step 2 of
  # docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md; design in
  # docs/plans/2026-08-04-e2-plugin-canary-design.md.
  #
  # WHAT IT IS FOR: opencode's plugin loader can reject a plugin FILE and leave
  # the serve otherwise healthy, logging one ERROR line and nothing else. That
  # happened on 2026-07-30 and disabled shell-env.ts -- per-session KUBECONFIG
  # and all sops secret injection -- for ~32 hours before a human noticed. There
  # is no health check that would have caught it: /config/providers returned 200
  # the whole time, and upstream's user-visible plugin-error event is commented
  # out, so the log line is quite literally the only signal that exists.
  #
  # WHY BEFORE the loader patch (step 3): that patch makes the loader validate
  # and throw, which converts the LOUD failure shape (poisoned hooks array,
  # every request 500s, impossible to miss) into the QUIET one (one log line).
  # Shipping it without a detector would manufacture more 32-hour silences. This
  # unit is its prerequisite, not merely a cheaper alternative.
  #
  # TWO LEGS, and neither is a backup for the other -- they fail along different
  # axes. Nine plugin files load on this host:
  #   - Leg A (behavioural probe) sees ANY failure shape, including ones we have
  #     never met, but covers self-compact.js by name plus the host-wide LOUD
  #     symptom.
  #   - Leg B (log tail) sees only failures that emit the known string, but
  #     covers all nine -- including opencode-pigeon.ts and superpowers.js, which
  #     are mkOutOfStoreSymlinks into other repos' live checkouts and have NO
  #     build-time cover at all. They change on a `git pull` nobody here reviews.
  # Shared blind cell: a non-logging failure (e.g. an import-time throw, which
  # goes through publishPluginError with no logError) in one of the eight files
  # leg A does not probe. Step 3 closes it by making the loader log per-plugin.
  #
  # DETECT-ONLY. It never restarts anything: a restart cannot fix a bad plugin
  # file, and a restart loop here would fight opencode-serve-canary, whose
  # contract is restart-the-wedged. Separate unit for that reason.
  # ---------------------------------------------------------------------------
  systemd.services.opencode-plugin-canary = {
    description = "OpenCode plugin-load canary (detect-only; alerts via pigeon)";
    onFailure = [ "opencode-plugin-canary-failure.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Runs as dev, not root: it reads dev's opencode log and dev-owned
      # /run/secrets/pigeon_daemon_auth_token (0400 dev), and needs no privilege
      # beyond that. StateDirectory is chowned to User.
      User = "dev";
      Group = "dev";
      StateDirectory = "opencode-plugin-canary";
      Nice = 19;
      IOSchedulingClass = "idle";
      ExecStart = "${pkgs.writeShellScript "opencode-plugin-canary" ''
        set -u
        # System-service PATH is minimal -- be explicit. gawk specifically: awk is
        # NOT in coreutils, and the library's partial-line rule depends on gawk's
        # RT variable.
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.curl pkgs.util-linux pkgs.jq ]}

        # Windowing, rotation, partial-line, plugin-key and probe-table logic,
        # with its own tests in `nix flake check` (check `plugin-canary`).
        source "${opencode-plugin-canary-sh}"

        # TEST SEAMS. The four values below are overridable so the whole script can
        # be exercised end to end against a scratch state dir, a scratch log, and a
        # stub alert sink -- which is how the roadmap's three controls are run. This
        # bead exists because a guard was verified as a module and never in the role
        # it actually plays; a canary with no seam can only be "verified" by reading
        # it, or by letting it page the on-call to prove it works. Defaults are
        # production, so the unit below passes none of them.
        STATE="''${PLUGIN_CANARY_STATE:-/var/lib/opencode-plugin-canary}"
        LOG="''${PLUGIN_CANARY_LOG:-/home/dev/.local/share/opencode/log/opencode.log}"
        ALERT="''${PLUGIN_CANARY_ALERT:-${driftAlert}}"

        LATCH="$STATE/latch"
        OFF_FILE="$STATE/logtail.state"

        # Latch key for the detector-degraded condition. Prefixed so the relatch
        # loop can tell it from a plugin name; `!` cannot appear in a plugin key,
        # which is sanitised to [A-Za-z0-9._-].
        OVERSIZE_KEY="!logtail-oversize"

        # Latch key for "the leg is reading nothing at all". Same `!` prefix and
        # same reason: it cannot collide with a sanitised plugin key.
        UNMEASURABLE_KEY="!logtail-unmeasurable"

        # 60 minutely passes. One inert pass is a transient stat failure; an hour
        # of them is a blind detector. Low enough to catch a repointed log before
        # a night of meaningless silence, high enough not to page on a boot race.
        # A seam so the behaviour suite can drive it without sleeping an hour.
        UNMEASURABLE_THRESHOLD="''${PLUGIN_CANARY_UNMEASURABLE_THRESHOLD:-60}"

        # Cloudbox runs the pool as SYSTEM units; devbox runs it as user units.
        # The alert text interpolates this, so each host tells the reader the
        # command that actually works there.
        POOL_RESTART_HINT="sudo systemctl restart opencode-serve-pool.target"

        # The FRONT DOOR, never an individual serve. Both probed routes are
        # global-ro and deliberately NOT poolSafe, so the door forwards them to the
        # anchor; see the notes in pkgs/opencode-frontdoor/src/routes.classification.ts.
        DOOR="''${PLUGIN_CANARY_DOOR:-http://127.0.0.1:4700}"

        # 7, matching opencode-serve-canary, and for its reason (workstation-g3iy):
        # the post-boot catalog/credential burn runs ~5-6 min, and /config/providers
        # IS the provider catalog, so it is legitimately unhealthy for minutes after
        # every restart. A threshold of 2-3 would page on routine restarts, and an
        # operator who learns to ignore this channel is worse than a missed alert.
        THRESHOLD=7

        mkdir -p "$LATCH"

        # PLUGIN_CANARY_LOCK_SKIP_BEFORE_STATE
        # Don't fight an in-flight reset-workspace: it stops and starts the pool
        # deliberately, so probes through that window mean nothing. This MUST come
        # before any state mutation -- in particular before the offset advances --
        # or error lines written during the reset get consumed unexamined. Shared,
        # non-blocking probe; the `flock <file> <cmd>` form execvp()s the command,
        # which fails on this minimal PATH and misreads as "lock held".
        if [ -e /tmp/reset-workspace.lock ]; then
          exec 9< /tmp/reset-workspace.lock
          if ! flock -n -s 9; then
            echo "reset-workspace in progress; skipping this run"
            exit 0
          fi
          exec 9<&-
        fi

        # =====================================================================
        # LEG A -- behavioural probe, level-triggered
        # =====================================================================
        TOOL_BODY="$(mktemp "$STATE/probe.XXXXXX")"
        CHUNK=""
        trap 'rm -f "$TOOL_BODY" ''${CHUNK:+"$CHUNK"}' EXIT

        TOOL_STATUS="$(curl -s -o "$TOOL_BODY" -w '%{http_code}' \
          --max-time 10 --connect-timeout 3 "$DOOR/experimental/tool/ids" 2>/dev/null || true)"
        PROV_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
          --max-time 20 --connect-timeout 3 "$DOOR/config/providers" 2>/dev/null || true)"

        # The `type == "array"` clause is load-bearing, not defensive noise: jq's
        # index() on a STRING does a substring search, so a body that is a bare JSON
        # string mentioning the tool would report present -- a false negative, in the
        # one direction that fails quiet. Every other malformed shape already reads
        # as absent and alerts.
        # self_compact_and_resume exists ONLY because self-compact.js loaded and its
        # `tool` hook registered. This is a real load-proof, and the only one
        # available over HTTP. Note what this is NOT: `opencode debug info` lists
        # CONFIGURED plugins and reports success for a file the loader rejected, so
        # it must never be substituted here as a "simplification".
        TOOL_PRESENT=no
        if [ "$TOOL_STATUS" = "200" ] \
          && jq -e 'type == "array" and index("self_compact_and_resume") != null' < "$TOOL_BODY" >/dev/null 2>&1; then
          TOOL_PRESENT=yes
        fi

        PROBE_ACTION="$(plugin_canary_probe_action "$TOOL_STATUS" "$TOOL_PRESENT" "$PROV_STATUS")"
        FAILS_FILE="$STATE/probe.fails"
        FAILS="$(cat "$FAILS_FILE" 2>/dev/null || echo 0)"
        # Written without a `'''` empty-string case pattern on purpose: inside a Nix
        # indented string a bare pair of single quotes terminates the string.
        if [ -z "$FAILS" ]; then FAILS=0; fi
        case "$FAILS" in *[!0-9]*) FAILS=0 ;; esac

        case "$PROBE_ACTION" in
          HEALTHY)
            rm -f "$FAILS_FILE" "$STATE/alert-probe"
            ;;
          SKIP)
            # Door or anchor unreachable. That is opencode-serve-canary's
            # jurisdiction and it already pages; alerting here too would make this
            # a duplicate pager for an unrelated fault. The counter is deliberately
            # NOT reset: a fault that alternates unreachable/broken is still a fault.
            echo "probe skipped (tool=$TOOL_STATUS providers=$PROV_STATUS): door or anchor not answering"
            ;;
          *)
            FAILS=$((FAILS + 1))
            printf '%s\n' "$FAILS" > "$FAILS_FILE"
            echo "probe FAILED ($PROBE_ACTION) $FAILS/$THRESHOLD (tool=$TOOL_STATUS present=$TOOL_PRESENT providers=$PROV_STATUS)"
            if [ "$FAILS" -ge "$THRESHOLD" ]; then
              case "$PROBE_ACTION" in
                ALERT:tool-missing)
                  PROBE_SIG="plugin-canary:tool-missing:self_compact_and_resume"
                  PROBE_TEXT="$(cat <<EOF
OpenCode plugin canary: self-compact.js is NOT loaded.

The anchor serve answers HTTP 200 but its tool list no longer contains
self_compact_and_resume, which exists only while that plugin is loaded. A plugin
file was almost certainly rejected at load time. Other plugins may be affected;
this is the one probe that can prove it.

Failed $FAILS consecutive passes (~$FAILS min).

Check:
  grep -E '^timestamp=[^ ]+ level=ERROR .*failed to load plugin' /home/dev/.local/share/opencode/log/opencode.log | tail -5
  curl -s $DOOR/experimental/tool/ids | jq .
EOF
)"
                  ;;
                ALERT:providers-unhealthy)
                  PROBE_SIG="plugin-canary:providers-unhealthy"
                  PROBE_TEXT="$(cat <<EOF
OpenCode plugin canary: /config/providers is 500 through the door.

This is the exact symptom of the 2026-07-30 outage: a plugin factory returned a
non-hook value, the hooks array was poisoned, and every later hook iteration
threw -- so the serve loses its provider catalog and can run NO prompt at all.

Failed $FAILS consecutive passes (~$FAILS min).

Check:
  grep -E '^timestamp=[^ ]+ level=ERROR .*(failed to load plugin|hook)' /home/dev/.local/share/opencode/log/opencode.log | tail -20
  curl -s -o /dev/null -w '%{http_code}\n' $DOOR/config/providers
EOF
)"
                  ;;
                *)
                  PROBE_SIG="plugin-canary:cannot-evaluate:''${PROBE_ACTION#CANNOT_EVALUATE:}"
                  PROBE_TEXT="$(cat <<EOF
OpenCode plugin canary CANNOT EVALUATE the behavioural leg ($PROBE_ACTION).

The door answered, but with a status this canary cannot interpret: tool route
$TOOL_STATUS, providers route $PROV_STATUS. Likely an upstream route change (the
/experimental namespace is unstable and opencode-patched bumps every 8h) or auth
drift. This is NOT a plugin failure report -- it means leg A is blind until fixed,
so treat it as a broken detector rather than a broken plugin.

Failed $FAILS consecutive passes (~$FAILS min).

Check:
  curl -s -o /dev/null -w '%{http_code}\n' $DOOR/experimental/tool/ids
  systemctl status opencode-frontdoor --no-pager | head -20
EOF
)"
                  ;;
              esac
              "$ALERT" "$STATE/alert-probe" "$PROBE_SIG" "$PROBE_TEXT" 3600 21600
            fi
            ;;
        esac

        # =====================================================================
        # LEG B -- log tail. Detection is EDGE, alerting is LEVEL.
        #
        # The body is in the shared library so devbox runs the SAME code rather
        # than a fork of it; see plugin_canary_run_logtail_leg there for the
        # latch-before-offset and relatch-every-pass invariants and why they
        # exist. Everything it needs is set above.
        # =====================================================================
        plugin_canary_run_logtail_leg

        # `ls | wc -l` rather than `find`: findutils is not on this unit's PATH, and
        # a canary whose own summary line errors every minute is training the reader
        # to skim its journal.
        echo "plugin canary pass complete (probe=$PROBE_ACTION latches=$(ls -1 "$LATCH" 2>/dev/null | wc -l))"
      ''}";
    };
  };

  systemd.timers.opencode-plugin-canary = {
    description = "Minutely OpenCode plugin-load canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "15s";
    };
  };

  # The canary crashing is itself a silent failure -- the exact shape bead
  # workstation-5yox is about. This covers the script-dying half of "nothing
  # watches the watcher"; a masked TIMER is still invisible and is filed as a
  # follow-up.
  systemd.services.opencode-plugin-canary-failure = {
    description = "Alert that the OpenCode plugin-load canary itself failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "opencode-plugin-canary";
      ExecStart = "${pkgs.writeShellScript "opencode-plugin-canary-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq ]}
        ${driftAlert} /var/lib/opencode-plugin-canary/alert-canary-crashed \
          "plugin-canary:canary-crashed" \
          "OpenCode plugin canary FAILED TO RUN.

opencode-plugin-canary.service exited non-zero, so the plugin-load detector is
down. While it is down, a rejected plugin file produces no signal at all.

Check:
  systemctl status opencode-plugin-canary.service --no-pager
  journalctl -u opencode-plugin-canary.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };

  # Phantom-busy sweeper (workstation-s5gl; step 1 of
  # docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md). Ported from
  # devbox (users/dev/home.devbox.nix:1312-1358, workstation-utnw).
  #
  # WHAT IT FIXES. When a serve dies uncleanly (canary SIGKILL, OOM, hard
  # reboot) its in-flight assistant messages are never finalized:
  # `data.time.completed` stays NULL, so every TUI that (re)loads the session
  # renders the "working" shimmer forever — observed burning ~1 CPU core per TUI
  # in a GC storm for hours. Cloudbox had 303 such rows and no sweeper.
  #
  # TWO GATES, and the second one is the whole design:
  #   (a) role=assistant, no time.completed, no error, row untouched >30min (a
  #       streaming turn bumps time_updated on every part append; 30min leaves
  #       headroom for long silent tool calls);
  #   (b) created BEFORE the oldest currently-running pool serve booted.
  # Gate (b) exists because of the 2026-07-05 incident: a row younger than all
  # live serves may belong to a fiber that is alive-but-blocked in a serve's
  # memory. DB-finalizing those does NOT free the session (the in-memory runner
  # still holds the turn) and lies to observers until the serve's own completion
  # write lands over ours. Gate (b) is structurally immune to the stalled-but-
  # alive class: any row a pool serve is executing was created by that serve,
  # hence after its boot, hence after CUTOFF = min(boot). A stall of any length
  # cannot push it below the line.
  #
  # WHY SYSTEM SCOPE, WHEN DEVBOX'S IS A USER UNIT. Cloudbox's serves are system
  # units (User=dev), devbox's are user units. Discovery must therefore query the
  # system bus, and a `systemctl --user` copy-paste finds nothing here — which
  # would silently collapse gate (b) (see the fail-closed handling below). Same
  # scope as the discovery target means one bus and one deploy for the sweeper
  # and the units it reads, and a pool resize in this file lands in the same
  # diff. The earlier "a system unit would create root-owned -wal/-shm" argument
  # was wrong: User=dev applies here exactly as it does to the serves, whose WAL
  # is dev-owned today. No hardening (ProtectHome=true would hide the DB).
  #
  # KNOWN RESIDUAL (do not file as a bug): CUTOFF is the min over the pool, so an
  # intraday single-member kill orphans rows younger than the *other* members'
  # boots, which stay invisible until 03:00 bounces the whole pool via
  # opencode-serve-pool.target and resets every boot epoch. The backlog and the
  # drained-pool case sweep immediately; a fresh intraday orphan can shimmer
  # until ~03:05. Fixing that needs per-session owner attribution (the routing DB
  # has leases) and is deliberately out of scope here.
  systemd.services.opencode-phantom-busy-sweeper = {
    description = "Finalize orphaned in-flight opencode messages (phantom busy)";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      ExecStart = "${pkgs.writeShellScript "opencode-phantom-busy-sweeper" ''
        set -u
        # System-service PATH is minimal — be explicit. No procps: boot times come
        # from systemd, not `ps` (see DISCOVERY below).
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.sqlite pkgs.systemd pkgs.gawk ]}

        # Hardcoded, NOT "$HOME": a system unit with User= does not reliably set
        # HOME (the serve template sets it explicitly for the same reason).
        #
        # OPENCODE_SWEEPER_DB is a TEST SEAM, not configuration. The unit sets no
        # Environment=, so production is byte-identical to the old hardcoded path;
        # it exists so the test harness can exercise THIS script against scratch
        # databases instead of re-implementing (and thereby not testing) its logic.
        DB=''${OPENCODE_SWEEPER_DB:-/home/dev/.local/share/opencode/opencode.db}

        DRY=0
        [ "''${1:-}" = "--dry-run" ] && DRY=1

        # An unrecognised argument must not silently perform a WET sweep. This
        # script is now run by hand often enough (test harness, manual probes)
        # that `--dryrun` or `-n` is a realistic typo, and the wrong outcome of
        # that typo is destructive.
        if [ $# -gt 0 ] && [ "$1" != "--dry-run" ]; then
          echo "sweeper: unknown argument '$1' (only --dry-run is accepted) — refusing to run"
          exit 1
        fi

        # Fail closed, not `exit 0`: the path is hardcoded, so a typo here would
        # otherwise be a permanently silent success.
        if [ ! -f "$DB" ]; then
          echo "sweeper: DB not found at $DB — refusing to run"
          exit 1
        fi

        # DISCOVERY. Two independent guards, covering opposite drift directions:
        #   - the EXPECTED list is generated from users/dev/serve-pool.nix, so a
        #     renamed/removed template is caught (LoadState != loaded -> exit 1)
        #     rather than silently matching nothing;
        #   - the running GLOB additionally catches a STRAY instance still
        #     running after its port was dropped from serve-pool.nix (nothing
        #     stops it until 03:00). Its rows must keep protecting themselves.
        # CUTOFF is the min over the union. Boot epochs come from systemd's
        # ActiveEnterTimestamp rather than MainPID+`ps etimes`: no pid race (a pid
        # exiting between the two calls would silently skip a unit and LOOSEN the
        # gate), and truncation rounds the cutoff earlier (conservative) instead
        # of later. Note `systemctl show` exits 0 even for a not-found unit, so
        # LoadState must be checked explicitly — the exit code proves nothing.
        EXPECTED="${lib.concatMapStringsSep " " (p: "opencode-serve@${toString p}.service") servePool.ports}"

        # Note the exit status is checked on `systemctl` ALONE. Piping straight
        # into awk would mask a systemctl failure behind awk's happy exit 0 —
        # the same shape of silent degradation this whole port exists to remove.
        if ! RAW=$(systemctl list-units 'opencode-serve@*.service' --no-legend --plain --state=active); then
          echo "sweeper: systemctl list-units failed — refusing to run"
          exit 1
        fi
        STRAYS=$(printf '%s\n' "$RAW" | awk '{print $1}')

        # awk 'NF' drops blank lines; grep is deliberately NOT on the PATH above.
        UNITS=$(printf '%s\n%s\n' "$EXPECTED" "$STRAYS" | tr ' ' '\n' | awk 'NF' | sort -u)

        NOW=$(date +%s)
        ACTIVE=0
        OLDEST=""
        for u in $UNITS; do
          state=$(systemctl show "$u" --timestamp=unix -p LoadState,ActiveState,ActiveEnterTimestamp)
          ls_=$(printf '%s\n' "$state" | awk -F= '/^LoadState=/{print $2}')
          as_=$(printf '%s\n' "$state" | awk -F= '/^ActiveState=/{print $2}')
          ts_=$(printf '%s\n' "$state" | awk -F= '/^ActiveEnterTimestamp=/{print $2}')

          # An EXPECTED unit that is not loaded means the template was renamed or
          # the pool definition drifted. Fail closed: a permissive sweep is the
          # loot-incident class.
          case " $EXPECTED " in
            *" $u "*)
              if [ "$ls_" != "loaded" ]; then
                echo "sweeper: $u LoadState=$ls_ (expected loaded) — refusing to run"
                exit 1
              fi
              ;;
          esac

          [ "$as_" = "active" ] || continue

          # ANY active unit whose boot epoch will not parse is fatal. Skipping it
          # would raise CUTOFF if it happened to be the oldest member, which is
          # exactly the permissive failure gate (b) exists to prevent.
          epoch=''${ts_#@}
          case "$epoch" in
            ""|*[!0-9]*)
              echo "sweeper: $u is active but ActiveEnterTimestamp=''${ts_:-<empty>} — refusing to run"
              exit 1
              ;;
          esac

          ACTIVE=$(( ACTIVE + 1 ))
          [ -n "$OLDEST" ] && [ "$OLDEST" -le "$epoch" ] || OLDEST=$epoch
          [ "$DRY" = 1 ] && echo "sweeper: $u active since $epoch"
        done

        # No live pool serve -> no live-owner risk at all (a drained pool is the
        # one case where sweeping everything stale is maximally correct). This is
        # deliberately distinct from the discovery failures above, which exit 1.
        if [ "$ACTIVE" -eq 0 ]; then
          CUTOFF=$NOW
        else
          CUTOFF=$OLDEST
        fi
        echo "sweeper: db=$DB active=$ACTIVE cutoff=$CUTOFF now=$NOW dry=$DRY"

        # PHASE 1 — find candidates on a READ-ONLY connection.
        #
        # The scan itself was never the problem; holding the WAL write lock
        # while doing it was. SQLite takes that lock at the START of a write
        # statement and holds it for the statement's entire duration EVEN WHEN
        # IT MATCHES 0 ROWS — which is every run in practice (173/173 finalized
        # nothing between 2026-08-01 and 2026-08-03, each still holding the lock
        # ~1.9s, ~288 stalls/day against the serves' 5s busy_timeout). On
        # 2026-08-02 16:05 a cold-cache run held it 17.8s, blew that budget
        # twice, and killed a live turn — stranding exactly the kind of orphan
        # row this sweeper exists to clean up. Bead workstation-yvxh.
        #
        # A read-only connection takes no write lock, so this scan no longer
        # touches the serves. (mode=ro can still create/recover the -shm, which
        # needs a writable DIRECTORY — dev has one. It cannot write the DB.)
        #
        # The predicate is byte-identical to devbox's, including
        # json_extract(data,'$.time.created') where the indexed-looking
        # time_created column would do. They never disagree (verified 360314/
        # 360314 rows) but the only index is (session_id, time_created, id) and
        # this query has no session filter, so both variants full-scan and parity
        # with the month-proven script costs nothing. Measured 1.8s on a 13GB DB.
        # Phase 2 repeats it verbatim so the two phases cannot drift apart.
        #
        # `-cmd ".timeout N"`, not `PRAGMA busy_timeout=N;`: the pragma RETURNS A
        # ROW, so the old script has been logging a bare "10000" line to the
        # journal every five minutes since it was deployed. Harmless when the
        # output was only ever read by a human; fatal here, where that line would
        # be parsed as a candidate id. The dot-command sets the same timeout
        # silently.
        #
        # `-init /dev/null -list -noheader` for the same reason: phase 1's output
        # format is now load-bearing (it is parsed into a SQL id list), so it is
        # pinned explicitly rather than left to the CLI's defaults, a stray
        # ~/.sqliterc, or a future sqlite bump. Verified that sqlite 3.50.4 does
        # not read an rc file non-interactively — this keeps that true by
        # construction instead of by version.
        if ! CANDIDATES=$(sqlite3 -init /dev/null -list -noheader -cmd ".timeout 10000" "file:$DB?mode=ro" "
          SELECT id FROM message
          WHERE json_extract(data, '\$.role') = 'assistant'
            AND json_extract(data, '\$.time.completed') IS NULL
            AND json_extract(data, '\$.error') IS NULL
            AND time_updated < (strftime('%s','now') - 1800) * 1000
            AND json_extract(data, '\$.time.created') < $CUTOFF * 1000;
        "); then
          # A failed probe must never be indistinguishable from "nothing to do".
          echo "sweeper: candidate query failed — refusing to run"
          exit 1
        fi

        # These ids get interpolated into a write statement below. They come
        # from our own database, but "our own database" is precisely the thing
        # whose contents we cannot assume when the next step is destructive, so
        # anything that is not shaped like an opencode message id stops the run.
        # This also guarantees the line-oriented chunking below can never be
        # confused by an id containing a newline.
        if ! printf '%s\n' "$CANDIDATES" | awk 'NF && !/^[A-Za-z0-9_.:-]+$/ { exit 1 }'; then
          echo "sweeper: candidate id failed validation — refusing to write"
          exit 1
        fi

        N=$(printf '%s\n' "$CANDIDATES" | awk 'NF' | wc -l)

        if [ "$DRY" = 1 ]; then
          echo "sweeper: would finalize $N orphaned message(s) (cutoff=$CUTOFF)"
          exit 0
        fi

        # THE POINT OF ALL THIS: the overwhelmingly common case now ends here,
        # having taken no write lock at all. Said out loud in the log so the
        # behaviour is observable in `journalctl -u
        # opencode-phantom-busy-sweeper`, and so a no-op run is distinguishable
        # from a writing one. Keeps the "finalized N orphaned message(s)"
        # prefix the old script logged, which existing greps rely on.
        if [ "$N" -eq 0 ]; then
          echo "sweeper: finalized 0 orphaned message(s) (cutoff=$CUTOFF) — no candidates, no write lock taken"
          exit 0
        fi

        # PHASE 2 — targeted writes, chunked.
        #
        # Each chunk is its own autocommit transaction resolved through the id
        # primary-key index (EXPLAIN QUERY PLAN: `SEARCH message USING INDEX
        # sqlite_autoindex_message_1 (id=?)`, against `SCAN message` for the old
        # statement), so the lock is held for the time it takes to rewrite at
        # most 500 known rows — not the time to read the whole table — and other
        # writers interleave between chunks. (Chunk size is therefore the knob if
        # a huge backlog of large rows ever makes a single chunk slow; 500 rows
        # of ~4KB JSON is nothing next to the 13GB scan it replaces.) Chunked because SQLite bounds expression
        # depth / bound-variable count, and a drained-pool backlog sweep can
        # legitimately produce thousands of ids.
        #
        # Every predicate is RE-CHECKED inside the UPDATE: a serve may
        # legitimately finish one of these rows between phase 1 and phase 2, and
        # a row that completed on its own must not be overwritten with an abort.
        CHUNKS=$(printf '%s\n' "$CANDIDATES" | awk -v q="'" '
          NF          { buf = buf sep q $0 q; sep = ","; n++ }
          n == 500    { print buf; buf = ""; sep = ""; n = 0 }
          END         { if (n) print buf }')

        OLDIFS=$IFS
        IFS='
'
        set -f
        set -- $CHUNKS
        IFS=$OLDIFS
        set +f

        NCHUNKS=$#
        TOTAL=0
        FAILED=0
        for chunk in "$@"; do
          if got=$(sqlite3 -init /dev/null -list -noheader -cmd ".timeout 10000" "$DB" "
            UPDATE message SET data = json_set(data,
                '\$.time.completed', CAST(strftime('%s','now') AS INTEGER)*1000,
                '\$.error', json('{\"name\":\"MessageAbortedError\",\"data\":{\"message\":\"Aborted (phantom-busy sweeper: in-flight row predates all live serves, silent >30min)\"}}'))
            WHERE id IN ($chunk)
              AND json_extract(data, '\$.role') = 'assistant'
              AND json_extract(data, '\$.time.completed') IS NULL
              AND json_extract(data, '\$.error') IS NULL
              AND time_updated < (strftime('%s','now') - 1800) * 1000
              AND json_extract(data, '\$.time.created') < $CUTOFF * 1000;
            SELECT changes();
          "); then
            TOTAL=$(( TOTAL + got ))
          else
            FAILED=$(( FAILED + 1 ))
          fi
        done

        echo "sweeper: finalized $TOTAL orphaned message(s) (cutoff=$CUTOFF) — $N candidate(s), $NCHUNKS chunk(s), $FAILED failed"

        # TOTAL < N is normal and benign: it means a serve finished the row
        # itself between the two phases and the re-check correctly declined to
        # clobber it. A chunk that could not be written is NOT benign — surface
        # it as a unit failure. The sweep is idempotent, so the next run retries.
        if [ "$FAILED" -gt 0 ]; then
          echo "sweeper: $FAILED chunk(s) failed to write — see above"
          exit 1
        fi
      ''}";
    };
  };

  systemd.timers.opencode-phantom-busy-sweeper = {
    description = "Periodic phantom-busy message finalization";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "30s";
    };
  };

  # W2d (bead workstation-yvxh.12): read-only instrumentation of opencode.db
  # write-lock contention, feeding W2's busy_timeout/retry tuning decision.
  # Spec: docs/plans/2026-08-03-w2d-lockprobe-spec.md
  #
  # Measures TWO quantities and never conflates them: hold duration H (from
  # /proc/locks, byte 120 of the -shm file, holder PID visible) and observed
  # main-thread freeze F (from /proc/<pid>/wchan). F is the RESIDUAL hold at
  # contender arrival, not H -- see the spec before quoting either number.
  #
  # Continuous rather than a timer: the quantity is a distribution, so its value
  # accrues with wall-clock coverage. A periodic oneshot would sample a biased
  # slice and miss precisely the rare long holds that matter.
  systemd.services.opencode-lockprobe = {
    description = "Sample opencode.db write-lock holds and serve event-loop freezes (read-only)";
    wantedBy = [ "multi-user.target" ];
    # Not Requires=: the probe must keep running (and keep emitting the rollup
    # heartbeat) across a pool restart, precisely so a reset is visible in the
    # data as a PID change rather than as a silent gap.
    after = [ "opencode-serve-pool.target" ];
    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      # /var/lib/opencode-lockprobe, created and chowned by systemd.
      StateDirectory = "opencode-lockprobe";
      ExecStart = "${pkgs.python3}/bin/python3 ${./opencode-lockprobe.py}";
      Environment = [
        # systemctl is needed for serve discovery (a unit GLOB -- no port is
        # ever named, which keeps this clear of the front-door opacity guard
        # by construction rather than by exemption).
        "PATH=${lib.makeBinPath [ pkgs.systemd pkgs.coreutils ]}"
        "LOCKPROBE_OUT=/var/lib/opencode-lockprobe/episodes.jsonl"
      ];
      Restart = "always";
      RestartSec = "10s";
      # This is a measurement of a contended box; it must not become a
      # contributor to that contention. Deprioritised on CPU and IO, and capped
      # on memory so a leak degrades the probe rather than the machine.
      Nice = 10;
      CPUWeight = 20;
      IOWeight = 20;
      MemoryMax = "192M";
      # Read-only observation. It reads procfs and stats the -shm file; the only
      # thing it writes is its own state directory.
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
    };
  };

  # TeamClaude: personal Claude Max rotator that the claude-failover-proxy
  # router forwards to when work Claude-on-Vertex spend is over budget
  # (8fe.15 PREREQ). Runs upstream KarpelesLab/teamclaude (tagged release,
  # zero-dep Node) from the nix package (pkgs/teamclaude), not a ~/projects checkout.
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
  # PROACTIVE PROBE (scoped weekly limits): the per-model scoped weekly-limit
  # awareness only populates PROACTIVELY when the background quota probe is on
  # (the reactive 429/SSE backstop is always armed). It is runtime opt-in and
  # also NOT nix-managed (lives as quotaProbeSeconds in the same writable config).
  # After seeding, enable it to match devbox:
  #   TEAMCLAUDE_CONFIG=/home/dev/.config/teamclaude.json \
  #     teamclaude probe 90   # reads /api/oauth/usage every 90s; spends NO quota
  #
  # BIND + AUTH: upstream 1.1.5 binds 127.0.0.1 by DEFAULT (server.listen host is
  # TEAMCLAUDE_HOST || config.proxy.host || '127.0.0.1'), so :3456 is
  # localhost-only unless explicitly widened. The router connects via 127.0.0.1
  # anyway, so no widening is needed (this is a safer default than the old fork,
  # which bound all interfaces). Two further backstops keep it private even if a
  # future config widens the bind: (1) cloudbox runs NO NixOS firewall and relies
  # on GCP's default-deny ingress (3456 is not opened), and (2) TeamClaude's own
  # auth gate (server.js) requires x-api-key === the config proxy.apiKey for any
  # NON-localhost client. The router sends the key anyway.
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

  # TeamClaude pool canary — the alarm that was missing on 2026-07-19.
  #
  # WHY THIS EXISTS. On 2026-07-19/20 the OAuth refresh tokens for two of the
  # three Max accounts expired (invalid_grant, "Refresh token expired").
  # TeamClaude logged "needs re-login" ~2,000x/day for SEVEN DAYS and nobody
  # noticed, because the only health signal anyone consumed was cfp's /stats
  # `maxAvailable` — which is `accounts.some(healthy)`, a BOOLEAN. The surviving
  # standby account kept answering, so `maxAvailable` stayed true and actively
  # MASKED a pool running at 1/3 capacity.
  #
  # That silence is expensive. Max is the only flat-rate tier; on healthy
  # high-demand days it absorbs 46-75% of notional spend (measured over
  # 2026-07-01..07-25). A dark pool roughly doubles the daily paid bill, because
  # everything falls back to Vertex/Enterprise, which are billed at the same
  # token rates as each other.
  #
  # WHAT IT DOES. Every 5 minutes it reads TeamClaude's own status endpoint and
  # alerts (via Pigeon -> Telegram, throttled) when healthy < total, turning a
  # 7-day blind spot into ~10 minutes. It deliberately does NOT auto-remediate:
  # the fix is an interactive `teamclaude login`, which only a human can run.
  #
  # DESIGN NOTES, each learned the hard way:
  #  - Needs no secret: /teamclaude/status is unauthenticated (verified
  #    2026-07-26 — it returns 200 with no, empty, or junk x-api-key). It binds
  #    127.0.0.1 only, so that is tolerable; it also means this canary carries no
  #    credential.
  #  - Trust ONLY the top-level accounts[].status. The per-account
  #    probe.accounts[].error field reports "HTTP 429: Rate limited" for
  #    AUTH-DEAD accounts — actively misleading, and it would send the operator
  #    chasing a quota problem instead of running `teamclaude login`.
  #  - UNKNOWN MUST NEVER ALERT (same rule the frontdoor canary learned): a curl
  #    failure, non-200, unparseable body, or zero-account roster logs a warning
  #    and exits 0. Otherwise a transient blip pages forever on the TTL.
  #  - Dampened to 2 consecutive passes (~10 min) so one flaky probe can't page.
  systemd.services.teamclaude-pool-canary = {
    description = "TeamClaude Max pool health canary (alerts when accounts die)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "teamclaude-pool-canary";
      ExecStart = "${pkgs.writeShellScript "teamclaude-pool-canary" ''
        set -u
        # System-service PATH is minimal — be explicit.
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.curl pkgs.jq ]}
        STATE=/var/lib/teamclaude-pool-canary
        PENDING="$STATE/degraded-pending"
        # Persisted so the reminder below can quote the live roster, and so a
        # post-mortem has the last body the canary actually saw.
        BODY="$STATE/last-status.json"

        # DECLARED pool size: how many accounts SHOULD be serving. Alerting on
        # `healthy < roster length` is wrong, and would have paged daily forever:
        # an account the operator deliberately leaves un-logged-in stays in the
        # roster with status "error" and disabled=false, so the roster length
        # never shrinks to match intent. BUMP THIS when the pool composition
        # changes — the twice-monthly reminder below reports actual-vs-expected so
        # a stale value surfaces on its own rather than silently under-alerting.
        # 2026-07-26: briefly 2 (johnnymo87 removed as a sizing experiment), then
        # back to 3 — the experiment is answered from the quota series below
        # instead, which does not require running the pool short.
        EXPECTED_HEALTHY=3

        # Only police a unit that is supposed to be up (mirrors the frontdoor
        # canary). An intentional stop must not page.
        if [ "$(systemctl is-active teamclaude.service)" != "active" ]; then
          rm -f "$PENDING" "$STATE/degraded-alerted"
          exit 0
        fi

        HTTP_CODE=$(curl -sS --max-time 10 --connect-timeout 3 -o "$BODY" -w "%{http_code}" \
          http://127.0.0.1:3456/teamclaude/status 2>/dev/null) || HTTP_CODE=000

        if [ "$HTTP_CODE" != "200" ]; then
          echo "WARNING: teamclaude status probe returned HTTP $HTTP_CODE (unknown; not alerting)"
          exit 0
        fi

        TOTAL=$(jq -r '(.accounts // []) | length' "$BODY" 2>/dev/null || echo "")
        HEALTHY=$(jq -r '[(.accounts // [])[] | select(.disabled != true and .status == "active")] | length' "$BODY" 2>/dev/null || echo "")

        # Both sides must be KNOWN before comparing.
        case "$TOTAL" in ""|*[!0-9]*) echo "WARNING: could not parse account total (unknown; not alerting)"; exit 0 ;; esac
        case "$HEALTHY" in ""|*[!0-9]*) echo "WARNING: could not parse healthy count (unknown; not alerting)"; exit 0 ;; esac
        if [ "$TOTAL" -eq 0 ]; then
          echo "WARNING: status reported zero accounts (unknown; not alerting)"
          exit 0
        fi

        # QUOTA TIME SERIES — for the pool-sizing question.
        #
        # Account COUNT is not capacity. The 2026-07-08 saturation looked like
        # "3 accounts wasn't enough", but two of the three were sitting at
        # 99-100% usage, so it was really a drawn-down pool of ~1. Judging pool
        # size from saturation events alone repeats that error.
        #
        # Recording per-account quota every pass lets us ask "would N-1 accounts
        # have covered the load we actually saw?" from measured consumption,
        # instead of removing an account and paying for the shortfall on the
        # paid tiers to find out. Note the 5h and 7d windows are ROLLING and
        # STAGGERED per account, so there is no clean weekly boundary to sample
        # at — a continuous series is the only thing that answers it.
        #
        # Sampled on EVERY pass, including healthy ones: the healthy days are
        # the baseline. ~250B/pass at 5-minutely => ~72KB/day, trimmed to ~30d.
        SAMPLES="$STATE/quota-samples.jsonl"
        if jq -c --arg ts "$(date -Is)" '{
              ts: $ts,
              healthy: ([(.accounts // [])[] | select(.disabled != true and .status == "active")] | length),
              roster: ((.accounts // []) | length),
              current: (.currentAccount // null),
              accounts: [(.accounts // [])[] | {
                n: ((.name // "?") | split("@")[0]),
                s: .status,
                u5h: ((.quota // {}).unified5h),
                u7d: ((.quota // {}).unified7d),
                u7dF: ((.quota // {}).unified7dFable)
              }]
            }' "$BODY" >> "$SAMPLES" 2>/dev/null; then
          # Trim to roughly the last 30 days of 5-minutely samples. Checked only
          # past a slack margin so we are not rewriting the file every pass.
          if [ "$(wc -l < "$SAMPLES" 2>/dev/null || echo 0)" -gt 9500 ]; then
            tail -n 8640 "$SAMPLES" > "$SAMPLES.tmp" 2>/dev/null \
              && mv -f "$SAMPLES.tmp" "$SAMPLES"
          fi
        else
          # Never fatal: a lost sample must not cost us the health alert.
          echo "WARNING: quota sample append failed (non-fatal)"
        fi

        if [ "$HEALTHY" -ge "$EXPECTED_HEALTHY" ]; then
          # Clear throttle + dampening ONLY on confirmed recovery.
          rm -f "$PENDING" "$STATE/degraded-alerted"
          # More healthy accounts than declared means EXPECTED_HEALTHY is stale.
          # Log only — an operator ADDING capacity is not an incident.
          if [ "$HEALTHY" -gt "$EXPECTED_HEALTHY" ]; then
            echo "NOTE: $HEALTHY healthy accounts but EXPECTED_HEALTHY=$EXPECTED_HEALTHY; bump the canary's declared pool size"
          fi
          exit 0
        fi

        PENDING_N=$(( $(cat "$PENDING" 2>/dev/null || echo 0) + 1 ))
        echo "$PENDING_N" > "$PENDING"
        echo "WARNING: teamclaude pool degraded: $HEALTHY healthy, expected $EXPECTED_HEALTHY (roster $TOTAL) ($PENDING_N/2 consecutive)"
        [ "$PENDING_N" -ge 2 ] || exit 0

        ROSTER=$(jq -r '(.accounts // [])[] | "  - \(.name // "?"): \(.status // "?")"' "$BODY" 2>/dev/null || echo "  (roster unavailable)")

        DEGRADED_TEXT=$(cat <<EOF
TeamClaude Max pool DEGRADED: $HEALTHY healthy, expected $EXPECTED_HEALTHY.

Roster ($TOTAL accounts; some may be intentionally left off):
$ROSTER

Max is the only flat-rate tier - it absorbs 46-75% of notional spend on busy
days, so a dark pool roughly doubles the daily paid bill.

Likely cause: expired OAuth refresh token(s) (~30d TTL). Ignore any
"HTTP 429 / Rate limited" wording in the probe detail - that string is reported
for auth-dead accounts too and is misleading.

To fix (interactive, on cloudbox):
  teamclaude login

Confirm: curl -s localhost:3456/teamclaude/status | jq '[.accounts[].status]'
EOF
)
        # Signature is healthy-vs-expected so a FURTHER degradation re-pages
        # immediately instead of being swallowed by the 24h throttle.
        ${driftAlert} "$STATE/degraded-alerted" "$HEALTHY/$EXPECTED_HEALTHY" "$DEGRADED_TEXT" 900 14400
        exit 0
      ''}";
    };
  };

  systemd.timers.teamclaude-pool-canary = {
    description = "5-minutely TeamClaude Max pool health canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      AccuracySec = "30s";
    };
  };

  # Proactive re-login reminder.
  #
  # The canary above catches a dead account within ~10 minutes, which bounds the
  # damage. This bounds it further by prompting BEFORE the tokens die. Anthropic
  # OAuth refresh tokens appear to carry a ~30-day TTL from issuance: the two
  # accounts added 2026-06-19 18:45 died 2026-07-19 23:55 and 2026-07-20 02:34,
  # ~30 days later and 2.5h apart — a cohort expiry, not usage-related (both had
  # stopped serving on 07-16 yet kept refreshing successfully until death).
  #
  # Fires the 1st and 15th (<=16 days apart, comfortably inside the ~30d TTL).
  # It is deliberately a dumb calendar reminder: token issue dates are NOT
  # recoverable from teamclaude.json (it stores only `expiresAt` for the
  # short-lived ACCESS token), so any "days remaining" figure would be invented.
  # The reminder quotes the live roster so the operator can judge at a glance.
  systemd.services.teamclaude-relogin-reminder = {
    description = "Periodic reminder to re-login TeamClaude accounts (~30d refresh-token TTL)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "teamclaude-pool-canary";
      ExecStart = "${pkgs.writeShellScript "teamclaude-relogin-reminder" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq ]}
        STATE=/var/lib/teamclaude-pool-canary
        BODY="$STATE/last-status.json"
        # Keep in sync with EXPECTED_HEALTHY in teamclaude-pool-canary above.
        EXPECTED_HEALTHY=3

        ROSTER="  (no recent status sample)"
        DRIFT=""
        if [ -f "$BODY" ]; then
          ROSTER=$(jq -r '(.accounts // [])[] | "  - \(.name // "?"): \(.status // "?")"' "$BODY" 2>/dev/null || echo "  (roster unavailable)")
          HEALTHY=$(jq -r '[(.accounts // [])[] | select(.disabled != true and .status == "active")] | length' "$BODY" 2>/dev/null || echo "")
          case "$HEALTHY" in
            ""|*[!0-9]*) : ;;
            *) if [ "$HEALTHY" -ne "$EXPECTED_HEALTHY" ]; then
                 DRIFT="
NOTE: $HEALTHY accounts healthy but the canary expects $EXPECTED_HEALTHY. Either
re-login the missing account(s), or update EXPECTED_HEALTHY in
hosts/cloudbox/configuration.nix so the canary matches reality."
               fi ;;
          esac
        fi

        REMINDER_TEXT=$(cat <<EOF
Scheduled reminder: re-login the TeamClaude Max accounts.

Anthropic OAuth refresh tokens appear to expire ~30 days after issuance. In
July 2026 two accounts died exactly 30 days after being added and the outage
went unnoticed for 7 days, costing the flat-rate tier entirely.

Last known roster (expected healthy: $EXPECTED_HEALTHY):
$ROSTER
$DRIFT

Run on cloudbox (interactive):
  teamclaude login

Confirm: curl -s localhost:3456/teamclaude/status | jq '[.accounts[].status]'
EOF
)
        # Date-stamped signature so the throttle never suppresses a scheduled fire.
        ${driftAlert} "$STATE/relogin-reminded" "reminder-$(date +%Y-%m-%d)" "$REMINDER_TEXT" 0
        exit 0
      ''}";
    };
  };

  systemd.timers.teamclaude-relogin-reminder = {
    description = "Twice-monthly TeamClaude re-login reminder";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01,15 09:00:00";
      Persistent = true;
      AccuracySec = "1h";
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
  # (8fe.14 / T13a). Listens on 127.0.0.1:8789. opencode's
  # google-vertex-anthropic baseURL is flipped to this in T13b.
  #
  # BIND ADDRESS (corrected 2026-07-26). This comment previously claimed cfp
  # "binds all interfaces" but ":8789 stays private via GCP's default-deny
  # ingress". Both halves were wrong in a way that mattered:
  #   - teamclaude does NOT bind all interfaces; it is 127.0.0.1:3456.
  #   - GCP default-deny blocks the public internet, but not VPC-internal peers
  #     and not the local docker bridge (172.18.0.1/16). firewall.service is
  #     inactive on this host, so nothing else was filtering either.
  # cfp has no inbound auth and injects the TeamClaude key and the real
  # Anthropic enterprise key on behalf of ANY caller, so a reachable port is a
  # license to spend money — and the enterprise leg is live on any day Vertex
  # is over budget (22 of 25 sampled days). It is now pinned to loopback below,
  # and cfp itself defaults to 127.0.0.1 as of the CFP_LISTEN_HOST change, so
  # this is belt-and-braces rather than the only guard.
  #
  # Startup is network-tolerant: index.ts binds the
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
        # Loopback only. All cfp clients are local to cloudbox. Widening this
        # re-exposes the credential-injecting legs described above, so treat
        # inbound auth as a prerequisite for changing it. NOTE: requires a cfp
        # build containing CFP_LISTEN_HOST; older binaries ignore it and still
        # bind 0.0.0.0.
        "CFP_LISTEN_HOST=127.0.0.1"
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
        # Per-request event log (cfp >= v0.9.0). MUST be set explicitly: cfp
        # ships this DISABLED (empty path => off) and deliberately does NOT
        # default it to a sibling of CFP_STATE_PATH the way stats.json and
        # history.jsonl do, because the file records RAW session ids. Without
        # this line the instrumentation is inert and we silently collect
        # nothing — which is the failure mode it exists to eliminate.
        #
        # Why we want it: /stats and history.jsonl are daily AGGREGATES and
        # cannot answer (a) the real session idle-gap distribution, so
        # CFP_IDLE_MIGRATE_SECONDS above stays an unvalidated guess, (b) how
        # much spend accrues to sessions already pinned to a tier after it
        # crossed budget, or (c) a counterfactual cap replay. Two JSONL events
        # per request (route + usage) joined by requestId answer all three.
        #
        # Volume: ~2.5 MB/day at peak observed traffic, ~75 MB at 30-day
        # retention, in the same StateDirectory as the spend ledger.
        "CFP_EVENTS_PATH=/var/lib/claude-failover-proxy/events.jsonl"
        # 30 days, not the tempting 14: the clean 3-account baseline only
        # restarts 2026-07-26, and 14 would age it out before release lag plus
        # weeks of collection plus analysis could consume it. This is also the
        # cfp default, set explicitly so a future default change can't quietly
        # shorten the window.
        "CFP_EVENTS_RETENTION_DAYS=30"
        # Enterprise failover tier (opt-in). CFP_ENTERPRISE_API_KEY is exported
        # from the sops secret in the shim below (RAW value, see note). The
        # enterprise spend ledger defaults to spend-enterprise.json beside
        # spend.json (same StateDirectory), so no CFP_ENTERPRISE_STATE_PATH needed.
        "CFP_ENTERPRISE_BUDGET_DOLLARS=100"
      ];
      # CFP_TEAMCLAUDE_API_KEY and CFP_ENTERPRISE_API_KEY are RAW values (not
      # KEY=VALUE) so they can't go via EnvironmentFile; export them from the sops
      # secrets in a shell shim (same pattern as aigateway). set -e makes a
      # missing/unreadable secret fail loud.
      ExecStart = "${pkgs.writeShellScript "claude-failover-proxy-start" ''
        set -euo pipefail
        export CFP_TEAMCLAUDE_API_KEY="$(${pkgs.coreutils}/bin/cat /run/secrets/teamclaude_api_key)"
        export CFP_ENTERPRISE_API_KEY="$(${pkgs.coreutils}/bin/cat /run/secrets/anthropic_enterprise_api_key)"
        exec ${claude-failover-proxy}/bin/claude-failover-proxy
      ''}";
      # Restart=ALWAYS, not on-failure (2026-08-06 outage, 36 minutes).
      #
      # cfp is the baseURL of opencode's google-vertex-anthropic provider, so a
      # dead :8789 is not a degraded mode — it is an immediate ECONNREFUSED on
      # every Claude request, fleet-wide ("Cannot connect to API: Unable to
      # connect", AI_APICallError).
      #
      # On 2026-08-06 13:54:31 a SIGTERM storm of unknown origin hit a broad set
      # of dev-uid daemons within ~900ms. Every peer came back within ~10s;
      # cfp stayed dead for 36 minutes until a human ran `systemctl start`.
      # The sole difference was this line. `Restart=on-failure` does not restart
      # on SIGHUP/SIGINT/SIGTERM/SIGPIPE — systemd scores a clean SIGTERM death
      # as SUCCESS and schedules no restart job at all.
      #
      # (pigeon-daemon is also on-failure and DID come back — only because it
      # installs a SIGTERM handler and exits 143, a non-zero code. That is an
      # accident of the app's exit path, not of the unit config. See bead
      # workstation-cfp-restart-audit.)
      Restart = "always";
      # 5s, down from 10s: matches opencode-frontdoor, the other loopback SPOF
      # in the request path. Every second here is a second of hard failures for
      # every live session, and cfp's startup is network-tolerant (it binds and
      # logs before any upstream call), so there is nothing to wait for.
      RestartSec = 5;
    };
    # Rate limiting DISABLED deliberately (default is 5 starts / 10s, after
    # which systemd gives up and leaves the unit `failed` until a human
    # intervenes). That terminal state is the exact failure this change exists
    # to remove: a silent systemd decision not to restart a component whose
    # absence breaks every session. For a process this cheap, "retry forever at
    # 5s and page a human" strictly dominates "give up quietly" — a start that
    # fails on a transient cause (unreadable sops secret during early boot,
    # e.g.) then heals on its own, and one that fails permanently is caught by
    # claude-failover-proxy-canary's restart-loop alert below rather than by a
    # user noticing their sessions are broken.
    startLimitIntervalSec = 0;
  };

  # claude-failover-proxy liveness canary.
  #
  # WHY IT EXISTS. The 2026-08-06 outage above was discovered only because
  # sessions broke; nothing watched :8789. Restart=always closes the "process
  # died" half of that hole on its own. This canary covers what systemd
  # structurally cannot see:
  #   1. LISTENING BUT WEDGED — the port is bound and the unit is `active`, but
  #      the event loop no longer answers. Identical in shape to the serve/door
  #      wedge documented in the monitoring-serve-pool skill; Restart= never
  #      fires because nothing exits. This branch auto-restarts.
  #   2. RESTART-LOOPING — Restart=always with no start limit (see above) means
  #      a genuinely broken binary retries forever and *silently*. This branch
  #      is the alarm that replaces the start limit we deliberately removed.
  #   3. STOPPED AND STAYING STOPPED — a human `systemctl stop`, or a start that
  #      keeps failing. Alert only; auto-starting would fight an intentional
  #      stop, and repeatedly `start`ing a broken binary is just the restart
  #      loop by another name.
  #
  # PROBE: GET /stats. It is the only unauthenticated endpoint (verified
  # 2026-08-06: /health, /healthz, /readyz, /status and / all return 401), it is
  # served by cfp itself rather than proxied upstream, and it returns JSON, so a
  # parseable body proves the JS loop is actually running rather than merely
  # that the kernel accepted a connection. A bare port check would have said
  # "fine" for the entire wedge class this canary is for.
  #
  # UNKNOWN MUST NEVER ALERT (the rule the frontdoor and teamclaude canaries
  # both learned): an unparseable body or an unexpected status logs a warning
  # and exits 0. Only "no response at all" counts as a wedge.
  systemd.services.claude-failover-proxy-canary = {
    description = "claude-failover-proxy liveness canary (restart wedged cfp, alert when it is down or looping)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "claude-failover-proxy-canary";
      ExecStart = "${pkgs.writeShellScript "claude-failover-proxy-canary" ''
        set -u
        # System-service PATH is minimal — be explicit. Deep stack dumps
        # (eu-stack, cpu-io-split) are omitted as on the frontdoor canary:
        # time-to-recovery matters more than depth for a request-path SPOF.
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.util-linux pkgs.curl pkgs.findutils pkgs.jq ]}

        STATE=/var/lib/claude-failover-proxy-canary
        UNIT=claude-failover-proxy.service
        PORT=8789
        FAILFILE="$STATE/fails"
        DOWNFILE="$STATE/down-pending"
        WINDOW="$STATE/restart-window"
        NOW=$(date +%s)

        # No /tmp/reset-workspace.lock check: the nightly reset does not touch
        # cfp (it restarts the serve pool and respawns nvims only).

        capture_and_restart() {
          local reason="''${1:-unknown}"
          TS=$(date +%Y%m%dT%H%M%S)
          DUMP="$STATE/wedge-$TS"
          mkdir -p "$DUMP"

          # Bound persistent forensics: keep only the 10 newest wedge dumps.
          ls -dt "$STATE"/wedge-* 2>/dev/null | tail -n +11 | xargs -r rm -rf || true

          PID=$(systemctl show "$UNIT" -p MainPID --value)
          CG=$(systemctl show "$UNIT" -p ControlGroup --value)
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            for f in status wchan syscall; do
              cat "/proc/$PID/$f" > "$DUMP/$f" 2>/dev/null || true
            done
            # Per-thread kernel wait channels. Read the SERIES, not one sample:
            # a single wchan reading cannot distinguish a wedged loop from a
            # healthy one caught mid-sleep (monitoring-serve-pool skill).
            for t in /proc/$PID/task/*/; do
              [ -d "$t" ] || continue  # skip the literal glob if the process just died
              tid=$(basename "$t")
              printf '%s %s %s\n' "$tid" "$(cat "$t/wchan" 2>/dev/null)" \
                "$(cat "$t/comm" 2>/dev/null)" >> "$DUMP/threads" 2>/dev/null || true
            done
            i=0
            while [ "$i" -lt 20 ]; do
              printf '%s\n' "$(cat "/proc/$PID/wchan" 2>/dev/null)" >> "$DUMP/wchan-series" 2>/dev/null || true
              sleep 0.1
              i=$((i + 1))
            done
          fi
          if [ -n "$CG" ]; then
            for f in memory.current memory.peak memory.max memory.stat memory.pressure cpu.pressure cgroup.procs; do
              cat "/sys/fs/cgroup$CG/$f" > "$DUMP/$f" 2>/dev/null || true
            done
          fi

          echo "RESTARTING $UNIT (reason: $reason, pid=$PID); forensics in $DUMP"
          systemctl restart "$UNIT"
          rm -f "$FAILFILE"
          # A manual restart zeroes NRestarts; drop the loop baseline with it so
          # the next pass re-seeds instead of reading a negative delta.
          rm -f "$WINDOW"
        }

        # ---- 1. Is it even supposed to be running, and is it? -----------------
        ACTIVE=$(systemctl is-active "$UNIT" 2>/dev/null || true)
        if [ "$ACTIVE" != "active" ]; then
          rm -f "$FAILFILE"
          DOWN_N=$(( $(cat "$DOWNFILE" 2>/dev/null || echo 0) + 1 ))
          echo "$DOWN_N" > "$DOWNFILE"
          echo "WARNING: $UNIT is $ACTIVE ($DOWN_N/2 consecutive)"
          # 2 consecutive (~2 min) so a legitimate restart in flight — including
          # one this canary just issued — cannot page.
          [ "$DOWN_N" -ge 2 ] || exit 0

          DOWN_TEXT=$(cat <<EOF
claude-failover-proxy is $ACTIVE. EVERY opencode Claude request is failing.

opencode's google-vertex-anthropic baseURL points at 127.0.0.1:8789, so with
nothing listening every request is an immediate ECONNREFUSED, surfaced as:
  AI_APICallError: Cannot connect to API: Unable to connect.

The unit is Restart=always with no start limit, so if it is still down it was
either stopped deliberately or it cannot start at all.

To fix (on cloudbox):
  sudo systemctl start claude-failover-proxy
  journalctl -u claude-failover-proxy -n 50 --no-pager

Precedent: 2026-08-06, dead 36 minutes, discovered only by sessions breaking.
EOF
)
          ${driftAlert} "$STATE/down-alerted" "down:$ACTIVE" "$DOWN_TEXT" 900 14400
          exit 0
        fi
        rm -f "$DOWNFILE" "$STATE/down-alerted"

        # ---- 2. Restart-loop detection ----------------------------------------
        # This replaces the StartLimitBurst we deliberately removed: the unit now
        # retries forever, so the loop must be LOUD instead of terminal.
        NR=$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || true)
        case "$NR" in
          ""|*[!0-9]*)
            echo "WARNING: could not read NRestarts for $UNIT (unknown; not alerting)"
            ;;
          *)
            W_TS=""; W_NR=""
            # Guarded by -f, NOT by `2>/dev/null` on the redirect: bash reports a
            # failed input redirection on the SHELL's stderr before it applies
            # the command's own 2>/dev/null, so the missing-file case would spam
            # the journal on the very first pass.
            if [ -f "$WINDOW" ]; then
              { read -r W_TS; read -r W_NR; } < "$WINDOW" || true
            fi
            case "$W_TS" in ""|*[!0-9]*) W_TS="" ;; esac
            case "$W_NR" in ""|*[!0-9]*) W_NR="" ;; esac
            # Re-seed the window when it is missing, older than 15 minutes, or
            # when NRestarts went BACKWARDS (a manual restart or a reboot zeroes
            # it, and a negative delta would otherwise wedge the detector).
            if [ -z "$W_TS" ] || [ -z "$W_NR" ] || [ "$((NOW - W_TS))" -ge 900 ] || [ "$NR" -lt "$W_NR" ]; then
              printf '%s\n%s\n' "$NOW" "$NR" > "$WINDOW"
            else
              DELTA=$((NR - W_NR))
              if [ "$DELTA" -ge 5 ]; then
                echo "WARNING: $UNIT restarted $DELTA times in the last $((NOW - W_TS))s"
                LOOP_TEXT=$(cat <<EOF
claude-failover-proxy is restart-looping: $DELTA restarts in $((NOW - W_TS))s.

It is Restart=always with startLimitIntervalSec=0, so it will keep retrying
every 5s forever rather than landing in the failed state. That is deliberate,
but it
means a genuinely broken start is INVISIBLE without this alert. Sessions are
likely seeing intermittent connection failures against 127.0.0.1:8789.

Diagnose (on cloudbox):
  journalctl -u claude-failover-proxy -n 100 --no-pager
  systemctl status claude-failover-proxy

Usual suspects: unreadable /run/secrets/teamclaude_api_key or
/run/secrets/anthropic_enterprise_api_key (the ExecStart shim is set -e), or a
bad cfp binary from a package bump.
EOF
)
                ${driftAlert} "$STATE/loop-alerted" "loop:$W_TS" "$LOOP_TEXT" 900 14400
              fi
            fi
            ;;
        esac

        # ---- 3. Liveness probe -------------------------------------------------
        BODY_FILE=$(mktemp)
        trap 'rm -f "$BODY_FILE"' EXIT

        HTTP_CODE=$(curl -s --max-time 5 --connect-timeout 3 -o "$BODY_FILE" -w "%{http_code}" \
          "http://127.0.0.1:$PORT/stats")
        CURL_EXIT=$?

        # 3a. No HTTP response at all: frozen loop or dead-but-active process.
        if [ "$CURL_EXIT" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" -eq 0 ]; then
          THRESHOLD=3
          FAILS=$(( $(cat "$FAILFILE" 2>/dev/null || echo 0) + 1 ))
          echo "$FAILS" > "$FAILFILE"
          echo "WARNING: $UNIT failed /stats ($FAILS/$THRESHOLD consecutive timeouts/failures)"
          # 3 rather than the door's 2: a cfp restart drops in-flight LLM legs
          # and loses the in-memory session->tier stickiness map, so one extra
          # minute of confirmation is cheap insurance against a flap.
          if [ "$FAILS" -ge "$THRESHOLD" ]; then
            capture_and_restart "no response on /stats"
          fi
          exit 0
        fi

        # 3b. 200 with a parseable body: healthy.
        if [ "$HTTP_CODE" -eq 200 ]; then
          UPTIME=$(jq -r 'if .uptimeSeconds == null then "" else .uptimeSeconds end' "$BODY_FILE" 2>/dev/null || echo "")
          case "$UPTIME" in
            ""|*[!0-9.]*)
              # Answered, so the loop is alive — but we could not read it.
              # Unknown never alerts.
              echo "WARNING: /stats returned 200 but uptimeSeconds was unparseable (unknown; not alerting)"
              ;;
            *)
              : # healthy
              ;;
          esac
          rm -f "$FAILFILE"
          exit 0
        fi

        # 3c. Anything else: the loop answered, so it is not wedged.
        echo "WARNING: unexpected /stats HTTP status: $HTTP_CODE (loop alive, not restarting)"
        rm -f "$FAILFILE"
        exit 0
      ''}";
    };
  };

  systemd.timers.claude-failover-proxy-canary = {
    description = "Minutely claude-failover-proxy liveness canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "15s";
    };
  };

  # opencode-frontdoor — the opaque single-port reverse proxy and session-sticky
  # router for the OpenCode serve pool (§7 isolation kit). It is a stateless
  # single point of failure (SPOF) that binds only to localhost on port 4700
  # (FRONTDOOR_PORT=4700). It features its own MemoryMax ceiling and a dedicated
  # /healthz canary (Task 6.4). Auto-starts on boot, but is completely safe to
  # run because nothing points at it until Phase 7.
  systemd.services.opencode-frontdoor = {
    description = "opencode-frontdoor (opaque single-port reverse proxy for the serve pool)";

    # Auto-starts on boot. Safe to run now because nothing points at it until Phase 7.
    wantedBy = [ "multi-user.target" ];

    # DM5/M6: Order after network, pigeon-daemon, and the serve-pool target.
    # Use wants (SOFT deps) only. Do NOT use requires: the front door must still
    # start and gracefully DEGRADE-TO-ANCHOR when pigeon is down (that graceful
    # degrade is a core design invariant; a hard requires would defeat it).
    after = [ "network.target" "pigeon-daemon.service" "opencode-serve-pool.target" ];
    wants = [ "pigeon-daemon.service" "opencode-serve-pool.target" ];

    # Never let `nixos-rebuild switch` restart this unit on a config change:
    # a restart would briefly drop long-lived SSE streams, dropping client
    # connections mid-turn. This is safe because the front door is stateless
    # and resolves targets dynamically. The new definition/package applies on the
    # next reboot or an EXPLICIT `sudo systemctl restart opencode-frontdoor.service`.
    # Later deploy procedure will rebuild, restart, then verify `/healthz`.
    restartIfChanged = false;

    serviceConfig = {
      Type = "simple";
      User = "dev";
      Group = "dev";
      Environment = [
        "FRONTDOOR_PORT=4700"
        "PIGEON_DAEMON_URL=http://127.0.0.1:4731"
        # frontdoor-exempt(C3): the door's own upstream; it cannot proxy through itself
        "OPENCODE_ANCHOR_URL=http://127.0.0.1:4096"
        # eon4: pool-invariant `global-ro` reads (the `poolSafe` entries in
        # routes.classification.ts) round-robin across the WHOLE pool instead of
        # concentrating every session-less read on the anchor. Concentration is
        # what made a burst of TUI attaches blow the door's cheap-first-byte
        # budget and return 503 (333 of them on 2026-07-30, still 22 on
        # 2026-08-01 after the caller-side retry landed).
        #
        # Derived from serve-pool.nix — the same single source of truth the serve
        # units and pigeon read — so this list cannot drift from the ports that
        # actually exist. Do NOT hand-write it.
        #
        # Unset => anchor-only, i.e. exactly the pre-eon4 behaviour. That is what
        # lets this env change and the door rebuild land in either order.
        #
        # NB no `frontdoor-exempt` marker: the opacity guard counts LITERAL
        # serve addresses, and this value is interpolated from serve-pool.nix, so
        # the guard does not see a site here. Adding a marker anyway would break
        # its 1:1 site:marker anti-laundering check. (The exemption is real in
        # spirit — these are the door's own upstreams, C3 — it simply has no site
        # to attach to.)
        "FRONTDOOR_POOL_URLS=${servePool.endpointsCsv}"
        # Builtins-only app (no framework reads NODE_ENV) — set for convention/
        # consistency with pigeon-daemon and to future-proof any added dependency.
        "NODE_ENV=production"
      ];
      ExecStart = "${opencode-frontdoor}/bin/opencode-frontdoor";
      Restart = "always";
      RestartSec = 5;

      # Memory cap: stream holder (≈1.5G). Deliberately set NO MemoryHigh because,
      # as noted in the monitoring-serve-pool skill rationale, a soft high limit
      # can cause the kernel to throttle and freeze the loop (creating a wedge).
      # Max-only ensures a clean OOM kill + rapid restart recovery (~10s).
      MemoryMax = "1500M";

      # Bounds shutdown: the app has no graceful-drain SIGTERM handler today, so
      # SIGTERM terminates promptly and in-flight SSE connections drop (clients
      # reconnect). This bound is a safety backstop against any future graceful
      # handler hanging indefinitely on never-ending SSE streams.
      TimeoutStopSec = "15s";

      # Raise file descriptor limit: the door doubles connection count (one client
      # socket + one upstream socket per proxied request). With ~900 concurrent
      # connections, we need at least ~1800+ fds, so raise ceiling well above
      # the default to avoid running out of descriptors.
      LimitNOFILE = 65536;
    };
  };

  # This is the front door's own §7-isolation-kit canary (independently restartable SPOF).
  # This timer probes the frontdoor's native /healthz on localhost (3s timeout) once a
  # minute; after 2 consecutive failures it dumps near-instant forensics
  # (/proc status/wchan/syscall + cgroup memory.*) to /var/lib/opencode-frontdoor-canary/
  # and restarts the service. Runs as root (system service).
  systemd.services.opencode-frontdoor-canary = {
    description = "opencode-frontdoor liveness canary (restart wedged front doors)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "opencode-frontdoor-canary";
      ExecStart = "${pkgs.writeShellScript "opencode-frontdoor-canary" ''
        set -u
        # System-service PATH is minimal — be explicit.
        # We include coreutils, systemd, util-linux, curl, gnugrep, gnused, findutils, and jq.
        # Deep stack dumps (the serve canary's `eu-stack` native-stack loop and its 2s `cpu-io-split` sample) are omitted to ensure fast recovery.
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.util-linux pkgs.curl pkgs.gnugrep pkgs.gnused pkgs.findutils pkgs.jq ]}

        # Serve HTTP Basic credentials for the F4 cross-probe below
        # (workstation-km5f). Resolved at call time so a rotated secret needs no
        # restart of this unit.
        source "${opencode-serve-auth-sh}"
        serve_auth_load

        STATE=/var/lib/opencode-frontdoor-canary
        UNIT=opencode-frontdoor.service
        PORT=4700
        FAILFILE="$STATE/fails"
        SICKFILE="$STATE/sick"

        # Only police units that are supposed to be up. Intentional stops,
        # crash-loop backoff, etc. reset the counters.
        if [ "$(systemctl is-active "$UNIT")" != "active" ]; then
          rm -f "$FAILFILE" "$SICKFILE" "$STATE/drift-pending"
          exit 0
        fi

        # We omit the `/tmp/reset-workspace.lock` check because the nightly reset
        # does not stop/restart the front door, and the no-`-f` probe already
        # tolerates backend bounces.

        # Refactored forensics capture and restart function.
        # The front door is a single point of failure (SPOF) for all opencode access.
        # We do NOT include deep stack checks to minimize time-to-recovery.
        capture_and_restart() {
          # Default the reason under `set -u` so a future arg-less call can't crash recovery.
          local reason="''${1:-unknown}"
          TS=$(date +%Y%m%dT%H%M%S)
          DUMP="$STATE/wedge-$TS"
          mkdir -p "$DUMP"

          # Bound persistent forensics: keep only the 10 newest wedge dumps.
          ls -dt "$STATE"/wedge-* 2>/dev/null | tail -n +11 | xargs -r rm -rf || true

          PID=$(systemctl show "$UNIT" -p MainPID --value)
          CG=$(systemctl show "$UNIT" -p ControlGroup --value)
          if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            for f in status wchan syscall; do
              cat "/proc/$PID/$f" > "$DUMP/$f" 2>/dev/null || true
            done
            # Per-thread kernel wait channels.
            for t in /proc/$PID/task/*/; do
              [ -d "$t" ] || continue  # skip the literal glob if the process just died
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

          echo "RESTARTING $UNIT (reason: $reason, pid=$PID); forensics in $DUMP"
          # Synchronous; blocks up to the door unit's TimeoutStopSec (15s) if the
          # wedged process is slow to die. Acceptable — we're already wedged.
          systemctl restart "$UNIT"
          rm -f "$FAILFILE" "$SICKFILE"
        }

        BODY_FILE=$(mktemp)
        trap 'rm -f "$BODY_FILE"' EXIT

        # Probe the native /healthz WITHOUT -f, capturing both body and HTTP status.
        #
        # Coupling note: The canary's --max-time (5s) MUST exceed the front door's
        # FRONTDOOR_ROUTE_TIMEOUT_MS (default 3000ms) so a healthy-but-degraded 503
        # (both backends slow) is still read as alive; only a true frozen loop /
        # dead process (no response within 5s) counts as a wedge. (If
        # FRONTDOOR_ROUTE_TIMEOUT_MS is ever raised on the door unit, this must be
        # raised too.)
        HTTP_CODE=$(curl -s --max-time 5 --connect-timeout 3 -o "$BODY_FILE" -w "%{http_code}" "http://127.0.0.1:$PORT/healthz")
        CURL_EXIT=$?

        # 1. No HTTP response (curl failed: connection refused or timeout — frozen-loop or dead-process)
        if [ "$CURL_EXIT" -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" -eq 0 ]; then
          rm -f "$SICKFILE"

          THRESHOLD=2
          FAILS=$(( $(cat "$FAILFILE" 2>/dev/null || echo 0) + 1 ))
          echo "$FAILS" > "$FAILFILE"
          echo "WARNING: $UNIT failed /healthz ($FAILS/$THRESHOLD consecutive timeouts/failures)"

          if [ "$FAILS" -ge "$THRESHOLD" ]; then
            capture_and_restart "no response"
          fi
          exit 0
        fi

        # 2. HTTP 200 -> healthy
        if [ "$HTTP_CODE" -eq 200 ]; then
          rm -f "$FAILFILE" "$SICKFILE"

          # Check pigeon auth and aggregate degrade signals (dx8p Stage 1, Task 8)
          PIGEON_OK=$(jq -r 'if .pigeon == null then "missing" else .pigeon end' "$BODY_FILE" 2>/dev/null || echo "false")
          DEGRADED=$(jq -r 'if .degraded == null then "missing" else .degraded end' "$BODY_FILE" 2>/dev/null || echo "true")
          NOT_ROUTED_MUTATIONS=$(jq -r 'if .notRoutedMutationToAnchor == null then -1 else .notRoutedMutationToAnchor end' "$BODY_FILE" 2>/dev/null || echo "-1")

          if [ "$PIGEON_OK" != "true" ]; then
            echo "WARNING: /healthz reports pigeon is unreachable or unauthenticated (pigeon=$PIGEON_OK)"
          fi
          if [ "$DEGRADED" = "true" ]; then
            echo "WARNING: /healthz reports DEGRADED mode active"
          fi
          if [ "$NOT_ROUTED_MUTATIONS" -gt 0 ]; then
            echo "WARNING: /healthz reports $NOT_ROUTED_MUTATIONS mutating request(s) degraded to anchor (notRoutedMutationToAnchor)"
          fi

          # Pigeon anonymous endpoint auth probe (dx8p Stage 1, Task 8)
          # If pigeon token secret exists on cloudbox (/run/secrets/pigeon_daemon_auth_token), assert anonymous requests 401
          if [ -f "/run/secrets/pigeon_daemon_auth_token" ]; then
            P_SESSIONS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:4731/sessions" || echo "000")
            P_INBOX=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:4731/swarm/inbox" || echo "000")
            P_ROUTE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:4731/route" || echo "000")
            P_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:4731/health" || echo "000")

            if [ "$P_SESSIONS" -ne 401 ]; then
              echo "WARNING: pigeon anonymous GET /sessions returned $P_SESSIONS (expected 401)"
            fi
            if [ "$P_INBOX" -ne 401 ]; then
              echo "WARNING: pigeon anonymous GET /swarm/inbox returned $P_INBOX (expected 401)"
            fi
            if [ "$P_ROUTE" -ne 401 ]; then
              echo "WARNING: pigeon anonymous GET /route returned $P_ROUTE (expected 401)"
            fi
            if [ "$P_HEALTH" -ne 200 ]; then
              echo "WARNING: pigeon anonymous GET /health returned $P_HEALTH (expected 200)"
            fi
          fi

          # Version-drift check (F7/F9/F-D6)
          # Parse version out of the body: {"status":"ok","degraded":...,"version":"/nix/store/..."}
          RUNNING_VER=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$BODY_FILE" | sed -n 's/.*"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/p')
          EXECSTART_FULL=$(systemctl show "$UNIT" -p ExecStart --value)
          EXECSTART_PATH=$(echo "$EXECSTART_FULL" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')

          # Both sides must be KNOWN before comparing. RUNNING_VER was already guarded;
          # EXECSTART_PATH was NOT, and it has the same hole the serve canary had
          # (bead workstation-bcmi): if the sed stops matching — a systemd ExecStart
          # format change, or a transient `systemctl show` failure — EXECSTART_PATH is
          # empty, the case falls through to *), and the canary reports "version drift"
          # against an empty execstart. This canary alerts UNCONDITIONALLY (no
          # dangerous-only gating), so that becomes a Telegram page on the 2nd pass
          # telling the operator to restart a door that is perfectly healthy. A format
          # change would make it page forever on the 24h TTL. Unknown must never alert.
          if [ -z "$RUNNING_VER" ]; then
            echo "WARNING: could not parse version from /healthz response"
          elif [ -z "$EXECSTART_PATH" ]; then
            echo "WARNING: could not parse ExecStart path for $UNIT; treating as unknown (no alert). Raw: $EXECSTART_FULL"
          else
            case "$EXECSTART_PATH" in
              "$RUNNING_VER"*)
                # Clear throttle file and dampening counter ONLY on confirmed resolution (paths match).
                # Do NOT clear on unparseable /healthz (unknown state could flap and storm).
                rm -f "$STATE/drift-alerted" "$STATE/drift-pending"
                ;;
              *)
                echo "WARNING: version drift: running=$RUNNING_VER execstart=$EXECSTART_PATH"
                DRIFT_PENDING=$(( $(cat "$STATE/drift-pending" 2>/dev/null || echo 0) + 1 ))
                echo "$DRIFT_PENDING" > "$STATE/drift-pending"

                if [ "$DRIFT_PENDING" -ge 2 ]; then
                  DRIFT_TEXT=$(cat <<EOF
opencode-frontdoor is running stale code.

To fix, run:
sudo systemctl restart opencode-frontdoor

IMPORTANT: Also check the serve pool! Restarting only the front door creates dangerous version skew if serves remain on old code.
See Deploy Runbook: .opencode/skills/rebuilding/SKILL.md

Running store path: $RUNNING_VER
Installed store path: $EXECSTART_PATH

Note: Restarting opencode-frontdoor drops in-flight SSE legs so pick an appropriate moment to restart.
EOF
)
                  # Throttled Telegram alert via Pigeon (2026-07-24 incident recovery).
                  # Auto-restart is intentionally omitted: restarting frontdoor drops all
                  # in-flight SSE connections and routing state, turning minor drift into an
                  # outage. A human decides when to restart.
                  # Dampened to alert only after 2 consecutive minutely passes showing drift.
                  # Backoff base 15m, cap 4h. This is the exact call site that produced ONE
                  # page across 12h39m of continuous, correct detection on 2026-07-26.
                  ${driftAlert} "$STATE/drift-alerted" "$RUNNING_VER|$EXECSTART_PATH" "$DRIFT_TEXT" 900 14400
                fi
                ;;
            esac
          fi
          exit 0
        fi

        # 3. HTTP 503 -> F4 cross-probe
        if [ "$HTTP_CODE" -eq 503 ]; then
          # Probe the anchor directly (mirroring door's OPENCODE_ANCHOR_URL = http://127.0.0.1:4096)
          # frontdoor-exempt(C4): canary must tell 'door down' from 'pool down'; through the door they look alike
          ANCHOR_CODE=$(curl -s --max-time 5 --connect-timeout 3 -o /dev/null -w "%{http_code}" \
            ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
            "http://127.0.0.1:4096/global/health")

          # The question this probe answers is "did the anchor ANSWER?", which is
          # what separates door-side sickness from a real backend outage. A 401
          # answers it just as well as a 200 -- the serve is up and serving HTTP.
          #
          # Treating 401 as "down" here would be quietly destructive rather than
          # loud (workstation-km5f): the else-branch below declares "both backends
          # genuinely down" and `rm -f`s BOTH counters, so an armed pool with a
          # stale canary credential would permanently disable door-side-sickness
          # recovery AND reset the door's wedge counter every single minute,
          # suppressing the detector this whole unit exists to provide.
          if [ "$ANCHOR_CODE" -eq 200 ] || [ "$ANCHOR_CODE" -eq 401 ]; then
            if [ "$ANCHOR_CODE" -eq 401 ]; then
              echo "NOTICE: anchor answered 401 (alive, but this canary's serve credential was rejected); treating as reachable for the door-vs-pool verdict"
            fi
            # Anchor is healthy directly, but door says 503 -> door-side sickness!
            # Reset wedge counter since the door's loop is alive
            rm -f "$FAILFILE"

            SICK_THRESHOLD=2 # 2 consecutive ≈ 2 min. A live-traffic SPOF shouldn't sit sick.
            SICK=$(( $(cat "$SICKFILE" 2>/dev/null || echo 0) + 1 ))
            echo "$SICK" > "$SICKFILE"
            echo "WARNING: door reports 503 but anchor healthy directly ($SICK/$SICK_THRESHOLD consecutive): door-side sickness"

            if [ "$SICK" -ge "$SICK_THRESHOLD" ]; then
              capture_and_restart "door-side sickness (anchor healthy but door reports 503)"
            fi
          else
            # Both unreachable directly -> genuine backend outage, not door's fault
            rm -f "$FAILFILE" "$SICKFILE"
            echo "both backends genuinely down (anchor unreachable directly too, status=$ANCHOR_CODE); door alive, not restarting"
          fi
          exit 0
        fi

        # 4. Any other status -> loop is alive, log unexpected status
        echo "WARNING: unexpected /healthz HTTP status: $HTTP_CODE (loop alive, not restarting)"
        rm -f "$FAILFILE" "$SICKFILE"
        exit 0
      ''}";
    };
  };

  systemd.timers.opencode-frontdoor-canary = {
    description = "Minutely OpenCode frontdoor liveness canary";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "15s";
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
        # sessionVariables for rationale). The restarted serve pool must hit
        # the same DB the interactive sessions use.
        "OPENCODE_DB=/home/dev/.local/share/opencode/opencode.db"
        "OPENCODE_DISABLE_CHANNEL_DB=1"
        # This oneshot already runs in its own system-slice cgroup, so it does
        # NOT need reset-workspace's `systemd-run --user --scope` survival
        # re-exec. Skipping it also removes a failure mode: a full runtime tmpfs
        # (/run/user/1000) makes every `systemd-run --user` fail with ENOSPC,
        # which would hard-exit the whole nightly run before any reset work
        # happened (2026-07 devbox outage). See pkgs/reset-workspace.
        "RESET_WORKSPACE_NO_DETACH=1"
      ];
    };
    script = ''
      # Restart pigeon-daemon (system unit) FIRST so every session created
      # after the reset registers with a fresh daemon.
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
  # A FOD's impureEnvVars are read from the environment of WHATEVER PROCESS
  # performs the build (see the NIX_REMOTE=daemon block just below for why that
  # matters). We REUSE the existing github_api_token secret (verified: it reads
  # the private cfp release asset, HTTP 200) rather than minting a second PAT; a
  # sops template wraps its raw value in the KEY=VALUE form EnvironmentFile
  # requires. The '-' prefix makes the file optional so the daemon still starts
  # if sops hasn't rendered it yet (early boot); restartUnits bounces the daemon
  # once it's (re)rendered.
  sops.templates."nix-daemon-github-token" = {
    content = "GITHUB_TOKEN=${config.sops.placeholder.github_api_token}";
    restartUnits = [ "nix-daemon.service" ];
  };
  systemd.services.nix-daemon.serviceConfig.EnvironmentFile =
    [ "-${config.sops.templates."nix-daemon-github-token".path}" ];

  # ...but putting the token in the DAEMON env is only HALF the fix: it reaches
  # the FOD build sandbox only when the DAEMON is the builder. `dev` (non-root)
  # can't write the store, so its builds are delegated to the daemon -> token
  # applies. ROOT, however, OWNS the store, so `sudo nixos-rebuild` builds the
  # FOD LOCALLY in the root process, whose env (sudo strips it) carries NO
  # GITHUB_TOKEN -> empty netrc password -> GitHub 404 on the private asset.
  # (Root cause proven end-to-end 2026-06-24, bead workstation-306j. This is NOT
  # the daemon-token-absence / "switch builds before it activates" bootstrap
  # story previously believed here; `systemctl restart nix-daemon` and
  # `nix-store --add-fixed` do NOT fix it.) Fix: force root's nix builds through
  # the daemon too by exporting NIX_REMOTE=daemon for every sudo command, so the
  # repo-documented `sudo nixos-rebuild switch` self-serves the private fetch.
  # env_file is global to sudo, which is harmless: NIX_REMOTE only affects nix
  # tools, and routing root's nix ops through the daemon is the normal
  # multi-user behavior. (Any other host that fetches private-asset FODs would
  # need both this and the EnvironmentFile token above.)
  environment.etc."nix-remote-daemon.env".text = "NIX_REMOTE=daemon\n";
  security.sudo.extraConfig = ''
    Defaults env_file = /etc/nix-remote-daemon.env
  '';

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
    # which doesn't need the plugin set -- but note that it re-tripped this
    # very landmine once (workstation-v8t5): the bare neovim escaped the unit
    # into tmux panes oc-auto-attach created for it. That `path` now lists
    # /home/dev/.nix-profile ahead of pkgs.neovim so the wrapper wins.
    gh gnupg pinentry-curses
    nodejs  # For pigeon
    xorg.xvfb  # Provides `Xvfb`; prebuilt Cypress spawns it for headless e2e
    # teamclaude CLI on PATH so Max-account management is a plain `teamclaude
    # login` / `teamclaude accounts` (no store-path resolution). Resolves to the
    # module-level `teamclaude` let-binding above (same derivation the
    # teamclaude.service runs); there is no `pkgs.teamclaude`, so the let-binding
    # wins over `with pkgs;`. Config/tokens live in ~/.config/teamclaude.json.
    teamclaude
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
