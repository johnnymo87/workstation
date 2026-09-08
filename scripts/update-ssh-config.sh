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

DEVBOX_IP=$(hcloud server ip devbox 2>/dev/null) || true
if [ -z "$DEVBOX_IP" ] && [ -f "$SSH_CONFIG" ]; then
    DEVBOX_IP=$(awk '/Host devbox$/{flag=1; next} flag && /HostName/{print $2; exit}' "$SSH_CONFIG" 2>/dev/null || true)
fi
if [ -z "$DEVBOX_IP" ]; then
    echo "Warning: Could not get IP for devbox (hcloud not configured and no existing SSH config entry)"
    echo "Skipping devbox block"
fi

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
    # Development tunnels (see troubleshooting-nixos-host skill for details)
    LocalForward 4000 localhost:4000
    LocalForward 4003 localhost:4003
    LocalForward 4005 localhost:4005
    LocalForward 4173 localhost:4173
    LocalForward 4400 localhost:4400
    LocalForward 1455 localhost:1455
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033
    # gclpr clipboard (remote copy/paste to macOS)
    RemoteForward 2850 127.0.0.1:2850
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
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null) || true
if [ -z "$CLOUDBOX_IP" ] && [ -f "$SSH_CONFIG" ]; then
    CLOUDBOX_IP=$(awk '/Host cloudbox$/{flag=1; next} flag && /HostName/{print $2; exit}' "$SSH_CONFIG" 2>/dev/null || true)
fi
if [ -z "$CLOUDBOX_IP" ]; then
    echo "Warning: Could not get IP for cloudbox (gcloud not configured and no existing SSH config entry)"
    echo "Skipping cloudbox block"
fi

# Jenkins hostname for the cloudbox RemoteForward below. Org-identifying, so it
# lives in the Keychain (service `jenkins-host`), never in this file. When the
# entry is absent the forward is simply omitted and the tunnel still comes up.
JENKINS_HOST=$(/usr/bin/security find-generic-password -s jenkins-host -w 2>/dev/null) || true
if [ -n "$JENKINS_HOST" ]; then
    JENKINS_FORWARD="    RemoteForward 8443 ${JENKINS_HOST}:443"
else
    echo "Warning: Keychain entry jenkins-host missing; omitting the Jenkins RemoteForward (reading-jenkins-builds skill)"
    JENKINS_FORWARD="    # RemoteForward 8443 <jenkins-host>:443  (Keychain entry jenkins-host was missing when this was generated)"
fi

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
    # mcp-remote OAuth callback (Atlassian instance)
    # Note: LocalForward 1455 (OpenCode OAuth) is owned exclusively by
    # devbox-tunnel; duplicating it here clashes under ExitOnForwardFailure.
    LocalForward 3334 localhost:3334
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033
    # gclpr clipboard (remote copy/paste to macOS)
    RemoteForward 2850 127.0.0.1:2850
    # Jenkins over this Mac's VPN session. cloudbox's loopback :443 proxies to
    # this port and its /etc/hosts maps the Jenkins hostname -> 127.0.0.1
    # (hosts/cloudbox/configuration.nix, jenkins-mac-proxy). The destination is
    # dialled per-connection, so this line cannot fail the tunnel at startup
    # even when the VPN is not yet up. Keep it OUT of \`Host cloudbox\` above: an
    # interactive login holding 8443 would kill the tunnel on its next restart
    # (ExitOnForwardFailure). Hostname from Keychain \`jenkins-host\`; see the
    # reading-jenkins-builds skill. Bead workstation-h559.
$JENKINS_FORWARD

# On-demand reverse SSH: opens cloudbox 127.0.0.1:2222 -> Mac :22 ONLY while a
# human runs \`ssh cloudbox-cutover\` from the Mac. This is the intentional
# channel for remote-driven cutovers / darwin-rebuild.
#
# SECURITY (2026-07): the RemoteForward 2222 used to live in the always-on
# \`cloudbox-tunnel\` block (driven by the cloudbox-dev-tunnel LaunchAgent),
# which meant a compromised public-IP cloudbox could \`ssh mac '<cmd>'\` at any
# time, unattended. It now lives here in a manual-only host so the reverse shell
# exists only during an operator-initiated window. Bringing it up still gives a
# full shell as your macOS user, so keep the window short; unattended root is separately
# disabled (see hosts/Y0FMQX93RR-2/configuration.nix enableUnattendedRemoteRoot)
# and durable revocation of the cloudbox key is a JumpCloud-console action.
Host cloudbox-cutover
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    RemoteForward 2222 127.0.0.1:22
$CLOUDBOX_MARKER_END
EOF

    upsert_block "$CLOUDBOX_MARKER_START" "$CLOUDBOX_MARKER_END" "$CLOUDBOX_BLOCK"
    echo "Cloudbox IP: $CLOUDBOX_IP"
fi
