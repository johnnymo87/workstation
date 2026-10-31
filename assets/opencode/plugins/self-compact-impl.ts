import type { EventSessionCompacted } from "@opencode-ai/sdk"
import { appendFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

export type ModelRef = { providerID: string; modelID: string }

export type ModelLookup =
  | { ok: true; model: ModelRef; source: "session" | "messages" }
  | { ok: false; reason: string }

const DEFAULT_LOOKUP_PAGE_LIMIT = 50
// 10 x 50 = 500 messages. A real session (cartographer, 2026-10) has a run of
// 213 consecutive assistant messages between model-bearing user messages, so a
// three- or four-page budget would be too small.
const DEFAULT_LOOKUP_MAX_PAGES = 10
const DEFAULT_LOOKUP_DEADLINE_MS = 20_000

function errText(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

type JsonResult = { ok: true; body: unknown; res: Response } | { ok: false; reason: string }

/**
 * GET + JSON decode under an independently enforced deadline.
 *
 * The AbortSignal is passed for cooperative cancellation, but the deadline does
 * NOT depend on the transport honouring it: the whole exchange (headers AND
 * body) is raced against a timer. This runs inside a tool's execute, so a hung
 * request must not hang the agent's turn -- and opencode's in-process web
 * handler can miss an abort that arrives during its cold initialisation.
 */
async function getJson(
  fetchFn: typeof fetch,
  url: URL,
  timeoutMs: number,
  outer?: AbortSignal,
): Promise<JsonResult> {
  if (outer?.aborted) return { ok: false, reason: "cancelled" }
  const ac = new AbortController()
  const budget = Math.max(1, timeoutMs)
  let timer: ReturnType<typeof setTimeout> | undefined
  let onOuter: (() => void) | undefined

  // Arm the deadline and the cancel hook BEFORE starting the request: a
  // transport may observe (or trigger) the abort synchronously.
  const deadline = new Promise<JsonResult>((resolve) => {
    timer = setTimeout(() => {
      ac.abort(new Error("deadline"))
      resolve({ ok: false, reason: `timed out after ${budget}ms (deadline)` })
    }, budget)
  })
  const cancelled = new Promise<JsonResult>((resolve) => {
    if (!outer) return
    onOuter = () => {
      ac.abort(outer.reason)
      resolve({ ok: false, reason: "cancelled" })
    }
    outer.addEventListener("abort", onOuter, { once: true })
  })
  const work = (async (): Promise<JsonResult> => {
    let res: Response
    try {
      res = await fetchFn(new Request(url.toString(), { method: "GET", signal: ac.signal }))
    } catch (err) {
      return { ok: false, reason: `fetch threw: ${errText(err)}` }
    }
    if (!res.ok) return { ok: false, reason: `HTTP ${res.status}` }
    try {
      return { ok: true, body: await res.json(), res }
    } catch (err) {
      return { ok: false, reason: `bad JSON: ${errText(err)}` }
    }
  })()
  try {
    return await Promise.race([work, deadline, cancelled])
  } finally {
    clearTimeout(timer)
    if (outer && onOuter) outer.removeEventListener("abort", onOuter)
  }
}

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined
}

function userModelOf(entry: unknown): ModelRef | undefined {
  const info = asRecord(asRecord(entry)?.info)
  if (!info || info.role !== "user") return undefined
  const model = asRecord(info.model)
  if (typeof model?.providerID === "string" && model.providerID && typeof model.modelID === "string" && model.modelID) {
    return { providerID: model.providerID, modelID: model.modelID }
  }
  return undefined
}

/**
 * Resolve the model a session is running on, WITHOUT downloading its history.
 *
 * 1. `GET /session/:id` -- the session row's own `model` metadata, which is
 *    what upstream's `SessionPrompt.currentModel()` consults first. Note the
 *    field is `model.id`, not `model.modelID`.
 * 2. Only if that is missing or unreadable: newest-first pages of
 *    `GET /session/:id/message?limit=N`, following `X-Next-Cursor` via
 *    `before=`, scanning each page backwards for a user message with a model.
 *    The latest *assistant* is deliberately not used: it may be a compaction
 *    summary produced by the separately configured compaction model.
 *
 * Never issues an unbounded `/message` request. That request is what broke
 * here: 313 MB for a 20k-message session, fetched by the serve from itself,
 * failing intermittently with the error swallowed.
 *
 * Every failure carries a reason, and "history exhausted" (there really is no
 * model) is kept distinct from "budget exhausted" / "deadline" (we stopped
 * looking).
 */
export async function lookupActiveModel(input: {
  fetch: typeof fetch
  serverUrl: URL
  sessionID: string
  pageLimit?: number
  maxPages?: number
  deadlineMs?: number
  now?: () => number
  /** The tool's abort signal: a cancelled turn stops the lookup. */
  signal?: AbortSignal
}): Promise<ModelLookup> {
  const pageLimit = input.pageLimit ?? DEFAULT_LOOKUP_PAGE_LIMIT
  const maxPages = input.maxPages ?? DEFAULT_LOOKUP_MAX_PAGES
  const deadlineMs = input.deadlineMs ?? DEFAULT_LOOKUP_DEADLINE_MS
  const now = input.now ?? Date.now
  const started = now()
  const sessionPath = `/session/${encodeURIComponent(input.sessionID)}`
  const reasons: string[] = []
  const remaining = () => deadlineMs - (now() - started)

  const session = await getJson(input.fetch, new URL(sessionPath, input.serverUrl), remaining(), input.signal)
  if (!session.ok && input.signal?.aborted) return { ok: false, reason: "cancelled" }
  if (session.ok) {
    const body = asRecord(session.body)
    const model = asRecord(body?.model)
    if (body?.id !== input.sessionID) {
      reasons.push("session GET returned a different session")
    } else if (typeof model?.providerID === "string" && model.providerID && typeof model.id === "string" && model.id) {
      return { ok: true, source: "session", model: { providerID: model.providerID, modelID: model.id } }
    } else {
      reasons.push("session has no model metadata")
    }
  } else {
    reasons.push(`session GET ${session.reason}`)
  }

  const seen = new Set<string>()
  let before: string | undefined
  for (let page = 1; page <= maxPages; page++) {
    if (remaining() <= 0) {
      reasons.push(`deadline ${deadlineMs}ms reached after ${page - 1} page(s)`)
      return { ok: false, reason: reasons.join("; ") }
    }
    const url = new URL(`${sessionPath}/message`, input.serverUrl)
    url.searchParams.set("limit", String(pageLimit))
    if (before) url.searchParams.set("before", before)
    const res = await getJson(input.fetch, url, remaining(), input.signal)
    if (!res.ok && input.signal?.aborted) return { ok: false, reason: "cancelled" }
    if (!res.ok) {
      reasons.push(`message page ${page} ${res.reason}`)
      return { ok: false, reason: reasons.join("; ") }
    }
    if (!Array.isArray(res.body)) {
      reasons.push(`message page ${page} is not an array`)
      return { ok: false, reason: reasons.join("; ") }
    }
    for (let i = res.body.length - 1; i >= 0; i--) {
      const model = userModelOf(res.body[i])
      if (model) return { ok: true, source: "messages", model }
    }
    const cursor = res.res.headers.get("X-Next-Cursor") ?? undefined
    if (!cursor) {
      reasons.push(`history exhausted after ${page} page(s): no user message carries a model`)
      return { ok: false, reason: reasons.join("; ") }
    }
    if (seen.has(cursor)) {
      reasons.push(`repeated cursor at page ${page}`)
      return { ok: false, reason: reasons.join("; ") }
    }
    seen.add(cursor)
    before = cursor
  }
  reasons.push(`budget exhausted: ${maxPages} page(s) of ${pageLimit} without a user model`)
  return { ok: false, reason: reasons.join("; ") }
}

const STALE_MS = 30 * 60 * 1000
// A `resuming` entry is waiting for a turn that is not ours to end (see
// createOnCompacted's deferral). Agent turns with subagents routinely run for
// hours, so the 30-minute bound would discard exactly the prompts the deferral
// exists to save. A day still keeps the Map bounded across the process lifetime.
const RESUMING_STALE_MS = 24 * 60 * 60 * 1000

/**
 * Prepended to a resumption prompt that could not be delivered straight after
 * compaction because another prompt (typically a swarm message) started a turn
 * first. The agent has been working from the compaction summary in the
 * meantime, so it needs to know this arrives late rather than act on it as if
 * nothing had happened since.
 */
export const DEFERRED_RESUME_NOTE =
  "[self-compact] This is the resumption prompt you queued with self_compact_and_resume. " +
  "Another message started a turn right after compaction, so it is arriving late, after that " +
  "turn. Reconcile it with anything you have done since before acting on it."

// Bounded poll for the post-compaction idle. session.compacted is published from inside
// the still-running compaction loop, so the runner needs a moment to finish and go idle
// before prompt_async can start a fresh loop. 120 * 250ms = 30s is a generous ceiling;
// in practice the runner goes idle within ~1s of session.compacted.
const DEFAULT_IDLE_POLL_ATTEMPTS = 120
const DEFAULT_IDLE_POLL_INTERVAL_MS = 250

/**
 * Diagnostic logger for the self-compact regression hunt (workstation issue:
 * post-1.15 bump, the resumption prompt no longer lands after compaction).
 *
 * Writes to a durable state-file sink with a `[self-compact]` tag so we can
 * inspect the trail across the four
 * boundaries we suspect:
 *
 *   1. tool execute        — did the model actually queue a resumption?
 *   2. onStatus(idle)      — did the plugin see the session go idle and fire summarize?
 *   3. onCompacted         — did the session.compacted bus event reach the plugin?
 *   4. HTTP POSTs          — did /summarize and /prompt_async succeed at the HTTP layer?
 *
 * Keep this lightweight — no JSON.stringify of large objects, no PII beyond
 * sessionID prefix. Stderr is opt-in only because opencode renders plugin
 * stderr as red TUI output.
 */
export function createDebugLogger(deps: {
  stderr: (line: string) => void
  stderrEnabled?: boolean
  appendLine?: (line: string) => void
  now?: () => string
}) {
  return (stage: string, fields: Record<string, unknown> = {}) => {
    const parts = [`[self-compact] ${stage}`]
    for (const [k, v] of Object.entries(fields)) {
      parts.push(`${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
    }
    const line = parts.join(" ")
    if (deps.stderrEnabled) deps.stderr(line)
    try {
      deps.appendLine?.(`${(deps.now ?? (() => new Date().toISOString()))()} ${line}`)
    } catch {
      // Diagnostics must never affect compaction behavior.
    }
  }
}

function debugLogPath(): string {
  if (process.env.OPENCODE_SELF_COMPACT_LOG) return process.env.OPENCODE_SELF_COMPACT_LOG
  const stateHome = process.env.XDG_STATE_HOME ??
    (process.env.HOME ? join(process.env.HOME, ".local", "state") : "/tmp")
  return join(stateHome, "opencode", "self-compact.log")
}

const debug = createDebugLogger({
  stderr: (line) => {
    // eslint-disable-next-line no-console
    console.error(line)
  },
  stderrEnabled: process.env.OPENCODE_SELF_COMPACT_STDERR === "1",
  appendLine: (line) => {
    const path = debugLogPath()
    mkdirSync(dirname(path), { recursive: true })
    appendFileSync(path, `${line}\n`, "utf8")
  },
})

export interface PendingResume {
  prompt: string
  /** Resolved by the tool at execute time (see createSelfCompactTool). */
  model: ModelRef
  /**
   * State machine discriminator.
   *
   * - `awaitingTurnEnd`: the tool has stashed the entry; the onStatus handler
   *   is waiting for the session to go idle so it can fire POST /summarize.
   * - `summarizing`: onStatus has fired summarize; the entry is held until
   *   the `session.compacted` event arrives.
   * - `resuming`: compaction is done and the prompt is waiting for the session
   *   to go idle. Whichever sees idle first -- onCompacted's status poll or
   *   onStatus's idle event -- deletes the entry synchronously and delivers it,
   *   so exactly one of them does (v5).
   *
   * Without this field, onStatus cannot distinguish "first idle after queue"
   * (should fire summarize) from "second idle while summarize is in flight"
   * (must not double-trigger). See addendum to v1 design doc for rationale.
   */
  phase: "awaitingTurnEnd" | "summarizing" | "resuming"
  /**
   * Set when onCompacted's post-compaction idle poll timed out: another prompt
   * started a turn straight after compaction. The entry then waits for that
   * turn's idle, and is delivered with DEFERRED_RESUME_NOTE prepended.
   */
  deferred?: boolean
  createdAt: number
}

const SHARED_PENDING_KEY = Symbol.for("opencode.selfCompact.pendingResumes")

export function getSharedPendingResumes(): Map<string, PendingResume> {
  const global = globalThis as typeof globalThis & {
    [SHARED_PENDING_KEY]?: Map<string, PendingResume>
  }
  global[SHARED_PENDING_KEY] ??= new Map<string, PendingResume>()
  return global[SHARED_PENDING_KEY]
}

/**
 * v4 tool: resolve the model, then stash-and-return.
 *
 * The tool records the resumption prompt under the session's ID and returns.
 * The actual `POST /summarize` trigger lives in `createOnStatus`, which fires
 * when the session goes idle (after this turn closes). Calling `/summarize`
 * from inside `execute` deadlocks with the outer prompt loop (v1), so it must
 * stay out of here.
 *
 * What `execute` DOES do since v4 is the model lookup: two small read-only GETs
 * at most (session metadata, then bounded message pages), which never touch the
 * session runner, so they cannot deadlock. Doing it here rather than at idle
 * time is what makes a failure visible: the reason comes back as this tool's
 * result, to the agent that can tell the human, instead of the old "queued"
 * followed by a silent eviction.
 */
export function createSelfCompactTool(deps: {
  pending: Map<string, PendingResume>
  lookupModel: (input: { sessionID: string; signal?: AbortSignal }) => Promise<ModelLookup>
}) {
  return {
    async execute(
      args: { prompt: string },
      toolCtx: { sessionID: string; abort?: AbortSignal },
    ): Promise<string> {
      const now = Date.now()
      // Evict stale entries so the Map doesn't grow without bound across the
      // process lifetime. 30 minutes is generous; a real compaction takes
      // seconds to a few minutes.
      for (const [sid, entry] of deps.pending) {
        const bound = entry.phase === "resuming" ? RESUMING_STALE_MS : STALE_MS
        if (now - entry.createdAt > bound) deps.pending.delete(sid)
      }

      let lookup: ModelLookup
      try {
        lookup = await deps.lookupModel({ sessionID: toolCtx.sessionID, signal: toolCtx.abort })
      } catch (err) {
        lookup = { ok: false, reason: `lookup threw: ${errText(err)}` }
      }
      // A turn cancelled while the lookup was in flight has already gone idle.
      // Arming an entry now would fire on some LATER, unrelated idle.
      if (toolCtx.abort?.aborted) {
        debug("tool.execute cancelled", { sessionID: toolCtx.sessionID, elapsedMs: Date.now() - now })
        return "Compaction NOT queued: the turn was cancelled."
      }
      if (!lookup.ok) {
        const earlier = deps.pending.get(toolCtx.sessionID)
        debug("tool.execute lookup FAILED", {
          sessionID: toolCtx.sessionID,
          reason: lookup.reason,
          elapsedMs: Date.now() - now,
          earlierEntry: earlier ? earlier.phase : "none",
        })
        if (earlier) {
          return (
            `This replacement was NOT queued (${lookup.reason}). ` +
            "The previously queued compaction and its earlier resumption prompt are still armed " +
            "and will run when this turn ends."
          )
        }
        return (
          "Compaction NOT queued: could not determine this session's model " +
          `(${lookup.reason}). Nothing will happen when this turn ends. ` +
          "Tell the user, and ask them to run /compact and then send your resumption prompt " +
          "(or call this tool again if the cause looks transient)."
        )
      }

      // Last-write-wins on duplicate calls within a session (acceptable for
      // MVP — see design doc "Risks for v2").
      deps.pending.set(toolCtx.sessionID, {
        prompt: args.prompt,
        model: lookup.model,
        phase: "awaitingTurnEnd",
        createdAt: now,
      })
      debug("tool.execute stash", {
        sessionID: toolCtx.sessionID,
        promptChars: args.prompt.length,
        pendingSize: deps.pending.size,
        modelSource: lookup.source,
        lookupMs: Date.now() - now,
      })
      return "Compaction queued; will run when this turn ends."
    },
  }
}

/**
 * Structural supertype matching any event the plugin bus may deliver. The
 * runtime hands us arbitrary events (opencode's plugin host invokes hooks
 * with `input as any`); the SDK's `Event` discriminated union is a
 * convenience type that's known to lag behind the runtime (pigeon's plugin
 * documents this). Typing the boundary wider than the SDK union avoids
 * pretending the union is closed.
 */
export type PluginBusEvent = {
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

/**
 * Narrows a `PluginBusEvent` to a `session.status` event whose status is
 * `idle`. The discriminator inside `properties.status` is `type` (per
 * `~/projects/opencode/packages/opencode/src/session/status.ts:9-21`),
 * NOT `status` — easy to confuse because the outer property holding the
 * status object is also called `status`. The v1 design doc finding #7
 * captured an earlier instance of this footgun.
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

export function createOnCompacted(deps: {
  pending: Map<string, PendingResume>
  callPromptAsync: (input: { sessionID: string; text: string }) => Promise<void>
  /**
   * Resolves true once the session's runner is idle, false on timeout.
   *
   * This is the v3 deadlock/discard fix. `session.compacted` is published from
   * INSIDE the still-running compaction loop (compaction.ts publishes Event.Compacted
   * mid-`runLoop`), so at the instant we receive it the session's `Runner` is still
   * in state `Running`. If we fired `prompt_async` now, `Runner.ensureRunning`
   * (opencode effect/runner.ts) would hit its `Running` branch, which awaits the
   * existing run and SILENTLY DISCARDS the new loop — the resumption message would be
   * persisted but never processed (the 1.17.2 regression). Waiting for idle guarantees
   * `ensureRunning` hits the `Idle` branch and starts a fresh loop.
   *
   * Polling the authoritative status (rather than waiting for an idle bus EVENT) makes
   * this order-independent: the loop-end `session.status: idle` event and this
   * `session.compacted` event are published nearly simultaneously and can be delivered
   * to the plugin in either order, so an event-driven "fire on next idle" approach would
   * intermittently miss.
   */
  waitForIdle: (input: { sessionID: string }) => Promise<boolean>
}) {
  return async ({ event }: { event: PluginBusEvent }) => {
    if (event.type === "session.compacted") {
      debug("onCompacted event observed", {
        sessionID:
          (event.properties as { sessionID?: string } | undefined)?.sessionID ?? "unknown",
        pendingSize: deps.pending.size,
        pendingKeys: Array.from(deps.pending.keys()),
      })
    }
    if (!isSessionCompacted(event)) return
    const { sessionID } = event.properties
    const entry = deps.pending.get(sessionID)
    if (!entry) {
      debug("onCompacted no-entry", { sessionID, pendingSize: deps.pending.size })
      return
    }
    if (entry.phase === "resuming") {
      // A poll for this entry is already running (or it is deferred to the next
      // idle). A second compacted event must not start a second delivery path.
      debug("onCompacted skip already-resuming", { sessionID, deferred: !!entry.deferred })
      return
    }
    // Mark synchronously BEFORE any await. From here the entry is claimable by
    // either the poll below or onStatus's idle event; each claims by deleting it
    // synchronously, so only one delivers. If delivery later fails the entry is
    // still gone (no automatic retry; the agent re-invokes the skill).
    entry.phase = "resuming"

    debug("onCompacted waiting for idle", { sessionID })
    const idle = await deps.waitForIdle({ sessionID })
    if (deps.pending.get(sessionID) !== entry) {
      // Claimed by onStatus's idle event while we polled, or replaced by a newer
      // self_compact_and_resume call. Either way it is not ours to touch.
      debug("onCompacted stand down (entry claimed or replaced)", { sessionID, idle })
      return
    }
    if (!idle) {
      // Another prompt (in the 2026-10-31 incident, a swarm message that reached
      // prompt_async 26 ms before the compaction loop ended) started a turn right
      // after compaction, and that turn can run for hours. Firing now would race
      // that run (see waitForIdle above), and dropping the prompt -- what v3-v4
      // did -- loses it silently. Keep it armed: onStatus delivers it on the
      // session's next idle, which is the same safe point summarize fires at.
      entry.deferred = true
      debug("onCompacted deferred to next idle (session busy after compaction)", { sessionID })
      return
    }
    deps.pending.delete(sessionID)
    await deliverResume(deps.callPromptAsync, sessionID, entry, "onCompacted", { rethrow: true })
  }
}

async function deliverResume(
  callPromptAsync: (input: { sessionID: string; text: string }) => Promise<void>,
  sessionID: string,
  entry: PendingResume,
  stage: string,
  opts: { rethrow: boolean },
): Promise<void> {
  const text = entry.deferred ? `${DEFERRED_RESUME_NOTE}\n\n${entry.prompt}` : entry.prompt
  debug(`${stage} firing prompt_async`, {
    sessionID,
    promptChars: text.length,
    deferred: !!entry.deferred,
  })
  try {
    await callPromptAsync({ sessionID, text })
    debug(`${stage} prompt_async OK`, { sessionID })
  } catch (err) {
    debug(`${stage} prompt_async FAILED`, { sessionID, error: errText(err) })
    if (opts.rethrow) throw err
  }
}

/**
 * Idle-triggered summarize handler, and (v5) the deferred-resume delivery.
 *
 * An idle session whose entry is `resuming` gets its resumption prompt now
 * (see createOnCompacted). Otherwise:
 *
 * When the session that just went idle has a pending entry in
 * `awaitingTurnEnd` phase, this handler:
 *
 *   1. Promotes the entry to `summarizing` synchronously (BEFORE awaiting
 *      anything) so a re-entrant idle event for the same session can't
 *      double-trigger.
 *   2. Fires `POST /summarize` with the model the tool resolved at execute
 *      time (v4; no HTTP model lookup here any more).
 *
 * On summarize throw the entry is evicted (no retry; the user re-invokes the
 * skill). On success, the entry is left in `summarizing` phase for
 * `createOnCompacted` to pop when the `session.compacted` bus event arrives.
 *
 * This is the deadlock-free path: by the time `SessionStatus.set(..., idle)`
 * publishes its bus event, the outer prompt loop has already cleared its
 * state, so our `loop()` call via `POST /summarize` gets a fresh start rather
 * than joining an existing loop's callback queue.
 */
export function createOnStatus(deps: {
  pending: Map<string, PendingResume>
  callSummarize: (input: {
    sessionID: string
    providerID: string
    modelID: string
  }) => Promise<void>
  /** Delivers a `resuming` entry (v5; see createOnCompacted). */
  callPromptAsync: (input: { sessionID: string; text: string }) => Promise<void>
}) {
  return async ({ event }: { event: PluginBusEvent }) => {
    if (!isSessionIdle(event)) return
    const { sessionID } = event.properties
    const entry = deps.pending.get(sessionID)
    if (!entry) return
    if (entry.phase === "resuming") {
      // Compaction is done and the session just went idle: deliver. Claim by
      // deleting synchronously so the status poll (or a re-entrant idle) can't
      // also deliver. An event hook must not throw, so failures are logged only.
      deps.pending.delete(sessionID)
      await deliverResume(deps.callPromptAsync, sessionID, entry, "onStatus", { rethrow: false })
      return
    }
    if (entry.phase !== "awaitingTurnEnd") {
      debug("onStatus skip non-awaiting", { sessionID, phase: entry.phase })
      return
    }

    // Promote phase synchronously BEFORE awaiting anything so a re-entrant
    // idle event for the same session can't double-trigger summarize.
    entry.phase = "summarizing"
    debug("onStatus idle promote", { sessionID, pendingSize: deps.pending.size })

    const model = entry.model
    if (!model?.providerID || !model?.modelID) {
      // Only reachable for an entry stashed by a pre-v4 tool in the same
      // process; never guess a model.
      debug("onStatus no-model evict", { sessionID })
      deps.pending.delete(sessionID)
      return
    }
    debug("onStatus firing summarize", {
      sessionID,
      providerID: model.providerID,
      modelID: model.modelID,
    })

    try {
      await deps.callSummarize({
        sessionID,
        providerID: model.providerID,
        modelID: model.modelID,
      })
      debug("onStatus summarize OK", { sessionID })
      // On success, leave the entry in 'summarizing' phase. The
      // session.compacted handler will pop it when compaction completes.
    } catch (err) {
      // Summarize failed; evict so the next idle doesn't retry. User
      // re-invokes the skill if they still want to compact.
      debug("onStatus summarize FAILED evict", {
        sessionID,
        error: errText(err),
      })
      deps.pending.delete(sessionID)
    }
  }
}


export interface CallContext {
  fetch: typeof fetch
  serverUrl: URL
}

export async function callSummarizeHttp(
  ctx: CallContext,
  input: { sessionID: string; providerID: string; modelID: string },
): Promise<void> {
  // No client-side timeout. POST /summarize is a long-running synchronous
  // endpoint: the server runs the prompt loop to completion (multiple
  // minutes for long sessions). The 10s AbortSignal.timeout that lived
  // here in v1 was masking the deadlock; with the deadlock fixed in v2,
  // the timeout would just spuriously cancel legitimate long
  // summarizations. Pigeon's daemon does the same — no timeout.
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/summarize`, ctx.serverUrl)
  debug("callSummarizeHttp request", { sessionID: input.sessionID, url: url.pathname })
  const res = await ctx.fetch(
    new Request(url.toString(), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        providerID: input.providerID,
        modelID: input.modelID,
        auto: false,
      }),
    }),
  )
  debug("callSummarizeHttp response", { sessionID: input.sessionID, status: res.status })
  if (!res.ok) throw new Error(`summarize failed: ${res.status} ${await res.text()}`)
}

