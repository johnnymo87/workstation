# Context-Usage Nudge — Design

**Date:** 2026-05-15
**Status:** Approved, ready for implementation plan
**Author:** brainstormed with johnnymo87

## Problem

The opencode model has no visibility into its own context usage. When a
session passes the rough region where it starts to drift (~200k absolute
tokens, regardless of the model's nominal window), nothing prompts it to
consider compacting. The existing safety net — `overflow.ts`
auto-compaction at the hard limit — only fires when the window is full,
which is disruptive and sometimes mid-task.

We already have the compaction *machinery*:

- `self_compact_and_resume` tool (in `assets/opencode/plugins/self-compact.ts`).
- `preparing-for-compaction` skill that orchestrates the practice.
- `compaction-context.ts` hook that shapes what gets preserved during the
  summary.

What's missing is **awareness + judgment**: the model can't see how full
the context is, and the AGENTS.md doesn't describe noticing it as part of
the agent's practice.

## Goal

Expose current context usage to the model on every turn so it can apply
judgment about when to compact. Pair the mechanism with a short prose
section in `~/.config/opencode/AGENTS.md` describing the practice.

The mechanism is informational, not coercive: the model sees a number and
chooses what to do with it.

## Non-goals

- Not automatic compaction at sub-overflow thresholds (`overflow.ts`
  already handles the hard ceiling).
- Not pruning or compression of stale tool outputs (DCP's territory; YAGNI
  here).
- Not a slash command or TUI dialog (orthogonal feature; could come
  later).
- Not telemetry or per-tool breakdown (TokenScope does this on demand).

The boundary we're drawing: the *plugin* is mechanical (compute + inject
one line). The *AGENTS.md note* is the virtue-ethics gesture — it
describes the kind of agent who notices context usage and acts
thoughtfully, without prescribing rules.

## Approach considered (and rejected)

- **Adopt `@tarquinen/opencode-dcp`.** Mature plugin that injects context
  guidance into the system prompt — but it's 3000+ lines focused on
  pruning, has opinions we don't share (it modifies message history in
  ways that break prompt caching by design), and conflates "show the
  number" with "rewrite the conversation".
- **Upstream a `/context` command + system injection to anomalyco/opencode.**
  Highest leverage but slow merge cycle, and issue #10575 (the previous
  attempt) was closed stale.

We're building our own small thing because the surface is tiny and we
control the prose, which is the part that actually matters.

## Architecture

One new plugin: `assets/opencode/plugins/context-usage.ts`. Lives
alongside `compaction-context.ts`, follows the same pattern (small,
single-concern, default-exported `Plugin` factory).

**Hook:** `experimental.chat.system.transform`. Fires once per LLM call,
before the request goes out (verified at
`~/projects/opencode/packages/opencode/src/session/llm.ts:114`). The hook
receives `{ sessionID, model }` and can push strings onto `output.system`.

**Data flow per turn:**

1. Hook fires with `sessionID` and `model` (which has
   `model.limit.context`).
2. Plugin fetches the session's message list via the in-process Hono
   transport captured from `ctx.client` (same trick as
   `self-compact.ts`). HTTP path: `GET /session/{sessionID}/message`.
3. Walk messages from the end, find the most recent assistant message
   with non-zero `info.tokens`. Compute used =
   `tokens.total ?? (input + output + cache.read + cache.write)`
   (matches `acp/agent.ts:114` and `overflow.ts:24`).
4. If no such message exists (turn 1, brand new session), return without
   pushing — silent.
5. Otherwise push one short line onto `output.system`. The line goes
   *after* the first element (header) so `llm.ts:120-124`'s 2-part rejoin
   keeps the cacheable header byte-identical across turns.

**The injected line:**

```
Context usage: 187,234 / 1,000,000 tokens (18.7%) as of last turn.
```

~15 tokens. No advice in the line itself — the AGENTS.md note carries
that.

## Failure modes

