#!/usr/bin/env bash
# One-time system-level setup for Crostini (ChromeOS Linux).
#
# Crostini runs plain Debian with Nix installed standalone (no NixOS).
# This script configures the Nix daemon so that home-manager can build
# efficiently using binary caches, and performs other one-time setup.
#
# Run once after installing Nix on a fresh Crostini container:
#   sudo bash scripts/setup-crostini.sh
#
# After this, apply home-manager:
#   nix run home-manager -- switch --flake .#livia

set -euo pipefail

NIX_CONF="/etc/nix/nix.conf"

echo "=== Crostini Nix Setup ==="
echo ""

# --- 1. Configure binary caches and trusted users ---
# Without this, home-manager builds devenv from source (~300 derivations).
# The devenv cachix has pre-built x86_64-linux binaries.
#
# trusted-users lets the user's ~/.config/nix/nix.conf (written by
# home-manager) add extra-substituters that the daemon will respect.

needs_update=false

if ! grep -q 'experimental-features' "$NIX_CONF" 2>/dev/null; then
  needs_update=true
fi

if ! grep -q 'devenv.cachix.org' "$NIX_CONF" 2>/dev/null; then
  needs_update=true
fi

if ! grep -q 'trusted-users.*livia' "$NIX_CONF" 2>/dev/null; then
  needs_update=true
fi

if $needs_update; then
  echo "Configuring $NIX_CONF ..."

  # Append only missing settings (idempotent)
  if ! grep -q 'experimental-features' "$NIX_CONF" 2>/dev/null; then
    echo 'experimental-features = nix-command flakes' >> "$NIX_CONF"
    echo "  Added experimental-features (nix-command flakes)"
  fi

  if ! grep -q 'trusted-users.*livia' "$NIX_CONF" 2>/dev/null; then
    echo 'trusted-users = root livia' >> "$NIX_CONF"
    echo "  Added trusted-users"
  fi

  if ! grep -q 'devenv.cachix.org' "$NIX_CONF" 2>/dev/null; then
    echo 'extra-substituters = https://devenv.cachix.org' >> "$NIX_CONF"
    echo 'extra-trusted-public-keys = devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=' >> "$NIX_CONF"
    echo "  Added devenv cachix substituter"
  fi

  echo "Restarting nix-daemon ..."
  systemctl restart nix-daemon
  echo "  Done"
else
  echo "nix.conf already configured, skipping."
fi

echo ""

# --- 2. Verify flakes are enabled ---
USER_NIX_CONF="/home/livia/.config/nix/nix.conf"
if ! grep -q 'experimental-features.*flakes' "$USER_NIX_CONF" 2>/dev/null; then
  echo "Enabling flakes in $USER_NIX_CONF ..."
  sudo -u livia mkdir -p "$(dirname "$USER_NIX_CONF")"
  echo 'experimental-features = nix-command flakes' | sudo -u livia tee "$USER_NIX_CONF" > /dev/null
  echo "  Done"
else
  echo "Flakes already enabled."
fi

echo ""

# --- 3. Verify sops age key ---
AGE_KEY="/home/livia/.config/sops/age/keys.txt"
if [ -f "$AGE_KEY" ]; then
  echo "sops age key found at $AGE_KEY"
else
  echo "WARNING: sops age key not found at $AGE_KEY"
  echo "  You need to create or copy an age key before home-manager can decrypt secrets."
  echo "  Generate one with: nix-shell -p age --run 'age-keygen -o $AGE_KEY'"
  echo "  Then add the public key to secrets/.sops.yaml and re-encrypt secrets/chromebook.yaml"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Ensure SSH key exists at ~/.ssh/id_ed25519_github"
echo "  2. Run: nix run home-manager -- switch --flake .#livia"
