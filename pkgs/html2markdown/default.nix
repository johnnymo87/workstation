{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

# NOTE: If buildGoModule causes issues, consider switching to pre-built
# binaries from GitHub releases (Linux arm64 + Darwin arm64 tarballs).
# See: https://github.com/JohannesKaufmann/html-to-markdown/releases
buildGoModule rec {
  pname = "html2markdown";
  version = "2.5.0";

  src = fetchFromGitHub {
    owner = "JohannesKaufmann";
    repo = "html-to-markdown";
    rev = "v${version}";
    hash = "sha256-xTfJNijtDlQ5oEZkl92KEyFg3U+Wl4nJcsT5puS7h4A=";
  };

  vendorHash = "sha256-ZU2sZZEmnVrrJb4SAAa4A4sYRtRxMgn5FaK9DByGQ2I=";

  subPackages = [ "cli/html2markdown" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  doCheck = false;

  meta = with lib; {
    description = "Convert HTML to Markdown";
    homepage = "https://github.com/JohannesKaufmann/html-to-markdown";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ fromSource ];
    mainProgram = "html2markdown";
    platforms = platforms.unix;
  };
}
