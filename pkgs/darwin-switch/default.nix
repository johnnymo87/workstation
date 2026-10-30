# darwin-switch -- the Mac's SYSTEM deploy: `sudo darwin-rebuild switch`.
#
# == Scope: system only ==
# Since home-manager became standalone on the Mac (flake.nix
# homeConfigurations.<host>, docs/plans/2026-10-30-mac-standalone-home-manager.md),
# this deploys ONLY nix-darwin's half: nix.conf, /etc/bashrc, /etc/shells, the
# login shell, the nix-daemon, sudoers, the nix-gc/nix-optimise daemons. User
# config (dotfiles, skills, opencode, launchd agents) is `home-switch`, which
# needs no root.
#
# Once local admin is gone, the sudo below works only inside an Admin By
# Request window (or with the enableUnattendedRemoteRoot rule installed, see
# hosts/Y0FMQX93RR-2/configuration.nix).
#
# == The cfp seed is best-effort here ==
# pkgs/claude-failover-proxy fetches a binary from a PRIVATE GitHub repo that
# the Mac's builder cannot fetch without the seed (pkgs/cfp-prefetch-darwin).
# cfp used to be in the system closure via the home-manager module, so a missing
# seed 404'd every system rebuild and this wrapper had to stop on it. cfp is now
# a HOME package, so the system build does not need it; the seed still runs (it
# is a no-op when already seeded, and harmless) but a failure only warns. That
# matters for remote system repair over SSH, where the login Keychain is usually
# locked: a pending cfp bump must not block a fix that has nothing to do with
# cfp. home-switch, which does need it, keeps the seed fatal.
#
# The prefetch runs as the invoking USER, not under sudo: the token comes from
# the user's login Keychain, which root cannot read.
#
# == Usage ==
#   darwin-switch                         # deploys ~/Code/workstation
#   darwin-switch --flake DIR             # deploy another checkout
#   darwin-switch --host NAME             # override the darwinConfiguration
#   darwin-switch -- --show-trace         # extra args go to darwin-rebuild
#
# The default is the main checkout on purpose: deploying a worktree silently
# reverts everything that worktree lacks (see the rebuilding skill).
{
  lib,
  writeShellApplication,
  coreutils,
  cfp-prefetch-darwin,
}:

writeShellApplication {
  name = "darwin-switch";

  runtimeInputs = [ coreutils cfp-prefetch-darwin ];

  text = ''
    flake="''${HOME}/Code/workstation"
    host=""
    extra=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --flake) flake="$2"; shift 2 ;;
        --host) host="$2"; shift 2 ;;
        --) shift; extra=("$@"); break ;;
        -h|--help)
          echo "usage: darwin-switch [--flake DIR] [--host NAME] [-- DARWIN-REBUILD-ARGS...]"
          echo
          echo "SYSTEM deploy: sudo darwin-rebuild switch --flake DIR#NAME"
          echo "(needs an Admin By Request window once local admin is removed)."
          echo "NAME defaults to the flake's only darwinConfiguration."
          echo "User config (dotfiles, skills, opencode, launchd agents) is home-switch: no root."
          exit 0 ;;
        *) echo "darwin-switch: unknown argument: $1 (pass darwin-rebuild args after --)" >&2; exit 2 ;;
      esac
    done

    # `sudo darwin-switch` out of `sudo darwin-rebuild` habit would look up the
    # token in ROOT's Keychain and report it missing -- but only on the run
    # after a cfp bump, since an already-seeded asset short-circuits. Refuse
    # always, so the habit is corrected before it matters.
    if [ "$(id -u)" -eq 0 ]; then
      echo "darwin-switch: run as your user, not under sudo (it calls sudo itself; the token is in YOUR Keychain)" >&2
      exit 1
    fi

    # A --flake in the passthrough args would override ours (last wins) and
    # silently deploy a tree the seed was not computed for.
    for a in "''${extra[@]}"; do
      case "$a" in
        --flake|--flake=*) echo "darwin-switch: pass --flake before --, not after it" >&2; exit 2 ;;
      esac
    done

    if [ "$(uname -s)" != "Darwin" ]; then
      echo "darwin-switch: not darwin; use nixos-rebuild / home-manager instead" >&2
      exit 1
    fi

    # Resolve to an absolute path so the flake ref does not depend on cwd, and
    # so cfp-prefetch-darwin and darwin-rebuild provably evaluate the SAME tree.
    # If they disagreed, the seed would be for the wrong cfp version and the
    # rebuild would 404 anyway.
    flake="$(cd "$flake" && pwd -P)"

    # Non-login shells (and some agent shells) lack the nix-darwin profile dirs
    # on PATH; cfp-prefetch-darwin takes `nix` from PATH deliberately.
    PATH="$PATH:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"

    # Prefer the exact path the optional NOPASSWD sudoers rule names
    # (hosts/Y0FMQX93RR-2/configuration.nix); a fresh Mac may not have it yet.
    rebuild=/run/current-system/sw/bin/darwin-rebuild
    if [ ! -x "$rebuild" ]; then
      rebuild="$(command -v darwin-rebuild || true)"
    fi
    if [ -z "$rebuild" ]; then
      echo "darwin-switch: darwin-rebuild not found. First-ever nix-darwin deploy? Run:" >&2
      echo "  nix run $flake#cfp-prefetch-darwin -- --flake $flake" >&2
      echo "  sudo nix run nix-darwin#darwin-rebuild -- switch --flake $flake#<name>" >&2
      exit 1
    fi

    # Ask the flake for its darwinConfiguration name instead of deriving it from
    # `hostname -s`: the two have drifted on this very Mac (hostname
    # `Y0FMQX93RR`, flake target `Y0FMQX93RR-2`), and darwin-rebuild's own
    # default (LocalHostName) is the same wrong guess.
    if [ -z "$host" ]; then
      names="$(nix eval --raw "$flake#darwinConfigurations" \
        --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)')"
      read -r -a name_list <<<"$names"
      if [ "''${#name_list[@]}" -ne 1 ]; then
        echo "darwin-switch: flake defines ''${#name_list[@]} darwinConfigurations ($names); pick one with --host" >&2
        exit 1
      fi
      host="''${name_list[0]}"
    fi

    # Best-effort: the system closure no longer contains cfp (see header).
    if ! cfp-prefetch-darwin --flake "$flake"; then
      echo "darwin-switch: WARNING: cfp seed failed; continuing (the system build does not need it)." >&2
      echo "  If the build below 404s on claude-failover-proxy, cfp is back in the system closure." >&2
    fi

    echo "darwin-switch: sudo darwin-rebuild switch --flake $flake#$host ''${extra[*]}"
    echo "darwin-switch: (system only -- user config is home-switch)"
    exec sudo "$rebuild" switch --flake "$flake#$host" "''${extra[@]}"
  '';

  meta = with lib; {
    description = "macOS system deploy: sudo darwin-rebuild switch (user config is home-switch)";
    platforms = platforms.darwin;
    mainProgram = "darwin-switch";
  };
}
