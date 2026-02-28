---
name: Setting Up Crostini (ChromeOS Linux)
description: Guide for setting up a Chromebook Crostini container with Nix and home-manager. Use when provisioning a new Chromebook or recovering from a container reset.
---

# Setting Up Crostini (ChromeOS Linux)

Crostini is a Debian Linux container on ChromeOS. Unlike devbox/cloudbox (NixOS) and macOS (nix-darwin), there is **no system-level Nix config manager** -- Nix is installed standalone and `/etc/nix/nix.conf` must be configured manually.

The setup script at `scripts/setup-crostini.sh` handles the one-time system configuration.

## Prerequisites

- ChromeOS with Linux (Crostini) enabled
- Nix installed (`curl -L https://nixos.org/nix/install | sh --daemon`)
- The workstation repo cloned to `~/projects/workstation`
- An SSH key at `~/.ssh/id_ed25519_github` for GitHub access

## Step 1: Install Nix

```bash
curl -L https://nixos.org/nix/install | sh --daemon
```

Log out and back in (or source the profile) so `nix` is on PATH.

## Step 2: Clone the repo

```bash
mkdir -p ~/projects
git clone git@github.com:johnnymo87/workstation.git ~/projects/workstation
```

## Step 3: Run the setup script

```bash
cd ~/projects/workstation
sudo bash scripts/setup-crostini.sh
```

This configures:

| Setting | Purpose |
|---------|---------|
| `trusted-users = root livia` | Lets home-manager's `nix.settings` add substituters the daemon respects |
| `extra-substituters = https://devenv.cachix.org` | Binary cache for devenv (~18MB download vs ~300 derivations from source) |
| `extra-trusted-public-keys = devenv.cachix.org-1:...` | Public key to verify cached binaries |
| `experimental-features = nix-command flakes` | Required for `nix run`, flake evaluation |

### Why this is needed

On NixOS (devbox/cloudbox), the system config in `hosts/*/configuration.nix` manages `/etc/nix/nix.conf`. On macOS, nix-darwin does the same. On Crostini, there's no system config manager, so these settings must be applied manually.

Without the devenv cache, `home-manager switch` builds devenv from source, which requires compiling the entire Nix C library stack (nix-util, nix-store, nix-cmd, nix-expr, etc.), cachix, and many Rust crate dependencies -- 300+ derivations that take hours on a Chromebook.

## Step 4: Set up sops age key

home-manager uses sops-nix to decrypt secrets (e.g., Gemini API key). An age key must exist before first activation.

```bash
# Generate a new key
nix-shell -p age --run 'mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt'
chmod 600 ~/.config/sops/age/keys.txt
```

Copy the public key (starts with `age1...`) and add it to `secrets/.sops.yaml` under the chromebook creation rule. Then re-encrypt `secrets/chromebook.yaml`:

```bash
# On a machine with the existing age key (e.g., devbox):
SOPS_AGE_KEY="<existing-key>" sops updatekeys secrets/chromebook.yaml
```

## Step 5: Apply home-manager

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#livia
```

This installs all user packages (tmux, neovim, opencode, beads, devenv, etc.), deploys dotfiles, clones declared projects, and decrypts secrets.

## Step 6: Verify

```bash
# Tools installed
tmux -V && nvim --version | head -1 && git --version && which opencode

# GitHub access
ssh -T git@github.com

# Projects cloned
ls ~/projects/

# Secrets decrypted (Gemini API key available)
echo $GOOGLE_GENERATIVE_AI_API_KEY | head -c 10
```

## Architecture differences from other hosts

| Property | Crostini | Devbox/Cloudbox | macOS |
|----------|----------|-----------------|-------|
| System manager | None (plain Debian) | NixOS | nix-darwin |
| `/etc/nix/nix.conf` | Manual (`setup-crostini.sh`) | NixOS `nix.settings` | nix-darwin `nix.settings` |
| Username | `livia` | `dev` | `jonathan.mohrbacher` |
| Home dir | `/home/livia` | `/home/dev` | `/Users/jonathan.mohrbacher` |
| Projects dir | `~/projects/` | `~/projects/` | `~/Code/` |
| System type | `x86_64-linux` | `aarch64-linux` | `aarch64-darwin` |
| Secrets | sops-nix (HM module, age key in `~/.config/sops/age/`) | sops-nix (NixOS module, `/run/secrets/`) | macOS Keychain |
| GPG signing | Disabled | Forwarded from macOS | Local (pinentry-op) |
| Flake config name | `homeConfigurations.livia` | `homeConfigurations.dev` | Embedded in `darwinConfigurations` |

## Relevant files

| File | Purpose |
|------|---------|
| `flake.nix` | `homeConfigurations.livia` (x86_64-linux, `isCrostini = true`) |
| `scripts/setup-crostini.sh` | One-time system config (nix.conf, flakes) |
| `users/dev/home.crostini.nix` | Crostini-specific HM: identity, sops, git, projects |
| `users/dev/tmux.crostini.nix` | Tmux plugins (resurrect, catppuccin, continuum) |
| `users/dev/home.base.nix` | Shared config (cross-platform) |
| `secrets/chromebook.yaml` | Encrypted secrets (age key on Chromebook) |
| `secrets/.sops.yaml` | Age public key for chromebook |

## Gotchas

1. **Binary cache chicken-and-egg**: The devenv cachix substituter is also configured in `home.base.nix` via `nix.settings`, but that only takes effect *after* home-manager activation. The `setup-crostini.sh` script breaks this cycle by configuring the daemon directly.

2. **trusted-users is required**: Even with `extra-substituters` in the user's `~/.config/nix/nix.conf`, the Nix daemon ignores them unless the user is in `trusted-users`. This is a security feature -- only trusted users can add arbitrary binary caches.

3. **No systemd user services by default**: Crostini's Debian does support systemd user units, but the session may not start `systemd --user` automatically. If `systemctl --user` commands fail, ensure the D-Bus session is running.

4. **Container resets lose everything**: If the Crostini container is deleted and recreated, you need to re-run the entire setup from Step 1. The setup script is idempotent and safe to re-run.
