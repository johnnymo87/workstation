# Self-Compact Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

---

## RESUMPTION CONTEXT (compaction handoff, 2026-04-21)

**This section is durable context for the post-compaction self.** Read
this first; the plan body below is the canonical task reference but this
section is the moment-in-time state.

### What just happened (THIS compaction is itself the smoke test)

You are reading this immediately after `self_compact_and_resume` was
invoked for the FIRST TIME on this session. The pre-compaction self
called the tool with this very resumption prompt as input. The fact that
you are running, with this message as your first user input, is the
smoke test working end-to-end.

**Your first job: confirm the smoke test passed.** Things to verify:

1. You received this resumption prompt as a fresh user message (look up
   in the conversation: did the auto-compaction summary appear, then
   this prompt as the first new user turn?).
2. You have access to the same tool set, including `self_compact_and_resume`
   itself — `bash`, `read`, `edit`, `write`, `task`, etc. should all be
   present.
3. Working tree is clean and on `main` with 9 unpushed commits.
4. The conversation should feel "fresh" — the auto-summary replaces the
   pre-compaction transcript with a synthesized recap.

If any of those don't hold, the smoke test had a problem; report what
you observe to the user and we'll debug.

### Where the work stands (Tasks 0-12 done, only Task 14 remains)

- **Done:** Tasks 0-12. Plugin coded, tested (18/18), nix-registered,
  skill rewritten, deployed. Plus three post-Task-12 fixes the original
  plan didn't anticipate (see "Iterations" below).
- **In flight:** Task 13 (smoke test) — that's literally what is
  happening right now.
- **Remaining:** Task 14 — push the 9 unpushed commits AND mark the
  design doc implemented. ONLY do this after the user confirms the
  smoke test passed (the user is the human-in-the-loop here).
- **Working dir:** `/home/dev/projects/workstation`, branch `main`,
  9 commits ahead of `origin/main`.

### Three post-Task-12 iterations the plan body doesn't capture

After the original Task 12 home-manager apply, three more fixes were
needed before the plugin actually worked. Commits on `main`:

1. **`15509c5 fix(self-compact): deploy via mkOutOfStoreSymlink so Bun can resolve runtime deps`**
   — The plugin imports `tool` from `@opencode-ai/plugin` at runtime
   (which transitively pulls zod). When deployed as a plain symlink into
   the nix store, Bun's import resolver walks up from the resolved
   real-path looking for `node_modules/` and finds none. Fix: use
   `mkOutOfStoreSymlink` (matching pigeon's pattern) so Bun resolves
   from the working-tree path where `node_modules/` is co-located.
   ChatGPT consulted on this; their recommended LONG-term refactor is a
   config-dir `package.json` + real-file approach (see
   `/tmp/answer-01.md` if it survives, or recreate the question).
   Recorded as deferred follow-up in the design doc next time it's
   touched.

2. **`92fcb88 fix(self-compact): split entry from impl so opencode loader sees only default export`**
   — opencode's plugin loader iterates `Object.entries(mod)` and calls
   EVERY exported function as a plugin factory (see
   `/home/dev/projects/opencode/packages/opencode/src/plugin/index.ts:81-87`).
   Our six named test-helper exports were getting called with
   `PluginInput` and throwing on `input.sessionID`. Fix: moved helpers
   to `assets/opencode/plugins/self-compact-impl.ts`; main entry now
   only exports `default`. Pigeon does the same. Tests updated to
   import from `-impl`.

3. **Branch consolidation:** the user's `feat/oc-cost` branch (7
   unrelated commits) was rebased onto `main`'s self-compact fixes,
   then ff-merged into `main`, then deleted. History is now linear,
   single branch. The user explicitly chose this consolidation.

### Critical environment quirks (still apply)

- **gpg-agent is unresponsive in this shell.** Every commit MUST use
  `--no-gpg-sign`. Without the flag commits fail.
- **No `sleep` in bash.** Hangs. Use bounded loops, `timeout`, or
  direct condition checks. See `assets/opencode/AGENTS.md`.
- **Use bash tool's `workdir` parameter**, not `cd /foo && cmd`.
- **Host is cloudbox**, not devbox. The home-manager target is
  `.#cloudbox`, not `.#dev`. (The original resumption brief said
  `.#dev`; that was wrong, the assertPlatform script caught it.)

### What "smoke test passed" means → Task 14 next steps

If the user confirms the smoke test passed:

1. Push the 9 unpushed commits: `git push` (after `git pull --rebase`
   per session-close protocol; should be a fast-forward).
2. Update `docs/plans/2026-04-20-self-compact-plugin-design.md` —
   change the status header to mark "Implemented 2026-04-21". Commit
   that with `--no-gpg-sign` and push.
