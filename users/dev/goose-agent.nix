# goose's tool-command slice and its wedge canary, on both NixOS hosts.
# Bead workstation-6w7i.7.
#
# 1. goose-agent.slice: every goose tool command runs in its own transient
#    user scope under this slice (pkgs/goose-tool-shell, built by the
#    goose-serve unit in hosts/*/configuration.nix with the same sliceName from
#    lib/goose-agent.nix). The per-command cap bounds ONE command; this slice's
#    cap bounds all of them together, now that they no longer count against
#    goose-serve's own MemoryMax.
#
# 2. goose-canary: minutely ACP probe of goose-serve and honkd. ALERT-ONLY:
#    restarting either ends every goose turn it carries, so until restarts stop
#    losing turns (workstation-6w7i.16) a human decides. See
#    pkgs/goose-canary/goose_canary.py.
{ config, pkgs, lib, localPkgs, isDevbox, isCloudbox, ... }:

let
  ga = import ../../lib/goose-agent.nix;
  hostName = if isCloudbox then "cloudbox" else "devbox";
  sizes = ga.hosts.${hostName};
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
in
lib.mkIf (isDevbox || isCloudbox) {
  systemd.user.slices.${ga.sliceName} = {
    Unit = {
      Description = "goose tool commands, each in its own capped scope, held outside goose-serve's cgroup";
      # Stopping a slice stops every scope in it, i.e. kills every running goose
      # tool command. A later edit to this unit must not do that unattended
      # (pull-workstation switches on its own); cgroup limits re-realize on
      # daemon-reload without a restart. Same reasoning as lgtm-review.slice.
      X-SwitchMethod = "keep-old";
    };
    Slice = {
      # Max-only, no MemoryHigh: the host's standing rule (a high mark stalls
      # instead of killing; workstation-94g8, h1y6).
      MemoryMax = sizes.sliceMemoryMax;
      MemorySwapMax = sizes.sliceMemorySwapMax;
      TasksMax = sizes.sliceTasksMax;
    };
  };

  systemd.user.services.goose-canary = {
    Unit.Description = "goose-serve + honkd wedge canary (ACP probe; alert-only)";
    Service = {
      Type = "oneshot";
      # A hung pass would stop the timer from ever firing again, silently.
      TimeoutStartSec = 300;
      Nice = 10;
      Environment = [
        "GOOSE_CANARY_HOST=${hostName}"
        "GOOSE_CANARY_STATE=${config.home.homeDirectory}/.local/state/goose-canary"
        "GOOSE_CANARY_ALERT=${driftAlert}"
        "GOOSE_CANARY_HONK=${config.home.homeDirectory}/.nix-profile/bin/honk"
        "GOOSE_CANARY_SECRET_FILE=/run/secrets/pigeon_goose_acp_token"
        "GOOSE_CANARY_SYSTEMCTL=${pkgs.systemd}/bin/systemctl"
        "GOOSE_CANARY_PORT=4080"
      ];
      ExecStart = "${localPkgs.goose-canary}/bin/goose-canary";
    };
  };

  systemd.user.timers.goose-canary = {
    Unit.Description = "Minutely goose-serve + honkd wedge canary";
    Timer = {
      OnBootSec = "3min";
      OnUnitActiveSec = "1min";
      AccuracySec = "10s";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
