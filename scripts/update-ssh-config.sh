#!/usr/bin/env bash
# Update local SSH config with devbox IP from Hetzner Cloud
set -euo pipefail

SERVER_NAME="devbox"
SSH_CONFIG="$HOME/.ssh/config"
MARKER_START="# BEGIN devbox managed block"
MARKER_END="# END devbox managed block"

# Get IP from hcloud
IP=$(hcloud server ip "$SERVER_NAME" 2>/dev/null) || {
    echo "Error: Could not get IP for server '$SERVER_NAME'"
    echo "Make sure hcloud is configured and the server exists"
    exit 1
}

# Generate SSH config block
read -r -d '' CONFIG_BLOCK << EOF || true
$MARKER_START
Host devbox
    HostName $IP
    User dev
    ForwardAgent yes
    # GPG agent forwarding
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/${USER}/.gnupg/S.gpg-agent.extra
    # Development tunnels (see troubleshooting-devbox skill for details)
    LocalForward 4000 localhost:4000
    LocalForward 4003 localhost:4003
    RemoteForward 9222 localhost:9222
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033
$MARKER_END
EOF

# Update SSH config
if grep -q "$MARKER_START" "$SSH_CONFIG" 2>/dev/null; then
    # Replace existing block (macOS sed)
    sed -i '' "/$MARKER_START/,/$MARKER_END/d" "$SSH_CONFIG"
    echo "" >> "$SSH_CONFIG"
    echo "$CONFIG_BLOCK" >> "$SSH_CONFIG"
    echo "Updated devbox entry in $SSH_CONFIG"
else
    # Append new block
    echo "" >> "$SSH_CONFIG"
    echo "$CONFIG_BLOCK" >> "$SSH_CONFIG"
    echo "Added devbox entry to $SSH_CONFIG"
fi

echo "Devbox IP: $IP"