3. Optionally: clean up this RESUMPTION CONTEXT section from the plan
   file (it served its purpose).
4. Optionally: file a follow-up issue or design-doc note for the
   ChatGPT-recommended refactor (config-dir `package.json` +
   real-file deployment) — this would untangle the working-tree
   coupling that mkOutOfStoreSymlink introduces.

### Files

- `assets/opencode/plugins/self-compact.ts` — slim entry, only `default` export
- `assets/opencode/plugins/self-compact-impl.ts` — all helpers + tests' targets
- `assets/opencode/plugins/test/self-compact.test.ts` — 18 vitest tests
- `users/dev/opencode-config.nix` — registration via mkOutOfStoreSymlink (lines 116-122)
- `assets/opencode/skills/preparing-for-compaction/SKILL.md` — the updated skill (Task 11)
- `docs/plans/2026-04-20-self-compact-plugin-design.md` — the why
- `docs/plans/2026-04-20-self-compact-plugin-plan.md` — this file

---

**Goal:** Ship an opencode plugin that lets the agent compact its own session and queue a resumption prompt as the first post-compaction user message, plus update the `preparing-for-compaction` skill to use it.

**Architecture:** Single TypeScript plugin file at `assets/opencode/plugins/self-compact.ts`, registered via home-manager. Tool stashes the resumption prompt + triggers `summarize`; plugin event handler watches `session.compacted` and enqueues via `prompt_async`. Uses pigeon-verified `internalFetch` pattern (capture `ctx.client.config.fetch`, raw `Request` against `ctx.serverUrl`) to bypass unreliable SDK wrappers. Tests via vitest co-located with the plugin in a tiny `assets/opencode/plugins/test/` setup.

**Tech Stack:** TypeScript, `@opencode-ai/plugin`, vitest, home-manager nix, opencode HTTP API (`/session/:id/summarize`, `/session/:id/prompt_async`, `/session/:id/message`).

**Design doc:** `docs/plans/2026-04-20-self-compact-plugin-design.md`

---

## Task 0: Resolve remaining shape unknowns

This is a 5-minute reading task before writing any code. Several types/shapes are still uncertain; resolving them up front prevents rework.

**Files:**
- Read: `~/projects/opencode/packages/plugin/src/index.ts` (Plugin, Hooks, Event types)
- Read: `~/projects/opencode/packages/sdk/js/src/v2/gen/types.gen.ts` (event payload shapes)
- Read: `~/projects/pigeon/packages/opencode-plugin/src/index.ts:1-30` (how to access `ctx.client.config.fetch`)

**Step 1: Confirm Event discriminator shape**

Open `~/projects/opencode/packages/plugin/src/index.ts`, find the `Event` import and trace its definition. Determine whether the event union is shaped as:
- `{ type: "session.compacted", properties: { sessionID } }` (flat), or
- `{ type: "session.compacted", payload: { sessionID } }`, or
- something else

Also confirm the property name is `sessionID` (camelCase) or `sessionId`.

**Step 2: Confirm `ctx.client.config.fetch` access**

In `~/projects/pigeon/packages/opencode-plugin/src/index.ts`, find the `internalFetch` line (line ~22). Verify the path is `(ctx.client as any).config.fetch` (or whatever it actually is) and confirm the cast pattern.

**Step 3: Confirm `ctx.serverUrl` is a `URL` (not a `string`)**

In `~/projects/opencode/packages/plugin/src/index.ts`, find `PluginInput`. Confirm `serverUrl: URL`.

**Step 4: Note findings in scratch**

Write a short comment block at the top of (a draft of) `assets/opencode/plugins/self-compact.ts` documenting each finding, e.g.:

```ts
// Verified shapes (Task 0 of plan):
// - Event union: { type: "session.compacted", properties: { sessionID: string } }
//   (sdk types.gen.ts:681-686; publisher compaction.ts:21-28,292)
// - internalFetch via pigeon's pattern (NOT ctx.client.config.fetch — that path doesn't exist):
//     const internalFetch =
//       (ctx.client as any)._client?.getConfig?.()?.fetch ?? globalThis.fetch
//   (pigeon/.../opencode-plugin/src/index.ts:21-22)
// - ctx.serverUrl is a URL instance (plugin/src/index.ts:31);
//   use directly: new URL(path, ctx.serverUrl)
```

**Step 5: No commit yet** — these findings inform the next task's code.

---

## Task 1: Set up vitest harness in `assets/opencode/plugins/`

**Files:**
- Create: `assets/opencode/plugins/package.json`
- Create: `assets/opencode/plugins/tsconfig.json`
- Create: `assets/opencode/plugins/vitest.config.ts`
- Modify: `assets/opencode/plugins/.gitignore` (create if absent; add `node_modules/`)

