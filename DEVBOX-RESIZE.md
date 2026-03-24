# Devbox Resize: CAX31 -> CAX41

## What This Does

Upgrades the Hetzner ARM server from CAX31 (8 vCPU, 16 GB RAM) to CAX41 (16 vCPU, 32 GB RAM).

- **Cost delta**: ~€13/month more (~€28.90 vs ~€15.90)
- **Downtime**: 1-5 minutes (server must be off for type change)
- **Data loss**: None. The boot disk is preserved, and the `/persist` Cloud Volume is a separate device entirely.

## Prerequisites

Run `hcloud server change-type --help` to confirm the exact flag
names before executing. The flag to skip disk upgrade may be
`--keep-disk` or `--upgrade-disk=false` depending on CLI version.

```bash
# 1. Ensure hcloud CLI is installed and context is configured
brew install hcloud          # if not already installed
hcloud context list          # should show "workstation" context
hcloud server list           # should show "devbox" with status "running"
```

If the context is missing, set it up:

```bash
hcloud context create workstation
# Paste API token from: Hetzner Console -> Project -> Access -> API Tokens
```

## Resize Procedure

```bash
# 2. Confirm current state
hcloud server describe devbox

# 3. Shut down the server (graceful ACPI shutdown)
hcloud server shutdown devbox

# 4. Wait for it to stop (poll until status is "off")
hcloud server list

# 5. Change type — use --keep-disk so you can downgrade later if needed
#    (the 152 GB boot disk is plenty; the constraint is RAM, not disk)
hcloud server change-type devbox cax41 --keep-disk

# 6. Start the server
hcloud server start devbox

# 7. Wait ~30 seconds, then verify SSH
ssh devbox
```

## Post-Resize Verification (run on devbox after SSH)

```bash
# Confirm new hardware
nproc                        # expect: 16
free -h                      # expect: ~31 Gi total
lsblk                        # boot disk still 152 GB (unchanged)
df -h /persist               # Cloud Volume still 10 GB (unchanged)

# Confirm services came back
systemctl is-active earlyoom opencode-serve pigeon-daemon cloudflared-tunnel
systemctl --user is-active anthropic-oauth-proxy

# Confirm zram resized automatically (75% of 32 GB = ~24 GB)
zramctl

# Check OOM mitigations still applied
systemctl show opencode-serve --property=MemoryMax,MemoryHigh
cat /sys/fs/cgroup/user.slice/user-1000.slice/memory.high
```

## Why --keep-disk

Without `--keep-disk`, Hetzner grows the boot disk from 152 GB to
320 GB. This is a one-way operation — you can never downgrade back
to CAX31 (or any type with a smaller disk) afterward. Since disk
space is not the bottleneck (70 GB free on root, projects live on
the separate Cloud Volume), keeping the disk unchanged preserves
the option to downgrade if 32 GB RAM turns out to be more than
needed.

## Data Safety

| Path                  | Device           | Survives? | Why                              |
|-----------------------|------------------|-----------|----------------------------------|
| ~/projects            | Cloud Volume sdb | Yes       | Separate device, bind-mounted    |
| ~/.ssh                | Cloud Volume sdb | Yes       | Symlink to /persist/ssh          |
| ~/.claude             | Cloud Volume sdb | Yes       | Symlink to /persist/claude       |
| /persist/sops-age-key | Cloud Volume sdb | Yes       | Separate device                  |
| / (NixOS, nix store)  | Boot disk sda    | Yes       | Preserved by change-type         |
| /boot                 | Boot disk sda    | Yes       | Preserved by change-type         |

This is NOT a reprovision. The VM is stopped, its resource
allocation is changed, and it is started again. No disks are
reformatted or replaced.

## Rollback

If something goes wrong or you want to downgrade later:

```bash
hcloud server shutdown devbox
hcloud server change-type devbox cax31 --keep-disk
hcloud server start devbox
```

This only works if you used `--keep-disk` during the upgrade.

## After Everything Works

Delete this file — it's a one-time runbook:

```bash
rm ~/projects/workstation/DEVBOX-RESIZE.md
```
