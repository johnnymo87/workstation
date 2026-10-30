# setproctitle's fork tests segfault on Darwin (exit code -11), which blocks the
# azure-cli build (azure-cli is a home package, see users/dev/home.base.nix).
# Disable tests for that one package.
#
# Shared by the darwin system (hosts/Y0FMQX93RR-2/configuration.nix) and the
# Mac's standalone home-manager (darwinHomePkgs in flake.nix), so both evaluate
# the same package set. Harmless on Linux, but only applied on darwin.
final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pfinal: pprev: {
      setproctitle = pprev.setproctitle.overridePythonAttrs {
        doCheck = false;
      };
    })
  ];
}