Goal: be able to run `cd assets/opencode/plugins && npm install && npm test` and have vitest exit cleanly with "no tests found" — proving the harness is wired.

**Step 1: Inspect pigeon's plugin test setup as reference**

Read these for patterns to copy:
- `~/projects/pigeon/packages/opencode-plugin/package.json`
- `~/projects/pigeon/packages/opencode-plugin/tsconfig.json` (if exists)
- `~/projects/pigeon/vitest.workspace.ts` and `~/projects/pigeon/packages/opencode-plugin/vitest.config.ts` (if exists)

The goal is matching pigeon's test conventions, not reinventing.

**Step 2: Write `package.json`**

```json
{
  "name": "workstation-opencode-plugins",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "@opencode-ai/plugin": "<version pigeon uses>",
    "typescript": "<version pigeon uses>",
    "vitest": "<version pigeon uses>"
  }
}
```

Pin versions to match pigeon's. If pigeon uses workspace ranges, copy specific versions that pigeon is currently resolving.

**Step 3: Write `tsconfig.json`**

Minimal config — strict mode, `target: "ES2022"`, `module: "ESNext"`, `moduleResolution: "bundler"`, `lib: ["ES2022", "DOM"]` (for `fetch`/`URL`/`AbortSignal`).

**Step 4: Write `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config"
export default defineConfig({
  test: {
    include: ["**/*.test.ts"],
    environment: "node",
  },
})
```

**Step 5: Write `.gitignore`**

```
node_modules/
```

**Step 6: Verify the harness**

```bash
cd assets/opencode/plugins
npm install
npm test
```

Expected: vitest runs, finds no tests, exits 0 (or with "no test files found" message). If it errors, debug before proceeding.

**Step 7: Commit**

```bash
git add assets/opencode/plugins/package.json \
        assets/opencode/plugins/tsconfig.json \
        assets/opencode/plugins/vitest.config.ts \
        assets/opencode/plugins/.gitignore
git commit -m "chore(opencode-plugins): add vitest harness for in-tree plugin tests"
```

