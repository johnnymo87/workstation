# goose-cutover: systemd template unit for controlled goose pin cutover (L3a, bead workstation-6w7i.27.3).
{ config, pkgs, lib, ... }:

let
  goose-link = pkgs.callPackage ../pkgs/goose-link { };
  goose-cutover = pkgs.callPackage ../pkgs/goose-cutover {
    inherit goose-link;
  };
  driftAlert = pkgs.callPackage ../pkgs/opencode-drift-alert { };
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
      PrivateTmp = false;
      TimeoutStartSec = "5h";
      MemoryMax = "8G";
      StateDirectory = "goose-cutover";
    };
  };

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
        ${driftAlert} "/var/lib/goose-cutover/alert-failed.state" "goose-cutover:failed" "$MSG" 0
      ''}";
    };
  };
}
