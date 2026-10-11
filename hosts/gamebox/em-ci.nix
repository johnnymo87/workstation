# gamebox's em-ci runners: the primary pool. devbox's runners are a label-gated
# failover (hosts/devbox/em-ci-failover.nix). Design:
# docs/plans/2026-10-11-em-ci-gamebox-design.md.
{ ... }:
{
  imports = [ ../../modules/em-ci-runners.nix ];

  services.em-ci-runners = {
    enable = true;
    namePrefix = "gamebox";
    runners = {
      em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
      em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
    };
    cpus = 3;
    memoryMax = "5G";
    stateDevice = null;          # root NVMe; the disk watchdog guards it
    externalInterface = null;    # Ethernet or Wi-Fi, whichever is up
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
