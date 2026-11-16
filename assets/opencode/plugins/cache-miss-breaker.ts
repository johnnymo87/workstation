import type { Plugin } from "@opencode-ai/plugin"

/**
 * Stop a Gemini subagent whose prompt cache has stopped hitting, before it
 * burns tens of dollars re-reading its whole context at full price every step.
 *
 * Why (workstation-ke9f): on 2026-11-16 four gemini-3.8-flash implementer
 * subagents each got stuck at cache_read=0 for dozens to hundreds of steps
 * while concurrent sessions on the same serve, model and endpoint hit 97-99%.
 * Stuck steps did not even hit the ~36K system+tools prefix every session
 * shares, so it is per-session on Vertex's side. A stuck session usually
 * stays stuck (3 of 10 backtest trips recovered, after 13 to 145 more steps). About $117 of that day's $170 on those four was the miss
 * penalty; one session (S7a) missed from its second step to its last, $44.
 *
 * What it does: count consecutive steps whose context (input + cache read +
 * cache write) is at least MIN_CONTEXT and whose cache read is 0. At
 * TRIP_STEPS in a row, stop the session, but only if it is a subagent (has a
 * parent) running a Gemini model. Claude caching is explicit, and a top-level
 * session has a human or coordinator who should decide.
 *
 * Stopping is a drain, not an abort: every further tool call in that session
 * is refused (tool.execute.before) with a message telling the model to reply
 * with a summary and stop. Its Task call then completes normally, and
 * tool.execute.after rewrites the result into an error block that says why,
 * carries the summary, and tells the parent to dispatch the task again once (a
 * fresh session gets a fresh chance at the cache). An abort alone would be
 * worse: opencode 1.18's Task tool turns a cancelled child into a bare "Task
 * cancelled" tool error, which skips tool.execute.after and reads to the
 * parent like a human interrupt (verified live 2026-11-16). So abort is only
 * the backstop, after DRAIN_STEPS more steps of a child that keeps going.
 *
 * Fail-open everywhere: a lookup or abort that throws leaves the session alone.
 */

export const TRIP_STEPS = 10
export const MIN_CONTEXT = 50_000
/** Steps a stopped child may take to wrap up before it is aborted. */
export const DRAIN_STEPS = 3

type Tokens = { input: number; output?: number; reasoning?: number; cache: { read: number; write: number } }

type Streak = { count: number; cost: number; context: number; tripped: boolean }

export function createDetector() {
  const streaks = new Map<string, Streak>()
  return {
    /** Record one finished step; true exactly once, on the step that trips. */
    step(sessionID: string, tokens: Tokens, cost = 0): boolean {
      let s = streaks.get(sessionID)
      if (!s) streaks.set(sessionID, (s = { count: 0, cost: 0, context: 0, tripped: false }))
      if (s.tripped) return false
      const read = tokens.cache?.read ?? 0
      const context = (tokens.input ?? 0) + read + (tokens.cache?.write ?? 0)
      if (read > 0) {
        s.count = 0
        s.cost = 0
        return false
      }
      if (context < MIN_CONTEXT) return false
      s.count += 1
      s.cost += cost
      s.context = context
      if (s.count < TRIP_STEPS) return false
      s.tripped = true
      return true
    },
    streak(sessionID: string): Streak | undefined {
      return streaks.get(sessionID)
    },
  }
}

export interface Deps {
  abort: (sessionID: string) => Promise<void>
  parentOf: (sessionID: string) => Promise<string | undefined>
  log: (message: string) => void
}

const GEMINI = /^gemini/i

