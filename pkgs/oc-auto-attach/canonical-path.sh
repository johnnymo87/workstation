# shellcheck shell=bash
# canonical-path.sh -- derive and apply the interactive-login PATH.
#
# Sourced verbatim into pkgs/oc-auto-attach/default.nix (builtins.readFile) and
# sourced directly by test-project-key.sh, so the tests exercise THIS code
# rather than a mirror of it (workstation-dimz).
#
# WHY THIS EXISTS
#
# tmux stamps the *invoking client's* PATH into every command it spawns. That
# override beats both the session environment and `new-window -e PATH=...`.
# Verified on tmux 3.6a: a client with PATH=/POLLUTED/bin running
# `new-window -e PATH=/GOOD/bin -e __MARKER= -- sleep` produced a pane whose
# /proc/<pid>/environ said PATH=/POLLUTED/bin and __MARKER= -- the sibling -e
# landed, the PATH one did not. So the ONLY way to give a created pane a usable
# PATH is to fix our own before calling tmux.
#
# This matters because oc-auto-attach's callers include systemd units whose
# PATH is a locked-down store list with no ~/.nix-profile/bin -- pigeon-daemon
# above all (the same family of breakage as the OC_NVIMS_BIN workaround in
# default.nix, workstation-1lp). A pane born from such a caller cannot find
# ~/.nix-profile/bin tools at all: `opencode` is a bashrc function delegating
# to oc-pool-attach, so it dies with "command not found". Worse, the pane
# cannot repair itself -- it also inherits __NIXOS_SET_ENVIRONMENT_DONE=1, and
# /etc/profile skips the set-environment that would rewrite PATH, so the
# reflexive `exec bash -l` is a no-op. See workstation-v8t5.
#
# WHY DERIVED, NOT BAKED
#
# The real login PATH is assembled by a store path that changes every system
# generation. Reconstructing it as a literal in the nix expression would drift
# from /etc/set-environment silently. /etc/set-environment is a stable
# /etc/static symlink regenerated on every activation, so reading it at runtime
# cannot go stale.

# canonical_login_path: print the PATH an interactive login shell would have.
#
# Uses NOTHING but bash builtins and $BASH (an absolute path bash always sets
# for itself). It deliberately does not call `env`, `id`, or any other external
# tool: this function's whole job is to run when PATH is broken, and an early
# version that shelled out to `env -i` returned failure in exactly that case --
# `env` was not resolvable either. A repair that needs a working PATH to repair
# PATH is not a repair.
#
# The guard variables are unset in the child rather than scrubbed with `env -i`
# for the same reason. That is sufficient: /etc/set-environment ASSIGNS PATH
# outright (it does not append to the inherited one), so the caller's pollution
# is overwritten, not merged.
#
# Prints nothing and returns 1 if the derivation fails, so callers can degrade
# instead of clobbering PATH with "".
canonical_login_path() {
  local derived
  # Test seam. Defaults to the real thing; test-project-key.sh points it at a
  # fixture so its assertions are hermetic. Inside a Nix build sandbox there is
  # no /etc/set-environment and no ~/.nix-profile, so a test that asserted the
  # host's real PATH could only pass by accident of where it ran -- which is
  # exactly how this first went red in `nix flake check`.
  local set_env_file="${OC_AA_SET_ENVIRONMENT:-/etc/set-environment}"

  # $USER feeds /etc/profiles/per-user/$USER/bin in set-environment. Fall back
  # to the basename of $HOME (builtin expansion, no `id`) so a systemd unit
  # that sets HOME but not USER still resolves that entry.
  # SC2016 is the point, not an oversight: the single-quoted body must reach
  # the child unexpanded so that $PATH and $HOME resolve THERE, after
  # /etc/set-environment has rewritten them.
  # shellcheck disable=SC2016
  derived="$(
    OC_AA_SET_ENV_FILE="$set_env_file" \
    USER="${USER:-${LOGNAME:-${HOME##*/}}}" \
    "${BASH:-bash}" --noprofile --norc -c '
      unset __NIXOS_SET_ENVIRONMENT_DONE __ETC_PROFILE_DONE \
            __ETC_PROFILE_SOURCED __HM_SESS_VARS_SOURCED
      . "$OC_AA_SET_ENV_FILE" 2>/dev/null || exit 1
      # Home-manager only writes these to ~/.profile (login shells); they carry
      # ~/.local/bin, where ba/oc-search/ensure-projects live. Optional: a host
      # without standalone home-manager still gets a valid system PATH.
      if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
        . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" 2>/dev/null || true
      fi
      printf %s "$PATH"
    ' 2>/dev/null
  )" || return 1

  [ -n "$derived" ] || return 1
  printf '%s' "$derived"
}

# repair_path: append the canonical login PATH to ours.
#
# APPENDED, not prepended, on purpose. writeShellApplication puts this script's
# pinned runtimeInputs first precisely so it cannot be hijacked by whatever the
# caller happens to have installed; prepending the user profile would undo that
# guarantee for every tool this script calls. Appending only adds entries that
# were missing, which is the whole bug.
#
# The corollary is that appending does NOT unshadow a binary the caller already
# has -- notably a bare `neovim` on a systemd unit's PATH, which `nvims` would
# still `exec nvim` into ahead of the home-manager-wrapped one. That half of
# workstation-v8t5 is fixed at the source instead, by keeping pkgs.neovim off
# pigeon-daemon's path (hosts/cloudbox/configuration.nix).
repair_path() {
  local canonical
  if canonical="$(canonical_login_path)"; then
    export PATH="$PATH:$canonical"
    return 0
  fi
  return 1
}
