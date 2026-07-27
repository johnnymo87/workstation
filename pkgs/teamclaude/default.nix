# teamclaude — a multi-account Claude Max proxy with automatic quota-based
# rotation. Used on devbox/cloudbox as a local Anthropic-API proxy
# (127.0.0.1:3456) that rotates across personal Claude Max accounts and injects
# the active account's OAuth token.
#
# This builds upstream KarpelesLab/teamclaude (tagged releases). We previously
# ran the johnnymo87/teamclaude "opus-aware" fork to add per-model scoped
# weekly-limit awareness + model-aware failover; upstream has since implemented
# the same capability independently (PR #64 "track Fable weekly quota and route
# by model", #69 "rich status output"), so the fork was retired in favor of
# upstream on 2026-07-06.
#
# Zero runtime dependencies (verified again at v1.1.9: package.json `dependencies`
# is still {}, and src/ has no bare imports). So packaging is just: fetch the
# source, vendor it into the store, and wrap `src/index.js` with a pinned node.
# No node_modules, no bundler.
#
# NODE FLOOR: upstream raised `engines.node` to >=20 in v1.1.9 (#128 fixed a
# Node-18 stream crash). The generic `nodejs` attr resolves to 22.x in our
# pinned nixpkgs, so this is satisfied — but if that attr is ever pinned
# downward, teamclaude breaks at runtime, not at build time.
#
# To bump: pick a newer tag from https://github.com/KarpelesLab/teamclaude/tags,
# set `rev` to its commit SHA, bump `version`, and refresh `src.hash` via
#   nix store prefetch-file --json --unpack \
#     https://github.com/KarpelesLab/teamclaude/archive/<rev>.tar.gz | jq -r .hash
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  nodejs,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "teamclaude";
  version = "1.1.9"; # upstream tag; bump per pinned release

  src = fetchFromGitHub {
    owner = "KarpelesLab";
    repo = "teamclaude";
    rev = "7dfd47af62663f81c123a74463cc412675e84eb8"; # tag v1.1.9
    hash = "sha256-2XKao3/1bD0T9ebVNl09OmpHdsd2gcX6oj4A91XfaYQ=";
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
