# darwin-switch -- `sudo darwin-rebuild switch`, with the cfp asset seeded first.
#
# == Why this exists ==
# pkgs/claude-failover-proxy fetches a binary from a PRIVATE GitHub repo, and
# this Mac has no GITHUB_TOKEN anywhere the Nix builder can see (full story in
# pkgs/cfp-prefetch-darwin/default.nix). So after every cfp release -- the daily
# auto-bump PR -- a plain `sudo darwin-rebuild switch` dies with a 404 that
# takes the WHOLE system build down, until someone remembers to run
# `cfp-prefetch-darwin` first.
#
# darwin-rebuild has no pre-build hook to hang that on: activation scripts run
# only AFTER the build succeeds, and the build is what fails. So the prefetch
# has to happen outside darwin-rebuild, in a wrapper. The wrapper also has to run
# the prefetch as the invoking USER, not under sudo: the token comes from the
# user's login Keychain, which root cannot read.
#
# The alternative -- handing the nix-daemon a token, as cloudbox does -- was
# considered and declined: it needs a root-only token file, a wrapped daemon
# launch, and NIX_REMOTE=daemon for sudo, to save typing one command.
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
          echo "Seeds the private claude-failover-proxy asset (cfp-prefetch-darwin),"
          echo "then runs: sudo darwin-rebuild switch --flake DIR#NAME"
          echo "NAME defaults to the flake's only darwinConfiguration."
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

    # A failed seed means the rebuild would 404 anyway; stop here, where the
    # error message names the actual problem (token, scope, hash).
    cfp-prefetch-darwin --flake "$flake"

    echo "darwin-switch: sudo darwin-rebuild switch --flake $flake#$host ''${extra[*]}"
    exec sudo "$rebuild" switch --flake "$flake#$host" "''${extra[@]}"
  '';

  meta = with lib; {
    description = "Seed the private cfp asset, then sudo darwin-rebuild switch";
    platforms = platforms.darwin;
    mainProgram = "darwin-switch";
  };
}
