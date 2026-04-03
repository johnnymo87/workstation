# Lemonade Clipboard Bridge Design

**Goal:** Replace OSC 52 clipboard (broken through mosh) with a TCP-based clipboard bridge using lemonade, enabling copy and paste between remote Neovim/tmux and macOS clipboard over mosh sessions.

**Architecture:** Lemonade server on macOS exposes pbcopy/pbpaste over TCP port 2489. Existing persistent SSH dev tunnels carry a RemoteForward for this port. Remote lemonade client connects to localhost:2489 for copy/paste operations.

## Components

### 1. macOS: lemonade server (launchd agent)

New launchd agent in `home.darwin.nix`. Runs `lemonade server` at login, auto-restarts on failure. Same pattern as GPG tunnel agents.

### 2. SSH tunnels: RemoteForward 2489

Add `RemoteForward 2489 localhost:2489` to `devbox-tunnel` and `cloudbox-tunnel` host blocks in `update-ssh-config.sh`. Piggybacks on existing persistent dev tunnel launchd agents -- no new tunnel needed.

### 3. Remote: lemonade client

Add `pkgs.lemonade` to `home.base.nix` home.packages. On the remote, `lemonade copy` and `lemonade paste` connect to localhost:2489 which tunnels back to macOS.

### 4. Neovim: clipboard provider

Update `assets/nvim/lua/user/settings.lua`. Replace the `SSH_TTY` check with a custom clipboard provider that uses lemonade when available on a remote host.

### 5. tmux: copy-command

Update `assets/tmux/extra.conf`. Add `copy-command 'lemonade copy'` so tmux copy-mode selections go through lemonade. Keep `set-clipboard on` as fallback for plain SSH sessions where OSC 52 still works.

### 6. Remove tcopy/tpaste

Remove `assets/scripts/tcopy.bash` and `assets/scripts/tpaste.bash`. Remove the `writeShellApplication` definitions and `home.packages` entries from `home.base.nix`. These relied on OSC 52 via `tmux load-buffer -w` which is broken through mosh. Lemonade replaces both with better behavior (tpaste couldn't read the macOS clipboard; lemonade paste can).

## Data flow

```
Copy:  nvim yank → lemonade copy → TCP :2489 → SSH tunnel → macOS lemonade server → pbcopy
Paste: nvim paste → lemonade paste → TCP :2489 → SSH tunnel → macOS lemonade server → pbpaste → response
```

## What stays the same

- Plain SSH + OSC 52 still works (tmux `set-clipboard on` remains)
- iTerm2 "Allow clipboard access" stays enabled
- `vim.opt.clipboard = "unnamedplus"` unchanged
- On macOS local nvim, default clipboard provider (pbcopy/pbpaste) unchanged
