# Shared builder for opencode plugins that ship as a self-contained JavaScript
# bundle. Callers are one-screen wrappers in pkgs/<name>/default.nix.
#
# WHY BUNDLE AT ALL. opencode resolves a plugin entry through realpathSync
# before importing it, so a deployed plugin sees import.meta.url as its
# /nix/store path. A multi-file plugin deployed as per-file xdg.configFile
# entries therefore lands one file per store path and its sibling import throws
# at import time -- and opencode SWALLOWS that: `opencode debug info` still
# lists the plugin and opencode.log stays empty. Separately, opencode loads every
# LOADABLE module in ~/.config/opencode/plugins as a plugin (.ts/.js -- a
# deployed .js.map sits there harmlessly), so shipping a helper .ts there also
# logs `Plugin export is not a function` on every bootstrap. Bundling
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
  # Opt out of the checkPhase's "invoke the factory and assert a hooks object"
  # assertion, for a plugin whose factory genuinely cannot return inside the
  # build sandbox (no network, no secrets, scrubbed env).
  #
  # This exists so that degradation is a REVIEWED DECISION rather than a silent
  # one. The obvious alternative -- treat a sandbox throw as a pass -- means a
  # plugin can stop being covered with no signal beyond an "OK: factory threw"
  # line buried in a passing build log that nobody reads. That is the same
  # skipped-assertion-is-not-a-passing-one failure the store-prefix check in
  # flake.nix was written up for. Both current callers return cleanly under the
  # mock, so the strict default costs nothing today.
  #
  # A runtime throw is separately contained: applyPlugin runs inside
  # Effect.tryPromise, so opencode drops the plugin and logs `failed to load
  # plugin` rather than dying. Catching THAT is step 2's job (the E2 canary).
  # This build check's job is the shape ratchet, and a ratchet that can quietly
  # disengage is not one.
, factoryMayThrowInSandbox ? false
}:

