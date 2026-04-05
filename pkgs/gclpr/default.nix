{ lib, stdenv, fetchurl, unzip }:

let
  version = "2.2.1";
  platforms = {
    aarch64-linux = {
      asset = "gclpr_linux_arm64.zip";
      hash = "sha256-C+4XWveoZhUp6H2AO+GTk5aNYxdSg8CG67lJp6zURWI=";
    };
    aarch64-darwin = {
      asset = "gclpr_darwin_arm64.zip";
      hash = "sha256-fReLnTjvxMa/35eL/4Hv+eNE8IDvQgcg5GrzPG+hITg=";
    };
    x86_64-linux = {
      asset = "gclpr_linux_amd64.zip";
      hash = "sha256-N7HeIzByA2/ZeOdBzZuBmN0yyxpr7cdKqdNryLkJnO4=";
    };
    x86_64-darwin = {
      asset = "gclpr_darwin_amd64.zip";
      hash = "sha256-ZO5gaN2LvjXh7LnpMUJOuse2jNy1GwIL5YTpy7qvPKs=";
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