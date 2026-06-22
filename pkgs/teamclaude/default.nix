# teamclaude — a multi-account Claude Max proxy with automatic quota-based
# rotation. Used on devbox/cloudbox as a local Anthropic-API proxy
# (127.0.0.1:3456) that rotates across personal Claude Max accounts and injects
# the active account's OAuth token.
#
# This builds the johnnymo87/teamclaude fork (branch opus-aware), which adds
# per-model scoped weekly-limit awareness (Opus) with per-request model-aware
# failover on the base-URL relay. See
# docs/plans/2026-06-21-teamclaude-opus-aware-fork-*.
#
# Zero runtime dependencies (Node 18+ builtins only; verified: package.json has
# no `dependencies`, and src/ has no bare imports). So packaging is just: fetch
# the fork source, vendor it into the store, and wrap `src/index.js` with a
# pinned node. No node_modules, no bundler.
#
# To bump: push a new commit to the fork, then update `rev` to its SHA and
# refresh `src.hash` via
#   nix store prefetch-file --json --unpack \
#     https://github.com/johnnymo87/teamclaude/archive/<rev>.tar.gz | jq -r .hash
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  nodejs,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "teamclaude";
  version = "0-unstable-2026-06-22"; # fork; bump per pinned commit

  src = fetchFromGitHub {
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "51bd04067f496baca18eb7fcf79a27e9f08eaf31";
    hash = "sha256-v/9STwU9lzzIPz+Fd4b1M36V5wtC7nvse7X3R8Uvf7g=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # fetchFromGitHub unpacks to the repo root (not ./package as the npm tarball
  # did), so src/ and package.json ("type":"module", needed for ESM resolution)
  # are already at the top level — vendor the whole tree.
  installPhase = ''
    runHook preInstall

    dest="$out/lib/teamclaude"
    mkdir -p "$dest"
    cp -r . "$dest/"

    makeWrapper ${nodejs}/bin/node "$out/bin/teamclaude" \
      --add-flags "$dest/src/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Multi-account Claude Max proxy with automatic quota-based rotation";
    homepage = "https://github.com/KarpelesLab/teamclaude";
    license = lib.licenses.mit;
    mainProgram = "teamclaude";
    platforms = lib.platforms.unix;
  };
}
