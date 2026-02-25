{
  lib,
  stdenv,
  fetchzip,
  bun,
}:

stdenv.mkDerivation rec {
  pname = "ccusage";
  version = "18.0.5";

  src = fetchzip {
    url = "https://registry.npmjs.org/ccusage/-/ccusage-${version}.tgz";
    hash = "sha256-i4UyRU7EA0PLduABnPGbcD8I06ZjmjwXCC77vtFM638=";
  };

  nativeBuildInputs = [ bun ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp -r dist/* $out/bin/
    chmod +x $out/bin/index.js
    mv $out/bin/index.js $out/bin/ccusage

    substituteInPlace $out/bin/ccusage \
      --replace-fail "#!/usr/bin/env node" "#!${bun}/bin/bun"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Usage analysis tool for Claude Code";
    homepage = "https://github.com/ryoppippi/ccusage";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryBytecode ];
    mainProgram = "ccusage";
    platforms = platforms.all;
  };
}
