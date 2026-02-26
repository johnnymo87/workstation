---
name: Setting Up Cloudbox (GCP ARM)
description: Guide for provisioning the cloudbox GCP VM from scratch with nixos-anywhere. Use when rebuilding the cloudbox or setting up a new GCP ARM instance.
---

# Setting Up Cloudbox (GCP ARM)

Cloudbox is a GCP C4a Axion (aarch64-linux) VM running NixOS, provisioned via nixos-anywhere. This documents the full setup process and the gotchas discovered along the way.

## Prerequisites

- `gcloud` CLI authenticated as a user with `roles/owner` on the `wonder-sandbox` project
- SSH key registered with GCP (or use `gcloud compute ssh` which handles this)
- The workstation repo checked out locally

## Step 1: Create the GCP VM

```bash
gcloud compute instances create cloudbox \
  --project=wonder-sandbox \
  --zone=us-east1-b \
  --machine-type=c4a-standard-4 \
  --image-family=ubuntu-2404-lts-arm64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=100GB \
  --boot-disk-type=hyperdisk-balanced \
  --no-address \
  --metadata=enable-oslogin=FALSE
```

### Critical C4a constraints

| Constraint | Details |
|-----------|---------|
| **Disk type** | Must use `hyperdisk-balanced`, not `pd-balanced` |
| **Disk device** | `/dev/nvme0n1` (NVMe), not `/dev/sda` (virtio-scsi) |
| **NIC** | gVNIC (not virtio-net), kernel module `gvnic` required |
| **Boot** | UEFI required, must override google-compute-config's default legacy GRUB |
| **Network** | `--no-address` blocks egress; need temporary external IP for nixos-anywhere |

## Step 2: Add temporary external IP

nixos-anywhere needs outbound internet to download the kexec tarball. Add a temporary access config:

```bash
gcloud compute instances add-access-config cloudbox \
  --zone=us-east1-b \
  --access-config-name="bootstrap-nat" \
  --project=wonder-sandbox
```

Get the assigned IP:

```bash
gcloud compute instances describe cloudbox \
  --zone=us-east1-b \
  --project=wonder-sandbox \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

## Step 3: Run nixos-anywhere

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#cloudbox \
  root@<EXTERNAL_IP>
```

This will:
1. kexec into a NixOS installer
2. Partition the disk via disko (`/dev/nvme0n1`)
3. Install the NixOS system configuration
4. Reboot

After reboot, SSH host keys change. Clear the old one:

```bash
ssh-keygen -R <EXTERNAL_IP>
ssh -o StrictHostKeyChecking=accept-new dev@<EXTERNAL_IP>
```

## Step 4: Generate the age key on cloudbox

sops-nix needs an age key for secret decryption. Generate it on the cloudbox:

```bash
ssh root@<EXTERNAL_IP>
nix-shell -p age --run "age-keygen -o /var/lib/sops-age-key.txt"
chmod 600 /var/lib/sops-age-key.txt
cat /var/lib/sops-age-key.txt | grep 'public key'
```

Save the public key (starts with `age1...`).

## Step 5: Encrypt secrets

Update `secrets/.sops.yaml` with the cloudbox age public key, then create/update `secrets/cloudbox.yaml`.

The easiest approach is to copy real secret values from devbox. Decrypt devbox secrets locally (requires devbox age private key):

```bash
SOPS_AGE_KEY="<devbox-age-private-key>" sops -d secrets/devbox.yaml
```

Then create `secrets/cloudbox.yaml` with the same values for:
- `github_ssh_key` — same key across machines
- `op_service_account_token` — same 1Password SA token
- `cloudflared_tunnel_token` — same tunnel (pigeon uses it)
- `cloudflare_api_token` — same API token

To set values in the encrypted file from the cloudbox (where the age key lives):

```bash
# On cloudbox:
sudo cat /var/lib/sops-age-key.txt > /tmp/sops-age-key.txt
SOPS_AGE_KEY_FILE=/tmp/sops-age-key.txt \
  nix-shell -p sops --run 'sops --set "[\"key_name\"] \"value\"" ~/projects/workstation/secrets/cloudbox.yaml'
rm /tmp/sops-age-key.txt
```

Copy the updated encrypted file back to your local repo:

```bash
scp cloudbox:~/projects/workstation/secrets/cloudbox.yaml secrets/cloudbox.yaml
```

## Step 6: Apply NixOS configuration

```bash
ssh cloudbox 'cd ~/projects/workstation && sudo nixos-rebuild switch --flake .#cloudbox'
```

This deploys sops secrets to `/run/secrets/`, sets up the SSH key symlink, creates the cloudflared and pigeon services, etc.

## Step 7: Apply home-manager

```bash
ssh cloudbox 'cd ~/projects/workstation && nix run home-manager -- switch --flake .#cloudbox'
```

This installs all user packages (tmux, neovim, opencode, beads, etc.), deploys dotfiles, and starts the `ensure-projects` service which clones all declared projects.

## Step 8: Authenticate gcloud ADC for Vertex AI

The VM's GCE service account only has default scopes (storage, logging, monitoring) — not `cloud-platform`. OpenCode's Vertex providers need user ADC credentials with full scopes:

