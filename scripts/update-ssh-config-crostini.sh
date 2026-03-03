#!/usr/bin/env bash
# Update Crostini SSH config with devbox IP (no hcloud dependency)
#
# Usage: ./scripts/update-ssh-config-crostini.sh <devbox-ip>
#
# Generates two SSH hosts:
#   devbox        — interactive sessions + Chrome CDP reverse tunnel
#   devbox-tunnel — adds local forward for citadels UI (port 4173)
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <devbox-ip>"
    echo "Example: $0 5.78.100.42"
    exit 1
fi

IP="$1"
SSH_CONFIG="$HOME/.ssh/config"
MARKER_START="# BEGIN devbox managed block"
MARKER_END="# END devbox managed block"

# Ensure .ssh directory and config file exist
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Generate SSH config block
read -r -d '' CONFIG_BLOCK << EOF || true
$MARKER_START
Host devbox
    HostName $IP
    User dev
    ForwardAgent yes
    # Chrome DevTools Protocol: Crostini browser -> devbox AI
    RemoteForward 9222 localhost:9222

Host devbox-tunnel
    HostName $IP
    User dev
    ForwardAgent yes
    # Citadels UI: devbox -> Crostini browser
    LocalForward 4173 localhost:4173
    # Chrome DevTools Protocol: Crostini browser -> devbox AI
    RemoteForward 9222 localhost:9222
$MARKER_END
EOF

# Update SSH config
if grep -q "$MARKER_START" "$SSH_CONFIG" 2>/dev/null; then
    # Replace existing block (GNU sed on Crostini)
    sed -i "/$MARKER_START/,/$MARKER_END/d" "$SSH_CONFIG"
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
