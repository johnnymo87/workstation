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
  cfpEvents = "${config.home.homeDirectory}/.local/state/claude-failover-proxy/events.jsonl";
  gooseDb = "${config.home.homeDirectory}/.local/share/goose/sessions/sessions.db";

  llmOutlookSyncScript = pkgs.writeShellScript "llm-outlook-sync" ''
    set -euo pipefail

    STATE_DIR="''${LLM_LEDGER_STATE_DIR:-$HOME/.local/state/llm-ledger}"
    REPO_DIR="''${LLM_OUTLOOK_REPO_DIR:-$STATE_DIR/outlook-repo}"
    OUTLOOK_JSON="''${LLM_LEDGER_OUTLOOK_JSON:-$STATE_DIR/outlook.json}"
    REMOTE="''${LLM_OUTLOOK_REMOTE:-git@github.com:johnnymo87/quota-telemetry.git}"
    BRANCH="''${LLM_OUTLOOK_BRANCH:-outlook}"

    export GIT_SSH_COMMAND="''${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15}"

    mkdir -p "$STATE_DIR"

    if ! git -C "$REPO_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      rm -rf "''${REPO_DIR:?}"
      git clone --quiet --depth 1 --branch "$BRANCH" "$REMOTE" "$REPO_DIR"
    else
      timeout 60 git -C "$REPO_DIR" fetch --quiet --depth 1 origin "$BRANCH"
      git -C "$REPO_DIR" update-ref "refs/heads/$BRANCH" FETCH_HEAD
      git -C "$REPO_DIR" reflog expire --expire=now --all
      git -C "$REPO_DIR" prune --expire=now
    fi

    TARGET_DIR="$(dirname "$OUTLOOK_JSON")"
    mkdir -p "$TARGET_DIR"
    TMP_FILE="$(mktemp "$TARGET_DIR/outlook.json.tmp.XXXXXX")"
    trap 'rm -f "$TMP_FILE"' EXIT

    git -C "$REPO_DIR" show "HEAD:outlook.json" > "$TMP_FILE"

    python3 -c '
import json, os, sys
path = sys.argv[1]
try:
    if os.path.getsize(path) > 65536:
        sys.exit(1)
    with open(path, "rb") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        sys.exit(1)
except Exception:
    sys.exit(1)
' "$TMP_FILE" || {
      echo "llm-outlook-sync: invalid outlook.json; keeping previous file" >&2
      exit 1
    }

    mv -f "$TMP_FILE" "$OUTLOOK_JSON"
    trap - EXIT
  '';
in
lib.mkIf (isDevbox || isDarwin) (lib.mkMerge [
  {
    home.file.".local/bin/quota-telemetry-export" = {
      executable = true;
      source = ../../assets/scripts/quota-telemetry-export.py;
    };
  }

  (lib.mkIf isDevbox {
    home.packages = [
      (pkgs.callPackage ../../pkgs/llm-ledger { })
    ];

    systemd.user.services.llm-outlook-sync = {
      Unit.Description = "Sync Claude quota outlook JSON from telemetry repo";
      Service = {
        Type = "oneshot";
        ExecStart = "${llmOutlookSyncScript}";
        Environment = [
          "HOME=%h"
          "PATH=${lib.makeBinPath [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.python3 ]}"
          "\"GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15\""
        ];
        Nice = 10;
        TimeoutStartSec = "90s";
      };
    };

    systemd.user.timers.llm-outlook-sync = {
      Unit.Description = "Sync Claude quota outlook JSON every 2 minutes";
      Timer = {
        OnCalendar = "*:0/2";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
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
  })

  (lib.mkIf isDarwin {
    # git from nix, ssh from /usr/bin (as ensure-projects does). The ssh
    # timeouts stop a push stuck across a lid close from wedging the agent.
    launchd.agents.quota-telemetry-export = {
      enable = true;
      config = {
        ProgramArguments = [ "${pkgs.python3}/bin/python3" script "--host" "mac" "--cfp-events" cfpEvents "--goose-db" gooseDb ];
        EnvironmentVariables = {
          HOME = config.home.homeDirectory;
          TEAMCLAUDE_USAGE_LOG = ledger;
          PATH = "${pkgs.git}/bin:/usr/bin:/bin";
          GIT_SSH_COMMAND = "/usr/bin/ssh -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4";
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
