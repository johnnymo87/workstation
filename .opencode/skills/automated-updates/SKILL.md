---
name: Automated Updates
description: How the devbox automatically updates llm-agents (claude-code) via GitHub Actions and systemd timers. Use when debugging update failures or understanding the update flow.
---

# Automated Updates

The devbox keeps dependencies up to date via two GitHub Actions workflows and a systemd timer.

## What Gets Updated

### Flake inputs (every 4 hours)

- **devenv**: Development environment tool from Cachix

Updated by `.github/workflows/update-devenv.yml` using `DeterminateSystems/update-flake-lock`.

### Local packages (daily)

- **beads**: Distributed issue tracker for AI workflows

Updated by `.github/workflows/update-packages.yml` using `nix-update`. Package definitions live in `pkgs/<name>/default.nix`.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│ GitHub Actions                                              │
│                                                             │
│  Flake inputs (every 4h):                                   │
│    update-devenv.yml → updates flake.lock → PR → auto-merge │
│                                                             │
│  Local packages (daily):                                    │
│    update-packages.yml → nix-update → PR → auto-merge       │
│                                                             │
│  CI (ci.yml) runs nix flake check on each PR                │
│  ↓                                                          │
│  Checks pass → PR auto-merges to main                       │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Devbox (systemd timer, every 4 hours)                       │
│                                                             │
│  1. pull-workstation.timer triggers                         │
│  2. Fetches origin/main                                     │
│  3. If updates: git pull --ff-only                          │
│  4. Runs: home-manager switch --flake .#dev                 │
└─────────────────────────────────────────────────────────────┘
```

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `ci.yml` | `.github/workflows/` | Runs `nix flake check` on PRs |
| `update-devenv.yml` | `.github/workflows/` | Updates devenv flake input, opens PR |
| `update-packages.yml` | `.github/workflows/` | Updates local packages via nix-update |
| `UPDATE_TOKEN` | GitHub Secrets | PAT for PR creation + CI triggers |
| `pull-workstation` | `~/.local/bin/` | Script to pull + apply home-manager |
| `pull-workstation.timer` | systemd user | Triggers every 4h + 10min after boot |
| `home-manager-auto-expire.timer` | systemd user | Cleans old generations daily |

## Adding a New Package

1. Create `pkgs/<name>/default.nix` with the derivation
2. Add to `localPkgsFor` in `flake.nix`
3. Reference as `localPkgs.<name>` in `home.base.nix`
4. Add `<name>` to the matrix in `.github/workflows/update-packages.yml`

## Checking Status

### GitHub Side

```bash
# Recent workflow runs
gh run list --workflow=update-devenv.yml --limit=5
gh run list --workflow=update-packages.yml --limit=5

# Open update PRs
gh pr list --label automated

# CI status on a PR
gh pr checks <pr-number>
```

### Devbox Side

```bash
# Timer status
systemctl --user status pull-workstation.timer
systemctl --user status home-manager-auto-expire.timer

# When timers will next run
systemctl --user list-timers

# Recent pull-workstation runs
journalctl --user -u pull-workstation -n 50

# Recent auto-expire runs
journalctl --user -u home-manager-auto-expire -n 50
```

## Manual Trigger

### Trigger GitHub Update

```bash
gh workflow run update-devenv.yml
gh workflow run update-packages.yml
# Or update a single package:
gh workflow run update-packages.yml -f package=beads
```

### Trigger Devbox Pull

```bash
~/.local/bin/pull-workstation
```

Or via systemd:

```bash
systemctl --user start pull-workstation
```

## Troubleshooting

### PR not being created

1. Check workflow ran: `gh run list --workflow=update-packages.yml --limit=1`
2. Check for errors: `gh run view <run-id> --log`
3. Verify `UPDATE_TOKEN` secret exists: `gh secret list`

### PR not auto-merging

1. Check CI passed: `gh pr checks <pr-number>`
2. Check auto-merge is enabled: `gh pr view <pr-number>`
3. Check branch protection: Settings → Branches → main

### Devbox not pulling updates

1. Check timer is active: `systemctl --user status pull-workstation.timer`
2. Check for dirty working tree: `git -C ~/projects/workstation status`
3. Check logs: `journalctl --user -u pull-workstation -n 50`
4. Manual test: `~/.local/bin/pull-workstation`

### "Working tree not clean" error

The pull script refuses to run if there are uncommitted changes:

```bash
cd ~/projects/workstation
git status
# Either commit, stash, or discard changes
```

### SSH errors in pull-workstation

The script uses `BatchMode=yes` which fails if:
- SSH key missing: Check `~/.ssh/id_ed25519_github` exists
- Host key missing: Run `ssh -T git@github.com` once manually

### Old generations piling up

Check auto-expire is running:

```bash
systemctl --user status home-manager-auto-expire.timer
journalctl --user -u home-manager-auto-expire -n 20
```

Manual cleanup:

```bash
home-manager expire-generations "-7 days"
nix-collect-garbage
```

## Configuration

### Update Frequency

**Flake inputs (devenv):** Edit `.github/workflows/update-devenv.yml`:
```yaml
schedule:
  - cron: '0 */4 * * *'  # Change */4 to desired interval
```

**Local packages:** Edit `.github/workflows/update-packages.yml`:
```yaml
schedule:
  - cron: '0 6 * * *'  # Daily at 06:00 UTC
```

**Devbox timer:** Edit `users/dev/home.devbox.nix`:
```nix
Timer = {
  OnStartupSec = "10min";
  OnUnitInactiveSec = "4h";  # Change to desired interval
};
```

### Generation Retention

Edit `users/dev/home.devbox.nix`:
```nix
services.home-manager.autoExpire = {
  frequency = "daily";
  timestamp = "-7 days";  # Keep generations from last 7 days
};
```
