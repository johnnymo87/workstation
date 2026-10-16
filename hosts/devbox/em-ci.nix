# devbox's em-ci runners. Implementation and rationale:
# modules/em-ci-runners.nix. Design: docs/plans/2026-10-11-em-ci-gamebox-design.md.
{ ... }:
{
  imports = [ ../../modules/em-ci-runners.nix ];

  services.em-ci-runners = {
    enable = true;
    namePrefix = "devbox";
    # One /30 per container: host side .1/.5, container side .2/.6.
    runners = {
      em-ci-1 = { n = 1; hostAddress = "10.233.71.1"; localAddress = "10.233.71.2"; };
      em-ci-2 = { n = 2; hostAddress = "10.233.71.5"; localAddress = "10.233.71.6"; };
    };
    cpus = 4;
    memoryMax = "6G";
    stateDevice = "/dev/disk/by-id/scsi-0HC_Volume_107073920";
    externalInterface = "enp1s0";
  };

  # /tmp/credo-diff-<ts> checkouts left by local `mix credo diff` runs are
  # removed by hosts/devbox/credo-diff-sweep.nix (it replaced a tmpfiles rule
  # here that atime kept from firing).
}