Do NOT commit `node_modules/` or `package-lock.json` yet — decide in Task 2 whether to commit a lockfile (pigeon's pattern guides this).

---

## Task 2: Decide on lockfile policy and apply

**Files:**
- Possibly: `assets/opencode/plugins/package-lock.json`

**Step 1: Check pigeon's pattern**

```bash
ls ~/projects/pigeon/packages/opencode-plugin/package-lock.json 2>/dev/null && echo "pigeon uses lockfile" || echo "pigeon doesn't lock at package level"
ls ~/projects/pigeon/package-lock.json
```

If pigeon has a single root lockfile and no per-package lock, we should similarly skip the per-plugin lockfile (since the plugin will run via opencode loading the .ts file directly — npm install is only for tests).

**Step 2: Apply decision**

If lockfile to commit: `git add assets/opencode/plugins/package-lock.json` and amend the previous commit.

If not: ensure `package-lock.json` is in `.gitignore`.

**Step 3: Commit if needed (or amend Task 1 commit)**

---

## Task 3: Write the first failing test (model discovery)

**Files:**
- Create: `assets/opencode/plugins/test/self-compact.test.ts`
- (Plugin file does not exist yet — that's intentional)

**Step 1: Write the test**

```ts
import { describe, it, expect, vi } from "vitest"
import { findActiveModel } from "../self-compact"  // does not exist yet

describe("findActiveModel", () => {
  it("returns the model from the most recent user message that has model info", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          { info: { role: "user", model: { providerID: "anthropic", modelID: "claude-old" } } },
          { info: { role: "assistant" } },
          { info: { role: "user", model: { providerID: "anthropic", modelID: "claude-new" } } },
          { info: { role: "assistant" } },
        ]),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    )
    const serverUrl = new URL("http://localhost:4096")
    const result = await findActiveModel({ fetch: mockFetch, serverUrl, sessionID: "s1" })
    expect(result).toEqual({ providerID: "anthropic", modelID: "claude-new" })
    expect(mockFetch).toHaveBeenCalledOnce()
    const req = mockFetch.mock.calls[0][0] as Request
    expect(req.url).toBe("http://localhost:4096/session/s1/message")
    expect(req.method).toBe("GET")
  })

  it("returns null when no user message has model info", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([{ info: { role: "user" } }]), { status: 200 }),
    )
    const result = await findActiveModel({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the fetch fails", async () => {
    const mockFetch = vi.fn().mockResolvedValue(new Response("err", { status: 500 }))
    const result = await findActiveModel({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the fetch itself throws (network error)", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("network down"))
    const result = await findActiveModel({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the response body is not valid JSON", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response("not json at all", { status: 200 }),
    )
    const result = await findActiveModel({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the parsed JSON is not an array", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ unexpected: "shape" }), { status: 200 }),
    )
    const result = await findActiveModel({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })
})
```

> **Note:** Three additional tests (network throw, invalid JSON, non-array JSON) added during code review to enforce the 'never throws' invariant. The original plan version had only the first 3 tests.

This shapes the API: `findActiveModel` is exported, takes `{ fetch, serverUrl, sessionID }`, returns `{ providerID, modelID } | null`. Pure function, no opencode dependency, easy to test.

**Step 2: Run test to verify it fails**

```bash
cd assets/opencode/plugins && npm test
```

Expected: FAIL — `Cannot find module '../self-compact'`.

**Step 3: Commit failing tests** (red commit)

```bash
git add assets/opencode/plugins/test/self-compact.test.ts
git commit -m "test(self-compact): add failing tests for findActiveModel"
```

---

## Task 4: Implement minimal `findActiveModel` to make Task 3 tests pass

**Files:**
- Create: `assets/opencode/plugins/self-compact.ts`

**Step 1: Write minimal exported function**

```ts
export async function findActiveModel(input: {
  fetch: typeof fetch
  serverUrl: URL
  sessionID: string
}): Promise<{ providerID: string; modelID: string } | null> {
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/message`, input.serverUrl)
  let messages: Array<{
    info: { role: string; model?: { providerID?: string; modelID?: string } }
  }>
  try {
    const res = await input.fetch(new Request(url.toString(), { method: "GET" }))
    if (!res.ok) return null
    const parsed = await res.json()
    if (!Array.isArray(parsed)) return null
    messages = parsed
  } catch {
    return null
  }
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (
      m.info.role === "user" &&
      m.info.model?.providerID &&
      m.info.model?.modelID
    ) {
      return { providerID: m.info.model.providerID, modelID: m.info.model.modelID }
    }
  }
  return null
}
```

> **Note:** This implementation hardens against `res.json()` throwing and a non-array JSON payload — refinements added during code review of the original Task 4 implementation. The original plan version had a narrower try/catch.

**Step 2: Run tests to verify they pass**

```bash
cd assets/opencode/plugins && npm test
```

Expected: PASS, 3 tests.

**Step 3: Commit**

```bash
git add assets/opencode/plugins/self-compact.ts
git commit -m "feat(self-compact): implement findActiveModel"
```

---

## Task 5: Write failing tests for the tool (`self_compact_and_resume`) execute logic

**Files:**
- Modify: `assets/opencode/plugins/test/self-compact.test.ts`

**Step 1: Add tests**

Test the tool's `execute` function by exporting a factory like `createTool({ pending, callSummarize, findActiveModel })`. This makes the tool's collaborators injectable for testing.

```ts
describe("self_compact_and_resume tool", () => {
  it("stashes the prompt, looks up model, and calls summarize", async () => {
    const pending = new Map<string, { prompt: string; createdAt: number }>()
    const callSummarize = vi.fn().mockResolvedValue(undefined)
    const findActiveModel = vi.fn().mockResolvedValue({
      providerID: "anthropic",
      modelID: "claude-3-5-sonnet",
    })
    const tool = createSelfCompactTool({ pending, callSummarize, findActiveModel })
    const result = await tool.execute({ prompt: "resume here" }, { sessionID: "s1" } as any)
    expect(findActiveModel).toHaveBeenCalledWith({ sessionID: "s1" })
    expect(callSummarize).toHaveBeenCalledWith({
      sessionID: "s1",
      providerID: "anthropic",
      modelID: "claude-3-5-sonnet",
    })
    expect(pending.get("s1")?.prompt).toBe("resume here")
    expect(typeof pending.get("s1")?.createdAt).toBe("number")
    expect(result).toMatch(/Compaction triggered/i)
  })

  it("returns an error message and does not stash when model lookup returns null", async () => {
    const pending = new Map()
    const callSummarize = vi.fn()
    const findActiveModel = vi.fn().mockResolvedValue(null)
    const tool = createSelfCompactTool({ pending, callSummarize, findActiveModel })
    const result = await tool.execute({ prompt: "resume" }, { sessionID: "s1" } as any)
    expect(callSummarize).not.toHaveBeenCalled()
    expect(pending.size).toBe(0)
    expect(result).toMatch(/Cannot determine active model/i)
  })

  it("removes stashed entry when summarize throws", async () => {
    const pending = new Map()
    const callSummarize = vi.fn().mockRejectedValue(new Error("boom"))
    const findActiveModel = vi.fn().mockResolvedValue({
      providerID: "p",
      modelID: "m",
    })
    const tool = createSelfCompactTool({ pending, callSummarize, findActiveModel })
    await expect(
      tool.execute({ prompt: "resume" }, { sessionID: "s1" } as any),
    ).rejects.toThrow("boom")
    expect(pending.size).toBe(0)
  })

  it("evicts stale entries (>30min) on each call", async () => {
    const pending = new Map<string, { prompt: string; createdAt: number }>()
    pending.set("old-session", { prompt: "stale", createdAt: Date.now() - 31 * 60 * 1000 })
    pending.set("recent-session", { prompt: "fresh", createdAt: Date.now() - 5 * 60 * 1000 })
    const tool = createSelfCompactTool({
      pending,
      callSummarize: vi.fn().mockResolvedValue(undefined),
      findActiveModel: vi.fn().mockResolvedValue({ providerID: "p", modelID: "m" }),
    })
    await tool.execute({ prompt: "new" }, { sessionID: "s1" } as any)
    expect(pending.has("old-session")).toBe(false)
    expect(pending.has("recent-session")).toBe(true)
    expect(pending.has("s1")).toBe(true)
  })
})
```

Note the test uses `createSelfCompactTool` (factory). We're shaping the design: the plugin's default export is a `Plugin` function, but it composes pure factories that we can test.

**Step 2: Run tests to verify they fail**

```bash
cd assets/opencode/plugins && npm test
```

Expected: FAIL — `createSelfCompactTool` undefined.

**Step 3: Commit failing tests**

```bash
git add assets/opencode/plugins/test/self-compact.test.ts
git commit -m "test(self-compact): add failing tests for tool execute"
```

---

## Task 6: Implement `createSelfCompactTool` to pass Task 5 tests

**Files:**
- Modify: `assets/opencode/plugins/self-compact.ts`

**Step 1: Add factory**

```ts
const STALE_MS = 30 * 60 * 1000

