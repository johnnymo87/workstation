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

    # Step 2: compute project key for editor routing.
    # Collapse ~/projects/<P>/(/.worktrees/<W>)?(/.*)? -> ~/projects/<P>.
    if [[ "$session_dir" =~ ^"''${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
      project_key="''${HOME}/projects/''${BASH_REMATCH[1]}"
      window_name="''${BASH_REMATCH[1]}"
    else
      project_key="$session_dir"
      window_name="$(basename "$session_dir")"
    fi
    log "project_key=$project_key window_name=$window_name"

    # Step 3: find an existing tmux pane that's running nvim with cwd
    # equal to (or a descendant of) project_key. Prefer exact match.
    pane_id=""
    while IFS='|' read -r p_id p_cmd p_path; do
      [ "$p_cmd" = "nvim" ] || continue
      if [ "$p_path" = "$project_key" ]; then
        pane_id="$p_id"
        break  # exact match wins
      fi
      if [[ "$p_path" == "$project_key"/* ]] && [ -z "$pane_id" ]; then
        pane_id="$p_id"  # remember as fallback, keep looking for exact
      fi
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)

    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id"
    else
      # Are we inside a tmux session at all? If not, there's no useful place
      # to put the window. (oc-auto-attach is meaningful only in a graphical
      # tmux+nvim workflow.)
      if [ -z "''${TMUX:-}" ] && ! tmux has-session 2>/dev/null; then
        log "no tmux server running; skipping"
        exit 0
      fi
      nvims_path="$(command -v nvims || true)"
      if [ -z "$nvims_path" ]; then
        log "nvims not found on PATH; skipping"
        exit 0
      fi
      pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
        -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
      if [ -z "$pane_id" ]; then
        log "tmux new-window failed; giving up"
        exit 0
      fi
      log "created new pane $pane_id (window $window_name)"
    fi

    # Step 4: compute socket path.
    sock="/tmp/nvim-''${pane_id#%}.sock"
    log "socket=$sock"
    # Step 5: wait until the nvim RPC server is ready AND the helper
    # module has been required.
    # shellcheck disable=SC2016
    if ! timeout 5 bash -c '
      sock="$1"
      until [ -S "$sock" ] && \
            nvim --server "$sock" --remote-expr \
              "luaeval(\"pcall(require, '"'"'user.oc_auto_attach'"'"') and 1 or 0\")" \
              2>/dev/null | grep -qx 1
      do
        # Pace the loop without using `sleep` (which hangs in this environment).
        read -t 0.1 -r _ < <(:) 2>/dev/null || true
      done
    ' _ "$sock"; then
      log "nvim at $sock not ready (or helper not loaded) after 5s; giving up"
      exit 0
    fi
    log "nvim at $sock is ready"

    # Step 6: invoke the helper. We pass the payload as JSON encoded by jq,
    # then decode it inside Lua via vim.json.decode to bulletproof against
    # any quoting hazards in sid/dir/url.
    payload="$(jq -nc \
      --arg sid "$sid" \
      --arg dir "$session_dir" \
      --arg url "$OPENCODE_URL" \
      '{sid:$sid, dir:$dir, url:$url}')"

    # jq -Rs '.' emits a JSON string literal, which doubles as a valid
    # Vimscript double-quoted string literal — that's what luaeval reads as _A.
    expr="luaeval(\"require('user.oc_auto_attach').open(vim.json.decode(_A))\", $(printf '%s' "$payload" | jq -Rs '.'))"

    if ! nvim --server "$sock" --remote-expr "$expr" >/dev/null; then
      log "nvim RPC call failed; giving up"
      exit 0
    fi

    log "tab opened in pane $pane_id for $sid"
  '';
}
