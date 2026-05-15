# Context-Usage Nudge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Inject a `Context usage: X / Y tokens (Z%) as of last turn.` line into the system prompt of every opencode turn (after turn 1), so the model has the same situational awareness about its working memory that a human collaborator would. Pair with a short AGENTS.md section describing the practice — virtue-ethics framing, not a rule.

**Architecture:** New plugin `assets/opencode/plugins/context-usage.ts` that hooks `experimental.chat.system.transform`. The hook gets `{ sessionID, model }`, fetches the latest assistant message via `GET /session/{sessionID}/message` using the in-process Hono fetch captured from `ctx.client` (same trick as `self-compact.ts`), reads its `tokens` field, and pushes one formatted line onto `output.system`. Pure helper lives in `context-usage-impl.ts` so vitest can import it without triggering the plugin loader's "every export is a plugin factory" behavior. Deployed as raw `.ts` like `compaction-context.ts`, not bundled.

**Tech Stack:** TypeScript, `@opencode-ai/plugin`, vitest, Nix home-manager for deployment.

**Design doc:** `docs/plans/2026-05-15-context-usage-nudge-design.md` (committed in 68f2d9f).

---

## Pre-flight

**Required reading before starting:**

1. The design doc: `docs/plans/2026-05-15-context-usage-nudge-design.md`. Section "Failure modes" and "Code shape" are the contract for this implementation.
2. `assets/opencode/plugins/self-compact-impl.ts` — pattern we're mirroring. Note especially:
   - The `_client.getConfig().fetch` trick at `self-compact.ts:21-23` (TUI mode in-process fetch).
   - Why `-impl.ts` exists: `self-compact.ts:14-17` comment about the plugin loader iterating `Object.entries(mod)`.
   - The `findActiveModel` helper at `self-compact-impl.ts:3-32` — same HTTP path, same parse shape we'll reuse.
3. `assets/opencode/plugins/test/self-compact.test.ts:1-100` — mocking pattern for the fetch+Response shape we'll copy.
4. Skim `~/projects/opencode/packages/opencode/src/session/llm.ts:95-125` for the exact hook invocation and the 2-part rejoin at `:120-124` that we mustn't break (push *after* the existing first element).

**Verify the test runner works before writing any code:**

```bash
cd ~/projects/workstation/assets/opencode/plugins
bun install        # if node_modules absent
bun test
```

Expected: `self-compact.test.ts` passes (currently ~30 cases). If it doesn't, **stop and resolve that first** — we don't want to inherit a broken test setup.

---

## Task 1: Create `-impl.ts` with the helper and its first failing test

**Files:**
- Create: `assets/opencode/plugins/context-usage-impl.ts`
- Create: `assets/opencode/plugins/test/context-usage.test.ts`

**Step 1: Write the failing test for the happy path**

Create `assets/opencode/plugins/test/context-usage.test.ts`:

```typescript
import { describe, it, expect, vi } from "vitest"
import { fetchLatestAssistantUsage } from "../context-usage-impl"

describe("fetchLatestAssistantUsage", () => {
  it("returns tokens.total from the latest assistant message", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          { info: { role: "user" } },
          {
            info: {
              role: "assistant",
              tokens: {
                total: 187234,
                input: 0,
                output: 0,
                cache: { read: 0, write: 0 },
              },
            },
          },
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(187234)
    const req = mockFetch.mock.calls[0][0] as Request
    expect(req.url).toBe("http://localhost:4096/session/s1/message")
    expect(req.method).toBe("GET")
  })
})
```

**Step 2: Run the test, confirm it fails**

```bash
cd ~/projects/workstation/assets/opencode/plugins
bun test context-usage
```

Expected: FAIL — `Cannot find module '../context-usage-impl'`. This is the right kind of failure.

**Step 3: Create the minimal `-impl.ts`**

Create `assets/opencode/plugins/context-usage-impl.ts`:

