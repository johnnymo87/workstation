{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-tags";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_tags.py $out/bin/oc-tags
    chmod +x $out/bin/oc-tags

    runHook postInstall
  '';

  meta = with lib; {
    description = "Tag opencode sessions and chart list-price consumption per tag";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-tags";
  };
}
