{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "0.8.0";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/gws-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-aJjR148eu+j+bFNqMW3Gm65MfRairwEoCBcD8oNY1y8=";
    };
    "x86_64-linux" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/gws-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-Sy28OxcWqgy/2R1Z6oltv16JOhUVlMNj8MmOdg4uUEY=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/gws-aarch64-apple-darwin.tar.gz";
      hash = "sha256-k2jJ5YHMJA/RZQSjaX18c3ELei5fxFGmSlaTWO8RZJk=";
    };
  };

  # Only x86_64-linux uses gnu (glibc-linked) and needs patching.
  # aarch64-linux uses musl (statically linked).
  isGnu = stdenv.hostPlatform.system == "x86_64-linux";

in

stdenv.mkDerivation {
  pname = "gws";
  inherit version;

  src = sources.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  sourceRoot = ".";

  nativeBuildInputs = lib.optionals isGnu [ autoPatchelfHook ];
  buildInputs = lib.optionals isGnu [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 gws-*/gws $out/bin/gws
    runHook postInstall
  '';

  # Musl binary is static — skip fixup. Gnu binary needs autoPatchelf.
  dontFixup = stdenv.isLinux && !isGnu;

  doCheck = false;

  meta = with lib; {
    description = "Google Workspace CLI for Drive, Gmail, Calendar, Sheets, Docs, Chat, Admin, and more";
    homepage = "https://github.com/googleworkspace/cli";
    license = licenses.asl20;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "gws";
    platforms = [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" ];
  };
}
