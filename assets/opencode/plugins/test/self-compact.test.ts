import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import plugin from "../self-compact"
import { invalidateServeAuthHeader } from "../serve-auth"
import {
  createDebugLogger,
  getSharedPendingResumes,
  lookupActiveModel,
  createSelfCompactTool,
  createOnCompacted,
  createOnStatus,
  callSummarizeHttp,
  callPromptAsyncHttp,
  waitForSessionIdleHttp,
} from "../self-compact-impl"
import type { PendingResume } from "../self-compact-impl"

describe("createDebugLogger", () => {
  it("writes each diagnostic line to the durable sink without stderr by default", () => {
    const stderr = vi.fn()
    const appendLine = vi.fn()
    const debug = createDebugLogger({ stderr, appendLine, now: () => "2026-05-18T00:00:00.000Z" })

    debug("stage", { sessionID: "ses_abc", pendingSize: 2 })

    expect(stderr).not.toHaveBeenCalled()
    expect(appendLine).toHaveBeenCalledWith(
      "2026-05-18T00:00:00.000Z [self-compact] stage sessionID=ses_abc pendingSize=2",
    )
  })

  it("can still write diagnostics to stderr when explicitly enabled", () => {
    const stderr = vi.fn()
    const appendLine = vi.fn()
    const debug = createDebugLogger({
      stderr,
      stderrEnabled: true,
      appendLine,
      now: () => "2026-05-18T00:00:00.000Z",
    })

    debug("stage", { sessionID: "ses_abc", pendingSize: 2 })

    expect(stderr).toHaveBeenCalledWith("[self-compact] stage sessionID=ses_abc pendingSize=2")
    expect(appendLine).toHaveBeenCalledWith(
      "2026-05-18T00:00:00.000Z [self-compact] stage sessionID=ses_abc pendingSize=2",
    )
  })

  it("does not throw when durable sink write fails", () => {
    const debug = createDebugLogger({
      stderr: vi.fn(),
      appendLine: () => {
        throw new Error("disk full")
      },
      now: () => "2026-05-18T00:00:00.000Z",
    })

    expect(() => debug("stage")).not.toThrow()
  })
})

// ---------------------------------------------------------------------------
// lookupActiveModel: session metadata first, bounded message pages second.
//
// Regression (workstation, 2026-10-16): the old findActiveModel did an
// UNBOUNDED GET /session/:id/message. For a 20k-message session that was a
// 313 MB response fetched by the serve from itself; it intermittently failed,
// every failure was collapsed into `null`, and the queued resumption prompt
// was silently evicted ("onStatus no-model evict").
// ---------------------------------------------------------------------------

const json = (body: unknown, init: ResponseInit = {}) =>
  new Response(JSON.stringify(body), {
    status: 200,
    ...init,
    headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
  })

const userMsg = (modelID: string, providerID = "anthropic") => ({
  info: { role: "user", model: { providerID, modelID } },
})
const assistantMsg = () => ({ info: { role: "assistant", providerID: "anthropic", modelID: "summary-model" } })

/** Routes /session/:id and /session/:id/message?limit&before to canned answers. */
function routedFetch(routes: {
  session?: () => Response | Promise<Response>
  page?: (q: { limit: string | null; before: string | null }) => Response | Promise<Response>
}) {
  return vi.fn(async (input: string | URL | Request) => {
    const url = new URL((input as Request).url)
    if (/^\/session\/[^/]+$/.test(url.pathname)) {
      if (!routes.session) throw new Error("unexpected session GET")
      return routes.session()
    }
    if (/^\/session\/[^/]+\/message$/.test(url.pathname)) {
      if (!routes.page) throw new Error("unexpected message GET")
      return routes.page({
        limit: url.searchParams.get("limit"),
        before: url.searchParams.get("before"),
      })
    }
    throw new Error(`unexpected request ${url.pathname}`)
  })
}

const serverUrl = new URL("http://localhost:4096")
const messageRequests = (f: { mock: { calls: unknown[][] } }) =>
  f.mock.calls
    .map((c) => new URL((c[0] as Request).url))
    .filter((u) => u.pathname.endsWith("/message"))