export interface PendingResume {
  prompt: string
  createdAt: number
}

export function createSelfCompactTool(deps: {
  pending: Map<string, PendingResume>
  callSummarize: (input: {
    sessionID: string
    providerID: string
    modelID: string
  }) => Promise<void>
  findActiveModel: (input: { sessionID: string }) => Promise<{ providerID: string; modelID: string } | null>
}) {
  return {
    async execute(args: { prompt: string }, toolCtx: { sessionID: string }): Promise<string> {
      // Evict stale entries
      const now = Date.now()
      for (const [sid, entry] of deps.pending) {
        if (now - entry.createdAt > STALE_MS) deps.pending.delete(sid)
      }

      const model = await deps.findActiveModel({ sessionID: toolCtx.sessionID })
      if (!model) {
        return "Cannot determine active model; aborting compaction. (No user message with model metadata found in this session.)"
      }

      deps.pending.set(toolCtx.sessionID, { prompt: args.prompt, createdAt: now })
      try {
        await deps.callSummarize({
          sessionID: toolCtx.sessionID,
          providerID: model.providerID,
          modelID: model.modelID,
        })
      } catch (err) {
        deps.pending.delete(toolCtx.sessionID)
        throw err
      }
      return "Compaction triggered. Your resumption prompt will be enqueued automatically once compaction completes."
    },
  }
}
```

> **Note (2nd revision):** After Task 9 wiring discovered the original loose shape was incompatible with the SDK's `Event` union, the parameter was first tightened to `{ event: Event }` (commit `29ce36e`) — but that turned out to treat a leaky abstraction as the source of truth (the SDK union is verifiably stale relative to the runtime; pigeon's plugin documents this; opencode's runtime invokes hooks with `input as any`). Final shape: a structural `PluginBusEvent = { type: string; properties?: unknown }` boundary type plus a named `isSessionCompacted` type predicate that imports only `EventSessionCompacted` (one variant, not the full union) from the SDK. Bonus: the tests' redundant `as any` casts on event payloads can come out. Research consult saved at `/tmp/research-opencode-plugin-event-type-answer.md`. Commit `3ec2823`.

**Step 2: Run tests to verify they pass**

```bash
cd assets/opencode/plugins && npm test
```

Expected: all 7 tests PASS.

**Step 3: Commit**

```bash
git add assets/opencode/plugins/self-compact.ts
git commit -m "feat(self-compact): implement createSelfCompactTool factory"
```

---

## Task 7: Write failing tests for the event handler

**Files:**
- Modify: `assets/opencode/plugins/test/self-compact.test.ts`

**Step 1: Add tests**

```ts
describe("createOnCompacted event handler", () => {
  it("ignores events that are not session.compacted", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "x", createdAt: Date.now() })
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({ event: { type: "session.idle", properties: { sessionID: "s1" } } })
    expect(callPromptAsync).not.toHaveBeenCalled()
    expect(pending.has("s1")).toBe(true)
  })

  it("ignores session.compacted for sessions without a pending prompt", async () => {
    const pending = new Map<string, PendingResume>()
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "unknown" } } })
    expect(callPromptAsync).not.toHaveBeenCalled()
  })

  it("calls callPromptAsync with the stashed prompt and clears state", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume now", createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({
      event: { type: "session.compacted", properties: { sessionID: "s1" } },
    })
    expect(callPromptAsync).toHaveBeenCalledWith({ sessionID: "s1", text: "resume now" })
    expect(pending.has("s1")).toBe(false)
  })

  it("clears state even if callPromptAsync throws", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockRejectedValue(new Error("boom"))
    const handler = createOnCompacted({ pending, callPromptAsync })
    await expect(
      handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } }),
    ).rejects.toThrow("boom")
    expect(pending.has("s1")).toBe(false)
  })
})
```

> **Note:** A fifth test ("removes the pending entry before awaiting callPromptAsync") added during code review to pin the no-double-delivery invariant. See `assets/opencode/plugins/test/self-compact.test.ts` for the canonical version.

**Step 2: Run tests to verify they fail**

Expected: FAIL — `createOnCompacted` undefined.

**Step 3: Commit**

```bash
git add assets/opencode/plugins/test/self-compact.test.ts
git commit -m "test(self-compact): add failing tests for event handler"
```

---

## Task 8: Implement `createOnCompacted` to pass Task 7 tests

**Files:**
- Modify: `assets/opencode/plugins/self-compact.ts`

**Step 1: Add factory**

```ts
/**
 * Structural supertype matching any event the plugin bus may deliver. The
 * runtime hands us arbitrary events (opencode's plugin host invokes hooks
 * with `input as any`); the SDK's `Event` discriminated union is a
 * convenience type that's known to lag behind the runtime (pigeon's plugin
 * documents this). Typing the boundary wider than the SDK union avoids
 * pretending the union is closed.
 */
