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
# don't trip Node fetch's hidden 5-minute timeout. undici is not in nixpkgs, so
# we install it via a fixed-output derivation (FOD), then vendor cli.js +
# node_modules into the store and wrap it with node. No playwright, no browser
# download, no bundler.
#
# To bump: change `rev`, refresh `src.hash`, and set `undiciVersion` to match
# the upstream package-lock.json (then refresh `nodeModules.outputHash`).
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  bun,
  cacert,
  nodejs,
  makeWrapper,
}:

let
  version = "0.1.0-unstable-2026-06-12";

  src = fetchFromGitHub {
    owner = "johnnymo87";
    repo = "chatgpt-relay";
    rev = "cb3bf1e27772a5e04be6a0e7a4478370ca222d0a";
    hash = "sha256-QqbgWFubF0qfbPYjMSDTdaWJoqmHM7BohwQE6iehRHs=";
  };

  # Exact undici version from chatgpt-relay's package-lock.json. undici has no
  # transitive dependencies, so a one-line manifest is enough.
  undiciVersion = "7.18.2";

  # Stage 1: install undici as an FOD. Network access is allowed, but the
  # result is pinned by outputHash. Refresh outputHash whenever undiciVersion
  # changes:
  #   1. set outputHash = lib.fakeHash
  #   2. nix build .#ask-question  → copy the "got: sha256-..." line back.
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "ask-question-node-modules";
    inherit version;

    dontUnpack = true;

    nativeBuildInputs = [ bun cacert ];

    buildPhase = ''
      runHook preBuild

      export HOME=$TMPDIR
      export BUN_INSTALL_CACHE_DIR=$TMPDIR/.bun-cache

      cat > package.json <<EOF
      {
        "name": "ask-question-deps",
        "version": "0.0.0",
        "private": true,
        "dependencies": { "undici": "${undiciVersion}" }
      }
      EOF

      bun install --no-progress --ignore-scripts

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -R node_modules $out/
      runHook postInstall
    '';

    # FOD: hash the entire node_modules tree.
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-jSRyfvA43qExaKzcySEMxmFKJCV4xPimEM5Mikj1fwM=";

    dontFixup = true;
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

  meta = with lib; {
    description = "chatgpt-relay client CLI: send prompts to ask-question-server over the localhost:3033 tunnel";
    homepage = "https://github.com/johnnymo87/chatgpt-relay";
    mainProgram = "ask-question";
    platforms = platforms.linux;
  };
}
