# How should we redesign Anthropic prompt-cache breakpoint placement in opencode to reduce per-turn cache-write cost?

## Keywords

Anthropic prompt caching, ephemeral cache_control, cache breakpoints, Vercel AI SDK, opencode, agentic CLI, per-turn cache invalidation, 5-minute cache TTL, prompt-prefix stability

## The situation

We run an agentic coding CLI called **opencode** (TypeScript / Bun, Vercel AI SDK based, talks to Anthropic's API directly using Opus 4.6 / 4.7). We've been measuring our cost over the last 30 days using a small Python tool we built (`oc-cost`) that reads opencode's local SQLite session DB and applies Anthropic's published per-MTok rates.

The numbers concern us:

```
Total 30-day cost:        $2,026
  Cache reads (input):       $848  (41.9%)
  Cache writes (creation):   $867  (42.8%)
  Uncached input:            $104  (5.1%)
  Output:                    $206  (10.2%)
```

For Anthropic ephemeral 5-minute caching, the rate ratios are: `cache_write = 1.25 × input`, `cache_read = 0.10 × input`. So cache writes cost **12.5×** what cache reads cost per token. Healthy intuition says cache writes should be a small minority of cost; ours are nearly half. The token volume actually shows ~92% cache-hit rate by tokens (1,808M reads vs 138M writes), but the 12.5× premium on writes inverts the dollar split.

We instrumented further. Splitting writes by inter-message gap **within the same session**:

| Inter-message gap | Events | Cache-write tokens | Avg/event | Likely cause |
|---|---:|---:|---:|---|
| < 1 min (steady-state turns) | 19,721 | 46.1M | 2,337 | tail-shift (every turn refreshes) |
| 5m–1h (TTL expired) | 505 | 54.2M | 107,233 | 5-minute cache TTL expired during pause |
| ≥ 1h (long pause) | 161 | 22.1M | 137,060 | full prefix re-write |
| First msg in a session | 844 | 8.9M | 10,521 | prefix never warm |
| 1m–5m (within TTL) | 976 | 8.5M | 8,720 | mostly tail-shift |

So **two buckets dominate**:

1. **TTL expiry during natural pauses** (~$338 over 30 days @ $6.25/MTok Opus rate).
2. **Steady-state tail-shift** (~$288 over 30 days). This comes from how opencode places cache_control markers.

Splitting by session role (the user-facing "primary" session vs spawned subagent sessions) shows primary sessions account for **77% of cost** while being only 14% of sessions. Long primary sessions of hours-to-days are where most cost lives.

## Environment

- opencode 1.14.19 (`opencode-patched` fork: upstream `sst/opencode@v1.14.19` + a community caching patch derived from upstream PR #5422 + a vim keybindings patch). Branch `dev` of `sst/opencode`.
- Node/Bun runtime; Vercel AI SDK with `@ai-sdk/anthropic`.
- Anthropic direct API (not Vertex/Bedrock), Opus 4.6 and 4.7.
- The patch carrier repo is `johnnymo87/opencode-cached`; the binary distribution is `johnnymo87/opencode-patched` (cached + vim).

## Code: how cache placement currently works

### Upstream (`sst/opencode`) — `packages/opencode/src/provider/transform.ts:216-265`

```typescript
function applyCaching(msgs: ModelMessage[], model: Provider.Model): ModelMessage[] {
  const system = msgs.filter((msg) => msg.role === "system").slice(0, 2)
  const final = msgs.filter((msg) => msg.role !== "system").slice(-2)

  const providerOptions = {
    anthropic: { cacheControl: { type: "ephemeral" } },
    bedrock:   { cachePoint:   { type: "default" } },
    // ... others
  }

  for (const msg of unique([...system, ...final])) {
    const useMessageLevelOptions =
      model.providerID === "anthropic" || model.providerID.includes("bedrock")
    const shouldUseContentOptions =
      !useMessageLevelOptions && Array.isArray(msg.content) && msg.content.length > 0

    if (shouldUseContentOptions) {
      const lastContent = msg.content[msg.content.length - 1]
      if (lastContent && /* ... */) {
        lastContent.providerOptions = mergeDeep(lastContent.providerOptions ?? {}, providerOptions)
        continue
      }
    }
    msg.providerOptions = mergeDeep(msg.providerOptions ?? {}, providerOptions)
  }
  return msgs
}
```

So upstream places **up to 4 cache_control markers**: 2 on the first 2 system messages, 2 on the last 2 non-system messages (the conversation tail).

### How `system` messages are constructed (`packages/opencode/src/session/llm.ts:99-124`)

```typescript
const system: string[] = []
system.push(
  [
    ...(input.agent.prompt ? [input.agent.prompt] : SystemPrompt.provider(input.model)),
    ...input.system,
    ...(input.user.system ? [input.user.system] : []),
  ].filter(x => x).join("\n"),
)
const header = system[0]
yield* plugin.trigger("experimental.chat.system.transform", ..., { system })
// rejoin to maintain 2-part structure for caching if header unchanged
if (system.length > 2 && system[0] === header) {
  const rest = system.slice(1)
  system.length = 0
  system.push(header, rest.join("\n"))
}
```

Then `system` is mapped to `[{role: "system", content: <static_provider_prompt>}, {role: "system", content: <env+skills+instructions>}]`. The first system message is a static Anthropic-flavored prompt loaded from a `.txt` file. The second contains an `<env>` block that, until we re-checked, embeds `Today's date: ${new Date().toDateString()}` per request — but our DB analysis showed this date-string change is essentially never observed (only 1 within-5min midnight-crossing in 30 days; sessions almost always pause through midnight so TTL would expire the cache anyway).

### The patched code (`opencode-cached/patches/caching.patch`)

The patch is 2294 lines and adds a `ProviderConfig` namespace with per-provider cache config (`maxBreakpoints`, `cacheBreakpoints`, `sortTools`, `toolCaching`, `hierarchy`). It mostly adds **configurability** rather than changing behavior. Key behavioral changes:

1. Caps the number of breakpoints applied via a counter: `if (breakpointsApplied >= maxBreakpoints) break` (anthropic config sets `maxBreakpoints: 4`).
2. **Adds an extra cache breakpoint on the last tool definition** in `prompt.ts` (in a different code path that does not consult the same counter). For anthropic, `toolCaching: true`. So the patched code can attempt to send up to **5** cache_control markers (1 tool + 2 system + 2 tail).
3. Sorts tool entries alphabetically when `sortTools: true` (mitigates an upstream bug where MCP tool ordering depended on async connection-completion race).

The patch keeps the same `slice(0, 2)` / `slice(-2)` selection policy on system and tail messages.

## What we know vs. what we suspect

### Known (verified empirically against our DB)

- Dollar split is roughly even between cache-read and cache-write components (~43% each).
- 19,721 of our assistant turns happen within < 1 minute of the previous turn but still emit a write (~2,337 tokens average). This is consistent with a single moving-tail breakpoint being re-written each turn.
- 505 turns have a 5-minute-to-1-hour gap and emit writes averaging 107k tokens. These are full-prefix re-creations after the 5-minute ephemeral TTL expired.
- Long primary sessions (avg 23 hours, 102 msgs each) drive 77% of dollar cost; short subagent sessions (avg 3.4 min, 14 msgs each) only 23%.
- 92% of input-token VOLUME is served from cache; cache writes are only ~7% of input volume but ~50% of cost.

### Suspected (not verified)

- Anthropic's 5-minute ephemeral cache TTL is short for our usage pattern. Anthropic documents an optional **1-hour cache** at higher creation cost (~2× input rate) and same cache-read cost (10% of input). We **think** the math works out favorably for us if many of those 505 TTL-expired events would have hit a 1-hour cache, but we haven't modeled the break-even point precisely.
- The "last 2 non-system messages" placement is suboptimal. We're not sure what optimal looks like — every message? every Nth? anchor on stable boundaries (compaction events, plan->build mode switches)?
- Whether the AI SDK silently drops the 5th `cache_control` marker or 400s — we don't know, and it might matter for the patched code that emits 5.
- Whether `mergeDeep` of providerOptions on already-cached messages causes hash drift (if the marker shape changes object key order, would that matter to Anthropic's hashing?).

## Specific questions

We're considering several mitigation strategies and want a researched, opinionated take:

### Q1 (the big one): Breakpoint placement strategy for the conversation tail

**Current behavior:** Anthropic's `cache_control: ephemeral` is placed on the LAST 2 non-system messages each turn. So every new assistant turn moves both tail breakpoints to fresh content (which has never been cache-written before), forcing a write. The OLD tail breakpoint just expires unused.

**Designs we're considering:**

- **A. Anchor-on-Nth.** Place the tail breakpoint every Nth message (e.g., every 10), so a single breakpoint serves N turns. Trade-off: misses caching during the N-message window between breakpoints; reads grow uncached.
- **B. Anchor-on-stable-boundary.** Place breakpoints on compaction events (which are well-defined boundaries), or on user-message boundaries (stable per-turn). Skip placement when the tail is dominated by mutating `<system-reminder>` wrappers.
- **C. Tail-only-when-cold.** Detect "are we in a tight burst of turns?" and skip the per-turn tail write; let tools+system breakpoints carry the cache. Heuristic: skip tail breakpoint if previous turn was < 30 seconds ago and the previous tail breakpoint isn't expired (~ < 4 min).
- **D. Use 1-hour cache_control TTL.** Anthropic has `ephemeral` with a `ttl: "1h"` variant. Costs ~2× input on creation but reads still 10%, so TTL expirations after 5+ minutes (which we see 505 of in 30 days) become "free" within an hour. We'd want analysis of when 1h vs 5m wins on aggregate.
- **E. Hybrid.** Use 1h TTL on the prefix (tools + system; long-lived) and 5m on the tail (or skip the tail write entirely).

Which design is most defensible given:
- Anthropic's documented behavior (we want sources for any claims).
- The ≤4 cache_control breakpoints per request limit.
- The Vercel AI SDK's serialization (does it pass through any `ttl` option, or strip it?).
- Our usage profile (~80% of cost in long primary sessions, ~20% in short subagents).

Please cite specific Anthropic docs (the prompt-caching page, the messages API reference) and AI SDK source code where relevant. We've found <https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching> but want pointers to the most authoritative writeups, including any community evidence (anyone's blog/PR/issue showing measured before/after for a similar mitigation).

### Q2: Is the patched code's 5th cache_control marker safe?

The opencode-cached patch sends:
- 1 marker on the last tool definition (added by patch in `prompt.ts`)
- 2 on first 2 system messages (from upstream `applyCaching`)
- 2 on last 2 non-system messages (from upstream `applyCaching`)

That's 5 total when Anthropic enforces ≤4. What does Anthropic's API actually do with the 5th? Silent drop? 400 error? We can't see this from logs because errors aren't captured. If silently dropped, *which* one is dropped (last applied wins? first wins?), and does that matter for our cost?

The Vercel AI SDK source for anthropic provider is at <https://github.com/vercel/ai/tree/main/packages/anthropic>. Please look at how `providerOptions.anthropic.cacheControl` is serialized and whether the SDK enforces any limit before the API does.

### Q3: 1-hour cache_control — does the AI SDK pass it through?

Anthropic documents `cache_control: { type: "ephemeral", ttl: "1h" }`. Does `@ai-sdk/anthropic` accept and forward the `ttl` field? If we pass `cacheControl: { type: "ephemeral", ttl: "1h" }` in `providerOptions.anthropic`, will it survive the SDK round-trip to the API request?

If yes, this would be a **~3-line patch** to the existing opencode code path: change the marker shape. Worth doing as a quick win.

### Q4: Anything else we're missing?

Are there other low-hanging optimizations specific to Anthropic prompt caching that experienced agentic-CLI builders ship? E.g.:
- Specific patterns to *avoid mutating* messages after they've been cached?
- Ways to detect cache hits/misses from the API response so opencode could log them and we could iterate?
- Any open issues/PRs in `sst/opencode` upstream that propose better caching policies (we know about Issue #5224 system prompt cache invalidation and PR #5422 provider-specific cache config — both unmerged at time of writing)?

## Constraints

- We can patch `johnnymo87/opencode-cached` (a fork) freely. We can attempt to upstream changes to `sst/opencode` later but the immediate goal is local mitigation.
- Must not break opencode for non-Anthropic providers (Bedrock, OpenAI-compatible, Copilot all use the same `applyCaching` code path).
- Must not change the user-visible CLI behavior of opencode (just the API request payload).
- Bun-compatible TypeScript, no new npm dependencies.

## What we want back from this research

1. A specific, opinionated recommendation for Q1 (which design, why, and roughly what the patch would look like in pseudocode or actual TypeScript). State your confidence level.
2. Verified answers to Q2 and Q3 with citations to Anthropic docs and the Vercel AI SDK source.
3. Any "you're missing X" insight for Q4.
4. If our analysis has a flaw (we're misreading the data, the math is wrong, our hypotheses are off), tell us. We'd rather hear that early than build the wrong thing.
