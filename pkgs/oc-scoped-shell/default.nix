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

      # Probe scope creation first, bounded (~2s). Probe BEFORE exec so the payload
      # still runs EXACTLY ONCE — a shell-level `systemd-run ... || bash ...` cannot
      # distinguish "scope failed to start" from "payload exited non-zero" and would run
      # a failing command twice. That single-execution property is load-bearing.
      if "$SYSTEMD_RUN" --user --scope --collect --quiet --unit="oc-scoped-shell-probe-$$-$RANDOM" -- true 2>/dev/null; then
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

      # On probe failure: warn on stderr that command is running UNSCOPED inside serve cgroup,
      # then exec <bash> "$@" (fail open — refusing would brick every agent).
      echo "oc-scoped-shell: WARNING: systemd-run --user is unusable (full ''${XDG_RUNTIME_DIR}, or no user manager)." >&2
      echo "oc-scoped-shell: WARNING: running command UNSCOPED inside serve cgroup." >&2

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