describe("lookupActiveModel", () => {
  it("uses the session's own model metadata and never touches message history", async () => {
    const f = routedFetch({
      session: () =>
        json({ id: "s1", model: { id: "claude-opus-5-5", providerID: "anthropic", variant: "default" } }),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r).toEqual({
      ok: true,
      source: "session",
      model: { providerID: "anthropic", modelID: "claude-opus-5-5" },
    })
    expect(f).toHaveBeenCalledOnce()
    const req = f.mock.calls[0][0] as Request
    expect(req.method).toBe("GET")
    expect(req.url).toBe("http://localhost:4096/session/s1")
  })

  it("falls back to a bounded newest page when the session has no model metadata", async () => {
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => json([userMsg("old"), assistantMsg(), userMsg("new"), assistantMsg()]),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r).toEqual({ ok: true, source: "messages", model: { providerID: "anthropic", modelID: "new" } })
    const [first] = messageRequests(f)
    expect(first.searchParams.get("limit")).toBe("50")
    expect(first.searchParams.get("before")).toBeNull()
  })

  it("falls back to messages when the session GET fails or returns another session", async () => {
    for (const session of [
      () => new Response("boom", { status: 500 }),
      () => json({ id: "someone-else", model: { id: "wrong", providerID: "x" } }),
      () => Promise.reject(new Error("socket hang up")),
      () => new Response("not json", { status: 200 }),
    ]) {
      const f = routedFetch({ session, page: () => json([userMsg("from-history")]) })
      const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
      expect(r).toEqual({
        ok: true,
        source: "messages",
        model: { providerID: "anthropic", modelID: "from-history" },
      })
    }
  })

  it("never issues an unbounded message request", async () => {
    let n = 0
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => json([assistantMsg()], { headers: { "X-Next-Cursor": `c${++n}` } }),
    })
    await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1", maxPages: 4 })
    const reqs = messageRequests(f)
    expect(reqs.length).toBe(4)
    for (const u of reqs) expect(u.searchParams.get("limit")).toBe("50")
  })

  it("pages backwards via X-Next-Cursor, keeping limit on every request", async () => {
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: ({ before }) =>
        before === null
          ? json([assistantMsg(), assistantMsg()], { headers: { "X-Next-Cursor": "cur1" } })
          : json([userMsg("older-user"), assistantMsg()]),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r).toMatchObject({ ok: true, model: { modelID: "older-user" } })
    const reqs = messageRequests(f)
    expect(reqs.map((u) => [u.searchParams.get("limit"), u.searchParams.get("before")])).toEqual([
      ["50", null],
      ["50", "cur1"],
    ])
  })

  it("finds a user model behind more than 200 consecutive assistant messages with the defaults", async () => {
    // cartographer (ses_0da8...) really has a run of 213 assistant messages.
    const history = [userMsg("behind-the-run"), ...Array.from({ length: 213 }, assistantMsg)]
    const pageOf = (before: string | null) => {
      const end = before === null ? history.length : Number(before)
      const start = Math.max(0, end - 50)
      return json(history.slice(start, end), start > 0 ? { headers: { "X-Next-Cursor": String(start) } } : {})
    }
    const f = routedFetch({ session: () => json({ id: "s1" }), page: ({ before }) => pageOf(before) })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r).toMatchObject({ ok: true, source: "messages", model: { modelID: "behind-the-run" } })
  })

  it("reports history exhausted (not an error) when no user message carries a model", async () => {
    const f = routedFetch({ session: () => json({ id: "s1" }), page: () => json([assistantMsg()]) })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/history exhausted/i)
  })

  it("stops on a repeated cursor instead of looping", async () => {
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => json([assistantMsg()], { headers: { "X-Next-Cursor": "same" } }),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/repeated cursor/i)
    expect(messageRequests(f).length).toBe(2)
  })

  it("reports budget exhausted (distinct from history exhausted) at maxPages", async () => {
    let n = 0
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => json([assistantMsg()], { headers: { "X-Next-Cursor": `c${++n}` } }),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1", maxPages: 3 })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/budget exhausted/i)
    expect(messageRequests(f).length).toBe(3)
  })

  it("stops at the deadline", async () => {
    let t = 0
    let n = 0
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => {
        t += 6_000
        return json([assistantMsg()], { headers: { "X-Next-Cursor": `c${++n}` } })
      },
    })
    const r = await lookupActiveModel({
      fetch: f,
      serverUrl,
      sessionID: "s1",
      deadlineMs: 10_000,
      now: () => t,
    })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/deadline/i)
    expect(messageRequests(f).length).toBe(2)
  })

  it("aborts a single hung request at the deadline (the tool turn must not hang)", async () => {
    const hang = (req: Request) =>
      new Promise<Response>((_, reject) => {
        req.signal.addEventListener("abort", () => reject(new Error("aborted by deadline")))
      })
    const f = vi.fn((input: string | URL | Request) => hang(input as Request))
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1", deadlineMs: 50 })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/aborted|timeout|deadline/i)
  })

  it("names the HTTP status when a message page fails", async () => {
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => new Response("nope", { status: 503 }),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/503/)
  })

  it("names the exception when every request throws", async () => {
    const f = vi.fn().mockRejectedValue(new Error("network down"))
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r.ok).toBe(false)
    if (!r.ok) expect(r.reason).toMatch(/network down/)
  })

  it("tolerates malformed pages and entries without throwing", async () => {
    for (const body of [{ unexpected: "shape" }, [null, 3, { nope: 1 }, { info: null }]]) {
      const f = routedFetch({ session: () => json({ id: "s1" }), page: () => json(body) })
      const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
      expect(r.ok).toBe(false)
    }
  })

  it("ignores a latest assistant (e.g. a compaction summary on another model)", async () => {
    const f = routedFetch({
      session: () => json({ id: "s1" }),
      page: () => json([userMsg("the-user-model"), assistantMsg()]),
    })
    const r = await lookupActiveModel({ fetch: f, serverUrl, sessionID: "s1" })
    expect(r).toMatchObject({ ok: true, model: { modelID: "the-user-model" } })
  })
})

