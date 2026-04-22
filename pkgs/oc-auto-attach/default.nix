{ pkgs }:

pkgs.writeShellApplication {
  name = "oc-auto-attach";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    coreutils      # timeout
  ];
  text = ''
    # oc-auto-attach <session-id>
    #
    # Auto-attach a launched OpenCode session to the right project's nvim,
    # inside tmux. See docs/plans/2026-04-22-launch-auto-attach-design.md.
    #
    # Behavior:
    #   1. Wait for the session to be visible at GET /session/<id> with
    #      a non-empty .directory.
    #   2. (Task 4) Compute project key + find/create tmux window.
    #   3. (Task 5) Wait for nvim RPC + helper module to be ready.
    #   4. (Task 5) RPC into nvim to open a new tab with `opencode attach`.
    #
    # Any failure logs to stderr and exits 0 (we don't want to break the
    # launcher on display issues).

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"

    log() {
      printf '[oc-auto-attach] %s\n' "$*" >&2
    }

    if [ $# -ne 1 ]; then
      log "usage: oc-auto-attach <session-id>"
      exit 0
    fi
    sid="$1"

    # Hard-validate session id before any shell interpolation.
    if ! [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
      log "invalid session id: $sid"
      exit 0
    fi

    # Step 1: wait for session to be visible with a non-empty directory.
    session_dir=""
    # shellcheck disable=SC2016
    if ! session_dir="$(timeout 5 bash -c '
      sid="$1"
      url="$2"
      while :; do
        body="$(curl -sf "$url/session/$sid" 2>/dev/null || true)"
        dir="$(printf "%s" "$body" | jq -r ".directory // empty" 2>/dev/null || true)"
        if [ -n "$dir" ] && [ "$dir" != "null" ]; then
          printf "%s" "$dir"
          exit 0
        fi
        # Pace the loop without using `sleep` (which hangs in this environment).
        read -t 0.1 -r _ < <(:) 2>/dev/null || true
      done
    ' _ "$sid" "$OPENCODE_URL")"; then
      log "session $sid not ready after 5s; giving up"
      exit 0
    fi

    if [ -z "$session_dir" ]; then
      log "session $sid has no directory; giving up"
      exit 0
    fi

    log "session $sid dir=$session_dir"

    # TODO (Task 4): project key + tmux window discovery
    # TODO (Task 5): RPC into nvim
  '';
}