function makeHooks(deps: Deps) {
  const detector = createDetector()
  const model = new Map<string, string>()
  const stopped = new Map<string, Streak>()
  /** Steps taken since being stopped, for sessions still draining. */
  const drain = new Map<string, number>()
  /** Sessions that had a tool call refused: only their Task result becomes an error. */
  const refused = new Set<string>()
  /** provider/model pairs this process has seen a cache hit from; others never trip. */
  const caches = new Set<string>()

  async function trip(sessionID: string) {
    const streak = detector.streak(sessionID)!
    try {
      if (!(await deps.parentOf(sessionID))) return
      stopped.set(sessionID, { ...streak })
      drain.set(sessionID, 0)
      deps.log(
        `cache-miss-breaker: stopping ${sessionID} (${model.get(sessionID)}): ${streak.count} consecutive uncached steps at ~${Math.round(streak.context / 1000)}K context, $${streak.cost.toFixed(2)}`,
      )
    } catch {
      // fail open
    }
  }

  async function backstop(sessionID: string) {
    const n = (drain.get(sessionID) ?? 0) + 1
    drain.set(sessionID, n)
    if (n !== DRAIN_STEPS) return
    try {
      deps.log(`cache-miss-breaker: ${sessionID} kept going after being stopped; aborting it`)
      await deps.abort(sessionID)
    } catch {
      // fail open
    }
  }

  return {
    event: async ({ event }: { event: any }) => {
      try {
        if (event?.type === "message.updated") {
          const info = event.properties?.info
          if (info?.role === "assistant" && typeof info.modelID === "string") model.set(info.sessionID, `${info.providerID}/${info.modelID}`)
          return
        }
        if (event?.type !== "message.part.updated") return
        const part = event.properties?.part
        if (part?.type !== "step-finish" || !part.tokens) return
        const m = model.get(part.sessionID)
        if (!m || !GEMINI.test(m.split("/").pop()!)) return
        if ((part.tokens.cache?.read ?? 0) > 0) caches.add(m)
        if (drain.has(part.sessionID)) {
          // Only a step that tried to keep working counts: the summary step must not trigger the abort.
          if (part.reason === "tool-calls") await backstop(part.sessionID)
          return
        }
        // A model that has never reported a cache hit here may just not report cache.
        if (!caches.has(m)) return
        if (detector.step(part.sessionID, part.tokens, typeof part.cost === "number" ? part.cost : 0)) await trip(part.sessionID)
      } catch {
        // fail open
      }
    },

    "tool.execute.before": async (input: { tool: string; sessionID?: string }) => {
      const streak = input?.sessionID ? stopped.get(input.sessionID) : undefined
      if (!streak) return
      refused.add(input.sessionID!)
      throw new Error(
        [
          `STOPPED by the cache-miss breaker: your last ${streak.count} model calls got no prompt-cache hits, so each one re-reads your whole ~${Math.round(streak.context / 1000)}K context at full price.`,
          "Do not call any more tools; every call will be refused. Reply now, in text only, with what you completed (files, commits) and what remains. Your parent will re-dispatch the rest.",
        ].join("\n"),
      )
    },

    "tool.execute.after": async (input: { tool: string; args: any }, output: { title: string; output: string; metadata: any }) => {
      try {
        if (input?.tool !== "task" || !output) return
        const sessionID = output.metadata?.sessionId
        const streak = typeof sessionID === "string" ? stopped.get(sessionID) : undefined
        if (!streak) return
        // Tripped on its final step: it finished, so keep the result and only note it.
        if (!refused.has(sessionID)) {
          output.output = output.output.replace(/<\/task_result>\n<\/task>$/, `\n(cache-miss breaker: this session's last ${streak.count} model calls got no prompt-cache hits; it finished anyway.)\n</task_result>\n</task>`)
          return
        }
        const agent = typeof input.args?.subagent_type === "string" ? input.args.subagent_type : "the subagent"
        const partial = /<task_result>\n([\s\S]*)\n<\/task_result>/.exec(output.output ?? "")?.[1]?.trim()
        output.output = [
          `<task id="${sessionID}" state="error">`,
          "<task_error>",
          `Subagent "${agent}" was STOPPED by the cache-miss breaker: its last ${streak.count} model calls got no prompt-cache hits at ~${Math.round(streak.context / 1000)}K context ($${streak.cost.toFixed(2)} for those calls).`,
          "This is almost certainly a Vertex-side fault that sticks to one session (workstation-ke9f), not something wrong with the task. Its work is UNFINISHED; check its worktree for partial edits or commits before continuing.",
          "Dispatch it again ONCE as a NEW task: do NOT pass task_id (this session refuses all tools). Give the same prompt plus what it already did, and write \"re-dispatch #1 after cache-miss breaker\" in it. If that session is stopped too, do not dispatch a third time: report it.",
          ...(partial ? ["--- its last output (its own summary, if it complied) ---", partial] : []),
          "</task_error>",
          "</task>",
        ].join("\n")
      } catch {
        // fail open
      }
    },
  }
}

const plugin: Plugin = async (ctx) =>
  makeHooks({
    abort: async (id) => {
      await (ctx.client as any).session.abort({ path: { id } })
    },
    parentOf: async (id) => {
      const res = await (ctx.client as any).session.get({ path: { id }, signal: AbortSignal.timeout(5_000) })
      const parentID = res?.data?.parentID
      return typeof parentID === "string" && parentID ? parentID : undefined
    },
    log: (message) => {
      void (ctx.client as any).app?.log?.({ body: { service: "cache-miss-breaker", level: "warn", message } })?.catch?.(() => {})
    },
  }) as any

/** v1 plugin shape: see subagent-failure.ts and test/plugin-loader-contract.test.ts. */
export default { id: "cache-miss-breaker", server: plugin }

export const internals = { makeHooks, createDetector, TRIP_STEPS, MIN_CONTEXT, DRAIN_STEPS }
