---
name: Cleaning Bazel Monorepo Disk
description: Reclaim disk space in Bazel monorepo development environments. Covers Bazel caches, Docker, Nix store/generations, and package manager caches. Use when disk space is low or for regular maintenance. Works on both macOS and cloudbox (NixOS).
---

# Cleaning Bazel Monorepo Disk

Systematic disk cleanup for Bazel monorepo development environments on macOS and cloudbox (NixOS).

## Platform Differences

| Resource | macOS | Cloudbox (NixOS) |
|----------|-------|------------------|
| Bazel tmp | `/private/var/tmp/_bazel_${USER}/` | `/tmp/_bazel_${USER}/` or `~/.cache/bazel/` |
| Bazel disk cache | `~/bazel-diskcache` | `~/bazel-diskcache` |
| Bazel repo cache | `~/bazel-cache/repository/` | `~/bazel-cache/repository/` |
| Nix generations | `nix-collect-garbage -d` | System + HM generations (see below) |
| Docker | Docker Desktop | Native Docker daemon |
| Monorepo | `~/Code/<repo>` | `~/projects/<repo>` |
| Worktrees | `~/Code/<repo>-trees/` or `<repo>/.worktrees/` | `~/projects/<repo>/.worktrees/` |

## Quick Assessment

```bash
# Disk usage
df -h /

# Nix store
du -sh /nix/store

# Bazel caches
du -sh ~/bazel-diskcache ~/bazel-cache/repository 2>/dev/null

# Bazel workspaces (macOS)
du -sh /private/var/tmp/_bazel_${USER}/* 2>/dev/null | sort -h

# Bazel workspaces (Linux/cloudbox)
du -sh /tmp/_bazel_${USER}/* ~/.cache/bazel/* 2>/dev/null | sort -h

# Docker
docker system df
```

## Emergency Cleanup (disk critically full)

Run these in order until you have enough space:

### 1. Bazel caches (always safe, ~10 GB)

```bash
rm -rf ~/bazel-diskcache/*
rm -rf ~/bazel-cache/repository/*
```

### 2. Docker (safe, ~5-15 GB)

```bash
docker image prune --all --force
docker container prune --force
docker volume prune --all --force
docker builder prune --all --force
```

### 3. Nix garbage collection

**macOS:**
```bash
nix-collect-garbage -d
```

**Cloudbox (NixOS) -- clean both system and HM generations:**
```bash
# Keep only latest 3 generations
nix-env --delete-generations +3 \
  --profile ~/.local/state/nix/profiles/home-manager
sudo nix-env --delete-generations +3 \
  --profile /nix/var/nix/profiles/system
sudo nix-collect-garbage
```

### 4. Old Bazel workspaces (~5-7 GB each)

```bash
# Identify your current workspace (don't delete this one!)
cd ~/Code/<repo>  # or ~/projects/<repo> on cloudbox
bazel info output_base

# Shutdown bazel before deleting
bazel shutdown

# macOS: delete workspaces older than 30 days
find /private/var/tmp/_bazel_${USER}/ -maxdepth 1 -type d -mtime +30 \
  -exec du -sh {} \;
# Then rm -rf the ones you don't need

# Linux: same but different path
find /tmp/_bazel_${USER}/ -maxdepth 1 -type d -mtime +30 \
  -exec du -sh {} \; 2>/dev/null
```

## macOS-Only Cleanup

These only apply to macOS workstations.

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

### Bazelisk Gatekeeper warning (macOS only)

Avoid deleting `~/Library/Caches/bazelisk/` and `/private/var/tmp/_bazel_${USER}/install/` unless necessary. If you do, Bazel may hang due to macOS Gatekeeper blocking the re-downloaded binary.

**Fix:** Enable Terminal as a Developer Tool:
```bash
sudo spctl developer-mode enable-terminal
# Then: System Settings -> Privacy & Security -> Developer Tools -> Enable Terminal
```

## Cloudbox-Specific Notes

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

If the disk fills above ~90%, a scheduled `nix-gc` run can cause enough I/O pressure to prevent socket-activated sshd from responding. Symptoms: `Connection timed out during banner exchange`. Fix: hard reset via `gcloud compute instances reset`.

Prevention: keep disk below 80%.

## Safety Guidelines

**Always safe to delete:**
- `~/bazel-diskcache/*`
- `~/bazel-cache/repository/*`
- Old Bazel workspaces (>30 days, not your current one)
- Docker: stopped containers, unused images/volumes
- Package manager caches
- Old Nix generations (keep latest 3)

**Check first:**
- Active Bazel workspace (`bazel info output_base`)
- Git worktrees with uncommitted work
- Docker images for running containers

**Never delete:**
- The monorepo source code itself
- Active worktrees with uncommitted changes
- Running Docker containers

## Monthly Maintenance

```bash
# Check disk
df -h /

# Clean Bazel caches
rm -rf ~/bazel-diskcache/*
rm -rf ~/bazel-cache/repository/*

# Clean Docker
docker image prune --all --force --filter "until=720h"
docker container prune --force

# Clean old Nix generations (cloudbox)
nix-env --delete-generations +5 \
  --profile ~/.local/state/nix/profiles/home-manager
sudo nix-env --delete-generations +5 \
  --profile /nix/var/nix/profiles/system
sudo nix-collect-garbage

# Clean old Nix generations (macOS)
nix-collect-garbage -d
```
