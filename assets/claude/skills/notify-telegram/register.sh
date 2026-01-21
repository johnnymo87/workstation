#!/usr/bin/env bash
# Register current Claude Code session for Telegram notifications
set -euo pipefail

LABEL="${1:-$(basename "$PWD")}"
DAEMON_URL="http://localhost:4731"

# Find session ID from most recent transcript in this project
# Claude Code uses path with slashes replaced by dashes, prefixed with dash
PROJECT_KEY="$(pwd | sed 's|/|-|g')"
TRANSCRIPT_DIR="$HOME/.claude/projects/$PROJECT_KEY"

if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
    echo "Error: No transcript directory found at $TRANSCRIPT_DIR"
    echo "Are you running this from within a Claude Code session?"
    exit 1
fi

# Get the most recently modified .jsonl file
LATEST_TRANSCRIPT=$(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)

if [[ -z "$LATEST_TRANSCRIPT" ]]; then
    echo "Error: No transcript files found in $TRANSCRIPT_DIR"
    exit 1
fi

# Extract session ID from filename
SESSION_ID=$(basename "$LATEST_TRANSCRIPT" .jsonl)

echo "Session ID: $SESSION_ID"
echo "Label: $LABEL"

# Check daemon is running
if ! curl -sf "$DAEMON_URL/health" >/dev/null 2>&1; then
    echo "Error: Daemon not responding at $DAEMON_URL"
    echo "Start it with: cd ~/projects/claude-code-remote && node start-telegram-webhook.js"
    exit 1
fi

echo "Daemon: running"

# Step 1: Register session with daemon
echo -n "Registering session... "
REGISTER_RESULT=$(curl -sf -X POST "$DAEMON_URL/session-start" \
    -H "Content-Type: application/json" \
    -d "{\"session_id\": \"$SESSION_ID\", \"cwd\": \"$PWD\"}" 2>&1) || {
    echo "FAILED"
    echo "Error: $REGISTER_RESULT"
    exit 1
}
echo "OK"

# Step 2: Enable notifications
echo -n "Enabling notifications... "
NOTIFY_RESULT=$(curl -sf -X POST "$DAEMON_URL/sessions/enable-notify" \
    -H "Content-Type: application/json" \
    -d "{\"session_id\": \"$SESSION_ID\", \"label\": \"$LABEL\", \"nvim_socket\": \"${NVIM:-}\"}" 2>&1) || {
    echo "FAILED"
    echo "Error: $NOTIFY_RESULT"
    exit 1
}
echo "OK"

# Step 3: Create runtime files for hooks
RUNTIME_DIR="$HOME/.claude/runtime/sessions/$SESSION_ID"
mkdir -p "$RUNTIME_DIR"
echo "$LABEL" > "$RUNTIME_DIR/notify_label"
echo "Runtime: $RUNTIME_DIR/notify_label"

# Step 4: Register with nvim if in nvim terminal
if [[ -n "${NVIM:-}" ]]; then
    echo -n "Registering with nvim... "
    if nvim --server "$NVIM" --remote-expr "execute('CCRegister $LABEL')" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "SKIPPED (ccremote plugin not loaded?)"
    fi
fi

echo ""
echo "Telegram notifications enabled for session: $SESSION_ID ($LABEL)"
