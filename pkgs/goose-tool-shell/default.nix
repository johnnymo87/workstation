# The shell goose-serve's developer extension runs every tool command through
# (GOOSE_SHELL on the goose-serve unit, both hosts). Bead workstation-pp9r.4.
#
# WHY: every goose tool shell is a child in goose-serve's own cgroup, so a
# command that pushes the unit to its MemoryMax makes the kernel pick an OOM
# victim from goose AND its shells together. It picks the highest badness, which
# is roughly RSS, so a many-worker job (cargo, make -j, vitest) whose workers are
# each smaller than goose (~0.9G) gets goose itself killed -- and with it every
# goose turn on the host, the stall-watch coordinators included.
#
# WHAT: raise this process's oom_score_adj to a floor, then exec the real bash.
# oom_score_adj is inherited across fork, so the command and everything it
# spawns carry the floor. Badness adds adj * (cgroup limit) / 1000, so at 500
# every shell descendant outranks goose (adj 0) by half the cap's worth of
# pages: 7G-equivalent at cloudbox's 14G, 3G at devbox's 6G -- more than goose's
# whole RSS, whatever size the descendant is. The unit's OOMScoreAdjust cannot do
# this, because goose's children inherit it.
#
# Named `bin/bash`, not something descriptive, ON PURPOSE: goose tells the model
# "Commands run under `<file name of GOOSE_SHELL>`" in the shell tool's
# description. Keeping it `bash` keeps that text, and so the prompt cache,
# byte-identical. `exec -a bash` keeps the shell's $0 what it was, and `exec`
# keeps the pid, which goose's process-group kill (fork patch 4) relies on.
#
# NOT a BASH_ENV hook: in the unit's environment that would also run in
# goose-serve-start (a bash script) before it execs goose, raising goose itself,
# and in every bash any child ever starts, MCP extension wrappers included.
{ pkgs
, lib ? pkgs.lib
  # The bash goose ran before this wrapper existed: `bash` resolved on the
  # unit's PATH, which leads with config.system.path, i.e. bashInteractive.
, bash ? pkgs.bashInteractive
, oomScoreAdjFloor ? 500
  # PER-COMMAND SCOPES (bead workstation-6w7i.7). null = the pp9r.4 behaviour
  # only (raise oom_score_adj, exec bash in the caller's cgroup); that is what
  # devbox's opencode `shell` uses, since devbox's serves have no agent slice.
  # A slice name = also run each command in its own transient user scope under
  # that slice, the way pkgs/oc-scoped-shell does for opencode on cloudbox, so
  # a tool command's memory is charged to (and capped in) its own scope instead
  # of goose-serve's cgroup. The slice MUST ship as a capped unit (see
  # lib/goose-agent.nix and flake check goose-agent-slice-wiring).
, sliceName ? null
, scopeMemoryMax ? "10G"
, scopeMemorySwapMax ? "2G"
, systemd ? pkgs.systemd
}:

let
  scoped = sliceName != null;
  wrapper = pkgs.writeShellApplication {
    name = "goose-tool-shell";
    runtimeInputs = [ ];
    text = ''
      REAL_BASH="${bash}/bin/bash"
      OOM_SCORE_ADJ_FLOOR="${toString oomScoreAdjFloor}"
      SYSTEMD_RUN="${systemd}/bin/systemd-run"
      SLICE_NAME="${if scoped then sliceName else ""}"
      SCOPE_MEMORY_MAX="${scopeMemoryMax}"
      SCOPE_MEMORY_SWAP_MAX="${scopeMemorySwapMax}"

      # RAISE ONLY, never lower: a caller that already asked to be killed
      # first should stay that way. Never fatal and never noisy: any output
      # here would be prepended to every tool call's output.
      #
      # Not a guarantee: an unprivileged descendant may lower its own value
      # again, down to oom_score_adj_min (0 for goose-serve), and then it
      # competes with goose on size alone, as before this wrapper.
      #
      # Consequence: if goose-serve is ever given OOMScoreAdjust >= the floor,
      # this no-ops and goose ties with its shells again. Keep the unit below it.
      cur_adj=""
      if { read -r cur_adj < /proc/self/oom_score_adj; } 2>/dev/null \
        && [ "$cur_adj" -lt "$OOM_SCORE_ADJ_FLOOR" ] 2>/dev/null; then
        { echo "$OOM_SCORE_ADJ_FLOOR" > /proc/self/oom_score_adj; } 2>/dev/null || true
      fi

      if [ -n "$SLICE_NAME" ]; then
        # goose-serve is a SYSTEM unit (User=dev) and its environment has no
        # XDG_RUNTIME_DIR, which `systemd-run --user` needs to find dev's user
        # manager. Measured: from a system unit running as dev, a --user
        # --scope works -- the user manager has PID1 migrate the pid -- once
        # this is set. $UID is a bash builtin.
        if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
          XDG_RUNTIME_DIR="/run/user/''${UID}"
          export XDG_RUNTIME_DIR
        fi

        # Probe first, bounded, exactly as pkgs/oc-scoped-shell does and for
        # its reasons: the payload must run EXACTLY ONCE (a `systemd-run ... ||
        # bash ...` cannot tell "no scope" from "command failed" and would run
        # a failing command twice), and a wedged user bus must cost 3s, not
        # sd-bus's 25s default, per command.
        if ${pkgs.coreutils}/bin/timeout -k 1 3 \
          "$SYSTEMD_RUN" --user --scope --collect --quiet \
          --unit="goose-agent-probe-$$-$RANDOM" -- true 2>/dev/null; then
          # exec in place: same pid, same process group, so goose's
          # process-group kill (fork patch) still reaches the command.
          # --unit=: never an auto run-pNNN name, which a nested systemd-run
          #   (the bazel shim) could collide with (workstation-yt0p).
          # --expand-environment=no: systemd would otherwise expand $$ and
          #   ''${VAR} in the payload before bash sees it.
          # OOMPolicy=continue: explicit; a scope defaults to `stop`.
          # The payload is a trampoline so the command still sees $0 == bash,
          # as it did before scoping (systemd-run cannot set argv[0]).
          # shellcheck disable=SC2016 # expanded by the payload bash, on purpose
          exec "$SYSTEMD_RUN" --user --scope --collect --quiet \
            --unit="goose-agent-$$-$RANDOM" \
            -p MemoryMax="$SCOPE_MEMORY_MAX" \
            -p MemorySwapMax="$SCOPE_MEMORY_SWAP_MAX" \
            -p OOMPolicy=continue \
            --expand-environment=no \
            --slice="$SLICE_NAME" \
            -- "$REAL_BASH" -c 'exec -a bash "$0" "$@"' "$REAL_BASH" "$@"
        fi

        # Fail open, loudly, in ONE line: goose returns stdout+stderr as the
        # tool result, so this is prepended to every command's output for as
        # long as the degrade lasts. The command still runs at the floor, in
        # goose-serve's cgroup, which is exactly the pre-6w7i.7 behaviour.
        echo "goose-tool-shell: WARNING: systemd-run --user unusable (wedged/full ''${XDG_RUNTIME_DIR}, or no user manager); running UNSCOPED in goose-serve's cgroup" >&2
      fi

      exec -a bash "$REAL_BASH" "$@"
    '';
  };
in
pkgs.runCommand "goose-tool-shell"
{
  meta = {
    description = "bash for goose tool commands: oom_score_adj raised so the OOM killer prefers them to goose, optionally each in its own capped user scope";
    platforms = lib.platforms.linux;
  };
} ''
  mkdir -p $out/bin
  ln -s ${wrapper}/bin/goose-tool-shell $out/bin/bash
''
