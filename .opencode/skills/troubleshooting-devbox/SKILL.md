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

Check tunnel status:
```bash
launchctl list | grep dev-tunnel
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

## Commit Signing

Each host (macOS, devbox, cloudbox) has its own SSH signing key at
`~/.ssh/id_ed25519_signing`. Git is configured with `gpg.format = ssh`
and signs commits locally on whichever host you are using; no agent
forwarding is involved.

GitHub validates SSH-signed commits via each host's public key registered
under [Settings → SSH and GPG keys](https://github.com/settings/keys) as a
**Signing Key**. Local verification (`git verify-commit`, `git log
--show-signature`) uses `~/.config/git/allowed_signers`, deployed via
home-manager from `assets/git/allowed_signers`.

### Symptoms

- `git commit` fails with `error: gpg failed to sign the data`
- `git log --show-signature` shows `No principal matched`
- GitHub shows commits as "Unverified"

### Diagnose

```bash
git config --get gpg.format                   # expect: ssh
git config --get user.signingkey              # expect: ~/.ssh/id_ed25519_signing.pub
git config --get gpg.ssh.allowedSignersFile   # expect: ~/.config/git/allowed_signers
ls -la ~/.ssh/id_ed25519_signing*             # both files present, private key 0600
ssh-keygen -l -f ~/.ssh/id_ed25519_signing.pub   # fingerprint should match the
                                                 # corresponding line in
                                                 # ~/.config/git/allowed_signers
```

If `gpg.format` is missing or returns `openpgp`, home-manager has not
applied the SSH-signing config yet — re-run `nix run home-manager -- switch
--flake .#<host>` (or `darwin-rebuild` on macOS).

### Add a new host's signing key

1. On the new host: `ssh-keygen -t ed25519 -N '' -C '<email> (<host> signing)' -f ~/.ssh/id_ed25519_signing`
2. Append the new pubkey to `assets/git/allowed_signers` with the format `<email> namespaces="git" <pubkey> <hostname-tag>`
3. Apply home-manager on every host so the updated `allowed_signers` propagates: `nix run home-manager -- switch --flake .#<host>` (or `darwin-rebuild` on macOS)
4. Register the pubkey at <https://github.com/settings/ssh/new> with type **Signing Key** (NOT Authentication Key)
