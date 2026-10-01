{ lib
, python3
}:

python3.pkgs.buildPythonApplication {
  pname = "oc-revive";
  version = "0.1.0";
  format = "other";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp oc_revive.py $out/bin/oc-revive
    chmod +x $out/bin/oc-revive

    runHook postInstall
  '';

  meta = with lib; {
    description = "Revive OpenCode sessions whose git worktrees were deleted";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "oc-revive";
  };
}
