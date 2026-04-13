---
name: rebuilding
description: How to apply configuration changes to NixOS hosts (devbox, cloudbox). Use when you need to rebuild the system, apply home-manager changes, or recover from issues.
---

# Rebuilding NixOS Hosts

## CRITICAL: Identify the Host First

**Before running ANY rebuild command, you MUST determine which machine you are on:**

```bash
cat /etc/hostname
```

This returns `devbox`, `cloudbox`, or another hostname. **Use the matching flake target.** Applying the wrong target overwrites system identity, secrets paths, and service configs — and can brick the machine.

There are NixOS activation guards that will abort if you use the wrong target, but **do not rely on them as a substitute for checking first.**

## Flake Targets

| Hostname | System rebuild | Home-manager |
|----------|---------------|--------------|
| `devbox` | `sudo nixos-rebuild switch --flake .#devbox` | `home-manager switch --flake .#dev` |
| `cloudbox` | `sudo nixos-rebuild switch --flake .#cloudbox` | `home-manager switch --flake .#cloudbox` |

**macOS** uses `sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2` (system + home combined).

## Applying Changes

### System Changes (requires sudo)

After editing files in `hosts/<hostname>/`:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
sudo nixos-rebuild switch --flake ".#$hostname"
```

This rebuilds the NixOS system. May require reboot if kernel changed.

### User Changes (no sudo, fast)

After editing files in `users/dev/` or `assets/`:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
# devbox uses #dev, cloudbox uses #cloudbox
if [ "$hostname" = "devbox" ]; then
  home-manager switch --flake .#dev
else
  home-manager switch --flake ".#$hostname"
fi
```

This is fast (~10 seconds) and doesn't affect system services.

## Pulling and Applying Updates

When fetching remote changes and applying them:

```bash
cd ~/projects/workstation
hostname=$(cat /etc/hostname)
git pull --rebase

# Check what changed to decide what to rebuild
git log --oneline HEAD@{1}..HEAD --name-only

# If hosts/$hostname/* changed → system rebuild
sudo nixos-rebuild switch --flake ".#$hostname"

# If users/dev/* or assets/* changed → home-manager
# (use correct HM target for this host)
```

## Updating Flake Inputs

To update all flake inputs (nixpkgs, home-manager, etc.):

```bash
nix flake update
git add flake.lock
git commit -m "Update flake.lock"
```

Then apply as above.

## Nuclear Option: Full Rebuild with nixos-anywhere

If a host is corrupted or you want a fresh start, see the host-specific setup skill:
- **Devbox (Hetzner):** Manual nixos-anywhere from macOS
- **Cloudbox (GCP):** See `setting-up-cloudbox` skill

## Troubleshooting

### "flake.nix not found"

Make sure you're in the workstation repo directory (`~/projects/workstation`).

### Home-manager errors about missing files

The `assets/` directory must exist. Check that `assets/` is populated.

### System won't boot after rebuild

- **Devbox:** Boot into previous generation from bootloader menu, then fix config.
- **Cloudbox:** Hard reset via `gcloud compute instances reset cloudbox --zone=us-east1-b --project=<project>`. See `setting-up-cloudbox` skill gotcha #10.

### Wrong flake target applied

If you accidentally applied the wrong host's config (e.g., `#devbox` on cloudbox):
1. The activation guard should catch this and abort. If it didn't (e.g., `/etc/hostname` was already overwritten):
2. Re-apply the correct config immediately: `sudo nixos-rebuild switch --flake .#<correct-hostname>`
3. If SSH is broken, use out-of-band access (serial console for GCP, rescue mode for Hetzner).
