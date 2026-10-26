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
#   - runtimeShell (the bash writeShellApplication itself uses) to run it.
#
# Where the script is missing it refuses and runs nothing. That happens on a
# host with no lgtm checkout (macOS), and on cloudbox if this lands before the
# lgtm change that added the script is pulled. The message tells the session
# NOT to fall back to plain `gh`: sessions on cloudbox carry the human's own
# GH_TOKEN, so plain gh would post as the human, unrecorded and ungated.
# (devbox may have a checkout, and then runs whatever it has checked out;
# devbox has no reviewer tokens, so the wrapper stops at the token lookup.)
# Behaviour is locked by test.sh (flake check lgtm-gh-launcher-tests); the
# wrapper's own suites run under `npm test` in the lgtm repo.
pkgs.writeShellApplication {
  name = "lgtm-gh";
  runtimeInputs = [ pkgs.coreutils pkgs.gh pkgs.jq pkgs.nodejs_22 ];
  text = ''
    script=${pkgs.lib.escapeShellArg script}
    if [ ! -f "$script" ]; then
      echo "lgtm-gh: not installed here ($script is missing; it comes from the lgtm checkout). Do NOT use plain gh or any other route instead: nothing posted without lgtm-gh is attributed or gated. Post nothing further, end your session, and say in your final report that lgtm-gh was unavailable." >&2
      exit 1
    fi
    exec ${pkgs.runtimeShell} "$script" "$@"
  '';
}
