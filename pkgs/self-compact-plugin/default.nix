# Builds the self-compact opencode plugin as a self-contained JavaScript
# bundle. See docs/plans/2026-04-21-self-compact-bundle-design.md for full
# design rationale.
#
# Two stages:
#   1. nodeModules — a fixed-output derivation (FOD) that runs
#      `bun install --frozen-lockfile` and outputs node_modules/. Network
#      access requires FOD; the outputHash only changes when bun.lock
#      changes.
#   2. bundle — a regular derivation that copies sources + node_modules,
#      runs `bun build --target=bun --format=esm`, and runs a checkPhase
#      that loads the built artifact under `bun --no-install` (matching
#      opencode's runtime exactly). Outputs $out/self-compact.js (+ map).
{ lib
, stdenvNoCC
, bun
, cacert
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  # Stage 1: fetch deps as an FOD. The install forces ALL platform variants
  # of optional native deps (see --cpu/--os below), so the output tree is
  # expected to be byte-identical on every host — outputHash.default below is
  # platform-INDEPENDENT. outputHash.default needs updating when bun.lock
  # changes. To refresh:
  #   1. Set the `default` value (see outputHash) to lib.fakeHash
  #   2. Run `nix build .#self-compact-plugin` and let it fail
  #   3. Copy the "got: sha256-..." line into `default` (same on all hosts)
  # If only ONE platform mismatches, add it to `overrides` instead (see there).
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "self-compact-plugin-node-modules";
    version = "0.1.0";

    # Only the install-input files matter for the FOD hash; including the
    # source files would make the hash churn on every plugin code change.
    src = lib.cleanSourceWith {
      src = pluginSrc;
      filter = path: type:
        let base = builtins.baseNameOf path;
        in builtins.elem base [ "package.json" "bun.lock" "bunfig.toml" ];
    };

    nativeBuildInputs = [ bun cacert ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/.bun-cache

      # --cpu='*' --os='*' force-install EVERY platform variant of optional
      # native deps (here @msgpackr-extract/* pulled transitively via
      # effect -> msgpackr). Without this, bun installs only the variant(s)
      # matching the BUILD host's arch/os, so the recursive FOD hash differs
      # per architecture (e.g. aarch64-linux vs darwin) — which is why a hash
      # committed from one machine kept breaking `home-manager switch` on the
      # others. Forcing the full superset makes node_modules identical on
      # every platform, giving one stable hash and ending the per-machine
      # hash tug-of-war. See workstation-l0f6.
      bun install \
        --frozen-lockfile \
        --production \
        --ignore-scripts \
        --no-progress \
        --cpu='*' \
        --os='*'

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R node_modules $out/
      runHook postInstall
    '';

    # FOD: hash the entire output tree. Allows network access to bun's
    # registry, but locks the result so subsequent builds are pure.
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    # Forcing all optional platform variants (see --cpu/--os in buildPhase)
    # makes node_modules platform-independent, so this single `default` hash
    # is expected to hold on EVERY system. The per-system `overrides` map is
    # an additive escape hatch: if some platform's bun ever lays the tree out
    # differently, add ONLY that system with its reported "got:" hash. Doing
    # so refreshes that one platform and can never re-break the others — which
    # ends the cross-machine hash tug-of-war that motivated this. The default
    # was verified on aarch64-linux (devbox/cloudbox). See workstation-l0f6.
    outputHash = let
      default = "sha256-eqQ4iTOvxw166aMJY0WghzcBltHKoq19CEvJN6pW3vM=";
      overrides = {
        # "aarch64-darwin" = "sha256-...";  # refresh in isolation if needed
      };
    in overrides.${stdenvNoCC.hostPlatform.system} or default;

    dontFixup = true;
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

    meta = with lib; {
      description = "Self-contained bundle for the OpenCode self-compact plugin";
      homepage = "https://github.com/anomalyco/workstation";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };
in
bundle