const MODEL = { providerID: "anthropic", modelID: "claude" }
const okLookup = () => vi.fn().mockResolvedValue({ ok: true, source: "session", model: MODEL })

describe("createSelfCompactTool (v4: resolve the model at tool time, then stash)", () => {
  it("shares pending entries across plugin instances in the same process", async () => {
    const pendingA = getSharedPendingResumes()
    pendingA.clear()
    const pendingB = getSharedPendingResumes()

    expect(pendingB).toBe(pendingA)

    const tool = createSelfCompactTool({ pending: pendingA, lookupModel: okLookup() })
    await tool.execute({ prompt: "resume across instances" }, { sessionID: "ses_shared" })
    pendingA.get("ses_shared")!.phase = "summarizing"

    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    const handler = createOnCompacted({ pending: pendingB, callPromptAsync, waitForIdle: async () => true })
    await handler({
      event: { type: "session.compacted", properties: { sessionID: "ses_shared" } },
    })

    expect(callPromptAsync).toHaveBeenCalledWith({
      sessionID: "ses_shared",
      text: "resume across instances",
    })
    expect(pendingA.has("ses_shared")).toBe(false)
  })

  it("stashes the prompt WITH the resolved model, phase 'awaitingTurnEnd'", async () => {
    const pending = new Map<string, PendingResume>()
    const lookupModel = okLookup()
    const tool = createSelfCompactTool({ pending, lookupModel })
    const result = await tool.execute({ prompt: "resume here" }, { sessionID: "ses_abc" })
    expect(lookupModel).toHaveBeenCalledWith({ sessionID: "ses_abc" })
    expect(result).toMatch(/queued/i)
    expect(pending.get("ses_abc")).toMatchObject({
      prompt: "resume here",
      phase: "awaitingTurnEnd",
      model: MODEL,
    })
    expect(typeof pending.get("ses_abc")?.createdAt).toBe("number")
  })

  it("on lookup failure: stashes nothing and TELLS the agent, with the reason", async () => {
    // The old behaviour returned "queued" and evicted silently at idle, so the
    // agent told the human "compacting next" and nothing ever happened.
    const pending = new Map<string, PendingResume>()
    const lookupModel = vi.fn().mockResolvedValue({ ok: false, reason: "session GET HTTP 503; page 1 HTTP 503" })
    const tool = createSelfCompactTool({ pending, lookupModel })
    const result = await tool.execute({ prompt: "resume here" }, { sessionID: "ses_abc" })
    expect(pending.has("ses_abc")).toBe(false)
    expect(result).toMatch(/NOT queued/)
    expect(result).toContain("session GET HTTP 503; page 1 HTTP 503")
    expect(result).not.toMatch(/^Compaction queued/)
  })

  it("on a lookup that throws: same visible failure, nothing stashed", async () => {
    const pending = new Map<string, PendingResume>()
    const lookupModel = vi.fn().mockRejectedValue(new Error("kaboom"))
    const tool = createSelfCompactTool({ pending, lookupModel })
    const result = await tool.execute({ prompt: "p" }, { sessionID: "ses_abc" })
    expect(pending.has("ses_abc")).toBe(false)
    expect(result).toMatch(/NOT queued/)
    expect(result).toContain("kaboom")
  })

  it("a failed retry does not clobber an earlier successfully queued entry", async () => {
    const pending = new Map<string, PendingResume>()
    const lookupModel = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, source: "session", model: MODEL })
      .mockResolvedValueOnce({ ok: false, reason: "nope" })
    const tool = createSelfCompactTool({ pending, lookupModel })
    await tool.execute({ prompt: "first" }, { sessionID: "ses_x" })
    await tool.execute({ prompt: "second" }, { sessionID: "ses_x" })
    expect(pending.get("ses_x")?.prompt).toBe("first")
  })

  it("evicts stale entries (>30min) before stashing", async () => {
    const pending = new Map<string, PendingResume>()
    const STALE_MS = 30 * 60 * 1000
    pending.set("ses_old", {
      prompt: "ancient",
      phase: "awaitingTurnEnd",
      model: MODEL,
      createdAt: Date.now() - STALE_MS - 1,
    })
    const tool = createSelfCompactTool({ pending, lookupModel: okLookup() })
    await tool.execute({ prompt: "fresh" }, { sessionID: "ses_new" })
    expect(pending.has("ses_old")).toBe(false)
    expect(pending.has("ses_new")).toBe(true)
  })

  it("overwrites a prior pending entry for the same session (last-write-wins)", async () => {
    const pending = new Map<string, PendingResume>()
    const tool = createSelfCompactTool({ pending, lookupModel: okLookup() })
    await tool.execute({ prompt: "first" }, { sessionID: "ses_x" })
    await tool.execute({ prompt: "second" }, { sessionID: "ses_x" })
    expect(pending.get("ses_x")?.prompt).toBe("second")
  })
})

