{ pkgs }:

pkgs.writeShellApplication {
  name = "reset-workspace";
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    procps         # pkill, pgrep
    util-linux     # flock
    coreutils      # timeout
    systemd        # systemd-run for cgroup re-exec
  ];
  text = ''
    # reset-workspace [--yes]
    #
    # Tear down all nvims and opencode sessions, restart opencode-serve,
    # bring nvims back up as `nvims`. See:
    # docs/plans/2026-04-24-reset-workspace-design.md
    #
    # --yes  Skip the confirmation prompt (used by the nightly systemd unit).

    OPENCODE_URL="''${OPENCODE_URL:-http://127.0.0.1:4096}"
    YES=0

    # Save original args for the flock re-exec below.
    ORIG_ARGS=("$@")

    log() {
      printf '[reset-workspace] %s\n' "$*" >&2
    }

    die() {
      log "FATAL: $*"
      exit 1
    }

    # Print a pid and all of its descendant pids, one per line. Used to
    # attribute `opencode attach` processes to the lgtm tmux session BEFORE we
    # kill it (after the kill, children reparent to init and become
    # unattributable).
    collect_subtree() {
      local root="$1" child
      printf '%s\n' "$root"
      for child in $(pgrep -P "$root" 2>/dev/null || true); do
        collect_subtree "$child"
      done
    }

    # ---- Process detachment: re-exec into a fresh user systemd scope ----
    # This script kills processes that are likely to be ancestors of its own
    # invoker — specifically nvim (step 4: pkill -9 -u dev -x nvim) and
    # opencode-serve.service (step 5: sudo systemctl restart, which kills
    # the whole service cgroup by default). If we don't detach, we die from:
    #   - SIGHUP propagating from the killed ancestor nvim's PTY collapse, OR
    #   - SIGTERM from systemd's KillMode=control-group cgroup-wide kill.
    #
    # `systemd-run --user --scope` wraps us in a transient .scope unit that:
    #   - Lives in /user.slice/.../app.slice/run-pXXX.scope (fresh cgroup,
    #     outside opencode-serve.service)
    #   - Is reparented under user@1000.service (no nvim ancestor)
    #   - Has its own session leader (no controlling TTY → no PTY-collapse SIGHUP)
    #
    # We do this unconditionally (gated only by the loop-guard env var) because
    # the cost on the happy path is ~10ms and the failure modes it prevents
    # are silent + subtle. Set RESET_WORKSPACE_NO_DETACH=1 to opt out (for
    # debugging only — known-broken in production-like invocation contexts).
    # See: docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md
    if [ "''${RESET_WORKSPACE_DETACHED:-}" != "1" ] \
       && [ "''${RESET_WORKSPACE_NO_DETACH:-}" != "1" ]; then
      log "detaching into fresh user systemd scope..."
      export RESET_WORKSPACE_DETACHED=1
      # --collect: GC the transient scope as soon as we exit.
      # --quiet: suppress the "Running scope as unit run-rXXX.scope" banner.
      # No --pty/--pipe: those flags are service-only and rejected in --scope mode.
      # In --scope mode the re-exec'd process just inherits our stdin/stdout/stderr,
      # which is what we want (the script runs synchronously, attached to whatever
      # terminal/pipe the caller gave us; the [y/N] prompt path still works because
      # interactive humans hit it via a terminal).
      # XDG_RUNTIME_DIR: required for --user (path to the user manager's socket).
      # Fall back to running in-place if systemd-run is unavailable or fails.
      if ! exec env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/''$(id -u)}" \
           systemd-run --user --scope --collect --quiet -- "$0" "$@"; then
        log "WARNING: systemd-run --user --scope failed; running in-place (script may die mid-flight)"
        # Continue past the re-exec block. The flock re-exec below will still run.
      fi
    fi

    # Parse args
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes|-y) YES=1; shift ;;
        --help|-h)
          cat <<EOF
Usage: reset-workspace [--yes]

