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
  commonPath = [ pkgs.git pkgs.openssh pkgs.coreutils pkgs.findutils pkgs.python3 llmLedger ];

  fleetImportScript = pkgs.writeShellScript "llm-fleet-import" ''
    set -euo pipefail

    TELEMETRY_DIR="/var/lib/llm-fleet/telemetry"
    REMOTE="git@github.com:johnnymo87/quota-telemetry.git"
    HOST="cloudbox"
    DB_PATH=""

    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"

    if [ ! -d "$TELEMETRY_DIR/.git" ]; then
      if [ -d "$TELEMETRY_DIR" ]; then
        find "$TELEMETRY_DIR" -mindepth 1 -delete
      fi
      git clone --quiet --single-branch --branch main "$REMOTE" "$TELEMETRY_DIR"
    else
      # With an existing clone, a failed or timed-out fetch warns to stderr and
      # proceeds to import-remote from the existing checkout. Only reset if the
      # fetch succeeded. Persistent staleness is caught by quota-watch fleet-stale (>3h).
      if timeout 90 git -C "$TELEMETRY_DIR" fetch --quiet origin main; then
        git -C "$TELEMETRY_DIR" reset --quiet --hard origin/main
      else
        echo "llm-fleet-import: warning: git fetch failed; continuing with existing clone" >&2
      fi
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
    pub_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

  modelSwitchPublishScript = pkgs.writeShellScript "model-switch-publish" ''
    set -euo pipefail

    PUBLISH_DIR="/var/lib/llm-fleet/model-switch"
    REMOTE="git@github.com:johnnymo87/quota-telemetry.git"
    BRANCH="model-switch"
    REPO_DIR="/home/dev/projects/eng-agent-platform"
    FEED="/var/lib/llm-ledger/commitment-spend.json"

    export HOME="/home/dev"
    export PYTHONPATH="$REPO_DIR"
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"

    if [ ! -f "$HOME/.local/state/model-switch/state.json" ]; then
      echo "model-switch-publish: no state.json yet; skipping" >&2
      exit 0
    fi

    if [ ! -d "$PUBLISH_DIR/.git" ]; then
      mkdir -p "$PUBLISH_DIR"
      cd "$PUBLISH_DIR"
      git init -q -b "$BRANCH"
      git remote add origin "$REMOTE"
    else
      cd "$PUBLISH_DIR"
    fi

    python3 -m stallwatch.modelswitch export-fleet --feed "$FEED" --leader cloudbox > fleet-state.json.tmp
    mv -f fleet-state.json.tmp fleet-state.json

    tree=$(git add fleet-state.json && git write-tree)
    pub_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    commit=$(git commit-tree "$tree" -m "model-switch $pub_at")
    git update-ref "refs/heads/$BRANCH" "$commit"

    pushed=0
    for try in 1 2 3; do
      if timeout 30 git push -q -f origin "refs/heads/$BRANCH:refs/heads/$BRANCH"; then
        pushed=1
        break
      fi
      echo "model-switch-publish: git push attempt $try failed" >&2
      if [ "$try" -lt 3 ]; then
        sleep 5
      fi
    done

    if [ "$pushed" -ne 1 ]; then
      echo "model-switch-publish: ERROR: all 3 git push attempts failed to origin refs/heads/$BRANCH" >&2
      exit 1
    fi

    git reflog expire --expire=now --all && git gc --prune=now -q || true
  '';
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/llm-fleet 0750 dev dev -"
    "d /var/lib/llm-fleet/telemetry 0750 dev dev -"
    "d /var/lib/llm-fleet/outlook 0750 dev dev -"
    "d /var/lib/llm-fleet/model-switch 0750 dev dev -"
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
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
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

  systemd.services.model-switch-publish = {
    description = "Publish fleet model-switch state to quota-telemetry (branch model-switch)";
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      OnFailure = [ "model-switch-publish-failure.service" ];
    };
    path = commonPath;
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      SupplementaryGroups = [ "llm-ledger" ];
      UMask = "0027";
      Nice = 10;
      TimeoutStartSec = "2min";
      MemoryMax = "256M";
      ExecStart = "${modelSwitchPublishScript}";
      ExecStartPost = "${pkgs.coreutils}/bin/rm -f /var/lib/model-switch-publish-failure/alerted";
      Environment = commonEnv;
      NoNewPrivileges = true;
      ProtectSystem = "full";
    };
  };

  systemd.services.model-switch-publish-failure = {
    description = "Alert that fleet model-switch publish failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "model-switch-publish-failure";
      TimeoutStartSec = 60;
      ExecStart = "${pkgs.writeShellScript "model-switch-publish-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.systemd ]}
        RESULT="$(systemctl show model-switch-publish -p Result --value 2>/dev/null || true)"
        [ -n "$RESULT" ] || RESULT=unknown
        ${driftAlert} /var/lib/model-switch-publish-failure/alerted \
          "model-switch-publish:$RESULT" \
          "Fleet model-switch publish FAILED (result: $RESULT).

model-switch-publish.service did not complete, so Mac follower state on
quota-telemetry branch model-switch is going stale (Mac fails closed to Opus
after 20 minutes).

Check:
  systemctl status model-switch-publish.service --no-pager
  journalctl -u model-switch-publish.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };

  systemd.timers.model-switch-publish = {
    description = "Publish fleet model-switch state every 2 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/2";
      AccuracySec = "15s";
      Persistent = true;
    };
  };
}
