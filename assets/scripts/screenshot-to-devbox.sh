#!/usr/bin/env bash
set -euo pipefail

DEVBOX_HOST="${DEVBOX_HOST:-devbox}"
REMOTE_DIR="${SCREENSHOT_REMOTE_DIR:-}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 127; }; }
need_cmd screencapture
need_cmd ssh
need_cmd scp

tmp="$(mktemp /tmp/screenshot-XXXXXX.png)"

cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM

if ! screencapture -i -x "$tmp"; then
  echo "Screenshot cancelled"
  exit 0
fi

if [[ ! -s "$tmp" ]]; then
  echo "Screenshot cancelled"
  exit 0
fi

if [[ -z "$REMOTE_DIR" ]]; then
  remote_home="$(ssh -o BatchMode=yes "$DEVBOX_HOST" 'printf %s "$HOME"')"
  REMOTE_DIR="$remote_home/.cache/claude-images"
fi

ssh -o BatchMode=yes "$DEVBOX_HOST" "umask 077; mkdir -p -- '$REMOTE_DIR'; chmod 700 -- '$REMOTE_DIR'"

filename="screenshot-$(date +%Y%m%d-%H%M%S)-$RANDOM-$$.png"
remote_path="$REMOTE_DIR/$filename"

scp -q "$tmp" "$DEVBOX_HOST:$remote_path"
ssh -o BatchMode=yes "$DEVBOX_HOST" "chmod 600 -- '$remote_path'" >/dev/null 2>&1 || true

printf %s "$remote_path" | pbcopy

echo "Uploaded to: $remote_path"
echo "(Path copied to clipboard)"
