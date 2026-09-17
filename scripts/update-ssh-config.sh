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
    # No ForwardAgent: nothing on devbox needs this Mac's SSH identity, so
    # lending it out bought nothing and risked a devbox compromise
    # authenticating as you against OTHER hosts. Verified 2026-09-12: devbox's
    # known_hosts contains only github.com and has not changed since
    # 2026-01-15; it reaches GitHub with its own sops-deployed key under
    # \`IdentitiesOnly yes\` (which ignores a forwarded agent anyway); commit
    # signing uses an on-disk key, not an agent. The line dated from this
    # file's FIRST commit (4cfef74), alongside a since-deleted GPG socket
    # forward, and predated the sops GitHub key by ~16 hours -- i.e. it was
    # plausibly load-bearing for one afternoon in January and residue after.
    # Same reasoning as the deliberate omission on \`cloudbox-chart\` below.
    # If you ever genuinely need it for a one-off, \`ssh -A devbox\`.
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
    # No ForwardAgent -- see the \`Host devbox\` block above.
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
    # Match `Host cloudbox` with or without the trailing IP alias -- the block
    # emitted below is `Host cloudbox <IP>` (for mosh; see there), and anchoring
    # on `cloudbox$` would stop matching the file this very script writes,
    # silently disabling IP rediscovery exactly when gcloud auth has expired and
    # this fallback is the only thing left.
    CLOUDBOX_IP=$(awk '/^Host cloudbox( |$)/{flag=1; next} flag && /HostName/{print $2; exit}' "$SSH_CONFIG" 2>/dev/null || true)
fi
if [ -z "$CLOUDBOX_IP" ]; then
    echo "Warning: Could not get IP for cloudbox (gcloud not configured and no existing SSH config entry)"
    echo "Skipping cloudbox block"
fi

# --- IAP transport for cloudbox ---
#
# Every cloudbox host block reaches sshd through an IAP TCP forwarding tunnel
# rather than dialling the public IP directly. This exists because the direct
# path was gated by a GCP firewall rule pinned to this Mac's Cloudflare WARP
# egress /32, and that egress ROTATES -- when it did, gclpr (2850), Chrome CDP
# (9222/9223), chatgpt-relay (3033) and the Jenkins forward (8443) all went down
# together, while ICMP kept answering because default-allow-icmp is 0.0.0.0/0.
# IAP's source range (35.235.240.0/20) is fixed, so source IP stops mattering.
#
# Authenticated by a dedicated service account, NOT by your user credentials:
# user creds are subject to the daily Google session-control reauth, so a
# user-cred tunnel would break every morning -- which is the very thing the
# forwarded CDP port exists to automate away. The SA lives in an isolated
# CLOUDSDK_CONFIG so activating it cannot disturb your normal gcloud account.
# It can do exactly two things: read this one instance, and open an IAP tunnel
# to port 22 (an IAM condition, verified: port 4710 returns 4033 not-authorized).
#
# `--listen-on-stdin` is a HIDDEN flag -- it is absent from `gcloud compute
# start-iap-tunnel --help` on 537.0.0, but it is real and is what `gcloud
# compute ssh --tunnel-through-iap` uses internally. Verified working here.
# Without it you would need a listening port plus nc, which races on startup.
#
# The gcloud path is the per-user profile symlink, deliberately NOT the
# /nix/store path it points at: a store path baked into ~/.ssh/config would be
# garbage-collected out from under the tunnel on the next GC.
GCLOUD_BIN="/etc/profiles/per-user/$USER/bin/gcloud"
IAP_CONFIG="$HOME/.config/gcloud-tunnel/config"
IAP_PROXY="    ProxyCommand env CLOUDSDK_CONFIG=$IAP_CONFIG $GCLOUD_BIN compute start-iap-tunnel cloudbox 22 --listen-on-stdin --zone=us-east1-b --project=wonder-sandbox"

