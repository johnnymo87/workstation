# BuildBuddy CLI -- Bazelisk wrapper plus subcommands for BuildBuddy
# (login, view, download, ...). We use it primarily as a CLI surface to the
# BuildBuddy enterprise API; see assets/opencode/skills/using-buildbuddy for
# the bb-test-log workflow built on top.
#
# Upstream releases prebuilt binaries per OS/arch on GitHub. The binaries are
# statically-linked Go (verified with `ldd`: "not a dynamic executable"), so
# no autoPatchelfHook is needed -- a plain mkDerivation that drops the binary
# into $out/bin is sufficient on every platform.
#
# Auto-updated by .github/workflows/update-bb.yml (mirrors update-gws.yml).
{
  lib,
  stdenv,
  fetchurl,
}:

let
  version = "5.0.502";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-arm64";
      hash = "sha256-yGN42C/NFzTYkmFbR/sc1n1Y9anV/QtJld8kgSNMAMc=";
    };
    "x86_64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-x86_64";
      hash = "sha256-olUcz0kJ9qvrdUe5Jg7plX1o0ELzBKdrX780TSj8tys=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-arm64";
      hash = "sha256-OXsUqdfP6BVNaw14QgMlgk7Bq9bq+mkFpfZXXEvXPAw=";
    };
    "x86_64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-x86_64";
      hash = "sha256-fFO/sqOPdmQeNXCY5b91cT1ZH8cs1k2ZCkEVeE1SHjE=";
    };
  };

in

stdenv.mkDerivation {
  pname = "bb";
  inherit version;

  src = sources.${stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  # The "source" is a single binary; skip unpack.
  dontUnpack = true;

  # Static Go binary -- nothing to patch.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/bb"
    runHook postInstall
  '';

  doCheck = false;

  meta = with lib; {
    description = "BuildBuddy CLI: Bazelisk wrapper with BuildBuddy auth, login, log viewing, and remote tools";
    homepage = "https://www.buildbuddy.io/docs/cli";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "bb";
    platforms = [ "aarch64-linux" "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ];
  };
}
