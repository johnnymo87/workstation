#!/usr/bin/env bash
# tpaste - paste clipboard contents via tmux
# Usage: tpaste
#        tpaste | grep foo
set -euo pipefail

if [[ -z "${TMUX:-}" ]]; then
  echo "tpaste: not in a tmux session" >&2
  exit 1
fi

tmux refresh-client -l
exec tmux save-buffer -
