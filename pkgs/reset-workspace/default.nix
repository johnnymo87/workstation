{ pkgs, opencode-serve-auth-sh ? pkgs.callPackage ../opencode-serve-auth-sh { } }:

pkgs.writeShellApplication {
  name = "reset-workspace";
  runtimeInputs = with pkgs; [
    curl
    tmux
    procps         # pkill, pgrep
    util-linux     # flock
    coreutils      # timeout
    findutils      # find (ShaDa temp reap)
    gnugrep        # grep (ShaDa parse check)
    systemd        # systemd-run for cgroup re-exec
    inotify-tools  # inotifywait (self-verifying ShaDa concurrency report)
  ];
  text = ''
    # reset-workspace [--yes]
    #
    # Tear down all nvims and opencode sessions, restart the opencode serve pool
    # (opencode-serve-pool.target), bring nvims back up as `nvims`. See:
    # docs/plans/2026-04-24-reset-workspace-design.md
    #
    # --yes  Skip the confirmation prompt (used by the nightly systemd unit).

    # shellcheck disable=SC1091  # sourced from a nix store path shellcheck cannot follow
    source "${opencode-serve-auth-sh}"
    serve_auth_load

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
    YES=0

    # Save original args for the flock re-exec below.
    ORIG_ARGS=("$@")

    log() {
      printf '[reset-workspace] %s\n' "$*" >&2 || true
    }
    trap "" PIPE

    die() {
      log "FATAL: $*"
      exit 1
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

    # pool_ports_from_wants <wants-string>: parse systemd Wants= string and print
    # port numbers for opencode-serve@<port>.service units in order. Pure helper.
    pool_ports_from_wants() {
      local wants="$1" unit port
      for unit in $wants; do
        case "$unit" in
          opencode-serve@*.service)
            port="''${unit#opencode-serve@}"
            port="''${port%.service}"
            [ -n "$port" ] && printf '%s\n' "$port"
            ;;
        esac
      done
    }

    # pool_scope: echo "user" when the per-user pool target is active on this
    # host (devbox), else "system" (cloudbox, where the pool is a system
    # target).
    # Single source of truth for which systemctl scope owns
    # opencode-serve-pool.target, so the restart and the readiness poll can
    # never disagree.
    # `systemctl --user` needs XDG_RUNTIME_DIR; the detach re-exec above
    # guarantees it. If the detach fell back to in-place, misdetecting "system"
    # on devbox dies at restart exactly as the old inline detection did.
    pool_scope() {
      if systemctl --user is-active --quiet opencode-serve-pool.target 2>/dev/null; then
        printf 'user\n'
      else
        printf 'system\n'
      fi
    }

    # get_pool_wants <scope>: read Wants= for opencode-serve-pool.target via systemctl.
    get_pool_wants() {
      local scope="$1" wants=""
      if [ "$scope" = "user" ]; then
        wants="$(systemctl --user show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
      else
        wants="$(systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
        if [ -z "$wants" ]; then
          wants="$(/run/wrappers/bin/sudo -n systemctl show -p Wants --value opencode-serve-pool.target 2>/dev/null || true)"
        fi
      fi
      printf '%s\n' "$wants"
    }

    # discover_pool_urls <scope>: print one http://127.0.0.1:<port> health URL
    # per pool serve, in port order, by reading the target's Wants= via the
    # given systemctl scope and parsing it with pool_health_urls_from_wants.
    # Degrades to $OPENCODE_URL when discovery yields nothing (pre-pool behavior).
    discover_pool_urls() {
      local scope="$1" wants
      wants="$(get_pool_wants "$scope")"
      pool_health_urls_from_wants "$wants" "$OPENCODE_URL"
    }

    # discover_pool_ports <scope>: print instance port numbers (e.g. 4096 4097)
    # for opencode-serve@<port>.service units in Wants=.
    discover_pool_ports() {
      local scope="$1" wants
      wants="$(get_pool_wants "$scope")"
      pool_ports_from_wants "$wants"
    }

    # should_detach_destructive <no_detach_env>: pure predicate deciding whether
    # the destructive phase should re-exec under setsid into a new session.
    # Detaches whenever RESET_WORKSPACE_NO_DETACH!=1. The tty_nr gate was removed
    # because pipe-stdio (e.g. opencode agent bash tools) has tty_nr=0 and needs
    # stdio redirection protection from setsid logfile re-exec; synchronous UX is
    # preserved by tail --pid follow. Nightly stays inline via RESET_WORKSPACE_NO_DETACH=1.
    should_detach_destructive() {
      local no_detach="$1"
      if [ "$no_detach" = "1" ]; then
        return 1
      fi
      return 0
    }

    # format_sentinel <status> <ts> <pid> [phase]: format sentinel line for
    # /tmp/reset-workspace-last-status.txt.
    # "started <ts> pid=<pid> phase=<name>", "ok <ts> pid=<pid>", or "failed <ts> pid=<pid> phase=<name>".
    format_sentinel() {
      local status="$1" ts="$2" pid="$3" phase="''${4:-}"
      if [ "$status" = "ok" ]; then
        printf 'ok %s pid=%s\n' "$ts" "$pid"
      elif [ "$status" = "failed" ]; then
        printf 'failed %s pid=%s phase=%s\n' "$ts" "$pid" "$phase"
      else
        printf 'started %s pid=%s phase=%s\n' "$ts" "$pid" "$phase"
      fi
    }

    SENTINEL_PATH="/tmp/reset-workspace-last-status.txt"
    CURRENT_PHASE="init"
    FINISHED=0
    OWNS_SENTINEL=0

    # update_sentinel <status> [phase]: write sentinel status atomically via mktemp + mv -f.
    # Only executes if OWNS_SENTINEL=1.
    update_sentinel() {
      [ "''${OWNS_SENTINEL:-0}" -eq 1 ] || return 0
      local status="$1" phase="''${2:-}"
      CURRENT_PHASE="$phase"
      local ts
      ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
      local line
      line="$(format_sentinel "$status" "$ts" "$BASHPID" "$phase")"
      local tmp_sentinel
      tmp_sentinel="$(mktemp "/tmp/reset-workspace-status.XXXXXX" 2>/dev/null || echo "$SENTINEL_PATH.tmp.$$")"
      printf '%s\n' "$line" > "$tmp_sentinel" || return 0
      mv -f "$tmp_sentinel" "$SENTINEL_PATH" || return 0
    }

    cleanup_trap() {
      local rc=$?
      # Reap the ShaDa watcher first (workstation-y3fq); it is a background child
      # and an un-reaped one keeps a manual --scope run alive after the script.
      if declare -F shada_watch_cleanup >/dev/null 2>&1; then shada_watch_cleanup; fi
      if [ "''${OWNS_SENTINEL:-0}" -eq 1 ] && [ "$FINISHED" -ne 1 ] && [ "$rc" -ne 0 ]; then
        local ts
        ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)"
        local line
        line="$(format_sentinel "failed" "$ts" "$BASHPID" "$CURRENT_PHASE")"
        local tmp_sentinel
        tmp_sentinel="$(mktemp "/tmp/reset-workspace-status.XXXXXX" 2>/dev/null || echo "$SENTINEL_PATH.tmp.$$")"
        printf '%s\n' "$line" > "$tmp_sentinel" || return 0
        mv -f "$tmp_sentinel" "$SENTINEL_PATH" || return 0
      fi
    }
    trap cleanup_trap EXIT HUP TERM INT

    # is_timestamp_increased <old_ts> <new_ts>: pure helper asserting new_ts > old_ts
    # for ExecMainStartTimestampMonotonic verification.
    is_timestamp_increased() {
      local old="$1" new="$2"
      [[ "$old" =~ ^[0-9]+$ ]] || old=0
      [[ "$new" =~ ^[0-9]+$ ]] || new=0
      [ "$new" -gt "$old" ]
    }

    # evaluate_restart_outcome <old_ts1> <new_ts1> [<old_ts2> <new_ts2> ...]:
    # pure predicate evaluating pool restart outcome across all port timestamp pairs.
    # Returns:
    #   "verified-restarted" when all ports strictly increased
    #   "verified-failed" when at least one port timestamp did NOT increase
    #   "unverifiable" when any timestamp read was missing/unreadable (and no port failed)
    evaluate_restart_outcome() {
      local has_failed=0 has_unreadable=0 has_restarted=0
      if [ "$#" -eq 0 ]; then
        printf 'unverifiable\n'
        return 0
      fi
      while [ "$#" -ge 2 ]; do
        local old="$1" new="$2"
        shift 2
        if [ -z "$old" ] || [ -z "$new" ] || ! [[ "$old" =~ ^[0-9]+$ ]] || ! [[ "$new" =~ ^[0-9]+$ ]]; then
          has_unreadable=1
        elif ! is_timestamp_increased "$old" "$new"; then
          has_failed=1
        else
          has_restarted=1
        fi
      done
      if [ "$has_failed" -eq 1 ]; then
        printf 'verified-failed\n'
      elif [ "$has_unreadable" -eq 1 ] || [ "$has_restarted" -eq 0 ]; then
        printf 'unverifiable\n'
      else
        printf 'verified-restarted\n'
      fi
    }

    # get_unit_monotonic_ts <scope> <port>: read ExecMainStartTimestampMonotonic for
    # opencode-serve@<port>.service. Returns empty string if read failed.
    get_unit_monotonic_ts() {
      local scope="$1" port="$2" ts=""
      if [ "$scope" = "user" ]; then
        ts="$(systemctl --user show -p ExecMainStartTimestampMonotonic --value "opencode-serve@$port.service" 2>/dev/null || true)"
      else
        ts="$(systemctl show -p ExecMainStartTimestampMonotonic --value "opencode-serve@$port.service" 2>/dev/null || true)"
        if [ -z "$ts" ]; then
          ts="$(/run/wrappers/bin/sudo -n systemctl show -p ExecMainStartTimestampMonotonic --value "opencode-serve@$port.service" 2>/dev/null || true)"
        fi
      fi
      if [[ "$ts" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$ts"
      else
        printf '\n'
      fi
    }

    # restart_pool_target <scope>: issue systemctl restart on opencode-serve-pool.target
    # with bounded 3 attempts and 1s backoff (cheap insurance, not the fix).
    restart_pool_target() {
      local scope="$1" attempt ok=0
      for attempt in 1 2 3; do
        log "  restarting opencode-serve-pool.target (attempt $attempt/3)..."
        if [ "$scope" = "user" ]; then
          if systemctl --user restart opencode-serve-pool.target; then
            ok=1; break
          fi
        else
          if /run/wrappers/bin/sudo systemctl restart opencode-serve-pool.target; then
            ok=1; break
          fi
        fi
        log "  WARNING: restart attempt $attempt failed; retrying in 1s..."
        sleep 1
      done
      if [ "$ok" -ne 1 ]; then
        die "failed to restart opencode-serve-pool target after 3 attempts"
      fi
    }

    # ---- Process detachment: re-exec into a fresh user systemd scope ----
    # This script kills processes that are likely to be ancestors of its own
    # invoker — specifically nvim (step 3: pkill -9 -u dev -x nvim) and the
    # opencode serve pool (step 5: systemctl restart opencode-serve-pool.target,
    # whose PartOf= instances are killed cgroup-wide by default).
    #
    # `systemd-run --user --scope` wraps us in a transient .scope unit that:
    #   - Lives in /user.slice/.../app.slice/run-pXXX.scope (a fresh cgroup,
    #     outside every opencode-serve@<port>.service instance's cgroup)
    #   - Is reparented under user@1000.service (no nvim ancestor)
    #
    # Note (workstation-px2p): `systemd-run --user --scope` provides CGROUP
    # isolation only; it does NOT create a new session leader and does NOT sever
    # stdio or the controlling terminal. Process and session detachment with logfile
    # stdio redirection for the destructive phase is handled separately via `setsid`
    # after confirmation (unless RESET_WORKSPACE_NO_DETACH=1).
    #
    # We attempt this whenever the script might be a descendant of a process it
    # will kill. It is gated by the loop-guard env var, and can be opted out of
    # with RESET_WORKSPACE_NO_DETACH=1 — set that on invocations that already run
    # in their own cgroup and don't need the survival re-exec (e.g. the nightly
    # oneshot systemd unit, which lives in its own system-slice scope). Skipping
    # the detach there also means a full runtime tmpfs can't take the nightly run
    # out via systemd-run (see below).
    #
    # IMPORTANT — degrade, don't hard-exit. Creating the transient scope can fail
    # even when systemd-run and the user manager are healthy, most notably when
    # the runtime tmpfs (XDG_RUNTIME_DIR = /run/user/$UID) is FULL: systemd
    # serializes every transient unit to $XDG_RUNTIME_DIR/systemd/transient/<name>
    # before loading it, so ENOSPC there surfaces as the misleading
    # "Failed to start transient scope unit: ... not found". This actually took
    # down every `systemd-run --user` on devbox in 2026-07 when a runaway devenv
    # postgres stderr log filled /run/user/1000.
    #
    # The old code did `exec systemd-run ...`, which made the in-place fallback
    # dead code: once exec replaced the shell, a systemd-run that started but
    # exited non-zero (ENOSPC) became the script's exit code, so the reset never
    # ran AND never fell back. Instead we probe with a throwaway canary scope
    # first; only if that succeeds do we commit to the real re-exec, otherwise we
    # run in-place.
    # See: docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md
    if [ "''${RESET_WORKSPACE_DETACHED:-}" != "1" ] \
       && [ "''${RESET_WORKSPACE_NO_DETACH:-}" != "1" ]; then
      # XDG_RUNTIME_DIR: required for --user (path to the user manager's socket).
      xdg="''${XDG_RUNTIME_DIR:-/run/user/''$(id -u)}"
      # Canary: verify a transient scope can actually be created (user manager
      # reachable AND runtime tmpfs has room) before committing to the re-exec.
      if env XDG_RUNTIME_DIR="$xdg" \
           systemd-run --user --scope --collect --quiet -- true 2>/dev/null; then
        log "detaching into fresh user systemd scope..."
        export RESET_WORKSPACE_DETACHED=1
        # --collect: GC the transient scope as soon as we exit.
        # --quiet: suppress the "Running scope as unit run-rXXX.scope" banner.
        # No --pty/--pipe: those flags are service-only and rejected in --scope mode.
        # In --scope mode the re-exec'd process just inherits our stdin/stdout/stderr,
        # which is what we want (the script runs synchronously, attached to whatever
        # terminal/pipe the caller gave us; the [y/N] prompt path still works because
        # interactive humans hit it via a terminal).
        exec env XDG_RUNTIME_DIR="$xdg" \
          systemd-run --user --scope --collect --quiet -- "$0" "$@"
      else
        log "WARNING: systemd-run --user --scope unavailable (full runtime tmpfs at $xdg, or no user manager); running in-place (script may die mid-flight if it kills an ancestor)"
        # Fall through to run in-place. Better a degraded reset than none.
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



    # ---- Interactive Head Phase (Steps 1.5 - 2) ----
    # When RESET_WORKSPACE_DESTRUCTIVE_DETACHED is set (re-exec'd under setsid),
    # skip the interactive head and jump straight to the destructive gauntlet.
    if [ "''${RESET_WORKSPACE_DESTRUCTIVE_DETACHED:-}" != "1" ]; then
      # ---- Step 1.5: (moved) ----
      # The lgtm junk-drawer teardown used to live here. It is now Step 3.4, in
      # the destructive tail, because `tmux kill-session` triggers a ShaDa write
      # from every pane it tears down and doing that here produced a burst of
      # concurrent writers BEFORE the walk that exists to serialize them
      # (workstation-n0yh.1). Nothing in the head phase depends on lgtm being
      # gone.

      # ---- Step 2: Confirm with user ----
      log ""
      log "About to:"
      log "  1. Exit all dev-owned nvim processes one at a time (SIGKILL only stragglers)"
      log "  2. Restart opencode-serve-pool.target (this Claude session's TUI will reconnect)"
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

      # ---- Detach destructive phase unless RESET_WORKSPACE_NO_DETACH=1 ----
      if should_detach_destructive "''${RESET_WORKSPACE_NO_DETACH:-0}"; then
        LOG_FILE="/tmp/reset-workspace-run.log"
        log "detaching destructive phase into new session via setsid (log at $LOG_FILE)..."
        : > "$LOG_FILE"
        # Prevent stale sentinel reads from previous runs
        rm -f "$SENTINEL_PATH"
        export RESET_WORKSPACE_DESTRUCTIVE_DETACHED=1
        # Concurrency lock preservation: setsid child inherits RESET_WORKSPACE_LOCKED=1
        # and the open flock file descriptor.
        setsid "$0" ''${ORIG_ARGS[@]+"''${ORIG_ARGS[@]}"} < /dev/null >> "$LOG_FILE" 2>&1 &
        TAIL_PID=$!
        log "destructive phase detached (PID $TAIL_PID); following log..."
        log "Note: pressing Ctrl+C stops following this log view, but reset continues in background"
        tail --pid="$TAIL_PID" -f "$LOG_FILE" 2>/dev/null || true

        # Check whether the destructive phase is still running in background
        # (e.g. log follow stopped via Ctrl+C or closed pipe).
        if kill -0 "$TAIL_PID" 2>/dev/null; then
          log "destructive phase still running in background (PID $TAIL_PID)"
          log "  follow log: tail -f $LOG_FILE"
          log "  check status: cat $SENTINEL_PATH"
          exit 0
        fi

        # Check sentinel status after tail finishes (or follower dies)
        if [ -f "$SENTINEL_PATH" ]; then
          status_line="$(cat "$SENTINEL_PATH" 2>/dev/null || true)"
          case "$status_line" in
            ok*" pid=$TAIL_PID") log "reset-workspace finished successfully"; exit 0 ;;
            ok*) die "destructive phase sentinel OK status belongs to stale PID (expected pid=$TAIL_PID; status: $status_line)" ;;
            *) die "destructive phase finished with status: $status_line" ;;
          esac
        else
          die "destructive phase PID $TAIL_PID exited without writing sentinel status"
        fi
      fi
    fi

    # ---- Destructive Tail Phase ----
    OWNS_SENTINEL=1
    POOL_SCOPE="$(pool_scope)"

    # ---- ShaDa helpers (used by Step 3's pre-walk guard and by Step 3.5) ----
    SHADA_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/nvim/shada"
    SHADA_MAIN="$SHADA_DIR/main.shada"

    # ---- Self-verifying ShaDa concurrency report (workstation-y3fq) ----
    # The corruption this script caused came from two ShaDa writers overlapping,
    # and the ONLY reason we can say it stopped is an inotify watch that was
    # started by hand and lives in /run -- it dies at the next reboot, silently.
    # So the reset now measures its own invariant, every night, on both hosts.
    #
    # Why in-band and not a permanent daemon: `inotifywait -m` goes DEAF when its
    # watched directory is replaced (verified 2026-08-09 -- the process stays
    # ALIVE and healthy-looking, so Restart=, is-active and the unit's
    # main-pid checks all pass while it sees nothing). A daemon like that cannot be calibrated. This
    # can: the walk knows how many writers it exited, and every graceful exit must
    # produce at least one temp. Exits with zero observed events therefore means
    # the instrument is dead, and we say UNKNOWN loudly instead of reporting a
    # reassuring "max 1".
    #
    # It starts here -- inside the destructive tail, i.e. AFTER the setsid/scope
    # re-exec -- deliberately. Started any earlier, a manual run launched from a
    # serve cgroup would lose its watcher to the pool restart mid-reset and
    # under-report its own concurrency, which is worse than not measuring.
    SHADA_WATCH_LOG=""
    SHADA_WATCH_PID=""
    shada_watch_start() {
      command -v inotifywait >/dev/null 2>&1 || { log "ShaDa watch: inotifywait unavailable; concurrency will be UNKNOWN"; return 0; }
      mkdir -p "$SHADA_DIR" 2>/dev/null || true
      SHADA_WATCH_LOG="$(mktemp -t reset-shada-watch.XXXXXX 2>/dev/null || true)"
      [ -n "$SHADA_WATCH_LOG" ] || { log "ShaDa watch: could not create log; concurrency will be UNKNOWN"; return 0; }
      inotifywait -m -q --format '%T %e %f' --timefmt '%H:%M:%S' \
        -e create,delete,moved_from "$SHADA_DIR" > "$SHADA_WATCH_LOG" 2>/dev/null &
      SHADA_WATCH_PID=$!
      # inotifywait needs a moment to establish, and a watch that starts after the
      # first writer is an under-reporting instrument.
      sleep 0.3
      kill -0 "$SHADA_WATCH_PID" 2>/dev/null || { SHADA_WATCH_PID=""; log "ShaDa watch: watcher died immediately; concurrency will be UNKNOWN"; }
    }
    # Stop the watcher and report. `expected_writers` is the walk's own count of
    # graceful exits -- the positive control that makes silence meaningful.
    shada_watch_report() {
      local expected_writers="$1" mx=0 temps=0
      [ -n "$SHADA_WATCH_PID" ] || { log "  shada concurrency: unknown (no watcher)"; return 0; }
      sleep 0.5   # let the last rename land before we stop listening
      kill "$SHADA_WATCH_PID" 2>/dev/null || true
      wait "$SHADA_WATCH_PID" 2>/dev/null || true
      SHADA_WATCH_PID=""
      if [ ! -s "$SHADA_WATCH_LOG" ] && [ "$expected_writers" -gt 0 ]; then
        # The calibration that a standalone daemon can never do.
        log "  shada concurrency: unknown -- $expected_writers writer(s) exited but the watch saw NOTHING (instrument is dead, not a quiet night)"
        rm -f "$SHADA_WATCH_LOG" 2>/dev/null || true
        return 0
      fi
      # max concurrent = running count of temps created but not yet renamed away
      read -r mx temps < <(awk '
        /main\.shada\.tmp/ {
          if ($2 ~ /CREATE/)                 { if (!($3 in live)) { live[$3]=1; n++; t++; if (n>mx) mx=n } }
          else if ($2 ~ /MOVED_FROM|DELETE/) { if ($3 in live)    { delete live[$3]; n-- } }
        }
        END { print mx+0, t+0 }
      ' "$SHADA_WATCH_LOG" 2>/dev/null || echo "0 0")
      if [ "''${mx:-0}" -le 1 ]; then
        log "  max concurrent shada writers: ''${mx:-0} (invariant holds; $temps temp(s), $expected_writers writer(s) exited)"
      else
        # This is the corruption precondition, live. Say so in the strongest terms
        # the log has: two writers overlapping is how the file was spliced.
        log "  WARNING: max concurrent shada writers: $mx -- the serialization invariant is BROKEN"
        log "           ($temps temp(s) from $expected_writers writer(s); this is the state that corrupted main.shada on 2026-08-01)"
        log "           raw events follow:"
        while IFS= read -r ev; do log "             $ev"; done < "$SHADA_WATCH_LOG"
      fi
      rm -f "$SHADA_WATCH_LOG" 2>/dev/null || true
    }
    # Never leak the watcher: a manual run in a --scope would keep the scope alive
    # waiting on it. This hooks the EXISTING cleanup_trap (line ~209) rather than
    # installing a second EXIT trap -- bash keeps only the last one per signal, so
    # `trap ... EXIT` here would silently disable the sentinel's failure reporting.
    shada_watch_cleanup() {
      [ -n "''${SHADA_WATCH_PID:-}" ] || return 0
      kill "$SHADA_WATCH_PID" 2>/dev/null || true
      rm -f "$SHADA_WATCH_LOG" 2>/dev/null || true
    }
    # Verdict for one file: prints `healthy`, `corrupt`, or `unknown`.
    #
    # This asks nvim the question we actually care about -- "would you refuse to
    # rename over this file?" -- instead of grepping read-error codes. The error
    # taxonomy is a trap: nvim emits E575 (per-entry semantic), E576 (structural)
    # and E886 (system) while reading, and only some of those classes cause the
    # refusal. A file nvim tolerates needs no repair, so keying on the refusal
    # itself is both exact and immune to upstream renumbering.
    #
    # Load-bearing details, each of which was a bug at some point:
    #   * The probe runs against a COPY in a scratch dir. `-i <file>` makes nvim
    #     write ShaDa on exit, so probing the real file MUTATES it and strands
    #     fresh temps -- once observed promoting the probe's own byproduct.
    #   * Match the refusal PHRASE, not bare `E136`. Five distinct messages share
    #     that code and one of them ("errors during writing it") fires on a
    #     healthy file when the disk is full -- which would quarantine good
    #     history. `LC_ALL=C` keeps the phrase stable if NLS is ever enabled.
    #   * Plain `wshada`. The `!` variant skips the check and would call every
    #     corrupt file healthy.
    #   * Output goes to a file, and the timeout's exit status is read BEFORE
    #     grepping. Piping nvim into `grep -q` yields grep's status, so a hung or
    #     missing nvim produces no match and reads as "healthy" -- the exact
    #     fail-open inversion this function replaces. nvim itself exits 0 on both
    #     verdicts, so only >=124 (timeout's own codes) means "could not run".
    shada_verdict() {
      local f="$1" scratch rc
      command -v nvim >/dev/null 2>&1 || { echo unknown; return; }
      scratch=$(mktemp -d 2>/dev/null) || { echo unknown; return; }
      if ! cp "$f" "$scratch/probe.shada" 2>/dev/null; then
        rm -rf "$scratch"; echo unknown; return
      fi
      LC_ALL=C timeout 30 nvim --headless -u NONE -i "$scratch/probe.shada" \
        -c 'wshada' -c 'qa!' > "$scratch/out" 2>&1
      rc=$?
      if [ "$rc" -ge 124 ]; then rm -rf "$scratch"; echo unknown; return; fi
      if grep -q 'E136.*does not look like a ShaDa file' "$scratch/out" 2>/dev/null; then
        rm -rf "$scratch"; echo corrupt; return
      fi
      rm -rf "$scratch"; echo healthy
    }
    # Promote the newest temp nvim would accept into $SHADA_MAIN. Prints the
    # basename promoted, or nothing. Installs via a same-directory temp + rename
    # so dying mid-write cannot leave a torn main.shada.
    shada_promote_newest_healthy() {
      local cand promoted="" promote_tmp
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if [ "$(shada_verdict "$cand")" = healthy ]; then promoted="$cand"; break; fi
      done <<EOF3
$(find "$SHADA_DIR" -maxdepth 1 -name 'main.shada.tmp.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
EOF3
      [ -n "$promoted" ] || return 1
      promote_tmp="$SHADA_MAIN.promote.$$"
      if cp "$promoted" "$promote_tmp" 2>/dev/null &&
         chmod 600 "$promote_tmp" 2>/dev/null &&
         mv "$promote_tmp" "$SHADA_MAIN" 2>/dev/null; then
        basename "$promoted"; return 0
      fi
      rm -f "$promote_tmp" 2>/dev/null || true
      return 1
    }

    # ---- Step 3: Exit all nvims, one at a time ----
    #
    # This used to be `pkill -9 -u dev -x nvim`, which did NOT suppress ShaDa
    # writes -- it triggered a burst of them. Each pane is a TUI client plus a
    # child `nvim --embed` server (same comm, so `-x nvim` matched both). pkill
    # signals in ascending pid order, so the lower-pid client died first, the
    # server saw channel EOF and began a GRACEFUL exit -- which writes ShaDa --
    # and ~10 servers did that in the same second. nvim's ShaDa write unlinks
    # main.shada before renaming the new file over it, so every one of those
    # writes opened an ENOENT window; on 2026-08-01 two writers landed in each
    # other's window and spliced two msgpack streams into one file, corrupting
    # it permanently. An inotify watch caught three concurrent writers and three
    # unlink windows in one second on 2026-08-03.
    #
    # So: drive the exits ONE AT A TIME. At most one writer exists at any moment,
    # which removes the race at its source. It also RESTORES history the burst was
    # destroying: a writer re-reads and merges main.shada at write time (verified),
    # so serialized exits accumulate every pane's history, where three concurrent
    # renames onto one path kept only the last writer's.
    #
    # Mechanism is SIGTERM to the writer pid, deliberately NOT an RPC `:qa!` over
    # /tmp/nvim-*.sock. Measured on cloudbox 2026-08-03: SIGTERM writes and merges
    # ShaDa identically, runs VimLeavePre, unlinks the socket and closes the pane;
    # while the RPC path cannot report success (a successful `:qa!` and a stale
    # socket BOTH exit 2), can block forever on a socket that accepts but never
    # answers, and misses writers whose socket is not /tmp/nvim-<pane>.sock (a
    # default-address nvim listens on /tmp/nvim.dev/<x>/nvim.<pid>.0). nvim also
    # delivers SIGTERM on the same main loop that services RPC, so RPC buys no
    # coverage of a wedged nvim. Do not "restore" the RPC path: it is absent by
    # decision, not by oversight. See docs/plans/2026-08-02-shada-corruption-roadmap.md.
    #
    # Landmine for the future: a deadly-signal exit sets v:dying=1, and persistence
    # plugins conventionally SKIP their save when it is set. This config has no such
    # plugin today (the only VimLeavePre consumer is a tabby timer cleanup), so
    # SIGTERM loses nothing -- but adding an auto-session plugin would silently
    # change that, and then the RPC path becomes worth its cost.
    update_sentinel "started" "kill-nvim"

    # A writer is any nvim that owns ShaDa state: every nvim EXCEPT a UI client,
    # where a UI client is an nvim having an nvim child whose cmdline contains
    # --embed. Defined by exclusion so `--headless` and `-es` are caught too --
    # grepping for --embed would miss them. Prints `<pid> <starttime> <depth>`,
    # deepest nvim-nesting first: a nested :terminal nvim must exit before the
    # host whose teardown would otherwise take it down as unserialized collateral.
    # Snapshot-based because the process set moves under you (a transient embed
    # was observed appearing and vanishing between two enumerations).
    nvim_writer_snapshot() {
      local p ppid cmd st depth anc
      declare -A PPID_OF=() CMD_OF=() START_OF=() IS_NVIM=() CLIENT=()
      for p in $(pgrep -u dev -x nvim 2>/dev/null || true); do
        st="$(cat /proc/"$p"/stat 2>/dev/null || true)"
        [ -n "$st" ] || continue
        # comm can contain spaces/parens: everything after the LAST ')' is fixed.
        ppid="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $2}')"
        START_OF[$p]="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $20}')"
        cmd="$(tr '\0' ' ' < /proc/"$p"/cmdline 2>/dev/null || true)"
        PPID_OF[$p]="$ppid"; CMD_OF[$p]="$cmd"; IS_NVIM[$p]=1
      done
      for p in "''${!IS_NVIM[@]}"; do
        case "''${CMD_OF[$p]}" in
          *--embed*) ppid="''${PPID_OF[$p]}"
                     [ -n "''${IS_NVIM[$ppid]:-}" ] && CLIENT[$ppid]=1 ;;
        esac
      done
      for p in "''${!IS_NVIM[@]}"; do
        [ -n "''${CLIENT[$p]:-}" ] && continue
        # depth = number of nvim ancestors, so deepest sorts first below.
        depth=0; anc="''${PPID_OF[$p]}"
        while [ -n "''${IS_NVIM[$anc]:-}" ]; do
          depth=$(( depth + 1 )); anc="''${PPID_OF[$anc]}"
          [ "$anc" -gt 1 ] 2>/dev/null || break
        done
        printf '%s %s %s\n' "$p" "''${START_OF[$p]}" "$depth"
      done | sort -k3,3nr -k1,1n
    }

    # Is this pid still the same live process we snapshotted? Guards pid reuse
    # (the pid counter has already wrapped on this host) and treats a ZOMBIE as
    # gone -- a Z-state process has finished its ShaDa write, and `kill -0`
    # reports it as alive, which would otherwise burn the whole timeout and log a
    # bogus WARN for every zombie.
    nvim_writer_live() {
      local pid="$1" want_start="$2" st state start
      st="$(cat /proc/"$pid"/stat 2>/dev/null || true)"
      [ -n "$st" ] || return 1
      state="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $1}')"
      [ "$state" = Z ] && return 1
      start="$(printf '%s' "$st" | sed 's/.*) //' | awk '{print $20}')"
      [ "$start" = "$want_start" ] || return 1
      grep -qx nvim /proc/"$pid"/comm 2>/dev/null || return 1
      return 0
    }

    # Poll until a writer is gone (or Z). rc=1 on timeout.
    nvim_writer_wait_gone() {
      local pid="$1" start="$2" budget_ms="$3" waited=0
      while [ "$waited" -lt "$budget_ms" ]; do
        nvim_writer_live "$pid" "$start" || return 0
        sleep 0.02; waited=$(( waited + 20 ))
      done
      ! nvim_writer_live "$pid" "$start"
    }

    # Start measuring BEFORE the first act that can make an nvim write. Nothing
    # above this line touches a pane; everything below it does.
    shada_watch_start

    # Pre-walk ShaDa guard. If main.shada is ALREADY corrupt entering the walk,
    # every serialized writer would fail its rename (E136) and strand a temp
    # holding only its own history, and the Step 3.5 repair afterwards would
    # promote the newest = ONE pane's history. Quarantining first means the first
    # writer direct-writes into the gap (safe: it is alone) and the rest merge
    # onto it, so the walk accumulates everything instead of one pane.
    if [ -f "$SHADA_MAIN" ]; then
      prewalk_state="$(shada_verdict "$SHADA_MAIN")"
      log "ShaDa pre-walk verdict: $prewalk_state ($(find "$SHADA_DIR" -maxdepth 1 -name 'main.shada.tmp.*' 2>/dev/null | wc -l) temp(s) present)"
      if [ "$prewalk_state" = corrupt ]; then
        prewalk_q="$SHADA_MAIN.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
        if mv "$SHADA_MAIN" "$prewalk_q" 2>/dev/null; then
          log "  quarantined corrupt ShaDa BEFORE the walk -> $(basename "$prewalk_q")"
          log "  (so the exits below accumulate history instead of each stranding a temp)"
        else
          log "  WARNING: could not quarantine corrupt ShaDa pre-walk; exits may strand temps"
        fi
      fi
      # Quarantine preserves a CORRUPT file; this preserves a GOOD one.
      if [ -f "$SHADA_MAIN" ]; then
        cp -a "$SHADA_MAIN" "$SHADA_MAIN.pre-reset" 2>/dev/null ||           log "  WARNING: could not snapshot main.shada to .pre-reset (non-fatal)"
      fi
    else
      log "ShaDa pre-walk: no main.shada present (nvim will create one)"
    fi

    # The walk. Bounded rounds because the set can change under us: nested
    # collateral, tmux respawn, or an agent starting nvim mid-walk.
    SELF_ANCESTORS=" "
    walk_anc=$PPID
    while [ "$walk_anc" -gt 1 ] 2>/dev/null; do
      SELF_ANCESTORS="$SELF_ANCESTORS$walk_anc "
      walk_anc="$(sed 's/.*) //' /proc/"$walk_anc"/stat 2>/dev/null | awk '{print $2}')"
      [ -n "$walk_anc" ] || break
    done
    nvim_killed=0 nvim_exited=0 nvim_unkillable=0 nvim_deferred=""
    for round in 1 2 3; do
      round_writers="$(nvim_writer_snapshot || true)"
      [ -n "$round_writers" ] || break
      log "nvim exit round $round: $(printf '%s\n' "$round_writers" | grep -c . ) writer(s) [$(printf '%s\n' "$round_writers" | awk '{printf "%s ", $1}')]"
      while read -r w_pid w_start _; do
        [ -n "$w_pid" ] || continue
        # Re-check: a previous writer's exit may have taken this one with it.
        nvim_writer_live "$w_pid" "$w_start" || continue
        case "$SELF_ANCESTORS" in
          *" $w_pid "*)
            log "  writer $w_pid is an ANCESTOR of this reset; deferring (killing it would HUP us)"
            nvim_deferred="$nvim_deferred$w_pid "
            continue ;;
        esac
        kill -TERM "$w_pid" 2>/dev/null || true
        if nvim_writer_wait_gone "$w_pid" "$w_start" 3000; then
          nvim_exited=$(( nvim_exited + 1 ))
        else
          # A straggler's write can land at any time, so it could overlap the
          # NEXT writer's unlink window. SIGKILL is the only signal that
          # suppresses the write: one pane's history costs less than the file.
          log "  writer $w_pid did not exit in 3s; SIGKILL (its history is forfeit)"
          kill -9 "$w_pid" 2>/dev/null || true
          if nvim_writer_wait_gone "$w_pid" "$w_start" 1000; then
            nvim_killed=$(( nvim_killed + 1 ))
            # SIGKILL between unlink and rename leaves NO main.shada, with the
            # history in that writer's temp. Step 3.5 promotes it, but say so.
            [ -f "$SHADA_MAIN" ] ||               log "  NOTE: main.shada is absent after that SIGKILL; Step 3.5 will promote a temp"
          else
            nvim_unkillable=$(( nvim_unkillable + 1 ))
            log "  WARNING: writer $w_pid survived SIGKILL; serialization invariant broken for it"
          fi
        fi
        # INVARIANT: no nvim writer is mid-write at this point.
      done <<EOF4
