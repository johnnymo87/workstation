{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
}:

let
  version = "1.15.2";
in

stdenvNoCC.mkDerivation {
  pname = "terraform";
  inherit version;

  src = fetchurl {
    url = "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_arm64.zip";
    hash = "sha256-zydlfpa73GEW9MFqDIAdNq5kENchAYOlIKxrIZj7cj4=";
  };

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
    platforms = [ "aarch64-linux" ];
  };
}
