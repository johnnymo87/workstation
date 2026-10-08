# Monitoring for the em-ci runner containers (em-ci.nix).
#
# Every 10 minutes a hardened oneshot checks, for johnnymo87/eternal-machinery:
#   - both runners online (GitHub's view);
#   - no em-ci job queued 20+ min while a runner is idle, or 120+ min at all;
#   - no em-ci job failed in ./.github/ci/setup in the last 20 min (runner
#     dirty, a disk admission floor, or devenv failing to evaluate);
#   - both containers active, and the disk watchdog not in a failed state;
#   - root disk >= 20 GB free, the em-ci Volume >= 8 GB free (jobs refuse to
#     start below 5 GB, so this warns first).
# Problems go to the Telegram forum group's General topic through pigeon's bot
# (no message_thread_id). A standing problem is announced once, repeated every
# 6 h, and followed by a "resolved" message when it clears.
#
# Dead-man's switch: each pass pings a healthchecks.io check (period 10 m,
# grace 20 m) whose own Telegram integration posts to the same group. The check
# measures the MONITOR, not runner health: a pass that observed everything and
# delivered its alerts pings success; one that could not deliver, or exited
# non-zero, pings /fail; one that never ran pings nothing. So devbox being
# down, the monitor dying, and Telegram delivery breaking all reach the human;
# em-ci-monitor.sh has the exact contract.
#
# Secrets (devbox sops, root 0400): em_ci_monitor_gh_token (fine-grained,
# eternal-machinery only, Actions: read + Administration: read) and
# em_ci_hc_ping_url. Telegram secrets are pigeon's, read via LoadCredential.
#
# Run a pass now:  sudo systemctl start em-ci-monitor; journalctl -u em-ci-monitor -n 30
# Dry run (prints what it would send; sends, pings and records nothing):
#   sudo systemctl start em-ci-monitor-dry-run; journalctl -u em-ci-monitor-dry-run -n 30
#
# Spec: eternal-machinery docs/plans/2026-10-07-ci-self-hosted-plan.md, PR-2,
# "Monitoring that survives the loss of devbox". Bead eternal-machinery-0oycj.5.
{ config, lib, pkgs, ... }:

let
  runbook = "eternal-machinery docs/runbooks/ci-self-hosted.md";
  containers = [ "em-ci-1" "em-ci-2" ];

  monitor = pkgs.writeShellApplication {
    name = "em-ci-monitor";
    runtimeInputs = with pkgs; [ coreutils curl jq gnused systemd ];
    text = builtins.readFile ./em-ci-monitor.sh;
  };

  unit = extraEnv: {
    description = "em-ci runner monitor (Telegram alerts + healthchecks.io heartbeat)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      EM_CI_REPO = "johnnymo87/eternal-machinery";
      EM_CI_RUNNERS = lib.concatMapStringsSep " " (c: "devbox-${c}") containers;
      EM_CI_CONTAINERS = lib.concatStringsSep " " containers;
      EM_CI_LABEL = "em-ci";
      EM_CI_QUEUE_MAX_MIN = "20";
      EM_CI_SETUP_WINDOW_MIN = "20";
      EM_CI_BACKLOG_MAX_MIN = "120";
      EM_CI_ROOT_MIN_GB = "20";
      EM_CI_VOLUME = "/var/lib/nixos-containers";
      EM_CI_VOLUME_MIN_GB = "8";
      EM_CI_REMIND_H = "6";
      EM_CI_RUNBOOK = runbook;
    } // extraEnv;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe monitor;
      TimeoutStartSec = "5min";
      DynamicUser = true;
      StateDirectory = "em-ci-monitor";
      LoadCredential = [
        "gh_token:${config.sops.secrets.em_ci_monitor_gh_token.path}"
        "hc_ping_url:${config.sops.secrets.em_ci_hc_ping_url.path}"
        "tg_bot_token:${config.sops.secrets.telegram_bot_token.path}"
        "tg_chat_id:${config.sops.secrets.telegram_chat_id.path}"
      ];
      # Read-only checks plus outbound HTTPS; nothing else.
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      SystemCallArchitectures = "native";
    };
  };

  secret = {
    owner = "root";
    group = "root";
    mode = "0400";
  };
in
{
  sops.secrets.em_ci_monitor_gh_token = secret;
  sops.secrets.em_ci_hc_ping_url = secret;

  systemd.services.em-ci-monitor = unit { };

  # Same pass with EM_CI_MONITOR_DRY_RUN=1; no timer, started by hand only.
  systemd.services.em-ci-monitor-dry-run = unit { EM_CI_MONITOR_DRY_RUN = "1"; };

  systemd.timers.em-ci-monitor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
      RandomizedDelaySec = "30s";
    };
  };
}
