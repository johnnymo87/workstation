# macOS-specific home-manager configuration
# Contains Darwin-only scripts, aliases, and settings
{ config, pkgs, lib, localPkgs, assetsPath, isDarwin, projects, ... }:

let
  servePool = (import ./serve-pool.nix).forHost.darwin;
  routingDbPath = "/Users/jonathan.mohrbacher/Code/pigeon/packages/daemon/data/pigeon-daemon.db";

  # Keepalive loop behind the tunnel LaunchAgents.
  #
  # `fallbackHost` is an alternate ssh host alias for the SAME tunnel on a
  # different transport. cloudbox reaches sshd through an IAP ProxyCommand; if
  # that keeps failing we alternate to the direct-to-public-IP alias, so a
  # Google-side IAP outage degrades instead of taking the tunnel down. devbox
  # has one transport and passes nothing.
  #
  # `iapConfig` is the isolated CLOUDSDK_CONFIG holding the tunnel service
  # account, used only to tell an expired/broken credential apart from a network
  # or transport fault.
  #
  # Failures are CLASSIFIED because the previous version could not say why it was
  # retrying, and the outage that motivated this work (a rotated WARP egress IP
  # silently blackholing the direct path) looked identical in the log to a laptop
  # sleep. Nobody noticed for hours -- it surfaced as "copy-paste is broken".
  # Hence also the notification: a tunnel that is down and not coming back should
  # say so rather than retry into an unwatched log forever.
  sshTunnelCommand = { host, fallbackHost ? null, iapConfig ? null }: ''
    state_file="${config.home.homeDirectory}/Library/Logs/${host}.state"
    fails=0
    delay=10
    target="${host}"

    while true; do
      started=$(${pkgs.coreutils}/bin/date +%s)
      echo "$(${pkgs.coreutils}/bin/date -Is) starting ${host} tunnel via $target" >&2
      echo "$(${pkgs.coreutils}/bin/date -Is) connecting via $target" > "$state_file"

      ${pkgs.openssh}/bin/ssh \
        -N \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o IgnoreUnknown=UseKeychain \
        "$target"
      status=$?
      elapsed=$(( $(${pkgs.coreutils}/bin/date +%s) - started ))

      # A connection that stayed up a while was healthy, so its exit is an
      # ordinary drop -- Mac sleep accounts for ~35 of these a day -- and must
      # not inherit a long backoff or count toward the failure streak.
      if [ "$elapsed" -ge 60 ]; then
        fails=0
        delay=10
      else
        fails=$(( fails + 1 ))
      fi

      # Ordered cheapest-and-most-likely first; each answer changes what a human
      # would do next, which is the only reason to distinguish them.
      if ! ${pkgs.curl}/bin/curl -s -m 10 -o /dev/null https://oauth2.googleapis.com/ ; then
        class="network (no route to Google; laptop asleep, offline, or VPN down)"
    ${lib.optionalString (iapConfig != null) ''
      elif ! env CLOUDSDK_CONFIG="${iapConfig}" ${pkgs.google-cloud-sdk}/bin/gcloud auth print-access-token >/dev/null 2>&1; then
        class="auth (IAP service-account credential is not usable; key may have expired)"
    ''}
      else
        class="transport (network and credential fine; ssh/IAP itself failed)"
      fi

      echo "$(${pkgs.coreutils}/bin/date -Is) ${host} via $target exited status=$status after $elapsed""s; class=$class; consecutive=$fails; retry in $delay""s" >&2
      echo "$(${pkgs.coreutils}/bin/date -Is) down via $target status=$status class=$class consecutive=$fails" > "$state_file"

      # Notify once per streak, at the point where this stops looking transient.
      if [ "$fails" -eq 3 ]; then
        /usr/bin/osascript -e "display notification \"$class\" with title \"${host} is down\" subtitle \"3 consecutive failures via $target\"" >/dev/null 2>&1 || true
      fi

    ${lib.optionalString (fallbackHost != null) ''
      # Alternate transports once a single failure is not explaining itself. Two
      # failures is deliberately early: the fallback is cheap to try and the cost
      # of staying on a dead transport is every forwarded service.
      if [ "$fails" -ge 2 ]; then
        if [ "$target" = "${host}" ]; then
          target="${fallbackHost}"
        else
          target="${host}"
        fi
      fi
    ''}

      ${pkgs.coreutils}/bin/sleep "$delay"
      delay=$(( delay * 2 ))
      if [ "$delay" -gt 60 ]; then delay=60; fi
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
    # What the `mosh` alias actually runs. Exists to force
    # --experimental-remote-ip=local.
    #
    # mosh 1.4.0 defaults to `proxy` mode, in which it injects its OWN
    # `--fake-proxy` ProxyCommand onto the ssh COMMAND LINE. A command-line
    # ProxyCommand beats ssh_config, so the IAP ProxyCommand on the cloudbox
    # blocks is silently discarded and mosh dials the public IP directly -- it
    # keeps working right up until the WARP egress rotates, then fails in a way
    # that looks nothing like its cause. `local` mode leaves ssh_config alone.
    #
    # The catch, and the reason update-ssh-config.sh keys the cloudbox block on
    # `cloudbox <IP>` rather than `cloudbox`: in `local` mode mosh resolves the
    # host and hands ssh the literal IP, so a block keyed only on the name never
    # matches. Rather than hardcode the IP here, ask ssh what it resolves to --
    # `ssh -G` applies the real config, so this stays correct when the IP
    # changes and works for any host alias, not just cloudbox.
    (pkgs.writeShellScriptBin "mosh-via-ssh-config" ''
      set -eu
      # Option-shaped (or absent) first argument: the caller is driving mosh
      # directly and knows what they want. Get out of the way.
      case "''${1-}" in
        -*|"") exec ${pkgs.mosh}/bin/mosh "$@" ;;
      esac
      host="$1"; shift
      cfg=$(${pkgs.openssh}/bin/ssh -G "$host")
      ip=$(${pkgs.gawk}/bin/awk '$1=="hostname"{print $2; exit}' <<<"$cfg")
      user=$(${pkgs.gawk}/bin/awk '$1=="user"{print $2; exit}' <<<"$cfg")
      if [ -z "$ip" ]; then
        echo "mosh-via-ssh-config: ssh -G $host resolved no hostname" >&2
        exit 1
      fi
      # MOSH_SERVER_NETWORK_TMOUT: reap servers abandoned by a client that never
      # came back, each of which otherwise holds a pty and a UDP port forever.
      exec ${pkgs.mosh}/bin/mosh \
        --experimental-remote-ip=local \
        --server="MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server" \
        "$user@$ip" "$@"
    '')

    pkgs.google-cloud-sdk
    pkgs.cloudflared
    # Hetzner Cloud CLI: used by scripts/update-ssh-config.sh to resolve the
    # devbox IP, and by the setting-up-hetzner / troubleshooting-nixos-host
    # skills for server management (resize, rescue, reboot).
    pkgs.hcloud
    # teamclaude CLI (multi-account Claude Max rotator). Needed for interactive
    # `teamclaude login` / `teamclaude accounts`; the launchd agent below runs the
    # server. Nix-packaged (pkgs/teamclaude, platforms = unix), zero runtime deps.
    localPkgs.teamclaude
    # Seeds the PRIVATE cfp release asset into the store. MUST be run before a
    # `darwin-rebuild switch` that picks up a new cfp version, because this Mac
    # has no GITHUB_TOKEN anywhere the builder can see and the failed fetch
    # takes the whole system build down with it, not just cfp. Idempotent.
    localPkgs.cfp-prefetch-darwin
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
          # frontdoor-exempt(D2): no front door on darwin; :4096 is the only endpoint that exists
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
          (sshTunnelCommand { host = "devbox-tunnel"; })
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
          (sshTunnelCommand {
            host = "cloudbox-tunnel";
            fallbackHost = "cloudbox-tunnel-direct";
            iapConfig = "${config.home.homeDirectory}/.config/gcloud-tunnel/config";
          })
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StartInterval = 30;  # Safety net if activation leaves the agent loaded but idle
        ThrottleInterval = 120;  # Outlast server-side ClientAliveInterval cleanup (~90s)
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/cloudbox-dev-tunnel.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudbox-dev-tunnel.err.log";
      };
    };

    # `oc-tags serve` chart, at http://127.0.0.1:4710 on this Mac.
    #
    # SOCKET-ACTIVATED, unlike the two tunnels above -- launchd owns :4710 and
    # spawns one `ssh -W` per accepted connection, so nothing is connected while
    # nobody is looking at the chart. The persistent-tunnel shape was built and
    # measured first; the numbers are in the commit message. Summary: this costs
    # ~+0.5s on a page load that is otherwise ~0.5s, and buys the removal of an
    # idle connection, a keepalive loop, and the failure mode below.
    #
    # Why not just add `LocalForward 4710` to the `cloudbox-tunnel` block above?
    # Not because that block is remote-only -- it already carries
    # `LocalForward 3334`, and devbox-tunnel carries six -- but because :4710
    # has plausible LOCAL colliders where 3334 has none: a muscle-memory
    # `ssh -N cloudbox-chart`, or an `oc-tags serve` started on this Mac. That
    # block runs under ExitOnForwardFailure=yes, where one bind clash aborts the
    # whole ssh process and takes gclpr (2850), chatgpt-relay (3033) and the
    # Jenkins forward (8443) down with the chart. Same hazard as LocalForward
    # 1455, which update-ssh-config.sh gives exclusively to devbox-tunnel.
    #
    # Socket activation also improves how a collision fails. A keepalive agent
    # would lose the bind and then reconnect to a public-IP VM every ~10s
    # forever, into an unrotated log, while whatever holds the port kept serving
    # the browser well enough that nothing looked wrong. launchd instead fails
    # the bind once, at load, and stops.
    #
    # The tradeoff is that it does NOT come back by itself: where the keepalive
    # loop would reclaim :4710 on its next retry once the collider exited, this
    # stays down until re-bootstrapped (bootout + bootstrap, or another
    # switch). troubleshooting-nixos-host/SKILL.md carries the recovery command.
    #
    # `-W` implies ClearAllForwardings, so the `LocalForward 4710` in the
    # cloudbox-chart ssh block is ignored here and cannot fight launchd for the
    # port. That block stays as the manual fallback (`ssh -N cloudbox-chart`).
    #
    # SockNodeName pins the listener to loopback -- omitting it would bind every
    # interface and publish the chart to the network. It is IPv4-literal because
    # every path we document (README, skills, this file) says 127.0.0.1.
    # `localhost` still works: it may try ::1 first and get refused, but clients
    # fall back to 127.0.0.1 (measured: 200, just slower for the wasted attempt).
    #
    # The far end need not be up. The remote dial happens per-connection, so a
    # stopped `oc-tags serve` shows as a reset / empty response, NOT connection
    # refused -- refused would mean this listener itself is gone.
    cloudbox-chart-tunnel = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.openssh}/bin/ssh"
          "-o" "BatchMode=yes"          # no tty here; a prompt would hang the browser's connection
          "-o" "ConnectTimeout=10"
          "-o" "IgnoreUnknown=UseKeychain"  # parity with sshTunnelCommand: nix ssh aborts on unknown
                                            # config keys, so this keeps a future UseKeychain line in
                                            # the ssh config from killing the chart but not the tunnels
          "-W" "127.0.0.1:4710"
          "cloudbox-chart"
        ];
        inetdCompatibility = { Wait = false; };
        Sockets = {
          Listeners = {
            SockNodeName = "127.0.0.1";
            SockServiceName = "4710";
            SockType = "stream";
            SockFamily = "IPv4";
          };
        };
        # No RunAtLoad/KeepAlive/ThrottleInterval: launchd runs this on demand,
        # and each instance is meant to exit when its connection closes.
        #
        # StandardErrorPath is load-bearing, not logging garnish. In nowait
        # inetd mode launchd hands the accepted socket to stdin, stdout AND
        # stderr, so without this redirect ssh's own chatter ("Connection reset
        # by peer", host-key warnings) would be written into the HTTP response
        # and corrupt the chart. Deliberately no StandardOutPath: stdout must
        # stay the socket, which is how the reply reaches the browser.
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/cloudbox-chart-tunnel.err.log";
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
            # --python 3.13, and the version pin: see codex-lb.nix, which holds
            # the rationale for BOTH flavors. KEEP THE VERSION HERE IN SYNC WITH
            # IT — these are two copies of one decision, and they drifted once
            # already (this flavor sat on 1.20.1 with the retired aiohttp<3.14
            # pin after the NixOS side moved to 1.24.0).
            exec ${pkgs.uv}/bin/uvx --python 3.13 --with 'aiohttp<3.15' --from codex-lb==1.24.0 codex-lb --host 127.0.0.1 --port 2455
          ''
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          # bare launchd service has no CA bundle -> httpx CERTIFICATE_VERIFY_FAILED
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          # uvx-generated wrapper shells out to realpath/dirname
          PATH = lib.concatStringsSep ":" [ "${pkgs.coreutils}/bin" "/usr/bin" "/bin" ];
          # Upstream defaults telemetry ON; off here for the same reason as the
          # NixOS flavor (see codex-lb.nix).
          CODEX_LB_TELEMETRY_ENABLED = "false";
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codex-lb.err.log";
      };
    };

    # teamclaude (Claude Max rotator) — darwin/launchd flavor of the systemd unit
    # in home.devbox.nix. Same opt-in wrapper pattern as codex-lb.
    #
    # THE GATE IS `teamclaude-seeded`, NOT FILE EXISTENCE. This wrapper used to
    # test `[ -e "$HOME/.config/teamclaude.json" ]`, which is not the same
    # question: teamclaude writes a default config with `accounts: []` on almost
    # any CLI invocation, including at the top of `teamclaude login` BEFORE the
    # OAuth flow. So an aborted login left a file that passed the test while the
    # server exited 1 -- and with `KeepAlive.SuccessfulExit = false` below,
    # launchd respawns a non-zero exit, so this WOULD BE an unbounded respawn
    # loop (launchd's default ThrottleInterval is 10s) appending "No accounts
    # configured" to the error log forever. Stated from the specs of the two
    # mechanisms, not from an observation on a Mac -- nothing here can watch
    # that host. Exiting 0 instead is a clean "nothing to do" that KeepAlive
    # does not retry.
    #
    # NOTE THIS ONLY NARROWS THE LOOP, it does not remove it. The check reads
    # the config file; an account list that is non-empty but whose entries are
    # all disabled or unusable still gets past it, and the server still exits 1
    # at runtime and still respawns forever. Only a zero-length list is covered.
    #
    # `teamclaude-seeded` is the single shared implementation of that check --
    # the devbox unit's ExecCondition and injectTeamclaudeBaseUrlDarwin call the
    # same binary, so the three sites cannot drift apart again. Bootstrap:
    #   1. teamclaude login    # PKCE OAuth, needs TTY + browser; repeat per account
    #   2. launchctl kickstart -k gui/$(id -u)/org.nix-community.home.teamclaude
    #   3. darwin-rebuild switch  (wires opencode via injectTeamclaudeBaseUrlDarwin)
    teamclaude = {
      enable = true;
      config = {
        ProgramArguments = [
          "/bin/sh" "-c"
          ''
            ${localPkgs.teamclaude}/bin/teamclaude-seeded || exit 0
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

    # claude-failover-proxy (cfp) -- darwin/launchd flavor of the cloudbox
    # systemd unit in hosts/cloudbox/configuration.nix.
    #
    # WHAT IT BUYS ON THIS MAC, specifically: measured over 30 days, every
    # single day's Opus traffic here went out as
    # `google-vertex-anthropic/claude-opus-5@default` -- 76-136 messages/day
    # straight to work-billed Vertex. cfp puts the personal Max pool in front of
    # that lane (CFP_OPUS_MAX_FIRST) while leaving Fable on Vertex, which is the
    # cheaper tenant for each. Fable volume here is ~3 days in 14, far below the
    # $100 gate, so the budget/enterprise machinery below essentially never
    # fires on this host -- it is carried for parity with cloudbox, not because
    # it binds.
    #
    # VERTEX LEG IS DIRECT, not via an aigateway. cloudbox points
    # CFP_AIGATEWAY_URL at a loopback cost-capture proxy; a laptop has none, and
    # tunnelling to cloudbox's was rejected deliberately -- this Mac must not
    # depend on cloudbox at runtime. The cost is that Mac Claude traffic does
    # not appear in that per-request ledger; cfp's own spend.json/stats.json
    # still meter it, which is what the budget gate actually reads.
    #
    # An HTTPS upstream only works at all because of cfp's C1 fix (v0.9.3,
    # `out.delete('host')` in sanitizeRequestHeaders): Bun's fetch honours a
    # caller-supplied Host for TLS SNI, so forwarding the inbound
    # `127.0.0.1:8789` made every HTTPS Vertex call fail certificate
    # verification. Invisible on cloudbox, which only ever talks plaintext
    # loopback. Do not "restore" header forwarding.
    #
    # The gate is `teamclaude-seeded`, the same marker binary the teamclaude
    # agent above uses -- a liveness probe would be the wrong shape here (see
    # the long comment there) and cfp without a Max pool is pointless anyway.
    claude-failover-proxy = {
      enable = true;
      config = {
        ProgramArguments = [
          "${pkgs.writeShellScript "claude-failover-proxy-start" ''
            set -u

            # No Max pool -> nothing to fail over TO. Exit 0 ("nothing to do")
            # rather than non-zero, which KeepAlive.SuccessfulExit=false would
            # respawn every 10s forever.
            ${localPkgs.teamclaude}/bin/teamclaude-seeded || exit 0

            # cfp REQUIRES this to be non-empty (config.ts throws otherwise) and
            # a throw here is exactly the unbounded-respawn shape described
            # above, so validate before exec'ing rather than after.
            #
            # Loopback callers are in fact exempt from teamclaude's key check,
            # so this is future-proofing against `proxy.trustLoopback: false`
            # rather than something the request path needs today.
            key="$(${pkgs.jq}/bin/jq -r '.proxy.apiKey // empty' \
              "${config.home.homeDirectory}/.config/teamclaude.json" 2>/dev/null || true)"
            if [ -z "$key" ]; then
              echo "cfp: no .proxy.apiKey in teamclaude.json; not starting" >&2
              exit 0
            fi
            export CFP_TEAMCLAUDE_API_KEY="$key"

            exec ${localPkgs.claude-failover-proxy}/bin/claude-failover-proxy
          ''}"
        ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          PATH = "/usr/bin:/bin";

          # Pinned for the same reason the teamclaude agent and both activations
          # pin it: this wrapper resolves `teamclaude-seeded` against a config
          # path, and if any of those four sites resolved a DIFFERENT file they
          # would disagree about whether a Max pool exists.
          TEAMCLAUDE_CONFIG = "${config.home.homeDirectory}/.config/teamclaude.json";

          CFP_LISTEN_HOST = "127.0.0.1";
          CFP_LISTEN_PORT = "8789";
          CFP_TEAMCLAUDE_URL = "http://127.0.0.1:3456";

          # Direct Vertex. cfp re-bases the inbound Vertex-shaped path onto this
          # origin and forwards the caller's Authorization verbatim, so
          # opencode's own ADC credentials do the authenticating.
          CFP_AIGATEWAY_URL = "https://aiplatform.googleapis.com";

          # Family-aware inversion: Opus to Max ahead of Vertex, leaving the
          # paid budget for Fable. Fable costs 2.0x Opus per dollar on Vertex
          # but drains the Max 5h bucket ~4.5x faster per weighted token.
          # ONLY the literal string "true" enables it (cfp warns and stays off
          # for anything else -- note CFP_DISABLE_BILLING_HEADER in the same
          # codebase uses "1", so the convention is not uniform). Roll back by
          # setting this to "false" and rebuilding.
          CFP_OPUS_MAX_FIRST = "true";

          CFP_BUDGET_DOLLARS = "100";
          CFP_IDLE_MIGRATE_SECONDS = "300";
          CFP_RESET_HOUR = "0";

          # PINNED, not inherited. cfp otherwise takes the system timezone
          # (Intl.DateTimeFormat), and this machine travels -- a timezone change
          # would silently move the ledger's day boundary, so the daily budget
          # would reset early or late depending on where you opened the laptop.
          CFP_TZ = "America/New_York";

          CFP_STATE_PATH = "${config.home.homeDirectory}/.local/state/claude-failover-proxy/spend.json";

          # CFP_ENTERPRISE_API_KEY is deliberately UNSET: the enterprise leg is
          # only reached once Vertex is over budget, which at this host's
          # measured volume never happens. cfp logs "enterprise tier: off" and
          # degrades cleanly. Revisit if /stats ever shows overBudget: true.
        };
        RunAtLoad = true;
        KeepAlive = { SuccessfulExit = false; };

        # Retry every 30s so the agent SELF-HEALS after the pool is first seeded.
        # Without this there is a real hole: the wrapper exits 0 when teamclaude
        # is unseeded, home-manager skips re-bootstrapping an agent whose plist
        # is unchanged, and nothing else starts it -- so the sequence
        # `teamclaude login` -> `darwin-rebuild switch` would leave activation
        # pointing opencode at :8789 (marker says seeded) while cfp is still not
        # running, and every Claude request would get ECONNREFUSED until someone
        # ran `launchctl kickstart` by hand. While unseeded this costs one exit-0
        # wrapper run per 30s; once cfp is up, launchd will not start a second
        # copy of a running agent. Same RunAtLoad+StartInterval combination the
        # devbox-dev-tunnel agent uses.
        StartInterval = 30;

        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/claude-failover-proxy.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-failover-proxy.err.log";
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

            # REGISTRY PORT FENCE (bead pigeon-13p) -- see the long rationale in
            # hosts/cloudbox/configuration.nix. Exported so children inherit this
            # slot's DECLARED port; a throwaway `opencode serve` spawned from a
            # session binds a different port and is refused (exit 20). Unset =
            # unarmed, so the binary release and this rebuild are order-independent.
            export OPENCODE_SERVE_EXPECTED_PORT="${toString port}"
            # REGISTRY PID FENCE (bead workstation-4b1q). The port fence above is
            # port-ONLY: it has no interface check, so a nested
            # `opencode serve --hostname ::1 --port <port>` binds alongside the real
            # serve on 127.0.0.1:<port>, passes the port fence, and claims the slot.
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
      # Jenkins hostname (org-identifying; see the reading-jenkins-builds skill).
      # Also read by scripts/update-ssh-config.sh for the cloudbox RemoteForward.
      JENKINS_HOST_VAL="$(/usr/bin/security find-generic-password -s jenkins-host -w 2>/dev/null)" && export JENKINS_HOST="$JENKINS_HOST_VAL"
      unset JENKINS_HOST_VAL
    '')
    ];
    shellAliases = {
      ssdb = "screenshot-to-devbox";
      # Why `mosh` is not the real mosh here: see mosh-via-ssh-config.
      mosh = "mosh-via-ssh-config";
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

  # cloudbox-chart-tunnel is deliberately NOT in this list: it is socket-
  # activated, so launchd starts it when something connects to :4710. Kick-
  # starting it would force-run an `ssh -W` with no accepted socket on stdin,
  # which just exits.
  #
  # The `timeout` is load-bearing, not defensive dressing. `kickstart -k` kills
  # the instance and then BLOCKS until launchd restarts it. On the first switch
  # after adding an agent, that was observed stalling activation for ~2 minutes
  # with no output explaining why.
  #
  # The stall duration matched ThrottleInterval (120s), and the likeliest
  # explanation is that the kill lands inside that window for an agent
  # setupLaunchAgents started seconds earlier. Treat that as unconfirmed: the
  # exact launchd behaviour here is not documented, and reproducing it means
  # kickstarting live tunnels. The bound does not depend on the diagnosis being
  # right -- whatever the cause, activation stops waiting, and KeepAlive plus
  # StartInterval bring the agent up within ~30-120s regardless.
  #
  # (`kickstart -p` is not the fix -- -p prints the new PID, it does not
  # detach, and awaiting a PID can block for longer rather than less.)
  home.activation.startDevTunnels = lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
    for agent in devbox-dev-tunnel cloudbox-dev-tunnel; do
      ${pkgs.coreutils}/bin/timeout 10 /bin/launchctl kickstart -k "gui/$UID/org.nix-community.home.$agent" 2>/dev/null || true
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
