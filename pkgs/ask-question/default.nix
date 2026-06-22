# ask-question — the client half of johnnymo87/chatgpt-relay.
#
# Only the `ask-question` CLI is packaged here: a thin ESM HTTP client that
# POSTs prompts to `ask-question-server` (running on macOS with a real
# browser) over the localhost:3033 SSH reverse tunnel. The `ask-question-server`
# and `ask-question-login` commands are intentionally NOT packaged — they need
# playwright + a browser and only ever run on the macOS side.
#
# cli.js's only third-party dependency is `undici`, used purely to build an
# Agent with headersTimeout/bodyTimeout disabled so long ChatGPT responses
# don't trip Node fetch's hidden 5-minute timeout. We install it via
# `importNpmLock.buildNodeModules` from a committed deps/ manifest, then vendor
# cli.js + node_modules into the store and wrap it with node. The deps stage is
# content-addressed by deps/package-lock.json's per-package integrity (NOT a
# recursive hash over a bun-produced tree), so a nixpkgs bun/node bump can only
# trigger a normal rebuild, never a fixed-output hash mismatch. No bundler, no
# bun, no outputHash to refresh. See
# docs/plans/2026-06-22-durable-bun-fod-design.md (workstation-g9fe).
#
# To bump the source: change `rev` + refresh `src.hash`.
# To bump undici: edit deps/package.json, then regenerate the lockfile with
#   (cd pkgs/ask-question/deps && npm install --package-lock-only --ignore-scripts)
# and commit deps/package-lock.json. No hash edits.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  nodejs,
  makeWrapper,
  importNpmLock,
}:

let
  version = "0.1.0-unstable-2026-06-12";

  src = fetchFromGitHub {
    owner = "johnnymo87";
    repo = "chatgpt-relay";
    rev = "cb3bf1e27772a5e04be6a0e7a4478370ca222d0a";
    hash = "sha256-QqbgWFubF0qfbPYjMSDTdaWJoqmHM7BohwQE6iehRHs=";
  };

  # Stage 1: content-addressed node_modules built by npm from the committed
  # deps/ manifest. undici is fetched via fetchurl keyed by the lockfile's SRI
  # integrity, so there is no outputHash and no bun in this stage.
  nodeModules = importNpmLock.buildNodeModules {
    package = lib.importJSON ./deps/package.json;
    packageLock = lib.importJSON ./deps/package-lock.json;
    inherit nodejs;
    derivationArgs = {
      pname = "ask-question-node-modules";
      inherit version;
    };
  };
in
stdenvNoCC.mkDerivation {
  pname = "ask-question";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/ask-question

    # cli.js is ESM (top-level `import`). node only treats `.mjs` as ESM
    # unconditionally, so vendor it under that extension.
    cp ${src}/src/cli.js $out/libexec/ask-question/ask-question.mjs

    # Co-locate node_modules so node resolves the bare `undici` import from the
    # file's own directory.
    cp -R ${nodeModules}/node_modules $out/libexec/ask-question/node_modules

    makeWrapper ${nodejs}/bin/node $out/bin/ask-question \
      --add-flags $out/libexec/ask-question/ask-question.mjs

    runHook postInstall
  '';

  dontFixup = true;

  # Expose the deps stage so pkgs/ask-question/test.sh can assert the
  # durability invariants (no bun, no outputHash) directly.
  passthru = { inherit nodeModules; };

  meta = with lib; {
    description = "chatgpt-relay client CLI: send prompts to ask-question-server over the localhost:3033 tunnel";
    homepage = "https://github.com/johnnymo87/chatgpt-relay";
    mainProgram = "ask-question";
    platforms = platforms.linux;
  };
}