```typescript
/**
 * Helper for the context-usage plugin: fetches the most recent assistant
 * message's accumulated token count.
 *
 * Lives in a separate file from the plugin entrypoint because opencode's
 * plugin loader iterates `Object.entries(mod)` and invokes every exported
 * function as a plugin factory. Test-only helpers must therefore not be
 * exported from `context-usage.ts`. (Same constraint as `self-compact.ts`;
 * see its header comment for the canonical statement.)
 */
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

  let parsed: unknown
  try {
    parsed = await res.json()
  } catch {
    return null
  }
  if (!Array.isArray(parsed)) return null

  for (let i = parsed.length - 1; i >= 0; i--) {
    const m = parsed[i] as { info?: { role?: string; tokens?: any } } | null
    if (!m || m.info?.role !== "assistant") continue
    const t = m.info?.tokens
    if (!t) continue
    // Match overflow.ts:24 and acp/agent.ts:114.
    const used =
      typeof t.total === "number"
        ? t.total
        : (t.input ?? 0) +
          (t.output ?? 0) +
          (t.cache?.read ?? 0) +
          (t.cache?.write ?? 0)
    if (used > 0) return used
  }
  return null
}
```

**Step 4: Run the test, confirm it passes**

```bash
bun test context-usage
```

Expected: PASS, 1 test.

**Step 5: Commit**

```bash
cd ~/projects/workstation
git add assets/opencode/plugins/context-usage-impl.ts \
        assets/opencode/plugins/test/context-usage.test.ts
git commit -m "feat(opencode-plugins): add fetchLatestAssistantUsage helper

First slice of the context-usage plugin: pure helper that fetches a
session's message list and returns the most recent assistant message's
accumulated token count. Lives in -impl.ts (not the future plugin
entrypoint) so vitest can import it without triggering the plugin
loader's 'every export is a plugin factory' behavior.

See docs/plans/2026-05-15-context-usage-nudge-design.md."
```

---

## Task 2: Round out helper test coverage (cases 2–8 from the design)

**Files:**
- Modify: `assets/opencode/plugins/test/context-usage.test.ts`

These tests should all pass against the implementation written in Task 1 — they're confirming the existing behavior across edge cases, not driving new code. If any of them fail, that's a bug in Task 1's implementation that we fix before moving on.

**Step 1: Add the cases**

Append inside the `describe("fetchLatestAssistantUsage", ...)` block:

```typescript
  it("falls back to summing input/output/cache when total is absent", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          {
            info: {
              role: "assistant",
              tokens: {
                input: 100_000,
                output: 5_000,
                cache: { read: 80_000, write: 2_000 },
              },
            },
          },
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(187_000)
  })

  it("walks past zero-token placeholder messages to find one with real numbers", async () => {
    const zeroTokens = { input: 0, output: 0, cache: { read: 0, write: 0 } }
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          { info: { role: "user" } },
          { info: { role: "assistant", tokens: { total: 50_000, ...zeroTokens } } },
          { info: { role: "user" } },
          { info: { role: "assistant", tokens: zeroTokens } }, // placeholder
        ]),
        { status: 200 },
      ),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBe(50_000)
  })

  it("returns null when there is no assistant message yet (turn 1)", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([{ info: { role: "user" } }]), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the message list is empty", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([]), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null on a non-OK HTTP response", async () => {
    const mockFetch = vi.fn().mockResolvedValue(new Response("err", { status: 500 }))
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when fetch itself throws (network error)", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("network down"))
    const result = await fetchLatestAssistantUsage({
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
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("returns null when the parsed body is not an array", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ unexpected: "shape" }), { status: 200 }),
    )
    const result = await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "s1",
    })
    expect(result).toBeNull()
  })

  it("URL-encodes the sessionID in the request path", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([]), { status: 200 }),
    )
    await fetchLatestAssistantUsage({
      fetch: mockFetch,
      serverUrl: new URL("http://localhost:4096"),
      sessionID: "ses/with slashes?",
    })
    const req = mockFetch.mock.calls[0][0] as Request
    expect(req.url).toBe(
      "http://localhost:4096/session/ses%2Fwith%20slashes%3F/message",
    )
  })
```

**Step 2: Run tests, confirm all 9 pass**

```bash
bun test context-usage
```

Expected: PASS, 9 tests in this file. If any fail, that's a real bug in `-impl.ts`; fix it and re-run.

**Step 3: Commit**

```bash
git add assets/opencode/plugins/test/context-usage.test.ts
git commit -m "test(opencode-plugins): cover fetchLatestAssistantUsage edge cases

Cases 2-8 from the design doc: fallback summation, walking past zero
placeholders, empty/turn-1 sessions, HTTP errors, fetch throws,
non-JSON bodies, non-array bodies, sessionID URL encoding."
```

---

