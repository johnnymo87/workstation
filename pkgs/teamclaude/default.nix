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
# `balanced` came BACK on 2026-09-10, and the retirement note above is why this
# one is shaped differently. #282's `expiryRouting` did not solve the
# concentration problem, it relocated it: routing by soonest-expiry
# concentrates the fleet's spend on the soonest-expiring account BY DESIGN.
# Measured that day with healthy=0 and all four accounts at 5h ~ 1.0, the rank
# correlation between time-to-reset and drain was 4-of-4, monotone in both
# buckets (jonathan u7dF 0.97 vs 872 at 0.11). So `balanced` is re-added as a
# PORT ONTO v1.1.16 rather than a revert to the old fork -- keeping #191/#175
# and #282 -- expressed in v1.1.16's own band/pressure terms as a different
# pressure FUNCTION, not the old parallel `_select`. Bead
# claude-failover-proxy-yri.
#
# SCOPE, stated because it is easy to over-claim: this fixes WEEKLY
# DISTRIBUTION. It does NOT fix the 5-hour wall -- total 5h capacity is
# policy-independent -- and it plausibly makes intraday slightly WORSE, since it
# rotates more and each rotation costs a prompt-cache re-write. That trade is
# UNMEASURED: the replay harness built to measure it failed its own
# pre-registered gate and was closed without a verdict (bead
# claude-failover-proxy-tw9).
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
  version = "1.1.16-balanced"; # upstream v1.1.16 + local patches + balanced port

  src = fetchFromGitHub {
    # SMALL FORK. Branch local/v1116-patches = upstream v1.1.16 (eed7b33) + the
    # four self-contained commits below, PLUS the `balanced` routing port merged
    # 2026-09-10 as 2fc0258 (PR johnnymo87/teamclaude#1, 15 commits).
    #
    # THIS BUILD DEFAULTS TO `routingStrategy: "expiry"`, which is byte-for-byte
    # the behaviour of the previous pin. Deploying it therefore changes NOTHING
    # until ~/.config/teamclaude.json opts in with routingStrategy "balanced".
    # That opt-in is a separate, deliberate act: it ends the expiryRouting era
    # that Track A (bead claude-failover-proxy-1o1) is measuring, and that
    # measurement cannot be re-run afterwards.
    #
    # Balanced also makes `quotaProbeSeconds > 0` a FATAL startup requirement --
    # ranking by utilization removes drain's "unknown weekly ranks first"
    # discovery pressure, so the periodic prober becomes the only way an
    # account's quota is ever learned. Our config has 90.
    #
    # The four pre-existing patches, in order:
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
    # 1412/1412 tests green on this rev (1345 on the previous pin, of which all
    # 1345 still pass unmodified; upstream alone is 1331). One pre-existing
    # upstream flake, unrelated: test/throttle-revalidation.test.js:74 races a
    # 5 ms real-time window and fails ~1 run in 23 (bead
    # claude-failover-proxy-fvb).
    #
    # Rollback, cheapest first:
    #   1. CONFIG ONLY -- drop routingStrategy from ~/.config/teamclaude.json
    #      (or set it to "expiry"). No rebuild. This is the real rollback for
    #      anything balanced does wrong, and it is why the port ships behind a
    #      default rather than as a replacement.
    #   2. PREVIOUS PIN = rev 770b2612546ebfb67b9aa7df5130462a984b1331, hash
    #      sha256-7wxTjVdop0qApXNKQVERf9/tFZs9MLgkPfMoXCTMtNk=, version
    #      "1.1.16-local4".
    #   3. STOCK upstream = owner "KarpelesLab", rev
    #      eed7b330826ef07f2e8d90b2a8fb3cda900173cf (v1.1.16), its own hash,
    #      version "1.1.16". Costs the four patches above; no config change.
    # Previous pin (v1.1.13 + balanced routing, 34 days in production) =
    # rev 890108cb25c40ef779fe9ca8c305326e5a75f575, hash
    # sha256-wgPCwep9+M2LQkzfKyHt7vy5quYDi4S9ut6DdOEMy2w=, version
    # "1.1.13-balanced" -- and put routingStrategy/weeklyBalanceMargin back in
    # ~/.config/teamclaude.json, which this bump removes.
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "2fc0258715590215b77d4f2ee7f169b4789924c1"; # local/v1116-patches
    hash = "sha256-FGgGmZ3RQ7leKZe7XKlNqZSjVX3ocjiizt3rS0hCKPs=";
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
