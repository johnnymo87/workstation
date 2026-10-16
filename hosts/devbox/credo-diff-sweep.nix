# credo-diff-sweep: hourly removal of /tmp/credo-diff-<ts> checkouts older
# than 6h.
#
# WHY. `mix credo diff` (eternal-machinery's lint ratchet, run by agent
# sessions on the host) materialises a full checkout of the baseline under
# /tmp/credo-diff-<ts> and never deletes it: 70-130M each, ~66 a day
# measured 2026-10-14/15. On 2026-10-16 134 of them held 8.2G and kept
# em-ci-monitor's "root disk below 20 GB" alert firing.
#
# WHY NOT THE tmpfiles RULE THIS REPLACES (`e /tmp/credo-diff-* - - - 1d`).
# systemd-tmpfiles ages on the newest of atime/mtime/ctime, and anything that
# reads a checkout (an rg over /tmp, a du) moves atime. With the clean timer
# running once a day, checkouts survived up to ~2 days -- a steady 6-8G.
# Same failure class as users/dev/disk-cleanup.nix's tmp-scratch-sweep notes.
# This sweep ages by the UTC timestamp credo writes into the name instead.
#
# 6h is far above a credo diff's runtime (minutes), so a live run is never
# swept; steady state is a few hours of checkouts, ~2G.
#
# The CI runner containers have their own /tmp, cleaned by
# eternal-machinery's .github/ci/prepare-workspace.sh; this is the host only.
{ pkgs, lib, ... }:

let
  sweep = pkgs.writeShellApplication {
    name = "credo-diff-sweep";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./credo-diff-sweep.sh;
  };
in
{
  systemd.services.credo-diff-sweep = {
    description = "Remove stale /tmp/credo-diff-* checkouts";
    environment.CREDO_SWEEP_MAX_AGE_MIN = "360";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe sweep;
      # The checkouts are dev's; deleting as dev means root never rm -rf's
      # anything in a world-writable /tmp.
      User = "dev";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.timers.credo-diff-sweep = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "1h";
    };
  };
}
