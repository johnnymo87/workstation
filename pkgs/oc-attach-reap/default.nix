{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-attach-reap";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  # Stdlib-only (sqlite3 / argparse / os / signal), matching oc-search and
  # oc-context: this reads a database and sends SIGTERM, and has no business
  # dragging a dependency closure onto three hosts to do it.
  doCheck = true;

  # NOTE: this checkPhase is NOT what makes the suite "run by CI" -- see
  # users/dev/test-unwired-tests.sh on why `doCheck` is not accepted as
  # evidence. The blessed reference is `checks.oc-attach-reap` in flake.nix,
  # which executes this same file. This is here so `nix build .#oc-attach-reap`
  # also catches a break locally.
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_oc_attach_reap.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp oc_attach_reap.py $out/bin/oc-attach-reap
    chmod +x $out/bin/oc-attach-reap
    patchShebangs $out/bin/oc-attach-reap
    runHook postInstall
  '';

  meta = with lib; {
    description = "Kill opencode attach TUIs whose session no longer exists";
    longDescription = ''
      opencode-launch opens an attach TUI per session and nothing ever closed
      them. Measured on cloudbox 2026-09-18: 124 attach processes, 60 of them
      pointing at sessions that no longer existed.

      The oracle is opencode.db rather than the front door: it needs no network
      and keeps working when a serve is wedged, which is exactly when TUIs pile
      up. (An earlier rationale claimed `GET /session/<id>` cannot tell a live
      session from a deleted one. That was wrong -- it answers 200 and 404
      correctly; the original test sampled two ids that were both already dead.)

      Every way the oracle can fail -- missing, corrupt, empty table, or an
      implausible orphan fraction -- makes healthy TUIs look dead, so each one
      is handled by killing nothing.
    '';
    platforms = platforms.linux;
  };
}
