{ pkgs }:

pkgs.writeShellApplication {
  name = "nvims";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    # nvims: nvim with a deterministic --listen socket keyed on tmux pane id.
    # Outside tmux -- or when nested inside an existing nvim's :terminal (see
    # the $NVIM nesting guard below, workstation-8iqt) -- defers to nvim's
    # default socket behavior.
    #
    # The socket path is /tmp/nvim-''${TMUX_PANE#%}.sock (e.g. %17 -> /tmp/nvim-17.sock)
    # so external tools (like oc-auto-attach) can compute it from
    # `tmux list-panes -F '#{pane_id}'`.
    #
    # If the user passes their own --listen, we honor it and skip our injection.

    # Force EDITOR/VISUAL=nvim for nvim and everything it spawns.
    #
    # oc-auto-attach launches nvim via `tmux new-window -- nvims`, so nvim
    # (and the `opencode attach` TUI it jobstart()s) inherit the *tmux server's*
    # environment. On NixOS that server carries EDITOR=nano from
    # /etc/set-environment, because home.sessionVariables (EDITOR/VISUAL=nvim)
    # only propagate through ~/.profile (login shells) -- which the tmux server
    # never sourced. The opencode TUI resolves its editor as
    # `process.env.VISUAL || process.env.EDITOR`, so ctrl+x x / `/export`
    # opened nano instead of nvim. Exporting here (the single chokepoint every
    # auto-attached nvim passes through) fixes nvim itself and every child it
    # spawns, regardless of how the tmux server got its environment. When nvims
    # is launched from an interactive shell these are already nvim, so this is
    # idempotent.
    export EDITOR=nvim
    export VISUAL=nvim

    # If caller already passed --listen, don't override.
    for arg in "$@"; do
      case "$arg" in
        --listen|--listen=*) exec nvim "$@" ;;
      esac
    done

    # nvim_listen_plan <in_tmux> <nested> <sock_state>: decide how to start
    # nvim's RPC server. Pure (all env/filesystem state passed as args) so it
    # is unit-testable without tmux/nvim/a real socket. Mirrored by test.sh.
    #
    #   in_tmux      "1" if $TMUX_PANE is set (we have a deterministic pane key)
    #   nested       "1" if running inside a LIVE parent nvim's :terminal
    #   sock_state   "" (no socket at the pane path), "stale" (a socket file
    #                nobody answers on), or "live" (an nvim answers on it)
    #
    # Prints one token: DEFAULT | LISTEN | RM_THEN_LISTEN (see dispatch below).
    nvim_listen_plan() {
      local in_tmux="$1" nested="$2" sock_state="$3"
      if [ "$in_tmux" != "1" ]; then printf 'DEFAULT\n'; return; fi
      if [ "$nested" = "1" ]; then printf 'DEFAULT\n'; return; fi
      case "$sock_state" in
        stale) printf 'RM_THEN_LISTEN\n' ;;
        live)  printf 'DEFAULT\n' ;;
        *)     printf 'LISTEN\n' ;;
      esac
    }

    # Detect nesting (workstation-8iqt). A parent nvim exports $NVIM (its own
    # RPC socket address) into every :terminal child, and $TMUX_PANE is
    # INHERITED by those children. So a `nvims` launched from inside nvim would
    # compute the SAME /tmp/nvim-<pane>.sock as the live parent and rm -f it
    # below -- unlinking the parent's still-open socket and leaving it listening
    # on an anonymous inode no external tool (oc-auto-attach) can reach. A
    # nested nvim must therefore NOT claim the pane socket; it defers to nvim's
    # default server. We require $NVIM to resolve to a LIVE socket ([ -S ]) so a
    # stale $NVIM leaked through the tmux server environment can't wrongly
    # suppress socket injection for a legitimate top-level pane.
    nested=""
    if [ -n "''${NVIM:-}" ] && [ -S "''${NVIM}" ]; then
      nested=1
    fi

    in_tmux=""
    sock=""
    sock_state=""
    if [ -n "''${TMUX_PANE:-}" ]; then
      in_tmux=1
      key="''${TMUX_PANE#%}"
      sock="/tmp/nvim-''${key}.sock"
      # Only treat it as a pane socket if it IS a socket (defensive against
      # weird path collisions). Then ASK whether something answers on it
      # before calling it stale: pane ids are only unique within ONE tmux
      # server, so when two servers are running (e.g. the main server's
      # socket was unlinked and a second one got started, seen 2026-09-29)
      # both hand out %0, %1, ... and this path can belong to a live nvim in
      # the OTHER server. rm -f'ing it would orphan that nvim's RPC endpoint.
      # A dead socket refuses the connection at once, so this costs ~nothing
      # in the common stale case; `timeout` bounds a wedged-but-alive one.
      #
      # Fail SAFE: only a confirmed "connection refused" counts as stale.
      # A timeout (a SIGSTOPped or busy nvim), a non-nvim listener, or any
      # other surprise is treated as held, because unlinking a live owner's
      # socket is unrecoverable and skipping cleanup of a dead one is not.
      if [ -S "$sock" ]; then
        probe_rc=0
        probe_out="$(timeout 2 nvim --server "$sock" --remote-expr 1 </dev/null 2>&1)" || probe_rc=$?
        if [ "$probe_rc" -ne 124 ] && [[ "$probe_out" == *"connection refused"* ]]; then
          sock_state=stale
        else
          sock_state=live
        fi
      fi
    fi

    case "$(nvim_listen_plan "$in_tmux" "$nested" "$sock_state")" in
      RM_THEN_LISTEN)
        # Stale socket left behind by a previous SIGKILL'd nvim in this pane.
        rm -f "$sock"
        exec nvim --listen "$sock" "$@"
        ;;
      LISTEN)
        exec nvim --listen "$sock" "$@"
        ;;
      *)
        # DEFAULT: outside tmux, nested inside a live nvim, or the pane path
        # is held by a live nvim we must not evict -- let nvim pick its own
        # default server address (don't touch the pane socket).
        if [ "$sock_state" = "live" ] && [ "$nested" != "1" ]; then
          printf 'nvims: %s is held by another live nvim (a second tmux server?); not claiming it -- oc-auto-attach cannot reach this nvim\n' "$sock" >&2
        fi
        exec nvim "$@"
        ;;
    esac
  '';
}
