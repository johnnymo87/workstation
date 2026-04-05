---
name: clipboard
description: Use when copy/paste doesn't work over mosh/SSH, or clipboard not syncing between local and remote, or setting up terminal remoting with gclpr or OSC 52
---

# Clipboard Setup (gclpr & OSC 52)

## Overview

We use two mechanisms for syncing the clipboard between the remote devbox/cloudbox and the local macOS environment:

1. **gclpr (Primary)**: A TCP-based clipboard bridge with NaCl key-pair authentication. This is essential for **mosh** sessions (which do not support OSC 52 escape sequences natively) and is the primary mechanism.
2. **OSC 52 (Fallback)**: Terminal escape sequences. This works as a fallback for plain **SSH** sessions.

## Data Flow for gclpr

```
Copy:  nvim yank → gclpr copy → TCP :2850 (signed) → SSH tunnel → macOS gclpr server → pbcopy
Paste: nvim paste → gclpr paste → TCP :2850 (signed) → SSH tunnel → macOS gclpr server → pbpaste → response
```

## How It's Configured in This Repo

### 1. gclpr Server (macOS)

The gclpr server runs locally on macOS via `launchd` (`gclpr-server` agent) and listens on port `2850` (default). It uses NaCl key-pair authentication — authorized public keys are listed in `~/.gclpr/trusted`.

### 2. SSH Tunnels

SSH tunnels carry the gclpr traffic from the remote host back to macOS. The `devbox-tunnel` and `cloudbox-tunnel` SSH configurations include a `RemoteForward`:
```ssh-config
RemoteForward 2850 127.0.0.1:2850
```
This forwards port 2850 on the remote host to port 2850 on the local macOS machine.

### 3. tmux (`assets/tmux/extra.conf`)

tmux is configured to pipe copy-mode selections to gclpr, and also accept OSC 52 from apps as a fallback:

```tmux
if-shell 'test -f ~/.gclpr/key' 'set -s copy-command "gclpr copy"'  # Remote hosts only
set -s set-clipboard on              # Accept OSC 52 from apps (fallback)
set -gq allow-passthrough on         # tmux 3.3+ passthrough support
set -as terminal-features ',xterm-256color:clipboard'  # Ms capability
```

The `if-shell` guard ensures the copy-command is only set on remote hosts that have the gclpr client key. On macOS, tmux uses pbcopy natively.

### 4. Neovim (`assets/nvim/lua/user/settings.lua`)

Neovim automatically detects if `gclpr` is available on the remote host (via the `gclpr` executable and the active tunnel port). If so, it uses it for clipboard operations. Otherwise, it falls back to OSC 52.

```lua
-- WHEN to use clipboard (sync unnamed register with +)
vim.opt.clipboard = "unnamedplus"
```

### 5. Local Terminal (iTerm2 - for OSC 52 Fallback)

Preferences → General → Selection → Enable "Applications in terminal may access clipboard"

## Key Management

gclpr uses NaCl key-pair authentication:

- **Private key** (`~/.gclpr/key`, 64 bytes): Deployed to remote hosts via sops-nix activation script
- **Public key** (`~/.gclpr/key.pub`, 32 bytes): Deployed to remote hosts via `home.file`
- **Trusted keys** (`~/.gclpr/trusted`, macOS only): Contains hex-encoded public keys, managed by `home.file` on Darwin

## Testing

### Test 1: gclpr Remote Check

On the remote machine (devbox/cloudbox):
```bash
echo "test-gclpr" | gclpr copy
# Cmd+V locally should paste "test-gclpr"

# To test paste:
# Copy "hello-from-mac" on macOS, then run:
gclpr paste
# Should output "hello-from-mac"
```

### Test 2: UTF-8 Round-Trip

```bash
echo "café résumé 日本語 🎉" | gclpr copy
gclpr paste
# Should output "café résumé 日本語 🎉" with all characters intact
```

### Test 3: Raw SSH OSC 52 (no tmux)

```bash
ssh devbox
printf '\033]52;c;%s\007' "$(printf 'test-raw' | base64 | tr -d '\n')"
# Cmd+V locally should paste "test-raw"
```

### Test 4: Inside tmux (Copy Mode)

```bash
# In tmux, enter copy mode, select text, and hit Enter (or y)
# Cmd+V locally should paste the selected text via gclpr copy
```

## Troubleshooting

### gclpr Issues

**"Connection refused" when running `gclpr copy`:**
1. Check if the SSH tunnel is active. The tunnel runs in the background (`ssh -N devbox-tunnel`). Ensure it hasn't died.
2. Verify the port is listening on the remote host: `netstat -tulpn | grep 2850`
3. Verify the macOS server is running: `launchctl list | grep gclpr` or `lsof -i :2850` on macOS.

**"authentication failed" or "bad signature":**
1. Verify the private key exists on the remote host: `ls -la ~/.gclpr/key` (should be 64 bytes, mode 400)
2. Verify the public key matches: compare `xxd ~/.gclpr/key.pub` on remote with the hex in `~/.gclpr/trusted` on macOS
3. Re-deploy keys: `nix run home-manager -- switch --flake .#dev` on remote

**Port Conflicts:**
If port 2850 is already in use on either end, the tunnel will fail to bind. Check for stale SSH sessions holding the port.

### OSC 52 Issues

**If nvim yanks don't reach clipboard (when gclpr is inactive):**

Check that `vim.opt.clipboard = "unnamedplus"` is set. Without this, yanks go to the unnamed register, not the `+` register that OSC 52 uses.

**If tmux fallback fails**, check:
```bash
tmux show -s set-clipboard    # Should be: on
tmux info | grep 'Ms:'        # Should NOT say [missing]
```

**After changing tmux config:** Must restart tmux server, not just detach/attach:
```bash
tmux kill-server
```

## Note on Paste

When using the **gclpr bridge**, Neovim and tmux can explicitly request the local clipboard contents via `gclpr paste`.

When falling back to **OSC 52**, it is primarily for **copy** (yank → local clipboard). Pasting from local clipboard into remote nvim typically uses your terminal's paste function (Cmd+V in insert mode, or terminal's paste bracketing).

## Images

OSC 52 and gclpr only handle **text**. For sharing images with Claude Code over SSH, use the [screenshot-to-devbox](../screenshot-to-devbox/SKILL.md) helper script, which:

1. Takes a screenshot on macOS
2. Uploads it to the devbox via scp
3. Copies the remote path to clipboard

Then paste the path into Claude Code:
```
Analyze this image: /home/dev/.cache/claude-images/screenshot-20240115-143022-12345.png
```