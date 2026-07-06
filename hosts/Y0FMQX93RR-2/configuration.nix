# Darwin (macOS) system configuration
{ config, pkgs, lib, mac, ... }:

let
  # SECURITY TOGGLE: unattended passwordless root via `sudo darwin-rebuild`.
  # Keep false. Flip to true (+ `darwin-rebuild switch`) only for a deliberate
  # hands-off remote workstation upgrade, then flip back. See the
  # environment.etc."sudoers.d/darwin-rebuild" block below for the full rationale.
  enableUnattendedRemoteRoot = false;
in
{
  # Platform
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Nix settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" mac.username ];
    extra-substituters = [
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  # Allow unfree
  nixpkgs.config.allowUnfree = true;

  # setproctitle fork tests segfault on Darwin (exit code -11),
  # blocking azure-cli build. Disable tests for this package.
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (pfinal: pprev: {
          setproctitle = pprev.setproctitle.overridePythonAttrs {
            doCheck = false;
          };
        })
      ];
    })
  ];

  # Primary user (single-user laptop ergonomics)
  system.primaryUser = mac.username;

  # Login shell: set Nix bash as the user's login shell via dscl
  # Requires knownUsers so nix-darwin's activation script runs chsh.
  programs.bash.enable = true;
  environment.shells = [ pkgs.bashInteractive ];
  users.knownUsers = [ mac.username ];
  users.users.${mac.username} = {
    uid = 504;
    shell = pkgs.bashInteractive;
  };

  # State version (nix-darwin uses integers 1-6)
  system.stateVersion = 6;

  # Passwordless sudo for darwin-rebuild.
  #
  # SECURITY (2026-07): DISABLED by default. This grants unattended root: a
  # remote driver (e.g. an opencode session on the public-IP cloudbox reaching
  # in over the reverse SSH tunnel) could run `sudo darwin-rebuild switch
  # --flake <anything>`, and darwin-rebuild activates arbitrary system config =
  # arbitrary code execution as root. That turned a compromised cloudbox into a
  # root foothold on this corporate laptop. See docs and the cloudbox->mac
  # reverse-tunnel notes in scripts/update-ssh-config.sh.
  #
  # Interactive `sudo darwin-rebuild ...` still works for the physically-present
  # user (normal sudo password / Touch ID) via the base (ALL) ALL grant, so
  # local upgrades are unaffected. Only the *unattended/remote* NOPASSWD path is
  # removed.
  #
  # RE-ENABLE for a hands-off remote workstation upgrade by flipping this flag to
  # true and running `darwin-rebuild switch`. Flip it back to false when done.
  # Pair it with an on-demand `ssh cloudbox-cutover` window (the reverse tunnel
  # is no longer always-on; see scripts/update-ssh-config.sh).
  environment.etc."sudoers.d/darwin-rebuild" = lib.mkIf enableUnattendedRemoteRoot {
    text = ''
      ${mac.username} ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild
    '';
  };
}
