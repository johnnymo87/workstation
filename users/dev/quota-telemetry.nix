# Hourly export of teamclaude's per-response usage ledger to the shared
# johnnymo87/quota-telemetry repo, so cloudbox can fit weekly-quota % against
# every host's tokens (the Max accounts are shared). Bead workstation-ynoq.2;
# plan docs/plans/2026-11-23-claude-max-quota-followups.md.
# devbox: systemd user timer. Mac: launchd agent (rows under mac/).
# Cloudbox exports its own rows from cfp events.
{ config, pkgs, lib, isDevbox, isDarwin, ... }:

let
  script = "${config.home.homeDirectory}/.local/bin/quota-telemetry-export";
  ledger = "${config.home.homeDirectory}/.local/state/teamclaude/usage.jsonl";
in
lib.mkIf (isDevbox || isDarwin) (lib.mkMerge [
  {
    home.file.".local/bin/quota-telemetry-export" = {
      executable = true;
      source = ../../assets/scripts/quota-telemetry-export.py;
    };
  }

  (lib.mkIf isDevbox {
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
  })

  (lib.mkIf isDarwin {
    # /usr/bin first so git uses macOS ssh (keychain-aware) for the push.
    launchd.agents.quota-telemetry-export = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkgs.python3}/bin/python3" script "--host" "mac" ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          TEAMCLAUDE_USAGE_LOG = ledger;
          PATH = "${pkgs.git}/bin:/usr/bin:/bin";
        };
        StartCalendarInterval = [ { Minute = 9; } ];
        RunAtLoad = false;
        ProcessType = "Background";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/quota-telemetry-export.out.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/quota-telemetry-export.err.log";
      };
    };
  })
])