$round_writers
EOF4
    done
    log "  nvim writers: $nvim_exited exited gracefully, $nvim_killed SIGKILLed, $nvim_unkillable unkillable"
    [ -z "$nvim_deferred" ] || log "  deferred (self-ancestor): $nvim_deferred"

    # Final sweep. Order matters: SIGKILL any remaining WRITER first (suppressing
    # its write), and only then the clients -- `pkill -9 -x nvim` on its own hits
    # the low-pid client first, which is precisely what triggers the write burst.
    while read -r s_pid _ _; do
      [ -n "$s_pid" ] || continue
      case "$SELF_ANCESTORS" in *" $s_pid "*) continue ;; esac
      log "  sweep: SIGKILL leftover writer $s_pid"
      kill -9 "$s_pid" 2>/dev/null || true
    done <<EOF5
$(nvim_writer_snapshot || true)
EOF5
    if pkill -9 -u dev -x nvim 2>/dev/null; then
      log "  swept remaining nvim client processes"
    else
      log "  no nvim client processes left to sweep"
    fi

    # ---- Step 3.4: Tear down the lgtm junk-drawer tmux session ----
    # lgtm confines its OpenCode launches to a tmux session literally named
    # `lgtm` (see lgtm src/dispatch.ts LGTM_TMUX_SESSION + workstation
    # oc-auto-attach --tmux-session). We tear it down for memory hygiene.
    # `=lgtm` is an exact match, so a session named e.g. `lgtm-foo` is untouched.
    #
    # This was Step 1.5, in the interactive head, until workstation-n0yh.1.
    # `tmux kill-session` tears down every pane AT ONCE; each pane's TUI client
    # dies, its `nvim --embed` server sees channel EOF and begins a GRACEFUL
    # exit -- which writes ShaDa. That is the identical mechanism to the old
    # `pkill -9` storm, only the trigger differs, and it produced 3 concurrent
    # writers at 03:00:03 on 2026-08-04 -- two seconds before the walk built to
    # prevent exactly that. It runs HERE instead: after the walk and its sweep,
    # where no nvim is left alive to write. It must stay BEFORE the socket reap
    # (a straggler SIGKILLed by the drain below does not unlink its own socket)
    # and BEFORE Step 3.5 (so any write that does slip through still lands where
    # the repair can see it).
    #
    # The drain below is not paranoia. The lgtm-run timer is OnCalendar=*:0/10,
    # so it fires at 03:00:00 -- the same second this reset starts (measured:
    # lgtm-run began 03:00:03.461, 113ms BEFORE this teardown logged at
    # 03:00:03.574) -- and dispatches fresh nvims into the lgtm session. Any that
    # land between the sweep and here are exited ONE AT A TIME, which is what
    # keeps max-concurrent-writers == 1 across the WHOLE reset rather than just
    # across the walk. Logging the count without draining would merely observe
    # the burst it is supposed to prevent.
    late_writers="$(nvim_writer_snapshot || true)"
    if [ -n "$late_writers" ]; then
      log "  draining $(printf '%s\n' "$late_writers" | grep -c . ) late writer(s) before the lgtm teardown [$(printf '%s\n' "$late_writers" | awk '{printf "%s ", $1}')]"
      while read -r l_pid l_start _; do
        [ -n "$l_pid" ] || continue
        case "$SELF_ANCESTORS" in *" $l_pid "*) continue ;; esac
        nvim_writer_live "$l_pid" "$l_start" || continue
        kill -TERM "$l_pid" 2>/dev/null || true
        if ! nvim_writer_wait_gone "$l_pid" "$l_start" 3000; then
          log "    late writer $l_pid did not exit in 3s; SIGKILL (its history is forfeit)"
          kill -9 "$l_pid" 2>/dev/null || true
        fi
      done <<EOF6
