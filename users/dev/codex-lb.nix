# codex-lb: multi-account ChatGPT/Codex rotator — the OpenAI/Codex analog of
# teamclaude. A local OpenAI-compatible proxy on 127.0.0.1:2455 that pools
# personal ChatGPT *subscription* OAuth accounts, injects the active account's
# token + chatgpt-account-id server-side, tracks per-account 5h/weekly quota, and
# fails over between accounts. opencode's first-party `openai` provider is pointed
# at it by `injectCodexLbBaseUrl` in opencode-config.nix (gated on the
# ~/.codex-lb/enabled opt-in marker below -- NOT on this unit being active, which
# raced sd-switch and stripped the baseURL; bead workstation-k03x), and the
# astra/sol/terra/luna subscription model catalog is injected there.
#
# HOSTS: devbox + cloudbox here (both NixOS/systemd). macOS runs codex-lb too,
# but through a SEPARATE launchd flavor in users/dev/home.darwin.nix — this file
# is `mkIf (isDevbox || isCloudbox)` and never evaluates there. THE VERSION PIN
# EXISTS IN BOTH PLACES and must be bumped in both; they drifted once already
# (darwin sat on 1.20.1 with the retired aiohttp pin after NixOS moved to
# 1.24.0). Everything below about why a pin or an env var is what it is applies
# to the darwin flavor too, which points back here rather than repeating it.
#
# Each host runs its OWN codex-lb instance with its OWN account logins;
# ~/.codex-lb is per-host runtime state, never synced.
#
# OPT-IN PER HOST (ConditionPathExists = %h/.codex-lb/enabled): the code is
# present on every gated host, but the service only starts where the marker file
# exists. This keeps an un-bootstrapped host from starting an *empty* codex-lb
# that injectCodexLbBaseUrl would then reroute opencode's `openai` provider into
# (breaking openai there until an account is logged in). devbox's marker is
# created automatically below (it is already bootstrapped). To enable a NEW host:
#   1. run codex-lb once by hand to bootstrap the store + log in an account via
#      the dashboard (SSH-forward 2455, browser OAuth). Both env vars matter:
#      without LD_LIBRARY_PATH, greenlet cannot load libstdc++.so.6 and startup
#      dies inside the SQLAlchemy session teardown with a misleading
#      "the greenlet library is required to use this function":
#        SSL_CERT_FILE=$(nix eval --raw nixpkgs#cacert)/etc/ssl/certs/ca-bundle.crt \
#        LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib \
#          uvx --python 3.13 --with 'aiohttp<3.15' --from codex-lb==1.24.0 codex-lb --host 127.0.0.1 --port 2455
#   2. touch ~/.codex-lb/enabled
#   3. systemctl --user start codex-lb   (and re-run home-manager switch to wire opencode)
#
# CLOUDBOX IS ENABLED TOO, by hand, via exactly that procedure. Only devbox's
# marker is created declaratively (below); cloudbox's was touched manually and
# is therefore invisible to this file. Do not read the `mkIf isDevbox` on the
# activation script as "cloudbox does not run codex-lb" — it does.
#
# RUN VIA uvx (not a nix package): codex-lb is a FastAPI + bun-SPA app; packaging
# it purely in Nix is a big lift, so we run the pinned PyPI release through uv's
# ephemeral-tool runner (cached under ~/.cache/uv). Bump the pin deliberately.
#
# FLOATING TRANSITIVE DEPS ARE A TIME BOMB: only codex-lb itself is pinned, so a
# host that re-resolves (fresh box, or a wiped ~/.cache/uv) can pick up newer
# deps than a long-running host and break in ways that look host-specific. Two
# such pins are encoded in ExecStart below; add more here as they bite.
#
#   --python 3.13   uvx otherwise grabs the newest interpreter on the box. That
#                   drifted to a 3.14 alpha on cloudbox.
#
#   aiohttp<3.15    A CEILING, not a workaround — see the history below. codex-lb
#                   declares `aiohttp>=3.13.4` with NO upper bound while still
#                   calling aiohttp private internals, and its own lock is
#                   3.14.3. Without a ceiling, a long-running host keeps the
#                   cached 3.14.3 while a fresh box or a wiped ~/.cache/uv
#                   floats to whatever aiohttp ships next — which is precisely
#                   the looks-host-specific breakage described below, and it has
#                   already happened once. Widen deliberately after checking
#                   that `_open_upstream_websocket` still matches the new
#                   aiohttp, not reflexively on the next bump.
#
# THE HISTORY, because the ceiling above is the scar tissue from it:
#
#   aiohttp<3.14    codex-lb 1.20.1 hand-rolled its upstream WebSocket upgrade
#                   against aiohttp PRIVATE internals (app/core/clients/proxy.py
#                   _open_upstream_websocket -> WebSocketDataQueue /
#                   WebSocketReader / WebSocketWriter). aiohttp 3.14.2 changed
#                   the Cython WebSocketReader.__init__ from 2 to 4 required
#                   positional args, so every streaming request died with
#                   `TypeError: __init__() takes exactly 4 positional arguments
#                   (2 given)`, surfaced to clients as a 502 `upstream_error`.
#                   Non-streaming paths (dashboard, /api/accounts, model
#                   refresh) kept working, which made this look like an auth
#                   problem rather than a dependency problem.
#
#                   Fixed upstream in codex-lb 1.22.0 (commit ed017d52, buried
#                   in a dependency-bump squash): the call now passes
#                   `compress=False, decode_text=True`. So the <3.14 ceiling is
#                   obsolete and was raised to <3.15 with the 1.24.0 bump — the
#                   ceiling was kept, not removed.
#
#                   Note the old pin was also mis-aimed: v1.20.1's own lock was
#                   already aiohttp 3.14.1, so the break was at 3.14.2, not
#                   3.14.0.
#
#                   THE UNDERLYING FRAGILITY REMAINS. `_open_upstream_websocket`
#                   still imports aiohttp private internals and still hand-rolls
#                   the Sec-WebSocket-Key challenge. It is reached on the
#                   DEFAULT direct-egress path whenever an HTTP request gets
#                   promoted to an upstream WebSocket, so it is not an exotic
#                   code path. Expect it to break again on some future aiohttp.
#
#                   3AM ESCAPE HATCH if it does, or for a WebSocket-502 storm:
#                   `CODEX_LB_UPSTREAM_STREAM_TRANSPORT=http` bypasses that
#                   function entirely. Untested here — do not flip it blind, but
#                   know it exists.
#
# CONFIG/STATE IS RUNTIME (NOT nix-managed): codex-lb reads + REWRITES
# ~/.codex-lb/ (store.db with accounts + OAuth tokens that auto-refresh, plus
# encryption.key), so it must stay writable + persistent and is LOST on a full
# reprovision.
#
# BUMPING THE PIN MIGRATES THE STORE, AND THE PIN ALONE DOES NOT ROLL BACK.
# codex-lb runs alembic migrations against ~/.codex-lb/store.db at startup; a
# newer version migrates the schema and an older version may then refuse to
# load it. Reverting this file gets you the old binary against a new store.
#
# You do NOT have to take the backup by hand: since 1.2x codex-lb writes its own
# consistent pre-migration snapshot via the sqlite backup API
# (`database_sqlite_pre_migrate_backup_enabled`, default true, keeps the last
# 5), landing as `~/.codex-lb/store.pre-migrate-<UTC timestamp>.db`. Verified
# present after the 1.20.1 -> 1.24.0 migration.
#
# ROLLBACK, therefore:
#   1. systemctl --user stop codex-lb
#   2. cp -f ~/.codex-lb/store.pre-migrate-<ts>.db ~/.codex-lb/store.db
#      (and remove store.db-wal / store.db-shm, which belong to the newer file)
#   3. revert the version in this file, home-manager switch
#   4. systemctl --user start codex-lb
#
# CAVEAT, suspected and unverified: OAuth refresh tokens rotate, and the
# snapshot holds whatever token was current at migration time. If enough time
# has passed the restored token may already be dead, in which case rollback
# costs you a re-login rather than being free. Roll back promptly or not at all.
#
# If you are taking a manual copy anyway, copy store.db + store.db-wal +
# store.db-shm + encryption.key together — store.db alone while the WAL is live
# is not a consistent snapshot.
#
# WHY 1.24.0 AND NOT NEWER: 1.24.0 is the latest STABLE. Everything after it is
# a 1.25.0-beta, which at the time of writing carries a dashboard RBAC/OIDC
# rewrite we do not want on a single-user loopback box.
#
# WHAT THE 1.20.1 -> 1.24.0 BUMP FIXED, concretely: on 1.20.1 our one account
# sat `status: deactivated`, `deactivationReason: "Usage API error: HTTP 404 -
# None"`, with `lastRefreshAt` frozen at 2026-08-30 — upstream moved the
# `backend-api/wham/usage` shape out from under the pinned version and the
# proxy quietly benched the account rather than failing loudly. 1.24.0 refreshes
# usage again. If this recurs, the symptom to look for is a frozen
# `lastRefreshAt` in `GET /api/accounts`, not an error in the log.
#
# THREE NixOS gotchas the env below fixes: (1) SSL_CERT_FILE — a bare user
# service has no CA bundle, so httpx/aiohttp can't verify chatgpt.com and every
# upstream call fails CERTIFICATE_VERIFY_FAILED; (2) PATH — the uvx-generated
# wrapper shells out to realpath/dirname, which need coreutils on PATH;
# (3) LD_LIBRARY_PATH — greenlet (via SQLAlchemy's async session) dlopens
# libstdc++.so.6, which a bare user service cannot find. Without it startup
# reaches "Application startup complete"'s neighbourhood and then dies in the
# session teardown with `ValueError: the greenlet library is required to use
# this function. libstdc++.so.6: cannot open shared object file`, which reads
# like a missing Python package rather than a missing C++ runtime.
#
# BIND + PRIVACY: bound to 127.0.0.1 explicitly (--host); neither box opens 2455
# in its firewall. opencode connects via 127.0.0.1 (auth-exempt on codex-lb), so
# no proxy API key is needed locally.
#
# QUOTA EXHAUSTION LOOKS LIKE A TRANSPORT BUG, AND `astra-probe` EXISTS FOR IT.
# When the only pooled account's 5h ("primary") window hits 100%, codex-lb marks
# it `rate_limited`, the load balancer hard-blocks that status
# (app/core/balancer/logic.py ~:598), and the proxy answers
# `502 stream_incomplete "Upstream websocket closed before response.completed"`.
# That message names the WebSocket, so it reads like the aiohttp-private-internals
# fragility documented above — it is not. Tell them apart by the response headers
# codex-lb attaches: `x-codex-primary-used-percent: 100.0` plus
# `x-codex-primary-reset-at: <epoch>` means quota, not transport.
#
# Why this matters beyond codex-lb: on devbox `adversarial-reviewer-astra` is the
# DEFAULT adversarial reviewer, and opencode's Task tool surfaces a subagent whose
# turn died on an API error as a task_result that is simply EMPTY, state
# "completed". So a quota-exhausted astra presents to the dispatching agent as "the
# reviewer returned nothing" with no error anywhere in its view. Observed
# 2026-09-21: one large review at 06:55 EDT burned the last of a 225-credit primary
# window; every dispatch after it returned empty until the 11:55 EDT reset.
#
# `astra-probe` (below) is the one-line pre-dispatch check. `/health` is NOT that
# check — it returns `{"status":"ok"}` while every account is rate-limited.
#
# TELEMETRY IS ON BY DEFAULT upstream and is turned OFF here. codex-lb ships an
# anonymous-telemetry reporter that starts with the app and announces itself in
# the log ("Anonymous telemetry is active; ... disable with
# CODEX_LB_TELEMETRY_ENABLED=false"). Upstream is actively expanding it
# (soju06/codex-lb#2294, schema v2) and has an open consent/send race
# (#1844). We are pooling subscription accounts through this thing; do not
# volunteer fleet shape to a third party. Flip it back deliberately if ever
# wanted.
{ config, pkgs, lib, isDevbox, isCloudbox, ... }:

