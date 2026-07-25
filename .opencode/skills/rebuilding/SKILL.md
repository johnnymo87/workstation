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

> **WARNING (cloudbox):** `nixos-rebuild switch` updates `opencode-frontdoor` on disk but does **NOT** restart the running process (`restartIfChanged = false`). Run `sudo systemctl restart opencode-frontdoor` afterward or the door keeps serving OLD code. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

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

This is fast (~10 seconds).

> **WARNING (cloudbox):** `home-manager switch` repoints `/home/dev/.nix-profile/bin/opencode` but does **NOT** restart active serve units (`restartIfChanged = false`). Run `sudo systemctl restart opencode-serve-pool.target` afterward or serves keep running OLD code in version drift. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

## Deploy Runbook: Front Door & Serve Pool

When deploying updates that affect `opencode-frontdoor` or the `opencode-serve@` pool (e.g. on `cloudbox`), explicit service restarts are **REQUIRED**.

### Canonical Deploy Sequence

```bash
sudo nixos-rebuild switch --flake ".#$(hostname)"   # installs new door binary, rewrites unit
sudo systemctl restart opencode-frontdoor           # REQUIRED: door does NOT self-restart
home-manager switch --flake .#cloudbox              # installs new opencode into /home/dev/.nix-profile
sudo systemctl restart opencode-serve-pool.target   # REQUIRED: serves do NOT self-restart
```

### Why Explicit Restarts Are Required (`restartIfChanged = false`)

Both `opencode-frontdoor` and `opencode-serve@` are configured with `restartIfChanged = false` in `hosts/cloudbox/configuration.nix`.

This design is **deliberate**:
- Restarting `opencode-frontdoor` drops active SSE connections and resets sticky session routing maps.
- Restarting `opencode-serve-pool.target` terminates running worker sessions.

Because neither service self-restarts on rebuild, `nixos-rebuild switch` and `home-manager switch` update binary files and unit definitions on disk while **leaving old processes running in version drift**.

**Past Production Incidents (2026-07-24):**
- **Stale serves (`reset-workspace` skipped pool restart):** Front door routed new session-scoped paths, but stale serves returned HTML SPA fallbacks. The attach TUI threw when trying to JSON-parse HTML and reconnected infinitely, resulting in a frozen TUI.
- **Stale door (`nixos-rebuild` ran without restart):** Front door binary was updated on disk but process wasn't restarted. The MCP dialog returned 404 through the door for ~70 minutes until `opencode-frontdoor` was restarted.

### Checking for Version Drift

**Front Door Drift:**
The canary checks `/healthz` against unit `ExecStart` every 60s (`WARNING: version drift: running=... execstart=...`) and raises a throttled Telegram alert via pigeon. Check manually with:
```bash
journalctl -u opencode-frontdoor-canary --since today | grep -i drift
```

**Serve Pool Drift:**
Compare the store path of the running serve process against the active nix profile:
```bash
readlink /proc/$(systemctl show opencode-serve@4096 -p MainPID --value)/exe   # running process
readlink -f /home/dev/.nix-profile/bin/opencode                               # profile target
```
Mismatched `/nix/store/<hash>-...` prefixes indicate stale serve processes requiring a pool restart (`sudo systemctl restart opencode-serve-pool.target`).

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
# WARNING (cloudbox): If front door code changed, also run:
# sudo systemctl restart opencode-frontdoor

# If users/dev/* or assets/* changed → home-manager
# (use correct HM target for this host)
# WARNING (cloudbox): If opencode package changed, also run:
# sudo systemctl restart opencode-serve-pool.target
```

> **WARNING (cloudbox):** Neither `nixos-rebuild switch` nor `home-manager switch` automatically restarts the front door or serve pool (`restartIfChanged = false`). Always run `sudo systemctl restart opencode-frontdoor` and/or `sudo systemctl restart opencode-serve-pool.target` after applying changes. See [Deploy Runbook: Front Door & Serve Pool](#deploy-runbook-front-door--serve-pool).

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