| Scenario | Behavior |
|---|---|
| Turn 1, no assistant message yet | `fetchLatestAssistantUsage` returns null → no line injected |
| HTTP fetch fails (server transient error) | Returns null → no line that turn; recovers next turn |
| Model has no `limit.context` (some local providers) | Skipped at the top |
| Subagent session | Works the same — every session has its own message list |
| Title generator / summarizer internal sessions | They also get the line, which is harmless |
| `used == 0` (placeholder tokens initialized but real usage not yet recorded) | Walk past these; find a message with real numbers |

Fail closed (silently): any fetch error, any unexpected shape, return
null and skip the line. The model never sees a half-broken footer. The
only operational signal that something's wrong would be: the line stops
appearing.

## AGENTS.md prose

To be inserted in `assets/opencode/AGENTS.md` between "Bash Environment"
and "Host Identification":

```markdown
## Managing Your Own Context

You can see your current context usage in every system prompt as a line
like `Context usage: 187,234 / 1,000,000 tokens (18.7%) as of last turn.`
It's there so you have the same situational awareness about your own
working memory that a human collaborator would have about theirs.

A few things worth knowing:

- Long sessions tend to drift. Past roughly 200k tokens of absolute
  usage, even on a model with a 1M window, the conversation often
  becomes less focused: stale tool outputs crowd out current state,
  early decisions get re-litigated, and the cost-per-turn climbs. The
  exact number isn't magic — 180k is fine, 220k is fine — but the
  region is real.

- When you notice you're in that region, the question to ask is "is
  this a good moment to compact?" — not "must I compact now?" A good
  moment is a natural break: a task finished, a plan written, a
  decision made, before starting the next chunk. A bad moment is
  mid-edit, mid-debug, or partway through a tool-call chain whose
  state would be hard to reconstruct from a summary.

- If it's a good moment, the `preparing-for-compaction` skill is the
  established path: persist durable context (beads, plan files), draft
  a resumption prompt, then call `self_compact_and_resume`.

- If it isn't, keep working. The hard ceiling at the model's actual
  context limit will auto-compact if you blow through it; that's a
  safety net, not a goal. The number in the footer is for your
  judgment, not for a threshold check.

- Don't announce the number unprompted, and don't pad turns with
  "context is at X" status updates — the user can see it too. Just
  let it inform when you raise the question of compacting.
```

The prose is the actual virtue-ethics gesture. It describes the kind of
agent who notices context usage and acts thoughtfully, without
prescribing rules. Following Askell's framing: rules tend to generalize
into "I'm the kind of agent that just follows rules"; ethos generalizes
into judgment. The "180k is fine, 220k is fine — but the region is
real" line is the explicit disclaim of rule-shape.

## Code shape

Two files, mirroring the `self-compact*` precedent:

```typescript
// assets/opencode/plugins/context-usage.ts
import type { Plugin } from "@opencode-ai/plugin"
import { fetchLatestAssistantUsage } from "./context-usage-impl"

const plugin: Plugin = async (ctx) => {
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch = sdkClientConfig?.fetch ?? globalThis.fetch

  return {
    "experimental.chat.system.transform": async (input, output) => {
      const contextLimit = input.model?.limit?.context
      if (!contextLimit || contextLimit === 0) return

      const used = await fetchLatestAssistantUsage({
        fetch: internalFetch,
        serverUrl: ctx.serverUrl,
        sessionID: input.sessionID,
      })
      if (used === null) return

      const pct = ((used / contextLimit) * 100).toFixed(1)
      const line =
        `Context usage: ${used.toLocaleString()} / ${contextLimit.toLocaleString()} ` +
        `tokens (${pct}%) as of last turn.`

      output.system.push(line)
    },
  }
}

export default plugin
```

