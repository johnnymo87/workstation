{ pkgs }:

# lgtm-gh: identity-resolving `gh` wrapper for lgtm's multi-reviewer feature.
#
# A dispatched (headless) OpenCode review session is told to use `lgtm-gh`
# instead of `gh` for any GitHub state-changing operation. This wrapper reads
# the reviewer login that lgtm wrote into the worktree's `.lgtm-reviewer`,
# resolves that login's classic PAT at `~/.config/lgtm/tokens/<login>.pat`
# (deployed from sops on cloudbox), and execs `gh` with `GH_TOKEN` set so the
# review posts under that identity. The token never enters the agent's
# reasoning context — the agent only ever sees the identity *name*.
#
# It ALSO records the id of every review artifact it creates to a JSONL ledger,
# and REFUSES a merge whose target repo is not one of the two the assist lane
# is allowed to merge in. Both are explained where they are implemented.
#
# The script body is `lgtm-gh.sh`, read verbatim. It is a separate file so that
# pkgs/lgtm-gh/test.sh can execute the real source with a fake `gh` on PATH —
# the shipped binary cannot be intercepted that way, because
# writeShellApplication prepends its runtimeInputs to PATH and the pinned real
# `gh` wins. That is what the mirror this suite used to carry existed to work
# around.
#
# Design: lgtm repo docs/plans/2026-04-30-multi-reviewer-identity-design.md.
# Behavior is locked by pkgs/lgtm-gh/test.sh (source) and test-real.sh (binary).
pkgs.writeShellApplication {
  name = "lgtm-gh";
  # coreutils: cat/tr/env/date/mktemp/mkdir. gh: the wrapped CLI itself, pinned
  # so the wrapper works even under a restricted systemd PATH. jq: parses the id
  # out of gh's response and emits the ledger line. writeShellApplication
  # prepends these to PATH (it does not clobber the inherited PATH).
  runtimeInputs = [ pkgs.coreutils pkgs.gh pkgs.jq ];
  text = builtins.readFile ./lgtm-gh.sh;
}