describe("createOnCompacted event handler", () => {
  it("ignores events that are not session.compacted", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "x", phase: "summarizing", model: MODEL, createdAt: Date.now() })
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle: async () => true })
    await handler({ event: { type: "session.idle", properties: { sessionID: "s1" } } })
    expect(callPromptAsync).not.toHaveBeenCalled()
    expect(pending.has("s1")).toBe(true)
  })

  it("ignores session.compacted for sessions without a pending prompt", async () => {
    const pending = new Map<string, PendingResume>()
    const callPromptAsync = vi.fn()
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle: async () => true })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "unknown" } } })
    expect(callPromptAsync).not.toHaveBeenCalled()
  })

  it("calls callPromptAsync with the stashed prompt and clears state", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume now", phase: "summarizing", model: MODEL, createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle: async () => true })
    await handler({
      event: { type: "session.compacted", properties: { sessionID: "s1" } },
    })
    expect(callPromptAsync).toHaveBeenCalledWith({ sessionID: "s1", text: "resume now" })
    expect(pending.has("s1")).toBe(false)
  })

  it("clears state even if callPromptAsync throws", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", phase: "summarizing", model: MODEL, createdAt: Date.now() })
    const callPromptAsync = vi.fn().mockRejectedValue(new Error("boom"))
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle: async () => true })
    await expect(
      handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } }),
    ).rejects.toThrow("boom")
    expect(pending.has("s1")).toBe(false)
  })

  it("removes the pending entry before awaiting callPromptAsync (no double-delivery race)", async () => {
    const pending = new Map<string, PendingResume>()
    pending.set("s1", { prompt: "resume", phase: "summarizing", model: MODEL, createdAt: Date.now() })
    let observedDuringCall: boolean | undefined
    const callPromptAsync = vi.fn().mockImplementation(async () => {
      // While callPromptAsync is in-flight, the pending entry must already
      // be gone — otherwise a re-entrant session.compacted event for the
      // same session would also see it and double-deliver.
      observedDuringCall = pending.has("s1")
    })
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle: async () => true })
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

