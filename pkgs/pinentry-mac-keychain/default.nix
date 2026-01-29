{ lib, buildGoModule, fetchFromGitHub, pinentry_mac }:

buildGoModule rec {
  pname = "pinentry-mac-keychain";
  version = "unstable-2024-04-15";

  src = fetchFromGitHub {
    owner = "olebedev";
    repo = "pinentry-mac-keychain";
    rev = "082f5bfb0aadab9e1a823461a9e7e7be6b0b49b2";
    hash = "sha256-ErcLx0eokJ/JOE2xIDPTmg0s7kMP+1oNJ4yyYnkW7sI=";
  };

  # Patch to inject pinentry-mac path
  postPatch = ''
    substituteInPlace main.go \
      --replace '"/usr/local/MacGPG2/libexec/pinentry-mac.app/Contents/MacOS/pinentry-mac"' \
                '"${pinentry_mac}/bin/pinentry-mac"'
  '';

  vendorHash = "sha256-7UzdYGhi9asQRVb9EbaW0ijXf+lDnkM01Pv6yGsAghM=";

  meta = with lib; {
    description = "Pinentry with macOS keychain support";
    homepage = "https://github.com/olebedev/pinentry-mac-keychain";
    license = licenses.mit;
    platforms = platforms.darwin;
    mainProgram = "pinentry-mac-keychain";
  };
}
