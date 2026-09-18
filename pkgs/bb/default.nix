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
  version = "5.0.472";

  sources = {
    "aarch64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-arm64";
      hash = "sha256-6tEtucHvhs6Iu66T5znhwZownlKyjWQFnTu6opzGtaQ=";
    };
    "x86_64-linux" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-linux-x86_64";
      hash = "sha256-MieI3pz7T0tRpdnl8UowKb+C9TAZz0vVlAz/nZuA3tI=";
    };
    "aarch64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-arm64";
      hash = "sha256-fFso9vS1+IEJ+jdp4E9RHKAb7ZTdD4kSyWBt1Aw7FyM=";
    };
    "x86_64-darwin" = fetchurl {
      url = "https://github.com/buildbuddy-io/bazel/releases/download/${version}/bazel-${version}-darwin-x86_64";
      hash = "sha256-mo5Scz4FZMPvMIlmqJaFtu0CrUfhVnNASGOye85Aa30=";
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
