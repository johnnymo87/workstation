# nix-gc-floor: a disk-triggered garbage collection of DEAD store paths.
#
# WHY. Every `nix flake check` of this repo on devbox realises
# checks.home-cloudbox (flake.nix, "Build-level CI gate"), about 10G of
# cloudbox-only closure (azure-cli, google-cloud-sdk, figma-mcp deps, goose,
# openjdk, ...). Nothing roots it, so it is dead the moment the check ends,
# but nothing collects it either:
#   - nix-gc.service is weekly;
#   - min-free (configuration.nix) acts only inside a build and only below
#     10G free, the same point at which em-ci-disk-watchdog stops the CI
#     runners and well under em-ci-monitor's 20G alert.
# Measured 2026-10-13: free space went 34G -> 19G in ~4h of agent sessions
# running flake checks, em-ci-monitor paged, and a plain GC freed 8.5G of dead
# paths. configuration.nix had estimated the mid-day dead set at ~2G.
#
# THRESHOLDS, against the other lines on the same disk:
#   35G  target: room for one more flake check before the trigger
#   25G  trigger: this unit           <- acts first
#   20G  em-ci-monitor early warning (Telegram)
#   15G  em-ci setup refuses jobs (EM_CI_MIN_STORE_FREE_GB)
#   10G  em-ci-disk-watchdog stops both runners; nix min-free
#
# WHY THIS IS NOT THE GC users/dev/disk-cleanup.nix REFUSES TO AUTOMATE. That
# hazard was a foreground, normal-priority nix-collect-garbage that also
# deleted generations, moving 80-90G, above ~90% full, and it stalled sshd.
# This is the argument configuration.nix already accepted for min-free:
#   - It runs IN nix-daemon (NIX_REMOTE=daemon), which devbox schedules at
#     batch CPU / idle I/O, so it yields to sshd and interactive sessions.
#   - It deletes only already-dead paths, bounded by --max-freed, so it moves
#     ~10G, not 80-90G, and it never removes a generation.
#   - It fires at 25G free (~83%), before the danger zone rather than in it.
#   - When a GC finds under 1G dead, the space is held by something a store GC
#     cannot reach, so it backs off for 2h instead of re-scanning a tight disk
#     every tick.
{ pkgs, lib, ... }:

let
  floor = pkgs.writeShellApplication {
    name = "nix-gc-floor";
    runtimeInputs = [ pkgs.coreutils pkgs.nix ];
    text = builtins.readFile ./nix-gc-floor.sh;
  };
in
{
  systemd.services.nix-gc-floor = {
    description = "Collect dead nix store paths when root free space is low";
    environment = {
      GC_FLOOR_TRIGGER_GIB = "25";
      GC_FLOOR_TARGET_GIB = "35";
      GC_FLOOR_BACKOFF_MIN = "120";
      GC_FLOOR_MIN_USEFUL_GIB = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe floor;
      StateDirectory = "nix-gc-floor";
      # The daemon does the deleting at its own scheduling; these keep the
      # client side (df, the RPC wait) out of the way too.
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUSchedulingPolicy = "batch";
    };
  };

  systemd.timers.nix-gc-floor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
    };
  };
}
