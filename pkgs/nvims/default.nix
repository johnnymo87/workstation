{ pkgs }:

pkgs.writeShellApplication {
  name = "nvims";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    # nvims: nvim with a deterministic --listen socket keyed on tmux pane id.
    # Outside tmux, defers to nvim's default socket behavior.
    #
    # The socket path is /tmp/nvim-''${TMUX_PANE#%}.sock (e.g. %17 -> /tmp/nvim-17.sock)
    # so external tools (like oc-auto-attach) can compute it from
    # `tmux list-panes -F '#{pane_id}'`.
    #
    # If the user passes their own --listen, we honor it and skip our injection.

    # If caller already passed --listen, don't override.
    for arg in "$@"; do
      case "$arg" in
        --listen|--listen=*) exec nvim "$@" ;;
      esac
    done

    if [ -n "''${TMUX_PANE:-}" ]; then
      key="''${TMUX_PANE#%}"
      sock="/tmp/nvim-''${key}.sock"
      # Remove stale socket left behind by previous SIGKILL'd nvim.
      # Only remove if it IS a socket (defensive against weird path collisions).
      if [ -S "$sock" ]; then
        rm -f "$sock"
      fi
      exec nvim --listen "$sock" "$@"
    else
      exec nvim "$@"
    fi
  '';
}