describe("createOnStatus (v4: idle-triggered summarize with the stashed model)", () => {
  it("ignores non-status events", async () => {
    const pending = new Map<string, PendingResume>()
    const callSummarize = vi.fn()
    const handler = createOnStatus({ pending, callSummarize })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "ses_x" } } })
    expect(callSummarize).not.toHaveBeenCalled()
  })

  it("ignores non-idle status events", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", model: MODEL, createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn()
    const handler = createOnStatus({ pending, callSummarize })
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
    const handler = createOnStatus({ pending, callSummarize })
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
      ["ses_x", { prompt: "p", phase: "summarizing", model: MODEL, createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn()
    const handler = createOnStatus({ pending, callSummarize })
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
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", model: MODEL, createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn().mockResolvedValue(undefined)
    const handler = createOnStatus({ pending, callSummarize })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(callSummarize).toHaveBeenCalledWith({
      sessionID: "ses_x",
      providerID: "anthropic",
      modelID: "claude",
    })
    // No HTTP model lookup at idle time any more: the model was resolved by the tool.
    expect(pending.get("ses_x")?.phase).toBe("summarizing")
  })

  it("evicts a (legacy) entry that carries no model instead of guessing one", async () => {
    const pending = new Map<string, PendingResume>([
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", createdAt: Date.now() } as unknown as PendingResume],
    ])
    const callSummarize = vi.fn()
    const handler = createOnStatus({ pending, callSummarize })
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
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", model: MODEL, createdAt: Date.now() }],
    ])
    const callSummarize = vi.fn().mockRejectedValue(new Error("boom"))
    const handler = createOnStatus({ pending, callSummarize })
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
      ["ses_x", { prompt: "p", phase: "awaitingTurnEnd", model: MODEL, createdAt: Date.now() }],
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
    const handler = createOnStatus({ pending, callSummarize })
    await handler({
      event: {
        type: "session.status",
        properties: { sessionID: "ses_x", status: { type: "idle" } },
      },
    })
    expect(summarizeCalls).toBe(1)
  })
})

