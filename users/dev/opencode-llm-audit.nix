# Durable OpenCode LLM-call audit logger (cloudbox)
#
# WHY: opencode writes a per-process log to
# ~/.local/share/opencode/log/<ISO>.log. The Log module (packages/core/src/
# util/log.ts) keeps only the newest 10 files (`const keep = 10`) and runs
# cleanup() on EVERY process start (every TUI attach). On a busy box the
# long-lived opencode-serve process's own log file (the oldest) gets
# fs.unlink()'d out from under it while the serve keeps writing to the now
# *deleted* inode via its still-open fd. So the attribution lines we care
# about (service=llm ...) live in a file that no longer appears in the
# directory and vanishes entirely when serve restarts. A naive
# `tail -F newest *.log` therefore captures only short-lived TUI client logs
# (which contain no service=llm lines) -- it MISSES the serve log completely.
#
# WHAT THIS DOES: a tiny always-on supervisor that locates the running
# `opencode serve` process, finds the fd it has open on its log file (even if
# deleted), and `tail`s that fd -- piping matching lines to a kept file under
# ~/.local/state (outside the disk-cleanup / nightly-restart scope). When
# serve restarts, `tail --pid=<serve>` self-terminates and the supervisor
# re-attaches to the new serve. Captured signals:
#   - attribution: `service=llm ... providerID= modelID= session.id=ses_...
#                   small= agent= mode= stream`  (llm.ts:90)
#   - errors/quota: the `service=llm ... stream error` line (llm.ts:274) carries
#                   the raw provider error text (RESOURCE_EXHAUSTED, 429, quota)
#     plus extra provider/gRPC error tokens for lines that lack service=llm.
#
# NOTE ON THE RETRY STORM: opencode-level retries (processor.ts:810
# Effect.retry(SessionRetry.policy)) re-invoke llm.stream, so each retry
# re-emits a service=llm line -- visible here. The deeper ~16-48x SDK/gateway
# retries that inflated the surge to ~97k live BELOW opencode's logging and are
# not capturable from opencode logs (they'd need Vertex/gateway-side metrics).
#
# Mirrors the disk-cleanup.nix idiom: inline script via home.file + a
# systemd --user service/timer. User-level (linger is enabled on cloudbox) so
# it applies with `home-manager switch` -- no system rebuild.
{ config, pkgs, lib, isCloudbox, ... }:

let
  stateDir = "${config.home.homeDirectory}/.local/state/opencode-llm-audit";
  outFile = "${stateDir}/llm.log";
  logDir = "${config.home.homeDirectory}/.local/share/opencode/log";
  logrotateConf = "${config.home.homeDirectory}/.config/opencode-llm-audit/logrotate.conf";
  logrotateState = "${stateDir}/logrotate.state";
