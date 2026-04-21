# Cache-Write Mitigation: Design (B+E)

> **Status:** Design draft, awaiting user review before implementation.
> **Date:** 2026-04-21
> **Predecessors:**
> - `docs/plans/2026-04-21-cache-write-investigation.md` — empirical findings
> - `docs/plans/2026-04-21-cache-write-consult-question.md` — what we asked ChatGPT
> - `docs/plans/2026-04-21-cache-write-consult-answer.md` — what ChatGPT recommended
> **Target repo:** `~/projects/opencode-cached` (a fork of `sst/opencode` PR #5422 by @ormandj)
> **Distribution:** Changes flow into `~/projects/opencode-patched` automatically (it pulls `caching.patch` from `opencode-cached@main` at build time).

## Goal

Cut OpenCode's cache-write spend on Anthropic Claude Opus by:
1. Eliminating the per-turn ~2,337-token "tail-shift" write (~$288/30d on cloudbox)
2. Reducing the cost of TTL-driven re-writes during natural 5m–1h pauses (~$338/30d)
3. Removing risk of sending 5 `cache_control` markers (Anthropic API hard-caps at 4)

ChatGPT (with Anthropic docs + Vercel AI SDK source citations) recommends design **B + E**: anchor the conversation breakpoint on the last *stable boundary* (not the live tail), and use 1-hour TTL only on the long-lived prefix (system + tools).

## Non-goals

- Bedrock, OpenRouter, OpenAI-compatible providers — out of scope. We only use Anthropic via `@ai-sdk/anthropic` from the cloudbox. Other provider configs in `ProviderConfig.defaults` stay untouched.
- Upstreaming to `sst/opencode` — user decision: fix locally first, evaluate impact, then decide.
- Per-request instrumentation (Q4 item 3 from ChatGPT) — separate follow-up. Useful but not required to ship the policy change.
- Stabilizing dynamic prompt content (Q4 item 1) — separate, larger investigation.
- Thinking-mode churn (Q4 item 2) — out of scope; we don't currently use extended thinking.

## What changes

### Three changes to `~/projects/opencode-cached/patches/caching.patch`:

#### Change 1: Make `buildCacheControl` actually emit `ttl: "1h"`

**File:** `packages/opencode/src/provider/config.ts` (in patch around line 1031)

**Current (broken):**
```typescript
case "explicit-breakpoint":
  if (ttl === "1h") {
    // Extended cache (if supported)
    return { type: "ephemeral" } // Currently only ephemeral is widely supported
  }
  return { type: "ephemeral" }
```

**Replace with:**
```typescript
case "explicit-breakpoint":
  return ttl === "1h"
    ? { type: "ephemeral", ttl: "1h" }
    : { type: "ephemeral" }
```

**Justification:** Vercel AI SDK 3.0.x `@ai-sdk/anthropic` accepts `ttl: "1h"` on the cache_control marker (verified by ChatGPT against `anthropic-messages-options.ts` — `ttl: z.union([z.literal('5m'), z.literal('1h')]).optional()`). The existing comment "Currently only ephemeral is widely supported" is stale; Anthropic ships the 1h tier for all `claude-*-4-*` models.

The 5m vs 1h trade-off (per Anthropic pricing):
- 5m write: 1.25× input rate, plus another 1.25× write each time the 5m TTL expires before reuse
- 1h write: 2.0× input rate, plus 0.1× read for any reuse within the hour
- Break-even: a single avoided 5m-expiry rewrite makes 1h cheaper

Cloudbox primary sessions average **23 hours** in duration — they will see *many* 5m–1h gaps per session.

#### Change 2: Replace tail-shift selection with stable-boundary anchor

**File:** `packages/opencode/src/provider/transform.ts` (in patch around line 1187)

**Current:**
```typescript
const system = msgs.filter((msg) => msg.role === "system").slice(0, 2)
const final = msgs.filter((msg) => msg.role !== "system").slice(-2)
// ...
for (const msg of unique([...system, ...final])) { ... }
```

This adds breakpoints to the *last 2 non-system messages*. Both shift forward every turn, forcing fresh writes on stable prefix content (~$288/30d wasted).

**Replace with:**
```typescript
const system = msgs.filter((msg) => msg.role === "system").slice(0, 2)

// Anchor the conversation breakpoint on the LAST USER MESSAGE only.
// This is the most recent stable boundary in any agent loop:
// - User messages do not change after they are sent
// - Assistant messages and tool-result messages mutate from one
//   request to the next within a single user turn (each tool call
//   appends a new tool-result), so anchoring on them defeats caching
const lastUserIndex = (() => {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role === "user") return i
  }
  return -1
})()
const anchor = lastUserIndex >= 0 ? [msgs[lastUserIndex]] : []

for (const msg of unique([...system, ...anchor])) { ... }
```

**Justification:** ChatGPT (citing Anthropic's caching docs): "The breakpoint should be on the last block whose prefix is identical across the requests you want to share a cache." During an agent's tool-loop, the user message is fixed; assistant/tool-result blocks accumulate. Anchoring on the last user message means the conversation breakpoint stays put for the whole loop, every subsequent request reads from cache up to that point, and only the new tail tokens are billed at full input rate (1.0×) instead of write rate (1.25×).

#### Change 3: Set anthropic TTL default to `1h`

**File:** `packages/opencode/src/provider/config.ts` in `defaults.anthropic.cache.ttl` (patch line 315)

**Current:**
```typescript
ttl: "5m", // Anthropic cache TTL is 5 minutes (not configurable via API)
```

**Replace with:**
```typescript
ttl: "1h", // Anthropic supports 5m or 1h ephemeral cache; long agent sessions benefit from 1h
```

Also update the comment on `defaults["google-vertex-anthropic"].cache.ttl` and any other Anthropic-style entry that hardcoded 5m with the same justification (`bedrock` stays 5m for now since we don't use it and Bedrock semantics may differ).

**Why we don't use `5m` for the conversation anchor:** The conversation anchor moves forward at every user turn, so it's already short-lived. There's no benefit to paying the 2.0× write multiplier on something that will be invalidated by the next user turn anyway. Per ChatGPT: "longer-TTL breakpoints must appear before shorter-TTL ones." Our patch puts system markers BEFORE the conversation marker (system is first in the message array), so this ordering rule is naturally satisfied.

But the message-anchor breakpoint will inherit the same `ttl` setting from config since `applyCaching` calls `buildCacheProviderOptions(model)` once and reuses it for all breakpoints. We need a small refactor:

```typescript
function applyCaching(msgs: ModelMessage[], model: Provider.Model): ModelMessage[] {
  // ... existing setup ...

  const longTtlOptions = buildCacheProviderOptions(model)  // 1h
  const shortTtlOptions = buildCacheProviderOptions(model, "5m")  // 5m for live anchor

  // Apply longTtlOptions to system breakpoints
  // Apply shortTtlOptions to the user-message anchor
}
```

This requires `buildCacheProviderOptions` to accept an optional `ttl` parameter. The change is mechanical — pass it down to `ProviderConfig.buildCacheControl(model.providerID, ttl)`.

### Total budget vs Anthropic's 4-marker API limit

After the change:
| Position | TTL | Source |
|---|---|---|
| 1. Tools (last tool definition) | 1h | `prompt.ts` (already exists in patch, lines 1296-1300) |
| 2. system[0] | 1h | `applyCaching` |
| 3. system[1] | 1h | `applyCaching` (only if 2 system messages exist) |
| 4. last user message | 5m | `applyCaching` |

That's at most **4 markers** — exactly Anthropic's API cap. No risk of hitting the "Found 5" 400 error that ChatGPT cited for older AI SDK builds.

The previous patched code could send **up to 5** (1 tools + 2 system + 2 tail) when `applyCaching`'s `maxBreakpoints=4` cap was reached AFTER `prompt.ts` already added the tools marker. Pinned `@ai-sdk/anthropic@3.0.71` *probably* drops the 5th silently (per ChatGPT's read of mainline source), but we shouldn't rely on it.

## Implementation plan (TDD)

Following workstation's standard TDD discipline:

1. **Read the existing test file `packages/opencode/test/provider/transform.test.ts`** in opencode-cached to see what helpers exist for constructing ModelMessage arrays.

2. **Write failing tests first** in `transform.test.ts`:
   - `applyCaching anchors on last user message, not the last 2 non-system messages` — given `[system, system, user, assistant, tool, assistant]`, expect cache_control on the user message and on system[0..1], NOT on the trailing assistants.
   - `applyCaching uses 1h TTL on system breakpoints when configured` — verify `cacheControl.ttl === "1h"`.
   - `applyCaching uses 5m TTL on conversation anchor` — verify the user-message marker is `{ type: "ephemeral" }` (no ttl field) since 5m is the default.
   - `applyCaching never produces more than 4 markers in total combined with tool breakpoint` — given a known input, count `cacheControl` occurrences across system + messages + tools and assert ≤ 4.

   Plus tests for `buildCacheControl`:
   - `buildCacheControl returns { type: "ephemeral", ttl: "1h" } when ttl is "1h"`
   - `buildCacheControl returns { type: "ephemeral" } when ttl is "5m"`

3. **Make tests pass** by editing the patch's three sections above.

4. **Regenerate the patch:**
   ```bash
   cd ~/projects/opencode-cached
   ./regenerate-patch.sh   # or whatever the existing flow is
   bun test packages/opencode/test/provider/  # all green
   ```

5. **Commit + push** in `opencode-cached`. The `opencode-patched` build pipeline picks up `main` automatically on its next release.

6. **Bump `opencode-patched` version, build, release.** This needs a release tag in `johnnymo87/opencode-patched`. Then GitHub Actions in `workstation` will see the new release and open a PR to update home.base.nix.

7. **After deploy:** Watch `oc-cost --days 7` over a week. Look for cache_write tokens dropping in the < 1min and 5m–1h gap buckets.

## Verification gates

Before claiming done:

```bash
# in opencode-cached
cd ~/projects/opencode-cached
bun test packages/opencode/test/provider/   # must be all green
git diff --stat main                          # patch should be smaller diff than full rewrite
./apply.sh ~/projects/opencode               # must apply cleanly to upstream

# in opencode-patched (after release)
cd ~/projects/opencode-patched
./apply.sh ~/projects/opencode               # both patches apply cleanly
```

After deploy on cloudbox:
```bash
oc-cost --days 7 --by-kind   # cache_write tokens for primary sessions should drop noticeably
```

A meaningful win would be primary session cache-write spend dropping by **at least $50/week** on cloudbox's typical workload, and the < 1min "tail-shift" bucket effectively disappearing (since tail-shift writes by design no longer happen).

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `@ai-sdk/anthropic@3.0.71` doesn't accept `ttl: "1h"` (ChatGPT verified mainline; pinned version is older) | Low-medium | Quick test: send a single request with the new marker shape and inspect the SDK's emitted JSON via debug logging or a test against the SDK's `convertToAnthropicMessagesPrompt`. If broken, fall back to no `ttl` field everywhere (Change 1 reverts; Changes 2+3 still help). |
| Anchoring on last user message during tool loops misses caching opportunities for very long single-turn tool sequences | Medium | Acceptable: even with the anchor frozen on the user message, the tools+system markers (still 1h-cached) cover the bulk of token volume. The mutating tail just isn't cached, which is also true today. |
| User has Anthropic's 1h cache disabled on their account or plan | Very low | Anthropic enables 1h ephemeral by default for all paid Claude API accounts. If denied, Anthropic returns a 400 with a clear error message — easy to spot in opencode logs. |
| Patch conflicts with upstream changes when next regenerating against newer `sst/opencode` | Medium | Standard cost of carrying a fork patch. The existing patch already absorbs PR #5422; adding ~30 lines on top doesn't materially increase merge burden. |
| Subagent (short, ~3.4 min) sessions don't benefit much from 1h TTL | Already known | They were 23% of cost anyway. The real target is primary sessions (77% of cost) which average 23 hours. |

## Open questions to resolve during implementation

1. Does `regenerate-patch.sh` (or equivalent) exist in `opencode-cached`, or is the patch maintained by hand? If hand-maintained, edit it directly rather than regenerating.

2. What does `unique()` (used in the `for` loop) do with respect to message identity? If `system[0]` happens to deep-equal `lastUserMessage`, we'd silently dedupe. Probably impossible (different `role` field) but worth verifying.

3. Should the conversation anchor use **last user message** or **last user message that contains text content** (filtering out tool-only user messages)? The patch doesn't currently distinguish, but agent-loop user messages can be either text or tool-results-as-user. Inspect a real session's message array.

4. What's the test fixture pattern for `applyCaching`? Does the existing test file `test/provider/transform.test.ts` (referenced at patch line 2248) already construct full `ModelMessage[]` arrays?

## Estimated savings (revised after ChatGPT correction)

ChatGPT corrected my naive cost-model:
- The $288 tail-shift bucket: actual savings is the **write-vs-input premium only** (1.25× → 1.0× on Opus = $1.25/MTok of avoided write). Since the bucket is 46.1M tokens, savings ≈ **46.1M × $1.25/MTok = ~$58/30d**.
- The $338 TTL-expiry bucket: depends on how often the same prefix is re-used within the 5m–1h window. With 1h TTL (2.0× write + 0.1× read), if avg reuse-count = 1, savings is the same as before because we're paying 2.0× once instead of 1.25× × 2 = 2.5×. If reuse-count > 1, savings grow rapidly.
- Best-case estimate: **~$100–$200/30d** on cloudbox. Modest but real, and the change is small.

The bigger long-term value is correctness: stop wasting an Anthropic breakpoint slot on a moving tail, and bring the patch in line with what Anthropic's own docs recommend.

## Open follow-ups (out of scope for this design)

- **Q4.1** — investigate dynamic content inside cached regions for further hit-rate improvement
- **Q4.3** — instrument per-request `cache_creation_input_tokens` / `cache_read_input_tokens` to validate this change empirically (vs. inferring from SQLite DB after the fact)
- **PR #5422 watch** — once merged upstream, retire the `caching.patch` carrier altogether and rebuild only with the smaller TTL/anchor delta

## Decision points for user (need before implementation)

1. **Approve the design as drafted** — or push back on any of the three changes.
2. **OK to ship behind the existing `opencode-cached` `main` workflow** (no feature flag, ships to everyone using the patch)? Alternative: add a `cache.policy: "stable-anchor" | "tail-shift"` config field for opt-in. My recommendation is no flag — the new policy is strictly better.
3. **OK with no upstream PR yet**? User already said no in this session, just confirming the design stage doesn't change that.
