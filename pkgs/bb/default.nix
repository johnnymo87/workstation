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
  version = "5.0.432";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-arm64";
      hash = "sha256-dTT5LyFjucb70wcihnXDYHE+Znp8M/Wbi632nT/4dDQ=";
    };
    "x86_64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-x86_64";
      hash = "sha256-inhmJYuEb7Gva6V2nB/nEFy5Bw9KrAZiOeXBwALSaxs=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-arm64";
      hash = "sha256-a/sTGmBVbXWOz99kT5+A/IEvv1NWf4BC/cdqIZoBO4M=";
    };
    "x86_64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-x86_64";
      hash = "sha256-eX0ZzNnJE3LT1QgqPHAeT2djFR3zK8i7sVxtrQ74TzA=";
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
