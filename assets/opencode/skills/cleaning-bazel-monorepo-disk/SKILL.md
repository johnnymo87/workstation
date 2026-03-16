---
name: cleaning-bazel-monorepo-disk
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

### 4. Bazel worktree output bases (often 50-70 GB!)

Each git worktree gets its own Bazel output base (2-8 GB each). With many
worktrees, this is typically the single largest disk consumer.

**Map output bases to worktrees** using Bazel's MD5 hash of the workspace path:

```python
# Run on cloudbox or macOS -- maps every output base to its worktree
python3 -c "
import hashlib, os, subprocess

def bazel_hash(path):
    return hashlib.md5(path.encode()).hexdigest()

# Adjust paths for your platform
mono = os.path.expanduser('~/projects/mono')       # cloudbox
# mono = os.path.expanduser('~/Code/mono')          # macOS
base = os.path.expanduser('~/.cache/bazel/_bazel_' + os.environ['USER'])

candidates = [mono]
wt_dir = os.path.join(mono, '.worktrees')
if os.path.isdir(wt_dir):
    candidates += [os.path.join(wt_dir, w) for w in os.listdir(wt_dir)]

hash_to_ws = {bazel_hash(c): c for c in candidates}

for entry in sorted(os.listdir(base)):
    path = os.path.join(base, entry)
    if not os.path.isdir(path) or entry in ('install', 'cache'):
        continue
    ws = hash_to_ws.get(entry, 'ORPHAN')
    size = subprocess.run(['du', '-sh', path], capture_output=True, text=True).stdout.split()[0]
    short = ws.replace(os.path.expanduser('~/projects/mono'), 'mono')
    print(f'{size}\t{entry[:12]}\t{short}')
"
```

**Clean all output bases except the main checkout:**

```bash
# Identify the mono main output base hash (KEEP this one)
python3 -c "import hashlib; print(hashlib.md5(b'$HOME/projects/mono').hexdigest())"

# Delete everything else -- sudo needed because Bazel sandbox sets
# read-only permissions on extracted runtimes (e.g., rules_python)
sudo rm -rf ~/.cache/bazel/_bazel_${USER}/<hash1>
sudo rm -rf ~/.cache/bazel/_bazel_${USER}/<hash2>
# ... or delete all except the keep hash
```

**Important:** Cleaning an output base does NOT delete the worktree or its
code. It only removes build artifacts. The next `bazel build` will rebuild
from scratch (using the disk cache to speed things up).

### 5. Old Bazel workspaces by age

If you don't use worktrees, you can clean by age instead:

```bash
# macOS: delete workspaces older than 30 days
find /private/var/tmp/_bazel_${USER}/ -maxdepth 1 -type d -mtime +30 \
  -exec du -sh {} \;
# Then rm -rf the ones you don't need

# Linux: same but different path
find ~/.cache/bazel/_bazel_${USER}/ -maxdepth 1 -type d -mtime +30 \
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
