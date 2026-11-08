# Daily run of the eternal-machinery skill curator (devbox).
#
# The curator (eternal-machinery `bin/skill-curator`, agentos/curator_cli.py)
# reviews the skills the in-game characters wrote and opens ONE draft pull
# request against eternal-machinery. Beads: eternal-machinery-qpmfc.18.16.49.2.21
# (this timer), .2.8 (the CLI); eternal-machinery PR #1276.
#
# NEVER MERGES. The curator opens a DRAFT PR and does not merge it or enable
# auto-merge (pinned in the curator's own tests). The rule it serves: only
# Jonathan merges a PR that carries a skill a character wrote (label
# `character-skills`, branch `curator/*`, or anything under
# `agent_skills_private/`). This timer must never be extended to merge, mark
# ready, or arm auto-merge on that PR.
#
# SPEND. One opus conversation per run, and only when a skill is due. Nothing
# due means no model call at all. While a curator PR for the profile is still
# open the CLI refuses (exit 3) before any model call; that is NORMAL and is
# logged as success here.
#
# WHERE IT RUNS. From the eternal-machinery primary root, the read-only main
# checkout kept at origin/main (same convention as em-drift-detector.nix). The
# curator only runs `git fetch origin main` there and adds/removes a throwaway
# `git worktree` (under $TMPDIR); it never edits the root's working tree. If the
# root, the AgentOS venv python or bin/skill-curator is missing the script logs
# why and exits 0, so a half-provisioned host does not leave a failed unit.
#
# NEEDS (all local to devbox, nothing is read from or written to them here):
#   - AgentOS DB   AGENTOS_DB_URL (curator default: postgresql on 127.0.0.1:5434), read only
#   - OAuth proxy  AGENTOS_PROXY_BASE_URL (curator default: http://127.0.0.1:4319)
#   - codex        CODEX_URL (curator default: http://localhost:4010)
#   - GH_TOKEN     read from the sops secret /run/secrets/github_api_token the way
#                  disk-cleanup.nix does (systemd user units get a minimal env);
#                  used by `gh` and by git's `gh auth git-credential` helper for
#                  the push. Exported into the process only, never printed.
# Those three URLs are the CLI's own defaults; set them in the unit only if the
# stack moves.
#
# Needs a devbox rebuild (home-manager switch) to take effect.
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  home.file.".local/bin/em-skill-curator" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -uo pipefail

      # External commands the curator shells out to (agentos/curator_cli.py and
      # agentos/main_tree.py): git (fetch, worktree, switch, add, commit, push,
      # show, ls-tree, merge-base, status), gh (pr list/create/...), plus `env`
      # and friends for bin/skill-curator's shebang and mkdtemp/rm.
      PATH="${lib.makeBinPath [
        pkgs.coreutils
        pkgs.bash
        pkgs.git
        pkgs.gh
        pkgs.gnutar
        pkgs.gnugrep
        pkgs.gnused
      ]}:$PATH"

      ROOT="$HOME/projects/eternal-machinery"
      PROFILE="''${EM_SKILL_CURATOR_PROFILE:-warrior_f}"
      RUN_TIMEOUT="''${EM_SKILL_CURATOR_TIMEOUT:-30m}"
      STATE_DIR="$HOME/.local/state/em-skill-curator"
      STATUS_FILE="$STATE_DIR/status.json"

      log() { echo "[em-skill-curator] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

      mkdir -p "$STATE_DIR"

      write_status() {
        # args: exit_code outcome note
        local code="$1" outcome="$2" note="$3" ts n
        ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        n="''${note//\\/\\\\}"; n="''${n//\"/\\\"}"
        # Hand-rolled JSON (no jq dep); written atomically.
        cat > "$STATUS_FILE.tmp" <<EOF
      {
        "timestamp": "$ts",
        "profile": "$PROFILE",
        "exit_code": $code,
        "outcome": "$outcome",
        "note": "$n"
      }
      EOF
        mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
      }

      PY="$ROOT/.devenv/state/agentos-venv/bin/python"
      CLI="$ROOT/bin/skill-curator"
      if [ ! -d "$ROOT" ]; then
        log "SKIP: $ROOT does not exist; nothing to run."
        write_status 0 "skip" "root missing"
        exit 0
      fi
      if [ ! -x "$PY" ]; then
        log "SKIP: AgentOS venv python missing: $PY (build it with bin/agentos-venv)."
        write_status 0 "skip" "venv python missing"
        exit 0
      fi
      if [ ! -x "$CLI" ]; then
        log "SKIP: $CLI missing or not executable (root not yet at a commit that has the curator?)."
        write_status 0 "skip" "bin/skill-curator missing"
        exit 0
      fi

      # systemd user units inherit a minimal env; give gh and git's gh
      # credential helper the token, as disk-cleanup.nix does. Never echoed.
      GH_TOKEN_FILE="/run/secrets/github_api_token"
      if [ -r "$GH_TOKEN_FILE" ]; then
        GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
        export GH_TOKEN
      else
        log "WARN: $GH_TOKEN_FILE not readable; gh and the push will fail unless gh is logged in."
      fi

      log "running: bin/skill-curator run --profile $PROFILE (timeout $RUN_TIMEOUT)"
      # SIGINT first so the CLI's cleanup (throwaway worktree + branch) runs;
      # SIGKILL only if it does not exit within 60s.
      timeout --signal=INT --kill-after=60 "$RUN_TIMEOUT" "$CLI" run --profile "$PROFILE"
      code=$?

      case "$code" in
        0)
          log "OK: curator finished (done, or nothing due)."
          write_status "$code" "ok" "done or nothing due"
          exit 0
          ;;
        3)
          log "OK: a curator PR for $PROFILE is still open; refused by design (exit 3), nothing to do."
          write_status "$code" "pr-open" "curator PR still open"
          exit 0
          ;;
        1)
          log "FAIL: a curator command failed (exit 1); see output above."
          write_status "$code" "failed" "a command failed"
          ;;
        2)
          log "FAIL: bad input (exit 2); see output above."
          write_status "$code" "bad-input" "bad input or missing venv"
          ;;
        4)
          log "FAIL: no usable patch from the model (exit 4)."
          write_status "$code" "no-patch" "no usable patch"
          ;;
        124|137)
          log "FAIL: timed out after $RUN_TIMEOUT (exit $code)."
          write_status "$code" "timeout" "timed out after $RUN_TIMEOUT"
          ;;
        *)
          log "FAIL: unexpected exit $code."
          write_status "$code" "failed" "unexpected exit code"
          ;;
      esac
      exit "$code"
    '';
  };

  systemd.user.services.em-skill-curator = {
    Unit = {
      Description = "Run the eternal-machinery skill curator (opens one draft PR; never merges)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/em-skill-curator";
      StandardOutput = "journal";
      StandardError = "journal";
      TimeoutStartSec = "40min";
      MemoryMax = "2G";
      MemorySwapMax = "0";
      Nice = 10;
      Environment = [
        "HOME=%h"
        "PATH=${pkgs.git}/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Daily at 09:30 UTC. Persistent so a missed run (host off) fires on boot.
  systemd.user.timers.em-skill-curator = {
    Unit = {
      Description = "eternal-machinery skill curator timer";
    };
    Timer = {
      OnCalendar = "*-*-* 09:30:00 UTC";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
