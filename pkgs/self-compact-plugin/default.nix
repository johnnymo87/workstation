# Builds the self-compact opencode plugin as a self-contained JavaScript
# bundle. See docs/plans/2026-04-21-self-compact-bundle-design.md for the
# original design and docs/plans/2026-06-22-durable-bun-fod-design.md for the
# content-addressed deps migration (workstation-g9fe).
#
# Two stages:
#   1. nodeModules — node_modules built by `importNpmLock.buildNodeModules` from
#      the committed package-lock.json. Each dependency is fetched via fetchurl
#      keyed by the lockfile's own SRI integrity, so this stage is
#      content-addressed by package content (NOT a recursive hash over bun's
#      on-disk tree). There is NO outputHash to maintain and NO bun in this
#      stage: a nixpkgs bun OR node bump can at most trigger a normal rebuild,
#      never a fixed-output hash mismatch. This supersedes the old bun-install
#      FOD (and workstation-l0f6's --cpu/--os + per-system outputHash hack,
#      both of which existed only to stabilize that recursive tree hash).
#   2. bundle — a regular derivation that copies sources + node_modules, runs
#      `bun build --target=bun --format=esm`, and runs a checkPhase that loads
#      the built artifact under `bun --no-install` (matching opencode's runtime
#      exactly). Outputs $out/self-compact.js (+ map).
#
# To bump deps: edit package.json, regenerate the lockfile with
#   (cd assets/opencode/plugins && npm install --package-lock-only --ignore-scripts)
# and commit package-lock.json. No hash edits anywhere.
{ lib
, stdenvNoCC
, bun
, nodejs
, importNpmLock
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  # Stage 1: content-addressed node_modules. Read the committed manifests
  # directly (pure eval over source files — not IFD) so this stage depends only
  # on package.json + package-lock.json content, never on plugin code changes.
  # --omit=dev keeps only runtime deps (matches the old `bun install
  # --production`); the bundle inlines @opencode-ai/plugin + zod at build time.
  nodeModules = importNpmLock.buildNodeModules {
    package = lib.importJSON (pluginSrc + "/package.json");
    packageLock = lib.importJSON (pluginSrc + "/package-lock.json");
    inherit nodejs;
    derivationArgs = {
      pname = "self-compact-plugin-node-modules";
      version = "0.1.0";
      npmInstallFlags = [ "--omit=dev" ];
    };
  };

  # Stage 2: bundle the plugin as a self-contained .js. Pure derivation
  # (no network); takes nodeModules as a Nix input.
  bundle = stdenvNoCC.mkDerivation {
    pname = "self-compact-plugin";
    version = "0.1.0";

    src = pluginSrc;

    nativeBuildInputs = [ bun ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      # Bun.build needs node_modules in the build dir to resolve imports.
      ln -s ${nodeModules}/node_modules ./node_modules

      mkdir -p dist

      # Use --outdir (not --outfile) because Bun requires the directory
      # form when emitting an external sourcemap. Output filename is
      # derived from the entry point: self-compact.ts → self-compact.js
      # (+ self-compact.js.map for the sourcemap).
      bun build self-compact.ts \
        --target=bun \
        --format=esm \
        --outdir=dist \
        --sourcemap=external

      runHook postBuild
    '';

    doCheck = true;

    checkPhase = ''
      runHook preCheck

      # Smoke test: load the bundle exactly the way opencode's runtime
      # does. With --no-install, Bun cannot fall back to auto-install,
      # so any unbundled @opencode-ai/plugin reference would fail here.
      bun --no-install -e "
        const m = await import('$PWD/dist/self-compact.js');
        if (typeof m.default !== 'function') {
          console.error('FAIL: Expected default export to be a plugin factory function, got:', typeof m.default);
          process.exit(1);
        }
        console.log('OK: bundle loads cleanly under --no-install; default export is a function.');
      "

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp dist/self-compact.js $out/
      cp dist/self-compact.js.map $out/ 2>/dev/null || true
      runHook postInstall
    '';

    dontFixup = true;

    # Expose the deps stage so pkgs/self-compact-plugin/test.sh can assert the
    # durability invariants (no bun, no outputHash) directly.
    passthru = { inherit nodeModules; };

    meta = with lib; {
      description = "Self-contained bundle for the OpenCode self-compact plugin";
      homepage = "https://github.com/anomalyco/workstation";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };
in
bundle
