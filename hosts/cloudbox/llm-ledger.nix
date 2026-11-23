# LLM spend ledger service and timer (bead workstation-4si2.1).
# Design: docs/plans/2026-11-23-llm-spend-metrics-design.md
#
# Schema uses DELETE journal mode (not WAL) and directory permissions 2750
# dev:llm-ledger with umask 0027 (giving 0640 files) because Grafana runs with
# ProtectHome=true and the read-only frser-sqlite-datasource reader needs
# access without write capability.
{ config, pkgs, lib, ... }:

let
  llmLedger = pkgs.callPackage ../../pkgs/llm-ledger { };
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/llm-ledger 2750 dev llm-ledger -"
    "d /var/lib/llm-ledger/raw 2750 dev llm-ledger -"
  ];

  # Phase 1 appends quota-watch to this unit after the writer
  # (design: one timer, writer -> snapshot -> quota-watch).
  systemd.services.llm-ledger = {
    description = "Maintain LLM spend ledger database and raw archive";
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig = {
      OnFailure = [ "llm-ledger-failure.service" ];
    };
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      SupplementaryGroups = [ "llm-ledger" ];
      UMask = "0027";
      MemoryMax = "1G";
      Nice = 10;
      TimeoutStartSec = "15min";
      ExecStart = "${llmLedger}/bin/llm-ledger run";
      Environment = [ "HOME=/home/dev" ];
    };
  };

  systemd.timers.llm-ledger = {
    description = "Timer for LLM spend ledger writer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:2/5";
      AccuracySec = "30s";
      Persistent = true;
    };
  };

  systemd.services.llm-ledger-failure = {
    description = "Alert that the LLM spend ledger writer failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "llm-ledger-failure";
      TimeoutStartSec = 60;
      ExecStart = "${pkgs.writeShellScript "llm-ledger-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq ]}
        ${driftAlert} /var/lib/llm-ledger-failure/alerted \
          "llm-ledger:failed" \
          "LLM spend ledger writer FAILED TO RUN.

llm-ledger.service exited non-zero. Data is not lost while cfp retains
events for 30 days, but the ledger is going stale.

Check:
  systemctl status llm-ledger.service --no-pager
  journalctl -u llm-ledger.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };
}
