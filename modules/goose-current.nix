# The approved goose binary on a NixOS host (bead workstation-6w7i.27.2, L6;
# runbook in the design field of epic workstation-6w7i.27).
#
# /var/lib/goose/current is a symlink to a goose store path. goose-serve's start
# script execs it, and the user's `goose` (users/dev/goose-config.nix) is a
# wrapper that execs it, so the serve and the CLI -- two writers of one
# sessions.db -- cannot run different binaries.
#
# The point is what does NOT move it. tmpfiles creates the link only if it is
# absent (`L`, never `L+`), so a merged pkgs/goose pin, a switch, the nightly
# reset's goose-serve restart, a Restart=always crash restart and
# pull-workstation all leave the running goose where it was. Only goose-link
# moves it: the cutover (goose-cutover, L3a) after the probe passes, or a human
# rolling back:
#
#   sudo goose-link rollback && sudo systemctl restart goose-serve
#
# A rollback that crosses a config change also wants the previous system and
# home-manager generations (the cutover does both; see goose-link's header).
#
# /etc/goose/pinned is what the merged pin WANTS; `goose-link status` shows
# whether it is what runs. Both link targets (current and previous) are indirect
# GC roots, so neither binary is collected while a link names it; the pinned one
# is in the system closure through /etc.
#
# On a fresh host the first switch creates the link at the pin, which is the
# only time the pin decides what runs. Darwin is out of scope (it restarts its
# goose-serve on every home-switch; bead A10, workstation-6w7i.26).
{ pkgs, ... }:

let
  # Not pkgs.goose: that is nixpkgs' pressly/goose database migration tool.
  goose-cli = pkgs.callPackage ../pkgs/goose { };
  goose-link = pkgs.callPackage ../pkgs/goose-link { };
in
{
  environment.etc."goose/pinned".source = goose-cli;
  environment.systemPackages = [ goose-link ];

  systemd.tmpfiles.rules = [
    "d /var/lib/goose 0755 root root - -"
    "L /var/lib/goose/current - - - - ${goose-cli}"
    "L+ /nix/var/nix/gcroots/goose-current - - - - /var/lib/goose/current"
    "L+ /nix/var/nix/gcroots/goose-previous - - - - /var/lib/goose/previous"
  ];
}
