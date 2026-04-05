# gclpr Clipboard Bridge Design

**Goal:** Replace lemonade with gclpr for the TCP clipboard bridge. Lemonade corrupts multi-byte UTF-8 characters (known unfixed bug since 2017). gclpr handles UTF-8 correctly, is actively maintained (v2.2.1, March 2026), and adds signed request authentication.

**Architecture:** gclpr server on macOS exposes pbcopy/pbpaste over signed TCP on port 2850 (gclpr default). Existing persistent SSH dev tunnels carry a RemoteForward for this port. Remote gclpr client connects to localhost:2850, signs each request with a NaCl key pair, and the server verifies against trusted public keys.

## Why not lemonade

Lemonade's protocol corrupts multi-byte UTF-8 at the system clipboard boundary. `c3 a9` (UTF-8 for 'é') becomes `8e`. Filed as [lemonade#26](https://github.com/lemonade-command/lemonade/issues/26) in September 2017, never fixed, project abandoned ("maintainers wanted"). We verified gclpr preserves UTF-8 bytes correctly through copy/paste round-trips including accented characters, CJK, and emoji.

## Components

### 1. Nix package: gclpr

New derivation in `pkgs/gclpr/default.nix`. Multi-platform prebuilt binary fetched from GitHub releases (same pattern as opencode-patched). Platforms: aarch64-linux, aarch64-darwin, x86_64-linux, x86_64-darwin.

### 2. Key management (sops)

gclpr requires NaCl key-pair authentication. One shared key pair for all remote hosts.

- **Private key** (64 bytes binary): encrypted in `secrets/secrets.yaml`, deployed to remote hosts via sops-nix at `/run/secrets/gclpr_private_key`. An activation script copies it to `~/.gclpr/key` with correct permissions (600).
- **Public key** (32 bytes binary): not secret, committed to `assets/gclpr/key.pub`. Deployed to `~/.gclpr/key.pub` via `home.file`.
- **Trusted keys** (macOS only): `~/.gclpr/trusted` contains the hex-encoded public key. Managed by `home.file` on Darwin.

### 3. macOS: gclpr server (launchd agent)

Replaces `lemonade-server` in `home.darwin.nix`. Runs `gclpr server` on port 2850 (default), auto-restarts on failure. Sets `LANG=en_US.UTF-8` and `LC_CTYPE=en_US.UTF-8` in the launchd environment for correct pbcopy/pbpaste encoding.

### 4. SSH tunnels: RemoteForward 2850

Change `RemoteForward 2489 127.0.0.1:2489` to `RemoteForward 2850 127.0.0.1:2850` in both `devbox-tunnel` and `cloudbox-tunnel` host blocks in `update-ssh-config.sh`.

### 5. tmux: copy-command

Change `set -s copy-command 'lemonade copy'` to `set -s copy-command 'gclpr copy'` in `assets/tmux/extra.conf`.

### 6. Neovim: clipboard provider

Replace lemonade commands with gclpr in `assets/nvim/lua/user/settings.lua`. Detection logic unchanged (check `is_remote` + executable).

### 7. Remove lemonade

Remove `pkgs.lemonade` from `home.base.nix`. Remove `lemonade-server` launchd agent from `home.darwin.nix`.

## Data flow

```
Copy:  nvim yank → gclpr copy → TCP :2850 (signed) → SSH tunnel → macOS gclpr server → pbcopy
Paste: nvim paste → gclpr paste → TCP :2850 (signed) → SSH tunnel → macOS gclpr server → pbpaste → response
```

## Key distribution

```
secrets/secrets.yaml
  └── gclpr_private_key (base64-encoded, 64 bytes)

assets/gclpr/key.pub (committed, 32 bytes, not secret)

macOS ~/.gclpr/trusted  ← hex public key string (home.file on Darwin)
devbox ~/.gclpr/key     ← decoded from /run/secrets/gclpr_private_key (activation)
       ~/.gclpr/key.pub ← from assets/gclpr/key.pub (home.file)
cloudbox: same as devbox
```

## What stays the same

- Plain SSH + OSC 52 still works (tmux `set-clipboard on` remains)
- iTerm2 "Allow clipboard access" stays enabled
- `vim.opt.clipboard = "unnamedplus"` unchanged
- On macOS local nvim, default clipboard provider (pbcopy/pbpaste) unchanged
- Persistent SSH dev tunnel launchd agents unchanged (just different port number)
- GPG tunnel agents unchanged

## What changes from lemonade

| Aspect | lemonade | gclpr |
|--------|----------|-------|
| Port | 2489 | 2850 |
| Auth | IP allowlist (`--allow 127.0.0.1,::1`) | NaCl key-pair signing |
| UTF-8 | Corrupted (bug #26) | Correct (verified) |
| Protocol | MessagePack (likely) | 4-byte frame length prefix |
| Maintained | No (2021, "maintainers wanted") | Yes (v2.2.1, March 2026) |
| Extras | None | Browser open, OAuth tunneling |
