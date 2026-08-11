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
}:

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
      # guard as a hard guarantee of one-scope-per-build.
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
