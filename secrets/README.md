# Secrets Management

This directory uses sops-nix with age encryption for secrets.

## Secret Files

| File | Host | Integration | Secrets |
|------|------|-------------|---------|
| `devbox.yaml` | NixOS devbox | sops-nix NixOS module (`/run/secrets/`) | github_ssh_key, cloudflare_api_token, gemini_api_key, ... |
| `chromebook.yaml` | Chromebook (Crostini) | sops-nix home-manager module | gemini_api_key |

## Devbox Setup (already done)

1. Age key generated and stored at `/persist/sops-age-key.txt` on devbox
2. Public key added to `.sops.yaml`
3. Secrets encrypted in `devbox.yaml`

## Chromebook (Crostini) Setup

1. **Generate age key on the Chromebook:**
   ```bash
   mkdir -p ~/.config/sops/age/
   nix-shell -p age --run "age-keygen -o ~/.config/sops/age/keys.txt"
   ```

2. **Get the public key:**
   ```bash
   nix-shell -p age --run "age-keygen -y ~/.config/sops/age/keys.txt"
   ```

3. **On a machine with the repo, update `.sops.yaml`:**
   Replace `PLACEHOLDER_GENERATE_AGE_KEY_ON_CHROMEBOOK` with the actual public key.

4. **Create the encrypted secrets file:**
   ```bash
   SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/chromebook.yaml
   ```
   Add: `gemini_api_key: <the-api-key>`

5. **Commit and push**, then on the Chromebook:
   ```bash
   cd ~/projects/workstation
   git pull
   home-manager switch --flake .#livia
   ```

## Adding New Secrets

### Devbox

1. Edit: `SOPS_AGE_KEY_FILE=/persist/sops-age-key.txt sops secrets/devbox.yaml`
2. Reference in `hosts/devbox/configuration.nix`
3. Rebuild: `sudo nixos-rebuild switch --flake .#devbox`

### Chromebook

1. Edit: `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/chromebook.yaml`
2. Reference in `users/dev/home.crostini.nix` (sops.secrets)
3. Apply: `home-manager switch --flake .#livia`

## Rotating the Age Key

1. Generate new key: `age-keygen`
2. Update `.sops.yaml` with new public key
3. Re-encrypt: `sops updatekeys secrets/<host>.yaml`
4. Deploy new private key to the host