/**
 * Polls `GET /session/status` until the given session's runner is idle.
 *
 * The status endpoint returns a `Record<sessionID, { type: "idle" | "busy" | "retry" }>`.
 * A session that is ABSENT from the map has no live runner, which is also idle (the
 * runner deletes itself on idle). Returns true the first time the session reads idle,
 * or false after `attempts` polls. A failed/malformed status read is treated as
 * "unknown — keep polling" so we never fire prematurely.
 *
 * IMPORTANT: `/session/status` has no sessionID in its path, so opencode's
 * workspace-routing scopes it by the `directory` query param (falling back to the
 * serve's process.cwd() — the wrong instance — if absent). The plugin's fetch does NOT
 * inject a directory the way the SDK client would (in serve mode it is plain
 * globalThis.fetch over loopback TCP, not the in-process app.fetch), so we MUST pass the
 * compacted session's directory explicitly (the plugin supplies ctx.directory, which the
 * plugin host guarantees equals the session's directory). Without it the map comes back
 * empty and we'd treat the session as idle immediately — defeating the whole fix.
 */
export async function waitForSessionIdleHttp(
  ctx: CallContext,
  input: {
    sessionID: string
    directory?: string
    attempts?: number
    intervalMs?: number
    sleep?: (ms: number) => Promise<void>
  },
): Promise<boolean> {
  const attempts = input.attempts ?? DEFAULT_IDLE_POLL_ATTEMPTS
  const intervalMs = input.intervalMs ?? DEFAULT_IDLE_POLL_INTERVAL_MS
  const sleep = input.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  const url = new URL("/session/status", ctx.serverUrl)
  if (input.directory) url.searchParams.set("directory", input.directory)

  for (let i = 0; i < attempts; i++) {
    let idle = false
    try {
      const res = await ctx.fetch(new Request(url.toString(), { method: "GET" }))
      if (res.ok) {
        const parsed = await res.json()
        if (parsed && typeof parsed === "object") {
          const status = (parsed as Record<string, { type?: string } | undefined>)[input.sessionID]
          // Absent session = no runner = idle; otherwise idle iff type === "idle".
          idle = !status || status.type === "idle"
        }
      }
    } catch {
      // Treat a read failure as "unknown"; keep polling rather than firing.
      idle = false
    }
    if (idle) {
      debug("waitForSessionIdle idle", { sessionID: input.sessionID, attempt: i })
      return true
    }
    if (i < attempts - 1) await sleep(intervalMs)
  }
  debug("waitForSessionIdle timeout", { sessionID: input.sessionID, attempts })
  return false
}

export async function callPromptAsyncHttp(
  ctx: CallContext,
  input: { sessionID: string; text: string },
): Promise<void> {
  const url = new URL(`/session/${encodeURIComponent(input.sessionID)}/prompt_async`, ctx.serverUrl)
  debug("callPromptAsyncHttp request", {
    sessionID: input.sessionID,
    url: url.pathname,
    textChars: input.text.length,
  })
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
  debug("callPromptAsyncHttp response", { sessionID: input.sessionID, status: res.status })
  if (!res.ok) throw new Error(`prompt_async failed: ${res.status} ${await res.text()}`)
}
