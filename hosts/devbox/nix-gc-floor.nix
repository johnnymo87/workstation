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
# hazard was a foreground, unthrottled nix-collect-garbage that also deleted
# generations, moving 80-90G, and it stalled sshd. This one:
#   - deletes only already-dead paths, bounded by --max-freed, so it moves
#     ~10G and never removes a generation;
#   - runs in its own cgroup with hard I/O limits on the store's disk (below).
#     A cgroup io.max limit is enforced by blk-throttle and works under any
#     scheduler. The obvious alternative -- route the GC through nix-daemon,
#     which is configured with daemonIOSchedClass=idle -- does NOT work here:
#     devbox's root disk runs the `none` scheduler, and I/O priority classes
#     are only honoured by BFQ/mq-deadline. (Limitation, stated: ext4 journal
#     commits run in jbd2, outside this cgroup, so unlink metadata is paced
#     by the throttled reads rather than capped directly.)
#     MEASURED 2026-10-14 with a probe doing a 4k O_DSYNC write plus two
#     small reads every 0.2s (baseline p50 21ms, max 34ms): a throttled run
#     freed 2.0G in 35s with p50 22ms; an UNthrottled run freed 1.4G in 12s
#     with max 46ms. So at this size a dead-only GC is not the operation that
#     stalled sshd; the limits are insurance for larger dead sets.
#   - fires at 25G free, well before the danger zone, so it normally runs
#     with room to spare rather than racing a full disk.
#   - backs off 30 min after a GC that found under 1G dead (the space is
#     held by something a store GC cannot reach), unless free space drops
#     another 2G meanwhile -- that drop is usually a flake check finishing,
#     i.e. fresh garbage, which is the case this unit exists for.
{ config, pkgs, lib, ... }:

let
  floor = pkgs.writeShellApplication {
    name = "nix-gc-floor";
    runtimeInputs = [ pkgs.coreutils config.nix.package ];  # the system nix, matching the store DB
    text = builtins.readFile ./nix-gc-floor.sh;
  };
in
{
  systemd.services.nix-gc-floor = {
    description = "Collect dead nix store paths when root free space is low";
    environment = {
      GC_FLOOR_TRIGGER_GIB = "25";
      GC_FLOOR_TARGET_GIB = "35";
      GC_FLOOR_BACKOFF_MIN = "30";
      GC_FLOOR_BACKOFF_BYPASS_GIB = "2";
      GC_FLOOR_MIN_USEFUL_GIB = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe floor;
      StateDirectory = "nix-gc-floor";
      # The GC runs in this unit (local store), so these bind the process
      # doing the deleting. The path form resolves to whatever block device
      # backs /nix/store (it has been both sdb and sdc). Verified applied as
      # `8:32 rbps=40000000 wbps=40000000 riops=300 wiops=300` on 2026-10-14.
      IOReadBandwidthMax = "/nix/store 40M";
      IOWriteBandwidthMax = "/nix/store 40M";
      IOReadIOPSMax = "/nix/store 300";
      IOWriteIOPSMax = "/nix/store 300";
      Nice = 19;
      CPUSchedulingPolicy = "idle";
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
