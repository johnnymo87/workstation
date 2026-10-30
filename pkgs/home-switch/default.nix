# home-switch -- deploy the Mac's USER-level config with no root.
#
# == Why this exists ==
# This Mac is losing local admin; afterwards root exists only inside a short
# Admin By Request window. Home-manager used to be a nix-darwin module, so every
# dotfile, skill, plugin, opencode-config and launchd-agent change rode along
# with `sudo darwin-rebuild switch`. It is now a standalone
# homeConfigurations.<darwinConfiguration name> (flake.nix), and this is its
# deploy command: no sudo anywhere.
#
# It also means a remote Claude (cloudbox, over the cutover tunnel) can repair
# the usual "broke Claude access" cases -- opencode config, plugins, skills,
# launchd agents -- with no root and no sudoers toggle.
#
# == What it does ==
#   1. cfp-prefetch-darwin: the claude-failover-proxy launchd agent is a HOME
#      package, so the home build needs the private asset seeded exactly like
#      the system build used to (see pkgs/cfp-prefetch-darwin/default.nix).
#   2. home-manager switch --flake DIR#NAME -b hm-backup, with the
#      home-manager CLI from the same flake input that builds the config.
#
# == Usage ==
#   home-switch                          # deploys ~/Code/workstation
#   home-switch --flake DIR              # deploy another checkout
#   home-switch --name NAME              # override the homeConfiguration
#   home-switch -- --show-trace          # extra args go to home-manager
#
# Not on PATH yet (first run / migration): nix run ~/Code/workstation#home-switch
#
# The default is the main checkout on purpose: deploying a worktree silently
# reverts everything that worktree lacks (see the rebuilding skill).
{
  lib,
  writeShellApplication,
  coreutils,
  cfp-prefetch-darwin,
  home-manager,
}:

writeShellApplication {
  name = "home-switch";

  runtimeInputs = [ coreutils cfp-prefetch-darwin home-manager ];

  text = ''
    flake="''${HOME}/Code/workstation"
    name=""
    extra=()

    while [ $# -gt 0 ]; do
      case "$1" in
        --flake) flake="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --) shift; extra=("$@"); break ;;
        -h|--help)
          echo "usage: home-switch [--flake DIR] [--name NAME] [-- HOME-MANAGER-ARGS...]"
          echo
          echo "Seeds the private claude-failover-proxy asset (cfp-prefetch-darwin),"
          echo "then runs: home-manager switch --flake DIR#NAME -b hm-backup"
          echo "NAME defaults to the flake's only darwinConfiguration name."
          echo "Needs no root. System changes are darwin-switch (needs elevation)."
          exit 0 ;;
        *) echo "home-switch: unknown argument: $1 (pass home-manager args after --)" >&2; exit 2 ;;
      esac
    done

    # Under sudo this would build root's home, read root's Keychain, and leave
    # root-owned files in the user's profile. There is never a reason to.
    if [ "$(id -u)" -eq 0 ]; then
      echo "home-switch: run as your user, not under sudo (it needs no root)" >&2
      exit 1
    fi

    for a in "''${extra[@]}"; do
      case "$a" in
        --flake|--flake=*) echo "home-switch: pass --flake before --, not after it" >&2; exit 2 ;;
      esac
    done

    if [ "$(uname -s)" != "Darwin" ]; then
      echo "home-switch: not darwin; use: nix run home-manager -- switch --flake .#<host>" >&2
      exit 1
    fi

    flake="$(cd "$flake" && pwd -P)"

    # Non-login shells (launchd, ssh with a bare command, agent shells) may lack
    # the nix-darwin profile dirs; cfp-prefetch-darwin and home-manager's
    # activation (nix-env / nix profile) both take `nix` from PATH.
    PATH="$PATH:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin"

    # Same name as the darwinConfiguration (flake.nix names the Mac's
    # homeConfiguration after it), resolved the same way darwin-switch does,
    # because `hostname -s` has drifted from it on this very Mac.
    if [ -z "$name" ]; then
      names="$(nix eval --raw "$flake#darwinConfigurations" \
        --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)')"
      read -r -a name_list <<<"$names"
      if [ "''${#name_list[@]}" -ne 1 ]; then
        echo "home-switch: flake defines ''${#name_list[@]} darwinConfigurations ($names); pick one with --name" >&2
        exit 1
      fi
      name="''${name_list[0]}"
    fi

    has="$(nix eval --raw "$flake#homeConfigurations" \
      --apply "c: if c ? \"$name\" then \"yes\" else \"no\"")"
    if [ "$has" != "yes" ]; then
      echo "home-switch: $flake has no homeConfigurations.\"$name\"." >&2
      echo "  A checkout from before the standalone-home-manager change? Its home is" >&2
      echo "  still deployed by darwin-switch. See docs/plans/2026-10-30-mac-standalone-home-manager.md" >&2
      exit 1
    fi

    if ! cfp-prefetch-darwin --flake "$flake"; then
      echo "home-switch: cfp seed failed, and the home build would 404 without it." >&2
      echo "  Over SSH the login Keychain is usually locked. Either run" >&2
      echo "  'cfp-prefetch-darwin --flake $flake' once at the Mac, or unlock it here:" >&2
      echo "  security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
      exit 1
    fi

    echo "home-switch: home-manager switch --flake $flake#$name -b hm-backup ''${extra[*]}"
    exec home-manager switch --flake "$flake#$name" -b hm-backup "''${extra[@]}"
  '';

  meta = with lib; {
    description = "Seed the private cfp asset, then standalone home-manager switch (no root)";
    platforms = platforms.darwin;
    mainProgram = "home-switch";
  };
}
