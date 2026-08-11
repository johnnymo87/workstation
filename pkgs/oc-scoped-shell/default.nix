{ pkgs
, lib ? pkgs.lib
, bash ? pkgs.bash
, systemd ? pkgs.systemd
, scopeMemoryMax ? "10G"
, scopeMemorySwapMax ? "2G"
, scopeOOMPolicy ? "continue"
, sliceName ? "oc-agent"
}:

let
  wrapper = pkgs.writeShellApplication {
    name = "oc-scoped-shell";

    runtimeInputs = [ ];

    text = ''
      REAL_BASH="${bash}/bin/bash"
      SYSTEMD_RUN="${systemd}/bin/systemd-run"
      SCOPE_MEMORY_MAX="${scopeMemoryMax}"
      SCOPE_MEMORY_SWAP_MAX="${scopeMemorySwapMax}"
      SCOPE_OOM_POLICY="${scopeOOMPolicy}"
      SLICE_NAME="${sliceName}"

      # Set XDG_RUNTIME_DIR to /run/user/<uid> when unset.
      # MEASURED: this is UNSET in the bash environment under `opencode serve`
      # (opencode's bash tool does not inherit a login session's runtime dir).
      # `systemd-run --user` needs it to find the user manager's bus socket and
      # fails with "Failed to connect to user scope bus" without it. $UID is a bash builtin.
      if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
        XDG_RUNTIME_DIR="/run/user/''${UID}"
        export XDG_RUNTIME_DIR
      fi

      # Probe scope creation first. Probe BEFORE exec so the payload still runs
      # EXACTLY ONCE — a shell-level `systemd-run ... || bash ...` cannot distinguish
      # "scope failed to start" from "payload exited non-zero" and would run a failing
      # command twice. That single-execution property is load-bearing.
      #
      # The probe MUST be externally bounded. `systemd-run` blocks on an sd-bus method
      # reply whose default timeout is 25s, and "alive but frozen" is a documented
      # failure mode of this box (see the monitoring-serve-pool skill). Unbounded, a
      # wedged user bus would stall EVERY bash tool call for ~25s -- and unlike the
      # plugin this replaced, there is no cross-command cache to amortise it, so the
      # stall would repeat per command until the bus recovered. Tool calls with short
      # timeouts would fail outright with no output. 3s is far above the measured 9ms
      # cost of a healthy scope creation.
      #
      # `timeout` is an absolute store path on purpose: runtimeInputs is deliberately
      # empty so the payload sees an unmodified PATH, and this must not depend on it.
      if ${pkgs.coreutils}/bin/timeout -k 1 3 \
        "$SYSTEMD_RUN" --user --scope --collect --quiet --unit="oc-scoped-shell-probe-$$-$RANDOM" -- true 2>/dev/null; then
        # On probe success: exec into systemd-run.
        # - --unit=: explicit unit name that can never match `run-p*`, because --scope execs
        #   in place and a NESTED systemd-run (the bazel shim) can otherwise inherit
        #   the PID that named the outer scope and collide.
        # - --expand-environment=no: systemd otherwise expands the payload ($$ collapses to $
        #   and ''${VAR} is substituted or errors).
        # - -p MemoryMax / MemorySwapMax: node and the JVM size themselves against the host's 62G
        #   if the scope is uncapped.
        # - -p OOMPolicy=continue: set EXPLICITLY; measured on systemd 258.7 a scope defaults to
        #   `stop`, which is the very behaviour being removed.
        # - --slice=oc-agent: must name a slice that actually SHIPS; if it does not, systemd
        #   silently creates an uncapped transient slice of that name.
        exec "$SYSTEMD_RUN" --user --scope --collect --quiet \
          --unit="oc-agent-$$-$RANDOM" \
          -p MemoryMax="$SCOPE_MEMORY_MAX" \
          -p MemorySwapMax="$SCOPE_MEMORY_SWAP_MAX" \
          -p OOMPolicy="$SCOPE_OOM_POLICY" \
          --expand-environment=no \
          --slice="$SLICE_NAME" \
          -- "$REAL_BASH" "$@"
      fi

      # On probe failure: warn, then exec <bash> "$@" (fail open — refusing would brick
      # every agent on the host to avoid a risk serve-canary already backstops).
      #
      # ONE line, deliberately. opencode merges the tool's stdout and stderr into a
      # single output string, so anything emitted here is prepended to EVERY command's
      # output for as long as the degrade lasts -- which breaks callers that parse
      # command output (jq, JSON) at exactly the moment the host is already sick.
      # Staying loud is still right (the plugin's failure was logging where no session
      # could see it), but the noise is kept to the minimum that names the condition.
      echo "oc-scoped-shell: WARNING: systemd-run --user unusable (wedged/full ''${XDG_RUNTIME_DIR}, or no user manager); running UNSCOPED in the serve cgroup" >&2

      exec "$REAL_BASH" "$@"
    '';
  };

in
pkgs.runCommand "oc-scoped-shell"
{
  meta = {
    description = "Bash wrapper that executes commands inside a systemd scope via systemd-run";
    platforms = lib.platforms.linux;
  };
} ''
  mkdir -p $out/bin
  ln -s ${wrapper}/bin/oc-scoped-shell $out/bin/oc-scoped-shell
''