```typescript
// assets/opencode/plugins/context-usage-impl.ts
export async function fetchLatestAssistantUsage(input: {
  fetch: typeof fetch
  serverUrl: URL
  sessionID: string
}): Promise<number | null> {
  const url = new URL(
    `/session/${encodeURIComponent(input.sessionID)}/message`,
    input.serverUrl,
  )
  let res: Response
  try {
    res = await input.fetch(new Request(url.toString(), { method: "GET" }))
  } catch {
    return null
  }
  if (!res.ok) return null
  const parsed = await res.json()
  if (!Array.isArray(parsed)) return null

  for (let i = parsed.length - 1; i >= 0; i--) {
    const m = parsed[i]
    if (m?.info?.role !== "assistant") continue
    const t = m.info.tokens
    if (!t) continue
    const used =
      t.total ?? (t.input ?? 0) + (t.output ?? 0)
              + (t.cache?.read ?? 0) + (t.cache?.write ?? 0)
    if (used > 0) return used
  }
  return null
}
```

Splitting the helper into a separate file is deliberate: opencode's
plugin loader iterates `Object.entries(mod)` and invokes every exported
function as a plugin factory (per the header comment in
`self-compact.ts`). So test-only helpers must live in `-impl.ts`, not in
the entrypoint.

## File-touch summary

| File | Change | Approx lines |
|---|---|---|
| `assets/opencode/plugins/context-usage.ts` | New, plugin entrypoint | ~25 |
| `assets/opencode/plugins/context-usage-impl.ts` | New, pure helper | ~30 |
| `assets/opencode/plugins/test/context-usage.test.ts` | New, vitest cases 1–12 | ~150 |
| `assets/opencode/AGENTS.md` | Add "Managing Your Own Context" section | +~25 |
| `users/dev/opencode-config.nix` | One-line deploy of the new plugin | +1 |

## Test plan

In `assets/opencode/plugins/test/context-usage.test.ts`, run via
`vitest`. Pattern follows `self-compact.test.ts`.

**`fetchLatestAssistantUsage` unit cases:**

1. Happy path: latest assistant message has `tokens.total: 187_234` →
   returns `187234`.
2. `total` absent → falls back to sum of input/output/cache.
3. Walks past zero-token placeholder messages; finds the most recent
   real one.
4. No assistant message yet (turn 1, empty or user-only list) → returns
   `null`.
5. HTTP non-OK response → returns `null`, no throw.
6. Fetch throws → returns `null`, no throw.
7. Body is not an array → returns `null`.
8. Encodes sessionID with `encodeURIComponent` (regression guard).

**Plugin entrypoint integration cases:**

9. Hook injects exactly one line matching
   `/^Context usage: [\d,]+ \/ [\d,]+ tokens \([\d.]+%\) as of last turn\.$/`
   when usage is available.
10. Hook silent when `model.limit.context` is 0 or missing.
11. Hook silent when no prior assistant message.
12. Hook silent on fetch error (no propagation).

**Explicitly not tested:**

- Exact wording — too brittle; the regex in case 9 is enough.
- Cache-key behavior of opencode's prompt builder — that's `llm.ts`'s
  contract.
- End-to-end against a real opencode server — `self-compact` precedent
  is unit-only and has been adequate.

**Manual verification before merge:**

- `bun test` (or `vitest`) passes in `assets/opencode/plugins/`.
- Rebuild home-manager.
- Start a fresh opencode session: confirm no footer on turn 1, footer
  appears after the first assistant response, and the numbers look right.

## Open questions

None. All design decisions resolved during brainstorm:

- Q1: failure mode — all three (overflow, drift, cost) → general-purpose
  awareness channel.
- Q2: where surfaced — system-prompt footer every turn.
- Q3: nudge shape — plain status, no advice in the footer itself.
- Q4: guidance location — short prose section in user AGENTS.md.
- Q5: plugin layout — new single-purpose file.
- Q6: build direction — minimal in-tree plugin (not DCP, not upstream).
- Q7: denominator — `model.limit.context` raw.
- Q8: first-turn behavior — silent on turn 1; all sessions including
  subagents.

## Next step

Hand off to `writing-plans` skill to generate the step-by-step
implementation plan with TDD-shaped tasks.
