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
# DOES UPSTREAM SUBSUME `balanced` YET? Checked at v1.1.20, answer is no. The
# obvious candidate is #290 ("adaptive distribution using plan tier and live
# congestion", v1.1.18), but its adaptive mode is consulted at exactly one call
# site -- `_pickLeastLoaded` -- reachable only from `_selectForSession`, which
# is gated on `distributeSessions`. WE RUN `distributeSessions: false`, so
# upstream's adaptive is inert in our configuration. Upstream still has no
# weekly-balance, margin, or `routingStrategy` logic anywhere on the
# rotation-cursor path; the only mention is a comment noting that #176 proposes
# a `routingStrategy` enum -- i.e. upstream treats our feature as an open
# proposal. Re-run this check on every bump; the day it flips, retire the fork.
#
# One composition is accepted by config validation and NOT covered by tests:
# `distributeSessions: "adaptive"` together with `routingStrategy: "balanced"`.
# Coherent in principle (balanced's band floor bounds the set, adaptive scores
# within it) but unheld by anything. Irrelevant while distributeSessions is
# false; matters the day anyone turns adaptive on. Bead
# claude-failover-proxy-ldc.
#
# To bump: pick a newer tag from https://github.com/KarpelesLab/teamclaude/tags,
# rebase branch feat/balanced-on-v1120 (or its successor) on it in the fork,
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
  version = "1.1.20-balanced"; # upstream v1.1.20 + local patches + balanced port

  src = fetchFromGitHub {
    # SMALL FORK. Branch feat/balanced-on-v1120 = upstream v1.1.20 (999eda4) +
    # the four self-contained commits below, PLUS the `balanced` routing port,
    # rebased 2026-09-13. 25 commits on top of v1.1.20.
    #
    # THIS BUILD DEFAULTS TO `routingStrategy: "expiry"` — but READ THE NEXT
    # PARAGRAPH BEFORE CONCLUDING A BUMP IS THEREFORE SAFE.
    #
    # The default is not what we run. cloudbox's ~/.config/teamclaude.json has
    # `routingStrategy: "balanced"` (confirmed 2026-09-13, 4 accounts,
    # quotaProbeSeconds 90, distributeSessions unset). The opt-in happened after
    # the v1.1.16 pin landed, so the "deploying changes nothing" reassurance
    # that was true for THAT bump is false for every bump after it: this one
    # carries a `balanced` implementation rebased across ~60 upstream commits
    # and four releases, and it goes live the moment the service restarts.
    # Rollback item 1 below (drop the config key, no rebuild) is the fast exit.
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
    # 1870/1870 tests green on this rev (1412 on the previous pin). The
    # throttle-revalidation flake below did not fire on this run.
    #
    # ONE REGRESSION WAS INTRODUCED BY THE REBASE AND FIXED IN IT (51d3aa6).
    # Upstream #361 made `previewRouteIndex` provider-scoped; our balanced
    # margin mirror kept passing `null` for `exclude`, so on a MIXED
    # Anthropic+Codex fleet the preview ranked across providers and could name a
    # Codex account while selection correctly stayed put. Display-only
    # (TUI/dashboard), and unreachable on a single-provider fleet like ours --
    # but it is the exact "our shape survived, upstream's changed underneath"
    # failure a rebase of this size exists to catch. Covered by a test that
    # fails without the fix.
    #
    # Rollback, cheapest first:
    #   1. CONFIG ONLY -- drop routingStrategy from ~/.config/teamclaude.json
    #      (or set it to "expiry"). No rebuild. This is the real rollback for
    #      anything balanced does wrong, and it is why the port ships behind a
    #      default rather than as a replacement.
    #   2. PREVIOUS PIN = rev 2fc0258715590215b77d4f2ee7f169b4789924c1, hash
    #      sha256-FGgGmZ3RQ7leKZe7XKlNqZSjVX3ocjiizt3rS0hCKPs=, version
    #      "1.1.16-balanced".
    #   3. STOCK upstream = owner "KarpelesLab", rev
    #      999eda4 (v1.1.20), its own hash, version "1.1.20". Costs the four
    #      patches AND balanced; no config change (we default to "expiry").
    # Previous pin (v1.1.13 + balanced routing, 34 days in production) =
    # rev 890108cb25c40ef779fe9ca8c305326e5a75f575, hash
    # sha256-wgPCwep9+M2LQkzfKyHt7vy5quYDi4S9ut6DdOEMy2w=, version
    # "1.1.13-balanced" -- and put routingStrategy/weeklyBalanceMargin back in
    # ~/.config/teamclaude.json, which this bump removes.
    owner = "johnnymo87";
    repo = "teamclaude";
    rev = "51d3aa6f42d0c9bb252fdead7c7d2a292f5c6ddb"; # feat/balanced-on-v1120
    hash = "sha256-l2IU8NmMtQ6+7+O5IJ9cMsBN4xuJNHyOIqr4g/RLZe4=";
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

    # teamclaude-seeded: exit 0 iff the config names at least one account.
    #
    # THE ONE PLACE THAT ANSWERS "is teamclaude usable here". Three separate
    # sites need that answer and they used to encode it three different ways:
    # the devbox systemd unit and the darwin launchd wrapper both tested mere
    # FILE EXISTENCE, while opencode-config.nix's injectTeamclaudeBaseUrl tested
    # the accounts array (added in #511). File existence is the wrong test --
    # teamclaude's own `loadOrCreateConfig()` writes a default config with
    # `accounts: []` on almost any CLI invocation, including at the top of
    # `teamclaude login` BEFORE the OAuth flow, so an aborted login leaves a file
    # that passes it while the server exits 1 and respawns forever. Shipping the
    # predicate as a binary means the next person cannot bring back a fourth
    # spelling.
    #
    # Node, not jq: node is already a pinned dependency here and is the same
    # parser teamclaude itself uses, so the check cannot disagree with the server
    # about what the config says.
    #
    # A FAILURE OF THE CHECK ITSELF ALSO READS AS "not seeded". If this binary
    # were missing or broken, systemd reports exit 203 and still SKIPS the unit
    # (Result=success), and the darwin wrapper's `|| exit 0` does the same. That
    # is the safe direction -- it cannot crash-loop -- but it does mean a broken
    # predicate looks exactly like an unseeded host. The store path is pinned
    # into the unit, so the GC cannot cause it.
    #
    # EXIT CODES ARE LOAD-BEARING. systemd's ExecCondition treats 1-254 as
    # "skip the unit cleanly" but 255 (and signals) as "the unit FAILED", so
    # every path here must land in 1-254. The catch-all is what guarantees that:
    # an unreadable file, malformed JSON or a surprise exception all become 1,
    # never an uncaught throw.
    cat > "$out/bin/teamclaude-seeded" <<'SEEDED'
#!/bin/sh
exec ${nodejs}/bin/node -e '
  try {
    const p = process.env.TEAMCLAUDE_CONFIG
      || ((process.env.XDG_CONFIG_HOME || (process.env.HOME + "/.config")) + "/teamclaude.json");
    const c = JSON.parse(require("fs").readFileSync(p, "utf8"));
    process.exit(Array.isArray(c.accounts) && c.accounts.length > 0 ? 0 : 1);
  } catch (e) {
    process.exit(1);
  }
'
SEEDED
    chmod +x "$out/bin/teamclaude-seeded"

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
