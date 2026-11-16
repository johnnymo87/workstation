{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "aigateway-cache-miss-watch";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    ${python3.interpreter} test_aigateway_cache_miss_watch.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp aigateway_cache_miss_watch.py $out/bin/aigateway-cache-miss-watch
    chmod +x $out/bin/aigateway-cache-miss-watch
    patchShebangs $out/bin/aigateway-cache-miss-watch
    runHook postInstall
  '';

  meta = with lib; {
    description = "Alert on Gemini sessions stuck at zero prompt-cache reads in aigateway's ledger";
    platforms = platforms.unix;
    mainProgram = "aigateway-cache-miss-watch";
  };
}
