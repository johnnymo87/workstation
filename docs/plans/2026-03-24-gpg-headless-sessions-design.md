# GPG for Headless Sessions Design

## Goal

Make GPG commit signing available in headless OpenCode sessions on devbox without moving secret key material off macOS.

## Problem

Headless sessions on devbox inherit the `opencode-serve` systemd service environment. That service starts at boot and runs continuously. GPG agent forwarding currently depends on an interactive SSH session from macOS (`ssh devbox` or `ssh devbox-tunnel`), which forwards `/run/user/1000/gnupg/S.gpg-agent` via `RemoteForward`. When no interactive SSH session is open, the forwarded socket does not exist, and any `git commit` that requires GPG signing fails with `No secret key`.

## Design

### Persistent SSH tunnel on macOS

Add a `launchd` agent on macOS that maintains a background SSH connection to devbox using the existing `devbox-tunnel` host config. This connection forwards the GPG agent socket (`RemoteForward /run/user/1000/gnupg/S.gpg-agent`) continuously, independent of any interactive terminal session.

The tunnel:
- runs as a `launchd` user agent, started at login
- uses `ssh -N devbox-tunnel` (no shell, just forwarding)
- is restarted automatically by launchd if it dies
- reuses the existing SSH config from `scripts/update-ssh-config.sh`

### Devbox side: no changes to key/agent management

- Local GPG agent units remain masked (`home.devbox.nix`)
- `no-autostart` remains in `~/.gnupg/common.conf`
- `opencode-serve` remains a system-level systemd service
- No secret key material is stored on devbox

### Launcher warning in `opencode-launch`

Before launching a headless session, `opencode-launch` checks whether `/run/user/1000/gnupg/S.gpg-agent` exists and is a socket:
- If present: proceed silently
- If missing: print a warning that signed commits will fail in this session, then continue launching

This is a warn-but-proceed model, not a hard gate.

## Scope

### macOS (`home.darwin.nix`)
- New `launchd` agent for the persistent SSH tunnel

### Devbox (`home.base.nix`)
- Update `opencode-launch` with GPG socket preflight warning

### Troubleshooting docs
- Update `troubleshooting-devbox/SKILL.md` to mention the persistent tunnel

## Non-Goals

- Moving GPG keys to devbox
- Running a local GPG agent on devbox
- Changing the `opencode-serve` service definition
- Blocking session launch when GPG is unavailable

## Verification

- macOS: `launchctl list | grep devbox-tunnel` shows the agent loaded
- devbox with no interactive SSH: `test -S /run/user/1000/gnupg/S.gpg-agent` succeeds
- `opencode-launch` with socket present: no warning, session launches
- `opencode-launch` with socket absent: warning printed, session still launches
- headless session with tunnel up: `echo test | gpg --clearsign` succeeds
