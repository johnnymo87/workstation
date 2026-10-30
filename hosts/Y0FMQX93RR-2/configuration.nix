# Darwin (macOS) system configuration
{ config, pkgs, lib, mac, ... }:

let
  # SECURITY TOGGLE: unattended passwordless root via `sudo darwin-rebuild`.
  # Keep false. Flip to true only for a deliberate hands-off remote SYSTEM
  # repair, then flip back. Turning it ON is a system deploy (`darwin-switch`)
  # and so needs one Admin By Request window; turning it OFF does not, because
  # the rule itself makes that deploy passwordless. See
  # the environment.etc."sudoers.d/darwin-rebuild" block below for the full
  # rationale, and the remote-workstation-cutover skill for when it is needed
  # at all (home-level repairs never need it).
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

  # Automatic garbage collection of SYSTEM generations.
  #
  # Both run as root launchd daemons (org.nixos.nix-gc / org.nixos.nix-optimise)
  # that nix-darwin installs and launchd fires on a calendar. No user sudo is
  # involved at run time, so they keep working after local admin is removed;
  # only changing the schedule is a system deploy.
  #
  # Why root is needed at all: the user can already GC the store unprivileged
  # (home-manager's autoExpire in home.darwin.nix runs nix-collect-garbage
  # nightly as the user), but every old /nix/var/nix/profiles/system-N-link is a
  # root-owned GC root that only root can delete -- and those generations pin
  # every package they ever referenced.
  #
  # Retention: 30 days. Long enough that `sudo darwin-rebuild --rollback` (and
  # the standalone-home-manager migration rollback in
  # docs/plans/2026-10-30-mac-standalone-home-manager.md) stays available for a
  # month; short enough that a weekly run keeps the store bounded.
  # Sunday 03:15 / 04:15 local. A Mac asleep at that time runs it at next wake
  # (launchd coalesces missed StartCalendarInterval slots).
  nix.gc = {
    automatic = true;
    interval = [ { Weekday = 0; Hour = 3; Minute = 15; } ];
    options = "--delete-older-than 30d";
  };
  # Hard-links identical store files. The periodic job, NOT
  # nix.settings.auto-optimise-store, which is known to misbehave on darwin.
  nix.optimise = {
    automatic = true;
    interval = [ { Weekday = 0; Hour = 4; Minute = 15; } ];
  };

  # Allow unfree
  nixpkgs.config.allowUnfree = true;

  # setproctitle fork tests segfault on Darwin; see the overlay file. The same
  # overlay is applied to the standalone home-manager's pkgs (darwinHomePkgs in
  # flake.nix) so system and home evaluate one package set.
  nixpkgs.overlays = [ (import ../../overlays/setproctitle-darwin.nix) ];

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
  # WITHOUT LOCAL ADMIN (IT is removing it from this Mac): interactive sudo of
  # any kind -- including `sudo darwin-rebuild` -- works only inside an
  # Admin By Request elevation window. The general sudo grant this user has
  # today comes from outside this repo -- the `%admin` rule in /etc/sudoers
  # and/or JumpCloud's per-user file in /etc/sudoers.d (root-only, so not
  # inspected) -- and both are IT's to remove along with admin. This repo
  # configures no Touch ID for sudo and never did. So plan on every SYSTEM
  # deploy (`darwin-switch`) needing a window.
  # User-level config deploys with `home-switch` and needs no root at all.
  #
  # TO TURN THIS ON you need one elevated system deploy: set
  # enableUnattendedRemoteRoot = true, run `darwin-switch` inside a window.
  #
  # ONCE INSTALLED, this rule keeps working with no admin membership and no
  # window: it is keyed on the USERNAME, not on %admin. That is the point of it
  # (a Claude on cloudbox can repair the Mac's system config when the Mac's own
  # Claude access is broken) and also its hazard: it BYPASSES Admin By Request,
  # whose whole job is to make root short-lived and audited. Leave it enabled
  # only for the repair that needs it, and flip it back the same day. Flipping
  # it back needs no window: while the rule is installed, `darwin-switch`'s
  # `sudo /run/current-system/sw/bin/darwin-rebuild` is exactly the command it
  # allows. One caveat: IT's agent also
  # manages files in /etc/sudoers.d; if it ever prunes files it did not write,
  # this rule silently disappears (fails closed -- `sudo -n` starts asking for a
  # password).
  #
  # Pair it with an on-demand `ssh cloudbox-cutover` window (the reverse tunnel
  # is no longer always-on; see scripts/update-ssh-config.sh) and the
  # remote-workstation-cutover skill.
  environment.etc."sudoers.d/darwin-rebuild" = lib.mkIf enableUnattendedRemoteRoot {
    text = ''
      ${mac.username} ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild
    '';
  };
}
