import { describe, it, expect, vi } from "vitest"
import plugin, { internals } from "../subagent-failure"

const { makeHooks, fallbackAgent } = internals

type Deps = Parameters<typeof makeHooks>[0]

function hooksWith(overrides: Partial<Deps> = {}) {
  const deps: Deps = {
    probe: vi.fn(overrides.probe ?? (async () => ({ code: 0, message: "astra UP" }))),
    lastMessage: vi.fn(overrides.lastMessage ?? (async () => undefined)),
  }
  return { deps, hooks: makeHooks(deps) }
}

const CHILD = "ses_child123"

function taskOutput(text: string, extra: Record<string, unknown> = {}) {
  return {
    title: "review",
    output: [`<task id="${CHILD}" state="completed">`, "<task_result>", text, "</task_result>", "</task>"].join("\n"),
    metadata: {
      parentSessionId: "ses_parent",
      sessionId: CHILD,
      model: { providerID: "openai", modelID: "gpt-6-astra" },
      ...extra,
    },
  }
}

function afterInput(agent: string) {
  return { tool: "task", sessionID: "ses_parent", callID: "call_1", args: { subagent_type: agent } }
}

function erroredAssistant(message: string, text?: string) {
  return {
    info: { role: "assistant", error: { name: "APIError", data: { message } } },
    parts: text === undefined ? [] : [{ type: "text", text }],
  }
}

describe("fallbackAgent", () => {
  it("maps astra and fable twins to the -opus twin", () => {
    expect(fallbackAgent("adversarial-reviewer-astra")).toBe("adversarial-reviewer-opus")
    expect(fallbackAgent("oracle-astra")).toBe("oracle-opus")
    expect(fallbackAgent("oracle-fable")).toBe("oracle-opus")
  })

  it("does not invent twins for other hyphenated agents", () => {
    expect(fallbackAgent("code-reviewer")).toBeUndefined()
    expect(fallbackAgent("spec-reviewer")).toBeUndefined()
    expect(fallbackAgent("adversarial-reviewer-opus")).toBeUndefined()
    expect(fallbackAgent("implementer")).toBeUndefined()
  })
})

describe("tool.execute.before (pre-dispatch probe)", () => {
  const before = (hooks: ReturnType<typeof makeHooks>, tool: string, agent: string) =>
    hooks["tool.execute.before"]!(
      { tool, sessionID: "ses_parent", callID: "call_1" },
      { args: { subagent_type: agent, prompt: "p", description: "d" } },
    )

  it("ignores non-task tools", async () => {
    const { deps, hooks } = hooksWith()
    await before(hooks, "bash", "adversarial-reviewer-astra")
    expect(deps.probe).not.toHaveBeenCalled()
  })

  it("does not probe for non-astra agents", async () => {
    const { deps, hooks } = hooksWith()
    await before(hooks, "task", "adversarial-reviewer-opus")
    await before(hooks, "task", "code-reviewer")
    expect(deps.probe).not.toHaveBeenCalled()
  })

  it("refuses an astra dispatch when astra-probe says DOWN, naming the -opus fallback", async () => {
    const { hooks } = hooksWith({
      probe: async () => ({ code: 1, message: "astra DOWN: no codex-lb account is active" }),
    })
    const err = await before(hooks, "task", "adversarial-reviewer-astra").then(
      () => undefined,
      (e: unknown) => e as Error,
    )
    expect(err).toBeInstanceOf(Error)
    expect(err!.message).toContain("adversarial-reviewer-astra")
    expect(err!.message).toContain("adversarial-reviewer-opus")
    expect(err!.message).toContain("astra DOWN: no codex-lb account is active")
  })

  it("covers oracle-astra too", async () => {
    const { hooks } = hooksWith({ probe: async () => ({ code: 1, message: "astra DOWN" }) })
    await expect(before(hooks, "task", "oracle-astra")).rejects.toThrow(/oracle-opus/)
  })

  it.each([
    ["UP", async () => ({ code: 0, message: "astra UP" })],
    ["UNKNOWN", async () => ({ code: 2, message: "astra UNKNOWN" })],
    ["probe missing/timed out", async () => ({ code: null, message: "" })],
    [
      "probe throws",
      async () => {
        throw new Error("spawn failed")
      },
    ],
  ])("fails open when the probe is %s", async (_label, probe) => {
    const { hooks } = hooksWith({ probe: probe as Deps["probe"] })
    await expect(before(hooks, "task", "adversarial-reviewer-astra")).resolves.toBeUndefined()
  })
})

