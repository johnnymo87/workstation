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
# Design: lgtm repo docs/plans/2026-04-30-multi-reviewer-identity-design.md.
# Behavior is locked by pkgs/lgtm-gh/test.sh.
pkgs.writeShellApplication {
  name = "lgtm-gh";
  # coreutils: cat/tr/env. gh: the wrapped CLI itself, pinned so the wrapper
  # works even under a restricted systemd PATH. writeShellApplication prepends
  # these to PATH (it does not clobber the inherited PATH).
  runtimeInputs = [ pkgs.coreutils pkgs.gh ];
  text = ''
    # Identity for this worktree: a single GitHub login lgtm wrote here.
    login_file="$PWD/.lgtm-reviewer"
    if [ ! -r "$login_file" ]; then
      echo "lgtm-gh: missing $login_file" >&2
      exit 1
    fi

    login="$(tr -d '[:space:]' < "$login_file")"
    if [ -z "$login" ]; then
      echo "lgtm-gh: empty $login_file" >&2
      exit 1
    fi

    # Resolve that login's PAT. On cloudbox this file is materialized from a
    # sops secret by home.activation.deployLgtmTokens (chmod 600, owner dev).
    token_file="$HOME/.config/lgtm/tokens/$login.pat"
    if [ ! -r "$token_file" ]; then
      echo "lgtm-gh: missing $token_file for login=$login" >&2
      exit 1
    fi

    # exec so GH_TOKEN lives only for gh's lifetime; the agent never sees it.
    exec env GH_TOKEN="$(cat "$token_file")" gh "$@"
  '';
}