let
  pluginSrc = ../../assets/opencode/plugins;

  # `entry` is interpolated raw into three shell phases AND into a JS string
  # inside a double-quoted bash argument, so a space/quote/$ in it would break
  # those in confusing ways. It is only ever a bare basename; assert that.
  checkedEntry =
    assert lib.assertMsg (builtins.match "[A-Za-z0-9._-]+" entry != null)
      "opencode-plugin-bundle: `entry` must be a bare basename (got: ${entry})";
    entry;

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
      # NOT the caller's `version`. This stage's content is determined by the
      # lockfile alone, so tying it to a plugin's version would silently fork
      # the "shared" deps derivation the moment one caller bumped -- defeating
      # the sharing this pname exists to guarantee.
      version = "0.1.0";
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
      # derived from the entry point: ${checkedEntry}.ts -> ${checkedEntry}.js
      # (+ ${checkedEntry}.js.map for the sourcemap).
      bun build ${checkedEntry}.ts \
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
      #
      # THIS ASSERTS THE v1 PLUGIN SHAPE against the ARTIFACT, which is the only
      # thing opencode ever loads. Asserting it here rather than reasoning about
      # bundler semantics is deliberate: `bun build --format=esm` preserving the
      # entry module's default export is a property of the bun in nixpkgs at
      # this instant, and bun moves under us on the 8-hourly auto-update with
      # zero edits to this repo. A property that is checked on every rebuild
      # cannot silently stop being true.
      #
      # The last three conditions MIRROR readPluginId/readV1Plugin in opencode's
      # loader: each is a shape that gets the whole file QUIETLY rejected at
      # load -- one ERROR line, a serve that looks perfectly healthy, and a
      # plugin that simply is not there (shell-env, dead ~32h, 2026-07-30..08-01).
      #
      # The FIRST condition is different in kind and is deliberately stricter
      # than the loader. A bare-function default in a BUNDLE loads fine today:
      # the artifact has no named exports, so the legacy branch accepts it --
      # that was the shipped state here for months. It is rejected because
      # reverting to the legacy shape re-arms the footgun for the next person
      # who adds a helper export, i.e. it is a policy ratchet, not a mirror.
      # Calling it a mirror would be exactly the hand-written-rule-about-the-
      # loader habit this bead exists to end, so: it is a rule, and this is why.
      #
      #   not a record  -> falls through to the legacy branch (loads today; the
      #                    ratchet above is what refuses it)
      #   id missing    -> `Path plugin ... must export id` (file-sourced)
      #   id whitespace -> readPluginId TRIMS before its empty check, so " "
      #                    passes a naive non-empty test and throws `has an
      #                    empty id`
      #   tui present   -> `must default export either server() or tui(), not
      #                    both`
      #
      # Arrays are excluded because upstream's isRecord does; `typeof === object`
      # alone would admit one.
      #
      # LOADER_SEMANTICS_PIN: 1.18.18
      #
      # THIS IS THE THIRD COPY of loader semantics in the repo. The marker above
      # couples it to the other two. The other two -- the vendored fixtures under
      # assets/opencode/plugins/test/fixtures/ and the replica in
      # test/plugin-loader-contract.test.ts -- are held to opencode's deployed
      # version by users/dev/test-loader-pin.sh (a `nix flake check` gate), and that
      # guard now checks the marker above too. When the pin moves, re-read
      # readV1Plugin and readPluginId, confirm this block still mirrors them,
      # and move the marker. CI will tell you -- an earlier revision of this
      # comment said "nothing will tell you", which was true and was the whole
      # problem.
      bun --no-install -e "
        const m = await import('$PWD/dist/${checkedEntry}.js');
        const d = m.default;
        if (d === null || typeof d !== 'object' || Array.isArray(d)) {
          console.error('FAIL: Expected default export to be a v1 plugin record { id, server }, got:', Array.isArray(d) ? 'array' : typeof d);
          process.exit(1);
        }
        if (typeof d.id !== 'string' || d.id.trim().length === 0) {
          console.error('FAIL: v1 plugin default export needs a non-empty, non-whitespace string \`id\`; got:', JSON.stringify(d.id));
          process.exit(1);
        }
        if (typeof d.server !== 'function') {
          console.error('FAIL: v1 plugin default export needs a \`server\` function; got:', typeof d.server);
          process.exit(1);
        }
        if (d.tui !== undefined) {
          console.error('FAIL: v1 plugin default export has BOTH server and tui; opencode rejects the file.');
          process.exit(1);
        }

        // Invoke the factory and assert it resolves to a hooks OBJECT.
        //
        // The v1 branch pushes this return value into the hooks array WITHOUT
        // validating it (plugin/index.ts:114), exactly as the legacy branch
        // does. A factory resolving to undefined therefore still poisons the
        // array and still takes the whole serve down -- no provider catalog, no
        // prompts. That is the 2026-07-30 devbox outage, and adopting the v1
        // shape does not fix it.
        //
        // The .ts plugins get this assertion from plugin-loader-contract.test.ts,
        // but that test's existsSync filter cannot see BUNDLES. Until step 4 of
        // docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md runs CI
        // against deployed artifacts, this line is the ONLY coverage of that
        // shape for this bundle.
        // THREW is a distinct outcome from RESOLVED-TO-UNDEFINED and must not
        // be collapsed into it: a sentinel is used rather than leaving \`hooks\`
        // undefined on the catch path, because \`undefined\` is itself the single
        // most dangerous return value here and a check that skips on it would
        // wave through the exact shape this is written to catch.
        const THREW = Symbol('threw');
        const mayThrow = ${if factoryMayThrowInSandbox then "true" else "false"};
        let hooks;
        try {
          // \`client\` is a stub rather than undefined so the factory gets far
          // enough to RETURN. With \`client: undefined\`, self-compact throws on
          // \`ctx.client._client\` and takes the contained-throw path below --
          // which passes without ever reaching the hook-shape assertion, i.e.
          // the assertion silently covers nothing. A mock that merely avoids
          // crashing is the difference between this check working and this
          // check being decoration.
          // Mirrors the ctx opencode actually hands a plugin. \`serverUrl\` and
          // \`\$\` are NOT undefined in the real thing -- upstream always builds a
          // serverUrl (falling back to a literal localhost serve URL), and \$ is
          // Bun's shell, which exists here because this runs under bun. Handing
          // over undefined for either invites a spurious sandbox throw whose
          // only effect would be to disable the assertion below.
          //
          // The host:port is deliberately NOT upstream's literal. Only its
          // SHAPE matters here -- nothing in a build sandbox may talk to a
          // serve, and copying the real port would hardcode a serve-pool
          // internal into a mock that gains nothing from it (and trips the
          // frontdoor-opacity guard, correctly). A URL that cannot resolve is
          // the honest choice: if a factory ever tries to USE it, the resulting
          // failure is loud rather than a silent hit on a real serve.
          const mockCtx = {
            client: { _client: { getConfig: () => ({}) } },
            app: {},
            \$: (globalThis.Bun && globalThis.Bun.\$) || undefined,
            directory: process.cwd(),
            worktree: process.cwd(),
            serverUrl: new URL('http://bundle-check.invalid'),
            project: { id: 'bundle-check' },
          };
          hooks = await d.server(mockCtx, {});
        } catch (e) {
          // A sandbox throw is NOT treated as a pass. At runtime it would be
          // contained (Effect.tryPromise drops the plugin and logs \`failed to
          // load plugin\`), but here it means the hook-shape assertion below
          // asserted NOTHING -- and a coverage loss that announces itself only
          // in a green build log is a coverage loss nobody will ever notice.
          // If a plugin legitimately cannot run in the sandbox, say so out loud
          // via factoryMayThrowInSandbox in its pkgs/<name>/default.nix.
          if (!mayThrow) {
            console.error('FAIL: plugin factory threw in the build sandbox:', e && e.message);
            console.error('      The hook-shape assertion therefore covered nothing. Either fix the mock ctx above,');
            console.error('      or set factoryMayThrowInSandbox = true in this plugin\\'s pkgs/<name>/default.nix to');
            console.error('      record that the gap is intentional.');
            process.exit(1);
          }
          console.log('SKIP: factory threw under the build sandbox and factoryMayThrowInSandbox is set; hook shape NOT checked for this plugin.');
          hooks = THREW;
        }
        if (hooks !== THREW && (hooks === null || typeof hooks !== 'object')) {
          console.error('FAIL: plugin factory resolved to', typeof hooks, '-- opencode pushes this into the hooks array unvalidated, which breaks every later hook iteration and takes down the serve.');
          process.exit(1);
        }
        console.log(hooks === THREW
          ? 'OK: bundle loads cleanly under --no-install; default export is a v1 plugin record (hook shape SKIPPED, see above).'
          : 'OK: bundle loads cleanly under --no-install; default export is a v1 plugin record and its factory is hook-shaped.');
      "

      # The whole point of bundling is that the artifact has no siblings to
      # resolve at runtime. Assert it: a relative specifier surviving into the
      # output means the bundler treated a local module as external, which
      # would fail at import time in the store -- silently, per the header.
      #
      # Two patterns. The first anchors at column 0 because that is where bun
      # emits externalised STATIC imports. The second is unanchored and catches
      # the dynamic forms -- import("./x") / require("./x") -- which the first
      # cannot see and which would otherwise fail only on the code path that
      # reaches them, long after load.
      if grep -nE "^[[:space:]]*(import|export)[^\"']*[\"']\.\.?/" dist/${checkedEntry}.js \
         || grep -nE "(import|require)\([[:space:]]*[\"']\.\.?/" dist/${checkedEntry}.js; then
        echo "FAIL: bundle contains a relative specifier; it is not self-contained." >&2
        exit 1
      fi

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp dist/${checkedEntry}.js $out/
      # NOT optional. opencode-config.nix deploys this map unconditionally, so a
      # silently-missing map would become a dangling symlink at activation. bun
      # bumps arrive automatically every 8h with auto-merge; if one ever changes
      # --sourcemap=external's behaviour, fail the build here rather than ship a
      # broken link.
      cp dist/${checkedEntry}.js.map $out/
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
