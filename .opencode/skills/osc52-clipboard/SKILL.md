---
name: osc52-clipboard
description: Use when copy/paste doesn't work over mosh/SSH, or clipboard not syncing between local and remote, or setting up terminal remoting with lemonade or OSC 52
---

# Clipboard Setup (Lemonade & OSC 52)

## Overview

We use two mechanisms for syncing the clipboard between the remote devbox/cloudbox and the local macOS environment:

1. **Lemonade (Primary)**: A TCP-based clipboard bridge. This is essential for **mosh** sessions (which do not support OSC 52 escape sequences natively) and is the primary mechanism.
2. **OSC 52 (Fallback)**: Terminal escape sequences. This works as a fallback for plain **SSH** sessions.

## Data Flow for Lemonade

```
Copy:  nvim yank → lemonade copy → TCP :2489 → SSH tunnel → macOS lemonade server → pbcopy
Paste: nvim paste → lemonade paste → TCP :2489 → SSH tunnel → macOS lemonade server → pbpaste → response
```

## How It's Configured in This Repo

### 1. Lemonade Server (macOS)

The lemonade server runs locally on macOS via `launchd` (`lemonade-server` agent) and listens on port `2489` (localhost only).

### 2. SSH Tunnels

SSH tunnels carry the lemonade traffic from the remote host back to macOS. The `devbox-tunnel` and `cloudbox-tunnel` SSH configurations include a `RemoteForward`:
```ssh-config
RemoteForward 2489 127.0.0.1:2489
```
This forwards port 2489 on the remote host to port 2489 on the local macOS machine.

### 3. tmux (`assets/tmux/extra.conf`)

tmux is configured to pipe copy-mode selections to lemonade, and also accept OSC 52 from apps as a fallback:

```tmux
set -s copy-command 'lemonade copy'  # Send copy-mode selections to lemonade
set -s set-clipboard on              # Accept OSC 52 from apps (fallback)
set -gq allow-passthrough on         # tmux 3.3+ passthrough support
set -as terminal-features ',xterm-256color:clipboard'  # Ms capability
```

*(Note: `lemonade copy` and `lemonade paste` replace the old `tcopy` and `tpaste` wrapper scripts.)*

### 4. Neovim (`assets/nvim/lua/user/settings.lua`)

Neovim automatically detects if `lemonade` is available on the remote host (via the `lemonade` executable and the active tunnel port). If so, it uses it for clipboard operations. Otherwise, it falls back to OSC 52.

```lua
-- WHEN to use clipboard (sync unnamed register with +)
vim.opt.clipboard = "unnamedplus"
```

### 5. Local Terminal (iTerm2 - for OSC 52 Fallback)

Preferences → General → Selection → Enable "Applications in terminal may access clipboard"

## Testing

### Test 1: Lemonade Remote Check

On the remote machine (devbox/cloudbox):
```bash
echo "test-lemonade" | lemonade copy
# Cmd+V locally should paste "test-lemonade"

# To test paste:
# Copy "hello-from-mac" on macOS, then run:
lemonade paste
# Should output "hello-from-mac"
```

### Test 2: Raw SSH OSC 52 (no tmux)

```bash
ssh devbox
printf '\033]52;c;%s\007' "$(printf 'test-raw' | base64 | tr -d '\n')"
# Cmd+V locally should paste "test-raw"
```

### Test 3: Inside tmux (Copy Mode)

```bash
# In tmux, enter copy mode, select text, and hit Enter (or y)
# Cmd+V locally should paste the selected text via lemonade copy
```

## Troubleshooting

### Lemonade Issues

**"Server not running" / "Connection refused" when running `lemonade copy`:**
1. Check if the SSH tunnel is active. The tunnel runs in the background (`ssh -N devbox-tunnel`). Ensure it hasn't died.
2. Verify the port is listening on the remote host: `netstat -tulpn | grep 2489`
3. Verify the macOS server is running: `launchctl list | grep lemonade` or `lsof -i :2489` on macOS.

**Port Conflicts:**
If port 2489 is already in use on either end, the tunnel will fail to bind. Check for stale SSH sessions holding the port.

### OSC 52 Issues

**If nvim yanks don't reach clipboard (when Lemonade is inactive):**

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

When using the **lemonade bridge**, Neovim and tmux can explicitly request the local clipboard contents via `lemonade paste`.

When falling back to **OSC 52**, it is primarily for **copy** (yank → local clipboard). Pasting from local clipboard into remote nvim typically uses your terminal's paste function (Cmd+V in insert mode, or terminal's paste bracketing).

## Images

OSC 52 and lemonade only handle **text**. For sharing images with Claude Code over SSH, use the [screenshot-to-devbox](../screenshot-to-devbox/SKILL.md) helper script, which:

1. Takes a screenshot on macOS
2. Uploads it to the devbox via scp
3. Copies the remote path to clipboard

Then paste the path into Claude Code:
```
Analyze this image: /home/dev/.cache/claude-images/screenshot-20240115-143022-12345.png
```