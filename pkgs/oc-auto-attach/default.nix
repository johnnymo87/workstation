{ pkgs }:

pkgs.writeShellApplication {
  name = "oc-auto-attach";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    coreutils      # timeout
    gawk           # awk (used in the "find existing window by name" branch)
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

    # resolve_nvims: locate the `nvims` launcher.
    #
    # Precedence:
    #   1. $OC_NVIMS_BIN (absolute path), if set and executable.
    #   2. `command -v nvims` on PATH.
    #
    # Prints the resolved path on stdout (0) or nothing (1).
    #
    # We honor $OC_NVIMS_BIN so the pigeon-daemon systemd unit on cloudbox
    # can inject ''${pkgs.nvims}/bin/nvims explicitly: the unit's PATH is a
    # locked-down nix-store list that does NOT include ~/.nix-profile/bin,
    # so a bare `command -v nvims` returns empty and the launcher silently
    # skips creating a TUI — which in turn means no pigeon plugin loads
    # and the launched session completes with no Telegram notification.
    # See workstation-1lp for the full incident writeup.
    #
    # A stale $OC_NVIMS_BIN (set but not -x) warns and falls back, so an
    # outdated systemd env can never strand an interactive caller who
    # has nvims on PATH.
    resolve_nvims() {
      if [ -n "''${OC_NVIMS_BIN:-}" ]; then
        if [ -x "$OC_NVIMS_BIN" ]; then
          printf '%s\n' "$OC_NVIMS_BIN"
          return 0
        fi
        log "OC_NVIMS_BIN=$OC_NVIMS_BIN is set but not executable; falling back to PATH"
      fi
      local found
      found="$(command -v nvims || true)"
      if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
      fi
      return 1
    }

    # classify_pane <pane_cmd>
    #
    # Decides what oc-auto-attach should do with a pane it has matched
    # by cwd. Prints exactly one token to stdout:
    #
    #   REUSE       — pane already has nvim in the foreground; caller
    #                 should proceed to the socket-wait + RPC path.
    #   SEND_NVIMS  — pane has a shell prompt; caller should
    #                 `tmux send-keys C-c` then `send-keys nvims Enter`
    #                 to start nvims in this pane, then proceed.
    #   SKIP        — pane has something else in the foreground (a
    #                 long-running tool the user doesn't want clobbered).
    #                 Caller should `tmux select-window` so the user
    #                 sees we noticed, log a hint, then exit 0.
    classify_pane() {
      local cmd="$1"
      case "$cmd" in
        nvim)
          printf 'REUSE\n'
          ;;
        bash|zsh|fish|sh)
          printf 'SEND_NVIMS\n'
          ;;
        *)
          printf 'SKIP\n'
          ;;
      esac
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
    #
    # Timeout is generous (30s, not 5s): cloudbox runs many concurrent
    # sessions on one `opencode serve` event loop and routinely sits at
    # load ~5. Under contention that event loop stalls in a binary way --
    # GET /session/<id> either returns in ~20ms or blocks for 5-15s+ until
    # the loop frees -- even though the session exists. A tight 5s window
    # made the launcher (and manual re-runs) intermittently log "not ready"
    # for perfectly healthy sessions; 5-15s stalls were observed live.
    session_dir=""
    # shellcheck disable=SC2016
    if ! session_dir="$(timeout 30 bash -c '
      sid="$1"
      url="$2"
      # Pace the loop without `sleep` (keeping the original sleep-free
      # design) via a held-open pipe on fd 9. The <> open keeps the pipe
      # open with no writer producing data, so `read -t` blocks for the
      # full interval and then times out. A plain `read -t 0.2 < <(:)`
      # EOFs instantly (the `:` writer exits the moment the subshell
      # starts), making the pace a silent no-op that busy-spins curl --
      # the worst thing to do while the server is already slow under load.
      exec 9<> <(:)
      while :; do
        # --connect-timeout fails fast if serve is not listening yet;
        # --max-time caps a single hung request so a stalled event loop
        # cannot consume the whole 30s window -- we cut at 3s and re-probe,
        # catching the loop the instant it frees (responses are near-instant
        # once unblocked).
        body="$(curl -sf --connect-timeout 2 --max-time 3 "$url/session/$sid" 2>/dev/null || true)"
        dir="$(printf "%s" "$body" | jq -r ".directory // empty" 2>/dev/null || true)"
        if [ -n "$dir" ] && [ "$dir" != "null" ]; then
          printf "%s" "$dir"
          exit 0
        fi
        read -t 0.2 -r -u 9 _ || true
      done
    ' _ "$sid" "$OPENCODE_URL")"; then
      log "session $sid not ready after 30s; giving up"
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
    pane_cmd=""
    # Scan all panes for one whose pane_current_path matches the project,
    # regardless of foreground command. We capture the command too so we
    # can branch on it in Step 3.5.
    while IFS='|' read -r p_id p_cmd p_path; do
      if [ "$p_path" = "$project_key" ]; then
        pane_id="$p_id"
        pane_cmd="$p_cmd"
        break  # exact match wins
      fi
      if [[ "$p_path" == "$project_key"/* ]] && [ -z "$pane_id" ]; then
        # Remember descendant as fallback; keep looking for exact.
        pane_id="$p_id"
        pane_cmd="$p_cmd"
      fi
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true)

    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id (cmd=$pane_cmd)"
    else
      # Are we inside a tmux session at all? If not, there's no useful place
      # to put the window. (oc-auto-attach is meaningful only in a graphical
      # tmux+nvim workflow.)
      if [ -z "''${TMUX:-}" ] && ! tmux has-session 2>/dev/null; then
        log "no tmux server running; skipping"
        exit 0
      fi
      # If a window with this name already exists in the current tmux
      # session, prefer reusing it over creating yet another window.
      # This is defense-in-depth: the earlier list-panes scan should have
      # caught it, but if two sessions race in the same dir, we don't want
      # to proliferate windows.
      #
      # Implemented in pure bash (no awk pipeline) because under
      # `set -o pipefail` a missing awk in PATH would abort the whole
      # script before we could fall through to `tmux new-window`. We hit
      # exactly that on cloudbox: the systemd-launched daemon's PATH did
      # not include awk, so /launch silently failed for any project
      # without a pre-existing tmux window.
      # Defense-in-depth: the main scan should have caught a window for this
      # project by pane_current_path, but if pane_current_path is stale (some
      # shells don't fire OSC 7 reliably) or two sessions raced in the same
      # cwd, we also check for a window literally named $window_name. Within
      # that window, prefer a pane already running nvim (instant REUSE),
      # else a pane sitting at a shell prompt (SEND_NVIMS), else the first
      # pane we see (which will route through SKIP if it's some other tool
      # the user doesn't want clobbered).
      existing_pane=""
      existing_pane_cmd=""
      existing_pane_priority=0   # 0=nothing, 1=other, 2=shell, 3=nvim
      while IFS='|' read -r ep_id ep_cmd; do
        case "$ep_cmd" in
          nvim)               this_priority=3 ;;
          bash|zsh|fish|sh)   this_priority=2 ;;
          *)                  this_priority=1 ;;
        esac
        if [ "$this_priority" -gt "$existing_pane_priority" ]; then
          existing_pane="$ep_id"
          existing_pane_cmd="$ep_cmd"
          existing_pane_priority="$this_priority"
          [ "$this_priority" -eq 3 ] && break   # nvim is best; stop early
        fi
      done < <(tmux list-panes -t ":$window_name" -F '#{pane_id}|#{pane_current_command}' 2>/dev/null || true)
      if [ -n "$existing_pane" ]; then
        pane_id="$existing_pane"
        pane_cmd="$existing_pane_cmd"
        log "reusing existing window $window_name pane $pane_id (cmd=$pane_cmd)"
      else
        if ! nvims_path="$(resolve_nvims)"; then
          log "nvims not resolvable (neither OC_NVIMS_BIN nor PATH); skipping"
          exit 0
        fi
        log "resolved nvims at $nvims_path"
        pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
          -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
        if [ -z "$pane_id" ]; then
          log "tmux new-window failed; giving up"
          exit 0
        fi
        # Brand new window: we know nvims is the entrypoint, so the
        # foreground is (or will be momentarily) nvim. Skip the
        # send-keys branch in Step 3.5 and go straight to socket-wait.
        pane_cmd="nvim"
        log "created new pane $pane_id (window $window_name)"
      fi
    fi

    # Step 3.5: Decide what to do with $pane_id based on its foreground.
    #
    # By this point pane_id is non-empty (we either matched or created)
    # and pane_cmd reflects the pane's foreground command. classify_pane
    # tells us which branch to take.
    action="$(classify_pane "$pane_cmd")"
    log "classify_pane: $action"
    case "$action" in
      REUSE)
        # Foreground is already nvim — bring the window to focus and
        # proceed to Step 4 (socket + RPC).
        tmux select-window -t "$pane_id" 2>/dev/null || true
        ;;
      SEND_NVIMS)
        # Shell prompt. Clear any half-typed command line with C-c,
        # then send `nvims\n`. nvims will exec into `nvim --listen
        # /tmp/nvim-<pane>.sock`, which Step 4-5 will pick up.
        tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
        tmux send-keys -t "$pane_id" 'nvims' Enter 2>/dev/null || true
        tmux select-window -t "$pane_id" 2>/dev/null || true
        log "sent C-c + 'nvims' to pane $pane_id; waiting for nvim to come up"
        ;;
      SKIP)
        # Some other tool is running in the matched pane (opencode,
        # tail -f, top, etc). Don't clobber. Just bring it to focus
        # and ask the user to launch nvims themselves.
        tmux select-window -t "$pane_id" 2>/dev/null || true
        log "found existing window for $project_key with $pane_cmd running; not launching nvims — start it yourself, then re-run oc-auto-attach $sid"
        exit 0
        ;;
      *)
        log "classify_pane returned unexpected token: $action; bailing"
        exit 0
        ;;
    esac

    # Step 4: compute socket path.
    sock="/tmp/nvim-''${pane_id#%}.sock"
    log "socket=$sock"
    # Step 5: wait until the nvim RPC server is ready AND the helper
    # module has been required.
    #
    # The </dev/null on the inner `nvim --remote-expr` is load-bearing:
    # when invoked with stdin attached to a tty (e.g. running this script
    # interactively from a tmux pane), neovim 0.11 does terminal capability
    # probing that corrupts/empties --remote-expr's stdout — the loop then
    # never sees "1", grep -qx 1 never matches, and we hit the timeout below.
    # See workstation-qmg for the full root-cause analysis.
    # Timeout bumped 5s -> 15s for the same load reason as Step 1: under
    # contention nvim startup plus helper-module load can take longer than
    # 5s, which surfaced as "nvim not ready" misfires in the log.
    # shellcheck disable=SC2016
    if ! timeout 15 bash -c '
      sock="$1"
      # Held-open pipe on fd 9 for real pacing -- see Step 1 for why a
      # plain `read -t < <(:)` would EOF instantly and busy-spin.
      exec 9<> <(:)
      until [ -S "$sock" ] && \
            nvim --server "$sock" --remote-expr \
              "luaeval(\"pcall(require, '"'"'user.oc_auto_attach'"'"') and 1 or 0\")" \
              </dev/null 2>/dev/null | grep -qx 1
      do
        read -t 0.2 -r -u 9 _ || true
      done
    ' _ "$sock"; then
      log "nvim at $sock not ready (or helper not loaded) after 15s; giving up"
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

    # </dev/null prevents nvim from terminal-probing on a tty (see Step 5
    # comment for the full story); without it, capability sequences leak
    # into the calling terminal and the call can also fail spuriously.
    if ! nvim --server "$sock" --remote-expr "$expr" </dev/null >/dev/null; then
      log "nvim RPC call failed; giving up"
      exit 0
    fi

    log "tab opened in pane $pane_id for $sid"
  '';
}
