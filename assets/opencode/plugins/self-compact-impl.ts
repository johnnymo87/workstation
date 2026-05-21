import type { EventSessionCompacted } from "@opencode-ai/sdk"
import { appendFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

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

const STALE_MS = 30 * 60 * 1000

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
  /**
   * State machine discriminator.
   *
   * - `awaitingTurnEnd`: the tool has stashed the entry; the onStatus handler
   *   is waiting for the session to go idle so it can fire POST /summarize.
   * - `summarizing`: onStatus has fired summarize; the entry is held until
   *   onCompacted pops it and enqueues the resumption prompt.
   *
   * Without this field, onStatus cannot distinguish "first idle after queue"
   * (should fire summarize) from "second idle while summarize is in flight"
   * (must not double-trigger). See addendum to v1 design doc for rationale.
   */
  phase: "awaitingTurnEnd" | "summarizing"
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
 * v2 tool: stash-and-return.
 *
 * The tool's only job is to record the resumption prompt under the current
 * session's ID and return immediately. The actual `POST /summarize` trigger
 * lives in `createOnStatus`, which fires when the session goes idle (i.e.,
 * after this turn — and any nested tool calls — closes).
 *
 * This is the deadlock fix from v1: calling `POST /summarize` from inside a
 * tool's `execute` causes mutual await with the outer prompt loop. By doing
 * nothing but a Map insert here, we cannot deadlock.
 */
export function createSelfCompactTool(deps: {
  pending: Map<string, PendingResume>
}) {
  return {
    async execute(args: { prompt: string }, toolCtx: { sessionID: string }): Promise<string> {
      const now = Date.now()
      // Evict stale entries so the Map doesn't grow without bound across the
      // process lifetime. 30 minutes is generous; a real compaction takes
      // seconds to a few minutes.
      for (const [sid, entry] of deps.pending) {
        if (now - entry.createdAt > STALE_MS) deps.pending.delete(sid)
      }
      // Last-write-wins on duplicate calls within a session (acceptable for
      // MVP — see design doc "Risks for v2").
      deps.pending.set(toolCtx.sessionID, {
        prompt: args.prompt,
        phase: "awaitingTurnEnd",
        createdAt: now,
      })
      debug("tool.execute stash", {
        sessionID: toolCtx.sessionID,
        promptChars: args.prompt.length,
        pendingSize: deps.pending.size,
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
    // Remove the entry synchronously BEFORE the await so a re-entrant
    // session.compacted event for the same session doesn't observe it
    // and double-deliver. If callPromptAsync throws, the entry is still
    // gone — matches MVP design (no automatic retry; user re-invokes the
    // skill if the prompt fails to deliver).
    deps.pending.delete(sessionID)
    debug("onCompacted firing prompt_async", { sessionID, promptChars: entry.prompt.length })
    try {
      await deps.callPromptAsync({ sessionID, text: entry.prompt })
      debug("onCompacted prompt_async OK", { sessionID })
    } catch (err) {
      debug("onCompacted prompt_async FAILED", {
        sessionID,
        error: err instanceof Error ? err.message : String(err),
      })
      throw err
    }
  }
}

/**
 * v2 idle-triggered summarize handler.
 *
 * When the session that just went idle has a pending entry in
 * `awaitingTurnEnd` phase, this handler:
 *
 *   1. Promotes the entry to `summarizing` synchronously (BEFORE awaiting
 *      anything) so a re-entrant idle event for the same session can't
 *      double-trigger.
 *   2. Looks up the session's active model.
 *   3. Fires `POST /summarize` from the now-idle session.
 *
 * On model lookup failure or summarize throw, the entry is evicted (no
 * retry; the user re-invokes the skill). On success, the entry is left in
 * `summarizing` phase for `createOnCompacted` to pop when the
 * `session.compacted` bus event arrives.
 *
 * This is the deadlock-free path: by the time `SessionStatus.set(..., idle)`
 * publishes its bus event, the outer prompt loop has already cleared its
 * `prompt.ts` state (`prompt.ts:265-267`), so our subsequent `loop()` call
 * via `POST /summarize` gets a fresh `start(sessionID)` signal rather than
 * joining an existing loop's callback queue. See addendum to v1 design doc
 * for the full RCA.
 */
export function createOnStatus(deps: {
  pending: Map<string, PendingResume>
  callSummarize: (input: {
    sessionID: string
    providerID: string
    modelID: string
  }) => Promise<void>
  findActiveModel: (input: {
    sessionID: string
  }) => Promise<{ providerID: string; modelID: string } | null>
}) {
  return async ({ event }: { event: PluginBusEvent }) => {
    if (!isSessionIdle(event)) return
    const { sessionID } = event.properties
    const entry = deps.pending.get(sessionID)
    if (!entry) return
    if (entry.phase !== "awaitingTurnEnd") {
      debug("onStatus skip non-awaiting", { sessionID, phase: entry.phase })
      return
    }

    // Promote phase synchronously BEFORE awaiting anything so a re-entrant
    // idle event for the same session can't double-trigger summarize.
    entry.phase = "summarizing"
    debug("onStatus idle promote", { sessionID, pendingSize: deps.pending.size })

    const model = await deps.findActiveModel({ sessionID })
    if (!model) {
      // No model means we can't proceed; evict the entry. User will re-invoke
      // the skill if they still want to compact.
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
        error: err instanceof Error ? err.message : String(err),
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