describe("tool.execute.after (surface the child's error)", () => {
  it("rewrites an empty result from an errored child into a task_error with the fallback", async () => {
    const { deps, hooks } = hooksWith({
      lastMessage: async () => erroredAssistant("Provider response headers timed out after 120000ms"),
    })
    const out = taskOutput("")
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), out)

    expect(out.output).toContain(`<task id="${CHILD}" state="error">`)
    expect(out.output).toContain("<task_error>")
    expect(out.output).not.toContain("<task_result>")
    expect(out.output).toContain("Provider response headers timed out after 120000ms")
    expect(out.output).toContain("adversarial-reviewer-opus")
    expect(out.output).toContain("openai/gpt-6-astra")
    expect(out.output).toMatch(/NOT a result/)
    expect(deps.lastMessage).toHaveBeenCalledWith(CHILD)
  })

  it("marks a mid-stream failure as an error and keeps the partial text, labelled as truncated", async () => {
    const { hooks } = hooksWith({
      lastMessage: async () => erroredAssistant("SSE read timed out", "Finding 1: the plan"),
    })
    const out = taskOutput("Finding 1: the plan")
    await hooks["tool.execute.after"]!(afterInput("oracle-astra"), out)

    expect(out.output).toContain('state="error"')
    expect(out.output).toContain("oracle-opus")
    expect(out.output).toContain("SSE read timed out")
    expect(out.output).toMatch(/truncated/i)
    expect(out.output).toContain("Finding 1: the plan")
  })

  it("gives generic advice (no invented twin) for agents without an -opus twin", async () => {
    const { hooks } = hooksWith({ lastMessage: async () => erroredAssistant("boom") })
    const out = taskOutput("")
    await hooks["tool.execute.after"]!(afterInput("code-reviewer"), out)

    expect(out.output).toContain('state="error"')
    expect(out.output).toContain("boom")
    expect(out.output).not.toContain("code-opus")
  })

  it("tells a failed -opus twin's parent to stop and report, not to substitute another agent", async () => {
    const { hooks } = hooksWith({ lastMessage: async () => erroredAssistant("boom") })
    const out = taskOutput("")
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-opus"), out)

    expect(out.output).toContain('state="error"')
    expect(out.output).toMatch(/Do not substitute another agent/)
    expect(out.output).toMatch(/stop and report/i)
    expect(out.output).not.toMatch(/another agent suited/)
  })

  it("never throws, even when called with an undefined output (subtask failure path)", async () => {
    const { deps, hooks } = hooksWith({ lastMessage: async () => erroredAssistant("boom") })
    await expect(
      hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), undefined as never),
    ).resolves.toBeUndefined()
    expect(deps.lastMessage).not.toHaveBeenCalled()
  })

  it("leaves a healthy result untouched", async () => {
    const { hooks } = hooksWith({
      lastMessage: async () => ({ info: { role: "assistant" }, parts: [{ type: "text", text: "ok" }] }),
    })
    const out = taskOutput("ok")
    const before = out.output
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), out)
    expect(out.output).toBe(before)
  })

  it("leaves the output untouched when the lookup fails (fail-open)", async () => {
    const { hooks } = hooksWith({
      lastMessage: async () => {
        throw new Error("timeout")
      },
    })
    const out = taskOutput("")
    const before = out.output
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), out)
    expect(out.output).toBe(before)
  })

  it("does not look up background tasks or non-task tools", async () => {
    const { deps, hooks } = hooksWith()
    const bg = taskOutput("", { background: true })
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), bg)
    await hooks["tool.execute.after"]!(
      { tool: "bash", sessionID: "s", callID: "c", args: {} },
      { title: "", output: "x", metadata: {} },
    )
    expect(deps.lastMessage).not.toHaveBeenCalled()
  })

  it("ignores outputs that are not a completed task block", async () => {
    const { deps, hooks } = hooksWith({ lastMessage: async () => erroredAssistant("boom") })
    const out = { title: "", output: "something else", metadata: { sessionId: CHILD } }
    await hooks["tool.execute.after"]!(afterInput("adversarial-reviewer-astra"), out)
    expect(out.output).toBe("something else")
    expect(deps.lastMessage).not.toHaveBeenCalled()
  })
})

describe("plugin shape", () => {
  it("is a v1 plugin with an id and registers both hooks", async () => {
    expect(plugin.id).toBe("subagent-failure")
    const hooks = await plugin.server({ client: {} } as never)
    expect(typeof hooks["tool.execute.before"]).toBe("function")
    expect(typeof hooks["tool.execute.after"]).toBe("function")
  })
})
