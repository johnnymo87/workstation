{
  lib,
  buildNpmPackage,
  nodejs_22,
  makeWrapper,
}:

buildNpmPackage rec {
  pname = "opencode-frontdoor";
  version = "1.0.0";

  nodejs = nodejs_22;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./package.json
      ./package-lock.json
      ./tsconfig.json
      ./tsconfig.build.json
    ];
  };

  npmDepsHash = "sha256-sd2sUEMSA6YphngTIaXMvrtSv78j1J/bArMwWipq8Iw=";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/opencode-frontdoor" "$out/bin"
    cp -r dist "$out/libexec/opencode-frontdoor/dist"

    makeWrapper ${lib.getExe nodejs_22} "$out/bin/opencode-frontdoor" \
      --add-flags "$out/libexec/opencode-frontdoor/dist/main.js" \
      --set FRONTDOOR_VERSION "$out"

    runHook postInstall
  '';

  # The vitest suite binds loopback sockets / uses fake timers against 127.0.0.1,
  # which the hermetic sandbox forbids — tests run OUTSIDE the sandbox via `./test.sh`.
  #
  # Since we use buildNpmPackage and tsc compiles our code during the build step,
  # the nix build now typechecks src (tsc emits + fails on type errors), closing
  # the F5 finding. A type- or import-broken src will fail the nix build.
  #
  # `./test.sh` is still required for running the vitest suite and for typechecking
  # the test files (which are not included in tsconfig.build.json).
  #
  # Bumping / regenerating package-lock.json:
  #   1. Regenerate lock: (cd pkgs/opencode-frontdoor && npm install --package-lock-only)
  #   2. Recompute npmDepsHash: nix run nixpkgs#prefetch-npm-deps -- pkgs/opencode-frontdoor/package-lock.json
  #   3. Update npmDepsHash below.
  doCheck = false;

  meta = {
    description = "Opaque single-port reverse proxy for the opencode serve pool";
    mainProgram = "opencode-frontdoor";
    platforms = lib.platforms.unix;
    license = lib.licenses.mit;
  };
}
