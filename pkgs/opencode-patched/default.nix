{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  unzip,
  autoPatchelfHook,
  fzf,
  ripgrep,
}:

let
  upstreamVersion = "1.17.13";
  patchedRevision = "4";
  tagSuffix = if patchedRevision == "" then "" else ".${patchedRevision}";
  releaseTag = "v${upstreamVersion}-patched${tagSuffix}";
  version = if patchedRevision == "" then upstreamVersion else "${upstreamVersion}.${patchedRevision}";

  opencode-platforms = {
    aarch64-linux = {
      asset = "opencode-linux-arm64.tar.gz";
      hash = "sha256-XPJTGOeQL/WJirAIwztunwpUlbzRdZzk1/+Ub56noko=";
      isZip = false;
    };
    aarch64-darwin = {
      asset = "opencode-darwin-arm64.zip";
      hash = "sha256-yM3TrFL64ln/EM5gsqnJbmYJUxovhUVU2QCsdke/saU=";
      isZip = true;
    };
    x86_64-linux = {
      asset = "opencode-linux-x64.tar.gz";
      hash = "sha256-NZrjbK0I8hVK1Nzzhtqpp8wdhbxDcsQuYmIXZGObZNk=";
      isZip = false;
    };
    x86_64-darwin = {
      asset = "opencode-darwin-x64.zip";
      hash = "sha256-mmiePXnDLJFVtPeWH9xmulVPIO/ZCudxyeoRzwgGlL4=";
      isZip = true;
    };
  };

  platformInfo = opencode-platforms.${stdenv.hostPlatform.system};
in stdenv.mkDerivation {
  pname = "opencode-patched";
  inherit version;
  src = fetchurl {
    url = "https://github.com/johnnymo87/opencode-patched/releases/download/${releaseTag}/${platformInfo.asset}";
    hash = platformInfo.hash;
  };
  nativeBuildInputs = [ makeWrapper ]
    ++ lib.optionals platformInfo.isZip [ unzip ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
  ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  unpackPhase = ''
    runHook preUnpack
  '' + lib.optionalString platformInfo.isZip ''
    unzip $src
  '' + lib.optionalString (!platformInfo.isZip) ''
    tar -xzf $src
  '' + ''
    runHook postUnpack
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 bin/opencode $out/bin/opencode
    wrapProgram $out/bin/opencode \
      --prefix PATH : ${lib.makeBinPath [ fzf ripgrep ]}
    runHook postInstall
  '';
  meta = {
    description = "OpenCode with prompt caching and local patches";
    homepage = "https://github.com/johnnymo87/opencode-patched";
    mainProgram = "opencode";
  };
}
