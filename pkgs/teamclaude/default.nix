# teamclaude — a multi-account Claude Max proxy with automatic quota-based
# rotation. Used on devbox/cloudbox as a local Anthropic-API proxy
# (127.0.0.1:3456) that rotates across personal Claude Max accounts and injects
# the active account's OAuth token.
#
# This builds upstream KarpelesLab/teamclaude plus a SHORT local patch series
# (see the fork note at `src` below). History of the fork: the "opus-aware"
# fork was retired 2026-07-06 once upstream #64/#69 covered it; the
# "balanced" weekly-routing fork (bead claude-failover-proxy-cto.3) was retired
# 2026-09-06 once upstream #191 fixed the family gate (#175) and #282 shipped
# opt-in `expiryRouting` for the concentration problem (#176). Both times the
# pattern held: file the issue, carry the patch only until upstream moves.
#
# Zero runtime dependencies (verified again at v1.1.16: package.json has no
# `dependencies` key at all, and every src/ import is either relative or a
# `node:` builtin). So packaging is just: fetch the source, vendor it into the
# store, and wrap `src/index.js` with a pinned node. No node_modules, no bundler.
#
# NODE FLOOR: upstream raised `engines.node` to >=20 in v1.1.9 (#128 fixed a
# Node-18 stream crash); still >=20.0.0 at v1.1.16. The generic `nodejs` attr
# resolves to 22.x in our pinned nixpkgs, so this is satisfied — but if that
# attr is ever pinned downward, teamclaude breaks at runtime, not at build time.
#
# RATE-LIMIT SEMANTICS (changed in v1.1.15 by #271): a *quota rejection* —
# upstream sends `anthropic-ratelimit-unified-{5h,7d}-status: rejected` —
# throttles the account and ROTATES, as before. A *transient* rate-limit 429
# (no such header) and an upstream 5xx now take ONE bounded failover hop to an
# untried sibling that is not itself inside a 429 pause, then fall back to the
# old same-account wait. Before #271 they never rotated (upstream #84,
# thundering herd), which stalled a fleet whose sibling was idle — upstream
# #137/#156/#165, and our own bead claude-failover-proxy-be0. The hop is bounded
# to one on purpose: if the second account is throttled too the limit is almost
# certainly per egress IP, and rotating further only pays cold caches.
# `switchThreshold` (and the per-bucket `switchThresholds` from #233) only feed
# proactive utilization-based selection and have no effect on 429 handling.
#
# To bump: pick a newer tag from https://github.com/KarpelesLab/teamclaude/tags,
# rebase branch local/v1116-patches (or its successor) on it in the fork,
# push, set `rev` to the new head, and refresh `src.hash` via
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
  version = "1.1.16-local4"; # upstream v1.1.16 + 4 local patches (see below)

  src = fetchFromGitHub {
    # SMALL FORK. Branch local/v1116-patches = upstream v1.1.16 (eed7b33) + four
    # self-contained commits, in order:
    #   d5bddec fix(routing): advisor-model family check in _selectNext's
    #           resurrect fallback (upstream checks _routeAllows only; a
    #           resurrect could land on an account whose advisor family bucket
    #           is spent). One line. Not filed upstream yet.
    #   333b313 feat(oauth): log the FIELD NAMES of a token-refresh response,
    #           once per shape.
    #   2f1a5c4 feat(oauth): log refresh_token_expires_in on EVERY refresh --
    #           the ~30d grant lifetime that kills accounts without warning is
    #           reported by the endpoint and upstream discards it (bead xyq).
    #   770b261 fix(routing): plan-less gating -- an account whose subscription
    #           lapsed keeps its OAuth grant, reports status=active and NO
    #           quota, and was never gated. Sustained over 3 silent probes,
    #           self-disabling when the whole fleet is silent, soft (the
    #           exhausted-probe path can still reach it). Returns the reason
    #           'plan-less' since #262 made _isAvailable a wrapper over
    #           unavailableReason() (bead claude-failover-proxy-arj).
    # 1345/1345 tests green on this rev (upstream alone is 1331).
    #
    # Rollback to STOCK upstream = owner "KarpelesLab",
    # rev eed7b330826ef07f2e8d90b2a8fb3cda900173cf (v1.1.16), its own hash,
    # version "1.1.16". Costs only the four patches above; no config change.
    # Previous pin (v1.1.13 + balanced routing, 34 days in production) =
    # rev 890108cb25c40ef779fe9ca8c305326e5a75f575, hash
    # sha256-wgPCwep9+M2LQkzfKyHt7vy5quYDi4S9ut6DdOEMy2w=, version
    # "1.1.13-balanced" -- and put routingStrategy/weeklyBalanceMargin back in
    # ~/.config/teamclaude.json, which this bump removes.
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "770b2612546ebfb67b9aa7df5130462a984b1331"; # local/v1116-patches
    hash = "sha256-7wxTjVdop0qApXNKQVERf9/tFZs9MLgkPfMoXCTMtNk=";
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