type PluginBusEvent = {
  type: string
  properties?: unknown
}

/**
 * Narrows a `PluginBusEvent` to `EventSessionCompacted` if the type
 * discriminator and the `properties.sessionID` shape both match. Used at
 * the top of `createOnCompacted`'s handler so all the code below can rely
 * on `event.properties.sessionID: string` without further casting.
 */
function isSessionCompacted(event: PluginBusEvent): event is EventSessionCompacted {
  if (event.type !== "session.compacted") return false
  const props = event.properties
  return (
    !!props &&
    typeof props === "object" &&
    "sessionID" in props &&
    typeof (props as Record<string, unknown>).sessionID === "string"
  )
}

export function createOnCompacted(deps: {
  pending: Map<string, PendingResume>
  callPromptAsync: (input: { sessionID: string; text: string }) => Promise<void>
}) {
  return async ({ event }: { event: PluginBusEvent }) => {
    if (!isSessionCompacted(event)) return
    const { sessionID } = event.properties
    const entry = deps.pending.get(sessionID)
    if (!entry) return
    // Remove the entry synchronously BEFORE the await so a re-entrant
    // session.compacted event for the same session doesn't observe it
    // and double-deliver. If callPromptAsync throws, the entry is still
    // gone — matches MVP design (no automatic retry; user re-invokes the
    // skill if the prompt fails to deliver).
    deps.pending.delete(sessionID)
    await deps.callPromptAsync({ sessionID, text: entry.prompt })
  }
}
```

> **Note:** Synchronous pop (rather than try/finally cleanup) added during code review of the original Task 8 implementation. The original plan version had a race window where two near-simultaneous `session.compacted` events for the same sessionID could both observe the pending entry. The post-review shape eliminates the race AND removes the need for `try/finally`.

**Step 2: Run tests to verify they pass**

Expected: all 11 tests PASS.

**Step 3: Commit**

```bash
git add assets/opencode/plugins/self-compact.ts
git commit -m "feat(self-compact): implement createOnCompacted event handler"
```

---

## Task 9: Wire the plugin entry point (default export)

**Files:**
- Modify: `assets/opencode/plugins/self-compact.ts`

This task glues the factories together into a real `Plugin`. Less test coverage here because the wiring is mostly type-level; we'll smoke-test it in Task 13.

**Step 1: Add HTTP wrappers and plugin entry point**

```ts
import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin"
import type { EventSessionCompacted } from "@opencode-ai/sdk"

// (existing exports above remain)

export interface CallContext {
  fetch: typeof fetch
  serverUrl: URL
}

