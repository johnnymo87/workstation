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

    # Pigeon daemon discovery endpoint. In a K-serve pool, opencode-serve
    # processes do NOT share an in-memory event bus, so a session's turns are
    # only streamed by the serve that actually runs its agent loop. Pigeon's
    # GET /route?session_id=<sid> reports the owning serve; we attach the TUI
    # there. Default matches the standard PIGEON_DAEMON_URL convention (4731).
    PIGEON_DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"

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

    # parse_serve_url <route-json-body> <fallback-url>
    #
    # Extract .apiBase from a pigeon `GET /route` JSON body and print it.
    # Falls back to <fallback-url> whenever the body is empty, not JSON, or
    # .apiBase is absent/null/empty. Pure (no network): the caller does the
    # curl and hands the body in, which keeps this unit-testable in
    # test-project-key.sh. The fallback guarantees that any pigeon hiccup
    # degrades to the pre-pool single-serve behavior, never worse.
    parse_serve_url() {
      # Accept BOTH response shapes: GET /route returns camelCase `apiBase`,
      # POST /place returns snake_case `api_base`. Either yields the owning
      # serve's base URL; anything malformed/absent degrades to the fallback.
      local body="$1" fallback="$2" api
      api="$(printf '%s' "$body" | jq -r '.apiBase // .api_base // empty' 2>/dev/null || true)"
      if [ -n "$api" ] && [ "$api" != "null" ]; then
        printf '%s\n' "$api"
      else
        printf '%s\n' "$fallback"
      fi
    }

    # classify_session_probe <http_code> <body>
    #
    # Decide what the Step 1 readiness loop should do with ONE
    # `GET /session/<id>` result. Prints exactly one line:
    #
    #   FOUND <directory>  200 with a non-empty .directory -> attach can proceed.
    #   MISS               404: the session is absent from the shared
    #                      opencode.db. Every serve in the K-serve pool reads
    #                      that one DB, so a 404 from the routed owner is
    #                      CONCLUSIVE -- waiting cannot make it appear. The loop
    #                      gives up fast (after a short grace for the
    #                      launch-commit race) instead of burning the whole 30s
    #                      window on a phantom sid (workstation-ovqu).
    #   WAIT               anything else -- empty/000 (connection refused, or a
    #                      --max-time abort while the event loop is wedged), 5xx,
    #                      or 200 without a directory yet -- a TRANSIENT
    #                      condition; keep polling through the full timeout.
    #
    # Pure (no network): the caller does the curl and hands code+body in, which
    # keeps this unit-testable in test-project-key.sh (kept in lockstep by the
    # source-grep guard there).
    classify_session_probe() {
      local code="$1" body="$2" dir
      if [ "$code" = "200" ]; then
        dir="$(printf '%s' "$body" | jq -r '.directory // empty' 2>/dev/null || true)"
        if [ -n "$dir" ] && [ "$dir" != "null" ]; then
          printf 'FOUND %s\n' "$dir"
          return 0
        fi
        printf 'WAIT\n'
        return 0
      fi
      if [ "$code" = "404" ]; then
        printf 'MISS\n'
        return 0
      fi
      printf 'WAIT\n'
      return 0
    }

    # list_session_panes <session-name>
    #
    # Emit "pane_id|pane_current_command|pane_current_path" for every pane in
    # the named tmux session ONLY.
    #
    # We filter `list-panes -a` on #{session_name} rather than the seemingly
    # obvious session-confined scan (-s with a "=<name>" target). That target
    # is NOT robust: tmux resolves "=<name>" through the WINDOW namespace of
    # the active session first, so if the user has a window literally named
    # <name> (e.g. an nvim editing ~/projects/<name>), the target matches that
    # window and `-s` then lists ITS session -- usually `main`. That made
    # lgtm-dispatched review/gather tabs land in the user's `main` session
    # instead of the dedicated `lgtm` session. The #{session_name} filter
    # matches the session name exactly and is immune to the collision.
    # Regression test: test-project-key.sh (list_session_panes tmux tests).
    list_session_panes() {
      local session="$1"
      tmux list-panes -a -f "#{==:#{session_name},$session}" \
        -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true
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

    # Leading --tmux-session <name> confines all pane discovery and window
    # creation to one tmux session (created detached if absent), overriding
    # the default. Confining to a dedicated non-`main` session lets background
    # callers (lgtm) launch without stealing the user's focus, since they
    # aren't attached to that session.
    #
    # The default is `main`: with no flag, launches land deterministically in
    # the user's primary session instead of whatever session tmux happens to
    # consider "current" -- which was nondeterministic for headless callers
    # (systemd, the pigeon daemon, the recommendation session) not attached to
    # tmux. An empty --tmux-session= is coerced back to `main` below.
    target_session="main"
    while [ $# -gt 0 ]; do
      case "$1" in
        --tmux-session)
          if [ $# -lt 2 ] || [ -z "$2" ]; then
            log "--tmux-session requires a name"
            exit 0
          fi
          target_session="$2"
          shift 2
          ;;
        --tmux-session=*)
          target_session="''${1#--tmux-session=}"
          shift
          ;;
        *)
          break
          ;;
      esac
    done
    # Coerce an empty override (--tmux-session=) back to the default.
    target_session="''${target_session:-main}"

    if [ $# -ne 1 ]; then
      log "usage: oc-auto-attach [--tmux-session <name>] <session-id>"
      exit 0
    fi
    sid="$1"

    # Hard-validate session id before any shell interpolation.
    if ! [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]]; then
      log "invalid session id: $sid"
      exit 0
    fi

    # Validate the tmux session name (tmux forbids '.' and ':'; this also
    # blocks any shell-interpolation hazard). target_session is always set
    # (defaults to `main`), so no empty-string guard is needed.
    if ! [[ "$target_session" =~ ^[A-Za-z0-9_-]+$ ]]; then
      log "invalid tmux session name: $target_session"
      exit 0
    fi
    log "confining to tmux session: $target_session"

    # Step 0: resolve which serve in the pool owns (runs) this session, and
    # attach the TUI there. opencode-serve's streaming event bus is in-memory
    # per process; with K>1 serves sharing one opencode.db, pigeon places a
    # session on one serve via rendezvous hashing, and ONLY that serve emits
    # the session's turn events. A TUI hardwired to a different serve renders
    # stale (misses telegram/swarm-delivered turns) -- the exact symptom this
    # resolves. Any failure (pigeon down, non-2xx, empty/garbage body, no
    # apiBase) degrades to $OPENCODE_URL, i.e. the pre-pool single-serve
    # behavior, so this is strictly safe. We use $serve_url for both the
    # session-dir probe below and the `opencode attach` URL handed to nvim.
    route_body="$(curl -sf --connect-timeout 2 --max-time 3 \
      "$PIGEON_DAEMON_URL/route?session_id=$sid" 2>/dev/null || true)"
    serve_url="$(parse_serve_url "$route_body" "$OPENCODE_URL")"
    log "serve_url=$serve_url (pigeon=$PIGEON_DAEMON_URL)"

    # Step 1: wait for session to be visible with a non-empty directory.
    #
    # Timeout is generous (30s, not 5s): cloudbox runs many concurrent
    # sessions on one `opencode serve` event loop and routinely sits at
    # load ~5. Under contention that event loop stalls in a binary way --
    # GET /session/<id> either returns in ~20ms or blocks for 5-15s+ until
    # the loop frees -- even though the session exists. A tight 5s window
    # made the launcher (and manual re-runs) intermittently log "not ready"
    # for perfectly healthy sessions; 5-15s stalls were observed live.
    #
    # BUT a stall and a genuinely-absent session look DIFFERENT on the wire,
    # and we must not treat them the same. A stall returns no HTTP response
    # (curl --max-time abort -> http_code 000); a deleted/never-existed
    # session returns a real HTTP 404. Because every serve in the K-serve pool
    # reads ONE shared opencode.db, a 404 from the routed owner is CONCLUSIVE
    # -- no amount of waiting makes the session appear. So we classify each
    # probe (classify_session_probe) and give up FAST on a definitive 404
    # (after OC_AA_404_GRACE_SECS of grace for the launch-commit race), while
    # still polling the full 30s through transient 000/5xx stalls. Pre-fix this
    # loop swallowed the 404 with `curl -sf ... || true` and hung the whole 30s
    # on phantom sids -- e.g. a manual attach of a stale id (workstation-ovqu).
    session_dir=""
    probe_rc=0
    probe_body_file="$(mktemp)"
    # classify_session_probe is consumed inside the timeout subshell below;
    # export it so the fresh `bash -c` inherits it via the environment.
    export -f classify_session_probe
    # shellcheck disable=SC2016
    session_dir="$(timeout 30 bash -c '
      sid="$1"
      url="$2"
      bodyf="$3"
      grace="''${OC_AA_404_GRACE_SECS:-3}"
      # When the current run of consecutive 404s began (-1 = no active run).
      miss_since=-1
      # Pace the loop with a fractional `sleep` so we re-probe ~5x/sec without
      # busy-spinning curl -- the worst thing to do while the server is already
      # slow under load. (A plain fractional `sleep` is portable: coreutils
      # sleep is a runtimeInput, and it paces the same on Linux and macOS,
      # unlike the fd-9 process-substitution pipe trick we used to use, which
      # Darwin rejects with EACCES.)
      while :; do
        # -o <file> captures the body; -w %{http_code} prints the status so we
        # can tell a real 404 from a connect/timeout (000). --connect-timeout
        # fails fast if the serve is not listening; --max-time caps a single
        # hung request so a wedged event loop cannot consume the whole window.
        # Note: NO -f -- we WANT to see the 404 status, not swallow it.
        code="$(curl -s -o "$bodyf" -w "%{http_code}" --connect-timeout 2 --max-time 3 "$url/session/$sid" 2>/dev/null || true)"
        body="$(cat "$bodyf" 2>/dev/null || true)"
        verdict="$(classify_session_probe "$code" "$body")"
        case "$verdict" in
          "FOUND "*)
            printf "%s" "''${verdict#FOUND }"
            exit 0
            ;;
          MISS)
            # Definitive absence. Tolerate a brief launch-commit race, then
            # give up with a DISTINCT exit code (3) so the caller can log it as
            # "not found" rather than the misleading "not ready after 30s".
            if [ "$miss_since" -lt 0 ]; then miss_since="$SECONDS"; fi
            if [ "$(( SECONDS - miss_since ))" -ge "$grace" ]; then exit 3; fi
            ;;
          *)
            # WAIT: transient (000 connect/timeout, 5xx, or 200-without-dir).
            # Reset the 404 streak and keep polling the full window.
            miss_since=-1
            ;;
        esac
        sleep 0.2
      done
    ' _ "$sid" "$serve_url" "$probe_body_file")" || probe_rc=$?
    rm -f "$probe_body_file"

    if [ "$probe_rc" -eq 3 ]; then
      log "session $sid not found (404 from $serve_url) -- absent from opencode.db; giving up"
      exit 0
    fi
    if [ "$probe_rc" -ne 0 ] || [ -z "$session_dir" ]; then
      log "session $sid not ready after 30s; giving up"
      exit 0
    fi

    log "session $sid dir=$session_dir"

    # Step 1.5: place the session (workstation-iwpj). The session is now
    # CONFIRMED to exist (Step 1 FOUND), so POSTing pigeon /place cannot
    # manufacture a phantom assignment for a stale/garbage sid (the pigeon-eup
    # hazard that made GET /route read-only). /place is idempotent
    # (ensureRouted = resolveRoute ?? placeSession) and load-aware (HRW +
    # ACTIVE_TURN_CAP), and returns the authoritative owning serve. Without it,
    # never-placed sessions 404 on GET /route and every TUI falls back to the
    # default :4096 -- the serve-0 concentration this fixes. Any failure (pigeon
    # down, non-2xx, empty/garbage body, no api_base) degrades to the Step-0
    # serve_url (itself an OPENCODE_URL fallback), i.e. never worse than today.
    place_auth=()
    if [ -n "''${PIGEON_DAEMON_AUTH_TOKEN:-}" ]; then
      place_auth=(-H "Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN")
    fi
    place_body="$(curl -sf --connect-timeout 2 --max-time 3 \
      -X POST "$PIGEON_DAEMON_URL/place" \
      -H "Content-Type: application/json" \
      ''${place_auth[@]+"''${place_auth[@]}"} \
      -d "{\"session_id\":\"$sid\"}" 2>/dev/null || true)"
    serve_url="$(parse_serve_url "$place_body" "$serve_url")"
    log "placed serve_url=$serve_url (pigeon=$PIGEON_DAEMON_URL)"

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
    # Scan panes for one whose pane_current_path matches the project,
    # regardless of foreground command. We capture the command too so we can
    # branch on it in Step 3.5. Discovery is always confined to
    # $target_session (default `main`) via list_session_panes, which filters
    # on #{session_name} to avoid the window/session name collision
    # documented on that function.
    panes_src="$(list_session_panes "$target_session")"

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
    done <<< "$panes_src"

    if [ -n "$pane_id" ]; then
      log "matched existing pane $pane_id (cmd=$pane_cmd)"
    else
      # No pane matched inside $target_session, so make a window there
      # (creating the session itself if absent). We don't need an "are we
      # inside tmux?" bail or a by-name defense-in-depth scan: the
      # list_session_panes scan above already covered every window in this
      # session, and new-session will start a tmux server if none exists.
      if ! nvims_path="$(resolve_nvims)"; then
        log "nvims not resolvable (neither OC_NVIMS_BIN nor PATH); skipping"
        exit 0
      fi
      log "resolved nvims at $nvims_path"
      if tmux has-session -t "=$target_session" 2>/dev/null; then
        pane_id="$(tmux new-window -d -P -F '#{pane_id}' \
          -t "$target_session:" -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
      else
        pane_id="$(tmux new-session -d -P -F '#{pane_id}' \
          -s "$target_session" -c "$project_key" -n "$window_name" -- "$nvims_path" 2>/dev/null || true)"
      fi
      if [ -z "$pane_id" ]; then
        log "tmux window/session create failed in $target_session; giving up"
        exit 0
      fi
      pane_cmd="nvim"
      log "created pane $pane_id in session $target_session (window $window_name)"
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
      # Fractional `sleep` for pacing -- see Step 1 for why we dropped the
      # `exec 9<> <(:)` + `read -t` fd trick (macOS EACCES on /dev/fd RW).
      until [ -S "$sock" ] && \
            nvim --server "$sock" --remote-expr \
              "luaeval(\"pcall(require, '"'"'user.oc_auto_attach'"'"') and 1 or 0\")" \
              </dev/null 2>/dev/null | grep -qx 1
      do
        sleep 0.2
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
      --arg url "$serve_url" \
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
