# teamclaude — @karpeleslab/teamclaude, a multi-account Claude Max proxy with
# automatic quota-based rotation. Used on devbox as a local Anthropic-API proxy
# (127.0.0.1:3456) that rotates across personal Claude Max accounts and injects
# the active account's OAuth token.
#
# Zero runtime dependencies (Node 18+ builtins only; verified: package.json has
# no `dependencies`, and src/ has no bare imports). So packaging is just: fetch
# the published npm tarball, vendor it into the store, and wrap `src/index.js`
# with a pinned node. No node_modules, no bundler.
#
# To bump: change `version` and refresh `src.hash` via
#   nix store prefetch-file --json \
#     https://registry.npmjs.org/@karpeleslab/teamclaude/-/teamclaude-<ver>.tgz \
#     | jq -r .hash
{
  lib,
  stdenvNoCC,
  fetchurl,
  nodejs,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "teamclaude";
  version = "1.0.7";

  src = fetchurl {
    url = "https://registry.npmjs.org/@karpeleslab/teamclaude/-/teamclaude-${version}.tgz";
    hash = "sha256-fxugj/n8wlerh7GsjRSgmMZSOMT2ITVVqxQ8F9Cy16M=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # The npm tarball unpacks into ./package (stdenv sets sourceRoot there).
  # ESM resolution needs the package's own package.json ("type":"module")
  # alongside src/, so vendor the whole package, not just src/.
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
