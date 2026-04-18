---
name: troubleshooting-devbox
description: Use when SSH connection fails, host key mismatch, NixOS issues, CPU/IO contention (high load), or verifying devbox is properly configured
---

# Troubleshooting Devbox

## Overview

Common issues and fixes for the Hetzner NixOS remote development environment.

## Connection Model

Interactive sessions use **mosh** for persistence (survives sleep/wake, network changes):

```bash
mosh devbox -- tmux attach -t 1    # Persistent session via mosh + tmux
mosh cloudbox -- tmux attach -t 1
```

Port forwarding runs via **persistent SSH tunnel launchd agents** on macOS (always-on, independent of interactive sessions):

| Agent | SSH Host | Purpose |
|-------|----------|---------|
| `devbox-dev-tunnel` | `devbox-tunnel` | Dev ports + gclpr + CDP + chatgpt-relay |
| `cloudbox-dev-tunnel` | `cloudbox-tunnel` | Dev ports + gclpr + CDP + chatgpt-relay |
| `devbox-gpg-tunnel` | `devbox-gpg-tunnel` | GPG agent forwarding only |
| `cloudbox-gpg-tunnel` | `cloudbox-gpg-tunnel` | GPG agent forwarding only |

Check tunnel status:
```bash
launchctl list | grep -E '(dev|gpg)-tunnel'
```

Restart a tunnel:
```bash
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.devbox-dev-tunnel
```

## Port Forwarding

Ports are configured in `scripts/update-ssh-config.sh` and carried by the persistent tunnel agents.

### devbox-tunnel ports

| Port | Direction | Purpose |
|------|-----------|---------|
| 4000 | Local (-L) | eternal-machinery dev server |
| 4003 | Local (-L) | eternal-machinery (secondary) |
| 4005 | Local (-L) | eternal-machinery (tertiary) |
| 4173 | Local (-L) | citadels Vite dev server |
| 1455 | Local (-L) | OpenCode OAuth callback |
| 9222 | Remote (-R) | Chrome DevTools Protocol - project A |
| 9223 | Remote (-R) | Chrome DevTools Protocol - project B |
| 3033 | Remote (-R) | chatgpt-relay (`/ask-question` CLI) |
| 2850 | Remote (-R) | gclpr clipboard (copy/paste to macOS) |

### cloudbox-tunnel ports

| Port | Direction | Purpose |
|------|-----------|---------|
| 1455 | Local (-L) | OpenCode OAuth callback |
| 3334 | Local (-L) | mcp-remote OAuth (default Atlassian) |
| 3335 | Local (-L) | mcp-remote OAuth (alt Atlassian) |
| 9222 | Remote (-R) | Chrome DevTools Protocol - project A |
| 9223 | Remote (-R) | Chrome DevTools Protocol - project B |
| 3033 | Remote (-R) | chatgpt-relay (`/ask-question` CLI) |
| 2850 | Remote (-R) | gclpr clipboard (copy/paste to macOS) |

**Local forwards (-L):** devbox/cloudbox service → accessible on macOS localhost
**Remote forwards (-R):** macOS service → accessible on remote localhost

**Note:** Both tunnels share `LocalForward 1455`. The agents use `ExitOnForwardFailure=no` so whichever starts first gets 1455; the other logs a warning but keeps all other forwards alive. OAuth is interactive and one-at-a-time, so this is fine.

### Multi-project CDP

Each project that uses human-in-the-loop visual QA needs its own Chrome instance on macOS with a unique `--remote-debugging-port` and `--user-data-dir`. Both CDP ports are reverse-forwarded over the same SSH session. See each project's VQA skill for the specific Chrome launch command and MCP server name (`chrome-devtools-9222` or `chrome-devtools-9223`).

## Can't SSH After Recreate

Host key changed because server was recreated with new IP or reinstalled.

```bash
# Remove old host key
ssh-keygen -R devbox
ssh-keygen -R $(hcloud server ip devbox)

# Reconnect with new key acceptance
ssh -o StrictHostKeyChecking=accept-new devbox
```