## Task 3: Write the plugin entrypoint with its first failing test

**Files:**
- Create: `assets/opencode/plugins/context-usage.ts`
- Modify: `assets/opencode/plugins/test/context-usage.test.ts`

Now we wire the helper into the actual hook. The hook isn't trivially unit-testable (it's a closure inside a Plugin factory), so we'll test it by invoking the plugin factory with a stub `ctx` and then calling the returned hook directly. This mirrors the pattern in `self-compact.test.ts` for the `createOnStatus` / `createOnCompacted` factories — except we don't have separate factories here because the wiring is short, so we just exercise the default-exported factory.

**Step 1: Write the failing test**

Append to `assets/opencode/plugins/test/context-usage.test.ts`:

```typescript
import contextUsagePlugin from "../context-usage"

describe("context-usage plugin hook", () => {
  // Helper: build a ctx with a mocked _client.getConfig().fetch
  function makeCtx(mockFetch: typeof fetch) {
    return {
      client: {
        _client: {
          getConfig: () => ({ fetch: mockFetch }),
        },
      },
      project: {} as any,
      directory: "/tmp",
      worktree: "/tmp",
      experimental_workspace: { register: () => {} },
      serverUrl: new URL("http://localhost:4096"),
      $: {} as any,
    }
  }

  it("pushes a formatted usage line when last-turn tokens are available", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify([
          {
            info: {
              role: "assistant",
              tokens: {
                total: 187234,
                input: 0,
                output: 0,
                cache: { read: 0, write: 0 },
              },
            },
          },
        ]),
        { status: 200 },
      ),
    )
    const hooks = await contextUsagePlugin(makeCtx(mockFetch) as any)
    const hook = hooks["experimental.chat.system.transform"]
    expect(hook).toBeDefined()

    const output = { system: ["existing header"] }
    await hook!(
      {
        sessionID: "s1",
        model: { limit: { context: 1_000_000 } } as any,
      },
      output,
    )
    expect(output.system).toHaveLength(2)
    expect(output.system[0]).toBe("existing header") // header unchanged
    expect(output.system[1]).toMatch(
      /^Context usage: [\d,]+ \/ [\d,]+ tokens \([\d.]+%\) as of last turn\.$/,
    )
    expect(output.system[1]).toContain("187,234")
    expect(output.system[1]).toContain("1,000,000")
    expect(output.system[1]).toContain("18.7%")
  })
})
```

**Step 2: Run the test, confirm it fails**

```bash
bun test context-usage
```

Expected: FAIL — `Cannot find module '../context-usage'`.

**Step 3: Create the plugin entrypoint**

Create `assets/opencode/plugins/context-usage.ts`:

```typescript
import type { Plugin } from "@opencode-ai/plugin"
import { fetchLatestAssistantUsage } from "./context-usage-impl"

/**
 * Injects a single "Context usage: X / Y tokens (Z%) as of last turn." line
 * into the system prompt on every LLM call, so the model has situational
 * awareness about its own working memory.
 *
 * Silent on turn 1 (no prior assistant message to read tokens from), silent
 * on fetch errors (returns without modifying output.system), and silent
 * when the model has no usable `limit.context` (some local providers).
 *
 * The actual judgment about *when* to act on the number lives in the
 * "Managing Your Own Context" section of ~/.config/opencode/AGENTS.md.
 *
 * See docs/plans/2026-05-15-context-usage-nudge-design.md.
 */
const plugin: Plugin = async (ctx) => {
  // Same trick as self-compact.ts: capture the in-process Hono fetch when
  // the SDK client is running in TUI mode; fall back to the global fetch.
  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const internalFetch: typeof fetch =
    sdkClientConfig?.fetch ?? globalThis.fetch

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

      // Push AFTER the existing first element (the cacheable header) so
      // llm.ts:120-124's 2-part rejoin keeps the header byte-identical
      // across turns.
      output.system.push(line)
    },
  }
}

export default plugin
```

**Step 4: Run the test, confirm it passes**

```bash
bun test context-usage
```

Expected: PASS, 10 tests.

**Step 5: Commit**