Tear down all nvims and opencode sessions, restart opencode-serve,
bring nvims back up as \`nvims\`.

  --yes, -y    Skip the confirmation prompt.
EOF
          exit 0
          ;;
        *) die "unknown arg: $1 (try --help)" ;;
      esac
    done

    # ---- Concurrency: re-exec under flock if not already locked ----
    LOCK="/tmp/reset-workspace.lock"
    if [ "''${RESET_WORKSPACE_LOCKED:-}" != "1" ]; then
      export RESET_WORKSPACE_LOCKED=1
      RET=0
      flock -n -E 99 "$LOCK" "$0" ''${ORIG_ARGS[@]+"''${ORIG_ARGS[@]}"} || RET=$?
      if [ "$RET" -eq 99 ]; then
        die "another reset-workspace is running (lock $LOCK held)"
      fi
      exit "$RET"
    fi



    # ---- Step 2: Snapshot live opencode attach clients ----
    # Restoration scope: ONLY sessions launched via Telegram /launch or
    # `opencode-launch` CLI. Both produce TUI processes with cmdline of the
    # form `<binary>/opencode attach <url> --session ses_xxx [--dir <path>]`
    # -- the sid is reliably in argv. Bare `:te opencode` TUIs (no
    # --session) are NOT restored across reset; they are intended for
    # ad-hoc work. See
    # docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md

    # ---- Step 1.5: Tear down the lgtm junk-drawer tmux session ----
    # lgtm confines its OpenCode launches to a tmux session literally named
    # `lgtm` (see lgtm src/dispatch.ts LGTM_TMUX_SESSION + workstation
    # oc-auto-attach --tmux-session). Those review sessions are noise in the
    # morning recommendations, so we capture their attach-client PIDs (whole
    # process subtree of each pane, while the tree is still intact), exclude
    # them from the snapshot below, then kill the session outright. `=lgtm`
    # is an exact-match so a session named e.g. `lgtm-foo` is untouched.
    LGTM_PIDS=" "
    if tmux has-session -t '=lgtm' 2>/dev/null; then
      while read -r pane_pid; do
        [ -n "$pane_pid" ] || continue
        while read -r d; do
          LGTM_PIDS="''${LGTM_PIDS}''${d} "
        done < <(collect_subtree "$pane_pid")
      done < <(tmux list-panes -s -t '=lgtm' -F '#{pane_pid}' 2>/dev/null || true)
      log "tearing down lgtm tmux session (excluding its sessions from recommendations); pids:$LGTM_PIDS"
      tmux kill-session -t '=lgtm' 2>/dev/null || true
    fi

    log "snapshotting live opencode attach clients..."

    OPENCODE_MANIFEST=""
    OPENCODE_STRICT_RAW=0     # strict-attach pgrep matches (raw, before dedupe)
    OPENCODE_BARE_RESOLVED=0  # bare TUIs whose cwd resolved to a sid via opencode-serve
    OPENCODE_BARE_SKIPPED=0   # bare TUIs whose cwd had no resolvable sid (or unreadable cwd)

    # Loose pgrep + strict per-pid validation. Strict regex anchors on the
    # binary path prefix, the literal `attach` subcommand, an http(s) url,
    # and a syntactically valid sid -- false positives are essentially
    # impossible.
    #
    # Note: the cmdline may have additional argv after the sid (notably
    # `--dir <path>`, which oc-auto-attach has been emitting since
    # 2026-04-28; see assets/nvim/lua/user/oc_auto_attach.lua). The match
    # therefore does NOT anchor with $ at the end -- it just requires that
    # `--session ses_xxx` appears somewhere after the url, with either a
    # space or end-of-string after the sid (so we don't capture a partial
    # token).
    OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach' 2>/dev/null || true)
    for pid in $OC_ATTACH_PIDS; do
      case "$LGTM_PIDS" in *" $pid "*) log "  skipping pid=$pid (lgtm junk-drawer session)"; continue ;; esac
      # Authoritative exe filter: skip non-opencode processes that pgrep
      # over-matched (e.g. a transient `grep "opencode attach"` running
      # alongside reset). Without this, those processes trigger misleading
      # "no --session in argv" WARNINGs that pollute the journal.
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
      exe_base=$(basename "$exe")
      if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
        continue
      fi

      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//' || true)
      [ -n "$cmdline" ] || continue

      if [[ "$cmdline" =~ ^[^[:space:]]+/opencode[[:space:]]+attach[[:space:]]+https?://[^[:space:]]+([[:space:]]+.*)?[[:space:]]+--session[[:space:]]+(ses_[A-Za-z0-9]+)([[:space:]]|$) ]]; then
        sid="''${BASH_REMATCH[2]}"
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
        log "  pid=$pid sid=$sid cwd=$cwd"
        OPENCODE_STRICT_RAW=$((OPENCODE_STRICT_RAW + 1))
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${sid}"$'\n'
      else
        log "  WARNING: skipping pid=$pid (no --session in argv) cmdline=$cmdline"
      fi
    done

    # Resolve bare opencode TUIs to sids via opencode-serve.
    # For each bare TUI alive, look up the most-recent root session for its
    # cwd; if found, restore it as an attach client by appending the sid to
    # OPENCODE_MANIFEST. opencode-serve is alive at this point (we restart
    # it later in step 5), so the API is always reachable here.
    OC_ALL_PIDS=$(pgrep -u dev -f opencode 2>/dev/null || true)
    for pid in $OC_ALL_PIDS; do
      case "$LGTM_PIDS" in *" $pid "*) log "  skipping pid=$pid (lgtm junk-drawer session)"; continue ;; esac
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
      exe_base=$(basename "$exe")
      if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
        continue
      fi
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//' || true)
      [ -n "$cmdline" ] || continue
      arg2=$(printf '%s' "$cmdline" | awk '{print $2}')
      # Skip serve (we restart it, not restore it) and attach clients
      # (already enumerated in the strict loop above).
      [ "$arg2" = "serve" ] && continue
      [ "$arg2" = "attach" ] && continue

      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
      if [ -z "$cwd" ]; then
        log "  WARNING: bare opencode TUI pid=$pid has no readable cwd; skipping"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
        continue
      fi

      resolved_sid=$(curl -fsS --get "$OPENCODE_URL/session" \
        --data-urlencode "directory=$cwd" \
        --data-urlencode "roots=true" \
        --data-urlencode "limit=1" 2>/dev/null \
        | jq -r '.[0].id // empty' 2>/dev/null || true)

      if [ -n "$resolved_sid" ] && printf '%s' "$resolved_sid" | grep -qxE 'ses_[A-Za-z0-9]+'; then
        log "  pid=$pid (bare-resolved) sid=$resolved_sid cwd=$cwd"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${resolved_sid}"$'\n'
        OPENCODE_BARE_RESOLVED=$((OPENCODE_BARE_RESOLVED + 1))
      else
        log "  WARNING: bare opencode TUI pid=$pid cwd=$cwd has no resolvable session in DB; skipping restoration"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
      fi
    done

    # Dedupe captured sids.
    OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')
    if [ -z "$OPENCODE_MANIFEST" ]; then
      OPENCODE_COUNT=0
    else
      OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
    fi

    log "  captured $OPENCODE_COUNT restorable session(s) (raw: $OPENCODE_STRICT_RAW strict-attach + $OPENCODE_BARE_RESOLVED bare-resolved; dedupe may collapse); $OPENCODE_BARE_SKIPPED bare TUI(s) skipped"

    # ---- Step 2: Confirm with user ----
    log ""
    log "About to:"
    log "  1. SIGKILL all dev-owned nvim processes"
    log "  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  3. Launch recommendation session referencing $OPENCODE_COUNT captured sid(s)"
    log ""

    if [ "$YES" -ne 1 ]; then
      printf '[reset-workspace] Continue? [y/N] ' >&2
      read -r REPLY
      case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) die "aborted by user" ;;
      esac
    else
      log "(--yes: skipping confirmation)"
    fi

    # ---- Step 3: Kill all nvims ----
    log "killing all nvim/nvims processes (SIGKILL)..."
    # -x nvim matches both `nvim` (TTY frontend) and `nvim --embed`
    # (embedded server) because both have comm = `nvim`.
    if pkill -9 -u dev -x nvim 2>/dev/null; then
      log "  pkill returned matches"
    else
      log "  pkill returned no matches (none running, or already dead)"
    fi

    # ---- Step 5: Restart opencode-serve ----
    log "restarting opencode-serve.service..."
    # Passwordless sudo works via wheel group + security.sudo.wheelNeedsPassword=false (set in hosts/cloudbox/configuration.nix).
    # Use absolute path /run/wrappers/bin/sudo because:
    #   1. NixOS ships the working setuid sudo at /run/wrappers/bin/sudo.
    #   2. /run/current-system/sw/bin/sudo is a non-setuid symlink that
    #      sudo itself refuses to exec from. systemd units with restricted
    #      PATH won't find the wrapper unless explicitly named.
    if ! /run/wrappers/bin/sudo systemctl restart opencode-serve.service; then
      die "failed to restart opencode-serve"
    fi

    log "polling /global/health for serve readiness..."
    # --max-time 3 is load-bearing: without it, a single hung curl (e.g. TCP
    # connected before serve's HTTP listener was ready, then read blocked
    # indefinitely) wedges the whole script. Observed in the wild on
    # 2026-05-16: curl parked for 6+ hours despite serve being healthy.
    # The bash `while` can't re-check the deadline while wait4()'d on the
    # curl child.
    DEADLINE=$(($(date +%s) + 30))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      if curl -sf --max-time 3 "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
        log "  serve healthy"
        break
      fi
      read -t 0.5 -r _ < <(:) 2>/dev/null || true
    done
    if ! curl -sf --max-time 3 "$OPENCODE_URL/global/health" >/dev/null 2>&1; then
      die "opencode-serve did not become healthy within 30s"
    fi

    # ---- Step 6: Write manifest + launch recommendation session ----
    # Replaces the old auto-restore (nvim respawn + oc-auto-attach loop).
    # The recommendation session reads the manifest, enriches each sid via
    # opencode-serve, messages the user via Telegram with conversational
    # recommendations, and re-opens only the chosen sessions on reply.
    # Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md
    MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"
    if [ -n "''$OPENCODE_MANIFEST" ]; then
      printf '%s\n' "''$OPENCODE_MANIFEST" > "''$MANIFEST_PATH"
      log "wrote ''$OPENCODE_COUNT sid(s) to ''$MANIFEST_PATH"
    else
      : > "''$MANIFEST_PATH"
      log "wrote empty ''$MANIFEST_PATH (no captured sids)"
    fi

    if [ "''$OPENCODE_COUNT" -eq 0 ]; then
      log "no sessions to recommend; skipping recommendation session launch"
    elif ! command -v opencode-launch >/dev/null 2>&1; then
      log "WARNING: opencode-launch not on PATH; cannot spawn recommendation session"
    else
      log "launching recommendation session in ~ ..."
      # The prompt is intentionally loose/judgmental. The recommendation
      # session does its own enrichment via the opencode-serve HTTP API.
      # See design doc for the rationale.
      RECOMMENDATION_PROMPT=''$(cat <<'PROMPT'
You're the morning recommendation agent. The user has just gone through a nightly reset of their workspace. Read the file at /tmp/reset-workspace-last-manifest.txt -- it contains one opencode session id per line, representing sessions that had a live TUI at reset time.

For each sid, fetch its metadata from GET http://127.0.0.1:4096/session/<sid> and look at the title, directory, and last update time. If useful, also fetch recent messages from GET http://127.0.0.1:4096/session/<sid>/message to get a sense of whether the session was mid-task or wrapped up.

Build a short, conversational Telegram message recommending which sessions to reopen and why. Be opinionated. Group by project. If something looks finished (a PR landed, a question got resolved), say so. If something looks mid-flight, say that too. Number the recommendations so the user can refer to them by number.

Then use the question tool to ask the user which to reopen. Accept free-form replies like "1,3,5", "all", "none", "the mono ones".

When they reply, parse their selection and for each chosen sid, run `oc-auto-attach <sid>` in a bash tool. Report a brief summary of what was opened.

If the manifest file is missing or empty, message the user "Nightly reset complete, no sessions to recommend." and exit.
PROMPT
)
      # opencode-launch first arg is directory, second is the prompt.
      # ~ resolves inside opencode-launch via "''${directory/#\~/$HOME}".
      if ! opencode-launch '~' "''$RECOMMENDATION_PROMPT" 2>&1 | while IFS= read -r line; do log "  ''$line"; done; then
        log "WARNING: opencode-launch failed (non-zero exit); recommendation session not started"
      fi
    fi

    log "reset-workspace complete"
  '';
}