in
lib.mkIf isCloudbox {
  # --- The follower/supervisor script ---
  home.file.".local/bin/opencode-llm-audit" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      # Follow the opencode-serve process's open log fd and append attributable
      # LLM + provider-error lines to a durable file. See opencode-llm-audit.nix
      # for the full rationale. Deliberately NOT `set -e`: the supervisor loop
      # must survive transient failures (serve restarts, races).
      set -uo pipefail

      PATH="${lib.makeBinPath [
        pkgs.coreutils   # tail, stdbuf, readlink, date, sleep, mkdir, head
        pkgs.gnugrep     # grep
        pkgs.procps      # pgrep
      ]}:$PATH"

      LOGDIR="${logDir}"
      OUT="${outFile}"
      POLL_INTERVAL=5

      # Attribution + provider error/quota signals. Intentionally does NOT match
      # the bare word "retry" -- that floods the file with benign TUI plugin
      # lines like `service=tui.plugin ... retry=false`. The opencode-level
      # retry storm is already visible via repeated service=llm lines.
      PATTERN='service=llm|RESOURCE_EXHAUSTED|DEADLINE_EXCEEDED|UNAVAILABLE|status=429|statusCode=429|Too Many Requests|too_many_requests|Rate Limited|RateLimit|rate limit|Provider is overloaded|Overloaded|insufficient_quota|quota_exceeded|Quota exceeded|AbortError'

      mkdir -p "$(dirname "$OUT")"

      meta() { printf '[opencode-llm-audit] %s %s\n' "$(date -Is)" "$*" >&2; }

      # Echo the /proc/<pid>/fd/<n> path that points at an opencode log file
      # (matches both live `.../X.log` and unlinked `.../X.log (deleted)`).
      find_log_fd() {
        local pid="$1" fd target
        for fd in /proc/"$pid"/fd/*; do
          target="$(readlink "$fd" 2>/dev/null)" || continue
          case "$target" in
            "$LOGDIR"/*.log*) printf '%s\n' "$fd"; return 0 ;;
          esac
        done
        return 1
      }

      serve_pid=""
      follower_pid=""

      meta "starting; LOGDIR=$LOGDIR OUT=$OUT"

      while :; do
        # If our follower died (serve restarted -> tail --pid exits, grep EOFs),
        # forget it so we re-attach below.
        if [ -n "$follower_pid" ] && ! kill -0 "$follower_pid" 2>/dev/null; then
          meta "follower for serve=$serve_pid exited; will re-attach"
          follower_pid=""
          serve_pid=""
        fi

        if [ -z "$follower_pid" ]; then
          # Find the opencode serve process that actually holds an open log fd.
          # (Validates via find_log_fd so the startup wrapper / TUI clients are
          # ignored.) Picks the first matching one.
          fd=""
          spid=""
          while read -r cand; do
            [ -n "$cand" ] || continue
            if fd="$(find_log_fd "$cand")"; then
              spid="$cand"
              break
            fi
          done < <(pgrep -f 'opencode serve' 2>/dev/null || true)

          if [ -n "$spid" ] && [ -n "$fd" ]; then
            # tail --pid: self-terminate when serve dies. --follow=descriptor:
            # keep following the (possibly deleted) inode by fd. -n 0: only new
            # lines from now (no dupes across follower restarts).
            stdbuf -oL tail -n 0 --pid="$spid" --follow=descriptor "$fd" 2>/dev/null \
              | stdbuf -oL grep --line-buffered -E "$PATTERN" >> "$OUT" &
            follower_pid="$!"
            serve_pid="$spid"
            meta "attached to serve=$serve_pid via $fd"
          fi
        fi

        sleep "$POLL_INTERVAL"
      done
    '';
  };

  # --- logrotate config (rotated by the user timer below) ---
  home.file.".config/opencode-llm-audit/logrotate.conf".text = ''
    ${outFile} {
        daily
        rotate 14
        compress
        delaycompress
        missingok
        notifempty
        # The follower holds llm.log open with O_APPEND; copytruncate keeps that
        # fd valid (copy then truncate in place) instead of renaming the inode.
        copytruncate
    }
  '';

  # --- Always-on follower service ---
  systemd.user.services.opencode-llm-audit = {
    Unit = {
      Description = "Durable OpenCode LLM-call audit logger (follows opencode-serve log fd)";
      After = [ "default.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/.local/bin/opencode-llm-audit";
      Restart = "always";
      RestartSec = 10;
      Nice = 19;
      IOSchedulingClass = "idle";
      Environment = [
        "HOME=%h"
        "PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.procps ]}"
      ];
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # --- Daily logrotate (user-level; no system rebuild needed) ---
  systemd.user.services.opencode-llm-audit-logrotate = {
    Unit = {
      Description = "Rotate the OpenCode LLM audit log";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.logrotate}/bin/logrotate --state ${logrotateState} ${logrotateConf}";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 19;
      IOSchedulingClass = "idle";
      Environment = [ "HOME=%h" ];
    };
  };

  systemd.user.timers.opencode-llm-audit-logrotate = {
    Unit = {
      Description = "Daily rotation of the OpenCode LLM audit log";
    };
    Timer = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
