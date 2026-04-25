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

    log "(Tasks 3-7 not yet implemented — exiting)"
  '';
}
