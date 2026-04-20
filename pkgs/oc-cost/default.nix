{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-cost";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_cost.py $out/bin/oc-cost
    chmod +x $out/bin/oc-cost

    runHook postInstall
  '';

  meta = with lib; {
    description = "Report OpenCode token usage and API cost from opencode.db";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-cost";
  };
}
