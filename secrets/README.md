# Secrets Management

This directory uses sops-nix with age encryption for secrets.

## Secret Files

| File | Host | Integration | Secrets |
|------|------|-------------|---------|
| `devbox.yaml` | NixOS devbox | sops-nix NixOS module (`/run/secrets/`) | github_ssh_key, cloudflare_api_token, gemini_api_key, ... |
| `cloudbox.yaml` | NixOS cloudbox (GCP) | sops-nix NixOS module (`/run/secrets/`) | work tokens, jenkins, buildbuddy, ... |

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
3. Re-encrypt: `sops --config secrets/.sops.yaml updatekeys secrets/<host>.yaml`
   (the `--config` is load-bearing when running from the repo root; without it
   sops looks for a config next to the file's own directory and gives up)
4. Deploy new private key to the host

## Removing a Secret

Use `sops unset`, never decrypt/edit/re-encrypt — see the
[Managing Secrets](../.opencode/skills/managing-secrets/SKILL.md) skill.

**Removing a secret is not revoking it.** The value stays valid at the
provider, and the ciphertext stays in this repo's git history, which is
public. Deleting a host's key from `.sops.yaml` likewise does not un-encrypt
the history that key can already read. If a credential was ever committed and
you want it dead, rotate it at the provider.
