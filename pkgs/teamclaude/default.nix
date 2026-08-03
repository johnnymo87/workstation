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
# Zero runtime dependencies (verified again at v1.1.11: package.json has no
# `dependencies` key at all, and every src/ import is either relative or a
# `node:` builtin). So packaging is just: fetch the source, vendor it into the
# store, and wrap `src/index.js` with a pinned node. No node_modules, no bundler.
#
# NODE FLOOR: upstream raised `engines.node` to >=20 in v1.1.9 (#128 fixed a
# Node-18 stream crash); still >=20.0.0 at v1.1.11. The generic `nodejs` attr
# resolves to 22.x in our pinned nixpkgs, so this is satisfied — but if that
# attr is ever pinned downward, teamclaude breaks at runtime, not at build time.
#
# RATE-LIMIT SEMANTICS (checked at v1.1.11, unchanged since 1.1.9): there are
# two distinct 429 paths in src/server.js. A *quota rejection* — upstream sends
# `anthropic-ratelimit-unified-{5h,7d}-status: rejected` — throttles the account
# and ROTATES. A *transient* rate-limit 429 (no such header) deliberately does
# NOT rotate: it pauses the account and retries the same one, because moving a
# burst to the next account just throttles that one too (upstream #84,
# thundering herd) and discards the account's KV cache. `switchThreshold` only
# feeds proactive utilization-based selection and has no effect on 429 handling.
# The inline wait is capped by TEAMCLAUDE_RATE_LIMIT_ABSORB_MAX_SECONDS
# (default 60); we leave it at the default deliberately, since a slow success
# beats surfacing a hard 429 to clients.
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
  version = "1.1.11-balanced"; # fork of upstream v1.1.11 + weekly-balanced routing

  src = fetchFromGitHub {
    # TEMPORARY FORK. Rollback = restore owner "KarpelesLab", rev
    # b556533836d1f5b64dc4919a55368fae9e083751, hash
    # sha256-2WmLMu6zTNHRonOV5Iw1QtGBa7Z4TCVfGB3Rj/lKznk=, and version "1.1.11".
    # Branch feat/weekly-balanced-routing = v1.1.11 + 5 commits adding the opt-in
    # `balanced` routing strategy (see claude-failover-proxy bead cto.3). Not yet
    # upstreamed, so this cannot be a tag.
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "79f1f69469d379ae84435ffefb7ca08c0d1c410e"; # feat/weekly-balanced-routing
    hash = "sha256-R0S+4Fr750rblKTYQLERgEW4PmcFyuQO03ObP93Pw+g=";
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
