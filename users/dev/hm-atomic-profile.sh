# shellcheck shell=bash
# Atomic replacement of home-manager's package set in a `nix profile`-style profile.
# Sourced by the installPackages activation in hm-atomic-profile.nix, and by
# test-hm-atomic-profile.sh, which drives it with stub `nix` / `nix-env`.
#
# THE BUG THIS REPLACES. Upstream installPackages (home-manager release-25.11 and
# master, modules/home-environment.nix) does:
#
#     nixProfileRemove 'home-manager-path'      # generation N+1: NO home-manager packages
#     nix profile install <new home-manager-path>   # generation N+2: complete again
#
# Each step is its own profile generation, and the live profile link is switched
# to each in turn. So for the time between the two (measured ~0.4 s on cloudbox,
# 2026-11-11 07:27:11, journal of pull-workstation) ~/.nix-profile/bin holds only
# the handful of packages installed outside home-manager: no python3, no git from
# the profile, nothing home-manager installs. Any process that resolves a command
# in that window fails with "command not found". It hit a test suite run that day,
# and every systemd unit with ~/.nix-profile/bin on PATH is exposed every time a
# switch runs (pull-workstation does one every ~4 h).
#
# THE FIX. Do both steps against a private STAGING profile that starts at the live
# profile's current store path, then point the live profile at the result with a
# single `nix-env --set`, which is one atomic symlink switch. The live profile goes
# from the old complete set straight to the new complete set; there is no
# generation in between for anyone to observe.
#
# hmAtomicReplaceProfile <live-profile-link> <new-home-manager-path>
#   <live-profile-link>: the profile symlink nix manages (e.g.
#     ~/.local/state/nix/profiles/profile), NOT ~/.nix-profile -- nix-env --set
#     creates "<link>-N-link" generations beside whatever it is given, so passing
#     ~/.nix-profile would litter $HOME. hmResolveProfileLink finds it.
#   Uses $HM_ATOMIC_NIX / $HM_ATOMIC_NIX_ENV (default: nix / nix-env on PATH) and
#   honours home-manager's DRY_RUN by printing instead of switching.
#   Returns non-zero, with the live profile untouched, on any failure.

# Resolve ~/.nix-profile (or whatever is given) to the profile link nix manages.
# Prints the link path; returns 1 if it cannot be resolved to a "...-N-link"
# generation chain, in which case the caller must not guess.
hmResolveProfileLink() {
  local p="$1" t
  [[ -L "$p" ]] || return 1
  t="$(readlink "$p")" || return 1
  [[ "$t" == /* ]] || t="$(dirname "$p")/$t"
  # $t must itself be a profile link: a symlink to "<name>-<N>-link".
  [[ -L "$t" ]] || return 1
  [[ "$(readlink "$t")" =~ -[0-9]+-link$ ]] || return 1
  printf '%s\n' "$t"
}

hmAtomicReplaceProfile() {
  local live="$1" newPath="$2"
  local nix="${HM_ATOMIC_NIX:-nix}" nixEnv="${HM_ATOMIC_NIX_ENV:-nix-env}"
  local cur curLink stage rc=0 result="" olds_raw="" paths="" old olds=()

  curLink="$(readlink "$live")" || return 1
  cur="$(readlink -f "$live")" || return 1
  [[ -n "$cur" && -d "$cur" ]] || { echo "hm-atomic-profile: cannot resolve $live" >&2; return 1; }

  if [[ -v DRY_RUN ]]; then
    echo "hm-atomic-profile (dry run): would stage $cur, replace home-manager-path with $newPath, then $nixEnv --profile $live --set <staged>"
    return 0
  fi

  # A FIXED staging dir beside the user's other nix state, emptied at the start of
  # every run: an interrupted run (stopped unit, Ctrl-C) leaves at most one stale
  # stage, whose GC auto-roots keep the same names and are replaced next time. No
  # `trap` here: it would replace home-manager's own EXIT trap.
  stage="${HM_ATOMIC_STAGE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hm-atomic-profile}"
  [[ "${stage##*/}" == hm-atomic-profile ]] || { echo "hm-atomic-profile: refusing stage dir $stage" >&2; return 1; }
  rm -rf -- "$stage"
  mkdir -p "$stage" || return 1
  ln -s "$cur" "$stage/profile" || rc=1

  # Remove every element whose store path ends in home-manager-path, by store path --
  # the selection upstream's nixProfileList makes. Needs `nix profile list --json`
  # (nix 2.17+); if that or jq fails, stop with the live profile untouched rather
  # than guess.
  if (( rc == 0 )); then
    olds_raw="$("$nix" profile list --profile "$stage/profile" --json)" || rc=1
  fi
  if (( rc == 0 )); then
    paths="$(jq -r '.elements | .[] | .storePaths[] | select(endswith("home-manager-path"))' \
               <<<"$olds_raw")" || rc=1
  fi
  if (( rc == 0 )); then
    while IFS= read -r old; do [[ -n "$old" ]] && olds+=("$old"); done <<<"$paths"
    if (( ${#olds[@]} > 0 )); then
      "$nix" profile remove --profile "$stage/profile" "${olds[@]}" || rc=1
    fi
  fi
  # `install`, not `add`: the deprecated alias is the spelling every nix this repo
  # deploys to accepts (upstream uses it too).
  (( rc == 0 )) && { "$nix" profile install --profile "$stage/profile" "$newPath" || rc=1; }
  if (( rc == 0 )); then
    result="$(readlink -f "$stage/profile")" || rc=1
    [[ -n "$result" && -d "$result" ]] || rc=1
  fi
  # Someone else wrote the live profile while we staged (an agent's
  # `nix profile install`, a concurrent switch): setting ours would silently revert
  # theirs. Fail loudly instead; the next switch starts from their state.
  if (( rc == 0 )) && [[ "$(readlink "$live")" != "$curLink" ]]; then
    echo "hm-atomic-profile: $live changed during staging ($curLink -> $(readlink "$live")); not overwriting it." >&2
    rc=1
  fi
  # THE ONLY WRITE TO THE LIVE PROFILE, and it is atomic. It roots the result
  # before the stage (and its roots) is removed below.
  (( rc == 0 )) && { "$nixEnv" --profile "$live" --set "$result" || rc=1; }

  rm -rf -- "$stage"
  return "$rc"
}
