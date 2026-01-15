---
name: rebuild
description: Rebuild the devbox system and/or user configuration
---

# /rebuild

Apply configuration changes to the devbox.

## Usage

Specify what to rebuild:

- **system** - NixOS system config (requires sudo, may need reboot)
- **home** - Home-manager user config (fast, no sudo)
- **both** - Apply both in sequence

## Steps

### For "system" or "both":

```bash
cd ~/Code/workstation
sudo nixos-rebuild switch --flake .#devbox
```

### For "home" or "both":

```bash
cd ~/Code/workstation
home-manager switch --flake .#dev
```

## After Rebuild

1. Check for errors in output
2. If kernel changed, reboot may be needed
3. Verify services are running: `systemctl status sshd`
