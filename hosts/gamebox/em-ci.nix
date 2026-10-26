# gamebox's em-ci runners: the primary pool. devbox's runners are a label-gated
# failover (hosts/devbox/em-ci-failover.nix). Design:
# docs/plans/2026-10-11-em-ci-gamebox-design.md.
{ ... }:
{
  imports = [
    ../../modules/em-ci-runners.nix
    ./em-ci-pause.nix
  ];

  # SIZING: three runners, 3 CPU / 5 GiB each, on an i7-7700K (4 cores /
  # 8 threads) with 16 GiB RAM and 24 GiB swap (disk + zram). The caps sum to
  # 9 CPUs and 15 GiB (18 GiB with nix-daemon's), which is more than the host
  # has. That is deliberate: they are ceilings, not reservations, and
  # measurement says jobs stay well under them. Measured 2026-10-26, bead
  # eternal-machinery-kdubj.5:
  # - Queueing, not job speed, was the CI cost. In the week to 2026-10-26, 405
  #   jobs waited 56 h for one of two runners. Replaying that week's arrivals
  #   and durations: 2 runners 46 h of waiting, 3 runners 12 h (17 h if each
  #   job also ran 15% slower), 4 runners 3 h.
  # - CPU: a busy runner averaged 0.9 cores and sat at its 3-core cap in 3-7%
  #   of minutes (CFS-throttled 8% of busy time), so a third runner rather than
  #   bigger ones. CPUWeight=50 keeps the host ahead when they contend.
  # - RAM: peak anonymous memory 2.9 GiB (lint job), 0.9 GiB (Elixir,
  #   conformance, agno, frontend), 3.6 GiB both runners together; host
  #   MemAvailable never fell below 9.4 GiB. memory.peak reads ~4.5 GiB only
  #   because it counts reclaimable page cache. nix-daemon's anon stayed under
  #   20 MiB; its MemoryMax hits are page-cache reclaim (oom 0).
  # - Gaming: the pause (em-ci-pause.nix) stops all runners for a stream, so
  #   these caps never compete with a game.
  # Adding a runner: next free pair is 10.233.71.13/.14; container names must
  # match em-ci-* for the egress fence and stay <= 11 chars.
  services.em-ci-runners = {
    enable = true;
    namePrefix = "gamebox";
    runners = {
      em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
      em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
      em-ci-3 = { n = 3; hostAddress = "10.233.71.9"; localAddress = "10.233.71.10"; };
    };
    cpus = 3;
    memoryMax = "5G";
    stateDevice = null;          # root NVMe; the disk watchdog guards it
    externalInterface = null;    # Ethernet or Wi-Fi, whichever is up
    pauseFlag = "/run/em-ci-paused";
  };

  # Builds the containers request run in nix-daemon's cgroup, outside the
  # container caps. Max-only (no MemoryHigh): a throttled daemon is the
  # alive-but-frozen trap. If a gamebox rebuild itself (Sunshine+CUDA compiles
  # locally) hits this, lift it for that one rebuild:
  #   sudo systemctl set-property --runtime nix-daemon MemoryMax=infinity CPUQuota=
  systemd.services.nix-daemon.serviceConfig = {
    MemoryMax = "3G";
    CPUQuota = "400%";
  };
  nix.settings = { max-jobs = 2; cores = 4; };
}
