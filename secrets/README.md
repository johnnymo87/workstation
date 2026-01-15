# Secrets Management

This directory uses sops-nix with age encryption for secrets.

## Current Secrets

- `github_ssh_key` - Devbox SSH key for GitHub access (auto-cloning projects)

## Setup (already done)

1. Age key generated and stored at `/persist/sops-age-key.txt` on devbox
2. Public key added to `.sops.yaml`
3. Secrets encrypted in `devbox.yaml`

## Adding New Secrets

1. Edit the encrypted file:
   ```bash
   SOPS_AGE_KEY_FILE=/path/to/key sops secrets/devbox.yaml
   ```

2. Reference in `hosts/devbox/configuration.nix`:
   ```nix
   sops.secrets.new_secret = {
     owner = "dev";
     path = "/desired/path";
   };
   ```

3. Rebuild: `sudo nixos-rebuild switch --flake .#devbox`

## Rotating the Age Key

1. Generate new key: `age-keygen`
2. Update `.sops.yaml` with new public key
3. Re-encrypt: `sops updatekeys secrets/devbox.yaml`
4. Deploy new private key to `/persist/sops-age-key.txt`

## Deploying Age Key to Fresh Devbox

After nixos-anywhere, before first rebuild:
```bash
scp /path/to/age-key devbox:/persist/sops-age-key.txt
```