export async function callSummarizeHttp(
  ctx: CallContext,
  input: { sessionID: string; providerID: string; modelID: string },
): Promise<void> {
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/summarize`, ctx.serverUrl)
  const res = await ctx.fetch(
    new Request(url.toString(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        providerID: input.providerID,
        modelID: input.modelID,
        auto: false,
      }),
      signal: AbortSignal.timeout(10_000),
    }),
  )
  if (!res.ok) throw new Error(`summarize failed: ${res.status} ${await res.text()}`)
}

export async function callPromptAsyncHttp(
  ctx: CallContext,
  input: { sessionID: string; text: string },
): Promise<void> {
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/prompt_async`, ctx.serverUrl)
  const res = await ctx.fetch(
    new Request(url.toString(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        parts: [{ type: "text", text: input.text }],
        noReply: false,
      }),
      signal: AbortSignal.timeout(10_000),
    }),
  )
  if (!res.ok) throw new Error(`prompt_async failed: ${res.status} ${await res.text()}`)
}

const plugin: Plugin = async (ctx) => {
  // Verified path: pigeon's `_client.getConfig().fetch` — captures the in-process
  // Hono transport in TUI mode while bypassing unreliable generated SDK wrappers.
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch = sdkClientConfig?.fetch ?? globalThis.fetch
  const callCtx: CallContext = { fetch: internalFetch, serverUrl: ctx.serverUrl }
  const pending = new Map<string, PendingResume>()

  const toolImpl = createSelfCompactTool({
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
          "as the first user message of the post-compaction turn. Use this as the final step " +
          "of the preparing-for-compaction skill, after persisting durable context.",
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
    event: onCompacted,
  }
}

export default plugin
```

**Step 2: Add lightweight tests for HTTP wrappers**

Append to `test/self-compact.test.ts`:

```ts
describe("callSummarizeHttp", () => {
  it("POSTs to /session/:id/summarize with the right body", async () => {
    const fetchFn = vi.fn().mockResolvedValue(new Response(null, { status: 204 }))
    await callSummarizeHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", providerID: "p", modelID: "m" },
    )
    const req = fetchFn.mock.calls[0][0] as Request
    expect(req.url).toBe("http://localhost:4096/session/s1/summarize")
    expect(req.method).toBe("POST")
    const body = await req.json()
    expect(body).toEqual({ providerID: "p", modelID: "m", auto: false })
  })

  it("throws on non-2xx", async () => {
    const fetchFn = vi.fn().mockResolvedValue(new Response("nope", { status: 500 }))
    await expect(
      callSummarizeHttp(
        { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
        { sessionID: "s1", providerID: "p", modelID: "m" },
      ),
    ).rejects.toThrow(/500/)
  })
})

describe("callPromptAsyncHttp", () => {
  it("POSTs to /session/:id/prompt_async with the right body", async () => {
    const fetchFn = vi.fn().mockResolvedValue(new Response(null, { status: 204 }))
    await callPromptAsyncHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", text: "hello" },
    )
    const req = fetchFn.mock.calls[0][0] as Request
    expect(req.url).toBe("http://localhost:4096/session/s1/prompt_async")
    expect(req.method).toBe("POST")
    const body = await req.json()
    expect(body).toEqual({
      parts: [{ type: "text", text: "hello" }],
      noReply: false,
    })
  })
})
```

**Step 3: Run tests**

```bash
cd assets/opencode/plugins && npm test
```

Expected: 14 tests PASS.

**Step 4: Typecheck**

```bash
cd assets/opencode/plugins && npx tsc --noEmit
```

Expected: no errors.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/self-compact.ts assets/opencode/plugins/test/self-compact.test.ts
git commit -m "feat(self-compact): wire HTTP wrappers and Plugin entry point"
```

---

## Task 10: Register the plugin in home-manager

**Files:**
- Modify: `users/dev/opencode-config.nix`

**Step 1: Find the plugin registration block**

Open `users/dev/opencode-config.nix` and find the existing line (around line 109):

```nix
xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
```

**Step 2: Add the new line**

Add immediately after, in alphabetical order if convention prefers it:

```nix
xdg.configFile."opencode/plugins/self-compact.ts".source = "${assetsPath}/opencode/plugins/self-compact.ts";
```

**Step 3: Validate the nix expression**

```bash
cd ~/projects/workstation
nix flake check 2>&1 | head -30
```

Or simply do a dry-run rebuild:

```bash
nix run home-manager -- build --flake .#dev 2>&1 | tail -10
```

Expected: builds without nix evaluation errors. Discrepancies in the path or unused-vars warnings should be addressed.