$late_writers
EOF6
    fi
    if tmux has-session -t '=lgtm' 2>/dev/null; then
      log "tearing down lgtm junk-drawer tmux session"
      tmux kill-session -t '=lgtm' 2>/dev/null || true
    fi

    # Reap orphan pane sockets (a graceful exit unlinks its own; a SIGKILL does
    # not, which is why 17 of 27 were orphans before this change). Skip any that
    # still has a live listener: an nvim started between the sweep and here would
    # otherwise be left listening on an unlinked inode, invisible to
    # oc-auto-attach and the session_switcher's socket discovery.
    sock_live="$(ss -xlp 2>/dev/null | grep -o '/tmp/nvim-[0-9]*\.sock' | sort -u || true)"
    sock_reaped=0
    for sock in /tmp/nvim-*.sock; do
      [ -S "$sock" ] || continue
      # Here-string, not `printf | grep -qxF`: writeShellApplication sets
      # pipefail, and grep -q closing the pipe early can make a MATCH read as a
      # non-match. Here that inversion would skip the `continue` and rm a LIVE
      # nvim socket. Size-bounded today (socket paths are ~22 bytes), but this
      # is the one site in the sweep whose failure mode destroys user state.
      grep -qxF "$sock" <<<"$sock_live" && continue
      rm -f "$sock" 2>/dev/null && sock_reaped=$(( sock_reaped + 1 )) || true
    done
    [ "$sock_reaped" -eq 0 ] || log "  reaped $sock_reaped orphaned pane socket(s)"

    # ---- Step 3.5: Repair a corrupt ShaDa file, then reap its temps ----
    # nvim persists ShaDa by writing `main.shada.tmp.<a-z>` and renaming it over
    # `main.shada` -- but only after checking that the CURRENT `main.shada`
    # parses. Once `main.shada` is corrupt, that check fails forever:
    #
    #   E576: Error while reading ShaDa file: expected positive integer at <pos>
    #   E136: Did not rename ...tmp.g because ...main.shada does not look like a
    #         ShaDa file
    #
    # so every nvim start/save warns, the rename never happens, and each exit
    # strands one more temp until all 26 suffixes are taken. Observed on cloudbox
    # 2026-08-02: the temps were the symptom, the corrupt master file the cause,
    # so sweeping temps alone left the warnings in place.
    #
    # Repair (in order), all after Step 3 so no live nvim owns these files:
    #   1. If nvim would REFUSE to rename over `main.shada`, quarantine it
    #      alongside as `main.shada.corrupt.<ts>` (kept, never deleted).
    #   2. Promote the newest temp nvim would accept into its place. Those temps
    #      are complete files nvim just wrote, so this preserves most history;
    #      if none is usable, leave no file and nvim starts a fresh one.
    #   3. Reap the remaining temps -- but ONLY if we know they are expendable.
    # Best-effort throughout: any failure logs a warning and the reset continues.
    if [ -d "$SHADA_DIR" ]; then
      # The temps are the ONLY material a later run could recover history from,
      # so the reap is gated: it happens when the master file is known good, or
      # when repair fully succeeded, or when there was genuinely nothing to
      # promote. Never when we could not tell. nvim caps temps at 26 (a-z), so
      # keeping them another day costs bounded disk and buys another attempt.
      shada_reap_ok=1
      if [ -e "$SHADA_MAIN" ] && [ ! -f "$SHADA_MAIN" ]; then
        log "WARNING: $SHADA_MAIN exists but is not a regular file; skipping ShaDa repair and reap"
        shada_reap_ok=0
      elif [ ! -e "$SHADA_MAIN" ]; then
        # main.shada ABSENT. This branch used to be missing entirely, which meant
        # shada_reap_ok stayed 1 and the reap below deleted every temp -- in the
        # one state where the temps are the ONLY copy of the history. Step 3's
        # straggler SIGKILL can land between a writer's unlink and its rename and
        # produce exactly this, so promote here instead of reaping.
        shada_missing_promoted="$(shada_promote_newest_healthy || true)"
        if [ -n "$shada_missing_promoted" ]; then
          log "main.shada was absent; promoted $shada_missing_promoted into its place (history preserved)"
        else
          shada_missing_temps=$(find "$SHADA_DIR" -maxdepth 1 -name 'main.shada.tmp.*' 2>/dev/null | wc -l)
          if [ "$shada_missing_temps" -gt 0 ]; then
            log "WARNING: main.shada absent and none of $shada_missing_temps temp(s) is usable;"
            log "  keeping them all rather than reaping the only recovery material"
            shada_reap_ok=0
          else
            log "main.shada absent and no temps to promote; nvim will start a fresh ShaDa file"
          fi
        fi
      elif [ -f "$SHADA_MAIN" ]; then
        shada_state=$(shada_verdict "$SHADA_MAIN")
        if [ "$shada_state" = unknown ]; then
          log "WARNING: cannot assess ShaDa file (nvim missing, probe timed out, or no scratch space)"
          log "  leaving it and its temps untouched -- the temps are the only recovery material"
          shada_reap_ok=0
        elif [ "$shada_state" = corrupt ]; then
          quarantine="$SHADA_MAIN.corrupt.$(date -u +%Y%m%dT%H%M%SZ)"
          log "ShaDa file is corrupt (nvim would refuse to rename over it); quarantining -> $(basename "$quarantine")"
          if mv "$SHADA_MAIN" "$quarantine" 2>/dev/null; then
            # Newest-first: the freshest usable temp has the most history.
            promoted=""
            while IFS= read -r cand; do
              [ -n "$cand" ] || continue
              if [ "$(shada_verdict "$cand")" = healthy ]; then promoted="$cand"; break; fi
            done <<EOF2
