# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
{ config, pkgs, lib, localPkgs, assetsPath, isDarwin, projects, ... }:

let
  servePool = (import ./serve-pool.nix).forHost.darwin;
  routingDbPath = "/Users/jonathan.mohrbacher/Code/pigeon/packages/daemon/data/pigeon-daemon.db";

  sshTunnelCommand = host: ''
    while true; do
      echo "$(${pkgs.coreutils}/bin/date -Is) starting ${host} tunnel" >&2
      ${pkgs.openssh}/bin/ssh \
        -N \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o IgnoreUnknown=UseKeychain \
        ${host}
      status=$?
      echo "$(${pkgs.coreutils}/bin/date -Is) ${host} tunnel exited with status $status; retrying in 10s" >&2
      ${pkgs.coreutils}/bin/sleep 10
    done
  '';
in
lib.mkIf isDarwin {
  home.file = {
    # Darwin common.conf - empty (no special options needed locally)
    ".gnupg/common.conf".text = "";

    # gclpr clipboard bridge trusted keys (macOS server)
    ".gclpr/trusted".text = "122dcc14fa37068a2d604a736279c32f9aa1a38958a76f292f61812421544670\n";
  };

  # Screenshot-to-devbox script (macOS only, uses screencapture + pbcopy)
  # Note: No runtimeInputs for openssh - we want the system SSH which supports UseKeychain
  home.packages = [
    (pkgs.writeShellScriptBin "opencode-serve-pool-restart" ''
      # Generated from serve-pool.nix
      ${lib.concatStringsSep "\n" (lib.imap0 (i: _: ''
        launchctl kickstart -k "gui/$(id -u)/org.nix-community.home.opencode-serve-${toString i}"
      '') servePool.ports)}
    '')
    (pkgs.writeShellApplication {
      name = "screenshot-to-devbox";
      text = builtins.readFile "${assetsPath}/scripts/screenshot-to-devbox.sh";
    })
    pkgs.google-cloud-sdk
    pkgs.cloudflared
    # teamclaude CLI (multi-account Claude Max rotator). Needed for interactive
    # `teamclaude login` / `teamclaude accounts`; the launchd agent below runs the
    # server. Nix-packaged (pkgs/teamclaude, platforms = unix), zero runtime deps.
    localPkgs.teamclaude
    (pkgs.writeShellApplication {
      name = "pigeon-setup-secrets";
      text = ''
        echo "Populating macOS Keychain with pigeon secrets."
        echo "Enter each secret value when prompted."
        echo ""

        secrets=(
          "pigeon-ccr-api-key"
          "pigeon-telegram-bot-token"
          "pigeon-telegram-chat-id"
        )

        for name in "''${secrets[@]}"; do
          printf "  %s: " "$name"
          read -r value
          # Delete existing entry if present (ignore errors)
          security delete-generic-password -s "$name" 2>/dev/null || true
          security add-generic-password -a "$USER" -s "$name" -w "$value"
          echo "  Stored $name in Keychain"
        done

        echo ""
        echo "Done. You can now start the pigeon daemon:"
        echo "  launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/org.nix-community.home.pigeon-daemon.plist"
      '';
    })
  ];

  # Cloudflare Tunnel launchd agent with Keychain-sourced token
  launchd.agents = {
    cloudflared-ccr = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            TUNNEL_TOKEN="$(/usr/bin/security find-generic-password -s cloudflared-tunnel-token -w)"
            exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
          ''
        ];
        RunAtLoad = false;  # Start manually, not at login
        KeepAlive = false;  # Don't auto-restart
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudflared-ccr.err.log";
      };
    };

    # Pigeon daemon launchd agent — secrets from macOS Keychain
    # Run `pigeon-setup-secrets` once in a terminal to populate Keychain
    pigeon-daemon = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            SEC="/usr/bin/security"
            export CCR_WORKER_URL="$($SEC find-generic-password -s ccr-worker-url -w)"
            export CCR_API_KEY="$($SEC find-generic-password -s pigeon-ccr-api-key -w)"
            export TELEGRAM_BOT_TOKEN="$($SEC find-generic-password -s pigeon-telegram-bot-token -w)"
            export TELEGRAM_CHAT_ID="$($SEC find-generic-password -s pigeon-telegram-chat-id -w)"
            cd "${config.home.homeDirectory}/Code/pigeon/packages/daemon"
            exec ${pkgs.nodejs}/bin/node \
              "${config.home.homeDirectory}/Code/pigeon/node_modules/tsx/dist/cli.mjs" \
              src/index.ts
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          NODE_ENV = "production";
          CCR_MACHINE_ID = "macbook";
          OPENCODE_URL = "http://127.0.0.1:4096";
          PIGEON_SERVE_ENDPOINTS = servePool.endpointsCsv;
          PIGEON_SERVE_LIVENESS = "self";
          PIGEON_DAEMON_DB_PATH = routingDbPath;
          # workstation-debug: widen the heartbeat-staleness window before a serve
          # is flagged "dead". opencode serve is single-threaded; a CPU-heavy turn
          # (or GC/swap stall) blocks its event loop and starves the 5s heartbeat
          # fiber, so the default 15s falsely declares a live, busy serve dead and
          # ServeHealthPoller.sweepStale → reassignFromDeadServe migrates its
          # sessions (churn + historically killed in-flight runs). The real fix is
          # pigeon-side (reassignFromDeadServe now skips sessions whose lease is
          # still valid); this is defense-in-depth churn reduction. CEILING: keep
          # <= serveLeaseTtl(30s) − serveRenewInterval(10s) = 20s, else a dead
          # serve can linger in listHealthy past its lease expiry and get re-picked.
          PIGEON_SERVE_STALE_MS = "20000";
          # /model provider allowlist. macbook has Vertex creds connected, so opt
          # this machine into the two Vertex families on top of the
          # anthropic/openai default. (devbox has no Vertex creds and keeps the
          # default.) Parsed by packages/daemon/src/config.ts.
          PIGEON_ALLOWED_PROVIDERS = "anthropic,openai,google-vertex,google-vertex-anthropic";
          # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
          # sessionVariables for rationale). pigeon revive spawns opencode that
          # must hit the same DB; a launchd agent doesn't source ~/.profile.
          # macOS data dir = ~/.local/share/opencode (xdg-basedir fallback).
          OPENCODE_DB = "${config.home.homeDirectory}/.local/share/opencode/opencode.db";
          OPENCODE_DISABLE_CHANNEL_DB = "1";
          PATH = lib.concatStringsSep ":" [
            "${pkgs.nodejs}/bin"
            "${pkgs.neovim}/bin"
            "/usr/bin"
            "/bin"
          ];
        };
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pigeon-daemon.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pigeon-daemon.err.log";
      };
    };

    # Persistent SSH tunnels for development port forwarding.
    # Keeps LocalForward ports (dev servers, OAuth callbacks) and RemoteForward
    # ports (CDP, chatgpt-relay) alive without a dedicated terminal tab.
    # Uses the *-tunnel SSH hosts defined in update-ssh-config.sh.
    devbox-dev-tunnel = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh"
          "-c"
          (sshTunnelCommand "devbox-tunnel")
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StartInterval = 30;  # Safety net if activation leaves the agent loaded but idle
        ThrottleInterval = 120;  # Outlast server-side ClientAliveInterval cleanup (~90s)
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/devbox-dev-tunnel.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/devbox-dev-tunnel.err.log";
      };
    };

    cloudbox-dev-tunnel = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh"
          "-c"
          (sshTunnelCommand "cloudbox-tunnel")
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StartInterval = 30;  # Safety net if activation leaves the agent loaded but idle
        ThrottleInterval = 120;  # Outlast server-side ClientAliveInterval cleanup (~90s)
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/cloudbox-dev-tunnel.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudbox-dev-tunnel.err.log";
      };
    };

    # gclpr clipboard server.
    # Exposes macOS pbcopy/pbpaste over signed TCP so remote sessions (via SSH
    # RemoteForward) can copy/paste to the local clipboard through mosh.
    gclpr-server = {
      enable = true;
      config = {
        ProgramArguments = [
          "${localPkgs.gclpr}/bin/gclpr"
          "server"
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          LANG = "en_US.UTF-8";
          LC_CTYPE = "en_US.UTF-8";
        };
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 30;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/gclpr-server.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gclpr-server.err.log";
      };
    };

    # codex-lb (ChatGPT/Codex rotator) — darwin/launchd flavor of the systemd
    # unit in codex-lb.nix (which is NixOS-only). Opt-in per host: the wrapper
    # exits 0 when the marker is absent, and KeepAlive.SuccessfulExit=false means
    # launchd does NOT respawn a clean exit — so no marker => stays down; marker
    # present => runs, and a crash (non-zero) is restarted. Bootstrap:
    #   1. touch ~/.codex-lb/enabled
    #   2. launchctl kickstart -k gui/$(id -u)/org.nix-community.home.codex-lb
    #   3. open http://127.0.0.1:2455 and log in ChatGPT account(s)
    #   4. darwin-rebuild switch  (wires opencode via injectCodexLbBaseUrlDarwin)
    codex-lb = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            [ -e "$HOME/.codex-lb/enabled" ] || exit 0
            exec ${pkgs.uv}/bin/uvx --from codex-lb==1.20.1 codex-lb --host 127.0.0.1 --port 2455
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          # bare launchd service has no CA bundle -> httpx CERTIFICATE_VERIFY_FAILED
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          # uvx-generated wrapper shells out to realpath/dirname
          PATH = lib.concatStringsSep ":" [ "${pkgs.coreutils}/bin" "/usr/bin" "/bin" ];
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.err.log";
      };
    };

    # teamclaude (Claude Max rotator) — darwin/launchd flavor of the systemd unit
    # in home.devbox.nix. Same opt-in wrapper pattern as codex-lb. Marker is the
    # config file itself, created by interactive `teamclaude login`. Bootstrap:
    #   1. teamclaude login    # PKCE OAuth, needs TTY + browser; repeat per account
    #   2. launchctl kickstart -k gui/$(id -u)/org.nix-community.home.teamclaude
    #   3. darwin-rebuild switch  (wires opencode via injectTeamclaudeBaseUrlDarwin)
    teamclaude = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            [ -e "$HOME/.config/teamclaude.json" ] || exit 0
            exec ${localPkgs.teamclaude}/bin/teamclaude server --headless
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          TEAMCLAUDE_CONFIG = "${config.home.homeDirectory}/.config/teamclaude.json";
          PATH = "/usr/bin:/bin";
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/teamclaude.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/teamclaude.err.log";
      };
    };
  } // (builtins.listToAttrs (lib.imap0 (i: port: {
    name = "opencode-serve-${toString i}";
    value = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.writeShellScript "opencode-serve-start-${toString i}" ''
            export HOME="${config.home.homeDirectory}"
            # mn9r M2: pin opencode.db to one absolute file (see home.base.nix
            # sessionVariables for rationale). A launchd agent doesn't source
            # ~/.profile, so the sessionVariables copy doesn't reach it.
            export OPENCODE_DB="${config.home.homeDirectory}/.local/share/opencode/opencode.db"
            export OPENCODE_DISABLE_CHANNEL_DB=1
            export PATH="${lib.concatStringsSep ":" [
              "${pkgs.git}/bin"
              "${pkgs.openssh}/bin"
              "${pkgs.fzf}/bin"
              "${pkgs.ripgrep}/bin"
              "${pkgs.gh}/bin"
              "${pkgs.bun}/bin"
              "/etc/profiles/per-user/${config.home.username}/bin"
              "/usr/bin"
              "/bin"
            ]}"

            # GitHub API token from macOS Keychain
            GH_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" \
              && export GH_TOKEN="$GH_TOKEN_VAL"

            # Google Vertex AI: project from Keychain, ADC from gcloud config
            GCP_VAL="$(/usr/bin/security find-generic-password -s google-cloud-project -w 2>/dev/null)" \
              && export GOOGLE_CLOUD_PROJECT="$GCP_VAL"
            export GOOGLE_APPLICATION_CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"
            export GOOGLE_CLOUD_LOCATION="global"

            # mn9r M5/M4 activation: each serve runs the per-session lease CAS against
            # pigeon's routing DB (the SAME file as pigeon's PIGEON_DAEMON_DB_PATH, DM5-1).
            export OPENCODE_ROUTING_DB="${routingDbPath}"
            export OPENCODE_SERVE_ID="serve-${toString i}"

            exec opencode serve --port ${toString port} --hostname 127.0.0.1
          ''}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve-${toString i}.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opencode-serve-${toString i}.err.log";
      };
    };
  }) servePool.ports));

  # Bash (Darwin-specific layer on top of home.base.nix).
  programs.bash = {
    # Homebrew bash (used by iTerm2 Custom Command) doesn't have SYS_BASHRC
    # compiled in, so it skips /etc/bashrc for non-login interactive shells.
    # Source it explicitly to pick up nix-darwin's set-environment (PATH with
    # /etc/profiles/per-user/$USER/bin, TERMINFO_DIRS, XDG_*, etc.).
    # mkBefore so it runs before home.base.nix's initExtra and the
    # mkAfter block below (Keychain reads depend on /usr/bin/security on PATH).
    initExtra = lib.mkMerge [
      (lib.mkBefore ''
        if [ -z "$__ETC_BASHRC_SOURCED" ] && [ -r /etc/bashrc ]; then
          source /etc/bashrc
        fi
      '')
      (lib.mkAfter ''
      # GitHub API token for gh CLI (from macOS Keychain)
      GH_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" && export GH_TOKEN="$GH_TOKEN_VAL"
      unset GH_TOKEN_VAL

      # DoltHub REST API token for creating DoltHub databases (from macOS Keychain)
      DOLTHUB_VAL="$(/usr/bin/security find-generic-password -s dolthub-api-token -w 2>/dev/null)" && export DOLTHUB_API_TOKEN="$DOLTHUB_VAL"
      unset DOLTHUB_VAL

      # Atlassian config (from macOS Keychain)
      ATLASSIAN_SITE_VAL="$(/usr/bin/security find-generic-password -s atlassian-site -w 2>/dev/null)" && export ATLASSIAN_SITE="$ATLASSIAN_SITE_VAL"
      unset ATLASSIAN_SITE_VAL

      ATLASSIAN_EMAIL_VAL="$(/usr/bin/security find-generic-password -s atlassian-email -w 2>/dev/null)" && export ATLASSIAN_EMAIL="$ATLASSIAN_EMAIL_VAL"
      unset ATLASSIAN_EMAIL_VAL

      ATLASSIAN_CLOUD_ID_VAL="$(/usr/bin/security find-generic-password -s atlassian-cloud-id -w 2>/dev/null)" && export ATLASSIAN_CLOUD_ID="$ATLASSIAN_CLOUD_ID_VAL"
      unset ATLASSIAN_CLOUD_ID_VAL

      # Atlassian API token for nvim Atlassian commands (from macOS Keychain)
      ATLASSIAN_VAL="$(/usr/bin/security find-generic-password -s atlassian-api-token -w 2>/dev/null)" && export ATLASSIAN_API_TOKEN="$ATLASSIAN_VAL"
      unset ATLASSIAN_VAL

      # BuildBuddy CLI + bb-test-log helper (from macOS Keychain).
      # BUILDBUDDY_HOST is the org-branded subdomain (no scheme, no path),
      # BUILDBUDDY_API_KEY is the org read API key. Provision with:
      #   security add-generic-password -a "$USER" -s buildbuddy-host -w 'your-org.buildbuddy.io'
      #   security add-generic-password -a "$USER" -s buildbuddy-api-key -w 'YOUR_KEY'
      BUILDBUDDY_HOST_VAL="$(/usr/bin/security find-generic-password -s buildbuddy-host -w 2>/dev/null)" && export BUILDBUDDY_HOST="$BUILDBUDDY_HOST_VAL"
      unset BUILDBUDDY_HOST_VAL

      BUILDBUDDY_API_KEY_VAL="$(/usr/bin/security find-generic-password -s buildbuddy-api-key -w 2>/dev/null)" && export BUILDBUDDY_API_KEY="$BUILDBUDDY_API_KEY_VAL"
      unset BUILDBUDDY_API_KEY_VAL

      # Azure DevOps PAT for private artifact registry (from macOS Keychain)
      AZDO_VAL="$(/usr/bin/security find-generic-password -s azure-devops-pat -w 2>/dev/null)" && export SYSTEM_ACCESSTOKEN="$AZDO_VAL"
      unset AZDO_VAL
      if [ -n "$SYSTEM_ACCESSTOKEN" ]; then
        export ADO_NPM_PAT_B64="$(printf '%s' "$SYSTEM_ACCESSTOKEN" | base64)"
      fi

      # GCP project for Vertex AI (from macOS Keychain)
      GCP_VAL="$(/usr/bin/security find-generic-password -s google-cloud-project -w 2>/dev/null)" && export GOOGLE_CLOUD_PROJECT="$GCP_VAL"
      unset GCP_VAL

      # Bundler private gem source credentials (from macOS Keychain)
      BUNDLE_VAL="$(/usr/bin/security find-generic-password -s bundle-gem-fury-io -w 2>/dev/null)" && export BUNDLE_GEM__FURY__IO="$BUNDLE_VAL"
      unset BUNDLE_VAL
      BUNDLE_VAL="$(/usr/bin/security find-generic-password -s bundle-enterprise-contribsys-com -w 2>/dev/null)" && export BUNDLE_ENTERPRISE__CONTRIBSYS__COM="$BUNDLE_VAL"
      unset BUNDLE_VAL
      BUNDLE_VAL="$(/usr/bin/security find-generic-password -s bundle-gems-graphql-pro -w 2>/dev/null)" && export BUNDLE_GEMS__GRAPHQL__PRO="$BUNDLE_VAL"
      unset BUNDLE_VAL
      # Vendor-encoded private gem source: Bundler env var name is
      # BUNDLE_<HOST_UPPER_WITH_DOTS_AS_DOUBLE_UNDERSCORES>. Compose dynamically
      # from a Keychain-stored host so the vendor name doesn't appear in source.
      # Provision with:
      #   security add-generic-password -a "$USER" -s bundle-source-host  -w 'fury.example.com'
      #   security add-generic-password -a "$USER" -s bundle-source-token -w 'TOKEN'
      _bundle_host="$(/usr/bin/security find-generic-password -s bundle-source-host -w 2>/dev/null)"
      _bundle_token="$(/usr/bin/security find-generic-password -s bundle-source-token -w 2>/dev/null)"
      if [ -n "$_bundle_host" ] && [ -n "$_bundle_token" ]; then
        _bundle_var="BUNDLE_$(printf '%s' "$_bundle_host" | tr '[:lower:]' '[:upper:]' | sed 's/\./__/g')"
        export "$_bundle_var=$_bundle_token"
        unset _bundle_var
      fi
      unset _bundle_host _bundle_token

      # Datadog CLI credentials (from macOS Keychain): Personal Access Token
      # (DD_PAT, Bearer auth).
      export DD_SITE="us3.datadoghq.com"
      DD_PAT_VAL="$(/usr/bin/security find-generic-password -s dd-pat -w 2>/dev/null)" && export DD_PAT="$DD_PAT_VAL"
      unset DD_PAT_VAL

      # ba CLI credentials (from macOS Keychain)
      # GITHUB_API_TOKEN is the GoBA token ba uses for self-updates (same token as GH_TOKEN)
      GITHUB_API_TOKEN_VAL="$(/usr/bin/security find-generic-password -s github-api-token -w 2>/dev/null)" && export GITHUB_API_TOKEN="$GITHUB_API_TOKEN_VAL"
      unset GITHUB_API_TOKEN_VAL
      JENKINS_API_TOKEN_VAL="$(/usr/bin/security find-generic-password -s jenkins-api-token -w 2>/dev/null)" && export JENKINS_API_TOKEN="$JENKINS_API_TOKEN_VAL"
      unset JENKINS_API_TOKEN_VAL
      JENKINS_USER_VAL="$(/usr/bin/security find-generic-password -s jenkins-user -w 2>/dev/null)" && export JENKINS_USER="$JENKINS_USER_VAL"
      unset JENKINS_USER_VAL
    '')
    ];
    shellAliases = {
      ssdb = "screenshot-to-devbox";
    };
  };

  # SSH: manages .ssh/config
  programs.ssh.enable = lib.mkForce false;

  home.sessionVariables = {
    # Enable Exa AI-backed websearch and codesearch tools in OpenCode.
    # These call mcp.exa.ai with no API key (free tier). If rate-limited (429),
    # obtain a free key at exa.ai and set OPENCODE_ENABLE_EXA=https://mcp.exa.ai/mcp?exaApiKey=<key>
    OPENCODE_ENABLE_EXA = "1";
  };

  # On Darwin, dotfiles creates symlinks that HM also wants to manage.
  # Remove dotfiles symlinks before HM tries to create its own.
  # Also clean up renamed/removed skills and commands.
  home.activation.ensureProjects = let
    mkLine = name: p: ''
      ensure_repo ${lib.escapeShellArg name} ${lib.escapeShellArg p.url}
    '';
    lines = lib.concatStringsSep "\n" (lib.mapAttrsToList mkLine projects);
  in lib.hm.dag.entryAfter ["writeBoundary"] ''
    ensure_repo() {
      local name="$1"
      local url="$2"
      local dir="${config.home.homeDirectory}/Code/$name"

      if [ -d "$dir/.git" ]; then
        return 0
      fi

      echo "Cloning $name to ~/Code ..."
      GIT_SSH_COMMAND="/usr/bin/ssh" ${pkgs.git}/bin/git clone --recursive "$url" "$dir"
    }

    mkdir -p "${config.home.homeDirectory}/Code"
    ${lines}

    # Post-clone: install pigeon dependencies
    if [ -d "${config.home.homeDirectory}/Code/pigeon" ] && [ ! -d "${config.home.homeDirectory}/Code/pigeon/node_modules" ]; then
      echo "Installing pigeon dependencies ..."
      (cd "${config.home.homeDirectory}/Code/pigeon" && PATH="${pkgs.nodejs}/bin:$PATH" ${pkgs.nodejs}/bin/npm install)
    fi

    # Check if pigeon Keychain secrets are populated
    if ! /usr/bin/security find-generic-password -s pigeon-ccr-api-key -w >/dev/null 2>&1; then
      echo ""
      echo "⚠ Pigeon Keychain secrets not found. Run: pigeon-setup-secrets"
      echo ""
    fi
  '';

  # Deploy the shared DoltHub credential used by `bd dolt push/pull` to back up
  # the git-free beads issue DB (remote configured in .beads/config.yaml). macOS
  # has no sops, so the Ed25519 JWK keypair lives in the Keychain. Populate it
  # once with (the value is the single-line JWK from ~/.dolt/creds/<keyid>.jwk):
  #   security add-generic-password -a "$USER" -s dolthub-jwk -w '<jwk-json>'
  # This writes a real 0600 ~/.dolt/creds/<keyid>.jwk and points
  # config_global.json at it. Skips cleanly if the Keychain entry is absent.
  home.activation.deployDoltCreds = lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] ''
    set -euo pipefail

    keyid="6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve"
    jwk="$(/usr/bin/security find-generic-password -s dolthub-jwk -w 2>/dev/null || true)"

    if [ -z "$jwk" ]; then
      echo "deployDoltCreds: skipping (dolthub-jwk not in Keychain; run: security add-generic-password -a \"\$USER\" -s dolthub-jwk -w '<jwk-json>')"
    else
      creds_dir="$HOME/.dolt/creds"
      mkdir -p "$creds_dir"

      tmp="$(mktemp "$creds_dir/$keyid.jwk.tmp.XXXXXX")"
      printf '%s' "$jwk" > "$tmp"
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

  home.activation.prepareForHM = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
    if [ -L ~/.bashrc ]; then rm -f ~/.bashrc; fi
    if [ -L ~/.bash_profile ]; then rm -f ~/.bash_profile; fi
    if [ -L ~/.profile ]; then rm -f ~/.profile; fi
    if [ -L ~/.bashrc.d ]; then rm -f ~/.bashrc.d; fi
    rm -f ~/.gnupg/gpg.conf 2>/dev/null || true
    rm -f ~/.gnupg/gpg-agent.conf 2>/dev/null || true
    rm -f ~/.gnupg/dirmngr.conf 2>/dev/null || true
    rm -f ~/.gnupg/common.conf 2>/dev/null || true
    # Neovim: remove dotfiles-managed files before HM takes over
    rm -f ~/.config/nvim/init.lua 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/user 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/config 2>/dev/null || true
    rm -rf ~/.config/nvim/lua/plugins 2>/dev/null || true
    rm -f ~/.config/nvim/lua/ccremote.lua 2>/dev/null || true
    rm -f ~/.config/nvim/lua/pigeon.lua 2>/dev/null || true
    rm -f ~/.bazelrc 2>/dev/null || true
  '';

  home.activation.startDevTunnels = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    for agent in devbox-dev-tunnel cloudbox-dev-tunnel; do
      /bin/launchctl kickstart -k "gui/$UID/org.nix-community.home.$agent" 2>/dev/null || true
    done
  '';

  # Tmux extra config (disable if you have existing tmux config)
  # Uncomment if tmux conflicts:
  # xdg.configFile."tmux/extra.conf".enable = lib.mkForce false;

  # Auto-expire old home-manager generations (same as Linux)
  services.home-manager.autoExpire = {
    enable = true;
    frequency = "daily";
    timestamp = "-7 days";
    store.cleanup = true;
  };
}
