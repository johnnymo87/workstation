# Shared builder for opencode plugins that ship as a self-contained JavaScript
# bundle. Callers are one-screen wrappers in pkgs/<name>/default.nix.
#
# WHY BUNDLE AT ALL. opencode resolves a plugin entry through realpathSync
# before importing it, so a deployed plugin sees import.meta.url as its
# /nix/store path. A multi-file plugin deployed as per-file xdg.configFile
# entries therefore lands one file per store path and its sibling import throws
# at import time -- and opencode SWALLOWS that: `opencode debug info` still
# lists the plugin and opencode.log stays empty. Separately, every file in
# ~/.config/opencode/plugins is loaded as a plugin, so shipping a helper module
# there also logs `Plugin export is not a function` on every bootstrap. Bundling
# to a single file removes both failure modes: one file, no siblings, no
# node_modules at runtime.
#
# Two stages:
#   1. nodeModules -- node_modules built by `importNpmLock.buildNodeModules`
#      from the committed package-lock.json. Each dependency is fetched via
#      fetchurl keyed by the lockfile's own SRI integrity, so this stage is
#      content-addressed by package content (NOT a recursive hash over bun's
#      on-disk tree). There is NO outputHash to maintain and NO bun in this
#      stage: a nixpkgs bun OR node bump can at most trigger a normal rebuild,
#      never a fixed-output hash mismatch. This supersedes the old bun-install
#      FOD (and workstation-l0f6's --cpu/--os + per-system outputHash hack,
#      both of which existed only to stabilize that recursive tree hash).
#      See docs/plans/2026-06-22-durable-bun-fod-design.md.
#   2. bundle -- a regular derivation that copies sources + node_modules, runs
#      `bun build --target=bun --format=esm`, and runs a checkPhase that loads
#      the built artifact under `bun --no-install` (matching opencode's runtime
#      exactly). Outputs $out/<entry>.js (+ map).
#
# The deps stage is shared across callers on purpose: every plugin here builds
# from the SAME assets/opencode/plugins/package-lock.json, so a per-caller pname
# would build byte-identical node_modules once per plugin and let the copies
# drift. `pname` below is deliberately not caller-derived.
#
# To bump deps: edit package.json, regenerate the lockfile with
#   (cd assets/opencode/plugins && npm install --package-lock-only --ignore-scripts)
# and commit package-lock.json. No hash edits anywhere.
{ lib
, stdenvNoCC
, bun
, nodejs
, importNpmLock
  # Caller-supplied:
, pname          # derivation name, e.g. "session-state-plugin"
, entry          # entry basename WITHOUT extension, e.g. "session-state";
                 # bun derives the output filename from it (foo.ts -> foo.js)
, description
, version ? "0.1.0"
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  # Stage 1. Read the committed manifests directly (pure eval over source files
  # -- not IFD) so this stage depends only on package.json + package-lock.json
  # content, never on plugin code changes. --omit=dev keeps only runtime deps
  # (matches the old `bun install --production`); the bundle inlines
  # @opencode-ai/plugin + zod at build time.
  nodeModules = importNpmLock.buildNodeModules {
    package = lib.importJSON (pluginSrc + "/package.json");
    packageLock = lib.importJSON (pluginSrc + "/package-lock.json");
    inherit nodejs;
    derivationArgs = {
      pname = "opencode-plugin-node-modules";
      inherit version;
      npmInstallFlags = [ "--omit=dev" ];
    };
  };

  # Stage 2: bundle the plugin as a self-contained .js. Pure derivation
  # (no network); takes nodeModules as a Nix input.
  bundle = stdenvNoCC.mkDerivation {
    inherit pname version;

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
      # derived from the entry point: ${entry}.ts -> ${entry}.js
      # (+ ${entry}.js.map for the sourcemap).
      bun build ${entry}.ts \
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
        const m = await import('$PWD/dist/${entry}.js');
        if (typeof m.default !== 'function') {
          console.error('FAIL: Expected default export to be a plugin factory function, got:', typeof m.default);
          process.exit(1);
        }
        console.log('OK: bundle loads cleanly under --no-install; default export is a function.');
      "

      # The whole point of bundling is that the artifact has no siblings to
      # resolve at runtime. Assert it: a relative import surviving into the
      # output means the bundler treated a local module as external, which
      # would fail at import time in the store -- silently, per the header.
      if grep -nE "^[[:space:]]*(import|export)[^\"']*[\"']\.\.?/" dist/${entry}.js; then
        echo "FAIL: bundle contains a relative import; it is not self-contained." >&2
        exit 1
      fi

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp dist/${entry}.js $out/
      cp dist/${entry}.js.map $out/ 2>/dev/null || true
      runHook postInstall
    '';

    dontFixup = true;

    # Expose the deps stage so pkgs/opencode-plugin-bundle/test.sh can assert
    # the durability invariants (no bun, no outputHash) directly.
    passthru = { inherit nodeModules; };

    meta = with lib; {
      inherit description;
      homepage = "https://github.com/anomalyco/workstation";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };
in
bundle
