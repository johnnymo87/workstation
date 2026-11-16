import { describe, it, expect, vi } from "vitest"
import { internals } from "../cache-miss-breaker"

const { createDetector, makeHooks, TRIP_STEPS, MIN_CONTEXT, DRAIN_STEPS } = internals

type Tokens = { input: number; output: number; reasoning: number; cache: { read: number; write: number } }
const miss = (input = 200_000): Tokens => ({ input, output: 100, reasoning: 0, cache: { read: 0, write: 0 } })
const hit = (read = 190_000): Tokens => ({ input: 10_000, output: 100, reasoning: 0, cache: { read, write: 0 } })

describe("createDetector", () => {
  it("trips on the Nth consecutive uncached step above the context floor", () => {
    const d = createDetector()
    for (let i = 1; i < TRIP_STEPS; i++) expect(d.step("s", miss())).toBe(false)
    expect(d.step("s", miss())).toBe(true)
  })

  it("trips only once per session", () => {
    const d = createDetector()
    for (let i = 0; i < TRIP_STEPS; i++) d.step("s", miss())
    expect(d.step("s", miss())).toBe(false)
  })

  it("resets the streak on any cache hit", () => {
    const d = createDetector()
    for (let i = 1; i < TRIP_STEPS; i++) d.step("s", miss())
    d.step("s", hit())
    for (let i = 1; i < TRIP_STEPS; i++) expect(d.step("s", miss())).toBe(false)
  })

  it("ignores steps below the context floor, without resetting the streak", () => {
    const d = createDetector()
    for (let i = 1; i < TRIP_STEPS; i++) d.step("s", miss())
    expect(d.step("s", miss(MIN_CONTEXT - 1))).toBe(false)
    expect(d.step("s", miss())).toBe(true)
  })

  it("counts cache writes as context", () => {
    const d = createDetector()
    const t: Tokens = { input: 10_000, output: 1, reasoning: 0, cache: { read: 0, write: MIN_CONTEXT } }
    for (let i = 1; i < TRIP_STEPS; i++) d.step("s", t)
    expect(d.step("s", t)).toBe(true)
  })

  it("keeps sessions apart", () => {
    const d = createDetector()
    for (let i = 1; i < TRIP_STEPS; i++) d.step("a", miss())
    expect(d.step("b", miss())).toBe(false)
    expect(d.step("a", miss())).toBe(true)
  })
})

function stepFinish(sessionID: string, tokens: Tokens, cost = 0.1, reason = "tool-calls") {
  return {
    event: {
      type: "message.part.updated",
      properties: { part: { id: "p", sessionID, messageID: "m", type: "step-finish", reason, cost, tokens } },
    },
  }
}
function assistant(sessionID: string, modelID = "gemini-3.8-flash") {
  return {
    event: {
      type: "message.updated",
      properties: { info: { id: "m", sessionID, role: "assistant", modelID, providerID: "google-vertex" } },
    },
  }
}

/** A hit from another session on the same model: the breaker only trips models that report cache. */
async function warm(hooks: any, modelID = "gemini-3.8-flash") {
  await hooks.event(assistant("warm", modelID))
  await hooks.event(stepFinish("warm", hit()))
}

function deps(parentID: string | null = "ses_parent") {
  return {
    abort: vi.fn(async () => {}),
    parentOf: vi.fn(async () => parentID ?? undefined),
    log: vi.fn(),
  }
}

async function feed(hooks: any, sessionID: string, n: number, tokens = miss()) {
  for (let i = 0; i < n; i++) await hooks.event(stepFinish(sessionID, tokens))
}

