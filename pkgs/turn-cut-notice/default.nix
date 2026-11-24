{ lib
, python3
}:

# turn-cut-notice: called by reset-workspace to tell agent sessions (opencode
# and goose) that the reset's serve restart cut their turn (workstation-dg6).
# Design: docs/plans/2026-11-24-reset-turn-cut-notice.md
python3.pkgs.buildPythonApplication {
  pname = "turn-cut-notice";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  # Stdlib only (sqlite3 / urllib / subprocess): it rides in reset-workspace's
  # closure on devbox and cloudbox.
  doCheck = true;

  # NOT the CI gate (users/dev/test-unwired-tests.sh does not accept checkPhase
  # as evidence); `checks.turn-cut-notice` in flake.nix is. This only makes a
  # local `nix build .#turn-cut-notice` catch a break too.
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_turn_cut_notice.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp turn_cut_notice.py $out/bin/turn-cut-notice
    chmod +x $out/bin/turn-cut-notice
    runHook postInstall
  '';

  meta = with lib; {
    description = "Tell agent sessions that a planned serve restart cut their turn";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "turn-cut-notice";
  };
}