lib.mkIf (isDevbox || isCloudbox) {
  systemd.user.services.codex-lb = {
    Unit = {
      Description = "codex-lb (multi-account ChatGPT/Codex rotator)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # Per-host opt-in: stays inactive (not failed) until the marker exists.
      ConditionPathExists = "%h/.codex-lb/enabled";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "simple";
      WorkingDirectory = config.home.homeDirectory;
      Environment = [
        "HOME=${config.home.homeDirectory}"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin:${config.home.homeDirectory}/.nix-profile/bin"
        "LD_LIBRARY_PATH=/run/current-system/sw/share/nix-ld/lib"
        "CODEX_LB_TELEMETRY_ENABLED=false"
      ];
      ExecStart = "${pkgs.uv}/bin/uvx --python 3.13 --with 'aiohttp<3.15' --from codex-lb==1.24.0 codex-lb --host 127.0.0.1 --port 2455";
      Restart = "always";
      RestartSec = 10;
      # A clean `systemctl --user stop` leaves the unit in `failed` state without
      # this: uvicorn exits 143 (128+SIGTERM) rather than 0, and systemd counts a
      # non-zero exit as a failure even when it sent the signal. Cosmetic, but it
      # makes `is-active` lie about why the service is down, which is exactly the
      # signal you want trustworthy while debugging an outage.
      SuccessExitStatus = "143";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # `astra-probe` — pre-dispatch reachability check for openai/gpt-6-astra.
  #
  # Exit 0 + "astra UP: ..." means a dispatch can be expected to return a review;
  # exit 1 + "astra DOWN: <why>" means it will come back empty. Run it BEFORE
  # dispatching @adversarial-reviewer-astra / @oracle-astra, and again when a
  # dispatch returns nothing — an empty task_result is the only symptom the
  # dispatching agent ever sees (see the quota note at the top of this file).
  #
  # Three independent ways astra is unreachable, checked in the order that
  # produces the most specific message:
  #   1. codex-lb is not answering at all (unit down / port moved).
  #   2. codex-lb is up but gpt-6-astra is missing from /v1/models — the
  #      model-catalog-refresh degradation documented in opencode-config.nix,
  #      where a failed Codex-version lookup drops the slug entirely.
  #   3. codex-lb is up and serving the catalog but every account is
  #      non-`active` (rate_limited, quota_exceeded, paused, reauth_required,
  #      deactivated). `active` is the criterion because the load balancer hard-
  #      blocks the other five; "eligible" in the dashboard's sense is weaker
  #      and would report UP for an account the balancer refuses to select.
  #
  # Deliberately NOT a real inference request: a live call would be the truest
  # test but spends a 5h-window credit every time it is run, on a probe whose
  # whole point is to be cheap enough to run before every dispatch.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "astra-probe";
      runtimeInputs = [ pkgs.curl pkgs.jq ];
      text = ''
        base="''${CODEX_LB_URL:-http://127.0.0.1:2455}"

        # curl's own stderr is discarded on purpose: the probe's contract is one
        # line of output, and every transport failure has the same next step.
        if ! accounts=$(curl -fsS --max-time 5 "$base/api/accounts" 2>/dev/null); then
          echo "astra DOWN: codex-lb not answering at $base (systemctl --user status codex-lb)"
          exit 1
        fi

        if ! models=$(curl -fsS --max-time 5 "$base/v1/models" 2>/dev/null); then
          echo "astra DOWN: codex-lb answered /api/accounts but not /v1/models at $base"
          exit 1
        fi

        if ! jq -e '[.data[].id] | index("gpt-6-astra")' >/dev/null <<<"$models"; then
          echo "astra DOWN: gpt-6-astra absent from codex-lb model catalog (refresh unhealthy)"
          exit 1
        fi

        active=$(jq -r '[.accounts[] | select(.status == "active")] | length' <<<"$accounts")
        if [ "$active" -gt 0 ]; then
          echo "astra UP: $active active codex-lb account(s)"
          exit 0
        fi

        detail=$(jq -r '
          if (.accounts | length) == 0 then "no accounts configured"
          else [.accounts[]
                | "\(.displayName // .accountId): \(.status), primary \(.usage.primaryRemainingPercent // "?")% left, resets \(.resetAtPrimary // "?")"]
               | join("; ")
          end' <<<"$accounts")
        echo "astra DOWN: no dispatchable codex-lb account -- $detail"
        exit 1
      '';
    })
  ];

  # devbox is already bootstrapped (account seeded, service running), so keep it
  # enabled by ensuring the opt-in marker exists. Runs before reloadSystemd so the
  # ConditionPathExists above is satisfied when the (re)generated unit is applied.
  # cloudbox is deliberately NOT auto-marked — it's opt-in (seed an account first).
  home.activation.codexLbEnableMarker = lib.mkIf isDevbox
    (lib.hm.dag.entryBefore [ "reloadSystemd" ] ''
      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex-lb"
      [ -e "$HOME/.codex-lb/enabled" ] || ${pkgs.coreutils}/bin/touch "$HOME/.codex-lb/enabled"
    '');
}