```bash
git add assets/opencode/plugins/context-usage.ts \
        assets/opencode/plugins/test/context-usage.test.ts
git commit -m "feat(opencode-plugins): add context-usage hook

Injects 'Context usage: X / Y tokens (Z%) as of last turn.' line into
the system prompt every LLM call via experimental.chat.system.transform.
Reads the most recent assistant message's accumulated tokens; silent on
turn 1, silent on errors, silent when model has no context limit.

Pushes after output.system[0] so the cacheable header at llm.ts:120-124
stays byte-identical across turns.

See docs/plans/2026-05-15-context-usage-nudge-design.md."
```

---

## Task 4: Cover plugin-entrypoint silent-skip cases

**Files:**
- Modify: `assets/opencode/plugins/test/context-usage.test.ts`

The remaining design cases 10–12: silent when no context limit, silent when no prior assistant message, silent on fetch error.

**Step 1: Add the cases**

Append inside `describe("context-usage plugin hook", ...)`:

```typescript
  it("is silent when model.limit.context is missing", async () => {
    const mockFetch = vi.fn() // should never be called
    const hooks = await contextUsagePlugin(makeCtx(mockFetch) as any)
    const output = { system: ["existing header"] }
    await hooks["experimental.chat.system.transform"]!(
      { sessionID: "s1", model: {} as any },
      output,
    )
    expect(output.system).toEqual(["existing header"])
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it("is silent when model.limit.context is zero", async () => {
    const mockFetch = vi.fn()
    const hooks = await contextUsagePlugin(makeCtx(mockFetch) as any)
    const output = { system: ["existing header"] }
    await hooks["experimental.chat.system.transform"]!(
      { sessionID: "s1", model: { limit: { context: 0 } } as any },
      output,
    )
    expect(output.system).toEqual(["existing header"])
    expect(mockFetch).not.toHaveBeenCalled()
  })

  it("is silent when there is no prior assistant message (turn 1)", async () => {
    const mockFetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify([{ info: { role: "user" } }]), { status: 200 }),
    )
    const hooks = await contextUsagePlugin(makeCtx(mockFetch) as any)
    const output = { system: ["existing header"] }
    await hooks["experimental.chat.system.transform"]!(
      { sessionID: "s1", model: { limit: { context: 1_000_000 } } as any },
      output,
    )
    expect(output.system).toEqual(["existing header"])
  })

  it("is silent and does not throw when the fetch fails", async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error("boom"))
    const hooks = await contextUsagePlugin(makeCtx(mockFetch) as any)
    const output = { system: ["existing header"] }
    await expect(
      hooks["experimental.chat.system.transform"]!(
        { sessionID: "s1", model: { limit: { context: 1_000_000 } } as any },
        output,
      ),
    ).resolves.toBeUndefined()
    expect(output.system).toEqual(["existing header"])
  })

  it("falls back to globalThis.fetch when ctx.client has no _client", async () => {
    // Simulates a non-TUI client where the _client.getConfig trick is unavailable.
    // We can't easily mock globalThis.fetch in a focused way, so just assert that
    // the plugin doesn't throw when constructing the closure. The earlier silent-
    // error case already proves graceful failure at call time.
    const ctx = {
      client: {}, // no _client
      project: {} as any,
      directory: "/tmp",
      worktree: "/tmp",
      experimental_workspace: { register: () => {} },
      serverUrl: new URL("http://localhost:4096"),
      $: {} as any,
    }
    const hooks = await contextUsagePlugin(ctx as any)
    expect(hooks["experimental.chat.system.transform"]).toBeDefined()
  })
```

**Step 2: Run tests, confirm all pass**

```bash
bun test context-usage
```

Expected: PASS, 15 tests in this file. Also run the full suite to make sure we haven't broken anything else:

```bash
bun test
```

Expected: all suites pass (self-compact suite included).

**Step 3: Commit**

```bash
git add assets/opencode/plugins/test/context-usage.test.ts
git commit -m "test(opencode-plugins): cover context-usage hook silent-skip paths

Design cases 10-12 plus a constructor-time fallback case: silent when
model.limit.context is missing or zero, silent on turn 1, silent (no
throw) on fetch errors, and the factory still returns a hook when
ctx.client has no _client (non-TUI mode)."
```

---

## Task 5: Wire deployment in Nix

**Files:**
- Modify: `users/dev/opencode-config.nix` (around line 114-115, in the plugins block)

We're deploying as a raw `.ts` file (same as `compaction-context.ts`), not a Nix-built bundle. This is appropriate because the plugin has no dependencies beyond `@opencode-ai/plugin` (already present in the opencode runtime) and it lives in a single `.ts` plus one helper.

