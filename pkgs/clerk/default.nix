{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
}:

# Clerk CLI — "a pre-authenticated gateway to Clerk's Backend + Platform API".
#   https://github.com/clerk/cli
#
# Why a prebuilt-binary derivation (not buildGoModule / build-from-source)?
#   Despite the task brief, clerk/cli is NOT a Go project — it is a
#   TypeScript/Bun monorepo. Releases are produced with `bun build --compile`,
#   which emits a single ~100 MB self-contained executable that embeds the Bun
#   runtime alongside the bundled JS. Reproducing that build in the Nix sandbox
#   is genuinely infeasible: it needs the Bun toolchain plus network access to a
#   large npm dependency tree, and there is no vendorHash-style story for a
#   Bun-compiled artifact. The clean, declarative Nix path is therefore to pin
#   the official release binary (tag + sha256). Provenance is `binaryNativeCode`.
#
# Why NOT autoPatchelfHook / patchelf?
#   A Bun single-file executable finds its bundled payload by reading its own
#   file (`/proc/self/exe`) and seeking a trailer at EOF. patchelf rewrites the
#   ELF and moves the section-header table past that trailer, so Bun can no
#   longer find the payload and silently degrades to behaving like a bare `bun`
#   runtime. Likewise we cannot launch it via an explicit `ld.so <exe>` wrapper,
#   because then `/proc/self/exe` points at the loader, not at clerk — same
#   failure. So the binary must be executed *directly, unmodified*.
#
# How we make an unmodified foreign binary run on NixOS:
#   devbox and cloudbox enable `programs.nix-ld`, which installs
#   `/lib/ld-linux-*.so.*`. We keep the binary untouched and hand nix-ld the
#   real glibc loader + a library path (libstdc++/libgcc) via NIX_LD /
#   NIX_LD_LIBRARY_PATH, so runtime lib resolution is hermetic to this package
#   (only the `/lib/ld-linux-*` stub itself comes from the host's nix-ld).
#
# Why unset BUN_INSPECT?
#   opencode itself runs on Bun and exports BUN_INSPECT in its shells; any Bun
#   binary launched from there would try to attach a debugger and crash. We
#   strip that (and NODE_OPTIONS) in the wrapper so clerk is robust regardless
#   of who launches it.
#
# Bumping the version:
#   1. Update `version` to the new released tag (without the leading `v`).
#   2. Refresh each hash below (note --executable: the source is fetched with
#      the +x bit, so these are recursive/NAR SRI hashes, not flat hashes):
#        nix store prefetch-file --executable --json \
#          https://github.com/clerk/cli/releases/download/v<VER>/clerk-linux-arm64
let
  version = "2.2.0";

  # Maps Nix systems to the matching GitHub release asset + its recursive/NAR
  # sha256 (SRI), as produced by `fetchurl { executable = true; }`.
  # NixOS is glibc, so the non-`-musl` Linux assets are the correct ones.
  assets = {
    "aarch64-linux" = {
      name = "clerk-linux-arm64";
      hash = "sha256-5fz4oRqVxOyOwDcHq/Qz1UUe0WvvwamoWUgV9Wtag48=";
    };
    "x86_64-linux" = {
      name = "clerk-linux-x64";
      hash = "sha256-M95p7tu206H4oYux4uSiYJLsr6AYeIGifWxCP8AYkwg=";
    };
    "aarch64-darwin" = {
      name = "clerk-darwin-arm64";
      hash = "sha256-7j28MlO524EnyGqAnWbEDnMghM3X0eekOBqk3cCXIuU=";
    };
    "x86_64-darwin" = {
      name = "clerk-darwin-x64";
      hash = "sha256-yz6Z4TaBJDtM8+eMRMd0kmB7v1IHylPQEtMvvCrJDcw=";
    };
  };

  asset =
    assets.${stdenv.hostPlatform.system}
      or (throw "clerk: unsupported system ${stdenv.hostPlatform.system}");

  # Linux-only: nix-ld inputs so the unmodified Bun binary can resolve its libs.
  nixLdArgs = lib.optionalString stdenv.hostPlatform.isLinux ''
    --set NIX_LD ${stdenv.cc.bintools.dynamicLinker} \
    --prefix NIX_LD_LIBRARY_PATH : ${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}
  '';
in
stdenv.mkDerivation {
  pname = "clerk";
  inherit version;

  # `executable = true` sets +x on the fetched file (and makes fetchurl use a
  # recursive/NAR hash — see the SRI values above). We deliberately do NOT copy
  # the binary into $out: the ~100 MB
  # Bun executable stores its payload in a trailer at EOF, and copying it (and
  # the daemon's auto-optimise-store dedup pass) proved able to silently corrupt
  # that trailer on a disk-pressured store, degrading clerk to a bare `bun`
  # runtime. Instead the wrapper execs the fetchurl output in place — the source
  # store path is content-addressed and hash-verified, so it can't be truncated
  # without failing the build, and `/proc/self/exe` still resolves to the real
  # binary so Bun finds its payload.
  src = fetchurl {
    url = "https://github.com/clerk/cli/releases/download/v${version}/${asset.name}";
    inherit (asset) hash;
    executable = true;
  };

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    makeWrapper $src $out/bin/clerk \
      --unset BUN_INSPECT \
      --unset NODE_OPTIONS \
      ${nixLdArgs}
    runHook postInstall
  '';

  meta = with lib; {
    description = "Pre-authenticated gateway to Clerk's Backend + Platform API";
    homepage = "https://github.com/clerk/cli";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "clerk";
    platforms = builtins.attrNames assets;
  };
}
