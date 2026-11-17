{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "worker-scorecard";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp worker_scorecard.py $out/bin/worker-scorecard
    chmod +x $out/bin/worker-scorecard

    runHook postInstall
  '';

  meta = with lib; {
    description = "Per-worker cost and PR outcome for a program's worker sessions, opencode and goose, with total $ per merged PR per arm";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "worker-scorecard";
  };
}