Important wrinkle: the plugin imports from `./context-usage-impl`. opencode's plugin loader supports `.ts` → `.ts` relative imports the same way as `compaction-context.ts` works standalone today. But we should deploy *both* files.

**Step 1: Add the deployment lines**

In `users/dev/opencode-config.nix`, find the block around line 114 (after `compaction-context.ts`):

```nix
    xdg.configFile."opencode/plugins/compaction-context.ts".source = "${assetsPath}/opencode/plugins/compaction-context.ts";
```

Add immediately after it:

```nix
    xdg.configFile."opencode/plugins/context-usage.ts".source = "${assetsPath}/opencode/plugins/context-usage.ts";
    xdg.configFile."opencode/plugins/context-usage-impl.ts".source = "${assetsPath}/opencode/plugins/context-usage-impl.ts";
```

**Step 2: Verify the Nix file still evaluates**

```bash
cd ~/projects/workstation
nix flake check 2>&1 | head -40
```

Or, more targeted — just try to evaluate the home-manager config without applying it:

```bash
nix eval ".#homeConfigurations.\"$(if [ "$OPENCODE_HOSTNAME" = devbox ]; then echo dev; else echo $OPENCODE_HOSTNAME; fi)\".activationPackage.drvPath" 2>&1 | tail -5
```

Expected: outputs a `/nix/store/...drv` path with no errors. If `flake check` produces unrelated warnings about other hosts, that's fine — we only care that ours evaluates.

**Step 3: Commit**

```bash
git add users/dev/opencode-config.nix
git commit -m "feat(home-manager): deploy context-usage opencode plugin

Adds context-usage.ts and context-usage-impl.ts to the deployed
plugins. Raw .ts deployment (no Nix bundle) matching the pattern
established by compaction-context.ts \u2014 the plugin has no
dependencies beyond @opencode-ai/plugin which opencode supplies at
runtime.

See docs/plans/2026-05-15-context-usage-nudge-design.md."
```

---

## Task 6: Add the AGENTS.md prose section

**Files:**
- Modify: `assets/opencode/AGENTS.md` (insert between "Bash Environment" and "Host Identification", roughly line 85-86)

This is the actual virtue-ethics piece. The plugin is just the wire; this prose is what shapes the agent's relationship to the number.

**Step 1: Add the section**

In `assets/opencode/AGENTS.md`, find line 84-86 (end of "Bash Environment", start of "Host Identification"):

```
- Use `timeout` to bound an operation.

## Host Identification
```

Insert between them:

````markdown

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
````

**Step 2: Sanity-check the file**

```bash
cd ~/projects/workstation
head -120 assets/opencode/AGENTS.md | tail -50
```

Visually confirm "Managing Your Own Context" sits between "Bash Environment" and "Host Identification" and the markdown is well-formed (no orphan code-fence, the section header has a blank line before and after it).

**Step 3: Commit**

```bash
git add assets/opencode/AGENTS.md
git commit -m "docs(opencode): describe the practice of noticing context usage

The context-usage plugin injects 'Context usage: X / Y tokens (Z%)' as
a system-prompt footer every turn. This section in AGENTS.md describes
the agent's relationship to that number: notice the region around 200k,
ask whether the current moment is a good one to compact, don't
mechanically threshold-check.

Virtue-ethics framing, not rules: 180k is fine, 220k is fine, the
region is real. The hard overflow is a safety net not a goal.

See docs/plans/2026-05-15-context-usage-nudge-design.md."
```

---

## Task 7: Apply home-manager and manually verify

**No new files. This is the end-to-end verification.**

**Step 1: Apply home-manager on whichever host you're on**

Use the per-host target from the workstation root `AGENTS.md`:

```bash
# Check which host:
echo $OPENCODE_HOSTNAME

# Then ONE of:
nix run home-manager -- switch --flake .#dev          # devbox
nix run home-manager -- switch --flake .#cloudbox     # cloudbox
sudo darwin-rebuild switch --flake .#Y0FMQX93RR-2     # macOS
nix run home-manager -- switch --flake .#livia        # crostini
```

Expected: switch completes successfully. After it does, verify the files landed:

```bash
ls -la ~/.config/opencode/plugins/context-usage*.ts
```

