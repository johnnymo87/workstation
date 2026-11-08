{ pkgs, script ? "/home/dev/projects/lgtm/scripts/lgtm-review" }:

# lgtm-review: launcher for lgtm's goose review units operator CLI.
#
# Provides the operator CLI for managing lgtm's goose review units:
# status, stop, stop-all, and logs. `stop-all` is a rollback step:
# stop lgtm-run.timer first, then run `lgtm-review stop-all`.
#
# The script itself lives in the lgtm repo (scripts/lgtm-review) and runs from
# the lgtm checkout, so it deploys when that checkout is pulled.
# No PATH pinning is needed: the script and lgtm's code use absolute
# /run/current-system/sw/bin paths for node, realpath, and tsx.
#
# Where the script is missing it refuses and runs nothing. That happens on a
# host with no lgtm checkout (macOS, devbox), and on cloudbox if this lands
# before the lgtm change that added the script is pulled.
#
# Behaviour is locked by test.sh (flake check lgtm-review-launcher-tests); the
# script's underlying CLI runs under `npm test` in the lgtm repo.
pkgs.writeShellApplication {
  name = "lgtm-review";
  runtimeInputs = [ ];
  text = ''
    script=${pkgs.lib.escapeShellArg script}
    if [ ! -f "$script" ]; then
      echo "lgtm-review: not installed here ($script is missing; it comes from the lgtm checkout)." >&2
      exit 1
    fi
    exec ${pkgs.runtimeShell} "$script" "$@"
  '';
}
