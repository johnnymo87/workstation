---
name: rebuild
description: Rebuild the devbox system and/or user configuration
---

# /rebuild

Apply configuration changes to the current machine (devbox or macOS).

## Usage

Specify what to rebuild:

- **system** - System config (requires sudo)
- **home** - Home-manager user config (fast, no sudo on devbox)
- **both** - Apply both in sequence

## Steps

### NixOS Devbox

**System:**
```bash
cd ~/projects/workstation
sudo nixos-rebuild switch --flake .#devbox
```

**Home (standalone home-manager):**
```bash
cd ~/projects/workstation
home-manager switch --flake .#dev
```

### macOS

**System + Home (integrated):**

On macOS, home-manager runs as a darwin module, so `darwin-rebuild` applies both system and home changes:

```bash
cd ~/Code/workstation
sudo /run/current-system/sw/bin/darwin-rebuild switch --flake .#Y0FMQX93RR-2
```

Note: The full path `/run/current-system/sw/bin/darwin-rebuild` is required because the PATH may not include it in all contexts.

## After Rebuild

1. Check for errors in output
2. On NixOS: If kernel changed, reboot may be needed
3. Verify services are running:
   - NixOS: `systemctl status sshd cloudflared-tunnel pigeon-daemon`
   - macOS: `launchctl list | grep cloudflared`
