# Self-Compact v2: Idle-Triggered Summarize Implementation Plan

**Status: COMPLETED 2026-04-21.** All 8 tasks landed on `main` (commits `dcc6162..df3d3d5`); live smoke test passed (see addendum in `2026-04-20-self-compact-plugin-design.md` for evidence).

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the deadlock in v1 of the self-compact plugin by moving the `POST /summarize` trigger out of the tool's `execute` and into a `session.status` event handler that fires when the session goes idle (after the agent's tool-call turn closes).

**Architecture:** Tool's `execute` becomes a no-op stash: it inserts `(sessionID, prompt, phase: 'awaitingTurnEnd')` into the existing `pending` Map and returns immediately. A new `onStatus` event handler watches for `session.status` events with `status.type === "idle"`; on match, it promotes the pending entry to `phase: 'summarizing'` and fires `POST /summarize` from idle (deadlock-free). The existing `onCompacted` handler is unchanged — it continues to enqueue the resumption prompt via `POST /prompt_async` when `session.compacted` fires.

**Tech Stack:** TypeScript, `@opencode-ai/plugin`, vitest, home-manager nix, opencode HTTP API. Same dependencies as v1.

**Design doc:** `docs/plans/2026-04-20-self-compact-plugin-design.md` — see "Addendum 2026-04-21: Architecture Reversal" at the bottom for the full root-cause analysis and v2 architecture.

---

## RESUMPTION CONTEXT (compaction handoff, 2026-04-21)

**This section is durable context for the post-compaction self.** Read this first; the plan body below is the canonical task reference but this section is the moment-in-time state.

### What just happened

The pre-compaction self investigated why the v1 `self_compact_and_resume` tool deadlocked when smoke-tested. Root cause is documented in the addendum at the bottom of the v1 design doc: calling `POST /summarize` from inside a tool's `execute` deadlocks because the route synchronously awaits `SessionPrompt.loop()` which joins the outer (currently-running, currently-awaiting-our-tool's-return) loop's callback queue. Mutual await.

Fix is the v2 architecture in this plan: tool stashes pending entry and returns instantly; a new `onStatus` event handler fires summarize after the turn ends and the session goes idle.

You compacted MANUALLY (typed `/compact` and pasted this prompt). The v1 tool was NOT invoked for this compaction — it is broken.

### State at handoff

- **Branch:** `main`
- **Working tree:** clean (assuming pre-compaction commits and push succeeded)
- **Commits ahead of origin/main:** zero (we pushed before compacting)
- **v1 plugin status:** deployed and loaded but BROKEN (deadlocks when `self_compact_and_resume` is invoked). Do not invoke the tool until v2 ships.
- **v1 design doc:** `docs/plans/2026-04-20-self-compact-plugin-design.md` — has the original architecture in the body and the v2 reversal in the addendum
- **v1 plan:** `docs/plans/2026-04-20-self-compact-plugin-plan.md` — Tasks 0-12 done, Task 13 smoke test failed, Task 14 superseded by this v2 plan
- **v2 plan:** this file
- **Skill:** `assets/opencode/skills/preparing-for-compaction/SKILL.md` currently directs the agent to call `self_compact_and_resume`. Until Task 7 of this plan lands, that direction will deadlock if followed. Be aware.

### What to do first

1. Read the addendum at the bottom of `docs/plans/2026-04-20-self-compact-plugin-design.md` — it's the source of truth for the v2 architecture and the deadlock RCA.
2. Read this plan top-to-bottom.
3. Begin Task 0.

### Critical environment quirks (carry over from v1)

- **gpg-agent is unresponsive.** Every commit MUST use `--no-gpg-sign`.
- **No `sleep` in bash.** Use bounded loops, `timeout`, or direct condition checks.
- **Use bash tool's `workdir` parameter**, not `cd /foo && cmd`.
- **Host is cloudbox.** Home-manager target is `.#cloudbox`, not `.#dev`.
- **Smoke test cannot use the broken v1 tool.** Smoke test the v2 by manually `/compact`ing and visually verifying the new flow on a throwaway session, OR by waiting until v2 is deployed and then attempting a real self-compact.

