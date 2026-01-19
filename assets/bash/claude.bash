# Claude Code Remote: Start neovim with RPC socket for remote control
# Usage: nvims [files...]
#
# The socket allows external tools (Claude-Code-Remote) to send commands
# to Claude instances running in neovim terminal buffers.
#
# Security: Uses XDG_RUNTIME_DIR (mode 0700) when available, falls back to /tmp.

nvims() {
  local run_dir="${XDG_RUNTIME_DIR:-/tmp}"
  local dir
  dir="$(mktemp -d "$run_dir/nvims.XXXXXX")" || return
  chmod 700 "$dir" 2>/dev/null || true

  local socket="$dir/nvim.sock"

  # Print socket path for tooling that needs it
  echo "NVIM_LISTEN_ADDRESS=$socket" >&2

  command nvim --listen "$socket" "$@"
}
