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

export function createOnCompacted(deps: {
  pending: Map<string, PendingResume>
  callPromptAsync: (input: { sessionID: string; text: string }) => Promise<void>
}) {
  return async (input: { event: { type: string; properties?: { sessionID?: string } } }) => {
    if (input.event.type !== "session.compacted") return
    const sessionID = input.event.properties?.sessionID
    if (!sessionID) return
    const entry = deps.pending.get(sessionID)
    if (!entry) return
    try {
      await deps.callPromptAsync({ sessionID, text: entry.prompt })
    } finally {
      deps.pending.delete(sessionID)
    }
  }
}