Both `context-usage.ts` and `context-usage-impl.ts` should be present as symlinks into the Nix store.

**Step 2: Start a fresh opencode session and verify turn-1 behavior**

In a fresh terminal (don't reuse the current opencode session, since plugins are loaded at session start):

```bash
opencode
```

Send a trivial first message like `hello`. The response should be the model's reply with NO `Context usage:` footer visible — turn 1 is silent by design. You won't see the system prompt directly, but you can verify by sending a second message that asks the model to tell you its context usage; if it answers with a number, the footer is being injected on turn 2+.

**Step 3: Verify turn-2 behavior**

After the first response, send: `What's your current context usage according to the system prompt?`

The model should respond with a number that roughly matches the model's `tokens.input + tokens.cache.read + tokens.cache.write` from the previous turn. Eyeball it for plausibility — first-turn responses on Anthropic models typically come in around 20-50k tokens of input (system prompt + tools + your message). A response like "Around 30,000 / 1,000,000 tokens (3%)" would be in the right ballpark.

**Step 4: Verify silent failure**

This is harder to test deliberately without breaking the server. Skip in normal cases; only relevant if turn-2 reveals a problem.

**Step 5: Commit nothing — this task is verification only**

If verification fails, the appropriate response is to fix forward (new task / new commit), not to commit anything from this step.

---

## Task 8: Push and close the loop

**Step 1: Verify everything is committed**

```bash
cd ~/projects/workstation
git status
```

Expected: `nothing to commit, working tree clean`. If there are unstaged changes from manual verification (e.g. debug logging), revert or commit them deliberately.

**Step 2: Pull, push, verify**

```bash
git pull --rebase
git push
git status  # MUST show "up to date with origin"
```

**Step 3: Note any follow-ups**

Worth filing as beads issues *if* manual verification surfaced anything:

- If the line formatting looked weird in practice (e.g. percentages with awkward precision), open a beads issue to tune the format.
- If the footer broke prompt caching unexpectedly, open a beads issue — that would warrant either moving the line into the `experimental.chat.messages.transform` layer instead, or computing it once and stashing.
- Nothing to file proactively — the existing plan covers the known design.

---

## Risks and known gaps

**Cache invalidation.** The injected line changes every turn (the token count changes). opencode's prompt builder at `llm.ts:120-124` joins `system[1..n]` into a single string that goes into the cache key. By always pushing onto `system` *after* the existing first element, we keep `system[0]` (the header) byte-identical, so the cache prefix up to that point is preserved. But the *suffix* (which includes our line) is not cached. This is probably fine — most caching benefit lives in the header + tools + AGENTS.md, not in the trailing variable text — but it's worth knowing if cache-hit metrics drop suddenly after deploy.

**Plugin loader strictness.** `self-compact.ts:14-17` documents that opencode iterates `Object.entries(mod)` and invokes every exported function as a plugin factory. We mitigate by exporting `fetchLatestAssistantUsage` only from `-impl.ts`. If opencode ever changes to also iterate transitively-imported modules, this would break — but that would also break `self-compact.ts`, so we'd find out fast.

**Non-TUI mode.** `ctx.client._client.getConfig().fetch` is specific to the TUI's in-process Hono transport. In headless / `opencode serve` mode, that path likely doesn't exist, and we fall back to `globalThis.fetch`. The fallback should work against the local server (assuming `serverUrl` is reachable from the plugin's process), but this code path isn't unit-tested end-to-end. The Task 7 manual verification will catch breakage on the dominant TUI path; headless verification can wait for a real headless session to hit it.

**Internal sessions** (title generator, summarizer). They'll also receive the footer. Cost is ~15 tokens per such call, run rate is low. DCP filters them; we YAGNI it for now. If it ever becomes a problem, add a sessionID-prefix filter in the hook.

---

## Definition of done

- [ ] All vitest cases pass: `cd assets/opencode/plugins && bun test`.
- [ ] `nix flake check` (or scoped eval) succeeds.
- [ ] Home-manager switch completes; both `.ts` files present at `~/.config/opencode/plugins/`.
- [ ] Fresh opencode session: turn 1 has no footer (verified indirectly by asking the model); turn 2 reports a plausible context-usage number.
- [ ] AGENTS.md section reads cleanly and sits in the right place.
- [ ] All changes committed and `git push` succeeds.
- [ ] No outstanding TODO / FIXME comments in the new code.
