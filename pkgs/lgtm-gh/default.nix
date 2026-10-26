{ pkgs, script ? "/home/dev/projects/lgtm/scripts/lgtm-gh/lgtm-gh.sh" }:

# lgtm-gh: launcher for lgtm's identity-resolving `gh` wrapper.
#
# A dispatched (headless) review session uses `lgtm-gh` instead of `gh` for any
# GitHub state-changing operation; the wrapper posts under the reviewer
# identity lgtm assigned to that worktree, and enforces lgtm's review policy.
# The wrapper itself lives in the lgtm repo (scripts/lgtm-gh/lgtm-gh.sh) and
# runs from the lgtm checkout, so it deploys when that checkout is pulled.
# This package only gives it a fixed environment:
#
#   - coreutils, gh, jq and nodejs_22 first on PATH. Dispatched sessions can
#     run under a restricted systemd PATH, and the wrapper's approval check
#     runs node under `env -i` with only node's directory on PATH, so node must
#     come from here (the same major lgtm-run uses). writeShellApplication
#     prepends these; the inherited PATH is kept after them.
#   - a pinned bash to run the script.
#
# Where there is no lgtm checkout (devbox, macOS) it refuses and runs nothing.
# Behaviour is locked by test.sh (flake check lgtm-gh-launcher-tests); the
# wrapper's own suites run under `npm test` in the lgtm repo.
pkgs.writeShellApplication {
  name = "lgtm-gh";
  runtimeInputs = [ pkgs.coreutils pkgs.gh pkgs.jq pkgs.nodejs_22 ];
  text = ''
    script=${pkgs.lib.escapeShellArg script}
    if [ ! -f "$script" ]; then
      echo "lgtm-gh: $script not found. The wrapper runs from the lgtm checkout, which only cloudbox has." >&2
      exit 1
    fi
    exec ${pkgs.bash}/bin/bash "$script" "$@"
  '';
}
