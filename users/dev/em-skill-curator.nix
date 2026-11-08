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
#   - SSH key      the push (and the root's fetch) goes over SSH: origin is
#                  git@github.com:..., the key comes from the ssh config. No
#                  token is involved in git.
#   - GH_TOKEN     read from the sops secret /run/secrets/github_api_token the way
#                  disk-cleanup.nix does (systemd user units get a minimal env);
#                  used by `gh` only (pr list, label create, pr create).
#                  Exported into the process only, never printed.
# Those three URLs are the CLI's own defaults; set them in the unit only if the
# stack moves.
#
# GUARDS, in order (each skips with exit 0 and a status.json outcome; none of
# them spends a model call):
#   busy          another run holds $STATE_DIR/lock (flock -n)
#   held          circuit breaker: $STATE_DIR/hold exists (see below)
#   fetch-failed  `git fetch origin main` in the root failed
#   stale-root    the root's agentos/, agent_spec/, bin/skill-curator or
#                 agent_skills/README.md differ from origin/main or have local
#                 edits, i.e. the curator code on disk is not main's
#   stack-down    the AgentOS DB (127.0.0.1:5434), the OAuth proxy
#                 (127.0.0.1:4319) or codex (localhost:4010) does not accept a
#                 TCP connection (overridable for tests: EM_SKILL_CURATOR_DB_ADDR,
#                 _PROXY_ADDR, _CODEX_ADDR as host:port)
#
# CIRCUIT BREAKER. After a run that may have spent money and left something to
# look at (exit 4, a timeout 124/137, or exit 1 with a new run folder under
# ${XDG_DATA_HOME:-$HOME/.local/share}/eternal-machinery/curator/), the script
# writes $STATE_DIR/hold (outcome, exit code, run folder) and every later run
# logs HELD and exits 0 until someone looks at the folder and removes the file.
# That bounds a failing curator to one bad run, not one per day.
#
# RUNNING BY HAND. Use `systemctl --user start em-skill-curator`, not the script
# directly: the unit gives it the same env, memory cap and timeout as the timer,
# and the lock and the hold apply either way. The first run after this lands
# should be supervised that way (watch `journalctl --user -fu em-skill-curator`).
#
# LEFTOVERS. SIGKILL or a host shutdown mid-run can leave a /tmp/curator-pr-*
# worktree and a local curator/<profile>-* branch registered in the root's .git.
# They are harmless; `git -C ~/projects/eternal-machinery worktree prune` and
# `git branch -D <branch>` clean them.
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
        pkgs.util-linux
      ]}:$PATH"

      ROOT="$HOME/projects/eternal-machinery"
      PROFILE="''${EM_SKILL_CURATOR_PROFILE:-warrior_f}"
      RUN_TIMEOUT="''${EM_SKILL_CURATOR_TIMEOUT:-30m}"
      STATE_DIR="$HOME/.local/state/em-skill-curator"
      STATUS_FILE="$STATE_DIR/status.json"
      HOLD_FILE="$STATE_DIR/hold"
      LOCK_FILE="$STATE_DIR/lock"
      RUN_ROOT="''${XDG_DATA_HOME:-$HOME/.local/share}/eternal-machinery/curator"
      DB_ADDR="''${EM_SKILL_CURATOR_DB_ADDR:-127.0.0.1:5434}"
      PROXY_ADDR="''${EM_SKILL_CURATOR_PROXY_ADDR:-127.0.0.1:4319}"
      CODEX_ADDR="''${EM_SKILL_CURATOR_CODEX_ADDR:-localhost:4010}"
      # The curator's own code and rules; the root must match origin/main here.
      WATCHED=(agentos agent_spec bin/skill-curator agent_skills/README.md)

      log() { echo "[em-skill-curator] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

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
      for pair in "AgentOS-DB=$DB_ADDR" "OAuth-proxy=$PROXY_ADDR" "codex=$CODEX_ADDR"; do
        if ! probe "''${pair#*=}"; then
          down="$down ''${pair%%=*}(''${pair#*=})"
        fi
      done
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

      list_runs() { { ls -1A "$RUN_ROOT" 2>/dev/null || true; } | LC_ALL=C sort; }
      before="$(list_runs)"

      log "running: bin/skill-curator run --profile $PROFILE (timeout $RUN_TIMEOUT)"
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
          log "OK: curator finished (done, or nothing due)."
          write_status "$code" "ok" "done or nothing due" "$new_run"
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
          log "FAIL: no usable patch from the model (exit 4)."
          write_status "$code" "no-patch" "no usable patch" "$new_run"
          hold "no-patch"
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
