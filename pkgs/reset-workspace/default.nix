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

    # ---- Step 2: Confirm with user ----
    SESSION_COUNT=$(curl -sf "$OPENCODE_URL/session" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "?")
    log ""
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. DELETE $SESSION_COUNT opencode session(s) via HTTP API"
    log "  3. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  4. Respawn nvims in $MANIFEST_COUNT pane(s)"
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

    # ---- Step 4: Delete all opencode sessions ----
    log "fetching opencode session list..."
    if ! IDS=$(curl -sf "$OPENCODE_URL/session" 2>/dev/null | jq -r '.[].id' 2>/dev/null); then
      log "  WARNING: failed to fetch session list (serve may be down)"
      IDS=""
    fi

    if [ -z "$IDS" ]; then
      log "  no sessions to delete"
    else
      DELETED=0
      FAILED=0
      while IFS= read -r id; do
        if curl -sf -X DELETE "$OPENCODE_URL/session/$id" -o /dev/null; then
          DELETED=$((DELETED + 1))
        else
          FAILED=$((FAILED + 1))
          log "  WARNING: failed to delete $id"
        fi
      done <<< "$IDS"
      log "  deleted $DELETED session(s), $FAILED failure(s)"
    fi

    # ---- Step 5: Restart opencode-serve ----
    log "restarting opencode-serve.service..."
    # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false (set in hosts/cloudbox/configuration.nix).
    if ! sudo systemctl restart opencode-serve.service; then
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