describe("createOnCompacted (v3: wait for the runner to go idle before resuming)", () => {
  // Regression: on 1.17.2 session.compacted is published from INSIDE the still-running
  // compaction loop. Firing prompt_async then hits Runner.ensureRunning's "Running"
  // branch, which silently discards the new loop, so the resumption message is persisted
  // but never processed. The fix waits until the session reports idle before firing.
  it("does NOT fire prompt_async until waitForIdle resolves", async () => {
    const pending = new Map<string, PendingResume>([
      ["s1", { prompt: "resume", phase: "summarizing", model: MODEL, createdAt: Date.now() }],
    ])
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    let releaseIdle!: (v: boolean) => void
    const idle = new Promise<boolean>((r) => (releaseIdle = r))
    const waitForIdle = vi.fn().mockReturnValue(idle)
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle })

    const done = handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } })
    await Promise.resolve()
    // Runner still Running: must not have fired yet (this is the bug we are fixing).
    expect(waitForIdle).toHaveBeenCalledWith({ sessionID: "s1" })
    expect(callPromptAsync).not.toHaveBeenCalled()

    releaseIdle(true)
    await done
    expect(callPromptAsync).toHaveBeenCalledWith({ sessionID: "s1", text: "resume" })
  })

  it("does NOT fire prompt_async if the session never goes idle (waitForIdle false)", async () => {
    const pending = new Map<string, PendingResume>([
      ["s1", { prompt: "resume", phase: "summarizing", model: MODEL, createdAt: Date.now() }],
    ])
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    const waitForIdle = vi.fn().mockResolvedValue(false)
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } })
    expect(callPromptAsync).not.toHaveBeenCalled()
    expect(pending.has("s1")).toBe(false)
  })

  it("removes the pending entry before awaiting waitForIdle (no double-delivery on re-entrant compacted)", async () => {
    const pending = new Map<string, PendingResume>([
      ["s1", { prompt: "resume", phase: "summarizing", model: MODEL, createdAt: Date.now() }],
    ])
    const callPromptAsync = vi.fn().mockResolvedValue(undefined)
    let observedDuringWait: boolean | undefined
    const waitForIdle = vi.fn().mockImplementation(async () => {
      observedDuringWait = pending.has("s1")
      return true
    })
    const handler = createOnCompacted({ pending, callPromptAsync, waitForIdle })
    await handler({ event: { type: "session.compacted", properties: { sessionID: "s1" } } })
    expect(observedDuringWait).toBe(false)
    expect(callPromptAsync).toHaveBeenCalledOnce()
  })
})

describe("waitForSessionIdleHttp", () => {
  const statusResponse = (map: Record<string, { type: string }>) =>
    new Response(JSON.stringify(map), { status: 200, headers: { "Content-Type": "application/json" } })

  it("GETs /session/status scoped by directory and returns true when the session is idle", async () => {
    const fetchFn = vi.fn().mockResolvedValue(statusResponse({ s1: { type: "idle" } }))
    const ok = await waitForSessionIdleHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", directory: "/home/dev/projects/foo", attempts: 5, intervalMs: 0, sleep: async () => {} },
    )
    expect(ok).toBe(true)
    const req = fetchFn.mock.calls[0][0] as Request
    const url = new URL(req.url)
    expect(url.pathname).toBe("/session/status")
    expect(url.searchParams.get("directory")).toBe("/home/dev/projects/foo")
    expect(req.method).toBe("GET")
  })

  it("treats a session absent from the status map (no runner) as idle", async () => {
    const fetchFn = vi.fn().mockResolvedValue(statusResponse({ other: { type: "busy" } }))
    const ok = await waitForSessionIdleHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", attempts: 3, intervalMs: 0, sleep: async () => {} },
    )
    expect(ok).toBe(true)
  })

  it("polls until the session transitions from busy to idle", async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(statusResponse({ s1: { type: "busy" } }))
      .mockResolvedValueOnce(statusResponse({ s1: { type: "busy" } }))
      .mockResolvedValueOnce(statusResponse({ s1: { type: "idle" } }))
    const sleep = vi.fn().mockResolvedValue(undefined)
    const ok = await waitForSessionIdleHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", attempts: 10, intervalMs: 5, sleep },
    )
    expect(ok).toBe(true)
    expect(fetchFn).toHaveBeenCalledTimes(3)
    expect(sleep).toHaveBeenCalledTimes(2)
  })

  it("returns false after exhausting attempts while still busy", async () => {
    const fetchFn = vi.fn().mockResolvedValue(statusResponse({ s1: { type: "busy" } }))
    const ok = await waitForSessionIdleHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", attempts: 4, intervalMs: 0, sleep: async () => {} },
    )
    expect(ok).toBe(false)
    expect(fetchFn).toHaveBeenCalledTimes(4)
  })

  it("keeps polling (does not crash or early-return idle) when a status read fails", async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(new Response("boom", { status: 500 }))
      .mockResolvedValueOnce(statusResponse({ s1: { type: "idle" } }))
    const ok = await waitForSessionIdleHttp(
      { fetch: fetchFn, serverUrl: new URL("http://localhost:4096") },
      { sessionID: "s1", attempts: 5, intervalMs: 0, sleep: async () => {} },
    )
    expect(ok).toBe(true)
    expect(fetchFn).toHaveBeenCalledTimes(2)
  })
})

