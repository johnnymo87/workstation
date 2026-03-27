{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  version = "0.22.3";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/google-workspace-cli-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-MqYUmQsD0lSrsSa5/JvStJhbZh0lxXeOhe6dZVbEwJw=";
    };
    "x86_64-linux" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz";
      hash = "sha256-uVHvhHs43UGiPTGjrq88tlBCGqxge7/mNye/T0ITzkQ=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/googleworkspace/cli/releases/download/v${version}/google-workspace-cli-aarch64-apple-darwin.tar.gz";
      hash = "sha256-PlaugAW/M+wUuj7xVBeSsmfvC23mw0RXPqwZRX45bZk=";
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
    install -Dm755 google-workspace-cli-*/gws $out/bin/gws
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
