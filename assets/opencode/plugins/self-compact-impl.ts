import type { EventSessionCompacted } from "@opencode-ai/sdk"

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
