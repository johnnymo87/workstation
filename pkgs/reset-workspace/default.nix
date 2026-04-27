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
    # Tear down all nvims and opencode sessions, restart opencode-serve,
    # bring nvims back up as `nvims`. See:
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

    # ---- Process detachment: re-exec into a fresh user systemd scope ----
    # This script kills processes that are likely to be ancestors of its own
    # invoker — specifically nvim (step 4: pkill -9 -u dev -x nvim) and
    # opencode-serve.service (step 5: sudo systemctl restart, which kills
    # the whole service cgroup by default). If we don't detach, we die from:
    #   - SIGHUP propagating from the killed ancestor nvim's PTY collapse, OR
    #   - SIGTERM from systemd's KillMode=control-group cgroup-wide kill.
    #
    # `systemd-run --user --scope` wraps us in a transient .scope unit that:
    #   - Lives in /user.slice/.../app.slice/run-pXXX.scope (fresh cgroup,
    #     outside opencode-serve.service)
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

Tear down all nvims and opencode sessions, restart opencode-serve,
bring nvims back up as \`nvims\`.

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

    # ---- Step 1: Snapshot tmux manifest ----
    log "snapshotting tmux panes running nvim/nvims..."

    MANIFEST=$(tmux list-panes -a \
      -F '#{pane_id}'$'\t'''#{window_name}'$'\t'''#{pane_current_command}'$'\t'''#{pane_current_path}' 2>/dev/null \
      | awk -F'\t' '$3 == "nvim" || $3 == "nvims" { print }' || true)

    if [ -z "$MANIFEST" ]; then
      log "no nvim/nvims panes found"
      MANIFEST_COUNT=0
    else
      MANIFEST_COUNT=$(printf '%s\n' "$MANIFEST" | wc -l)
      log "found $MANIFEST_COUNT nvim/nvims pane(s):"
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane window cmd path; do
        log "  $pane  $window  ($cmd)  $path"
      done
    fi

    # ---- Step 2: Snapshot live opencode TUIs/processes ----
    # Walk every opencode process owned by `dev`, except `opencode serve`.
    # We identify "opencode" by basename of /proc/$pid/exe (handles the
    # wrapped binary path), NOT by argv match — argv-based matching also
    # captures the bundled lua-language-server (path: .cache/opencode/bin/...).
    # For each opencode process, derive the session id:
    #   1. Parse `-s ses_xxx` from /proc/<pid>/cmdline if present.
    #   2. Otherwise grep the open log file for the first GET /session/ses_xxx line.
    # Skip with WARNING if neither attempt yields a valid id.
    log "snapshotting live opencode TUIs..."

    OPENCODE_MANIFEST=""

    # Tolerate empty pgrep result (no matches => exit 1) under set -e.
    OC_PIDS=$(pgrep -u dev -f opencode 2>/dev/null || true)

    if [ -z "$OC_PIDS" ]; then
      log "  no opencode processes found"
    else
      for pid in $OC_PIDS; do
        # Skip if process is gone (race) or unreadable.
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        [ -n "$cmdline" ] || continue

        # Authoritative filter: /proc/$pid/exe must basename-match opencode
        # or the wrapped variant (.opencode-wrapped). This excludes
        # lua-language-server etc. that live under .cache/opencode/.
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        exe_base=$(basename "$exe")
        if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
          continue
        fi

        # Skip opencode-serve itself (we restart it, we don't restore it).
        # Check argv[1] specifically — `grep -qw serve` against the full cmdline
        # would false-positive on TUIs whose cwd or args happen to contain "serve"
        # (e.g. `opencode -d /home/dev/projects/serve/`).
        if printf '%s' "$cmdline" | awk '{print $2}' | grep -qx 'serve'; then
          continue
        fi

        # Match both -s ses_xxx (short form, used by `opencode -s ...`) and
        # --session ses_xxx (long form, used by `opencode attach ... --session
        # ses_xxx`, which is how oc-auto-attach launches restored TUIs).
        # `opencode attach` clients have no log file, so this argv match is
        # the only path that captures restored TUIs on subsequent resets.
        sid=$(printf '%s' "$cmdline" | grep -oE -- '(--session|-s) ses_[A-Za-z0-9]+' | head -1 | awk '{print $2}' || true)

        # Attempt 2: log file fallback.
        if [ -z "$sid" ]; then
          # shellcheck disable=SC2012
          log_file=$(ls -la "/proc/$pid/fd/" 2>/dev/null \
            | awk '/-> .*opencode\/log\/.*\.log$/ { print $NF; exit }' || true)
          if [ -n "$log_file" ] && [ -r "$log_file" ]; then
            sid=$(grep -oE 'path=/session/ses_[A-Za-z0-9]+' "$log_file" 2>/dev/null \
              | head -1 \
              | sed 's|^path=/session/||' || true)
          fi
        fi

        # Validate.
        if [ -z "$sid" ]; then
          log "  WARNING: skipping pid=$pid (no session id) cmdline=$cmdline"
          continue
        fi
        if ! printf '%s' "$sid" | grep -qxE 'ses_[A-Za-z0-9]+'; then
          log "  WARNING: skipping pid=$pid (invalid sid='$sid')"
          continue
        fi

        log "  pid=$pid -> $sid"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${sid}"$'\n'
      done

      # Deduplicate.
      OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')

      if [ -z "$OPENCODE_MANIFEST" ]; then
        OPENCODE_COUNT=0
        log "  (no session ids captured)"
      else
        OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
        log "  captured $OPENCODE_COUNT session id(s)"
      fi
    fi

    # If we never set OPENCODE_COUNT (e.g. no opencode processes at all), set it now.
    OPENCODE_COUNT=''${OPENCODE_COUNT:-0}

    # ---- Step 2: Confirm with user ----
    log ""
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  3. Respawn nvims in $MANIFEST_COUNT pane(s)"
    log "  4. Restore $OPENCODE_COUNT opencode TUI(s) via oc-auto-attach"
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
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "killing all nvim/nvims processes (SIGKILL)..."
      # Use -x nvim. This matches both `nvim` (the TTY frontend)
      # and `nvim --embed` (the embedded server) because both have
      # `comm` field = `nvim`.
      if pkill -9 -u dev -x nvim 2>/dev/null; then
        log "  pkill returned matches"
      else
        log "  pkill returned no matches (none running, or already dead)"
      fi

      # Poll each pane until its current command is no longer nvim/nvims.
      log "polling panes for return to shell..."
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd _path; do
        DEADLINE=$(($(date +%s) + 10))
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
          CUR=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || echo "GONE")
          if [ "$CUR" = "GONE" ]; then
            log "  $pane: pane no longer exists (skipping)"
            break
          fi
          if [ "$CUR" != "nvim" ] && [ "$CUR" != "nvims" ]; then
            log "  $pane: now running $CUR"
            break
          fi
          # Sub-second poll without sleep (per AGENTS.md no-sleep policy)
          read -t 0.1 -r _ < <(:) 2>/dev/null || true
        done
        if [ "$CUR" = "nvim" ] || [ "$CUR" = "nvims" ]; then
          log "  $pane: WARNING — still running $CUR after 10s"
        fi
      done
    fi

    # ---- Step 5: Restart opencode-serve ----
    log "restarting opencode-serve.service..."
    # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false (set in hosts/cloudbox/configuration.nix).
    # Use absolute path /run/wrappers/bin/sudo because:
    #   1. NixOS ships the working setuid sudo at /run/wrappers/bin/sudo.
    #   2. /run/current-system/sw/bin/sudo is a non-setuid symlink that
    #      sudo itself refuses to exec from. systemd units with restricted
    #      PATH won't find the wrapper unless explicitly named.
    if ! /run/wrappers/bin/sudo systemctl restart opencode-serve.service; then
      die "failed to restart opencode-serve"
    fi

    log "polling /global/health for serve readiness..."
    DEADLINE=$(($(date +%s) + 30))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        log "  serve healthy"
        break
      fi
      read -t 0.5 -r _ < <(:) 2>/dev/null || true
    done
    if ! curl -sf "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
      die "opencode-serve did not become healthy within 30s"
    fi

    # ---- Step 6: Respawn nvims in each manifest pane ----
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "respawning nvims in $MANIFEST_COUNT pane(s)..."
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd path; do
        # Verify pane still exists
        if ! tmux display-message -t "$pane" -p '#{pane_id}' >/dev/null 2>&1; then
          log "  $pane: pane no longer exists, skipping respawn"
          continue
        fi
        # cd to original path, then nvims. Single send-keys to keep it atomic.
        tmux send-keys -t "$pane" "cd $path && nvims" Enter || true
        log "  $pane: sent 'cd $path && nvims'"
      done
    fi

    # ---- Step 6.5: Restore opencode TUIs via oc-auto-attach ----
    # OPENCODE_MANIFEST was captured in Step 2 (one session id per line).
    # oc-auto-attach handles its own polling for nvim socket + helper
    # readiness, project-key resolution, and pane creation.
    if [ "$OPENCODE_COUNT" -gt 0 ]; then
      log "restoring $OPENCODE_COUNT opencode TUI(s)..."
      while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        log "  restoring $sid"
        # oc-auto-attach exits 0 even on internal failure (by design).
        # Merge its stderr into our stdout so any errors land in the
        # systemd journal alongside our own logs (without our log()
        # prefix — they're prefixed with [oc-auto-attach] already).
        if ! /home/dev/.nix-profile/bin/oc-auto-attach "$sid" 2>&1; then
          log "  WARNING: oc-auto-attach $sid returned non-zero"
        fi
      done <<< "$OPENCODE_MANIFEST"
    else
      log "no opencode TUIs to restore"
    fi

    # ---- Step 7: Verify nvim sockets exist ----
    if [ "$MANIFEST_COUNT" -gt 0 ]; then
      log "verifying nvim sockets..."
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane _window _cmd _path; do
        DEADLINE=$(($(date +%s) + 5))
        # pane_id is %N — strip the %
        SOCK="/tmp/nvim-''${pane#%}.sock"
        # Re-poll until found or deadline (sockets appear within ~1s typically)
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
          [ -S "$SOCK" ] && break
          read -t 0.2 -r _ < <(:) 2>/dev/null || true
        done
        if [ -S "$SOCK" ]; then
          log "  $pane: socket $SOCK ✓"
        else
          log "  $pane: WARNING — socket $SOCK missing"
        fi
      done
    fi

    log "reset-workspace complete"
  '';
}