**Step 4: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "feat(opencode): register self-compact plugin via home-manager"
```

---

## Task 11: Update the `preparing-for-compaction` skill

**Files:**
- Modify: `assets/opencode/skills/preparing-for-compaction/SKILL.md`

**Step 1: Read the existing skill**

```bash
cat assets/opencode/skills/preparing-for-compaction/SKILL.md
```

**Step 2: Update the skill to use the new tool**

Replace the existing "Process" / "Provide a resumption prompt" sections (or rework them) so that:
- Steps 1-3 (assess, persist, commit/push) remain unchanged.
- Step 4 (formerly "Provide a resumption prompt") is reframed: instead of presenting the prompt to the user, **draft the resumption prompt and call the `self_compact_and_resume` tool with it as the `prompt` argument**.
- Add a brief note: "If the `self_compact_and_resume` tool is not available (e.g., older opencode version, plugin disabled), fall back to printing the prompt for the user to paste after `/compact`."

The exact wording is judgment — preserve the skill's "Care about the continuity of the work" ethos. Adjust the example resumption prompt section to clarify it shows what to *pass to the tool*.

**Step 3: Verify the updated skill renders sensibly**

Just read it back and sanity-check.

**Step 4: Commit**

```bash
git add assets/opencode/skills/preparing-for-compaction/SKILL.md
git commit -m "docs(preparing-for-compaction): use self_compact_and_resume tool for automated handoff"
```

---

## Task 12: Apply the home-manager change locally

**Files:** none

**Step 1: Apply**

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#dev
```

Expected: completes without errors, `~/.config/opencode/plugins/self-compact.ts` exists and is a symlink into `${assetsPath}/opencode/plugins/self-compact.ts`.

```bash
ls -la ~/.config/opencode/plugins/self-compact.ts
```

Expected: symlink to the workstation source.

**Step 2: No commit** — this is a local apply, not a code change.

---

## Task 13: Smoke test in a real opencode TUI session

**Files:** none

This is a manual verification step. Document any findings inline.

**Step 1: Start a fresh opencode session in a throwaway directory**

```bash
mkdir -p /tmp/self-compact-smoke
cd /tmp/self-compact-smoke
opencode
```

**Step 2: Generate some context**

Have a brief conversation with the agent — anything that produces 5-10 messages so compaction has something to summarize.

**Step 3: Trigger self-compaction**

In the TUI, send: "Please call the `self_compact_and_resume` tool with prompt='Verify smoke test passed by listing your previous instructions.' and report what happens."

**Step 4: Observe**

- Did the tool call succeed?
- Did the TUI render the compaction process?
- Did the resumption prompt arrive as a fresh user message after compaction?
- Did the agent respond to it?

**Step 5: Capture findings**

If everything works, note success in the commit message of the next non-trivial change. If not, troubleshoot:
- Check `~/.config/opencode/plugins/self-compact.ts` is loaded (look at opencode startup logs).
- Add `console.log` statements to trace which path is hit.
- Check whether `session.compacted` event fires (instrument `event` handler with a log).

**Step 6: No commit unless changes are needed**

If smoke test reveals bugs, fix them in a new commit (e.g., `fix(self-compact): correct event property name after smoke test`).

---

## Task 14: Push and close the loop

**Files:** none

**Step 1: Verify clean state**

```bash
git status
git log --oneline origin/main..HEAD
```

**Step 2: Push**

```bash
git pull --rebase
git push
git status
```

Expected: "Your branch is up to date with 'origin/main'."

**Step 3: Verify push succeeded**

```bash
git log --oneline -8
```

The new commits should appear on origin.

**Step 4: Final note**

Update the design doc's status from "Approved, ready for implementation plan" to "Implemented YYYY-MM-DD" with a one-liner summarizing the smoke test outcome.

```bash
# Edit the status line in docs/plans/2026-04-20-self-compact-plugin-design.md
git add docs/plans/2026-04-20-self-compact-plugin-design.md
git commit -m "docs(self-compact): mark design doc implemented"
git push
```

---

## Done Criteria

- ✅ Plugin file exists, registered via home-manager, deployed at `~/.config/opencode/plugins/self-compact.ts`.
- ✅ All vitest tests pass.
- ✅ Skill `preparing-for-compaction` instructs the agent to call the tool.
- ✅ Smoke test in a real TUI session: agent calls tool → compaction happens → resumption prompt processed as fresh turn.
- ✅ All commits pushed to origin/main.

## What's Explicitly NOT in This Plan (Deferred)

- Pigeon integration (Telegram-driven `/compact-then <prompt>` or equivalent).
- Persisting `pending` state to disk for crash recovery.
- Idle-gating the `prompt_async` call (decision deferred; revisit if smoke test shows ordering issues).
- Multi-session pending state (today the plugin handles one pending entry per session, but does not coordinate across multiple sessions in the same opencode process — should be fine).
- Updating the user-level instruction file `~/.config/opencode/AGENTS.md` to mention the new tool. (The skill is the right surface; the AGENTS.md mention may emerge organically if useful.)

## Plan Complete

Plan saved to `docs/plans/2026-04-20-self-compact-plugin-plan.md`.

**Two execution options:**

1. **Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration.

2. **Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints.

The user can decide which approach they want when ready to start implementation.
