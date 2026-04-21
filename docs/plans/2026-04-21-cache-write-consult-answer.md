My recommendation is B + E:

Use explicit breakpoints only on stable boundaries, and use 1-hour TTL only for the long-lived prefix. Do not keep a moving tail breakpoint on the last 2 non-system messages. Anthropic’s docs are pretty direct here: writes happen only at the breakpoint you mark, reads only find previous writes, and putting cache_control on a block that changes every request causes repeated fresh writes; automatic caching falls into the same trap because it also moves to the last cacheable block. Anthropic also caps lookback to 20 blocks and says multiple breakpoints are for sections that change at different frequencies. 
Claude API Docs
+1

Q1

The most defensible design for opencode is:

Keep a breakpoint on the last tool definition with ttl: "1h".

Keep a breakpoint on the static system prompt with ttl: "1h".

Optionally keep a breakpoint on the second system message only if you make it session-stable; otherwise leave it 5m or drop it.

Replace “last 2 non-system messages” with one conversation breakpoint on the last stable boundary, not the live tail. In practice, that means:

during an in-progress tool loop, anchor on the current user message;

after compaction, anchor on the compaction summary / stable compacted block;

do not anchor on the mutating assistant/tool-result suffix each request. Anthropic’s own guidance says the breakpoint should be on “the last block whose prefix is identical across the requests you want to share a cache.” 
docs.anthropic.com

Why I prefer this over your candidates:

A (every Nth message) is the wrong unit. Anthropic’s miss window is 20 content blocks, not 20 turns or 20 messages, and tool-heavy agent loops can blow past 20 blocks quickly. A fixed “every 10 messages” heuristic will be brittle. 
docs.anthropic.com

C (tail only when cold) still reasons from time instead of prefix stability. Anthropic’s cache semantics are about stable prefixes and prior writes, not burst detection. 
docs.anthropic.com

D (1-hour everywhere) helps pause-induced misses, but it does not fix the moving-tail problem. A changing suffix still writes every request. Anthropic even recommends 1-hour for prompts reused after >5 minutes, including long-running agentic workflows, which fits your stable prefix much better than your live tail. 
Claude API Docs
+1

E (hybrid) is right, but only if the “tail” side becomes a stable-boundary message anchor, not the current last-two-message policy. Anthropic requires longer-TTL breakpoints to appear before shorter-TTL ones, so 1h on tools/system and 5m on the conversation anchor is the clean mix. 
Claude API Docs

A minimal Anthropic-only patch would look like this:

TypeScript
function anthropicCache(type: '5m' | '1h' = '5m') {
  return { anthropic: { cacheControl: { type: 'ephemeral', ...(type === '1h' ? { ttl: '1h' } : {}) } } }
}

function applyAnthropicCaching(msgs: ModelMessage[], tools: ToolDefinition[]) {
  // 1) tools: mark only the LAST tool definition
  markLastTool(tools, anthropicCache('1h'))

  // 2) system[0]: static provider/agent prompt
  if (system[0]) mark(system[0], anthropicCache('1h'))

  // 3) system[1]: only if stable enough; otherwise leave 5m or skip
  if (system[1] && isSessionStable(system[1])) {
    mark(system[1], anthropicCache('1h'))
  }

  // 4) message anchor: latest stable boundary, not moving tail
  const anchor =
    lastCompactionBlock(msgs) ??
    lastUserMessage(msgs)      // strong first heuristic
  if (anchor) mark(anchor, anthropicCache('5m'))
}

For a first rollout, I would ship the simplest version:

1h on tool-definition breakpoint and static system breakpoint.

5m on last user message only.

Delete the “last 2 non-system” logic for Anthropic.

That is the smallest change with the best odds of cutting both categories you care about. Confidence: moderate-to-high.

Two corrections to your cost model:

Your tail-shift bucket is real, but the whole $288 is not automatically “recoverable.” If those tokens stop being cache writes, many of them become ordinary input, not free. Using Anthropic’s published pricing, the immediate premium you’re shedding is the difference between 5m write (1.25×) and plain input (1.0×), not the entire write charge. Likewise, 1-hour isn’t free: one delayed reuse after 5 minutes makes 1h cheaper than two 5m writes, but only because you pay 2.0× once + 0.1× read instead of 1.25× twice. On Opus, that is a net win of about $2/MTok for a single avoided 5m-expiry rewrite, not the full write→read spread. Your $338 intuition for the 5m–1h bucket is therefore an overestimate unless the same stable prefix is reused multiple times in that 5m–1h window. 
docs.anthropic.com

