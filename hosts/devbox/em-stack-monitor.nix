# Telegram alerts for the running Eternal Machinery stack, if one is running.
#
# Every 10 minutes a hardened oneshot (as dev: stack-health lives in /home/dev,
# uses per-user pgrep and /run/user/1000, and reads postgres through the
# dev-owned binary) looks at the stack:
#   - the gate: a BEAM serving 127.0.0.1:4002. No BEAM = no stack = quiet (one
#     "stopped, no longer watching" line if problems had been announced);
#   - bin/stack-health in the main checkout: any FAIL/DOWN/DEAD_MANAGER line,
#     or the monitor being blind (no SUMMARY, UNKNOWN lines);
#   - GET :4002/v1/presence: the server closed a link nobody asked to close;
#   - GET :4002/v1/sessions/<sid>/status: a GM halt unanswered for 20+ min;
#   - GET :4400/em/quiescence: a quarantined agent, and one-off events
#     (child_restart_failed, flapping recoveries).
# Problems go to the Telegram forum group's General topic through pigeon's bot
# (no message_thread_id), one message per pass. A standing problem set is
# announced once, repeated every 6 h, and followed by "resolved" when it clears;
# most keys must be seen on 2 passes in a row before they alert.
#
# Secrets: Telegram's are pigeon's (telegram_bot_token, telegram_chat_id), read
# via LoadCredential. The dead-man's ping is off (hcEnabled below): when on, it
# adds sops secret em_stack_hc_ping_url (root 0400, a healthchecks.io ping URL;
# suggested check: period 10 m, grace 20 m). The script pings only when the
# credential exists, with em-ci-monitor's contract (em-stack-monitor.sh).
#
# Run a pass now:  sudo systemctl start em-stack-monitor; journalctl -u em-stack-monitor -n 30
# Dry run (prints the raw key set before debounce and the message it would
# send; sends, pings and records nothing):
#   sudo systemctl start em-stack-monitor-dry-run; journalctl -u em-stack-monitor-dry-run -n 30
# On a healthy stack the raw key set must be empty (no monitor:blind).
#
# Spec: docs/plans/2026-11-04-em-stack-monitor.md. EM bead eternal-machinery-qpmfc.103.1
# (prerequisite: eternal-machinery #1173, stack-health grades 503 session_not_found WARN).
{ config, lib, pkgs, ... }:

let
  # Flip to true once the healthchecks.io check exists and its ping URL is in
  # devbox sops as em_stack_hc_ping_url.
  hcEnabled = false;

  repo = "/home/dev/projects/eternal-machinery";
  uid = toString config.users.users.dev.uid;

  monitor = pkgs.writeShellApplication {
    name = "em-stack-monitor";
    # What bin/stack-health needs besides the script's own tools: without
    # python3 every API check reads UNKNOWN, without procps the manager check
    # reads OK blind.
    # bash too: bin/stack-health starts with `#!/usr/bin/env bash`, and a system
    # unit's PATH has none (the first live pass read monitor:blind for that).
    runtimeInputs = with pkgs; [
      bash coreutils curl jq gnused gnugrep gawk findutils procps iproute2 python3 git
    ];
    text = builtins.readFile ./em-stack-monitor.sh;
  };

  unit = extraEnv: {
    description = "EM stack monitor (Telegram alerts)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      EM_STACK_REPO = repo;
      EM_STACK_RUNBOOK = "eternal-machinery docs/runbooks/stack-health.md";
      EM_STACK_REMIND_H = "6";
      EM_STACK_GM_MIN = "20";
      XDG_RUNTIME_DIR = "/run/user/${uid}";
    } // extraEnv;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe monitor;
      # Worst case: stack-health 200 s (its own timeout) + four 10 s fetches +
      # Telegram (3 retries of 20 s plus backoff, ~90 s) + a /fail ping
      # (~45 s) is about 6.5 min, so 8 min; the timeout inside the script stays.
      TimeoutStartSec = "8min";
      User = "dev";
      Group = config.users.users.dev.group;
      # systemd creates /var/lib/em-stack-monitor and chowns it to User=.
      StateDirectory = "em-stack-monitor";
      LoadCredential = [
        "tg_bot_token:${config.sops.secrets.telegram_bot_token.path}"
        "tg_chat_id:${config.sops.secrets.telegram_chat_id.path}"
      ] ++ lib.optional hcEnabled "hc_ping_url:${config.sops.secrets.em_stack_hc_ping_url.path}";
      # Light by nature: this runs dev-writable code as dev. No PrivateTmp
      # (stack-health scans /tmp/devenv-* and writes mktemp files there) and no
      # PrivateNetwork (localhost and api.telegram.org). ProtectHome=read-only,
      # not tmpfs: the script and the checkout must stay readable.
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      # strict makes /tmp read-only; stack-health's mktemp needs it.
      ReadWritePaths = [ "/tmp" ];
      NoNewPrivileges = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      SystemCallArchitectures = "native";
    };
  };
in
{
  sops.secrets = lib.optionalAttrs hcEnabled {
    em_stack_hc_ping_url = { owner = "root"; group = "root"; mode = "0400"; };
  };

  systemd.services.em-stack-monitor = unit { };

  # Same pass with EM_STACK_MONITOR_DRY_RUN=1; no timer, started by hand only.
  systemd.services.em-stack-monitor-dry-run = unit { EM_STACK_MONITOR_DRY_RUN = "1"; };

  systemd.timers.em-stack-monitor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
      RandomizedDelaySec = "30s";
    };
  };
}
