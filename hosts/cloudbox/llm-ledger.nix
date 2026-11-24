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
  # Grafana joins this group via ./grafana.nix (workstation-4si2.3).
  users.groups.llm-ledger = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/llm-ledger 2750 dev llm-ledger -"
    "d /var/lib/llm-ledger/raw 2750 dev llm-ledger -"
  ];

  # One timer, writer -> snapshot -> quota-watch (design "Ordering"). quota-watch
  # is its own unit, started by OnSuccess= only after a writer run succeeds, so
  # it always sees the rows the writer just committed, and the two fail (and
  # page) separately: a quota-watch bug must not ride the writer's alert
  # backoff and hide a "ledger going stale" page.
  systemd.services.llm-ledger = {
    description = "Maintain LLM spend ledger database and raw archive";
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig = {
      OnFailure = [ "llm-ledger-failure.service" ];
      OnSuccess = [ "llm-quota-watch.service" ];
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
      # The gateway step copies aigateway's Gemini rows (Vertex Gemini goes
      # through it, not cfp) and the run then writes the GCP-commitment spend
      # feed that the model-switch controller's daily Neon cap reads (bead
      # eng-agent-platform-ul4.28.4). dev is in group docker. The step never
      # fails this unit (which gates quota-watch and pages as "cfp ledger
      # stale"); it records its status, the feed says complete=false, and
      # quota-watch pages gemini-feed-stale after 30 min of errors.
      ExecStart = lib.concatStringsSep " " [
        "${llmLedger}/bin/llm-ledger run"
        "--teamclaude-log /home/dev/.local/state/teamclaude/usage.jsonl"
        "--gateway-psql '${config.virtualisation.docker.package}/bin/docker exec -i dev-postgres-1 psql -U aigateway -d aigateway'"
        "--gateway-flag ${import ./aigateway-flag.nix}"
        "--commitment-json /var/lib/llm-ledger/commitment-spend.json"
      ];
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
    description = "Alert that the LLM spend ledger writer failed";
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
          "LLM spend ledger writer FAILED (result: $RESULT).

llm-ledger.service did not complete, so /var/lib/llm-ledger/ledger.db is going
stale. Nothing is lost yet: the writer resumes from its saved offset, and cfp
keeps 30 days of events. Past 30 days of failure, events are lost for good.

Check:
  systemctl status llm-ledger.service --no-pager
  journalctl -u llm-ledger.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };

  # quota-watch: Max pool shortfall / pool-dry / account-high / blind-input alerts
  # (bead workstation-4si2.2, docs/plans/2026-11-23-quota-watch-p1-plan.md).
  # Reads the ledger read-only (group llm-ledger); alert state lives in its own
  # StateDirectory, which the Grafana group cannot read.
  systemd.services.llm-quota-watch = {
    description = "Alert on Claude Max pool shortfall from the LLM spend ledger";
    unitConfig = {
      OnFailure = [ "llm-quota-watch-failure.service" ];
      OnSuccess = [ "llm-outlook-publish.service" ];
    };
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      SupplementaryGroups = [ "llm-ledger" ];
      # SQLite gives the journal the DB file's mode (0640 dev:llm-ledger);
      # UMask 0027 is defence in depth, not what makes it 0640.
      # StateDirectoryMode 0700 still keeps its own state private.
      UMask = "0027";
      MemoryMax = "512M";
      Nice = 10;
      TimeoutStartSec = "5min";
      StateDirectory = "llm-quota-watch";
      StateDirectoryMode = "0700";
      ExecStart = "${llmLedger}/bin/llm-ledger quota-watch --state-dir /var/lib/llm-quota-watch --alert-cmd ${driftAlert} --outlook-pushed-file /var/lib/llm-fleet/outlook-pushed --alert-stale-hosts devbox";
      ExecStartPost = "${pkgs.coreutils}/bin/rm -f /var/lib/llm-quota-watch-failure/alerted";
      Environment = [ "HOME=/home/dev" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      # Load-bearing: SQLite spills GROUP BY sorts to a temp file in /var/tmp or
      # /tmp, which ProtectSystem=strict makes read-only ("disk I/O error" on
      # the first aggregate query, reproduced with systemd-run).
      PrivateTmp = true;
      ReadWritePaths = [
        "/var/lib/llm-quota-watch"
        # DELETE journal needs parent dir writable to create/remove ledger.db-journal
        "/var/lib/llm-ledger"
      ];
    };
  };

  systemd.services.llm-quota-watch-failure = {
    description = "Alert that quota-watch failed";
    serviceConfig = {
      Type = "oneshot";
      User = "dev";
      Group = "dev";
      StateDirectory = "llm-quota-watch-failure";
      TimeoutStartSec = 60;
      ExecStart = "${pkgs.writeShellScript "llm-quota-watch-failure" ''
        set -u
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.systemd ]}
        RESULT="$(systemctl show llm-quota-watch -p Result --value 2>/dev/null || true)"
        [ -n "$RESULT" ] || RESULT=unknown
        ${driftAlert} /var/lib/llm-quota-watch-failure/alerted \
          "llm-quota-watch:$RESULT" \
          "quota-watch FAILED (result: $RESULT).

No Claude Max pool alerts (shortfall, pool dry, account high, blind inputs)
are being sent until it is fixed. The ledger writer is separate and unaffected.

Check:
  systemctl status llm-quota-watch.service --no-pager
  journalctl -u llm-quota-watch.service -n 50 --no-pager" \
          3600 21600
      ''}";
    };
  };
}