describe("self-compact plugin auth integration", () => {
  const originalEnv = { ...process.env }

  beforeEach(() => {
    invalidateServeAuthHeader()
    delete process.env.OPENCODE_SERVER_PASSWORD
    delete process.env.OPENCODE_SERVER_PASSWORD_FILE
    delete process.env.OPENCODE_SERVER_USERNAME
  })

  afterEach(() => {
    process.env = { ...originalEnv }
    invalidateServeAuthHeader()
  })

  it("plugin fetch attaches Authorization header when OPENCODE_SERVER_PASSWORD is set", async () => {
    process.env.OPENCODE_SERVER_PASSWORD = "secret_pass"
    process.env.OPENCODE_SERVER_USERNAME = "opencode"

    const mockFetch = vi.fn().mockImplementation(async (req: Request) => {
      if (/\/session\/[^/]+$/.test(new URL(req.url).pathname)) {
        const id = new URL(req.url).pathname.split("/")[2]
        return new Response(
          JSON.stringify({ id, model: { id: "claude-3-5", providerID: "anthropic" } }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        )
      }
      if (req.url.endsWith("/summarize")) {
        return new Response(null, { status: 200 })
      }
      return new Response(null, { status: 200 })
    })

    const p = await plugin.server({
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } } as any,
      serverUrl: new URL("http://localhost:54321"),
      directory: "/tmp/test",
    } as any)

    // Execute tool to stash pending resume
    const pending = getSharedPendingResumes()
    pending.clear()
    await p.tool!.self_compact_and_resume.execute({ prompt: "resume prompt" }, { sessionID: "s_auth_1" } as any)

    // Trigger onStatus idle event which calls callSummarizeHttp with the stashed model
    await p.event!({
      event: {
        type: "session.status",
        properties: { sessionID: "s_auth_1", status: { type: "idle" } },
      },
    })

    const paths = mockFetch.mock.calls.map((c) => new URL((c[0] as Request).url).pathname)
    // End-to-end: the tool resolved the model from session metadata (no
    // history download) and the idle handler fired summarize with it.
    expect(paths).toEqual(["/session/s_auth_1", "/session/s_auth_1/summarize"])
    const summarizeBody = await (mockFetch.mock.calls[1][0] as Request).clone().json()
    expect(summarizeBody).toEqual({ providerID: "anthropic", modelID: "claude-3-5", auto: false })
    for (const call of mockFetch.mock.calls) {
      const req = call[0] as Request
      expect(req.headers.get("Authorization")).toBe(
        `Basic ${Buffer.from("opencode:secret_pass").toString("base64")}`,
      )
    }
  })

  it("plugin fetch remains inert with NO Authorization header key when no password set", async () => {
    const mockFetch = vi.fn().mockImplementation(async (req: Request) => {
      if (/\/session\/[^/]+$/.test(new URL(req.url).pathname)) {
        const id = new URL(req.url).pathname.split("/")[2]
        return new Response(
          JSON.stringify({ id, model: { id: "claude-3-5", providerID: "anthropic" } }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        )
      }
      if (req.url.endsWith("/summarize")) {
        return new Response(null, { status: 200 })
      }
      return new Response(null, { status: 200 })
    })

    const p = await plugin.server({
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } } as any,
      serverUrl: new URL("http://localhost:54321"),
      directory: "/tmp/test",
    } as any)

    const pending = getSharedPendingResumes()
    pending.clear()
    await p.tool!.self_compact_and_resume.execute({ prompt: "resume prompt" }, { sessionID: "s_no_auth" } as any)

    await p.event!({
      event: {
        type: "session.status",
        properties: { sessionID: "s_no_auth", status: { type: "idle" } },
      },
    })

    expect(mockFetch).toHaveBeenCalled()
    for (const call of mockFetch.mock.calls) {
      const req = call[0] as Request
      expect(req.headers.has("Authorization")).toBe(false)
      expect(req.headers.has("authorization")).toBe(false)
      expect(Object.fromEntries(req.headers.entries())).not.toHaveProperty("authorization")
    }
  })
})
