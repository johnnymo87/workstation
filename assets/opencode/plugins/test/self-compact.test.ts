import { describe, it, expect, vi } from "vitest"
import {
  findActiveModel,
  createSelfCompactTool,
  createOnCompacted,
  callSummarizeHttp,
  callPromptAsyncHttp,
} from "../self-compact"
import type { PendingResume } from "../self-compact"

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

describe("createOnCompacted event handler", () => {
  it("ignores events that are not session.compacted", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "x", createdAt: Date.now() })
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({ event: { type: "session.idle", properties: { sessionID: "s1" } } } as any)
    expect(callPromptAsync).not.toHaveBeenCalled()
    expect(pending.has("s1")).toBe(true)
  })

  it("ignores session.compacted for sessions without a pending prompt", async () => {
    const pending = new Map<string, PendingResume>()
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "unknown" } } } as any)
    expect(callPromptAsync).not.toHaveBeenCalled()
  })

  it("calls callPromptAsync with the stashed prompt and clears state", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume now", createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    const handler = createOnCompacted({ pending, callPromptAsync })
    await handler({
      event: { type: "session.compacted", properties: { sessionID: "s1" } },
    } as any)
    expect(callPromptAsync).toHaveBeenCalledWith({ sessionID: "s1", text: "resume now" })
    expect(pending.has("s1")).toBe(false)
  })

  it("clears state even if callPromptAsync throws", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockRejectedValue(new Error("boom"))
    const handler = createOnCompacted({ pending, callPromptAsync })
    await expect(
      handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } } as any),
    ).rejects.toThrow("boom")
    expect(pending.has("s1")).toBe(false)
  })

  it("removes the pending entry before awaiting callPromptAsync (no double-delivery race)", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", createdAt: Date.now() })
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
    } as any)
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