### Subagent dispatch routing

| Task type | Subagent |
|-----------|----------|
| Implementation (red+green TDD task pair) | `implementer` |
| Spec compliance review | `spec-reviewer` |
| Code quality review | `code-reviewer` |
| Read-only research | `explore` |

### Files

- `assets/opencode/plugins/self-compact.ts` — entry, only `default` export (will register both event handlers)
- `assets/opencode/plugins/self-compact-impl.ts` — all helpers and tests' targets (most changes here)
- `assets/opencode/plugins/test/self-compact.test.ts` — vitest tests (will grow)
- `assets/opencode/skills/preparing-for-compaction/SKILL.md` — agent-facing skill (Task 7)

---

## Task 0: Verify v2 design assumptions are still true

A 5-minute reading task before writing code. Confirm the source code we depended on hasn't changed since the addendum was authored.

**Files:**

- Read: `~/projects/opencode/packages/opencode/src/session/status.ts`
- Read: `~/projects/opencode/packages/opencode/src/session/prompt.ts:239-296` (the `start`, `cancel`, top of `loop`)
- Read: `~/projects/opencode/packages/opencode/src/server/routes/session.ts:484-540` (the `/summarize` route)

**Step 1: Confirm `session.status` event shape**

Verify `SessionStatus.Event.Status` is defined as:

```ts
Status: BusEvent.define(
  "session.status",
  z.object({
    sessionID: z.string(),
    status: Info,  // { type: "idle" | "busy" | "retry", ... }
  }),
)
```

If the shape has shifted (e.g., property name change, nested structure), the type predicate in Task 2 must be adjusted accordingly.

**Step 2: Confirm `set` publishes synchronously**

Confirm `SessionStatus.set` calls `Bus.publish(Event.Status, ...)` synchronously and that the publish happens BEFORE `delete state()[sessionID]` (which otherwise would race the handler's `pending` lookup; the handler doesn't read state(), just our own `pending`, but worth knowing).

**Step 3: Confirm `loop()` re-entrancy resolves cleanly**