Q2

For the current Vercel AI SDK source, the 5th marker is not sent. The Anthropic provider has a shared CacheControlValidator with MAX_CACHE_BREAKPOINTS = 4; once the counter exceeds 4, it returns undefined and records a warning instead of serializing the extra breakpoint. The validator is shared across prompt conversion and tools, and the model code builds messages first and tools later, so with your “2 system + 2 tail + 1 tool” shape, the tool breakpoint is the most likely one to get dropped in the current mainline SDK. 
GitHub
+3
GitHub
+3
GitHub
+3

That said, Anthropic’s own docs still say you can define up to 4 breakpoints, and Anthropic documents analogous over-slot cases as 400 errors. There is also a community repro against Anthropic’s TypeScript agent SDK showing the API error text: “A maximum of 4 blocks with cache_control may be provided. Found 5.” So if your installed @ai-sdk/anthropic is older than the validator logic, the safe assumption is 400, not silent drop. 
Claude Platform
+2
Claude API Docs
+2

So the answer is:

Current AI SDK main: mostly safe, because the SDK drops the 5th.

API itself / older provider builds: not safe; expect a 400.

Q3

Yes. In the current Vercel AI SDK, ttl: "1h" is accepted and forwarded.

There are three separate pieces of evidence:

Anthropic’s docs show block-level cache_control: { type: "ephemeral", ttl: "1h" } and say the default is 5 minutes, with 1 hour available at higher write cost. 
Claude API Docs
+1

Vercel’s Anthropic provider docs explicitly show providerOptions.anthropic.cacheControl: { type: 'ephemeral', ttl: '1h' } on a message part. 
AI SDK

The Anthropic provider schema in anthropic-messages-options.ts includes ttl: z.union([z.literal('5m'), z.literal('1h')]).optional(), and anthropic-messages-language-model.ts forwards anthropicOptions.cacheControl directly to request cache_control. 
GitHub
+1

So for your existing block-level path, changing the marker shape to include ttl: "1h" should survive the SDK round-trip. The same source also shows top-level request cache_control forwarding in current main, although there was a recent issue report saying this had been stripped in some path/version. 
GitHub
+1

Q4

A few things you’re still missing:

1. Stabilize anything dynamic inside cached regions.
Anthropic requires exact matching of cached prompt segments, and its docs specifically warn that randomized key ordering in tool-use content can break caches. In opencode land, there are already reports about dynamic user.system merging and dynamic tool descriptions breaking Anthropic caching. Your sortTools patch helps tool-array order, but it does not solve every dynamic prompt segment. 
Claude API Docs
+2
GitHub
+2

2. Be careful with thinking-mode churn.
Anthropic says changing thinking modes invalidates message-history caching, though system prompts and tool definitions remain cached. It also says tool-use requests must pass back thinking blocks unmodified, and for long thinking workflows Anthropic explicitly suggests considering the 1-hour cache. Community bug reports from similar agentic CLIs show dropping prior thinking blocks can zero out cache reads on later turns. 
Claude Platform
+2
Claude Platform
+2

3. Log cache metadata every request.
Anthropic exposes usage.cache_creation_input_tokens and usage.cache_read_input_tokens; Vercel’s Anthropic docs show these surfacing in providerMetadata?.anthropic, and the provider source maps them into the AI SDK usage object. That is the fastest way to validate any new placement policy instead of inferring from the SQLite DB after the fact. 
Claude API Docs
+2
AI SDK
+2

4. Upstream evidence already points the same way.
The opencode community has already reported that static/dynamic system separation and tool stability materially improve hit rate, and one opencode issue reports cross-repo first-prompt hit rate moving from 0% to 97.6% after prefix-stability fixes. Another issue specifically asks for TTL configurability because 5-minute expiry causes expensive rewrites in real workflows. 
GitHub
+3
GitHub
+3
GitHub
+3

So the short version is:

Do not move the cache breakpoint with the live Anthropic tail.

Do anchor the conversation cache at the last stable boundary.

Do put 1h only on the long-lived prefix.

Do hard-cap Anthropic to 4 total slots in your own transform logic instead of relying on downstream behavior.

Do instrument request-level cache reads/writes so you can see whether the new anchor actually reduced writes or just shifted them.

If you want, I can turn this into a concrete TypeScript patch against the applyCaching logic you pasted.