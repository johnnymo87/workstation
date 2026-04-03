#!/usr/bin/env bash
# Update local SSH config with devbox and cloudbox IPs
set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"

# --- Helper ---

upsert_block() {
    local marker_start="$1"
    local marker_end="$2"
    local block="$3"

    if grep -q "$marker_start" "$SSH_CONFIG" 2>/dev/null; then
        sed -i '' "/$marker_start/,/$marker_end/d" "$SSH_CONFIG"
    fi
    echo "" >> "$SSH_CONFIG"
    echo "$block" >> "$SSH_CONFIG"
}

# --- Devbox (Hetzner) ---

DEVBOX_MARKER_START="# BEGIN devbox managed block"
DEVBOX_MARKER_END="# END devbox managed block"

DEVBOX_IP=$(hcloud server ip devbox 2>/dev/null) || {
    echo "Warning: Could not get IP for devbox (hcloud not configured?)"
    echo "Skipping devbox block"
    DEVBOX_IP=""
}

if [ -n "$DEVBOX_IP" ]; then
    read -r -d '' DEVBOX_BLOCK << EOF || true
$DEVBOX_MARKER_START
Host devbox
    HostName $DEVBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033

Host devbox-tunnel
    HostName $DEVBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Development tunnels (see troubleshooting-devbox skill for details)
    LocalForward 4000 localhost:4000
    LocalForward 4003 localhost:4003
    LocalForward 4005 localhost:4005
    LocalForward 4173 localhost:4173
    LocalForward 1455 localhost:1455
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033
    # Lemonade clipboard (remote copy/paste to macOS)
    RemoteForward 2489 127.0.0.1:2489

# Persistent GPG agent forwarding (kept alive by launchd on macOS).
# GPG forwarding is isolated here so it doesn't contend with interactive
# SSH sessions or claim LocalForward ports from devbox-tunnel.
Host devbox-gpg-tunnel
    HostName $DEVBOX_IP
    User dev
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Rebind stale socket when tunnel reconnects
    StreamLocalBindUnlink yes
    # GPG agent forwarding
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/${USER}/.gnupg/S.gpg-agent.extra
$DEVBOX_MARKER_END
EOF

    upsert_block "$DEVBOX_MARKER_START" "$DEVBOX_MARKER_END" "$DEVBOX_BLOCK"
    echo "Devbox IP: $DEVBOX_IP"
fi

# --- Cloudbox (GCP) ---

CLOUDBOX_MARKER_START="# BEGIN cloudbox managed block"
CLOUDBOX_MARKER_END="# END cloudbox managed block"

CLOUDBOX_IP=$(gcloud compute instances describe cloudbox \
    --zone=us-east1-b \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null) || {
    echo "Warning: Could not get IP for cloudbox (gcloud not configured?)"
    echo "Skipping cloudbox block"
    CLOUDBOX_IP=""
}

if [ -n "$CLOUDBOX_IP" ]; then
    read -r -d '' CLOUDBOX_BLOCK << EOF || true
$CLOUDBOX_MARKER_START
Host cloudbox
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033

Host cloudbox-tunnel
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # OpenCode OAuth callback
    LocalForward 1455 localhost:1455
    # mcp-remote OAuth callbacks (default + alt Atlassian instances)
    LocalForward 3334 localhost:3334
    LocalForward 3335 localhost:3335
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033
    # Lemonade clipboard (remote copy/paste to macOS)
    RemoteForward 2489 127.0.0.1:2489

# Persistent GPG agent forwarding (kept alive by launchd on macOS).
Host cloudbox-gpg-tunnel
    HostName $CLOUDBOX_IP
    User dev
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Rebind stale socket when tunnel reconnects
    StreamLocalBindUnlink yes
    # GPG agent forwarding
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/${USER}/.gnupg/S.gpg-agent.extra
$CLOUDBOX_MARKER_END
EOF

    upsert_block "$CLOUDBOX_MARKER_START" "$CLOUDBOX_MARKER_END" "$CLOUDBOX_BLOCK"
    echo "Cloudbox IP: $CLOUDBOX_IP"
fi
