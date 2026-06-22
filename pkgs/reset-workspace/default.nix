{ pkgs }:

pkgs.writeShellApplication {
  name = "reset-workspace";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    procps         # pkill, pgrep
    util-linux     # flock
    coreutils      # timeout
    systemd        # systemd-run for cgroup re-exec
  ];
  text = ''
    # reset-workspace [--yes]
    #
    # Tear down all nvims and opencode sessions, restart the opencode serve pool
    # (opencode-serve-pool.target), bring nvims back up as `nvims`. See:
    # docs/plans/2026-04-24-reset-workspace-design.md
    #
    # --yes  Skip the confirmation prompt (used by the nightly systemd unit).

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
    YES=0

    # Save original args for the flock re-exec below.
    ORIG_ARGS=("$@")

    log() {
      printf '[reset-workspace] %s\n' "$*" >&2
    }

    die() {
      log "FATAL: $*"
      exit 1
    }

    # Print a pid and all of its descendant pids, one per line. Used to
    # build the `main` tmux session allowlist (Step 1.6): a captured
    # `opencode attach` TUI is restored only if its pid is a descendant of a
    # `main` pane (snapshot the tree while it's intact -- after the nvim kill
    # children reparent to init and become unattributable).
    collect_subtree() {
      local root="$1" child
      printf '%s\n' "$root"
      for child in $(pgrep -P "$root" 2>/dev/null || true); do
        collect_subtree "$child"
      done
    }

    # pool_health_urls_from_wants <wants-string> <fallback-url>: parse a systemd
    # `Wants=` value (space-separated unit names) and print one
    # http://127.0.0.1:<port> per opencode-serve@<port>.service instance, in
    # order. Falls back to <fallback-url> when no instances are found (e.g. the
    # query failed or the pool isn't templated), preserving the pre-pool
    # single-serve behavior. Pure (no systemd): the caller runs `systemctl show`
    # and hands the value in (kept in lockstep with pkgs/reset-workspace/test.sh).
    pool_health_urls_from_wants() {
      local wants="$1" fallback="$2" unit port
      local urls=()
      for unit in $wants; do
        case "$unit" in
          opencode-serve@*.service)
            port="''${unit#opencode-serve@}"
            port="''${port%.service}"
            [ -n "$port" ] && urls+=("http://127.0.0.1:$port")
            ;;
        esac
      done
      if [ "''${#urls[@]}" -eq 0 ]; then
        printf '%s\n' "$fallback"
      else
        printf '%s\n' "''${urls[@]}"
      fi
    }

    # ---- Process detachment: re-exec into a fresh user systemd scope ----
    # This script kills processes that are likely to be ancestors of its own
    # invoker — specifically nvim (step 4: pkill -9 -u dev -x nvim) and the
    # opencode serve pool (step 5: systemctl restart opencode-serve-pool.target,
    # whose PartOf= instances are killed cgroup-wide by default). If we don't
    # detach, we die from:
    #   - SIGHUP propagating from the killed ancestor nvim's PTY collapse, OR
    #   - SIGTERM from systemd's KillMode=control-group cgroup-wide kill.
    #
    # `systemd-run --user --scope` wraps us in a transient .scope unit that:
    #   - Lives in /user.slice/.../app.slice/run-pXXX.scope (a fresh cgroup,
    #     outside every opencode-serve@<port>.service instance's cgroup)
    #   - Is reparented under user@1000.service (no nvim ancestor)
    #   - Has its own session leader (no controlling TTY → no PTY-collapse SIGHUP)
    #
    # We do this unconditionally (gated only by the loop-guard env var) because
    # the cost on the happy path is ~10ms and the failure modes it prevents
    # are silent + subtle. Set RESET_WORKSPACE_NO_DETACH=1 to opt out (for
    # debugging only — known-broken in production-like invocation contexts).
    # See: docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md
    if [ "''${RESET_WORKSPACE_DETACHED:-}" != "1" ] \
       && [ "''${RESET_WORKSPACE_NO_DETACH:-}" != "1" ]; then
      log "detaching into fresh user systemd scope..."
      export RESET_WORKSPACE_DETACHED=1
      # --collect: GC the transient scope as soon as we exit.
      # --quiet: suppress the "Running scope as unit run-rXXX.scope" banner.
      # No --pty/--pipe: those flags are service-only and rejected in --scope mode.
      # In --scope mode the re-exec'd process just inherits our stdin/stdout/stderr,
      # which is what we want (the script runs synchronously, attached to whatever
      # terminal/pipe the caller gave us; the [y/N] prompt path still works because
      # interactive humans hit it via a terminal).
      # XDG_RUNTIME_DIR: required for --user (path to the user manager's socket).
      # Fall back to running in-place if systemd-run is unavailable or fails.
      if ! exec env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/''$(id -u)}" \
           systemd-run --user --scope --collect --quiet -- "$0" "$@"; then
        log "WARNING: systemd-run --user --scope failed; running in-place (script may die mid-flight)"
        # Continue past the re-exec block. The flock re-exec below will still run.
      fi
    fi

    # Parse args
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes|-y) YES=1; shift ;;
        --help|-h)
          cat <<EOF
