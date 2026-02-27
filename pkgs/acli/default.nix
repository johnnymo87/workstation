{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "1.3.13-stable";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://acli.atlassian.com/linux/${version}/acli_${version}_linux_arm64.tar.gz";
      hash = "sha256-Ui2gZtmkvDV+r4/Mp2OgvjBI/Q5VlapDPWkEBlRy3VY=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://acli.atlassian.com/darwin/${version}/acli_${version}_darwin_arm64.tar.gz";
      hash = "sha256-BDxUIjJ2EOgv2DrHnKPd8MkXYROG91J1ZNtMi8mTiLE=";
    };
  };
in

stdenv.mkDerivation {
  pname = "acli";
  inherit version;

  src = sources.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    install -Dm755 acli_${version}_*/acli $out/bin/acli
    runHook postInstall
  '';

  dontFixup = stdenv.isLinux; # Statically linked on Linux, no patching needed

  doCheck = false;

  meta = with lib; {
    description = "Atlassian CLI - interact with Atlassian Cloud from the terminal";
    homepage = "https://developer.atlassian.com/cloud/acli/";
    license = licenses.unfree;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "acli";
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
  };
}
