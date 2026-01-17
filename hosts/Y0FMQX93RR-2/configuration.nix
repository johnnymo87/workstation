# Darwin (macOS) system configuration
{ config, pkgs, lib, mac, ... }:

{
  # Platform
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" mac.username ];
  };

  # Allow unfree
  nixpkgs.config.allowUnfree = true;

  # Primary user (single-user laptop ergonomics)
  system.primaryUser = mac.username;

  # State version (nix-darwin uses integers 1-6)
  system.stateVersion = 6;
}
