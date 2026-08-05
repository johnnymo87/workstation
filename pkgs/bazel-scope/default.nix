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
# it in /user.slice/.../user@1000.service/bazel.slice/run-pNNN.scope -- a
# different cgroup subtree from /system.slice/system-opencode\x2dserve.slice/...
# A memcg OOM in the build can no longer reach the serve. Two levels of cap:
# per-scope (this file) bounds one workspace; bazel.slice (declared in
# users/dev/home.cloudbox.nix) bounds the aggregate.
#
# The per-scope cap must be sized for a WHOLE BUILD, not for one client process:
# bazel's client forks a long-lived server JVM, and the server -- not the client
# -- spawns every action, worker and sandbox. So the first invocation's scope is
# where ~all of a workspace's build memory lands, and later invocations against
# the same warm server contribute to THAT scope while their own stays near-empty.
# Lopsided per-scope accounting in systemd-cgtop is therefore expected, not a leak.
{ pkgs
  # Whole-build budget for one workspace. Capped worst case with the bazelrc
  # limits in force: server JVM ~2.5-3G (-Xmx2g plus metaspace/JIT/threads) +
  # persistent workers <=2.5G + local actions <=4G (--local_resources=memory=4096)
  # + bazel-out/misc ~0.5G ~= 9.5G. 8G kills routine builds; 10G clears the worst
  # case and still sits under the serve's own 14G.
, scopeMemoryMax ? "10G"
  # Aggregate slice. Kept as an argument so the caller that declares the slice
  # and the caller that sets the scope cap cannot drift apart silently.
, sliceName ? "bazel"
}:

pkgs.writeShellApplication {
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

    # ---- 1. Loop guard -------------------------------------------------------
    # A `bazel run` target that itself calls bazel would otherwise nest a scope
    # per level. The guard is inherited by children; the PID is not, but we only
    # need "am I already inside a shim-created scope".
    if [ "''${BAZEL_SCOPE_SHIM_ACTIVE:-}" = "1" ]; then
      exec "$REAL_BAZEL" "$@"
    fi
    export BAZEL_SCOPE_SHIM_ACTIVE=1

    # ---- 2. XDG_RUNTIME_DIR --------------------------------------------------
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

    # ---- 3. Canary -----------------------------------------------------------
    # Creating a transient unit can fail even when systemd-run and the user
    # manager are healthy -- most notably when the runtime tmpfs (/run/user/$UID)
    # is FULL, since systemd serialises every transient unit there before loading
    # it, and ENOSPC surfaces as the misleading "Failed to start transient scope
    # unit: ... not found". Probe with a throwaway scope before committing, so a
    # failure degrades instead of taking the build out. Same shape as
    # pkgs/reset-workspace/default.nix.
    #
    # NOTE the ordering: we must NOT `exec` the probe, or a systemd-run that
    # starts and then exits non-zero becomes our exit code and the fallback below
    # turns into dead code. reset-workspace shipped exactly that bug once.
    if "$SYSTEMD_RUN" --user --scope --collect --quiet -- true 2>/dev/null; then
      # --collect: GC the scope once it empties. The scope outlives this client
      #   by design -- the server JVM stays in it until --max_idle_secs (900s).
      # No --unit=: the auto-generated run-pNNN.scope name is unique by
      #   construction. A stable per-workspace name would COLLIDE with the still
      #   -alive scope of the resident server on the very next build, and
      #   systemd-run cannot join an existing scope.
      # -p MemoryMax: MANDATORY. The JVM is container-aware, so an uncapped scope
      #   would size its heap against the host's 62G instead of the cgroup --
      #   strictly worse than no shim at all.
      # -p OOMPolicy=continue: set EXPLICITLY. Measured on systemd 258, a scope
      #   defaults to OOMPolicy=stop (the "scopes default to continue" folklore
      #   is wrong), which tears the whole scope down -- warm server JVM included
      #   -- when one sandboxed action is OOM-killed. With continue, bazel just
      #   reports that action as failed, which is a far better diagnostic and
      #   keeps the server warm for the next build.
      exec "$SYSTEMD_RUN" --user --scope --collect --quiet \
        --slice="$SLICE_NAME" \
        -p MemoryMax="$SCOPE_MEMORY_MAX" \
        -p OOMPolicy=continue \
        -- "$REAL_BAZEL" "$@"
    fi

    # ---- 4. Degrade ----------------------------------------------------------
    # A degraded build beats no build, so we still run it -- but this path is
    # genuinely dangerous and must not pass quietly. The server JVM this forks
    # lands in the SERVE's cgroup and lives there for max_idle_secs (900s), and
    # because the server (not the client) spawns every build action, EVERY later
    # build against this workspace would charge its memory to the serve even if
    # its own client scoped correctly. One degraded invocation would otherwise
    # re-arm the exact bug this shim exists to prevent. So: shut the server down
    # afterwards, and keep the build's own exit code rather than shutdown's.
    echo "bazel-scope-shim: WARNING: systemd-run --user is unusable (full ''${XDG_RUNTIME_DIR}, or no user manager)." >&2
    echo "bazel-scope-shim: WARNING: running bazel UNSCOPED -- it is charged to this process's cgroup." >&2
    echo "bazel-scope-shim: WARNING: if that cgroup is an opencode serve, an OOM here kills every session on it (workstation-mqp3)." >&2

    rc=0
    "$REAL_BAZEL" "$@" || rc=$?
    "$REAL_BAZEL" shutdown >/dev/null 2>&1 || true
    exit "$rc"
  '';

  meta.description = "bazel wrapped in a memory-capped systemd scope, outside the opencode serve cgroup";
}
