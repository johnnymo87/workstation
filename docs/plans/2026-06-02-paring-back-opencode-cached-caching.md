# Paring back opencode-cached's `caching.patch` toward upstream `applyCaching`

**Date:** 2026-06-02
**Beads epic:** `workstation-nvj` (children `.1`–`.5`)
**Decision:** Option C / lean toward full drop — ride upstream's mature `applyCaching`
for moving-tail/vertex/bedrock caching; keep only the minimum upstream lacks.
**Hard guardrail (user):** must NOT lose first-party Anthropic caching benefits.

This document is the **preservation inventory**: every capability the fork's
`caching.patch` adds, its upstream parity, its measured/estimated value, and a
**restore recipe** so a future session can selectively bring a piece back
without re-deriving it.

---

## Background: why this is even on the table

- Pristine upstream `applyCaching` (`packages/opencode/src/provider/transform.ts`)
  **already anchors on the moving tail**:
  ```js
  const system = msgs.filter(m => m.role === "system").slice(0, 2)
  const final  = msgs.filter(m => m.role !== "system").slice(-2)  // last 2 non-system = tail
  ```
  Upstream **never had** our "stuck last-user anchor" bug. PR
  [anomalyco/opencode#5422](https://github.com/anomalyco/opencode/pull/5422)
  (the fork's `caching.patch`, **open/unmerged since 2025-12-12**) *introduced*
  it by replacing `slice(-2)` with a "last user message" anchor. Our
  `opencode-cached` PR #62 (2026-06-01) fixed it back to a moving tail.
- Upstream caching is mature + actively maintained: vertex enablement
  ([#20266](https://github.com/anomalyco/opencode/pull/20266), merged 2026-03-31),
  bedrock ([#18959](https://github.com/anomalyco/opencode/pull/18959)), azure,
  venice, alibaba; ~12 commits to `transform.ts` in the two weeks before
  2026-05-30.
- So the moving-tail behavior we care about is now **redundant** with upstream,
  and we're carrying a year-old unmerged parallel implementation we rebase every
  release and whose bugs we own (we just spent days fixing one we introduced).

## Workload measurement (DB, last 10 days) — the economic backdrop

| Route | turns | <5m gap | 5–60m gap | ≥60m gap | first |
|---|---|---|---|---|---|
| google-vertex-anthropic | 10,006 | **91.8%** | 5.0% | 0.6% | 2.5% |
| anthropic | 8,395 | **96.5%** | 2.1% | 0.6% | 0.8% |

The 1h-TTL win only exists on 5–60m-gap turns. Upper-bound value
(cache_read on those turns × $17.25/M Opus write−read delta):
**~$16/day (vertex) + ~$11/day (anthropic) ≈ $27/day combined**, and that's
*before* subtracting the higher cost of establishing 1h writes (2× vs 1.25×).
Compare: the moving-tail fix was ~$500/day. **1h TTL is marginal on our
rapid-fire workload.**

---

## Component inventory of `caching.patch`

Per-file numstat (vs upstream v1.15.13):

| File | +/− | Role |
|---|---|---|
| `provider/config.ts` | +857 / 0 (NEW) | `ProviderConfig` namespace: per-provider cache + prompt-order config for 25 providers, plus helper fns |
| `provider/transform.ts` | +192 / −42 | `applyCaching` rewrite + cache-option/TTL builders + tool-cache builder |
| `config/agent.ts` | +27 / −1 | Agent-level `cache` + `promptOrder` override schema |
| `config/provider.ts` | +25 / −1 | User-config (opencode.json) `cache` + `promptOrder` override schema |
| `session/tools.ts` | +30 / 0 | `sortTools` for prefix stability + dedicated tool cache breakpoint |
| `test/provider/config.test.ts` | +965 (NEW) | Tests for the config system |
| `test/provider/transform.test.ts` | +178 / −52 | Tests for the patched applyCaching |

### Capability-by-capability (with restore recipes)

#### 1. Moving-tail conversation anchor — **REDUNDANT, drop freely**
- **What:** anchors the conversation cache breakpoint on the last cacheable
  non-system message; skips `<context_usage>` telemetry + thinking blocks.
- **Upstream parity:** ✅ `final = non-system.slice(-2)` (upstream marks the last
  TWO non-system messages; fork marks ONE). Functionally equivalent for
  append-only caching.
- **Value:** this is the ~$500/day fix — but **upstream already does it.**
- **Restore recipe:** n/a — upstream provides it. (Our PR #62 diff in
  `opencode-cached` is the reference if upstream's ever regresses.)

#### 2. 1h TTL tiering — **MARGINAL (~$27/day upper bound), likely drop**
- **What:** `config.ts` sets `ttl:"1h"` for `anthropic` + `google-vertex-anthropic`
  on system/tools breakpoints; `transform.ts` `applyCaching` overrides the moving
  anchor to `5m` via `anchorOptions = buildCacheOptionsInternal(model, "5m")`.
  Vertex 1h verified header-free on Opus 4.x (rawPredict probe, 2026-05-29; see
  config.ts comment block).
- **Upstream parity:** ❌ upstream is flat `{ type: "ephemeral" }` = 5m.
- **Value:** marginal — see workload table. Only 2–5% of turns benefit.
- **Restore recipe:** re-introduce `ProviderConfig.buildCacheControl(providerID, ttl)`
  emitting `{ cacheControl: { type:"ephemeral", ttl:"1h" } }` and apply it to the
  system+tool breakpoints, keeping the moving anchor at 5m. Needs the config layer
  (#5) OR a hardcoded per-provider TTL map. Reference: `config.ts:794 buildCacheControl`,
  `transform.ts` `buildCacheOptionsInternal(model, ttlOverride)`.

#### 3. Stable tool ordering (`sortTools`) — **UNMEASURED, first-party-relevant**
- **What:** `session/tools.ts` sorts the tool list deterministically when
  `providerConfig.promptOrder.sortTools` is set, so the tool-definition prefix is
  byte-identical across requests (cacheable).
- **Upstream parity:** ❌ upstream `tools.ts` has no sort. Tools cache only
  *implicitly* via the system breakpoint, and only if their order happens to be
  byte-stable.
- **Value:** UNKNOWN without A/B. If upstream tool order is already stable, this
  is redundant; if not, dropping it busts the tool-prefix cache (hits BOTH routes,
  incl. first-party Anthropic). **This is the main thing the A/B build must check
  via cache_write rate.**
- **Restore recipe:** re-add the sort block at `session/tools.ts` `resolve()`
  (~line 203 in patched). It's ~10 lines and self-contained; could be a standalone
  micro-patch independent of the config system (hardcode "sort for anthropic-family").

#### 4. Dedicated tool cache breakpoint — **UNMEASURED, first-party-relevant**
- **What:** `session/tools.ts` applies a cache breakpoint to the LAST tool via
  `ProviderTransform.buildToolCacheOptions(model)` when
  `cache.enabled && promptOrder.toolCaching && supportsExplicitCaching`. Lets tool
  defs cache at 1h independently of a possibly-dynamic system prompt.
- **Upstream parity:** ❌ upstream caches tools only implicitly (system breakpoint
  covers the tools prefix). No independent tool breakpoint.
- **Value:** matters IF the system prompt has dynamic content that would otherwise
  bust the implicit tools cache. UNKNOWN without A/B.
- **Restore recipe:** re-add `buildToolCacheOptions` to `transform.ts` and the
  breakpoint-application block in `tools.ts`. Pairs with #3. Budget: costs 1 of the
  4 cache_control breakpoints.

#### 5. Thinking/reasoning block cache-skip — **KEEP (tiny) + UPSTREAM**
- **What:** `isCacheableBlock` excludes `reasoning`/`redacted-reasoning` (and
  tool-approval pseudo-blocks); `applyCaching` marks the last *cacheable* block,
  not blindly the last block.
- **Upstream parity:** ❌ upstream marks `msg.content[length-1]` blindly → can land
  on a reasoning block → Anthropic 400. Same bug is open upstream as
  [#17883](https://github.com/anomalyco/opencode/issues/17883).
- **Value:** correctness. We run adaptive reasoning on Opus 4.7+/4.8, so this can
  bite. ~5 lines.
- **Restore recipe / plan:** keep as a micro-patch on upstream `applyCaching`, AND
  send it upstream (epic task `workstation-nvj.5`) to fix #17883 — then even the
  micro-patch sunsets.

#### 6. `<context_usage>` telemetry skip — **drop unless telemetry kept**
- **What:** `applyCaching` skips messages containing `<context_usage>` when picking
  the anchor.
- **Upstream parity:** ❌ but `<context_usage>` is a LOCAL construct (not in pristine
  upstream). If we keep whatever injects it, upstream's `slice(-2)` could anchor on
  it. Verify whether it's still injected post-pare-back.
- **Restore recipe:** fold the skip into the thinking-skip micro-patch if needed.

#### 7. Per-provider/agent config schema (25 providers + override knobs) — **drop**
- **What:** `config.ts` `defaults` for 25 providers; `provider.ts`/`agent.ts` add
  `cache` + `promptOrder` override schema to opencode.json + agent config; helpers
  `getConfig`, `getConfigProviderID`, `detectEffectiveProvider`, `resolveMinTokens`,
  `supportsExplicitCaching`, `getCacheProperty`, `isCachingEnabled`,
  `getProviderOptionsKey`, `buildCacheControl`, `getPromptOrdering`,
  `fromUserProviderConfig`.
- **Upstream parity:** ❌ upstream hardcodes 6 providers in `applyCaching`. We don't
  use the 25-provider breadth or the user-override knobs.
- **Value:** the enabler for #2/#3/#4. Pure maintenance surface for us otherwise.
- **Restore recipe:** the whole `config.ts` is the artifact; restoring any of
  #2/#3/#4 in config-driven form means restoring (a subset of) this. A leaner
  alternative when restoring: hardcode the one or two knobs needed for
  anthropic-family rather than the full namespace.

---

## The A/B build gate (`workstation-nvj.1`)

Build a v1.15.13 binary **without** `caching.patch` (keep the other local patches:
tool-fix, mcp-reconnect, eager-input-streaming, gemini-empty-parts,
instance-state-partition; **+ a thinking-skip micro-patch** = capability #5). Run
identical workloads vs the deployed fork binary, isolated `XDG_DATA_HOME`:

1. Chained tool-loop (`/tmp/opencode/sessiontest` f1..f6), Vertex + first-party
   Anthropic Opus. Measure per-step **uncached%** (expect ~0 if upstream moving-tail
   works) AND **cache_write rate** (a spike = tool-prefix/system instability that #3/#4
   were preventing).
2. Reasoning-ON session: confirm whether plain upstream marks a thinking block → 400
   (#17883), i.e. whether the micro-patch is load-bearing.

**Decision rule:**
- Upstream matches (uncached ~0, cache_write low, no 400s) → **drop `caching.patch`
  entirely**, keep only the thinking-skip micro-patch, upstream it. ~1100 patch
  lines retired.
- cache_write spikes on either route → restore #3 (+#4) as a focused micro-patch.
- 400s with reasoning → micro-patch #5 is mandatory (it already is in the build).

## A/B RESULTS (2026-06-02) — full drop VALIDATED

Built `v1.15.13 + 8 non-caching local patches + thinking-skip micro-patch`,
**no `caching.patch`** (binary:
`/tmp/opencode/stacktest/opencode-src/packages/opencode/dist/opencode-linux-arm64/bin/opencode`).
All 8 non-caching patches apply clean to pristine — no entanglement with
`caching.patch`.

**Vertex Opus tool-loop (isolated data dir, 7 steps) — UPSTREAM `applyCaching`:**

| step | input | cache_read | cache_write | uncached% |
|---|---|---|---|---|
| 0 | 2 | 0 | 25,240 | 0.0% |
| 1 | 2 | 25,240 | 172 | 0.0% |
| 7 | 2 | 26,166 | 140 | 0.0% |

`cache_read` grows every step; `cache_write` = cold-start + tiny deltas;
write/read 14.6% (cold-start dominated). **Exactly matches the deployed fork
binary** (which was 0% uncached, cache_read 0→25,504, cache_write ~156 deltas).
=> Upstream moving-tail caches Vertex (the hard, no-auto-cache case) identically.
The low cache_write means **no tool-prefix busting** — the fork's `sortTools` +
dedicated tool breakpoint (#3/#4) are NOT load-bearing for our toolset.

**First-party Anthropic:** could not measure in the isolated harness — the
OAuth plugin (`@ex-machina/opencode-anthropic-auth`) won't activate outside the
production serve (`ProviderAuthError` even with `auth.json` copied +
`CLAUDE_CODE_OAUTH_TOKEN` set + temp serve). **Deferred to deploy-verification
(`nvj.4`) on the real serve.** Strong basis for parity: shared `applyCaching`
selection; first-party is the *easier* case (Anthropic API auto-extends the
prefix → only ~3% uncached even *with* the fork bug); tool-stability is
provider-agnostic and Vertex proved it stable.

**Decision:** FULL DROP of `caching.patch` + keep the thinking-skip micro-patch
is **validated**. Remaining design = the thinking-skip patch only (capability
#5). Gate first-party empirical confirmation at `nvj.4` before finalizing/archiving.

## READY-TO-USE: `cache-thinking-skip.patch` (the lone survivor)

Generated + verified 2026-06-02: applies clean to pristine v1.15.13 AND atop the
full non-caching local stack (prompt-loop-cache, cache-aligned-compaction,
gemini-empty-parts, vim, tool-fix, mcp-reconnect, eager-input-streaming,
instance-state-partition). Drop this file at `opencode-patched/patches/cache-thinking-skip.patch`:

```diff
diff --git a/packages/opencode/src/provider/transform.ts b/packages/opencode/src/provider/transform.ts
--- a/packages/opencode/src/provider/transform.ts
+++ b/packages/opencode/src/provider/transform.ts
@@ -375,13 +375,26 @@ function applyCaching(msgs: ModelMessage[], model: Provider.Model): ModelMessage
     const shouldUseContentOptions = !useMessageLevelOptions && Array.isArray(msg.content) && msg.content.length > 0
 
     if (shouldUseContentOptions) {
-      const lastContent = msg.content[msg.content.length - 1]
-      if (
-        lastContent &&
-        typeof lastContent === "object" &&
-        lastContent.type !== "tool-approval-request" &&
-        lastContent.type !== "tool-approval-response"
-      ) {
+      // Mark the last CACHEABLE block: scan backwards and skip trailing
+      // reasoning/redacted-reasoning (Anthropic rejects cache_control on thinking
+      // blocks -> HTTP 400, cf anomalyco/opencode#17883) and tool-approval
+      // pseudo-blocks. Upstream marked content[length-1] blindly.
+      let lastContent: any = undefined
+      for (let i = msg.content.length - 1; i >= 0; i--) {
+        const c = msg.content[i]
+        if (
+          c &&
+          typeof c === "object" &&
+          c.type !== "reasoning" &&
+          c.type !== "redacted-reasoning" &&
+          c.type !== "tool-approval-request" &&
+          c.type !== "tool-approval-response"
+        ) {
+          lastContent = c
+          break
+        }
+      }
+      if (lastContent) {
         lastContent.providerOptions = mergeDeep(lastContent.providerOptions ?? {}, providerOptions)
         continue
       }
```

(A copy also lives at `/tmp/opencode/cache-thinking-skip.patch` until /tmp is cleared.)

### nvj.3 implementation steps (opencode-patched repo)
1. Add `patches/cache-thinking-skip.patch` (above).
2. Edit `patches/apply.sh`: **remove** the "Patch 1: Caching (fetched from
   opencode-cached)" block (the `curl` of `CACHING_PATCH_URL` + its apply), and
   **add** an apply step for `cache-thinking-skip.patch`. This is what cuts the
   production dependency on opencode-cached (unblocks nvj.6 archive).
3. Update `.github/workflows/build-release.yml` release-notes body (drop "patch #1
   Prompt caching … via opencode-cached"; renumber) and the `notify-on-failure`
   caching-patch references.
4. Update opencode-patched README (caching now upstream; only thinking-skip local).
5. Deploy via the established chain: `gh workflow run build-release.yml --field
   version=1.15.13 --field revision=2` → bump 4 hashes + `patchedRevision="2"` in
   `users/dev/home.base.nix` (verify arm64 via `nix store prefetch-file`) → push →
   `nix run home-manager -- switch --flake .#cloudbox` → restart serve via the
   **cgroup-safe detached timer** (`sudo systemd-run --on-active=15s --unit=… systemctl
   restart opencode-serve.service`; bash lives in that cgroup, KillMode=control-group).
6. **nvj.4 GATE:** measure Vertex AND first-party Anthropic uncached% + cache_write
   rate over 24h vs the current fork. First-party MUST show no regression before
   nvj.6 (archive). Roll back (revert hashes) if uncached climbs or cache_write jumps.

## DEPLOY + GATE STATUS (nvj.4, 2026-06-02)

**Deployed.** opencode-patched PR #15 merged → built `v1.15.13-patched.2` (CI run
26829384638) → workstation `ffac48a` bumped 4 hashes + `patchedRevision="2"` →
`home-manager switch .#cloudbox` → **direct** `systemctl restart opencode-serve`
(safe: my session is `opencode` PID 2076575 under tmux/neovim in `user@1000.service`,
NOT in the serve's system cgroup — verified `served-by-1568995=no`; the prior
session's cgroup-kill risk did not apply this time). Serve now PID 2776098 running
`/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2`.

**Cutover timestamp:** `2026-06-02T15:24:59Z`.

**Fork .1 baseline (pre-cutover window 03:00:04Z→15:24:59Z, 12.4h) — the target:**

| provider | msgs | uncached% | write/(r+w)% |
|---|---|---|---|
| google-vertex-anthropic | 417 | **0.00%** | 6.08% |
| anthropic (first-party) | 279 | **0.00%** | 4.62% |
| google-vertex (Gemini, N/A) | 580 | 28.53% | 0.00% |

**Early post-cutover .2 (first ~minutes):** first-party `anthropic` 7 msgs **0.00%
uncached**, 1.09% write — no regression. `google-vertex-anthropic`: 0 samples yet.

**GATE NOT YET CLOSED — re-measure after ≥24h of .2 traffic.** Need both
anthropic-family routes to match baseline (uncached ~0%, write-rate not materially
higher). Re-run this (read-only) against `~/.local/share/opencode/opencode.db`,
`start = 2026-06-02T15:24:59Z`:

```python
import sqlite3,json,datetime
db="/home/dev/.local/share/opencode/opencode.db"
con=sqlite3.connect(f"file:{db}?mode=ro",uri=True,timeout=10); cur=con.cursor()
def ms(s): return int(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()*1000)
start=ms("2026-06-02T15:24:59Z")
agg={}
for (data,) in cur.execute("select data from message where time_created>=?",(start,)):
    try: d=json.loads(data)
    except: continue
    if d.get("role")!="assistant": continue
    t=d.get("tokens") or {}; c=t.get("cache") or {}
    inp=t.get("input",0) or 0; rd=c.get("read",0) or 0; wr=c.get("write",0) or 0
    if inp+rd+wr==0: continue
    p=d.get("providerID","?"); a=agg.setdefault(p,{"msgs":0,"input":0,"read":0,"write":0})
    a["msgs"]+=1; a["input"]+=inp; a["read"]+=rd; a["write"]+=wr
for p,a in sorted(agg.items(),key=lambda x:-x[1]["msgs"]):
    tot=a["input"]+a["read"]+a["write"]; unc=100*a["input"]/tot if tot else 0
    wrt=100*a["write"]/(a["read"]+a["write"]) if (a["read"]+a["write"]) else 0
    print(f"{p:28} msgs={a['msgs']:>4} uncached={unc:.2f}% write/(r+w)={wrt:.2f}%")
```

**Pass rule:** `google-vertex-anthropic` AND `anthropic` both ≤ ~1% uncached and
write-rate not materially above baseline (6%/4.6%). **Rollback** = revert hashes +
`patchedRevision="1"` in `home.base.nix`, switch, restart. Only after PASS → nvj.6 archive.

## nvj.5 (upstream PR) — WON'T DO (2026-06-02)

Investigated and **deliberately not submitting** an upstream PR:
- The thinking-skip is **defensive** — even the fork's `caching.patch` shipped it with
  no reproducing test. Reasoning blocks are normally **first** in assistant content,
  so a *trailing* reasoning block only arises in rare/corrupted shapes (e.g.
  interrupted-stream reconstruction, cf `tool-fix.patch`). No deterministic real repro.
- Upstream `dev` `applyCaching` **does** still `mark content[length-1]` blindly (bug
  present), and the content-options path covers `google-vertex-anthropic`/`openrouter`
  (first-party `anthropic` uses the message-level path, unaffected).
- Issue **#17883 is a different repro** (plugin-injected *system* blocks, v1.2.27);
  `Fixes #17883` would be inaccurate, and Issue-First policy needs an accurate link.
- `anomalyco/opencode` has a **vouch/denounce** system tied to the `johnnymo87`
  identity and explicitly denounces low-quality AI PRs + requires "how to reproduce".
- Our patch also uses `let`/`any`, violating their style (would need a `findLast()`
  rewrite).

**Decision (user):** keep the local `cache-thinking-skip.patch` as cheap defensive
insurance; do not open the PR. `check-sunset.yml` still tracks #17883 as a loose
sunset signal. If a real trailing-reasoning 400 is ever observed in production, revisit
with a genuine repro + upstream-style rewrite.

## Out of scope

`caching.patch` (opencode-cached) is ONLY the applyCaching/config/tool system. The
OTHER opencode-patched local patches are SEPARATE and evaluated independently:
prompt-loop-cache ([#25367](https://github.com/anomalyco/opencode/pull/25367),
byte-identity across the prompt loop — complementary, we keep), cache-aligned-compaction
([#25100](https://github.com/anomalyco/opencode/pull/25100)), tool-fix, mcp-reconnect,
eager-input-streaming, gemini-empty-parts, vim, instance-state-partition.
