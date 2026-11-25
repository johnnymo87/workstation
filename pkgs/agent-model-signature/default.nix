{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "agent-model-signature";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  # Stdlib-only (sqlite3 / json / re / argparse): ships to devbox, cloudbox and
  # macOS and is invoked on the hot path of Slack MCP posts.
  doCheck = true;

  # NOTE: this checkPhase runs on local `nix build`; CI coverage is wired via
  # `checks.<system>.agent-model-signature-tests` in flake.nix (required by
  # users/dev/test-unwired-tests-guard.sh).
  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_agent_model_signature.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp agent_model_signature.py $out/bin/agent-model-signature
    chmod +x $out/bin/agent-model-signature

    runHook postInstall
  '';

  meta = with lib; {
    description = "Resolve active agent model family and rewrite trailing post signatures";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "agent-model-signature";
  };
}
