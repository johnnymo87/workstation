---
name: apply-home
description: Quick apply home-manager changes (fast, no sudo)
---

# /apply-home

Fast apply of home-manager user configuration.

## When to Use

After editing:
- `users/dev/home.nix`
- `assets/claude/skills/*`
- `assets/nvim/*`

## Command

```bash
cd ~/Code/workstation
home-manager switch --flake .#dev
```

## Expected Output

```
Starting Home Manager activation
Activating checkFilesChanged
Activating checkLinkTargets
...
Activating onFilesChange
```

Takes ~10 seconds. No sudo needed.
