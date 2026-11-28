# Nightly run of the eternal-machinery journal curator (devbox).
#
# The journal curator (eternal-machinery `bin/journal-curator`,
# agentos/journal_curator_cli.py, runbook docs/runbooks/journal-curator.md)
# reads the characters' new journal pages, rewrites their books through the
# em-history-shell service's sync op, and opens ONE pull request labelled
# `curator-journal` on branch `journal-curator/<profile>-<stamp>` with
# auto-merge on. Jonathan, 2026-11-27: "auto-merge. they may reach her before
# merge."; 2026-11-28: "curator may rewrite" and "switch it on". Beads:
# eternal-machinery-xe9gl.151.3 and .7.
#
# This is NOT the hand curator (em-skill-curator.nix): that one opens draft PRs
# that only Jonathan merges, and nothing here changes it.
#
# SPEND. One Sonnet call per character with new pages, nothing when there are
# none. While a journal-curator PR of the profile is still open the CLI refuses
# (exit 3) before any model call; that is NORMAL and logged as success here.
#
# WHERE IT RUNS. From the eternal-machinery primary root, kept at origin/main
# (em-drift-detector.nix). The CLI adds and removes a throwaway worktree for the
# PR and never edits the root's working tree.
#
# NEEDS: the AgentOS DB (127.0.0.1:5434), the OAuth proxy (127.0.0.1:4318), the
# em-history-shell socket (/run/em-history-shell/sock, which bin/journal-curator
# pings before anything else), SSH for git, and GH_TOKEN from
# /run/secrets/github_api_token for gh.
#
# GUARDS (each skips with exit 0 and a status.json outcome, no model call):
# busy, held (circuit breaker), fetch-failed, stale-root (agentos/, agent_spec/,
# bin/journal-curator or scripts/tec/history_shell.py differ from origin/main),
# stack-down (DB, proxy or the history shell socket).
#
# CIRCUIT BREAKER. After a run that may have spent and left something to look
# at (exit 4, a timeout, or exit 1 with a new run folder under
# ~/.local/share/eternal-machinery/curator/journal-*), $STATE_DIR/hold is
# written and later runs log HELD until someone removes it.
#
# RUNNING BY HAND: `systemctl --user start em-journal-curator`.
#
# Needs a devbox rebuild (home-manager switch) to take effect.
{ config, pkgs, lib, isDevbox, ... }:

