# Reconciler for devbox runner failover.
# Removes the em-ci label from devbox runners while gamebox runners are online,
# and restores it when gamebox runners are offline (with hysteresis).
# Design: docs/plans/2026-10-11-em-ci-gamebox-design.md, "Failover reconciler".
{ config, lib, pkgs, ... }:

let
  failover = pkgs.writeShellApplication {
    name = "em-ci-failover";
    runtimeInputs = with pkgs; [ coreutils curl jq ];
    text = builtins.readFile ./em-ci-failover.sh;
  };
in
{
  systemd.services.em-ci-failover = {
    description = "em-ci: gate devbox runners' em-ci label on gamebox's runners";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      EM_CI_REPO = "johnnymo87/eternal-machinery";
      EM_CI_PRIMARY_PREFIX = "gamebox-";
      EM_CI_FALLBACK_RUNNERS = "devbox-em-ci-1 devbox-em-ci-2";
      EM_CI_LABEL = "em-ci";
      EM_CI_TICKS = "3";
      EM_CI_ERROR_ALERT = "10";
      EM_CI_PRIMARY_OFFLINE_ALERT_H = "9";   # above the 8 h streaming-pause ceiling (RuntimeMaxSec)
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe failover;
      TimeoutStartSec = "5min";   # 1 GET + 2 writes, each up to 30 s x 3 attempts
      DynamicUser = true;
      StateDirectory = "em-ci-failover";
      LoadCredential = [
        # Administration: write is needed for label edits; the monitor's token is read-only.
        "gh_token:${config.sops.secrets.em_ci_runner_pat.path}"
        "tg_bot_token:${config.sops.secrets.telegram_bot_token.path}"
        "tg_chat_id:${config.sops.secrets.telegram_chat_id.path}"
      ];
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

  systemd.timers.em-ci-failover = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "1min";
      AccuracySec = "5s";
    };
  };
}
