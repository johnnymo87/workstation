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
    # Unlike pkgs/vercel (which vendors node_modules at runtime), opencode-frontdoor
    # has ZERO runtime dependencies — the emitted dist/ imports only its own modules
    # and node stdlib (devDeps are build-only: typescript/@types/node/vitest). So we
    # ship dist/ alone; no node_modules in the runtime closure.
    cp -r dist "$out/libexec/opencode-frontdoor/dist"

    makeWrapper ${lib.getExe nodejs_22} "$out/bin/opencode-frontdoor" \
      --add-flags "$out/libexec/opencode-frontdoor/dist/main.js" \
      --set FRONTDOOR_VERSION "$out"

    runHook postInstall
  '';

  # doCheck stays false, but NOT for the reason this comment used to give.
  #
  # The old rationale was that the vitest suite "binds loopback sockets / uses
  # fake timers against 127.0.0.1, which the hermetic sandbox forbids". That is
  # false — route-gate.nix next door boots a whole opencode serve on loopback
  # inside the sandbox — and believing it kept 496 assertions out of CI. The
  # suite now runs hermetically as `checks.frontdoor-vitest` in flake.nix.
  #
  # It stays false because a checkPhase is the WRONG channel here, twice over.
  # The `src` fileset above deliberately ships no test/ directory, so a check
  # phase would find nothing without widening what the shipped artifact
  # carries. And users/dev/test-unwired-tests.sh explicitly refuses to accept
  # doCheck/checkPhase as evidence that a test runs — oc-session-list set
  # doCheck = true while its checkPhase ran `--help` and its 700-line suite
  # never ran at all. A separate checks entry is the blessed, legible channel.
  #
  # Since we use buildNpmPackage and tsc compiles our code during the build step,
  # the nix build now typechecks src (tsc emits + fails on type errors), closing
  # the F5 finding. A type- or import-broken src will fail the nix build.
  #
  # Note that build-time tsc covers tsconfig.build.json, which EXCLUDES test/.
  # The type-correctness of the 25 test files is therefore checked by
  # `checks.frontdoor-vitest` (which runs `tsc --noEmit` over tsconfig.json)
  # and by nothing here.
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
