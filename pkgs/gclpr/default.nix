{ lib, stdenv, fetchurl, unzip }:

let
  version = "2.2.1";
  platforms = {
    aarch64-linux = {
      asset = "gclpr_linux_arm64.zip";
      hash = "sha256-CPnKZF9DPSCxXECMXxIzHPBUnQYKiDTnh7+8XmkWS7Y=";
    };
    aarch64-darwin = {
      asset = "gclpr_darwin_arm64.zip";
      hash = "sha256-4QjZfle+P/lsgw7L6gYbVJ2gYhJWSFNAMa+u+mpfnF8=";
    };
    x86_64-linux = {
      asset = "gclpr_linux_amd64.zip";
      hash = "sha256-cvkXKSt2Z7hOjPxhxuZyVLJR4uo+1R03QV6wD2DV//o=";
    };
    x86_64-darwin = {
      asset = "gclpr_darwin_amd64.zip";
      hash = "sha256-9TR9Hh6f94mRF38Xl6Opb9zVJYpFbXzCrxYIEh9uMuc=";
    };
  };
  platformInfo = platforms.${stdenv.hostPlatform.system} or (throw "gclpr: unsupported system ${stdenv.hostPlatform.system}");
in stdenv.mkDerivation {
  pname = "gclpr";
  inherit version;
  src = fetchurl {
    url = "https://github.com/rupor-github/gclpr/releases/download/v${version}/${platformInfo.asset}";
    hash = platformInfo.hash;
  };
  nativeBuildInputs = [ unzip ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  unpackPhase = ''
    runHook preUnpack
    unzip $src
    runHook postUnpack
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 gclpr $out/bin/gclpr
    runHook postInstall
  '';
  meta = {
    description = "Clipboard sharing and browser-open bridge tool";
    homepage = "https://github.com/rupor-github/gclpr";
    license = lib.licenses.mit;
    mainProgram = "gclpr";
  };
}