if [ ! -d "$IAP_CONFIG" ]; then
    echo "Warning: $IAP_CONFIG missing -- the IAP service account is not set up on this machine."
    echo "         Emitting cloudbox blocks WITHOUT the IAP ProxyCommand; they will only work"
    echo "         from an allowlisted source IP. See docs/plans/2026-09-17-iap-tunnel-cutover.md."
    IAP_PROXY="    # ProxyCommand omitted: $IAP_CONFIG did not exist when this was generated"
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
# The IP literal is a deliberate second pattern, not redundancy. \`mosh\` under
# --experimental-remote-ip=local (which the \`mosh\` alias forces; see
# home.darwin.nix) REWRITES the host to the literal IP before exec'ing ssh, so a
# block keyed only on the name would be skipped and mosh would silently take the
# unproxied direct path -- the exact fragility this cutover removes.
Host cloudbox $CLOUDBOX_IP
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
$IAP_PROXY
    # Pin the host identity to the IP no matter which of the two patterns above
    # was used to get here, so every spelling shares one known_hosts entry.
    HostKeyAlias $CLOUDBOX_IP
    # Chrome DevTools Protocol (one port per project, each needs its own Chrome instance)
    RemoteForward 9222 localhost:9222
    RemoteForward 9223 localhost:9223
    # chatgpt-relay tunnel (ask-question CLI)
    RemoteForward 3033 localhost:3033

# IAP is the default transport; \`cloudbox-tunnel-direct\` is the same tunnel
# dialled straight at the public IP, kept as a fallback for a Google-side IAP
# outage. It only works from a source the firewall still allows -- today that is
# the home ISP range (dev-ssh-client), i.e. WARP off -- so it is a real but
# conditional escape hatch, not an equivalent path. The tunnel LaunchAgent
# alternates between the two after repeated failures (home.darwin.nix).
#
# The ProxyCommand sits in its OWN stanza so the two hosts can SHARE the single
# forward list below. ssh takes the first value it obtains for each option, so
# cloudbox-tunnel picks up the proxy here and cloudbox-tunnel-direct does not,
# while both then inherit one copy of the forwards. Duplicating that list would
# let the two drift, and a forward that exists on only one path fails as a
# mystery on whichever path nobody tested.
Host cloudbox-tunnel
$IAP_PROXY

Host cloudbox-tunnel cloudbox-tunnel-direct
    HostName $CLOUDBOX_IP
    User dev
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    HostKeyAlias $CLOUDBOX_IP
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
$IAP_PROXY
    HostKeyAlias $CLOUDBOX_IP
    RemoteForward 2222 127.0.0.1:22

# Chart tunnel: reaches cloudbox's loopback 4710, where \`oc-tags serve\` runs.
# No manual \`ssh -N\` is needed -- just open http://127.0.0.1:4710. The
# socket-activated \`cloudbox-chart-tunnel\` LaunchAgent
# (users/dev/home.darwin.nix) owns that port and runs \`ssh -W\` through THIS
# host block on demand. Since \`-W\` implies ClearAllForwardings, the
# LocalForward below is ignored on that path; it is what makes the manual
# \`ssh -N cloudbox-chart\` fallback still work.
#
# Deliberately NOT a forward on the always-on \`cloudbox-tunnel\` block above --
# not because that block is remote-only (it already has LocalForward 3334), but
# because :4710 has plausible local colliders that 3334 does not: a
# muscle-memory \`ssh -N cloudbox-chart\`, or an \`oc-tags serve\` running on this
# Mac. That block runs under ExitOnForwardFailure=yes, so a bind clash there
# kills the whole tunnel, taking gclpr (2850), chatgpt-relay (3033) and the
# Jenkins :8443 forward with it -- the same reason LocalForward 1455 is owned
# exclusively by devbox-tunnel (see the note above). A separate agent contains
# the blast radius to the chart.
#
# No ForwardAgent here: this host exists only to carry the forward, and the
# LaunchAgent's \`ssh -N\` opens no session channel to forward an agent over
# anyway. Omitting it means an interactive \`ssh cloudbox-chart\` run while
# debugging does not hand this Mac's SSH agent to a public-IP VM.
#
# This path pays the IAP ProxyCommand's startup (a gcloud process per
# connection) on top of the ~0.5s the socket-activated \`ssh -W\` already costs,
# because launchd spawns one ssh per accepted connection and each brings up its
# own tunnel. Measured 2026-09-17, \`ssh ... true\` best of 3: direct 0.32s, IAP
# 1.74s, so about +1.4s per connection. Accepted: the chart is opened by hand,
# occasionally, and a chart that loads slower is better than one that stops
# loading whenever the WARP egress rotates.
Host cloudbox-chart
    HostName $CLOUDBOX_IP
    User dev
    ServerAliveInterval 60
    ServerAliveCountMax 3
$IAP_PROXY
    HostKeyAlias $CLOUDBOX_IP
    LocalForward 4710 127.0.0.1:4710
$CLOUDBOX_MARKER_END
EOF

    upsert_block "$CLOUDBOX_MARKER_START" "$CLOUDBOX_MARKER_END" "$CLOUDBOX_BLOCK"
    echo "Cloudbox IP: $CLOUDBOX_IP"
fi
