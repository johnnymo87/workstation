# Secrets Management

This directory uses sops-nix with age encryption for secrets.

## Secret Files

| File | Host | Integration | Secrets |
|------|------|-------------|---------|
| `devbox.yaml` | NixOS devbox | sops-nix NixOS module (`/run/secrets/`) | github_ssh_key, cloudflare_api_token, gemini_api_key, ... |

## Devbox Setup (already done)

1. Age key generated and stored at `/persist/sops-age-key.txt` on devbox
2. Public key added to `.sops.yaml`
3. Secrets encrypted in `devbox.yaml`

## Adding New Secrets

### Devbox

1. Edit: `SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/devbox.yaml`
2. Reference in `hosts/devbox/configuration.nix`
3. Rebuild: `sudo nixos-rebuild switch --flake .#devbox`

## Rotating the Age Key

1. Generate new key: `age-keygen`
2. Update `.sops.yaml` with new public key
3. Re-encrypt: `sops updatekeys secrets/<host>.yaml`
4. Deploy new private key to the host