## Verify NixOS Installation

Check NixOS version:

```bash
ssh devbox 'nixos-version'
# Expected: 24.11... (Vicuna)
```

Check tools are installed:

```bash
ssh devbox 'tmux -V && nvim --version | head -1 && mise --version'
```

## NixOS Configuration Issues

View current system generation:

```bash
ssh devbox 'sudo nix-env --list-generations --profile /nix/var/nix/profiles/system'
```

Rollback to previous generation:

```bash
ssh devbox 'sudo nixos-rebuild switch --rollback'
```

Check system journal for errors:

```bash
ssh devbox 'journalctl -b --priority=err'
```

## nixos-anywhere Deployment Failed

If deployment fails mid-way, the server may be in an inconsistent state.

Check if server is accessible:

```bash
# Try root (during nixos-anywhere)
ssh root@$(hcloud server ip devbox) 'uname -a'

# Try dev (after completion)
ssh dev@$(hcloud server ip devbox) 'uname -a'
```

If stuck, use Hetzner rescue mode:

```bash
hcloud server enable-rescue devbox --type linux64
hcloud server reboot devbox
# Then SSH as root with rescue password from console
```

Or just destroy and recreate:

```bash
/rebuild
```

## Verify SSH Hardening

```bash
# Should fail (root login disabled):
ssh root@$(hcloud server ip devbox) 'echo test'

# Should work:
ssh dev@$(hcloud server ip devbox) 'echo test'
```

## Connection Timeout / Slow

Check latency:

```bash
ping -c 5 $(hcloud server ip devbox)
```

Helsinki datacenter latency from US East: ~100-150ms (acceptable for terminal work).

## Server Not Responding

Check Hetzner console:

```bash
hcloud server list
hcloud server describe devbox
```

Power cycle if needed:

```bash
hcloud server reboot devbox
```

## CPU / IO Contention (High Load)

### Symptoms
- Mosh shows "last contact X ago" with blue status bar, but SSH still connects
- Commands over SSH hang or time out (even `ps`, `top`)
- Load average far exceeds core count (e.g. load 80 on 16 cores)

### Quick Diagnosis

```bash
# Check load (reads /proc directly, works even under extreme load)
ssh devbox 'cat /proc/loadavg'

# Count runnable + blocked processes
# Format: load1 load5 load15 running/total lastpid
# "running" >> cores = oversubscribed

# Check memory (if this times out, problem is CPU not memory)
ssh devbox 'cat /proc/meminfo | head -5'

# Process count by name (lighter than ps/top)
ssh devbox 'for f in /proc/[0-9]*/comm; do cat "$f" 2>/dev/null; done | sort | uniq -c | sort -rn | head -20'
```

### Common Causes

1. **Too many opencode subagents** — parallel subagent dispatch triggers concurrent nix evaluations via direnv, each consuming CPU and IO
2. **pull-workstation rebuild** — home-manager switch compounding an already-loaded system
3. **devenv services left running** — postgres, BEAM, etc. running 24/7 across multiple projects

### Mitigations In Place

Resource controls prevent this from becoming unrecoverable:

| Layer | Setting | Devbox | Cloudbox |
|-------|---------|--------|----------|
| nix-daemon | `CPUSchedulingPolicy` | batch | batch |
| nix-daemon | `IOSchedulingClass` | idle | idle |
| nix-daemon | `max-jobs` | 8 (of 16) | 2 (of 4) |
| nix-daemon | `cores` | 2 | 2 |
| pull-workstation | `Nice` | 15 | 15 |
| pull-workstation | `CPUQuota` | 200% | 200% |
| pull-workstation | `IOSchedulingClass` | idle | idle |
| user-1000 slice | `TasksMax` | 2048 | 512 |
| sshd | `CPUWeight` | 200 | 200 |

These ensure nix builds and background updates yield to interactive sessions (mosh, tmux, opencode). SSH gets elevated CPU scheduling priority.

### If Load Is Still Too High

If the box is unresponsive despite mitigations:

