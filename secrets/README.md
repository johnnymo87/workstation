# Secrets Management

This directory is a skeleton for sops-nix encrypted secrets.

## Setup (when needed)

1. Install age: `nix-shell -p age`
2. Generate key: `age-keygen -o ~/.config/sops/age/keys.txt`
3. Add public key to `.sops.yaml`
4. Create secrets: `sops secrets/devbox.yaml`

## Usage in Nix

```nix
# In flake.nix inputs:
sops-nix.url = "github:Mic92/sops-nix";

# In configuration:
sops.secrets.my-secret = {
  sopsFile = ../secrets/devbox.yaml;
};
```

## Current Status

No secrets currently managed. This is a skeleton for future use.
