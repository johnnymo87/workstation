# LLM spend ledger service and timer (bead workstation-4si2.1).
# Design: docs/plans/2026-11-23-llm-spend-metrics-design.md
#
# The writer runs as dev (it reads opencode/goose/tags DBs under ~/.local);
# the readers (Grafana, phase 2) join group llm-ledger. Two constraints from the
# design's "Implementation constraints" section shape this file:
#   * The DB lives under /var/lib, not ~, because the grafana unit runs with
#     ProtectHome=true. The dir is setgid 2750 dev:llm-ledger and the writer's
#     UMask is 0027, so ledger.db, its transient -journal, .lock and raw/*.gz
#     come out dev:llm-ledger 0640.
#   * The writer uses journal_mode=DELETE, not WAL: the frser plugin opens a
#     read-only connection per query, and once the writer has exited a WAL DB
#     has no -shm that a read-only reader could recreate.
{ config, pkgs, lib, ... }:

let
  llmLedger = pkgs.callPackage ../../pkgs/llm-ledger { };
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
in
{
  # Grafana joins this group in phase 2 (workstation-4si2.3).
  users.groups.llm-ledger = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/llm-ledger 2750 dev llm-ledger -"
    "d /var/lib/llm-ledger/raw 2750 dev llm-ledger -"
  ];

  # One timer, writer -> snapshot -> quota-watch (design "Ordering"): a oneshot
  # runs its ExecStart lines in order and stops at the first failure, so
  # quota-watch always sees the rows the writer just committed. quota-watch
  # (bead workstation-4si2.2, docs/plans/2026-11-23-quota-watch-p1-plan.md)
  # opens the ledger read-only and keeps its alert state in StateDirectory.
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
      ExecStart = [
        "${llmLedger}/bin/llm-ledger run"
        "${llmLedger}/bin/llm-ledger quota-watch --state-dir /var/lib/llm-quota-watch --alert-cmd ${driftAlert}"
      ];
      StateDirectory = "llm-quota-watch";
      StateDirectoryMode = "0700";
      # On success, clear the failure alert's backoff state so a later failure pages afresh.
      ExecStartPost = "${pkgs.coreutils}/bin/rm -f /var/lib/llm-ledger-failure/alerted";
      Environment = [ "HOME=/home/dev" ];
      # Light hardening only. ProtectSystem=strict / ProtectHome would make
      # /home read-only, and a read-only connection to the WAL-mode opencode,
      # goose and tags DBs still needs to write their -shm.
      NoNewPrivileges = true;
      ProtectSystem = "full";
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
    description = "Alert that the LLM spend ledger writer or quota-watch failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "llm-ledger-failure";
      TimeoutStartSec = 60;
      ExecStart = "${pkgs.writeShellScript "llm-ledger-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.systemd ]}
        # The Result goes into the signature so a change of failure mode
        # (exit-code -> timeout -> oom-kill) pages afresh instead of riding
        # the previous episode's backoff.
        RESULT="$(systemctl show llm-ledger -p Result --value 2>/dev/null || true)"
        [ -n "$RESULT" ] || RESULT=unknown
        ${driftAlert} /var/lib/llm-ledger-failure/alerted \
          "llm-ledger:$RESULT" \
          "LLM spend ledger FAILED (result: $RESULT).

llm-ledger.service did not complete. It runs the ledger writer, then
quota-watch (Max pool shortfall / pool-dry alerts); the journal says which.
If the writer failed, /var/lib/llm-ledger/ledger.db is going stale. Nothing is
lost yet: the writer resumes from its saved offset, and cfp keeps 30 days of
events. Past 30 days of failure, events are lost for good. If quota-watch
failed, no Max quota alerts are being sent until it is fixed.

Check:
  systemctl status llm-ledger.service --no-pager
  journalctl -u llm-ledger.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };
}
