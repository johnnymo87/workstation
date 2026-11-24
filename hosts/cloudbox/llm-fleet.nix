# LLM fleet telemetry import and outlook publish units (cloudbox).
# Design: docs/plans/2026-11-23-llm-spend-metrics-design.md
#
# Runs alongside llm-ledger.nix:
#   * llm-fleet-import: fetches telemetry from git@github.com:johnnymo87/quota-telemetry.git
#     (branch main) and imports rows into /var/lib/llm-ledger/ledger.db via
#     `llm-ledger import-remote`.
#   * llm-outlook-publish: triggered by OnSuccess of llm-quota-watch.service, builds
#     a single parentless commit on branch 'outlook' with the latest outlook JSON
#     and pushes to git@github.com:johnnymo87/quota-telemetry.git.
{ config, pkgs, lib, ... }:

let
  llmLedger = pkgs.callPackage ../../pkgs/llm-ledger { };
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };

  commonEnv = [
    "HOME=/home/dev"
    "\"GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15\""
  ];
  commonPath = [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.jq llmLedger ];

  fleetImportScript = pkgs.writeShellScript "llm-fleet-import" ''
    set -euo pipefail

    TELEMETRY_DIR="/var/lib/llm-fleet/telemetry"
    REMOTE="git@github.com:johnnymo87/quota-telemetry.git"
    HOST="cloudbox"
    DB_PATH=""

    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"

    if [ ! -d "$TELEMETRY_DIR/.git" ]; then
      if [ -d "$TELEMETRY_DIR" ] && [ -n "$(ls -A "$TELEMETRY_DIR" 2>/dev/null)" ]; then
        rm -rf "$TELEMETRY_DIR"
      fi
      git clone --quiet --single-branch --branch main "$REMOTE" "$TELEMETRY_DIR"
    else
      timeout 90 git -C "$TELEMETRY_DIR" fetch --quiet origin main && git -C "$TELEMETRY_DIR" reset --quiet --hard origin/main
    fi

    if [ -n "$DB_PATH" ]; then
      llm-ledger import-remote --repo "$TELEMETRY_DIR" --host "$HOST" --db "$DB_PATH"
    else
      llm-ledger import-remote --repo "$TELEMETRY_DIR" --host "$HOST"
    fi
  '';

  outlookPublishScript = pkgs.writeShellScript "llm-outlook-publish" ''
    set -euo pipefail

    OUTLOOK_DIR="/var/lib/llm-fleet/outlook"
    REMOTE="git@github.com:johnnymo87/quota-telemetry.git"
    MARKER_FILE="/var/lib/llm-fleet/outlook-pushed"
    HOST="cloudbox"
    DB_PATH=""

    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"

    if [ ! -d "$OUTLOOK_DIR/.git" ]; then
      mkdir -p "$OUTLOOK_DIR"
      cd "$OUTLOOK_DIR"
      git init -q -b outlook
      git remote add origin "$REMOTE"
    else
      cd "$OUTLOOK_DIR"
    fi

    if [ -n "$DB_PATH" ]; then
      llm-ledger outlook-publish-json --host "$HOST" --db "$DB_PATH" > outlook.json.tmp && mv -f outlook.json.tmp outlook.json
    else
      llm-ledger outlook-publish-json --host "$HOST" > outlook.json.tmp && mv -f outlook.json.tmp outlook.json
    fi

    tree=$(git add outlook.json && git write-tree)
    pub_at=$(jq -r '.published_at // empty' outlook.json 2>/dev/null || true)
    if [ -z "$pub_at" ]; then
      pub_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    commit=$(git commit-tree "$tree" -m "outlook $pub_at")
    git update-ref refs/heads/outlook "$commit"

    pushed=0
    for try in 1 2 3; do
      if timeout 30 git push -q -f origin refs/heads/outlook:refs/heads/outlook; then
        pushed=1
        break
      fi
      echo "llm-outlook-publish: git push attempt $try failed" >&2
      if [ "$try" -lt 3 ]; then
        sleep 5
      fi
    done

    if [ "$pushed" -eq 1 ]; then
      mkdir -p "$(dirname "$MARKER_FILE")"
      touch "$MARKER_FILE"
    else
      echo "llm-outlook-publish: ERROR: all 3 git push attempts failed to origin refs/heads/outlook" >&2
    fi

    git reflog expire --expire=now --all && git gc --prune=now -q || true

    exit 0
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/llm-fleet 0750 dev dev -"
    "d /var/lib/llm-fleet/telemetry 0750 dev dev -"
    "d /var/lib/llm-fleet/outlook 0750 dev dev -"
  ];

  systemd.services.llm-fleet-import = {
    description = "Import remote LLM telemetry into spend ledger";
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      OnFailure = [ "llm-fleet-import-failure.service" ];
    };
    path = commonPath;
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      SupplementaryGroups = [ "llm-ledger" ];
      UMask = "0027";
      Nice = 10;
      TimeoutStartSec = "5min";
      MemoryMax = "512M";
      ExecStart = "${fleetImportScript}";
      ExecStartPost = "${pkgs.coreutils}/bin/rm -f /var/lib/llm-fleet-import-failure/alerted";
      Environment = commonEnv;
      NoNewPrivileges = true;
      ProtectSystem = "full";
    };
  };

  systemd.timers.llm-fleet-import = {
    description = "Timer for LLM fleet telemetry import";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:14/15";
      AccuracySec = "30s";
      Persistent = true;
    };
  };

  systemd.services.llm-fleet-import-failure = {
    description = "Alert that the LLM fleet telemetry import failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "llm-fleet-import-failure";
      TimeoutStartSec = 60;
      ExecStart = "${pkgs.writeShellScript "llm-fleet-import-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.systemd ]}
        RESULT="$(systemctl show llm-fleet-import -p Result --value 2>/dev/null || true)"
        [ -n "$RESULT" ] || RESULT=unknown
        ${driftAlert} /var/lib/llm-fleet-import-failure/alerted \
          "llm-fleet-import:$RESULT" \
          "LLM fleet telemetry import FAILED (result: $RESULT).

llm-fleet-import.service did not complete, so telemetry from remote hosts is
not being imported into /var/lib/llm-ledger/ledger.db.

Check:
  systemctl status llm-fleet-import.service --no-pager
  journalctl -u llm-fleet-import.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };

  systemd.services.llm-outlook-publish = {
    description = "Publish quota outlook to fleet telemetry repo";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = commonPath;
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      SupplementaryGroups = [ "llm-ledger" ];
      UMask = "0027";
      Nice = 10;
      TimeoutStartSec = "3min";
      MemoryMax = "256M";
      ExecStart = "${outlookPublishScript}";
      Environment = commonEnv;
      NoNewPrivileges = true;
      ProtectSystem = "full";
    };
  };
}
