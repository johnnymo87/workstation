{
  lib,
  stdenvNoCC,
  nodejs_22,
  tsx,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "opencode-frontdoor";
  version = "1.0.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./src ./package.json ./tsconfig.json ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    dest="$out/libexec/opencode-frontdoor"
    mkdir -p "$dest"
    cp -r . "$dest/"

    makeWrapper ${tsx}/bin/tsx "$out/bin/opencode-frontdoor" \
      --add-flags "$dest/src/main.ts" \
      --set FRONTDOOR_VERSION "$out" \
      --prefix PATH : ${lib.makeBinPath [ nodejs_22 ]}

    runHook postInstall
  '';

  # The vitest suite binds loopback sockets / uses fake timers against 127.0.0.1,
  # which the hermetic sandbox forbids — tests run OUTSIDE the sandbox via `./test.sh`.
  #
  # FABLE-P6-F5: this build does NOT typecheck or run tests — `installPhase` just
  # vendors the sources and tsx strips types at RUNTIME without checking. So a
  # type- or import-broken `src/` produces a GREEN nix build that only fails when
  # the unit (re)starts — and `restartIfChanged=false` on the system unit means a
  # broken package can sit until the next (possibly unattended canary) restart.
  # MANDATORY GATE: run `./test.sh` (npm ci + tsc --noEmit + vitest) and confirm it
  # passes BEFORE any `nixos-rebuild` that ships a new frontdoor build.
  doCheck = false;

  meta = {
    description = "Opaque single-port reverse proxy for the opencode serve pool";
    mainProgram = "opencode-frontdoor";
    platforms = lib.platforms.unix;
    license = lib.licenses.mit;
  };
}
