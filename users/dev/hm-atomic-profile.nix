# installPackages without the empty-profile window (see hm-atomic-profile.sh).
#
# Upstream's installPackages removes home-manager-path from ~/.nix-profile and
# only then installs the new one, as two separate profile generations, so every
# switch leaves ~/.nix-profile/bin without anything home-manager installs for a
# fraction of a second. On cloudbox that is every ~4 h (pull-workstation) plus
# every manual switch, and it has already failed a run that resolved `python3`
# inside the window. This replaces the `nix profile` branch with a staged build
# and one atomic `nix-env --set`; the `nix-env` branch (no manifest.json) and the
# externalPackageInstall case are left exactly as upstream has them.
#
# REVISIT WHEN BUMPING home-manager: this is an mkForce over an upstream
# activation entry. If upstream's installPackages changes shape (new ordering
# deps, a different element name than home-manager-path), re-read
# modules/home-environment.nix and update or delete this module.
{ config, lib, pkgs, ... }:

let
  cfg = config.home;
  lib' = ./hm-atomic-profile.sh;
in
lib.mkIf (!config.submoduleSupport.externalPackageInstall) {
  home.activation.installPackages = lib.mkForce (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [[ -e ${cfg.profileDirectory}/manifest.json ]] ; then
      source ${lib'}
      _hmLive="$(hmResolveProfileLink ${lib.escapeShellArg cfg.profileDirectory})" || _hmLive=""
      if [[ -z "$_hmLive" ]]; then
        # Unknown profile layout (not "<link> -> <name>-N-link"): do what upstream
        # does rather than fail the switch. Loud, because the window is back.
        _iWarn 'hm-atomic-profile: cannot resolve %s to a nix profile link; falling back to upstream remove-then-install (non-atomic).' ${lib.escapeShellArg cfg.profileDirectory}
        nixProfileRemove 'home-manager-path'
        if ! run "$(command -v nix)" profile install ${cfg.path} ; then
          _iError 'Oops, Nix failed to install your new Home Manager profile!'
          exit 1
        fi
      elif ! HM_ATOMIC_NIX="$(command -v nix)" PATH="${pkgs.jq}/bin:$PATH" \
           hmAtomicReplaceProfile "$_hmLive" ${cfg.path} ; then
        echo
        _iError $'Oops, Nix failed to install your new Home Manager profile!\n\nThe live profile was NOT changed (hm-atomic-profile stages the change and\nswitches only on success). Perhaps there is a conflict with a package that was\ninstalled using "nix profile install"? Try running\n\n    nix profile list\n\nand if there is a conflicting package you can remove it with\n\n    nix profile remove {number | store path}\n\nThen try activating your Home Manager configuration again.'
        exit 1
      fi
      unset _hmLive
    else
      if ! run nix-env -i ${cfg.path} ; then
        echo
        _iError $'Oops, Nix failed to install your new Home Manager profile!\n\nPerhaps there is a conflict with a package that was installed using\n"nix-env -i"? Try running\n\n    nix-env -q\n\nand if there is a conflicting package you can remove it with\n\n    nix-env -e {package name}\n\nThen try activating your Home Manager configuration again.'
        exit 1
      fi
    fi
  '');
}
