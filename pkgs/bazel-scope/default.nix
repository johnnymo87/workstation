# bazel scope shim -- keeps builds out of the opencode serve cgroup.
#
# THE BUG (bead workstation-mqp3, epic workstation-rdsq).
#
# The agent's bash tool spawns `bazel` as a CHILD of `opencode serve`, so every
# bazel process is charged to opencode-serve@<port>.service's cgroup and counts
# against its MemoryMax=14G. That unit is OOMPolicy=stop, so ANY OOM kill in the
# cgroup restarts the WHOLE serve and destroys every session on it.
# opencode-serve@4098 was killed that way FOUR times in ~6h on 2026-08-03/04; a
# capture 35s before the third kill showed 7.61G of the cgroup's 9.04G held by
# bazel. Those kills produced 960 HTTP 502s at the front door.
#
# WHY THE BAZELRC CAPS WERE NOT ENOUGH. --jobs=8, --local_resources,
# --local_test_jobs and -Xmx2g (all shipped, see users/dev/home.base.nix) bound a
# SINGLE INVOCATION. They stopped the kills but the cgroup still rode 13.9-14.0G
# for six minutes with bazel at 93% of anon, surviving on reclaim. Nothing in a
# bazelrc can bound the AGGREGATE across concurrent invocations, and nothing can
# remove the per-workspace server JVMs (2.4G standing across two workspaces was
# measured on one serve). Those are structural, so the fix has to be structural.
#
# WHAT THIS DOES. Re-execs bazel inside `systemd-run --user --scope`, which lands
# it in /user.slice/.../user@1000.service/<slice>/run-pNNN.scope -- a different
# cgroup subtree from /system.slice/system-opencode\x2dserve.slice/... A memcg OOM
# in the build can no longer reach the serve. Two levels of cap: per-scope (this
# file) bounds one workspace; the slice (declared in users/dev/home.cloudbox.nix)
# bounds the aggregate.
#
# The per-scope cap must be sized for a WHOLE BUILD, not for one client process:
# bazel's client forks a long-lived server JVM, and the server -- not the client
# -- spawns every action, worker and sandbox. So the first invocation's scope is
# where ~all of a workspace's build memory lands, and later invocations against
# the same warm server contribute to THAT scope while their own stays near-empty.
# Lopsided per-scope accounting in systemd-cgtop is therefore expected, not a leak.
{ pkgs
, lib ? pkgs.lib
  # Whole-build budget for one workspace. Capped worst case with the bazelrc
  # limits in force: server JVM ~2.5-3G (-Xmx2g plus metaspace/JIT/threads) +
  # persistent workers <=2.5G + local actions <=4G (--local_resources=memory=4096)
  # + bazel-out/misc ~0.5G ~= 9.5G. 8G kills routine builds; 10G clears the worst
  # case and still sits under the serve's own 14G.
, scopeMemoryMax ? "10G"
  # Name of the parent slice passed to `systemd-run --slice=`.
  #
  # THE CALLER MUST PASS THIS EXPLICITLY and use the same value to declare the
  # slice unit. The default here is a convenience for `nix build .#bazel-scope`,
  # NOT a coordination mechanism: if this and the declared slice ever disagree,
  # systemd-run silently creates a transient slice of that name with NO limits,
  # the aggregate cap vanishes, and nothing goes red until the host OOMs. See the
  # `bazelSliceName` binding in users/dev/home.cloudbox.nix, which is the single
  # source of truth, and the generation check in flake.nix that asserts the shim's
  # --slice= names a slice unit that actually ships.
, sliceName ? "bazel"
  # Concurrency gate (bead workstation-o5s1.19): how many build/test/coverage
  # invocations may run at once, host-wide. See the gate section of the script
  # for what it bounds and, as importantly, what it does not. The caller sizes
  # this against the slice cap; the default is only for `nix build`.
, maxConcurrentBuilds ? 2
  # How long a gated invocation waits for a slot before running anyway, loudly.
, gateMaxWaitSecs ? 1800
}:

assert lib.assertMsg (maxConcurrentBuilds >= 1) "bazel-scope: maxConcurrentBuilds must be >= 1";
assert lib.assertMsg (gateMaxWaitSecs >= 1) "bazel-scope: gateMaxWaitSecs must be >= 1";

