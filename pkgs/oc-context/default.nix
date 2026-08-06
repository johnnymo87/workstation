{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-context";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  # Stdlib-only on purpose (sqlite3 / urllib / argparse), same as oc-cost: this
  # ships to devbox, cloudbox and macOS and must not drag a dependency closure
  # along to print a table.
  doCheck = true;

  # NOTE: this checkPhase is NOT what makes the suite "run by CI" -- see
  # users/dev/test-unwired-tests.sh on why `doCheck` is not accepted as
  # evidence. The blessed reference is `checks.oc-context` in flake.nix, which
  # executes this same file. This is here so `nix build .#oc-context` also
  # catches a break locally.
  # Run from the unpacked source, not from a bare store path: the suite imports
  # `oc_context` as a sibling module.
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_oc_context.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_context.py $out/bin/oc-context
    chmod +x $out/bin/oc-context

    runHook postInstall
  '';

  meta = with lib; {
    description = "Report OpenCode session context usage (tokens, window, % used)";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-context";
  };
}