lib.mkIf isDevbox {
  home.file.".local/bin/em-journal-curator" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -uo pipefail

      # External commands the curator shells out to (agentos/curator_cli.py and
      # agentos/main_tree.py): git (fetch, worktree, switch, add, commit, push,
      # show, ls-tree, merge-base, status), gh (pr list/create/...), plus `env`
      # and friends for bin/journal-curator's shebang and mkdtemp/rm.
      PATH="${lib.makeBinPath [
        pkgs.coreutils
        pkgs.bash
        pkgs.git
        pkgs.gh
        pkgs.gnutar
        pkgs.gnugrep
        pkgs.gnused
        pkgs.util-linux
      ]}:$PATH"

      ROOT="$HOME/projects/eternal-machinery"
      PROFILE="''${EM_JOURNAL_CURATOR_PROFILE:-warrior_f}"
      RUN_TIMEOUT="''${EM_JOURNAL_CURATOR_TIMEOUT:-30m}"
      STATE_DIR="$HOME/.local/state/em-journal-curator"
      STATUS_FILE="$STATE_DIR/status.json"
      HOLD_FILE="$STATE_DIR/hold"
      LOCK_FILE="$STATE_DIR/lock"
      RUN_ROOT="''${XDG_DATA_HOME:-$HOME/.local/share}/eternal-machinery/curator"
      DB_ADDR="''${EM_JOURNAL_CURATOR_DB_ADDR:-127.0.0.1:5434}"
      PROXY_ADDR="''${EM_JOURNAL_CURATOR_PROXY_ADDR:-127.0.0.1:4318}"
      HS_SOCK="''${AGENTOS_HISTORY_SHELL_SOCKET:-/run/em-history-shell/sock}"
      # The curator's own code and rules; the root must match origin/main here.
      WATCHED=(agentos agent_spec bin/journal-curator scripts/tec/history_shell.py)

      log() { echo "[em-journal-curator] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

      mkdir -p "$STATE_DIR"

      json_escape() {
        local v="$1"
        v="''${v//\\/\\\\}"; v="''${v//\"/\\\"}"
        printf '%s' "$v"
      }

      write_status() {
        # args: exit_code outcome note [run_folder]
        local code="$1" outcome="$2" note="$3" folder="''${4:-}" ts n f extra=""
        ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        n="$(json_escape "$note")"
        if [ -n "$folder" ]; then
          f="$(json_escape "$folder")"
          extra="  \"run_folder\": \"$f\","$'\n'
        fi
        # Hand-rolled JSON (no jq dep); written atomically.
        cat > "$STATUS_FILE.tmp" <<EOF
      {
        "timestamp": "$ts",
        "profile": "$PROFILE",
        "exit_code": $code,
        "outcome": "$outcome",
      ''${extra}  "note": "$n"
      }
      EOF
        mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
      }

      # Whole body under one lock: fd 9 is held until this script exits. It is
      # closed (9>&-) for the commands that may leave a daemon behind (ssh), so
      # a straggler can never keep the lock after the run is over.
      exec 9> "$LOCK_FILE"
      if ! flock -n 9; then
        log "BUSY: another run holds $LOCK_FILE; exiting."
        write_status 0 "busy" "another run holds the lock"
        exit 0
      fi

      # Circuit breaker: a previous bad run left a hold; do nothing until a
      # human has looked at its folder and removed the file.
      if [ -e "$HOLD_FILE" ]; then
        held_outcome="$(sed -n 's/^outcome=//p' "$HOLD_FILE" | head -n 1)"
        held_folder="$(sed -n 's/^run_folder=//p' "$HOLD_FILE" | head -n 1)"
        log "HELD: last run ''${held_outcome:-unknown}, folder ''${held_folder:-unknown}. Remove $HOLD_FILE to resume."
        case "$held_folder" in unknown|"") held_folder="" ;; esac
        write_status 0 "held" "last run ''${held_outcome:-unknown}; remove $HOLD_FILE to resume" "$held_folder"
        exit 0
      fi

      PY="$ROOT/.devenv/state/agentos-venv/bin/python"
      CLI="$ROOT/bin/journal-curator"
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
        write_status 0 "skip" "bin/journal-curator missing"
        exit 0
      fi

      # Is the curator code on disk main's? Fetch (SSH), then compare only the
      # paths the curator runs from. A failed fetch skips: we cannot tell.
      if ! timeout 120 git -C "$ROOT" fetch --quiet origin main 9>&-; then
        log "SKIP: git fetch origin main failed in $ROOT; cannot tell whether the root is current."
        write_status 0 "fetch-failed" "git fetch origin main failed"
        exit 0
      fi
      if ! git -C "$ROOT" diff --quiet HEAD origin/main -- "''${WATCHED[@]}" \
         || [ -n "$(git -C "$ROOT" status --porcelain -- "''${WATCHED[@]}")" ]; then
        log "SKIP: $ROOT is stale: ''${WATCHED[*]} differ from origin/main or have local edits."
        write_status 0 "stale-root" "root differs from origin/main in the curator's paths"
        exit 0
      fi

      # Is the stack up? A closed port means a skip, not a run folder and not
      # spend. Plain bash /dev/tcp, bounded to 3s each.
      probe() {
        local addr="$1"
        # shellcheck disable=SC2016  # $1/$2 belong to the inner bash, on purpose
        timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "''${addr%:*}" "''${addr##*:}" 2>/dev/null
      }
      down=""
      for pair in "AgentOS-DB=$DB_ADDR" "OAuth-proxy=$PROXY_ADDR"; do
        if ! probe "''${pair#*=}"; then
          down="$down ''${pair%%=*}(''${pair#*=})"
        fi
      done
      if [ ! -S "$HS_SOCK" ]; then
        down="$down history-shell($HS_SOCK)"
      fi
      if [ -n "$down" ]; then
        log "SKIP: stack down, not accepting connections:$down."
        write_status 0 "stack-down" "not reachable:$down"
        exit 0
      fi

      # systemd user units inherit a minimal env; give gh the token, as
      # disk-cleanup.nix does. Git's push uses SSH and needs none. Never echoed.
      GH_TOKEN_FILE="/run/secrets/github_api_token"
      if [ -r "$GH_TOKEN_FILE" ]; then
        GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
        export GH_TOKEN
      else
        log "WARN: $GH_TOKEN_FILE not readable; gh (pr list, label create, pr create) will fail unless gh is logged in."
      fi

      list_runs() { { ls -1A "$RUN_ROOT" 2>/dev/null || true; } | { grep '^journal-' || true; } | LC_ALL=C sort; }
      before="$(list_runs)"

      log "running: bin/journal-curator run --profile $PROFILE (timeout $RUN_TIMEOUT)"
      # SIGINT first so the CLI's cleanup (throwaway worktree + branch) runs;
      # SIGKILL only if it does not exit within 60s.
      timeout --signal=INT --kill-after=60 "$RUN_TIMEOUT" "$CLI" run --profile "$PROFILE" 9>&-
      code=$?

      # A run folder that appeared during the run, if any (the newest by name).
      after="$(list_runs)"
      new_name="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' | tail -n 1 || true)"
      new_run=""
      [ -n "$new_name" ] && new_run="$RUN_ROOT/$new_name"

      hold() {
        # args: outcome. Trip the breaker; the next runs log HELD and stop.
        {
          echo "outcome=$1"
          echo "exit_code=$code"
          echo "run_folder=''${new_run:-unknown}"
          echo "timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        } > "$HOLD_FILE"
        log "HOLD written: $HOLD_FILE (outcome $1, exit $code, folder ''${new_run:-unknown}). Remove it to resume."
      }

      case "$code" in
        0)
          log "OK: journal curator finished (a PR opened, or nothing new)."
          write_status "$code" "ok" "done or nothing new" "$new_run"
          exit 0
          ;;
        5)
          log "OK: another journal-curator run holds the CLI lock (exit 5)."
          write_status "$code" "busy" "the CLI lock is held" "$new_run"
          exit 0
          ;;
        3)
          log "OK: a curator PR for $PROFILE is still open; refused by design (exit 3), nothing to do."
          write_status "$code" "pr-open" "curator PR still open" "$new_run"
          exit 0
          ;;
        1)
          log "FAIL: a curator command failed (exit 1); see output above."
          write_status "$code" "failed" "a command failed" "$new_run"
          # A run folder means the model ran (spend) and left work to inspect.
          [ -n "$new_run" ] && hold "failed"
          ;;
        2)
          log "FAIL: bad input (exit 2); see output above."
          write_status "$code" "bad-input" "bad input or missing venv" "$new_run"
          ;;
        4)
          log "FAIL: a character's night failed and the others went on (exit 4)."
          write_status "$code" "night-failed" "a character's night failed" "$new_run"
          hold "night-failed"
          ;;
        124|137)
          log "FAIL: timed out after $RUN_TIMEOUT (exit $code)."
          write_status "$code" "timeout" "timed out after $RUN_TIMEOUT" "$new_run"
          hold "timeout"
          ;;
        *)
          log "FAIL: unexpected exit $code."
          write_status "$code" "failed" "unexpected exit code" "$new_run"
          ;;
      esac
      exit "$code"
    '';
  };

  systemd.user.services.em-journal-curator = {
    Unit = {
      Description = "Run the eternal-machinery journal curator (one curator-journal PR, auto-merge)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/em-journal-curator";
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

  # Nightly at 03:00 UTC: after a live window hands back (about 01:00 UTC) and
  # before the next one boots (about 04:00 UTC). Persistent so a missed run fires
  # on boot; the curator's cursor reads a missed night the next night.
  systemd.user.timers.em-journal-curator = {
    Unit = {
      Description = "eternal-machinery journal curator timer";
    };
    Timer = {
      OnCalendar = "*-*-* 03:00:00 UTC";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