```bash
# From macOS — reboot via cloud API (doesn't need SSH)
hcloud server reboot devbox  # Hetzner devbox
# For cloudbox: use GCP console or gcloud CLI
```

Tmux sessions are lost but the load clears. Mosh will reconnect automatically after reboot.

### Post-Mortem Investigation

After a reboot, check the previous boot's journal:

```bash
# Resource accounting per tmux session
journalctl -b -1 --no-pager -u "user@1000.service" | grep "Consumed"

# Check for OOM kills
journalctl -b -1 -k | grep -i "oom\|killed"

# nix-daemon IO during the incident
journalctl -b -1 -u nix-daemon | tail -5
```

## Disk Space Issues

NixOS can accumulate old generations. Clean up:

```bash
ssh devbox 'sudo nix-collect-garbage --delete-older-than 7d'
ssh devbox 'sudo nix-store --optimise'
```

Check disk usage:

```bash
ssh devbox 'df -h /'
```

## Systemd User Timers

The devbox runs several user-level timers for automation.

### Check Timer Status

```bash
# List all user timers
systemctl --user list-timers

# Specific timers
systemctl --user status pull-workstation.timer
systemctl --user status home-manager-auto-expire.timer
```

### View Timer Logs

```bash
# Auto-update pull logs
journalctl --user -u pull-workstation -n 50

# Generation cleanup logs
journalctl --user -u home-manager-auto-expire -n 50
```

### Timer Not Running

If a timer isn't active after `home-manager switch`:

```bash
# Reload systemd
systemctl --user daemon-reload

# Enable and start timer
systemctl --user enable --now pull-workstation.timer
```

See [Automated Updates](../automated-updates/SKILL.md) for full details on the update pipeline.

## GPG Agent Forwarding

The devbox is configured to forward your local GPG agent so you can sign commits on the remote machine using your local keys (and Touch ID via 1Password).

### Symptoms
- `gpg --card-status` on devbox hangs or says "No such device"
- Commits fail with "error: gpg failed to sign the data"
- You see `gpg: problem with fast path key listing: Forbidden - ignored`

### Fix: Stale Local Socket
If the local agent socket (`~/.gnupg/S.gpg-agent.extra`) gets into a bad state (e.g. after sleep/wake), the connection breaks.

Run this **locally on macOS** to reload the agent:
```bash
gpg-connect-agent reloadagent /bye
```

### Fix: Stale Remote Forwarded Socket
If reconnecting still leaves GPG broken on devbox, the remote socket path can be stale.

Run this on **devbox**:
```bash
rm -f /run/user/1000/gnupg/S.gpg-agent
```

Then reconnect from macOS and test on devbox:
```bash
echo test | gpg --clearsign >/dev/null && echo ok
```

### Hardening Note
`scripts/update-ssh-config.sh` configures `StreamLocalBindUnlink yes` on `devbox-gpg-tunnel` and `cloudbox-gpg-tunnel`.
This lets SSH automatically unlink stale remote unix sockets before binding forwarded sockets.

### Note: Fast Path Warning
You may see this warning when running GPG commands on devbox:
`gpg: problem with fast path key listing: Forbidden - ignored`

**This is normal and harmless.** It happens because we forward the restricted `extra` socket, which blocks certain administrative commands (like listing secret keys in fast mode). GnuPG automatically falls back to the standard mode, and signing works fine.

### Persistent Tunnel

Dedicated `launchd` agents on macOS keep the GPG forwarding alive in the background:
- `devbox-gpg-tunnel` — forwards GPG agent socket to devbox
- `cloudbox-gpg-tunnel` — forwards GPG agent socket to cloudbox

These use isolated SSH hosts (`devbox-gpg-tunnel`, `cloudbox-gpg-tunnel`) that only
forward the GPG socket, avoiding port contention with interactive `*-tunnel` sessions.

Check tunnel status on macOS:
```bash
launchctl list | grep gpg-tunnel
```

If a tunnel is down, restart it:
```bash
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.devbox-gpg-tunnel
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.cloudbox-gpg-tunnel
```

`opencode-launch` warns if the forwarded socket is missing before launching a session.
