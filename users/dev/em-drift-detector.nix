# Read-only drift detector for the eternal-machinery primary root (devbox).
#
# Part of the "read-only main + enforced per-worktree work" guard family (bead
# workstation-tgo9). em's local `main` at ~/projects/eternal-machinery is meant
# to stay pinned at origin/main and be used only to fetch latest + RUN THE STACK
# (bin/devenv-up, em-tec-mcp.service). Real incident: multiple sessions edited
# the shared root directly, diverging local main (42 behind / 9 ahead) with
# uncommitted WIP.
#
# The commit-side enforcement (a pre-commit reject at the root) lives in em's OWN
# devenv/prek config, because em uses a per-worktree core.hooksPath that a
# home-manager-managed core.hooksPath cannot win against (worktree scope
# overrides local scope, and devenv re-asserts/unsets it every enterShell). See
# bead workstation-tgo9 for the full rationale.
#
# This module is the DETECTION half: a purely read-only timer that surfaces the
# ENTIRE incident class (ahead / behind / dirty), including the staleness and
# uncommitted-WIP legs that no client-side commit hook can catch. It NEVER
# mutates the working tree, index, or local branches -- it only does a
# best-effort `git fetch` (updates remote-tracking refs) and reads status. This
# is compatible with running the stack from the root (fetch + read don't touch
# tracked files).
#
# Alerting for v1 is journald (WARNING on drift, INFO when clean) plus a
# machine-readable status file at ~/.local/state/em-drift/status.json that a
# consumer (e.g. the morning workspace agent) can surface. Escalation to
# Telegram/pigeon is a deliberate follow-up, not wired here.
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  home.file.".local/bin/em-drift-detector" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      PATH="${lib.makeBinPath [
        pkgs.coreutils
        pkgs.git
        pkgs.gnugrep
      ]}:$PATH"

      ROOT="$HOME/projects/eternal-machinery"
      # Warn when the root is more than this many commits behind origin/<trunk>.
      BEHIND_WARN="''${EM_DRIFT_BEHIND_WARN:-25}"
      FETCH_TIMEOUT="''${EM_DRIFT_FETCH_TIMEOUT:-30}"
      STATE_DIR="$HOME/.local/state/em-drift"
      STATUS_FILE="$STATE_DIR/status.json"

      log() { echo "[em-drift] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

      mkdir -p "$STATE_DIR"

      # Fail-open: never let a detection error break the timer. The whole point
      # is to observe, not to gate anything.
      write_status() {
        # args: state branch ahead behind dirty note
        local state="$1" branch="$2" ahead="$3" behind="$4" dirty="$5" note="$6"
        local ts
        ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        # Hand-rolled JSON (no jq dep). Values are integers or simple tokens;
        # branch/note are escaped minimally (backslash + double-quote).
        local b n
        b="''${branch//\\/\\\\}"; b="''${b//\"/\\\"}"
        n="''${note//\\/\\\\}"; n="''${n//\"/\\\"}"
        cat > "$STATUS_FILE" <<EOF
      {
        "timestamp": "$ts",
        "root": "$ROOT",
        "state": "$state",
        "branch": "$b",
        "ahead": $ahead,
        "behind": $behind,
        "dirty": $dirty,
        "behind_warn_threshold": $BEHIND_WARN,
        "note": "$n"
      }
      EOF
      }

      if [ ! -e "$ROOT/.git" ]; then
        log "SKIP: $ROOT is not a git repo (no .git); nothing to check."
        write_status "skip" "" 0 0 0 "no .git at root"
        exit 0
      fi

      if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        log "SKIP: $ROOT is not a valid git repo."
        write_status "skip" "" 0 0 0 "invalid git repo"
        exit 0
      fi

      # Resolve trunk from origin/HEAD (fall back to 'main').
      trunk="$(git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      trunk="''${trunk#origin/}"
      [ -n "$trunk" ] || trunk="main"

      # Best-effort fetch of remote-tracking ref (updates refs/remotes only; does
      # NOT touch the working tree or local branches). Bounded; never fatal.
      fetch_note=""
      if ! timeout "$FETCH_TIMEOUT" git -C "$ROOT" fetch --quiet origin "$trunk" 2>/dev/null; then
        fetch_note="fetch of origin/$trunk failed or timed out; ahead/behind may be stale"
        log "WARN: $fetch_note"
      fi

      branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"

      if ! git -C "$ROOT" rev-parse --verify --quiet "origin/$trunk" >/dev/null 2>&1; then
        log "SKIP: origin/$trunk not found; cannot compute ahead/behind."
        write_status "skip" "$branch" 0 0 0 "origin/$trunk missing''${fetch_note:+; $fetch_note}"
        exit 0
      fi

      # Left/right counts: left = commits in origin/<trunk> not in HEAD (behind),
      # right = commits in HEAD not in origin/<trunk> (ahead).
      counts="$(git -C "$ROOT" rev-list --left-right --count "origin/$trunk...HEAD" 2>/dev/null || echo '0	0')"
      behind="$(printf '%s' "$counts" | awk '{print $1}')"
      ahead="$(printf '%s' "$counts" | awk '{print $2}')"
      [ -n "$behind" ] || behind=0
      [ -n "$ahead" ] || ahead=0

      # Dirty = tracked modifications + staged + untracked-non-ignored. Ignored
      # build artifacts (devenv/BEAM output) are excluded by porcelain default, so
      # running the stack does not register as drift.
      dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -c . || true)"
      [ -n "$dirty" ] || dirty=0

      # Assess drift.
      reasons=()
      [ "$ahead" -gt 0 ] && reasons+=("$ahead commit(s) ahead of origin/$trunk (local $branch has diverged)")
      [ "$behind" -gt "$BEHIND_WARN" ] && reasons+=("$behind commit(s) behind origin/$trunk (> $BEHIND_WARN; run \`git -C $ROOT fetch\` / rebuild off a fresh worktree)")
      [ "$dirty" -gt 0 ] && reasons+=("$dirty uncommitted/untracked path(s) in the root working tree")

      if [ "''${#reasons[@]}" -eq 0 ]; then
        log "OK: $ROOT on '$branch' is clean and within $BEHIND_WARN of origin/$trunk (ahead=$ahead behind=$behind dirty=$dirty)."
        write_status "ok" "$branch" "$ahead" "$behind" "$dirty" "clean''${fetch_note:+; $fetch_note}"
        exit 0
      fi

      log "WARNING: eternal-machinery root has drifted from origin/$trunk. This root is meant to stay read-only + pinned at origin/$trunk; do writable work in a fresh worktree (\`work <slug>\`)."
      for r in "''${reasons[@]}"; do
        log "  - $r"
      done
      note="drift"
      for r in "''${reasons[@]}"; do note="$note; $r"; done
      write_status "drift" "$branch" "$ahead" "$behind" "$dirty" "$note''${fetch_note:+; $fetch_note}"
      exit 0
    '';
  };

  # Read-only detection service (never mutates the tree).
  systemd.user.services.em-drift-detector = {
    Unit = {
      Description = "Detect drift of the eternal-machinery primary root (read-only: ahead/behind/dirty)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/em-drift-detector";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 19;
      IOSchedulingClass = "idle";
      Environment = [
        "HOME=%h"
        "PATH=${pkgs.git}/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Timer: every 30 minutes. Drift accumulates over a work session; a read-only
  # check is cheap, so a tight-ish cadence keeps the status file fresh.
  systemd.user.timers.em-drift-detector = {
    Unit = {
      Description = "eternal-machinery drift detector timer";
    };
    Timer = {
      OnCalendar = "*:0/30";
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
