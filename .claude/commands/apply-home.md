---
name: apply-home
description: Quick apply home-manager changes (fast, no sudo on devbox)
---

# /apply-home

Fast apply of home-manager user configuration.

## When to Use

After editing:
- `users/dev/home.nix`
- `users/dev/home.darwin.nix`
- `assets/claude/skills/*`
- `assets/nvim/*`

## Command

### NixOS Devbox (standalone home-manager)

```bash
cd ~/projects/workstation
home-manager switch --flake .#dev
```

Takes ~10 seconds. No sudo needed.

### macOS (integrated with darwin)

On macOS, home-manager is a darwin module, so use:

```bash
cd ~/Code/workstation
sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Note: Requires sudo because darwin-rebuild activates system changes too.

## Expected Output

```
Starting Home Manager activation
Activating checkFilesChanged
Activating checkLinkTargets
...
Activating onFilesChange
```