describe("makeHooks", () => {
  it("refuses a tripped Gemini subagent's tool calls, telling it to summarize", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("child"))
    await feed(hooks, "child", TRIP_STEPS - 1)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).resolves.toBeUndefined()
    await feed(hooks, "child", 1)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).rejects.toThrow(/cache-miss breaker[\s\S]*Reply now/)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "other" })).resolves.toBeUndefined()
    expect(d.abort).not.toHaveBeenCalled()
  })

  it("aborts a stopped child only if it keeps going for DRAIN_STEPS more steps", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("child"))
    await feed(hooks, "child", TRIP_STEPS)
    await feed(hooks, "child", DRAIN_STEPS - 1, hit())
    expect(d.abort).not.toHaveBeenCalled()
    await feed(hooks, "child", 1, hit())
    expect(d.abort).toHaveBeenCalledTimes(1)
    expect(d.abort).toHaveBeenCalledWith("child")
    await feed(hooks, "child", 3, hit())
    expect(d.abort).toHaveBeenCalledTimes(1)
  })

  it("leaves a top-level session alone", async () => {
    const d = deps(null)
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("top"))
    await feed(hooks, "top", TRIP_STEPS)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "top" })).resolves.toBeUndefined()
  })

  it("leaves non-Gemini models alone (Claude caching is explicit)", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await warm(hooks, "claude-opus-5-5@default")
    await hooks.event(assistant("child", "claude-opus-5-5@default"))
    await feed(hooks, "child", TRIP_STEPS)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).resolves.toBeUndefined()
  })

  it("does nothing for a session whose model it has not seen", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await feed(hooks, "child", TRIP_STEPS)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).resolves.toBeUndefined()
  })

  it("fails open when the parent lookup or abort throws", async () => {
    const d = deps()
    d.parentOf.mockRejectedValue(new Error("boom"))
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("child"))
    await expect(feed(hooks, "child", TRIP_STEPS + DRAIN_STEPS)).resolves.toBeUndefined()
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).resolves.toBeUndefined()
    expect(d.abort).not.toHaveBeenCalled()

    const d2 = deps()
    d2.abort.mockRejectedValue(new Error("boom"))
    const hooks2 = makeHooks(d2)
    await warm(hooks2)
    await hooks2.event(assistant("child"))
    await expect(feed(hooks2, "child", TRIP_STEPS + DRAIN_STEPS)).resolves.toBeUndefined()
    expect(d2.abort).toHaveBeenCalled()
  })

  it("rewrites the parent's Task result for a session it stopped", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("child"))
    await feed(hooks, "child", TRIP_STEPS)
    await hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" }).catch(() => {})
    const output = {
      title: "t",
      output: '<task id="child" state="completed">\n<task_result>\npartial\n</task_result>\n</task>',
      metadata: { sessionId: "child" },
    }
    await hooks["tool.execute.after"]({ tool: "task", args: { subagent_type: "implementer" } }, output)
    expect(output.output).toContain('state="error"')
    expect(output.output).toContain("cache-miss breaker")
    expect(output.output).toContain("partial")
    expect(output.output).toMatch(/dispatch it again once/i)
    expect(output.output).toMatch(/do NOT pass task_id/)
  })

  it("keeps a finished result when the trip came on the final step", async () => {
    const hooks = makeHooks(deps())
    await warm(hooks)
    await hooks.event(assistant("child"))
    await feed(hooks, "child", TRIP_STEPS)
    const output = {
      title: "t",
      output: '<task id="child" state="completed">\n<task_result>\nall done\n</task_result>\n</task>',
      metadata: { sessionId: "child" },
    }
    await hooks["tool.execute.after"]({ tool: "task", args: {} }, output)
    expect(output.output).toContain('state="completed"')
    expect(output.output).toContain("all done")
    expect(output.output).toContain("it finished anyway")
  })

  it("never trips a model that has not reported a cache hit in this process", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await hooks.event(assistant("child", "gemini-9-new"))
    await feed(hooks, "child", TRIP_STEPS * 2)
    await expect(hooks["tool.execute.before"]({ tool: "bash", sessionID: "child" })).resolves.toBeUndefined()
  })

  it("does not count the summary (text-only) step toward the abort", async () => {
    const d = deps()
    const hooks = makeHooks(d)
    await warm(hooks)
    await hooks.event(assistant("child"))
    await feed(hooks, "child", TRIP_STEPS)
    for (let i = 0; i < DRAIN_STEPS + 2; i++) await hooks.event(stepFinish("child", hit(), 0.1, "stop"))
    expect(d.abort).not.toHaveBeenCalled()
  })

  it("leaves other Task results alone", async () => {
    const hooks = makeHooks(deps())
    const before = '<task id="x" state="completed">\n<task_result>\nok\n</task_result>\n</task>'
    const output = { title: "t", output: before, metadata: { sessionId: "x" } }
    await hooks["tool.execute.after"]({ tool: "task", args: {} }, output)
    expect(output.output).toBe(before)
  })
})
