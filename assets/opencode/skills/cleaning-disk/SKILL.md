---
name: cleaning-disk
description: Reclaim disk space on devbox (NixOS) and macOS. Covers Nix store/generations, Python caches (uv/pip), application caches (Playwright, datalab), and project-specific bloat. Use when disk space is low or for regular maintenance.
---

# Cleaning Disk

Systematic disk cleanup for devbox (NixOS) and macOS workstations.

## Quick Assessment

```bash
# Overall disk usage
df -h /

# Nix store (typically the largest consumer)
du -sh /nix/store

# Home directory breakdown
du -sh ~/* 2>/dev/null | sort -h
du -sh ~/.cache/* 2>/dev/null | sort -h
du -sh ~/.local/share/* 2>/dev/null | sort -h
```

## Emergency Cleanup (disk critically full)

Run these in order until you have enough space:

### 1. Nix garbage collection (typically 0.5-5 GB)

**macOS:**
```bash
nix-collect-garbage -d
```

**Devbox/Cloudbox (NixOS) -- clean both system and HM generations:**
```bash
# Keep only latest 3 generations
nix-env --delete-generations +3 \
  --profile ~/.local/state/nix/profiles/home-manager
sudo nix-env --delete-generations +3 \
  --profile /nix/var/nix/profiles/system
sudo nix-collect-garbage
```

### 2. Python package caches (often 5-10 GB combined)

```bash
# uv cache (often 3-7 GB) -- always safe
rm -rf ~/.cache/uv/*

# uv virtualenvs (often 3-6 GB) -- will rebuild on `direnv allow`
rm -rf ~/.local/share/uv/*

# pip cache -- always safe
rm -rf ~/.cache/pip/
```

### 3. Application-specific caches

```bash
# Playwright browsers (1-2 GB) -- re-downloads on demand
rm -rf ~/.cache/ms-playwright/

# datalab cache -- re-downloads on demand
rm -rf ~/.cache/datalab/*

# Elixir/Erlang mix cache
rm -rf ~/.cache/mix/*

# Node caches
rm -rf ~/.cache/node-gyp/
rm -rf ~/.cache/electron/
```

### 4. Project-specific caches

Check for TTS audio caches, build artifacts, or other project data:

```bash
# Look for large directories outside ~/projects
du -sh ~/* 2>/dev/null | sort -h

# Common project cache patterns
du -sh ~/.local/share/tts_joinery 2>/dev/null  # TTS audio cache
du -sh ~/.local/share/devenv 2>/dev/null       # devenv state
```

## macOS-Only Cleanup

### Bazel (if present)

```bash
# Bazel caches (always safe)
rm -rf ~/bazel-diskcache/*
rm -rf ~/bazel-cache/repository/*

# Old Bazel workspaces
du -sh /private/var/tmp/_bazel_${USER}/* 2>/dev/null | sort -h
```

### Language version managers (often 20-60 GB!)

```bash
# Check what's installed vs what's needed
du -sh ~/.rbenv/versions/* | sort -h
find ~/Code -name ".ruby-version" -exec cat {} \; 2>/dev/null | sort -u

du -sh ~/.nodenv/versions/* | sort -h
find ~/Code -name ".node-version" -exec cat {} \; 2>/dev/null | sort -u

# Remove old versions not needed by any project
```

### Package manager caches (always safe, ~5-10 GB)

```bash
npm cache clean --force 2>/dev/null
brew cleanup --prune=all 2>/dev/null
pip cache purge 2>/dev/null
rm -rf ~/.cache/uv/*
rm -rf ~/Library/Caches/Coursier/*
```

### Docker (if present)

```bash
docker image prune --all --force
docker container prune --force
docker volume prune --all --force
docker builder prune --all --force
```

### Bazelisk Gatekeeper warning (macOS only)

Avoid deleting `~/Library/Caches/bazelisk/` and `/private/var/tmp/_bazel_${USER}/install/` unless necessary. If you do, Bazel may hang due to macOS Gatekeeper blocking the re-downloaded binary.

**Fix:** Enable Terminal as a Developer Tool:
```bash
sudo spctl developer-mode enable-terminal
# Then: System Settings -> Privacy & Security -> Developer Tools -> Enable Terminal
```

## Devbox/Cloudbox-Specific Notes

### Generation bloat from auto-updates

The `pull-workstation` timer runs every 4 hours and creates a new home-manager generation each time. The `home-manager-auto-expire` timer cleans generations older than 7 days daily, but rapid rebuilds can still accumulate 30+ generations in a week.

**Check generation count:**
```bash
nix-env --list-generations \
  --profile ~/.local/state/nix/profiles/home-manager | wc -l
sudo nix-env --list-generations \
  --profile /nix/var/nix/profiles/system | wc -l
```

### Disk filling can break SSH

If the disk fills above ~90%, a scheduled `nix-gc` run can cause enough I/O pressure to prevent socket-activated sshd from responding. Symptoms: `Connection timed out during banner exchange`. Fix: hard reset via `gcloud compute instances reset` (cloudbox) or Hetzner console (devbox).

Prevention: keep disk below 80%.

## Safety Guidelines

**Always safe to delete:**
- `~/.cache/uv/*`, `~/.cache/pip/`, `~/.cache/mix/*`
- `~/.cache/ms-playwright/`, `~/.cache/datalab/*`
- `~/.cache/node-gyp/`, `~/.cache/electron/`
- Old Nix generations (keep latest 3)
- TTS audio caches (`~/.local/share/tts_joinery/`)
- `~/.local/share/uv/*` (virtualenvs rebuild on demand)

**Check first:**
- `~/.local/share/opencode/` -- session history, may want to keep
- Project directories outside `~/projects/`
- `~/.local/share/devenv/` -- may need `direnv allow` after deletion

**Never delete:**
- Project source code with uncommitted changes
- `/nix/store` directly (always use `nix-collect-garbage`)
- Sops keys or secrets

## Monthly Maintenance

```bash
# Check disk
df -h /

# Clean Python caches
rm -rf ~/.cache/uv/* ~/.cache/pip/

# Clean application caches
rm -rf ~/.cache/ms-playwright/ ~/.cache/datalab/*

# Clean old Nix generations (devbox/cloudbox)
nix-env --delete-generations +5 \
  --profile ~/.local/state/nix/profiles/home-manager
sudo nix-env --delete-generations +5 \
  --profile /nix/var/nix/profiles/system
sudo nix-collect-garbage

# Clean old Nix generations (macOS)
nix-collect-garbage -d
```
