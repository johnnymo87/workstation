# goose-cutover: systemd template unit for controlled goose pin cutover (L3a, bead workstation-6w7i.27.3).
{ config, pkgs, lib, ... }:

let
  goose-link = pkgs.callPackage ../pkgs/goose-link { };
  driftAlert = pkgs.callPackage ../pkgs/opencode-drift-alert { };
  goose-cutover = pkgs.callPackage ../pkgs/goose-cutover {
    inherit goose-link driftAlert;
  };
in
{
  environment.systemPackages = [ goose-cutover ];

  systemd.services."goose-cutover@" = {
    description = "goose cutover execution (%i)";
    restartIfChanged = false;
    stopIfChanged = false;
    onFailure = [ "goose-cutover-failed.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${goose-cutover}/bin/goose-cutover --run %i";
      ExecStopPost = "${pkgs.writeShellScript "goose-cutover-exec-stop-post" ''
        set -u
        # By the time ExecStopPost runs, our own goose-cutover process has already exited
        # and released /var/lib/goose-cutover/run.lock. If run.lock is currently held,
        # another goose-cutover instance is running and owns the locks and timer state.
        if ! ${pkgs.util-linux}/bin/flock -n /var/lib/goose-cutover/run.lock true 2>/dev/null; then
          echo "goose-cutover ExecStopPost: run.lock is held by another cutover instance; skipping stall-watch restore"
          exit 0
        fi
        ${pkgs.util-linux}/bin/runuser -u dev -- env XDG_RUNTIME_DIR=/run/user/1000 ${pkgs.systemd}/bin/systemctl --user start stall-watch.timer stall-watch-wake.path
      ''}";
      WorkingDirectory = "/var/lib/goose-cutover";
      PrivateTmp = false;
      TimeoutStartSec = "5h";
      TimeoutStopSec = "15min";
      MemoryMax = "16G"; # the probe peaked at 8G + 2.9G swap under an 8G cap (dry run 2026-11-22)
      StateDirectory = "goose-cutover";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/goose-cutover 0755 root root - -"
    "f /var/lib/goose-cutover/run.lock 0644 root root - -"
    "d /var/lib/goose-cutover/gcroots 0755 dev users - -"
    "d /var/lib/goose-cutover/backups 0755 dev users - -"
    "d /var/lib/goose-cutover/host-reports 0755 dev users - -"
  ];

  systemd.services.goose-cutover-failed = {
    description = "goose-cutover failure notification";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "goose-cutover-failed" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq pkgs.curl pkgs.systemd pkgs.gawk ]}
        STATE_FILE="/var/lib/goose-cutover/state.json"
        PHASE="unknown"
        if [ -f "$STATE_FILE" ]; then
          PHASE=$(jq -r '.phase // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
        fi
        FAILED_UNIT=$(systemctl list-units 'goose-cutover@*' --state=failed --no-legend 2>/dev/null | awk '{print $1}' | head -n1)
        [ -z "$FAILED_UNIT" ] && FAILED_UNIT="goose-cutover"
        MSG="$FAILED_UNIT died; state.json phase=$PHASE, goose-serve may need \`goose-cutover deploy --recover\`"
        SIG="goose-cutover-failed:$FAILED_UNIT:$(date +%s)"
        ${driftAlert} "/var/lib/goose-cutover/alert-failed.state" "$SIG" "$MSG" 0
      ''}";
    };
  };
}