let
  shim = pkgs.writeShellApplication {
    name = "bazel";

    # Deliberately EMPTY. Every helper is reached by absolute /nix/store path
    # below, because a shim named `bazel` that resolved `bazel` -- or systemd-run,
    # whose absence would silently disable the whole mechanism -- off PATH could
    # recurse into itself. users/dev/test-bazel-scope-shim.sh asserts both paths
    # are absolute store paths.
    runtimeInputs = [ ];

    text = ''
      REAL_BAZEL="${pkgs.bazelisk}/bin/bazelisk"
      SYSTEMD_RUN="${pkgs.systemd}/bin/systemd-run"
      SCOPE_MEMORY_MAX="${scopeMemoryMax}"
      SLICE_NAME="${sliceName}"
      FLOCK="${pkgs.util-linux}/bin/flock"
      SLEEP="${pkgs.coreutils}/bin/sleep"
      MKDIR="${pkgs.coreutils}/bin/mkdir"
      SYSTEMD_CAT="${pkgs.systemd}/bin/systemd-cat"
      GATE_SLOTS="${toString maxConcurrentBuilds}"
      GATE_MAX_WAIT_SECS="${toString gateMaxWaitSecs}"
      GATE_POLL_SECS="2"
      # Filesystem roots, named so the test can point them at a fixture tree.
      # There is deliberately no env-var override: the SHIPPED script must have no
      # branch a caller could use to escape the scope or skip the cleanup.
      PROC_ROOT="/proc"
      CGROUP_ROOT="/sys/fs/cgroup"

      # True when a bazel SERVER process is resident in this process's own
      # cgroup. Used only on the degrade path (step 4) -- see the rationale there.
      #
      # Identifies the server by argv[0], which bazel rewrites to `bazel(<name>)`
      # for the server JVM. Cheap, needs no workspace, and takes no client lock.
      bazel_server_in_own_cgroup() {
        local cg procs pid cmd
        cg=$(cut -d: -f3 "$PROC_ROOT/self/cgroup" 2>/dev/null | head -n1) || return 1
        [ -n "$cg" ] || return 1
        procs="$CGROUP_ROOT$cg/cgroup.procs"
        [ -r "$procs" ] || return 1
        while read -r pid; do
          [ -n "$pid" ] || continue
          cmd=$(tr '\0' ' ' < "$PROC_ROOT/$pid/cmdline" 2>/dev/null) || continue
          case "$cmd" in
            'bazel('*) return 0 ;;
          esac
        done < "$procs"
        return 1
      }

      # ---- 1. Loop guard -----------------------------------------------------
      # A `bazel run` target that itself calls bazel would otherwise nest a scope
      # per level.
      #
      # This guard is best-effort, and deliberately so. Bazel SCRUBS the
      # environment of actions and tests, so a test that shells out to bazel will
      # NOT see this variable and will open a scope of its own. That is benign --
      # the new scope still lands in the same capped slice -- but do not read this
      # guard as a hard guarantee of one-scope-per-build. Such a nested build also
      # queues for a gate slot (step 2b), which is why that gate cannot block
      # forever.
      if [ "''${BAZEL_SCOPE_SHIM_ACTIVE:-}" = "1" ]; then
        exec "$REAL_BAZEL" "$@"
      fi
      export BAZEL_SCOPE_SHIM_ACTIVE=1

      # ---- 2. XDG_RUNTIME_DIR ------------------------------------------------
      # MEASURED: this is UNSET in the bash environment under `opencode serve`
      # (opencode's bash tool does not inherit a login session's runtime dir).
      # `systemd-run --user` needs it to find the user manager's bus socket and
      # fails with "Failed to connect to user scope bus" without it. Omit this and
      # EVERY build takes the degrade path below -- the shim would look installed
      # and do nothing. $UID is a bash builtin, so this needs no external binary.
      if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
        XDG_RUNTIME_DIR="/run/user/''${UID}"
        export XDG_RUNTIME_DIR
      fi
      # ---- 2b. Concurrency gate (bead workstation-o5s1.19) --------------------
      #
      # WHY. bazel.slice (16G, users/dev/home.cloudbox.nix) was sized for ONE
      # active build plus idle servers. On 2026-09-15 five-plus workspaces built
      # at once, the slice sat at its cap with anon ~16.6G and file cache down to
      # ~300M, re-reading its own outputs at ~270 MB/s for ~2.5h and OOM-killing
      # JVMs intermittently. Pressure-sampler rows 2026-09-10..26: in samples
      # where slice anon exceeded 13G, 2-5 scopes were actively burning CPU at
      # ~3.7G anon each. The slice cap cannot fix that -- it only decides who
      # dies -- so this bounds the NUMBER of concurrent builds instead.
      #
      # WHAT IT BOUNDS. At most GATE_SLOTS build/test/coverage CLIENTS run at once
      # host-wide. A slot is an flock on $GATE_DIR/slot.N.
      #
      # WHO HOLDS THE LOCK. Not this shell: it must still `exec` into the scope,
      # so that the bazel client keeps THIS pid and every signal aimed at it
      # (kill <pid>, a tool timeout, Ctrl-C) reaches the client exactly as it did
      # before the gate existed. Instead a tiny WATCHER subshell inherits the
      # slot fd and holds it while pid $$ is alive -- and $$ survives the exec,
      # so the watcher is really watching the client. This shell then closes its
      # own copy of the fd, so nothing it execs can pass the slot on to a server
      # JVM, which would otherwise hold it for max_idle_secs after the build.
      # Release lags the client's exit by at most one watcher poll (1s).
      #
      # FAIRNESS. Waiters queue on $GATE_DIR/turnstile first, and only the one
      # holding it polls for a slot. Without that, a newcomer arriving as a slot
      # frees has the same odds as a build that has waited 25 minutes, and under
      # exactly the sustained swarm load this gate is for, old waiters starve
      # into the overflow below.
      #
      # WHAT IT DOES NOT BOUND, and the gaps are deliberate:
      #   * Idle server JVMs. A workspace's server outlives its build for
      #     --max_idle_secs (900s) at ~2.35G anon (sampler mean), holding no slot.
      #   * Other commands. query/cquery/info/fetch are ungated. `run` is ungated
      #     because its client EXECS the target in place: a slot would be held for
      #     as long as the target runs, which for a dev server is forever. So the
      #     BUILD half of a `bazel run` is ungated too -- a known hole.
      #   * A client killed without its server being told (SIGKILL of the agent's
      #     process group) leaves the server finishing the build slot-less.
      #   * Two clients of ONE workspace each take a slot, though bazel runs them
      #     one at a time on that workspace's server.
      #
      # WAIT, THEN RUN ANYWAY. After GATE_MAX_WAIT_SECS a waiter proceeds
      # ungated, loudly, and logs `overflow` to the journal. Blocking forever is
      # worse: a test that shells out to bazel gets a SCRUBBED environment, so
      # the loop guard above cannot see it. Such a test is recognised instead by
      # its cgroup (it runs inside a bazel.slice scope) and skips the gate.
      # Verified 2026-09-26: a genrule action here (processwrapper-sandbox;
      # linux-sandbox is not registered on this host) read
      # 0::/user.slice/.../bazel.slice/run-pNNN.scope from /proc/self/cgroup. A
      # sandbox with its own cgroup namespace would hide that, and the timeout
      # is the backstop for that case. Same
      # philosophy as the degrade path below: a degraded build beats no build,
      # but never a quiet one.
      #
      # THE DIRECTORY is pinned to /run/user/$UID rather than following the
      # caller's XDG_RUNTIME_DIR: the gate is host-wide by intent, and a caller
      # with an odd XDG_RUNTIME_DIR must not get a private gate of its own.
      #
      # EVENTS go to the user journal: journalctl --user -t bazel-gate. The
      # workstation-o5s1.10 decision is waiting on exactly that data.
      GATE_DIR="/run/user/''${UID}/bazel-gate"
      GATE_FD=""
      GATE_SLOT=""
      GATE_CMD=""

      gate_log() {
        printf '%s\n' "$*" | "$SYSTEMD_CAT" -t bazel-gate 2>/dev/null || true
      }

      # The bazel command: the first argument that is not a startup option.
      # A startup option written with a SEPARATE value (`--output_base /x`) makes
      # this return the value, which matches no gated command and so fails OPEN
      # (ungated, as before this gate existed), never closed.
      bazel_command() {
        local a
        for a in "$@"; do
          case "$a" in
            -*) continue ;;
            *) printf '%s' "$a"; return 0 ;;
          esac
        done
        return 0
      }

      # True when this process already runs inside a bazel.slice scope, i.e. it
      # was spawned by a build (a test or action that shells out to bazel). The
      # outer build holds a slot already; waiting for another could deadlock.
      inside_bazel_slice() {
        local cg
        { cg=$(< "$PROC_ROOT/self/cgroup"); } 2>/dev/null || return 1
        case "$cg" in
          *"/$SLICE_NAME.slice/"*) return 0 ;;
        esac
        return 1
      }

      # 0 = got a slot (GATE_FD/GATE_SLOT set), 1 = all busy, 2 = cannot open.
      gate_try_acquire() {
        local j i fd start
        start=$((RANDOM % GATE_SLOTS))
        for ((j = 0; j < GATE_SLOTS; j++)); do
          i=$(( (start + j) % GATE_SLOTS ))
          # <> opens without truncating, and creates the file if missing.
          # The braces matter: `exec {fd}<>f 2>/dev/null` would apply the
          # 2>/dev/null to THIS SHELL permanently and swallow bazel's stderr.
          { exec {fd}<>"$GATE_DIR/slot.$i"; } 2>/dev/null || return 2
          if "$FLOCK" -n "$fd" 2>/dev/null; then
            GATE_FD=$fd
            GATE_SLOT=$i
            printf 'pid=%s since=%(%F %T)T cmd=%s cwd=%s\n' "$$" -1 "$GATE_CMD" "$PWD" \
              > "$GATE_DIR/slot.$i.info" 2>/dev/null || true
            return 0
          fi
          exec {fd}>&-
        done
        return 1
      }

      # Hand the slot to a watcher of $$, then drop this shell's copy.
      gate_handoff() {
        local holder=$$
        (
          # stdio to /dev/null: the watcher must not hold the caller's pipes
          # open, or a caller waiting for EOF waits on the watcher too.
          while kill -0 "$holder" 2>/dev/null; do
            "$SLEEP" 1 {GATE_FD}>&-
          done
        ) </dev/null >/dev/null 2>&1 &
        exec {GATE_FD}>&-
        GATE_FD=""
      }

      # Last recorded holder of each slot whose recorded pid is still alive.
      gate_holders() {
        local f line pid
        for f in "$GATE_DIR"/slot.*.info; do
          [ -r "$f" ] || continue
          line=$(< "$f") || continue
          pid=''${line#pid=}; pid=''${pid%% *}
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            printf 'bazel-scope-shim:   %s\n' "$line"
          fi
        done
      }

      gate_ungated() { # gate_ungated <reason>
        echo "bazel-scope-shim: WARNING: running WITHOUT the concurrency gate ($1; workstation-o5s1.19)." >&2
        gate_log "ungated reason=$1 cmd=$GATE_CMD cwd=$PWD"
      }

      gate_waiting() { # gate_waiting <verb>
        echo "bazel-scope-shim: $1 for a build slot ($((SECONDS - started))s so far): at most $GATE_SLOTS builds run at once on this host, to keep bazel.slice out of memory thrash (workstation-o5s1.19). Held by:" >&2
        gate_holders >&2
      }

      gate_enter() {
        local started=$SECONDS tfd rc remaining next_report announced=0
        if ! "$MKDIR" -p "$GATE_DIR" 2>/dev/null; then
          gate_ungated "cannot create $GATE_DIR"
          return 0
        fi
        if ! { exec {tfd}<>"$GATE_DIR/turnstile"; } 2>/dev/null; then
          gate_ungated "cannot open $GATE_DIR/turnstile"
          return 0
        fi

        # Queue. Uncontended, this is one non-blocking flock. The quiet 2s grace
        # covers a peer that holds the turnstile only for its own instant
        # acquisition, so simultaneous starts do not all print a wait notice.
        if ! "$FLOCK" -n "$tfd" 2>/dev/null && ! "$FLOCK" -w 2 "$tfd" 2>/dev/null; then
          gate_waiting "waiting in line"
          gate_log "wait cmd=$GATE_CMD cwd=$PWD"
          announced=1
          while :; do
            remaining=$((GATE_MAX_WAIT_SECS - (SECONDS - started)))
            if (( remaining <= 0 )); then
              exec {tfd}>&-
              gate_overflow
              return 0
            fi
            if "$FLOCK" -w "$(( remaining < 300 ? remaining : 300 ))" "$tfd" 2>/dev/null; then
              break
            fi
            (( SECONDS - started >= GATE_MAX_WAIT_SECS )) || gate_waiting "still waiting in line"
          done
        fi

        # Head of the line: wait for a slot.
        next_report=$((SECONDS + 300))
        while :; do
          rc=0
          gate_try_acquire || rc=$?
          if (( rc == 0 )); then
            exec {tfd}>&-
            if (( announced )); then
              echo "bazel-scope-shim: got build slot $GATE_SLOT after $((SECONDS - started))s." >&2
            fi
            gate_log "acquired slot=$GATE_SLOT waited=$((SECONDS - started)) cmd=$GATE_CMD cwd=$PWD"
            gate_handoff
            return 0
          fi
          if (( rc == 2 )); then
            exec {tfd}>&-
            gate_ungated "cannot open a slot file in $GATE_DIR"
            return 0
          fi
          if (( ! announced )); then
            gate_waiting "waiting"
            gate_log "wait cmd=$GATE_CMD cwd=$PWD"
            announced=1
          fi
          if (( SECONDS - started >= GATE_MAX_WAIT_SECS )); then
            exec {tfd}>&-
            gate_overflow
            return 0
          fi
          "$SLEEP" "$GATE_POLL_SECS" {tfd}>&-
          if (( SECONDS >= next_report )); then
            gate_waiting "still waiting"
            next_report=$((next_report + 300))
          fi
        done
      }

      gate_overflow() {
        echo "bazel-scope-shim: WARNING: no build slot after $((SECONDS - started))s; running UNGATED. If many builds are doing this, bazel.slice is about to thrash." >&2
        gate_log "overflow waited=$((SECONDS - started)) cmd=$GATE_CMD cwd=$PWD"
      }

      GATE_CMD=$(bazel_command "$@")
      case "$GATE_CMD" in
        build|test|coverage)
          if inside_bazel_slice; then
            gate_log "nested cmd=$GATE_CMD cwd=$PWD"
          else
            gate_enter
          fi
          ;;
      esac

      # ---- 3. Canary ---------------------------------------------------------
      # Creating a transient unit can fail even when systemd-run and the user
      # manager are healthy -- most notably when the runtime tmpfs
      # (/run/user/$UID) is FULL, since systemd serialises every transient unit
      # there before loading it, and ENOSPC surfaces as the misleading "Failed to
      # start transient scope unit: ... not found". Probe with a throwaway scope
      # before committing, so a failure degrades instead of taking the build out.
      # Same shape as pkgs/reset-workspace/default.nix.
      #
      # NOTE the ordering: we must NOT `exec` the probe, or a systemd-run that
      # starts and then exits non-zero becomes our exit code and the fallback
      # below turns into dead code. reset-workspace shipped exactly that bug once.
      #
      # If the canary passes but the real invocation fails, we do NOT fall back:
      # that failure is loud (systemd-run's own exit code and stderr), and a
      # silent unscoped build is precisely what this shim exists to prevent.
      if "$SYSTEMD_RUN" --user --scope --collect --quiet -- true 2>/dev/null; then
        # --collect: GC the scope once it empties. The scope outlives this client
        #   by design -- the server JVM stays in it until --max_idle_secs (900s).
        # No --unit=: the auto-generated run-pNNN.scope name is unique ENOUGH
        #   here. A stable per-workspace name would COLLIDE with the still-alive
        #   scope of the resident server on the very next build, and systemd-run
        #   cannot join an existing scope.
        #   CAVEAT, learned in workstation-yt0p: "unique by construction" is
        #   false once this shim runs INSIDE another scope. The auto name is
        #   derived from systemd-run's own PID, and because --scope execs in
        #   place (and `bash -c` exec-optimizes a final simple command) the inner
        #   systemd-run can inherit the very PID that named the outer scope,
        #   failing with "Unit run-pNNN.scope was already loaded". The oc-scoped-shell
        #   wrapper therefore names ITS scopes `oc-agent-*` so this one still
        #   works; do not "simplify" that back to an auto name.
        # -p MemoryMax: MANDATORY. The JVM is container-aware, so an uncapped
        #   scope would size its heap against the host's 62G instead of the cgroup
        #   -- strictly worse than no shim at all.
        # -p OOMPolicy=continue: set EXPLICITLY. Measured on systemd 258, a scope
        #   defaults to OOMPolicy=stop (the "scopes default to continue" folklore
        #   is wrong), which tears the whole scope down -- warm server JVM
        #   included -- when one sandboxed action is OOM-killed. With continue,
        #   bazel just reports that action as failed, which is a far better
        #   diagnostic and keeps the server warm for the next build.
        # --expand-environment=no: systemd otherwise EXPANDS the argv it is
        #   handed, which CORRUPTS bazel arguments. Measured:
        #     systemd-run --user --scope -q -- printf '%s\n' 'both=$$ and ''${FOO}'
        #     both=$ and
        #   i.e. `$$` collapses to `$` and `''${...}` is substituted or errors.
        #   Any bazel flag or target pattern containing those was silently
        #   mangled before this flag was added (workstation-yt0p).
        exec "$SYSTEMD_RUN" --user --scope --collect --quiet \
          --expand-environment=no \
          --slice="$SLICE_NAME" \
          -p MemoryMax="$SCOPE_MEMORY_MAX" \
          -p OOMPolicy=continue \
          -- "$REAL_BAZEL" "$@"
      fi

      # ---- 4. Degrade --------------------------------------------------------
      # A degraded build beats no build, so we still run it -- but this path is
      # genuinely dangerous and must not pass quietly.
      echo "bazel-scope-shim: WARNING: systemd-run --user is unusable (full ''${XDG_RUNTIME_DIR}, or no user manager)." >&2
      echo "bazel-scope-shim: WARNING: running bazel UNSCOPED -- it is charged to this process's cgroup." >&2
      echo "bazel-scope-shim: WARNING: if that cgroup is an opencode serve, an OOM here kills every session on it (workstation-mqp3)." >&2

      rc=0
      "$REAL_BAZEL" "$@" || rc=$?

      # A degraded build may fork a server JVM into OUR cgroup, where it then
      # lives for max_idle_secs (900s). Because the server -- not the client --
      # spawns build actions, that one lingering server would charge EVERY later
      # build of this workspace to our cgroup even if those clients scoped
      # correctly. So it has to go.
      #
      # But shutting down unconditionally does real damage: if this workspace's
      # server already lives in a proper scope (the common case -- the degrade
      # trigger is a transient full /run/user, not a permanent condition), an
      # unconditional `bazel shutdown` throws away a healthy warm server and its
      # analysis cache for no benefit, and on a big workspace that is minutes of
      # re-analysis. `bazel version` would be worse still: it would fork a JVM
      # purely so we could kill it.
      #
      # So look before leaping: shut down only when a bazel SERVER is actually
      # resident in our own cgroup. The server renames itself to `bazel(<name>)`,
      # which is how it was identified in the original captures, so this needs no
      # bazel invocation, no workspace, and takes no client lock.
      #
      # --noblock_for_lock: never wait on a peer's client lock. Without it a
      # concurrent build of the same workspace makes this block silently (output
      # is discarded) after the build has already finished.
      if bazel_server_in_own_cgroup; then
        echo "bazel-scope-shim: shutting down the bazel server left in this cgroup by the unscoped build." >&2
        "$REAL_BAZEL" --noblock_for_lock shutdown >/dev/null 2>&1 || true
      fi

      exit "$rc"
    '';
  };

in
pkgs.runCommand "bazel-scope"
{
  meta = {
    description = "bazel wrapped in a memory-capped systemd scope, outside the opencode serve cgroup";
    # systemd is Linux-only, and so is the whole premise (cgroups). Without this,
    # the flake's `packages.<system>` filter lets this into the darwin package set
    # and `nix eval .#packages.aarch64-darwin.bazel-scope` fails the entire flake.
    platforms = lib.platforms.linux;
  };
} ''
  mkdir -p $out/bin
  ln -s ${shim}/bin/bazel $out/bin/bazel
  # bazelisk resolves to the shim too. The real bazelisk is NOT on PATH (it is
  # reached only by store path from inside the shim), so this closes the obvious
  # bypass: anyone -- human muscle memory, a script, an agent -- typing
  # `bazelisk build` would otherwise get a completely unscoped build.
  ln -s ${shim}/bin/bazel $out/bin/bazelisk
''
