# Hourly export of teamclaude's per-response usage ledger to the shared
# johnnymo87/quota-telemetry repo, so cloudbox can fit weekly-quota % against
# BOTH hosts' tokens (the five Max accounts are shared). Bead
# workstation-ynoq.2; plan docs/plans/2026-11-23-claude-max-quota-followups.md.
# Devbox only: cloudbox exports its own rows from cfp events.
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  home.file.".local/bin/quota-telemetry-export" = {
    executable = true;
    source = ../../assets/scripts/quota-telemetry-export.py;
  };

  systemd.user.services.quota-telemetry-export = {
    Unit.Description = "Export hourly Claude Max usage rows to quota-telemetry";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 %h/.local/bin/quota-telemetry-export --host devbox";
      Environment = [
        "HOME=%h"
        "TEAMCLAUDE_USAGE_LOG=%h/.local/state/teamclaude/usage.jsonl"
        "PATH=${lib.makeBinPath [ pkgs.git pkgs.openssh pkgs.coreutils ]}"
      ];
      Nice = 15;
      TimeoutStartSec = "5min";
    };
  };

  systemd.user.timers.quota-telemetry-export = {
    Unit.Description = "Hourly quota-telemetry export";
    Timer = {
      OnCalendar = "*-*-* *:07:00";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