Usage: reset-workspace [--yes]

Tear down all nvims and opencode sessions, restart the opencode serve pool
(opencode-serve-pool.target), bring nvims back up as \`nvims\`.

  --yes, -y    Skip the confirmation prompt.
EOF
          exit 0
          ;;
        *) die "unknown arg: $1 (try --help)" ;;
      esac
    done

    # ---- Concurrency: re-exec under flock if not already locked ----
    LOCK="/tmp/reset-workspace.lock"
    if [ "''${RESET_WORKSPACE_LOCKED:-}" != "1" ]; then
      export RESET_WORKSPACE_LOCKED=1
      RET=0
      flock -n -E 99 "$LOCK" "$0" ''${ORIG_ARGS[@]+"''${ORIG_ARGS[@]}"} || RET=$?
      if [ "$RET" -eq 99 ]; then
        die "another reset-workspace is running (lock $LOCK held)"
      fi
      exit "$RET"
    fi



    # ---- Step 1.5: Tear down the lgtm junk-drawer tmux session ----
    # lgtm confines its OpenCode launches to a tmux session literally named
    # `lgtm` (see lgtm src/dispatch.ts LGTM_TMUX_SESSION + workstation
    # oc-auto-attach --tmux-session). We tear it down for memory hygiene.
    # Its exclusion from the recommendation manifest is now handled
    # structurally by the `main` allowlist (Step 1.6) -- we no longer
    # enumerate its pids here (the old denylist leaked: orphaned lgtm attach
    # clients whose pane had been torn down were reparented to init, escaped
    # the subtree walk, and landed in the manifest). `=lgtm` is an
    # exact-match so a session named e.g. `lgtm-foo` is untouched.
    if tmux has-session -t '=lgtm' 2>/dev/null; then
      log "tearing down lgtm junk-drawer tmux session"
      tmux kill-session -t '=lgtm' 2>/dev/null || true
    fi

    # ---- Step 1.6: Build the `main` tmux session allowlist ----
    # The user's interactive opencode TUIs all live in the `main` tmux
    # session: oc-auto-attach with no --tmux-session creates windows in the
    # current/default session (which is `main`), whereas lgtm passes
    # --tmux-session lgtm. We capture the whole process subtree of every
    # `main` pane while the tree is intact, then capture a TUI's sid below
    # ONLY if its pid is in this set. This allowlist is robust where the old
    # lgtm denylist was leaky: orphaned attach clients (pane gone, process
    # reparented to init) belong to no pane subtree and so are correctly
    # dropped. `=main` is an exact match. If `main` is absent the allowlist
    # stays empty and the manifest ends up empty -- intentional: with no
    # main session there is nothing the user wants restored.
    MAIN_PIDS=" "
    if tmux has-session -t '=main' 2>/dev/null; then
      while read -r pane_pid; do
        [ -n "$pane_pid" ] || continue
        while read -r d; do
          MAIN_PIDS="''${MAIN_PIDS}''${d} "
        done < <(collect_subtree "$pane_pid")
      done < <(tmux list-panes -s -t '=main' -F '#{pane_pid}' 2>/dev/null || true)
      log "main-session allowlist pids:$MAIN_PIDS"
    else
      log "WARNING: no 'main' tmux session found; nothing to restore (manifest will be empty)"
    fi

    # ---- Step 2: Snapshot live opencode attach clients ----
    # Restoration scope: ONLY opencode TUIs in the `main` tmux session
    # (allowlist built in Step 1.6). The strict loop matches TUIs launched
    # via Telegram /launch or `opencode-launch` CLI, whose cmdline is of the
    # form `<binary>/opencode attach <url> --session ses_xxx [--dir <path>]`
    # -- the sid is reliably in argv. The bare loop resolves `:te opencode`
    # TUIs (no --session) by cwd. In BOTH loops a TUI is captured only if
    # its pid is a descendant of a `main` pane, so lgtm review TUIs (a
    # different tmux session) and orphaned attach clients (pane torn down ->
    # reparented to init -> no session) are excluded. See
    # docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md and
    # docs/plans/2026-06-04-reset-workspace-exclude-lgtm-plan.md.
    log "snapshotting live opencode attach clients..."

    OPENCODE_MANIFEST=""
    OPENCODE_STRICT_RAW=0     # strict-attach pgrep matches (raw, before dedupe)
    OPENCODE_BARE_RESOLVED=0  # bare TUIs whose cwd resolved to a sid via opencode-serve
    OPENCODE_BARE_SKIPPED=0   # bare TUIs whose cwd had no resolvable sid (or unreadable cwd)

    # Loose pgrep + strict per-pid validation. Strict regex anchors on the
    # binary path prefix, the literal `attach` subcommand, an http(s) url,
    # and a syntactically valid sid -- false positives are essentially
    # impossible.
    #
    # Note: the cmdline may have additional argv after the sid (notably
    # `--dir <path>`, which oc-auto-attach has been emitting since
    # 2026-04-28; see assets/nvim/lua/user/oc_auto_attach.lua). The match
    # therefore does NOT anchor with $ at the end -- it just requires that
    # `--session ses_xxx` appears somewhere after the url, with either a
    # space or end-of-string after the sid (so we don't capture a partial
    # token).
    OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach' 2>/dev/null || true)
    for pid in $OC_ATTACH_PIDS; do
      # Authoritative exe filter: skip non-opencode processes that pgrep
      # over-matched (e.g. a transient `grep "opencode attach"` running
      # alongside reset). Without this, those processes trigger misleading
      # "no --session in argv" WARNINGs that pollute the journal. Run before
      # the allowlist check so pgrep false-matches don't generate skip noise.
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
      exe_base=$(basename "$exe")
      if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
        continue
      fi
      # main-session allowlist: capture only TUIs whose pid is a descendant
      # of a `main` pane (excludes lgtm review TUIs and orphaned attach
      # clients, which live in a different tmux session or none).
      case "$MAIN_PIDS" in *" $pid "*) ;; *) log "  skipping pid=$pid (not in main tmux session)"; continue ;; esac

      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//' || true)
      [ -n "$cmdline" ] || continue

      if [[ "$cmdline" =~ ^[^[:space:]]+/opencode[[:space:]]+attach[[:space:]]+https?://[^[:space:]]+([[:space:]]+.*)?[[:space:]]+--session[[:space:]]+(ses_[A-Za-z0-9]+)([[:space:]]|$) ]]; then
        sid="''${BASH_REMATCH[2]}"
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
        log "  pid=$pid sid=$sid cwd=$cwd"
        OPENCODE_STRICT_RAW=$((OPENCODE_STRICT_RAW + 1))
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${sid}"$'\n'
      else
        log "  WARNING: skipping pid=$pid (no --session in argv) cmdline=$cmdline"
      fi
    done

    # Resolve bare opencode TUIs to sids via opencode-serve.
    # For each bare TUI alive, look up the most-recent root session for its
    # cwd; if found, restore it as an attach client by appending the sid to
    # OPENCODE_MANIFEST. opencode-serve is alive at this point (we restart
    # it later in step 5), so the API is always reachable here.
    OC_ALL_PIDS=$(pgrep -u dev -f opencode 2>/dev/null || true)
    for pid in $OC_ALL_PIDS; do
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
      exe_base=$(basename "$exe")
      if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
        continue
      fi
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//' || true)
      [ -n "$cmdline" ] || continue
      arg2=$(printf '%s' "$cmdline" | awk '{print $2}')
      # Skip serve (we restart it, not restore it) and attach clients
      # (already enumerated in the strict loop above).
      [ "$arg2" = "serve" ] && continue
      [ "$arg2" = "attach" ] && continue
      # main-session allowlist: capture only bare TUIs in the `main` tmux
      # session. Placed after the serve/attach/exe filters so background
      # daemons (opencode-serve, headless workers) don't generate skip-log
      # noise on every run.
      case "$MAIN_PIDS" in *" $pid "*) ;; *) log "  skipping bare TUI pid=$pid (not in main tmux session)"; continue ;; esac

      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
      if [ -z "$cwd" ]; then
        log "  WARNING: bare opencode TUI pid=$pid has no readable cwd; skipping"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
        continue
      fi

      resolved_sid=$(curl -fsS --get "$OPENCODE_URL/session" \
        --data-urlencode "directory=$cwd" \
        --data-urlencode "roots=true" \
        --data-urlencode "limit=1" 2>/dev/null \
        | jq -r '.[0].id // empty' 2>/dev/null || true)

      if [ -n "$resolved_sid" ] && printf '%s' "$resolved_sid" | grep -qxE 'ses_[A-Za-z0-9]+'; then
        log "  pid=$pid (bare-resolved) sid=$resolved_sid cwd=$cwd"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${resolved_sid}"$'\n'
        OPENCODE_BARE_RESOLVED=$((OPENCODE_BARE_RESOLVED + 1))
      else
        log "  WARNING: bare opencode TUI pid=$pid cwd=$cwd has no resolvable session in DB; skipping restoration"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
      fi
    done

    # Dedupe captured sids.
    OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')
    if [ -z "$OPENCODE_MANIFEST" ]; then
      OPENCODE_COUNT=0
    else
      OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
    fi

    log "  captured $OPENCODE_COUNT restorable session(s) (raw: $OPENCODE_STRICT_RAW strict-attach + $OPENCODE_BARE_RESOLVED bare-resolved; dedupe may collapse); $OPENCODE_BARE_SKIPPED bare TUI(s) skipped"

    # ---- Step 2: Confirm with user ----
    log ""
    log "About to:"
    log "  1. SIGKILL all dev-owned nvim processes"
      log "  2. Restart opencode-serve-pool.target (this Claude session's TUI will reconnect)"
    log "  3. Launch recommendation session referencing $OPENCODE_COUNT captured sid(s)"
    log ""

    if [ "$YES" -ne 1 ]; then
      printf '[reset-workspace] Continue? [y/N] ' >&2
      read -r REPLY
      case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) die "aborted by user" ;;
      esac
    else
      log "(--yes: skipping confirmation)"
    fi

    # ---- Step 3: Kill all nvims ----
    log "killing all nvim/nvims processes (SIGKILL)..."
    # -x nvim matches both `nvim` (TTY frontend) and `nvim --embed`
    # (embedded server) because both have comm = `nvim`.
    if pkill -9 -u dev -x nvim 2>/dev/null; then
      log "  pkill returned matches"
    else
      log "  pkill returned no matches (none running, or already dead)"
    fi

    # ---- Step 5: Restart the opencode serve pool ----
    # mn9r M5: opencode-serve is no longer a single unit — it's a K-serve pool
    # behind opencode-serve-pool.target (templated opencode-serve@<port>.service
    # instances, PartOf the target so ONE target restart fans out to all K). The
    # old `opencode-serve.service` unit no longer exists, which broke the nightly
    # reset (03:00: "Unit opencode-serve.service not found"). Restart the target.
    #
    # Host-aware restart. The pool target runs as a USER target on devbox
    # (~/.config/systemd/user/opencode-serve-pool.target; restart via
    # `systemctl --user`, no sudo) and as a SYSTEM target on cloudbox
    # (hosts/cloudbox/configuration.nix; restart via passwordless sudo).
    # Prefer the user target when it is active so this shared script is portable.
    # On cloudbox there is no user pool target, so `is-active --quiet` returns
    # non-zero and we fall through to the sudo path (cloudbox restarts the system
    # target). The target's PartOf= linkage makes the restart propagate to every
    # opencode-serve@<port>.service instance (a target's Wants= alone would NOT).
    log "restarting opencode-serve-pool.target..."
    if systemctl --user is-active --quiet opencode-serve-pool.target; then
      POOL_SCOPE=user
      log "  opencode-serve-pool is a user target; restarting via systemctl --user"
      if ! systemctl --user restart opencode-serve-pool.target; then
        die "failed to restart opencode-serve-pool (user target)"
      fi
    else
      # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false.
      # Use absolute path /run/wrappers/bin/sudo because NixOS ships the working
      # setuid sudo there; /run/current-system/sw/bin/sudo is a non-setuid symlink
      # sudo refuses to exec from.
      POOL_SCOPE=system
      log "  opencode-serve-pool is a system target; restarting via sudo"
      if ! /run/wrappers/bin/sudo systemctl restart opencode-serve-pool.target; then
        die "failed to restart opencode-serve-pool (system target)"
      fi
    fi

    # mn9r M7: confirm readiness for EVERY serve in the pool, not just serve-0.
    # Discover the pool's endpoints from the target's Wants= (generated from
    # serve-pool.nix, the single source of truth) using the same scope we
    # restarted under, so this can't drift from the actual pool and degrades to
    # $OPENCODE_URL (serve-0) if discovery yields nothing.
    if [ "''${POOL_SCOPE:-system}" = "user" ]; then
      pool_wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    else
      pool_wants="$(/run/wrappers/bin/sudo systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
    fi
    mapfile -t serve_health_urls < <(pool_health_urls_from_wants "$pool_wants" "$OPENCODE_URL")

    log "polling /global/health for ''${#serve_health_urls[@]} serve(s): ''${serve_health_urls[*]}"
    # --max-time 3 is load-bearing: without it, a single hung curl (e.g. TCP
    # connected before serve's HTTP listener was ready, then read blocked
    # indefinitely) wedges the whole script. Observed in the wild on
    # 2026-05-16: curl parked for 6+ hours despite serve being healthy.
    # The bash `while` can't re-check the deadline while wait4()'d on the
    # curl child.
    DEADLINE=$(($(date +%s) + 30))
    pending=("''${serve_health_urls[@]}")
    while [ "$(date +%s)" -lt "$DEADLINE" ] && [ "''${#pending[@]}" -gt 0 ]; do
      still=()
      for u in "''${pending[@]}"; do
        if curl -sf --max-time 3 "$u/global/health" >/dev/null 2>&1; then
          log "  serve healthy: $u"
        else
          still+=("$u")
        fi
      done
      pending=(''${still[@]+"''${still[@]}"})
      [ "''${#pending[@]}" -eq 0 ] && break
      read -t 0.5 -r _ < <(:) 2>/dev/null || true
    done
    if [ "''${#pending[@]}" -gt 0 ]; then
      die "opencode serve pool did not become fully healthy within 30s (still down: ''${pending[*]})"
    fi

    # ---- Step 6: Write manifest + launch recommendation session ----
    # Replaces the old auto-restore (nvim respawn + oc-auto-attach loop).
    # The recommendation session reads the manifest, enriches each sid via
    # opencode-serve, messages the user via Telegram with conversational
    # recommendations, and re-opens only the chosen sessions on reply.
    # Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md
    MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"
    if [ -n "''$OPENCODE_MANIFEST" ]; then
      printf '%s\n' "''$OPENCODE_MANIFEST" > "''$MANIFEST_PATH"
      log "wrote ''$OPENCODE_COUNT sid(s) to ''$MANIFEST_PATH"
    else
      : > "''$MANIFEST_PATH"
      log "wrote empty ''$MANIFEST_PATH (no captured sids)"
    fi

    if [ "''$OPENCODE_COUNT" -eq 0 ]; then
      log "no sessions to recommend; skipping recommendation session launch"
    elif ! command -v opencode-launch >/dev/null 2>&1; then
      log "WARNING: opencode-launch not on PATH; cannot spawn recommendation session"
    else
      log "launching recommendation session in ~ ..."
      # The prompt is intentionally loose/judgmental. The recommendation
      # session does its own enrichment via the opencode-serve HTTP API.
      # See design doc for the rationale.
      RECOMMENDATION_PROMPT=''$(cat <<'PROMPT'
You're the morning recommendation agent. The user has just gone through a nightly reset of their workspace. Read the file at /tmp/reset-workspace-last-manifest.txt -- it contains one opencode session id per line, representing sessions that had a live TUI at reset time.

For each sid, fetch its metadata from GET http://127.0.0.1:4096/session/<sid> and look at the title, directory, and last update time. If useful, also fetch recent messages from GET http://127.0.0.1:4096/session/<sid>/message to get a sense of whether the session was mid-task or wrapped up.

Build a short, conversational Telegram message recommending which sessions to reopen and why. Be opinionated. Group by project. If something looks finished (a PR landed, a question got resolved), say so. If something looks mid-flight, say that too. Number the recommendations so the user can refer to them by number.

Then use the question tool to ask the user which to reopen. Accept free-form replies like "1,3,5", "all", "none", "the mono ones".

When they reply, parse their selection and for each chosen sid, run `oc-auto-attach --tmux-session main <sid>` in a bash tool. ALWAYS pass `--tmux-session main` -- you are a headless session not attached to tmux, so without it the reopened tab lands in whatever session tmux considers "current" rather than reliably in the user's `main` session. Report a brief summary of what was opened.

If the manifest file is missing or empty, message the user "Nightly reset complete, no sessions to recommend." and exit.
PROMPT
)
      # opencode-launch first arg is directory, second is the prompt.
      # ~ resolves inside opencode-launch via "''${directory/#\~/$HOME}".
      if ! opencode-launch '~' "''$RECOMMENDATION_PROMPT" 2>&1 | while IFS= read -r line; do log "  ''$line"; done; then
        log "WARNING: opencode-launch failed (non-zero exit); recommendation session not started"
      fi
    fi

    log "reset-workspace complete"
  '';
}
