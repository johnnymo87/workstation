{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "1.15.2";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_arm64.zip";
      hash = "sha256-zydlfpa73GEW9MFqDIAdNq5kENchAYOlIKxrIZj7cj4=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_darwin_arm64.zip";
      hash = "sha256-QgS8NFBBinzkI+WEUbBT5drtYlrWxqFd6YvAk0Umn5k=";
    };
  };
in

stdenvNoCC.mkDerivation {
  pname = "terraform";
  inherit version;

  src = sources.${stdenvNoCC.hostPlatform.system}
    or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");

  sourceRoot = ".";

  nativeBuildInputs = [ unzip ];

  installPhase = ''
    runHook preInstall
    install -Dm755 terraform $out/bin/terraform
    runHook postInstall
  '';

  doCheck = false;

  meta = with lib; {
    description = "Terraform CLI pinned for infra repositories requiring Terraform 1.15.x";
    homepage = "https://www.terraform.io/";
    license = licenses.unfree;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "terraform";
    platforms = [ "aarch64-linux" "aarch64-darwin" ];
  };
}
