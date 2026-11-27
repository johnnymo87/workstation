# Wedge canary for goose-serve and honkd (bead workstation-6w7i.7). Alert-only;
# see the docstring in goose_canary.py. Deployed by users/dev/goose-agent.nix.
{ pkgs, lib ? pkgs.lib, python3 ? pkgs.python3 }:

pkgs.writeShellScriptBin "goose-canary" ''
  exec ${python3}/bin/python3 ${./goose_canary.py} "$@"
''
