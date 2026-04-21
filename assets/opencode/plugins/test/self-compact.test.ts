import { describe, it, expect, vi } from "vitest"
import {
  findActiveModel,
  createSelfCompactTool,
  createOnCompacted,
  createOnStatus,
  callSummarizeHttp,
  callPromptAsyncHttp,
} from "../self-compact-impl"
import type { PendingResume } from "../self-compact-impl"

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
    expect(typeof pending.get("ses_abc")?.createdAt).toBe("number")
  })

  it("does NOT perform any HTTP work from execute (deadlock vector removed)", async () => {
    // The factory should not even accept findActiveModel/callSummarize as deps anymore.
    // If this test compiles AND passes, the API surface is correct: execute
    // takes only a `pending` Map as a dependency, so there is no path by which
    // it could reach into HTTP/SDK calls during a tool turn.
    const pending = new Map<string, PendingResume>()
    const tool = createSelfCompactTool({ pending })
    const result = await tool.execute({ prompt: "x" }, { sessionID: "ses_abc" })
    expect(result).toMatch(/queued/i)
    expect(pending.has("ses_abc")).toBe(true)
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

describe("createOnCompacted event handler", () => {
  it("ignores events that are not session.compacted", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "x", phase: "summarizing", createdAt: Date.now() })
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
    pending.set("s1", { prompt: "resume now", phase: "summarizing", createdAt: Date.now() })
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
    pending.set("s1", { prompt: "resume", phase: "summarizing", createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockRejectedValue(new Error("boom"))
    const handler = createOnCompacted({ pending, callPromptAsync })
    await expect(
      handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } }),
    ).rejects.toThrow("boom")
    expect(pending.has("s1")).toBe(false)
  })

  it("removes the pending entry before awaiting callPromptAsync (no double-delivery race)", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", phase: "summarizing", createdAt: Date.now() })
    let observedDuringCall: boolean | undefined
    const callPromptAsync = vi.fn().mockImplementation(async () => {
      // While callPromptAsync is in-flight, the pending entry must already
      // be gone — otherwise a re-entrant session.compacted event for the
      // same session would also see it and double-deliver.
      observedDuringCall = pending.has("s1")
    })
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({
      event: { type: "session.compacted", properties: { sessionID: "s1" } },
    })
    expect(callPromptAsync).toHaveBeenCalledOnce()
    expect(observedDuringCall).toBe(false)
    expect(pending.has("s1")).toBe(false)
  })
})

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
    const findActiveModel = vi
      .fn()
      .mockResolvedValue({ providerID: "anthropic", modelID: "claude" })
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