```bash
ssh cloudbox 'gcloud auth application-default login --no-launch-browser'
```

Open the URL in your browser, complete the OAuth flow, and paste the code back. This creates `~/.config/gcloud/application_default_credentials.json` which the `google-auth-library` ADC chain prefers over the GCE metadata service account.

Without this step, Vertex AI calls fail with `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`.

## Step 9: Install pigeon dependencies

Pigeon is a Node.js project that needs `npm install`. The systemd service expects `node_modules/` to exist:

```bash
ssh cloudbox 'cd ~/projects/pigeon && npm install'
```

Then restart pigeon:

```bash
ssh cloudbox 'sudo systemctl restart pigeon-daemon.service'
```

## Step 10: Set up macOS SSH config

Add entries to `~/.ssh/config` on your Mac:

```
Host cloudbox
    HostName <EXTERNAL_IP>
    User dev
    ForwardAgent yes
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/<you>/.gnupg/S.gpg-agent.extra
    RemoteForward 9222 localhost:9222
    RemoteForward 3033 localhost:3033

Host cloudbox-tunnel
    HostName <EXTERNAL_IP>
    User dev
    ForwardAgent yes
    RemoteForward /run/user/1000/gnupg/S.gpg-agent /Users/<you>/.gnupg/S.gpg-agent.extra
    LocalForward 1455 localhost:1455
    RemoteForward 9222 localhost:9222
    RemoteForward 3033 localhost:3033
```

- `ssh cloudbox` for normal use
- `ssh cloudbox-tunnel` when running `opencode auth login` (needs port 1455 forwarded)

## Step 11: Verify everything works

```bash
ssh cloudbox

# Tools
tmux -V && nvim --version | head -1 && git --version && bd --version && which opencode

# GitHub auth
ssh -T git@github.com

# Projects cloned
ls ~/projects/

# Services
systemctl status cloudflared-tunnel.service pigeon-daemon.service
systemctl --user --failed
```

## Post-setup hardening

After bootstrap is confirmed working, ensure `PermitRootLogin` is set to `"no"` in `hosts/cloudbox/configuration.nix` and re-apply.

## Gotchas discovered during setup

1. **google-compute-config.nix enables OS Login by default** (`security.googleOsLogin.enable = true`), which injects a PAM module that breaks SSH connections after key auth. Must disable with `lib.mkForce false`.

2. **google-compute-config.nix sets legacy GRUB boot** which doesn't work on C4a UEFI. Must override with `boot.loader.grub.enable = lib.mkForce false` and `boot.loader.systemd-boot.enable = true`.

3. **`nixpkgs.config.allowUnfree = true`** is required for `pkgs._1password-cli` (used by pigeon).

4. **`users.mutableUsers = false`** is needed for declarative user management (also prevents google-guest-agent from creating accounts).

5. **Bare coreutils not on PATH in systemd services** — scripts run by systemd must use full nix store paths (e.g., `${pkgs.coreutils}/bin/mkdir`), not bare commands like `mkdir`.

6. **npm hoists dependencies to root `node_modules/`** — pigeon's `tsx` is at `/home/dev/projects/pigeon/node_modules/tsx/`, not `packages/daemon/node_modules/tsx/`.

7. **`nix.package = pkgs.nix`** must be set in home-manager base config when `nix.settings` is configured, or home-manager fails with a missing `nix.package` error.

8. **sops age key at `/var/lib/sops-age-key.txt`** is owned by root — user-level sops commands need `sudo cat` to a temp file or a user-readable copy.

9. **GCE default scopes lack `cloud-platform`** — the VM's service account credentials (from metadata server) don't include Vertex AI access. Must run `gcloud auth application-default login` to create user ADC credentials that override the metadata chain. Without this, Vertex calls fail with `403 ACCESS_TOKEN_SCOPE_INSUFFICIENT`.

## Removing the temporary external IP

If you switch to IAP tunneling and no longer need the public IP:

```bash
gcloud compute instances delete-access-config cloudbox \
  --zone=us-east1-b \
  --access-config-name="bootstrap-nat" \
  --project=wonder-sandbox
```

Then update SSH config to use a `ProxyCommand` with `gcloud compute ssh --tunnel-through-iap`.

## Relevant files

| File | Purpose |
|------|---------|
| `flake.nix` | `nixosConfigurations.cloudbox`, `homeConfigurations.cloudbox` |
| `hosts/cloudbox/configuration.nix` | System config (sops, cloudflared, pigeon, SSH, users) |
| `hosts/cloudbox/hardware.nix` | GCP C4a hardware (NVMe, gVNIC, UEFI, google-compute-config) |
| `hosts/cloudbox/disko.nix` | Disk partitioning (`/dev/nvme0n1`, GPT, ESP + root ext4) |
| `users/dev/home.cloudbox.nix` | Home-manager (ensure-projects, pull-workstation, bash secrets) |
| `users/dev/tmux.cloudbox.nix` | Tmux plugins (resurrect, catppuccin, continuum) |
| `secrets/cloudbox.yaml` | Encrypted secrets (age key on cloudbox) |
| `secrets/.sops.yaml` | Age public key for cloudbox |
