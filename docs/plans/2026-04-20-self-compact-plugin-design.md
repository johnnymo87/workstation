# Self-Compact Plugin Design

**Status:** Approved, ready for implementation plan
**Date:** 2026-04-20
**Author:** OpenCode (with johnnymo87)

## Problem

When the user wants the agent to compact and continue, the current workflow is:

1. User says "please invoke your preparing-for-compaction skill, [continue with X]".
2. Agent persists context durably (writes plan files, updates beads, commits) and emits a "resumption prompt" — a short paragraph the user should send right after compaction.
3. **User** copies the resumption prompt, types `/compact`, then pastes the resumption prompt (which opencode queues behind the compact summary).

Step 3 is repetitive friction. Every compaction cycle, the user is doing mechanical work that the agent could trivially do itself. The agent already authors the resumption prompt; we just need to wire it directly into opencode's compact + queue machinery instead of routing through the user's clipboard.

## Goal

Equip the agent with a tool that, when called, compacts its own session **and** enqueues a resumption prompt so it becomes the first user message of the next (post-compaction) turn — entirely without user intervention beyond the original "please prepare for compaction" instruction.

## Non-Goals (MVP)

- Pigeon integration (i.e., letting Telegram trigger the same flow). Noted as post-MVP; design accommodates it.
- Auto-detection of when to compact (the user always initiates).
- Cross-session resumption (the prompt goes back into the same session).
- Sophisticated UX in the TUI for "compaction in progress" (we rely on opencode's existing rendering).

## Constraints

- Must work in opencode TUI (primary use case).
- Must not depend on pigeon being running.
- Distributed via home-manager / nix from the workstation monorepo.
- Single-file plugin if reasonable; matches existing workstation plugin convention (`compaction-context.ts`, `non-interactive-env.ts`).

## Key Findings (verified by source-reading + ChatGPT consultation)

These shaped the design. The full ChatGPT briefing is at `/tmp/research-opencode-self-compact-question.md` and the response is at `/tmp/research-opencode-self-compact-answer.md`.

1. **Compaction is asynchronous.** `POST /session/:id/summarize` only appends a synthetic "compaction" part to the message stream (`packages/opencode/src/session/compaction.ts:296`). The actual summarization happens in the next prompt-loop iteration (`packages/opencode/src/session/prompt.ts:706`).

2. **Naive "summarize then prompt_async" is racy.** If the tool calls both back-to-back, the resumption prompt may be enqueued *before* the loop consumes the compaction marker. Worse, opencode wraps mid-turn user messages with `<system-reminder>` and treats them as interruptions — not as a clean fresh turn. So the resumption prompt could end up against an un-compacted context, or rendered awkwardly.

3. **The right pattern is split-phase via plugin event hook.** Tool stashes the prompt and triggers compaction. Event handler (subscribed to `session.compacted`) waits for idle, then enqueues. This guarantees the prompt arrives as a fresh user turn against the post-compact context. **Verified:** event is emitted by `Bus.publish(Event.Compacted, { sessionID })` in `packages/opencode/src/session/compaction.ts:292`. Plugin event hook signature is `event?: (input: { event: Event }) => Promise<void>` (`packages/plugin/src/index.ts:149`).

4. **Use raw `fetch` against the in-process server, not the SDK wrappers.** There is an open opencode issue: "client.session.summarize hangs forever in Plugin". Pigeon documented that `ctx.client.session.promptAsync()` silently fails in serve mode. **Pattern (verified in pigeon, Task 0 of plan confirmed exact path):** capture `internalFetch = (ctx.client as any)._client?.getConfig?.()?.fetch ?? globalThis.fetch`, then call `internalFetch(new Request(new URL(\`/session/${id}/summarize\`, ctx.serverUrl).toString(), { method, headers, body }))`. This uses the in-process Hono transport in TUI mode while bypassing the unreliable generated SDK wrappers. Source: `pigeon/packages/opencode-plugin/src/index.ts:21-22`.

   ChatGPT proposed `ctx.client.post(...)`, but the SDK doesn't expose a public `.post` method on `OpencodeClient` — `_client` is `protected`. Earlier drafts of this design used `ctx.client.config.fetch` as the access path; that's also wrong (`config` is not a top-level property on the wrapper). Pigeon's `_client.getConfig().fetch` is the verified, in-production pattern.

5. **Model discovery: walk messages backward.** Opencode core itself derives the active model by walking backward through messages and taking the newest user message with `info.model`. There's no cleaner session-level "current model" field. We mirror this — same approach pigeon uses in `compact-ingest.ts`.

6. **`auto: false` is correct for user-initiated compaction.** It is the same value `/compact` passes from the TUI and `pigeon` passes from `/compact` swipe-replies.

7. **Status discriminator is `type`, not `status`.** `SessionStatus.Info` is `{ type: "idle" | "busy" | "retry", ... }` (`packages/opencode/src/session/status.ts:7`). The `GET /session/status` endpoint returns *all* sessions as a `Record<string, Info>`, not a single session's status. Absence of an entry implies idle (`SessionStatus.get` defaults to `{ type: "idle" }`). For per-session status, we either fetch the full record and pick our entry, or subscribe to the `session.status` event (more efficient but extra plumbing). MVP can rely on the natural ordering: `session.compacted` is published *after* the compaction work runs in the prompt loop, and `prompt_async` is fire-and-forget into opencode's queue, so we may not need to gate on idle at all. We'll decide during implementation.

## Architecture

### File layout

```
~/projects/workstation/
├── assets/opencode/plugins/
│   └── self-compact.ts             # NEW: the plugin
├── assets/opencode/skills/
│   └── preparing-for-compaction/
│       └── SKILL.md                 # UPDATED: final step calls the tool
└── users/dev/opencode-config.nix    # UPDATED: register the plugin
```

### Plugin structure (sketch — exact shapes finalized during implementation)

```typescript
import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"

interface PendingResume {
  prompt: string
  createdAt: number
}

const STALE_MS = 30 * 60 * 1000  // 30 minutes

const plugin: Plugin = async (ctx) => {
  const pending = new Map<string, PendingResume>()

  // Mirror pigeon's pattern: use the SDK's underlying fetch to keep the
  // in-process Hono transport in TUI mode while bypassing the unreliable
  // generated SDK wrappers (client.session.summarize / promptAsync are
  // known to hang or silently fail in plugin context).
  // Verified path (Task 0 of plan): _client.getConfig().fetch.
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch =
    sdkClientConfig?.fetch ?? globalThis.fetch

  async function callSummarize(sessionID: string, providerID: string, modelID: string) {
    const url = new URL(
      `/session/${encodeURIComponent(sessionID)}/summarize`,
      ctx.serverUrl,
    )
    const res = await internalFetch(
      new Request(url.toString(), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ providerID, modelID, auto: false }),
        signal: AbortSignal.timeout(10_000),
      }),
    )
    if (!res.ok) throw new Error(`summarize failed: ${res.status} ${await res.text()}`)
  }

  async function callPromptAsync(sessionID: string, text: string) {
    const url = new URL(
      `/session/${encodeURIComponent(sessionID)}/prompt_async`,
      ctx.serverUrl,
    )
    const res = await internalFetch(
      new Request(url.toString(), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          parts: [{ type: "text", text }],
          noReply: false,
        }),
        signal: AbortSignal.timeout(10_000),
      }),
    )
    if (!res.ok) throw new Error(`prompt_async failed: ${res.status} ${await res.text()}`)
  }

  async function findActiveModel(sessionID: string): Promise<{ providerID: string; modelID: string } | null> {
    const url = new URL(`/session/${encodeURIComponent(sessionID)}/message`, ctx.serverUrl)
    const res = await internalFetch(new Request(url.toString(), { method: "GET" }))
    if (!res.ok) return null
    const messages = (await res.json()) as Array<{
      info: { role: string; model?: { providerID?: string; modelID?: string } }
    }>
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i]
      if (m.info.role === "user" && m.info.model?.providerID && m.info.model?.modelID) {
        return { providerID: m.info.model.providerID, modelID: m.info.model.modelID }
      }
    }
    return null
  }

  return {
    tool: {
      self_compact_and_resume: tool({
        description:
          "Compact the current session and queue a resumption prompt that will be processed " +
          "as the first user message of the post-compaction turn. Use this as the final step " +
          "of the preparing-for-compaction skill, after persisting durable context.",
        args: {
          prompt: tool.schema
            .string()
            .describe("The resumption prompt to send after compaction completes."),
        },
        async execute(args, toolCtx) {
          // Evict stale entries opportunistically
          const now = Date.now()
          for (const [sid, p] of pending) {
            if (now - p.createdAt > STALE_MS) pending.delete(sid)
          }

          const model = await findActiveModel(toolCtx.sessionID)
          if (!model) {
            return "Cannot determine active model; aborting compaction. (No user message with model metadata found in this session.)"
          }

          // Stash AFTER model lookup succeeds so we don't leave orphan state on failure
          pending.set(toolCtx.sessionID, { prompt: args.prompt, createdAt: now })

          try {
            await callSummarize(toolCtx.sessionID, model.providerID, model.modelID)
          } catch (err) {
            pending.delete(toolCtx.sessionID)
            throw err
          }

          return "Compaction triggered. Your resumption prompt will be enqueued automatically once compaction completes."
        },
      }),
    },

    async event(input) {
      if (input.event.type !== "session.compacted") return
      const sessionID = (input.event as any).properties?.sessionID
      if (!sessionID) return
      const entry = pending.get(sessionID)
      if (!entry) return

      try {
        await callPromptAsync(sessionID, entry.prompt)
      } finally {
        pending.delete(sessionID)
      }
    },
  }
}

export default plugin
```

The exact `Event` discriminator shape (`input.event.type` vs. `input.event.event.type`) and the precise `properties` shape need to be verified against the `@opencode-ai/plugin` version we ship — the type cast `(input.event as any)` is a placeholder during the design phase. We'll tighten the types in implementation.

### Skill update

The `preparing-for-compaction` skill (currently at `~/.config/opencode/skills/preparing-for-compaction/SKILL.md`, sourced from `assets/opencode/skills/preparing-for-compaction/SKILL.md`) gets a new step 5:

> 5. **Trigger self-compaction.** Call the `self_compact_and_resume` tool with your drafted resumption prompt as the `prompt` argument. The plugin will compact the session and queue your prompt as the first user message of the post-compaction turn. The user does not need to do anything further.

The existing prose about "Provide a resumption prompt" is preserved but reframed: instead of presenting the prompt to the user for copy-paste, you pass it to the tool. The "Example Resumption Prompt" section remains useful as guidance for what makes a good prompt.

### Distribution

In `users/dev/opencode-config.nix`, alongside the existing plugin registrations (around line 109):

```nix
xdg.configFile."opencode/plugins/self-compact.ts".source =
  "${assetsPath}/opencode/plugins/self-compact.ts";
```

Apply via `nix run home-manager -- switch --flake .#dev` on devbox/cloudbox or `darwin-rebuild switch` on macOS.

## Data Flow

```
User: "please invoke preparing-for-compaction"
  │
  ▼
Agent (skill steps 1-4): persist durable context, draft resumption prompt
  │
  ▼
Agent (new step 5): tool.self_compact_and_resume({ prompt: "..." })
  │
  ├─► Plugin: pending[sessionID] = { prompt, createdAt }
  ├─► Plugin: discover model from message history
  ├─► Plugin: POST /session/:id/summarize (auto: false)
  └─► Returns "Compaction triggered..."
  │
  ▼
Tool returns; current assistant turn ends
  │
  ▼
opencode prompt loop: sees compaction marker → runs summarization
  │
  ▼
opencode emits event: session.compacted { sessionID }
  │
  ▼
Plugin event handler:
  ├─► Look up pending[sessionID] → found
  ├─► Poll session.status until idle (≤5s)
  └─► POST /session/:id/prompt_async with the stashed prompt
  │
  ▼
opencode treats it as a fresh user turn
  │
  ▼
Agent processes the resumption prompt and continues work
```

## Testing Strategy

Tests live alongside the plugin. The exact harness depends on what infra exists for testing workstation plugins:

- **Option A (preferred if simple):** Add a `package.json` + vitest config beside the plugin. Mirrors how pigeon plugin tests are structured.
- **Option B:** Co-locate in pigeon-style devenv, but that conflates ownership.

Tests (TDD, written before implementation):

1. Tool stashes prompt and POSTs to `/summarize` with correct body.
2. Tool extracts model from the last user message in history.
3. Tool returns an error message and clears state when no model can be determined.
4. Event handler ignores events whose type ≠ `session.compacted`.
5. Event handler ignores `session.compacted` for sessions with no pending prompt.
6. Event handler POSTs to `/prompt_async` with correct body when a pending prompt exists.
7. Event handler clears the pending entry after enqueueing.
8. Stale entries (>30min) are evicted on next tool call.

Mocking strategy mirrors pigeon's `compact-ingest.test.ts`: pass a `Pick<Client, "post" | "session">` interface so the test can assert on calls without bringing up a real opencode server.

## Verification (manual smoke test)

After deployment, manual steps to verify end-to-end:

1. In a real opencode TUI session, do some work to accumulate context.
2. Say "please invoke your preparing-for-compaction skill, then continue with [trivial follow-up task]".
3. Agent runs the skill, calls `self_compact_and_resume`.
4. Observe: TUI shows compaction happening, then immediately processes the resumption prompt as a new turn.
5. Verify: post-compaction context contains only the summary + the resumption prompt as the first user message.

## Risks & Open Questions (for implementation)

1. ~~**Event name verification.**~~ ✅ Verified: `session.compacted` is published with `{ sessionID }` properties (`compaction.ts:292`).
2. **Exact `Event` discriminator shape in the plugin hook.** The plugin hook receives `{ event: Event }`. We need to confirm whether the type discriminator is `event.type` (e.g., `"session.compacted"`) or nested deeper. Will resolve by reading `@opencode-ai/plugin` types at implementation time.
3. **Race: tool returns before event fires.** The tool returns synchronously; the event handler fires later. If something interrupts between them (process crash, plugin reload), the pending prompt is lost. MVP accepts this — user can re-invoke the skill. Future improvement: persist pending state to disk.
4. **Duplicate sessions.** The `pending` Map is per-process; if a session is reopened in a new opencode process before the event fires, the pending prompt is lost. MVP accepts.
5. **Multi-step compactions / failed compactions.** What if `summarize` succeeds but the session crashes before `session.compacted` fires? Pending prompt sits stale until evicted at 30min. Acceptable.
6. **TUI rendering of injected prompts.** Historical opencode TUI bugs reportedly mishandled `prompt_async`-injected prompts. We'll discover and report any rendering oddities during smoke testing.
7. **Should we gate enqueueing on idle?** ChatGPT recommended polling `session.status` for idle before calling `prompt_async`. But: (a) `prompt_async` is fire-and-forget into opencode's queue — busy state shouldn't matter; (b) `session.compacted` is published *after* the compaction work, so by the time we receive it, the busy state from the compaction has already cleared. **Decision deferred to implementation:** start without idle gating, add it only if smoke testing reveals timing issues.

## Pigeon Integration (Post-MVP, Sketched)

Two viable paths, both purely additive:

**A. Telegram command extension.** Add a `/compact-then <prompt>` (or `/compact <prompt>` with optional payload) to pigeon's worker. Daemon delivers it as a structured payload that ends up calling `self_compact_and_resume`. Requires a small new endpoint on the plugin (e.g., HTTP on the existing direct-channel) that pigeon can hit to set the pending entry directly. Most powerful and pigeon-native.

**B. Synthetic prompt routing.** Pigeon sends a normal message that says "use the self_compact_and_resume tool with this resumption text: ...". Zero new plugin code. Less elegant; requires the agent to interpret a meta-instruction.

We'll choose between these when we get to that work. Either way, MVP doesn't need any provision for them — the design's split-phase shape is already friendly to both.

## Decision Log

- **Split-phase (tool + event handler)** chosen over naive "summarize then prompt_async in the tool" — ChatGPT identified ordering races and mid-turn `<system-reminder>` wrapping that would corrupt the resumption-prompt UX.
- **`ctx.client.post(...)` chosen** over `ctx.client.session.summarize/promptAsync` — known reliability issues with the generated SDK wrappers in plugin context (open opencode issue + pigeon's documented experience).
- **`auto: false`** chosen for `summarize` — matches user-initiated compaction semantics; `auto: true` would gate the result behind opencode's auto-continue branch which we don't want.
- **Module-level `Map` for pending state** chosen over disk persistence — simpler, sufficient for MVP given user can always re-invoke the skill if the process dies between trigger and event fire.
- **Plugin lives in `assets/opencode/plugins/`** rather than `pkgs/` or its own repo — matches existing convention; no need for a separately-versioned Nix derivation for a small single-file plugin.
- **Pigeon integration deferred** to post-MVP — keeps scope tight; design accommodates it.

## References

- ChatGPT briefing: `/tmp/research-opencode-self-compact-question.md`
- ChatGPT response: `/tmp/research-opencode-self-compact-answer.md`
- Existing plugin precedent: `assets/opencode/plugins/compaction-context.ts`
- Pigeon's compact handler: `~/projects/pigeon/packages/daemon/src/worker/compact-ingest.ts`
- Pigeon's plugin (HTTP transport pattern): `~/projects/pigeon/packages/opencode-plugin/src/index.ts`
- Opencode summarize route: `~/projects/opencode/packages/opencode/src/server/routes/session.ts:485`
- Opencode compaction internals: `~/projects/opencode/packages/opencode/src/session/compaction.ts:296`
- Opencode prompt loop (queued message handling): `~/projects/opencode/packages/opencode/src/session/prompt.ts:631,706`
- Plugin SDK tool definition: `~/projects/opencode/packages/plugin/src/tool.ts`
- Plugin SDK type surface: `~/projects/opencode/packages/plugin/src/index.ts`

---

## Addendum 2026-04-21: Architecture Reversal (Idle-Triggered Summarize)

**Status of original architecture:** Implemented through Tasks 0-12, deployed, smoke-tested — and **deadlocks**. Superseded by the v2 idle-triggered architecture, which **landed and smoke-test passed on 2026-04-21**. The v2 implementation is the active code on `main` (commits `dcc6162..df3d3d5`) and is described in `docs/plans/2026-04-21-self-compact-idle-trigger-plan.md`.

**v2 smoke test result (2026-04-21):** Tool `self_compact_and_resume` completed in `duration=0` (stash-and-return as designed); subsequent `POST /summarize` ran from the idle handler and completed cleanly in `duration=81796ms` (~82s — actual model summarization time, not a hang); `session.compacted` bus event fired; `POST /prompt_async` enqueued the resumption prompt; new session loop started with the resumption prompt as the first user message. The v1 deadlock signature (>4-minute hang ending in manual `/abort`) did not recur. Log evidence: `~/.local/share/opencode/log/2026-04-21T125635.log` lines ~5300-5346.

### What we got wrong

The v1 design assumed `POST /session/:id/summarize` from inside the tool's `execute` would trigger compaction the same way the TUI's `/compact` slash-command does. **It does not — when called mid-turn it deadlocks.**

### Root cause (verified from opencode source + log evidence)

The HTTP route at `packages/opencode/src/server/routes/session.ts:516-539` does:

```ts
await SessionCompaction.create({...})  // writes the compaction marker part
await SessionPrompt.loop({ sessionID }) // <-- runs the prompt loop synchronously
```

`SessionPrompt.loop` checks `start(sessionID)` (`prompt.ts:239-248`); if a loop is already running for that session it returns `undefined`, and `loop()` then enqueues a callback and `await`s the existing loop's resolution (`prompt.ts:278-284`):

```ts
const abort = resume_existing ? resume(sessionID) : start(sessionID)
if (!abort) {
  return new Promise<MessageV2.WithParts>((resolve, reject) => {
    const callbacks = state()[sessionID].callbacks
    callbacks.push({ resolve, reject })
  })
}
```

When our plugin tool's `execute` calls `POST /summarize`:

1. The outer prompt loop is currently mid-turn (it's waiting for our `execute` to return).
2. `/summarize` calls `SessionPrompt.loop` → joins the outer loop's callback queue → awaits its resolution.
3. The outer loop can only resolve once our tool returns.
4. Our tool can only return once `await callSummarizeHttp` resolves.
5. **Mutual await. Deadlock.**

The 10-second `AbortSignal.timeout(10_000)` we placed on `callSummarizeHttp` does not save us. The in-process Hono fetch may or may not honor client-side AbortSignals; even when it does, the abort only cancels the client's fetch — the server's `await loop()` keeps waiting indefinitely.

**Log evidence** (`~/.local/share/opencode/log/2026-04-21T025630.log`):
- 02:59:32 — first `POST /summarize` arrives at server
- 03:03:30 — same request still pending after ~4 minutes; **user manually `POST /abort`** which kills the deadlocked outer loop
- After revert + a fresh user `/message` POST (which kicks a fresh idle-state loop), 03:05:10's second `/summarize` from idle completes naturally; `session.compacted` fires at 03:06:54; `prompt_async` lands at 03:06:54+1ms; resumption-prompt enqueue path works correctly **once the trigger fires from idle**.

So the split-phase architecture (tool stash → bus event → prompt_async) is sound. **What's wrong is the trigger location: summarize must fire from outside any active turn, never from inside a tool's `execute`.**

### Cross-checks

- **Pigeon does not exhibit this.** Pigeon's `ingestCompactCommand` (`pigeon/packages/daemon/src/worker/compact-ingest.ts:47`) calls the same `POST /summarize` endpoint, but from a daemon process — the session is always idle when pigeon hits it. Pigeon was never the proof-of-concept this design assumed.
- **The TUI does not exhibit this.** The TUI's `/compact` slash-command (`opencode/packages/opencode/src/cli/cmd/tui/routes/session/index.tsx:466-470`) calls `sdk.client.session.summarize(...)` — but only as a user-initiated keyboard action when no prompt loop is active.
- **No upstream issue covers this.** Of the 25 compaction-related issues searched on `anomalyco/opencode`, none describe plugin-tool-triggered summarize. The closest, #16395 ("Compacting status never appears in TUI"), is about a missing `session.time.compacting` field — orthogonal to our deadlock.

### Tangential discoveries

These don't affect the redesign but were learned during RCA:

1. **The TUI streaming you see during interactive `/compact` is just the normal assistant message-part stream.** `SessionCompaction.process` calls `processor.process(...)` which is the same processor used for any LLM turn; the TUI subscribes to `message.part.updated` and renders. There is no "compaction-mode" rendering path. So a working v2 will get the streaming UX automatically — provided the trigger fires when the TUI isn't already showing "tool running" overlay.
2. **`session.time.compacting` is a dead field.** `sync.tsx:463` checks it for the "compacting" status indicator but compaction.ts never sets it. Upstream issue #16395, no PR.
3. **`session.idle` is "deprecated"** but still emitted (`status.ts:36-41`). The non-deprecated event is `session.status` with `status.type === "idle"` (`status.ts:62-71`). Use `session.status` in v2 and discriminate on `status.type`.
4. **`/compact` text via `prompt_async` does NOT invoke the slash command.** Slash commands are TUI command-palette entries (`session/index.tsx:447-455`), not server-interpreted. Sending the literal text would just be enqueued as a user message saying "/compact". Not a viable shortcut.

### The v2 architecture

**Tool's `execute` becomes a no-op stash.** It captures `(sessionID, prompt)` into the in-memory `pending` map, marks the entry's phase as `awaitingTurnEnd`, and returns immediately ("Compaction queued; will run when this turn ends.").

**A new event handler subscribes to `session.status`.** When the status transitions to `idle` for a session that has a `pending` entry in phase `awaitingTurnEnd`:
1. Promote the entry to phase `summarizing`.
2. Look up the active model (existing `findActiveModel` logic).
3. Fire `POST /summarize` from the now-idle state. Drop the 10-second timeout (match pigeon: no client-side timeout).
4. Do not await deeply — the call is fire-and-let-the-loop-do-its-thing; we don't actually need its return value because the existing `session.compacted` handler does the next step.

**The existing `session.compacted` handler is unchanged.** When the bus event fires after compaction completes, the handler pops the pending entry and `POST /prompt_async`s the resumption prompt. (This already worked correctly in the v1 smoke test; the only thing that didn't work was getting compaction to start in the first place.)

**End-to-end flow:**

```
LLM emits tool call: self_compact_and_resume(prompt="...")
  ↓
Tool execute: pending.set(sessionID, {prompt, phase: 'awaitingTurnEnd'})
Tool execute: returns "Compaction queued; will run when this turn ends."
  ↓
LLM ack's tool result, finishes turn (no follow-up planned)
  ↓
SessionPrompt.loop sets status.type = 'idle' on exit (prompt.ts:267)
  ↓
Bus publishes session.status { sessionID, status: { type: 'idle' } }
  ↓
Plugin onStatus handler:
  - sees pending[sessionID].phase === 'awaitingTurnEnd'
  - flips phase to 'summarizing'
  - findActiveModel → POST /summarize from idle (works correctly)
  ↓
Server: SessionCompaction.create → SessionPrompt.loop runs from idle
  → assistant message of mode=compaction streams parts → TUI renders
  ↓
Compaction completes, Bus publishes session.compacted
  ↓
Plugin onCompacted handler (unchanged from v1):
  - pops pending entry
  - POST /prompt_async with resumption text
  ↓
Resumption prompt arrives as next user turn (with full TUI streaming UX)
```

### Why this works without re-introducing the deadlock

When `onStatus` fires `POST /summarize`, the outer prompt loop has already `await`ed its `defer(() => cancel(sessionID))` (`prompt.ts:286`) which calls `SessionStatus.set(..., {type: 'idle'})` which is what published the event we're handling. The outer loop is gone. The summarize-triggered `loop()` call sees `start(sessionID)` succeed (no existing loop), gets a real abort signal, and runs to completion.

There IS a subtle timing question: is there a race where `onStatus` fires `POST /summarize` so quickly that the outer loop's cleanup hasn't fully torn down its state? The defer/cancel is synchronous (`prompt.ts:257-269`) and `SessionStatus.set` is synchronous (`status.ts:61-75`). The bus event fires synchronously inside `set`. So by the time our handler runs, the outer loop's state entry is already `delete`d (`prompt.ts:266`). The race is impossible. (We could also defensively `await` a microtask before firing summarize; cheap insurance.)

### What stays from v1

- `assets/opencode/plugins/self-compact.ts` (entry, only `default` export) — file structure unchanged
- `assets/opencode/plugins/self-compact-impl.ts` — most helpers reused
  - `findActiveModel` — unchanged
  - `callSummarizeHttp` — drop `AbortSignal.timeout(10_000)`; otherwise unchanged
  - `callPromptAsyncHttp` — keep `AbortSignal.timeout(10_000)` (this one is genuinely fast)
  - `PluginBusEvent` + `isSessionCompacted` type predicate — unchanged
  - `createOnCompacted` factory — unchanged
- Test harness (`vitest`, `package.json`, etc.) — unchanged
- Deployment via `mkOutOfStoreSymlink` — unchanged
- Skill `assets/opencode/skills/preparing-for-compaction/SKILL.md` — minor update to expectation-setting language (the agent should know the tool returns instantly; compaction happens after the turn closes)

### What changes from v1

- `createSelfCompactTool.execute` — drops `findActiveModel` call, drops `callSummarize` call, drops the try/catch+pending.delete. Now: stash entry, return string. Add `phase: 'awaitingTurnEnd' | 'summarizing'` to the `PendingResume` shape.
- New factory `createOnStatus(deps)` — takes `pending`, `findActiveModel`, `callSummarize`. Handler fires on `session.status` events; checks for `idle` + matching pending entry in `awaitingTurnEnd` phase; promotes to `summarizing` then triggers summarize. Includes its own `isSessionStatusIdle` type predicate paralleling `isSessionCompacted`.
- `self-compact.ts` — must register BOTH `onStatus` and `onCompacted`. The plugin's `event` hook receives a single `(input: { event }) => Promise<void>` function; we'll compose them by dispatching internally on `event.type`.

### Decisions

- **Listen to `session.status` (not `session.idle`).** `session.idle` is marked deprecated upstream. `session.status` carries the discriminated state directly.
- **Drop `AbortSignal.timeout(10_000)` on summarize.** It's wrong for a long-running endpoint and was masking the real problem. Match pigeon (no timeout).
- **Add `phase` to PendingResume.** Without it, the status-handler can't distinguish "first idle after queue" (should fire summarize) from "second idle after summarize completes" (no-op, the compacted handler will run separately) from "post-compaction idle" (no-op). Phase makes the state machine explicit.
- **Same `pending` Map.** Don't introduce a second map for `summarizing` state. Single source of truth, single state machine.
- **No Map snapshot via JSON.** State doesn't need to survive process restart for MVP. v1's note about "stale entries evicted at 30 min" still applies.
- **No retry on summarize failure.** If summarize fails (network, model error), evict the pending entry and log. User re-invokes the skill. Matches v1's no-retry stance for prompt_async.
- **The current broken code stays on main.** It's not invoked unless the agent calls the tool, which the skill currently directs it to do. We'll update the skill in v2's first task to set the expectation that the tool returns instantly.

### Risks for v2

- **What if the LLM follows up with another tool call before the turn ends?** The status won't go idle until that nested turn completes. That's actually correct: we WANT to wait for the full turn to finish. Risk: if the LLM emits an infinite tool-call loop after self_compact_and_resume, we never fire summarize. Mitigation: 30-min stale-eviction (already present).
- **What if multiple `self_compact_and_resume` calls happen in the same turn?** Last-write-wins on the pending entry. Acceptable for MVP.
- **What if the user starts a new turn (sends a message) between the tool returning and idle firing?** The status briefly goes idle (between the assistant turn ending and the new user message starting a new loop), our handler fires summarize, the new user message gets enqueued behind the compaction. Order: user message → compaction → summarize completes → resumption prompt → new user message (?). Need to confirm during smoke test. Worst case: user message arrives in the post-compaction context, before the resumption prompt. Probably acceptable.

### Implementation plan

See `docs/plans/2026-04-21-self-compact-idle-trigger-plan.md`.
