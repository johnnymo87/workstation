{ lib
, python3
, makeWrapper
, _1password-cli
, pinentry_mac
}:

python3.pkgs.buildPythonApplication {
  pname = "pinentry-op";
  version = "1.0.0";
  format = "other";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp pinentry-op.py $out/bin/pinentry-op
    chmod +x $out/bin/pinentry-op

    wrapProgram $out/bin/pinentry-op \
      --set OP_BIN "${_1password-cli}/bin/op" \
      --set PINENTRY_MAC_PATH "${pinentry_mac}/bin/pinentry-mac"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Pinentry wrapper that fetches GPG passphrase from 1Password";
    license = licenses.mit;
    platforms = platforms.darwin;
    mainProgram = "pinentry-op";
  };
}