$(find "$SHADA_DIR" -maxdepth 1 -name 'main.shada.tmp.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
EOF2
            if [ -z "$promoted" ]; then
              log "  no usable temp to promote; nvim will start a fresh ShaDa file"
            else
              # Install via a same-directory temp + rename, so a reset dying
              # mid-write cannot leave a torn main.shada -- i.e. so the repair
              # cannot manufacture the very corruption it exists to fix. The name
              # is deliberately outside nvim's `main.shada.tmp.*` namespace.
              promote_tmp="$SHADA_MAIN.promote.$$"
              if cp "$promoted" "$promote_tmp" 2>/dev/null &&
                 chmod 600 "$promote_tmp" 2>/dev/null &&
                 mv "$promote_tmp" "$SHADA_MAIN" 2>/dev/null; then
                log "  promoted $(basename "$promoted") to main.shada (history preserved)"
                # A temp that parses can still be older or shorter than what was
                # lost: truncation on a record boundary reads as perfectly valid,
                # and the 03:00 SIGKILL can strand a half-written temp. Neither is
                # a reason to refuse (the alternative is zero history, and the
                # quarantine keeps the original for manual recovery) but both are
                # reasons to say so out loud.
                q_age=$(stat -c %Y "$quarantine" 2>/dev/null || echo 0)
                p_age=$(stat -c %Y "$promoted" 2>/dev/null || echo 0)
                q_size=$(stat -c %s "$quarantine" 2>/dev/null || echo 0)
                p_size=$(stat -c %s "$promoted" 2>/dev/null || echo 0)
                gap=$(( q_age - p_age ))
                if [ "$gap" -gt 86400 ]; then
                  log "  WARNING: promoted history is $(( gap / 86400 )) day(s) older than the quarantined file"
                fi
                if [ "$q_size" -gt 0 ] && [ "$p_size" -lt $(( q_size * 4 / 5 )) ]; then
                  log "  WARNING: promoted file is $p_size bytes vs $q_size quarantined -- history may be truncated"
                fi
              else
                rm -f "$promote_tmp" 2>/dev/null || true
                log "  WARNING: could not install $(basename "$promoted") as main.shada;"
                log "  keeping every temp so a later run can retry the promotion"
                shada_reap_ok=0
              fi
            fi
          else
            log "  WARNING: could not quarantine corrupt ShaDa file (non-fatal);"
            log "  keeping every temp so a later run can retry the repair"
            shada_reap_ok=0
          fi
        fi
      fi
      if [ "$shada_reap_ok" -eq 1 ]; then
        shada_orphans=$(find "$SHADA_DIR" -maxdepth 1 \( -name 'main.shada.tmp.*' -o -name 'main.shada.promote.*' \) 2>/dev/null | wc -l)
        if [ "$shada_orphans" -gt 0 ]; then
          log "reaping $shada_orphans orphaned ShaDa temp file(s) in $SHADA_DIR ..."
          find "$SHADA_DIR" -maxdepth 1 \( -name 'main.shada.tmp.*' -o -name 'main.shada.promote.*' \) -delete 2>/dev/null || \
            log "  WARNING: ShaDa temp reap failed (non-fatal); continuing reset"
        fi
      fi
    fi

    # ---- Step 4: Prune merged launch worktrees ----
    # opencode-launch --worktree (Phase 3.5) lands writable sessions in a fresh
    # `work` worktree and leaves the worktree+branch behind on the happy path.
    # reset-workspace is the named pruning OWNER for that lifecycle (design M1c):
    # `work --prune-merged` reclaims only worktrees whose branch is fully merged
    # into origin/<trunk> AND whose tree is clean, so an in-flight session's
    # worktree (unmerged or dirty) is never removed -- no live-session probe
    # needed. v1 scope: the mono primary root, where the read-only-main guard
    # lives and churn matters. Best-effort: a failure here never fails the reset.
    # Moved before Step 5 so a pool-death restart/health failure cannot skip it.
    # (`work` is found on the inherited PATH, not runtimeInputs.)
    update_sentinel "started" "prune"
    MONO_ROOT="''${HOME}/projects/mono"
    if command -v work >/dev/null 2>&1 && [ -e "$MONO_ROOT/.git" ]; then
      log "pruning merged launch worktrees under $MONO_ROOT/.worktrees ..."
      if ! ( trap - PIPE; cd "$MONO_ROOT" && exec work --prune-merged ) 2>&1 | while IFS= read -r line; do log "  ''$line"; done; then
        log "WARNING: work --prune-merged failed (non-fatal); continuing reset"
      fi
    else
      log "skipping worktree prune (work not on PATH or $MONO_ROOT is not a git repo)"
    fi

    # ---- Step 5: Restart the opencode serve pool ----
    # mn9r M5: opencode-serve is no longer a single unit — it's a K-serve pool
    # behind opencode-serve-pool.target (templated opencode-serve@<port>.service
    # instances, PartOf the target so ONE target restart fans out to all K). The
    # old `opencode-serve.service` unit no longer exists, which broke the nightly
    # reset (03:00: "Unit opencode-serve.service not found"). Restart the target.
    #
    # Host-aware restart. Scope was computed ONCE as POOL_SCOPE at the top of
    # the destructive tail (see pool_scope), so the restart and the readiness
    # poll below cannot disagree. The pool target
    # runs as a USER target on devbox (~/.config/systemd/user/; restart via
    # `systemctl --user`, no sudo) and as a SYSTEM target on cloudbox
    # (hosts/cloudbox/configuration.nix; restart via passwordless sudo). The
    # target's PartOf= linkage makes the restart propagate to every
    # opencode-serve@<port>.service instance (a target's Wants= alone would
    # NOT).
    update_sentinel "started" "restart-pool"
    log "restarting opencode-serve-pool.target..."

    mapfile -t pool_ports < <(discover_pool_ports "$POOL_SCOPE")
    declare -A BEFORE_TS=()
    before_read_ok=1
    if [ "''${#pool_ports[@]}" -eq 0 ]; then
      log "WARNING: could not discover pool instances; restart postcondition NOT verified"
      update_sentinel "started" "restart-pool-unverified"
      before_read_ok=0
    else
      for port in "''${pool_ports[@]}"; do
        ts="$(get_unit_monotonic_ts "$POOL_SCOPE" "$port")"
        if [ -z "$ts" ]; then
          log "  WARNING: could not read ExecMainStartTimestampMonotonic for serve port $port before restart"
          before_read_ok=0
        else
          BEFORE_TS["$port"]="$ts"
          log "  port $port ExecMainStartTimestampMonotonic before restart: $ts"
        fi
      done
      if [ "$before_read_ok" -eq 0 ]; then
        log "WARNING: some BEFORE monotonic timestamp reads failed; restart postcondition NOT fully verifiable"
        update_sentinel "started" "restart-pool-unverified"
      fi
    fi

    restart_pool_target "$POOL_SCOPE"

    update_sentinel "started" "health-poll"
    # mn9r M7: confirm readiness for EVERY serve in the pool, not just serve-0.
    # Discover the pool's endpoints from the target's Wants= (generated from
    # serve-pool.nix, the single source of truth) using the same scope we
    # restarted under, so this can't drift from the actual pool and degrades to
    # $OPENCODE_URL (serve-0) if discovery yields nothing.
    # INFRA exemption: must probe each pool member directly (per-serve liveness can't be verified through the opaque door).
    mapfile -t serve_health_urls < <(discover_pool_urls "$POOL_SCOPE")

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
        # frontdoor-exempt(C5): per-serve readiness after restart; must confirm every member, not one
        if curl -sf --max-time 3 \
          ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
          "$u/global/health" >/dev/null 2>&1; then
          log "  serve healthy: $u"
        else
          still+=("$u")
        fi
      done
      pending=(''${still[@]+"''${still[@]}"})
      [ "''${#pending[@]}" -eq 0 ] && break
      sleep 0.5
    done
    if [ "''${#pending[@]}" -gt 0 ]; then
      die "opencode serve pool did not become fully healthy within 30s (still down: ''${pending[*]})"
    fi

    # Assert restart postcondition: each pool instance's ExecMainStartTimestampMonotonic strictly increased
    if [ "''${#pool_ports[@]}" -gt 0 ]; then
      eval_args=()
      for port in "''${pool_ports[@]}"; do
        old_ts="''${BEFORE_TS[$port]:-}"
        new_ts="$(get_unit_monotonic_ts "$POOL_SCOPE" "$port")"
        eval_args+=("''${old_ts}" "''${new_ts}")
        if [ -z "$old_ts" ] || [ -z "$new_ts" ]; then
          log "  WARNING: serve port $port timestamp read failed (before: ''${old_ts:-FAILED}, after: ''${new_ts:-FAILED})"
        elif ! is_timestamp_increased "$old_ts" "$new_ts"; then
          log "  WARNING: serve port $port ExecMainStartTimestampMonotonic did not increase (before: $old_ts, after: $new_ts)"
        else
          log "  serve port $port verified restarted (before: $old_ts, after: $new_ts)"
        fi
      done

      outcome="$(evaluate_restart_outcome ''${eval_args[@]+"''${eval_args[@]}"})"
      if [ "$outcome" = "verified-failed" ]; then
        log "WARNING: pool restart assertion failed; retrying restart once..."
        restart_pool_target "$POOL_SCOPE"
        # Re-poll health after retry
        DEADLINE=$(($(date +%s) + 30))
        pending=("''${serve_health_urls[@]}")
        while [ "$(date +%s)" -lt "$DEADLINE" ] && [ "''${#pending[@]}" -gt 0 ]; do
          still=()
          for u in "''${pending[@]}"; do
            # frontdoor-exempt(C5): per-serve readiness after restart; must confirm every member, not one
            if curl -sf --max-time 3 \
              ''${SERVE_AUTH_CURL_ARGS[@]+"''${SERVE_AUTH_CURL_ARGS[@]}"} \
              "$u/global/health" >/dev/null 2>&1; then
              log "  serve healthy: $u"
            else
              still+=("$u")
            fi
          done
      pending=(''${still[@]+"''${still[@]}"})
      [ "''${#pending[@]}" -eq 0 ] && break
      sleep 0.5
    done
        if [ "''${#pending[@]}" -gt 0 ]; then
          die "opencode serve pool did not become fully healthy after retry within 30s (still down: ''${pending[*]})"
        fi

        for port in "''${pool_ports[@]}"; do
          old_ts="''${BEFORE_TS[$port]:-}"
          new_ts="$(get_unit_monotonic_ts "$POOL_SCOPE" "$port")"
          if [ -n "$old_ts" ] && [ -n "$new_ts" ] && ! is_timestamp_increased "$old_ts" "$new_ts"; then
            die "opencode serve port $port failed to restart (ExecMainStartTimestampMonotonic did not increase: before $old_ts, after $new_ts)"
          fi
        done
      elif [ "$outcome" = "unverifiable" ]; then
        log "WARNING: pool restart postcondition unverifiable; continuing reset without retry"
        update_sentinel "started" "restart-pool-unverified"
      else
        log "pool restart verified for all ports"
      fi
    else
      log "WARNING: could not discover pool instances; restart postcondition NOT verified"
    fi

    # Stop measuring and report. This sits at the very END of the run, not right
    # after the walk, because the invariant is "max concurrent == 1 across the
    # WHOLE reset" and Steps 4-5 are part of the reset. Measured 2026-08-10: the
    # first night of in-band reporting agreed with the retiring external watch on
    # the walk window (7 temps, max 1) but MISSED an 8th write at 03:00:57 -- 53
    # seconds after the old report closed, during the prune/restart steps. A
    # measurement that stops before the run does cannot substantiate a claim
    # about the run.
    #
    # `nvim_exited` is the positive control: nonzero exits with zero observed
    # events means the instrument is dead, and the report says so rather than
    # reporting a reassuring "max 1".
    shada_watch_report "$nvim_exited"

    FINISHED=1
    update_sentinel "ok"
    log "reset-workspace complete"
  '';
}
