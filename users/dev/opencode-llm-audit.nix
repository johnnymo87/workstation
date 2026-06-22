# Durable OpenCode LLM-call audit logger (cloudbox)
#
# WHY: opencode writes its logs under ~/.local/share/opencode/log/. Historically
# that was a per-process `<ISO>.log` whose oldest entry the Log module
# (packages/core/src/util/log.ts) `fs.unlink()`'d on EVERY process start
# (`const keep = 10`) -- so the long-lived serve kept writing to a now *deleted*
# inode via its still-open fd, and a naive `tail -F newest *.log` captured only
# short-lived TUI client logs (no service=llm lines), MISSING the serve log.
# opencode-patched 1.17.x instead appends every process to a single fixed
# `opencode.log`. Either way, the attribution we care about (service=llm ...)
# lives in a file best reached by the fd the serve holds open, not by name.
#
# POOL FAN-OUT (mn9r M5, workstation-ofma): under the serve pool cloudbox runs
# K=4 serves (serve-pool.nix). With the shared opencode.log all four hold the
# SAME inode; with per-process logs each holds its own. So the supervisor must
# follow EVERY distinct log inode, not just the first serve pgrep returns, or it
# silently captures ~1/K of LLM traffic -- the exact blind spot this audit
# exists to prevent.
#
# WHAT THIS DOES: a tiny always-on supervisor that, each poll, finds every
# running `opencode serve`, resolves the fd each holds open on its log file (even
# if deleted), DEDUPES those by inode, and runs one `tail` per DISTINCT inode --
# piping matching lines to a kept file under ~/.local/state (outside the
# disk-cleanup / nightly-restart scope). Dedupe means the shared-opencode.log
# case yields a single follower (no duplicate lines); a per-process-log future
# yields K. Each follower uses `tail --pid=<serve>` so it self-terminates when
# that serve dies and the supervisor re-attaches. Captured signals (opencode
# 1.17.x logfmt; the old `service=...` token was replaced by `message=...`):
#   - attribution: `message=stream providerID= modelID= session.id=ses_...
#                   small= agent= mode=`  (level=INFO, one per LLM call)
#   - errors/quota: the `message="stream error" ... error.error="..."` line
#                   (level=ERROR) carries the raw provider text (RESOURCE_
#                   EXHAUSTED, 429, quota) plus bare provider/gRPC error tokens.
# capture_filter first DROPS the >100k/day `message=evaluated permission` lines
# (which echo arbitrary command text) so trigger words in a command can't create
# false positives, then keeps only the attribution + error/quota lines above.
#
# NOTE ON THE RETRY STORM: opencode-level retries (processor.ts:810
# Effect.retry(SessionRetry.policy)) re-invoke llm.stream, so each retry
# re-emits a message=stream line -- visible here. The deeper ~16-48x SDK/gateway
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
        pkgs.coreutils   # tail, stdbuf, readlink, stat, date, sleep, mkdir, head
        pkgs.gnugrep     # grep
        pkgs.procps      # pgrep
      ]}:$PATH"

      LOGDIR="${logDir}"
      OUT="${outFile}"
      POLL_INTERVAL=5

      mkdir -p "$(dirname "$OUT")"

      meta() { printf '[opencode-llm-audit] %s %s\n' "$(date -Is)" "$*" >&2; }

      # === BEGIN TESTABLE HELPERS ===
      # opencode-patched 1.17.x replaced the old `service=llm ...` attribution
      # line with a structured logfmt format. The signals we keep are:
      #   - attribution: `message=stream providerID= modelID= session.id=ses_...
      #                   small= agent= mode=`            (success, level=INFO)
      #   - errors/quota: `message="stream error" ... error.error="..."` (level=
      #                   ERROR; carries the raw provider text incl. RESOURCE_
      #                   EXHAUSTED / 429 / quota) plus bare provider/gRPC tokens.
      # Both anchor on `message="?stream` (the quote is optional: success is
      # unquoted, the error message is quoted). The bare error tokens stay for
      # any other line that carries a provider quota signal.
      PATTERN='message="?stream|RESOURCE_EXHAUSTED|DEADLINE_EXCEEDED|UNAVAILABLE|status=429|statusCode=429|Too Many Requests|too_many_requests|Rate Limited|RateLimit|rate limit|Provider is overloaded|Overloaded|insufficient_quota|quota_exceeded|Quota exceeded|AbortError'

      # The single highest-volume log line (>100k/day) is the permission engine's
      # `message=evaluated permission ... pattern="<verbatim command>"`. It echoes
      # arbitrary command text, so a bash command merely MENTIONING a trigger word
      # (e.g. RESOURCE_EXHAUSTED, status=429, message=stream) would otherwise land
      # in the audit as a false positive. Drop these lines BEFORE matching.
      EXCLUDE='message=evaluated permission'

      # Read raw log lines on stdin; emit only the attributable LLM + provider
      # error/quota lines. Exclude-then-include so trigger words inside an echoed
      # command can never create a false positive. Pure (stdin->stdout) so it is
      # unit-testable independent of any tail/serve.
      capture_filter() {
        stdbuf -oL grep --line-buffered -vF -- "$EXCLUDE" \
          | stdbuf -oL grep --line-buffered -E -- "$PATTERN"
      }

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

      # Collapse "inode pid fdpath" lines to ONE per unique inode (first wins,
      # input order preserved). opencode-patched 1.17.x writes EVERY process to a
      # single shared opencode.log, so all K serves resolve to the SAME inode;
      # without this dedupe the per-serve fan-out below would attach K tails to
      # one inode and duplicate every captured line (corrupting retry-storm
      # counts). Pure (stdin->stdout) so it is unit-testable.
      dedupe_by_inode() {
        local ino rest
        declare -A seen
        while read -r ino rest; do
          [ -n "$ino" ] || continue
          if [ -z "''${seen[$ino]:-}" ]; then
            seen[$ino]=1
            printf '%s %s\n' "$ino" "$rest"
          fi
        done
      }

      # Read candidate pids on stdin; for each that holds an open opencode log fd,
      # emit "inode pid fdpath". (The impure pgrep stays in the caller so this is
      # testable from a fixed pid list.)
      discover_serve_log_fds() {
        local cand fd ino
        while read -r cand; do
          [ -n "$cand" ] || continue
          fd="$(find_log_fd "$cand")" || continue
          ino="$(stat -L -c '%i' "$fd" 2>/dev/null)" || continue
          [ -n "$ino" ] || continue
          printf '%s %s %s\n' "$ino" "$cand" "$fd"
        done
      }
      # === END TESTABLE HELPERS ===

      # inode -> follower(pipeline) pid. One follower per DISTINCT log inode so we
      # capture ALL serves in the mn9r M5 pool (cloudbox K=4), not just the first
      # match pgrep returns -- while never double-following a shared inode.
      declare -A follower

      meta "starting; LOGDIR=$LOGDIR OUT=$OUT"

      while :; do
        # Reap followers whose pipeline died (the serve we bound --pid to exited
        # -> tail exits -> grep EOFs). Drop them so we re-attach below if the log
        # is still held open by some live serve.
        for ino in "''${!follower[@]}"; do
          if ! kill -0 "''${follower[$ino]}" 2>/dev/null; then
            meta "follower for inode=$ino (pid=''${follower[$ino]}) exited; will re-attach if still served"
            unset 'follower[$ino]'
          fi
        done

        # Attach exactly one follower per distinct log inode currently held by a
        # live `opencode serve` (validated via find_log_fd so the startup wrapper
        # / TUI clients are ignored). dedupe_by_inode makes the shared-opencode.log
        # case yield a single follower; a per-process-log future yields K.
        while read -r ino spid fd; do
          [ -n "$ino" ] || continue
          [ -n "''${follower[$ino]:-}" ] && continue
          # tail --pid: self-terminate when that serve dies. --follow=descriptor:
          # keep following the (possibly deleted) inode by fd. -n 0: only new
          # lines from now (no dupes across follower restarts).
          stdbuf -oL tail -n 0 --pid="$spid" --follow=descriptor "$fd" 2>/dev/null \
            | capture_filter >> "$OUT" &
          follower[$ino]="$!"
          meta "attached to serve=$spid inode=$ino via $fd"
        done < <(pgrep -f 'opencode serve' 2>/dev/null | discover_serve_log_fds | dedupe_by_inode)

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
