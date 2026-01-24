#!/usr/bin/env bash
# tcopy - copy stdin to clipboard via tmux
# Usage: echo "text" | tcopy
#        cat file | tcopy
set -euo pipefail

if [[ -z "${TMUX:-}" ]]; then
  echo "tcopy: not in a tmux session" >&2
  exit 1
fi

exec tmux load-buffer -w -
