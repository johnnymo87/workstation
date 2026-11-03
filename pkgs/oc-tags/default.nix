{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "session-tags";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_tags.py $out/bin/session-tags
    chmod +x $out/bin/session-tags
    ln -s session-tags $out/bin/oc-tags

    runHook postInstall
  '';

  meta = with lib; {
    description = "Tag opencode and goose sessions with a program; chart list-price consumption per tag";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "session-tags";
  };
}