Re-read `prompt.ts:275-284`. Confirm that when a second `loop()` call is made on a session that already has an active loop, the second call awaits a callback rather than starting a parallel loop. (This is the deadlock mechanism in v1; we need it confirmed because v2's safety depends on the OUTER loop completing before our handler fires the next `/summarize`.)

**Step 4: Note findings**

If any assumption has broken, STOP and re-read the addendum to see whether the v2 architecture still holds. If all assumptions hold, proceed.

**No commit yet.**

---

## Task 1: Failing test for tool's new "stash and return" semantics

**Files:**

- Modify: `assets/opencode/plugins/test/self-compact.test.ts`

**Step 1: Find the existing `createSelfCompactTool` test block**

Search for `describe("createSelfCompactTool"` (or similar) in the test file. The existing tests assert behavior like "calls findActiveModel" and "calls callSummarize" — those tests will be invalidated by the redesign.

**Step 2: Write new failing tests**

Replace the existing `createSelfCompactTool` tests with these (full TDD: run them first, watch them fail, THEN implement Task 2):

```ts
describe("createSelfCompactTool (v2: stash-and-return)", () => {
  it("stashes pending entry with phase 'awaitingTurnEnd' and returns instantly", async () => {
    const pending = new Map<string, PendingResume>()
    const tool = createSelfCompactTool({ pending })
    const result = await tool.execute(
      { prompt: "resume here" },
      { sessionID: "ses_abc" },
    )
    expect(result).toMatch(/queued/i)
    expect(pending.get("ses_abc")).toMatchObject({
      prompt: "resume here",
      phase: "awaitingTurnEnd",
    })
  })

  it("does NOT call findActiveModel or callSummarize from execute", async () => {
    // Verifies the v1 deadlock vector is removed.
    const pending = new Map<string, PendingResume>()
    const tool = createSelfCompactTool({ pending })
    // The factory should not even accept findActiveModel/callSummarize as deps anymore.
    // If this test compiles AND passes, the API surface is correct.
    await tool.execute({ prompt: "x" }, { sessionID: "ses_abc" })
    // Nothing to assert beyond "didn't throw and didn't await any HTTP work" —
    // type-level assertion: createSelfCompactTool's `deps` parameter has only `pending`.
  })

  it("evicts stale entries (>30min) before stashing", async () => {
    const pending = new Map<string, PendingResume>()
    const STALE_MS = 30 * 60 * 1000
    pending.set("ses_old", {
      prompt: "ancient",
      phase: "awaitingTurnEnd",
      createdAt: Date.now() - STALE_MS - 1,
    })
    const tool = createSelfCompactTool({ pending })
    await tool.execute({ prompt: "fresh" }, { sessionID: "ses_new" })
    expect(pending.has("ses_old")).toBe(false)
    expect(pending.has("ses_new")).toBe(true)
  })

  it("overwrites a prior pending entry for the same session (last-write-wins)", async () => {
    const pending = new Map<string, PendingResume>()
    const tool = createSelfCompactTool({ pending })
    await tool.execute({ prompt: "first" }, { sessionID: "ses_x" })
    await tool.execute({ prompt: "second" }, { sessionID: "ses_x" })
    expect(pending.get("ses_x")?.prompt).toBe("second")
  })
})
```

**Step 3: Run tests to verify they fail**

Run: `npm test -- --run` (from `assets/opencode/plugins/`)

Expected: TypeScript should likely still compile (the existing factory signature still works); the new tests should fail because the existing implementation calls `findActiveModel` and `callSummarize` as part of execute and uses a different `PendingResume` shape (no `phase` field).

**Step 4: Commit**

```bash
git add assets/opencode/plugins/test/self-compact.test.ts
git commit --no-gpg-sign -m "test(self-compact): failing tests for v2 stash-and-return tool semantics

Documents the new tool contract: execute() stashes pending entry with
phase='awaitingTurnEnd' and returns instantly; no HTTP work happens
inside execute. Deletes the v1 contract that drove the deadlock."
```

---

## Task 2: Implement v2 tool: stash-and-return

**Files:**

- Modify: `assets/opencode/plugins/self-compact-impl.ts`

**Step 1: Update `PendingResume` shape**

Add the `phase` discriminator:

```ts
export interface PendingResume {
  prompt: string
  phase: "awaitingTurnEnd" | "summarizing"
  createdAt: number
}
```

**Step 2: Rewrite `createSelfCompactTool`**

Replace the v1 implementation. New signature takes ONLY `pending`:

```ts
export function createSelfCompactTool(deps: {
  pending: Map<string, PendingResume>
}) {
  return {
    async execute(args: { prompt: string }, toolCtx: { sessionID: string }): Promise<string> {
      const now = Date.now()
      // Evict stale entries
      for (const [sid, entry] of deps.pending) {
        if (now - entry.createdAt > STALE_MS) deps.pending.delete(sid)
      }
      deps.pending.set(toolCtx.sessionID, {
        prompt: args.prompt,
        phase: "awaitingTurnEnd",
        createdAt: now,
      })
      return "Compaction queued; will run when this turn ends."
    },
  }
}
```

`STALE_MS` constant stays at `30 * 60 * 1000` (no change from v1).

**Step 3: Run tests to verify they pass**

Run: `npm test -- --run`

Expected: All four new tests in Task 1 pass. (Existing `createOnCompacted` and `findActiveModel` tests should still pass — they're untouched.)

**Step 4: Commit**

```bash
git add assets/opencode/plugins/self-compact-impl.ts
git commit --no-gpg-sign -m "feat(self-compact): rewrite tool execute as stash-and-return (v2)

Removes the v1 deadlock vector. Tool execute now only inserts a pending
entry into the in-memory map and returns instantly. The actual summarize
trigger moves to the new onStatus handler in Task 4.

Adds 'phase' field to PendingResume to drive the state machine that
distinguishes 'queued, awaiting turn end' from 'summarize fired,
awaiting compacted bus event'."
```

---

## Task 3: Failing test for `createOnStatus` event handler

**Files:**

- Modify: `assets/opencode/plugins/test/self-compact.test.ts`

**Step 1: Add new describe block for `createOnStatus`**

```ts
describe("createOnStatus (v2: idle-triggered summarize)", () => {
  it("ignores non-status events", async () => {
    const pending = new Map<string, PendingResume>()
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn()
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "ses_x" } } })
    expect(callSummarize).not.toHaveBeenCalled()
  })

  it("ignores non-idle status events", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn()
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "busy" } },
      },
    })
    expect(callSummarize).not.toHaveBeenCalled()
  })

  it("ignores idle status for sessions without a pending entry", async () => {
    const pending = new Map<string, PendingResume>()
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn()
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(callSummarize).not.toHaveBeenCalled()
  })

  it("ignores idle status for entries already in 'summarizing' phase (no double-trigger)", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "summarizing", createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn()
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(callSummarize).not.toHaveBeenCalled()
  })

  it("on idle for awaitingTurnEnd entry: promotes to summarizing then fires summarize", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn().mockResolvedValue(undefined)
    const findActiveModel = vi.fn().mockResolvedValue({ providerID: "anthropic", modelID: "claude" })
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(findActiveModel).toHaveBeenCalledWith({ sessionID: "ses_x" })
    expect(callSummarize).toHaveBeenCalledWith({
      sessionID: "ses_x",
      providerID: "anthropic",
      modelID: "claude",
    })
    expect(pending.get("ses_x")?.phase).toBe("summarizing")
  })

  it("evicts pending entry if findActiveModel returns null (no model means no compaction)", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn().mockResolvedValue(null)
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(callSummarize).not.toHaveBeenCalled()
    expect(pending.has("ses_x")).toBe(false)
  })

  it("evicts pending entry if callSummarize throws (no retry; user re-invokes the skill)", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn().mockRejectedValue(new Error("boom"))
    const findActiveModel = vi.fn().mockResolvedValue({ providerID: "a", modelID: "m" })
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(pending.has("ses_x")).toBe(false)
  })

  it("phase promotion happens BEFORE await — re-entrant idle event for same session does not double-trigger", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() }],
    ])
    let summarizeCalls = 0
    const callSummarize = vi.fn().mockImplementation(async () => {
      summarizeCalls++
      // While summarize is "in flight", simulate a re-entrant idle event:
      await handler({
        event: {
          type: "session.status",
          properties: { sessionID: "ses_x", status: { type: "idle" } },
        },
      })
    })
    const findActiveModel = vi.fn().mockResolvedValue({ providerID: "a", modelID: "m" })
    const handler = createOnStatus({ pending, callSummarize, findActiveModel })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(summarizeCalls).toBe(1)
  })
})
```

**Step 2: Run tests to verify all 7 fail**

Run: `npm test -- --run`

Expected: TypeScript fails to compile because `createOnStatus` doesn't exist. (Vitest will report compile errors as failures.)

**Step 3: Commit**

```bash
git add assets/opencode/plugins/test/self-compact.test.ts
git commit --no-gpg-sign -m "test(self-compact): failing tests for createOnStatus event handler

Documents v2's idle-triggered summarize semantics: handler ignores
non-status / non-idle / non-pending events, promotes phase synchronously
before awaiting summarize (re-entrancy safety), and evicts pending
entries on either model lookup failure or summarize throw."
```

---

## Task 4: Implement `createOnStatus`

**Files:**

- Modify: `assets/opencode/plugins/self-compact-impl.ts`

**Step 1: Add the type predicate**

Mirroring `isSessionCompacted`. Place it near the existing predicate:

```ts
/**
 * Narrows a PluginBusEvent to a SessionStatus event with status.type === 'idle'.
 * The status discriminator is "type" (per status.ts:7-21), not "status" — this
 * was a known v1 confusion captured in the original design doc finding #7.
 */
function isSessionIdle(event: PluginBusEvent): event is {
  type: "session.status"
  properties: { sessionID: string; status: { type: "idle" } }
} {
  if (event.type !== "session.status") return false
  const props = event.properties
  if (!props || typeof props !== "object") return false
  const p = props as Record<string, unknown>
  if (typeof p.sessionID !== "string") return false
  const status = p.status as { type?: unknown } | undefined
  return !!status && status.type === "idle"
}
```

**Step 2: Add the factory**

Place adjacent to `createOnCompacted`:

```ts
export function createOnStatus(deps: {
  pending: Map<string, PendingResume>
  callSummarize: (input: {
    sessionID: string
    providerID: string
    modelID: string
  }) => Promise<void>
  findActiveModel: (input: { sessionID: string }) => Promise<{ providerID: string; modelID: string } | null>
}) {
  return async ({ event }: { event: PluginBusEvent }) => {
    if (!isSessionIdle(event)) return
    const { sessionID } = event.properties
    const entry = deps.pending.get(sessionID)
    if (!entry) return
    if (entry.phase !== "awaitingTurnEnd") return

    // Promote phase synchronously BEFORE awaiting anything so a re-entrant
    // idle event for the same session can't double-trigger.
    entry.phase = "summarizing"

    const model = await deps.findActiveModel({ sessionID })
    if (!model) {
      // No model means we can't proceed; evict the entry. User will re-invoke
      // the skill if they still want to compact.
      deps.pending.delete(sessionID)
      return
    }

    try {
      await deps.callSummarize({ sessionID, providerID: model.providerID, modelID: model.modelID })
      // On success, leave the entry in 'summarizing' phase. The session.compacted
      // handler will pop it when compaction completes.
    } catch {
      // Summarize failed; evict so the next idle doesn't retry. User re-invokes.
      deps.pending.delete(sessionID)
    }
  }
}
```

**Step 3: Run tests to verify all 7 pass**

Run: `npm test -- --run`

Expected: All Task 3 tests pass. All previously-passing tests still pass.

**Step 4: Commit**

```bash
git add assets/opencode/plugins/self-compact-impl.ts
git commit --no-gpg-sign -m "feat(self-compact): add createOnStatus handler that fires summarize on idle

Listens for session.status events with status.type === 'idle'. When the
session that just went idle has a pending entry in 'awaitingTurnEnd'
phase, promotes the phase to 'summarizing' synchronously (re-entrancy
safe), looks up the active model, then fires POST /summarize from the
now-idle session — the deadlock-free path.

The session.compacted handler (createOnCompacted, unchanged from v1)
continues to handle the next phase: pop pending entry and POST
/prompt_async with the resumption text."
```

---

## Task 5: Drop the timeout on callSummarizeHttp

**Files:**

- Modify: `assets/opencode/plugins/self-compact-impl.ts`
- Modify: `assets/opencode/plugins/test/self-compact.test.ts` (if there's a test asserting on the timeout)

**Step 1: Look for and remove the AbortSignal.timeout(10_000) on callSummarizeHttp**

In `self-compact-impl.ts`, the v1 `callSummarizeHttp` includes:

```ts
signal: AbortSignal.timeout(10_000),
```

Remove that line. Match pigeon's pattern (no client-side timeout). Leave the timeout on `callPromptAsyncHttp` — that endpoint genuinely IS fast and a 10s timeout there is reasonable defense.

**Step 2: Adjust any test that asserted on the signal**

Search the test file for `AbortSignal` or `signal` references in summarize-related tests. If any assert that the call was made with a signal, update to assert `signal: undefined` (or just remove the assertion if it was incidental).

**Step 3: Run all tests**

Run: `npm test -- --run`

Expected: All tests pass.

**Step 4: Commit**

```bash
git add assets/opencode/plugins/self-compact-impl.ts assets/opencode/plugins/test/self-compact.test.ts
git commit --no-gpg-sign -m "fix(self-compact): drop client-side timeout on summarize HTTP call

POST /summarize is a long-running synchronous endpoint (server-side
runs the prompt loop to completion — multiple minutes for long
sessions). The 10-second AbortSignal.timeout was inherited from v1
where it was masking the real deadlock; now that the deadlock is
fixed, the timeout would just spuriously cancel legitimate long
summarizations. Match pigeon's no-timeout pattern.

Keep the 10s timeout on callPromptAsyncHttp — that endpoint really
is fast (DB write + bus publish, no LLM round-trip)."
```

---

## Task 6: Wire both event handlers in self-compact.ts entry

**Files:**

- Modify: `assets/opencode/plugins/self-compact.ts`

**Step 1: Update imports**

Add `createOnStatus` to the imports from `./self-compact-impl`.

**Step 2: Refactor the plugin's `event` registration**

The plugin SDK accepts a single `event?: (input: { event: Event }) => Promise<void>` hook per plugin (per `~/projects/opencode/packages/plugin/src/index.ts:149`). We need to dispatch internally.

Replace the plugin body so both handlers run for every event (each has its own filtering):

```ts
const plugin: Plugin = async (ctx) => {
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch = sdkClientConfig?.fetch ?? globalThis.fetch
  const callCtx: CallContext = { fetch: internalFetch, serverUrl: ctx.serverUrl }
  const pending = new Map<string, PendingResume>()

  const toolImpl = createSelfCompactTool({ pending })

  const onStatus = createOnStatus({
    pending,
    callSummarize: (input) => callSummarizeHttp(callCtx, input),
    findActiveModel: ({ sessionID }) =>
      findActiveModel({ fetch: internalFetch, serverUrl: ctx.serverUrl, sessionID }),
  })

  const onCompacted = createOnCompacted({
    pending,
    callPromptAsync: (input) => callPromptAsyncHttp(callCtx, input),
  })

  return {
    tool: {
      self_compact_and_resume: tool({
        description:
          "Compact the current session and queue a resumption prompt that will be processed " +
          "as the first user message of the post-compaction turn. The tool returns immediately; " +
          "compaction runs after this turn closes (you don't need to wait or follow up). Use as " +
          "the final step of the preparing-for-compaction skill, after persisting durable context.",
        args: {
          prompt: tool.schema
            .string()
            .describe("The resumption prompt to send after compaction completes."),
        },
        async execute(args, toolCtx) {
          return toolImpl.execute(args, { sessionID: toolCtx.sessionID })
        },
      }),
    },
    event: async (input) => {
      // Both handlers filter internally; safe to call both for every event.
      await onStatus(input)
      await onCompacted(input)
    },
  }
}
```

**Step 3: Run tests**

Run: `npm test -- --run`

Expected: All tests still pass. (No tests target `self-compact.ts` directly — it's exercised by the impl tests + manual smoke.)

**Step 4: Apply home-manager and verify the plugin still loads**

Run: `home-manager switch --flake .#cloudbox`
Then start a fresh opencode session and check the log:

```bash
ls -lt ~/.local/share/opencode/log/ | head -3
# Pick the newest log
grep "loading plugin" ~/.local/share/opencode/log/<newest>.log | grep self-compact
```

Expected: plugin loads. NO errors about missing exports or zod resolution.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/self-compact.ts
git commit --no-gpg-sign -m "feat(self-compact): wire both onStatus and onCompacted handlers

Plugin's event hook now dispatches to both handlers (each filters
internally on event.type). Updates the tool description to set the
correct expectation for the agent: tool returns instantly, compaction
runs after the turn closes."
```

---

## Task 7: Update the skill to set the correct expectation

**Files:**

- Modify: `assets/opencode/skills/preparing-for-compaction/SKILL.md`

**Step 1: Update the section that describes the tool's behavior**

Find the section describing how to call `self_compact_and_resume` (probably step 4 of the skill's process). Adjust the language so the agent knows:

- The tool returns INSTANTLY with a "queued" message.
- Compaction begins after THIS turn closes (i.e., after the agent finishes any follow-up actions and returns control).
- The agent should NOT wait for compaction to complete before ending the turn — that defeats the design.
- The TUI will visibly stream the compaction summary once it begins.
- The resumption prompt arrives as the next user message.

Keep it concise — 3-5 bullets. Don't overwrite the existing structural content (the "what to persist" guidance, etc.).

**Step 2: Apply skills via home-manager (skills are deployed by `opencode-skills.nix`)**

Run: `home-manager switch --flake .#cloudbox`

Verify the skill is updated:
```bash
diff <(cat ~/.config/opencode/skills/preparing-for-compaction/SKILL.md) \
     <(cat assets/opencode/skills/preparing-for-compaction/SKILL.md)
```

Expected: no diff (or a `realpath`-style symlink-content equivalence).

**Step 3: Commit**

```bash
git add assets/opencode/skills/preparing-for-compaction/SKILL.md
git commit --no-gpg-sign -m "docs(skill): update preparing-for-compaction for v2 self_compact behavior

The v2 tool returns instantly and queues compaction to run after the
turn closes. Agents calling the tool should NOT wait for compaction
to complete — they should let the turn end. The TUI will stream the
compaction summary visibly once it begins."
```

---

## Task 8: Smoke test on this real session

**Files:** none (live testing)

**Step 1: Verify state is clean**

```bash
git status
```

Expected: clean tree, all v2 commits present.

**Step 2: Push so the changes are durable before testing**

```bash
git pull --rebase
git push
git status  # MUST show "up to date with origin/main"
```

**Step 3: Plan a low-cost real test**

In a real opencode session, accumulate a small amount of context (a short conversation). Then ask the agent to invoke `preparing-for-compaction`. Watch:

1. Tool returns instantly with the "queued" message.
2. Agent ends its turn cleanly.
3. The TUI shows the compaction summary streaming (visible token-by-token).
4. After compaction completes, the resumption prompt arrives as the next user message.
5. New turn proceeds normally.

If any of those don't happen, capture the log timestamp and STOP — do not blindly retry. Re-run RCA.

**Step 4: Document the result**

If smoke test passes:

- Update `docs/plans/2026-04-20-self-compact-plugin-design.md` — change status header to "Implemented v2 2026-04-21" (preserve the v1 status info elsewhere).
- Optionally remove the RESUMPTION CONTEXT section from this v2 plan (it served its purpose).

If smoke test fails:

- Capture the log line range covering the test.
- Document what happened where in the addendum's v2 risks section.
- File a beads task with the captured evidence.
- Do NOT push another fix attempt without RCA.

**Step 5: Commit**

```bash
git add docs/plans/2026-04-20-self-compact-plugin-design.md docs/plans/2026-04-21-self-compact-idle-trigger-plan.md
git commit --no-gpg-sign -m "docs(self-compact): mark v2 implemented after successful smoke test

[Brief description of what the smoke test confirmed.]"
git pull --rebase
git push
```

---

## Notes / Open Questions

- **The v1 plan file (`2026-04-20-self-compact-plugin-plan.md`) is now historical.** Its Tasks 0-12 captured what was built; Tasks 13-14 are superseded. Don't delete it — the iteration history is valuable. After v2 ships, optionally add a one-line "SUPERSEDED — see 2026-04-21" header.
- **The deferred ChatGPT-recommended refactor** (config-dir `package.json` + real-file deployment to remove the `mkOutOfStoreSymlink` working-tree coupling) is still a separate piece of work. Not in scope for this plan.
- **Pigeon integration** remains post-MVP. The v2 architecture is just as friendly to it as v1 was; the daemon would still call `POST /summarize` directly without going through the plugin tool.
