import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"

/**
 * Make a subagent whose model is unavailable FAIL LOUDLY in the parent's Task
 * call, instead of hanging or coming back as an empty "completed" result.
 *
 * Design + evidence: docs/plans/2026-10-01-reviewer-fail-fast-design.md.
 *
 * Two hooks, both scoped to the `task` tool:
 *
 * 1. tool.execute.before -- pre-dispatch probe. For an `*-astra` agent, run
 *    `astra-probe` (the one source of truth for "can astra be dispatched via
 *    codex-lb"). On DOWN (exit 1) throw, so the Task call fails in seconds with
 *    a message naming the `-opus` twin. This is the common outage (every
 *    codex-lb account usage-limited), and refusing BEFORE dispatch matters:
 *    codex-lb never notices a client disconnect while it waits for an account,
 *    so every timed-out attempt otherwise leaves a request parked in codex-lb for
 *    up to 2h that fires upstream when the account recovers.
 *    UP (0), UNKNOWN (2), a missing binary or a timeout all FAIL OPEN: the probe
 *    is advisory, and the provider headerTimeout + hook 2 remain the backstop.
 *
 * 2. tool.execute.after -- surface the child's error. opencode 1.18.18's task
 *    tool returns the child's last text part and never consults the child
 *    message's `error`, so a child that died on an API error reads as
 *    `state="completed"` with an empty (or truncated) <task_result>. Look up the
 *    child's newest message; if it carries an error, rewrite the output into a
 *    `state="error"` <task_error> block that says it is not a result and names
 *    the fallback. Lookup failures leave the output untouched (fail-open).
 */

/** Twin slugs that have a `<base>-opus` sibling. Explicit on purpose: a generic
 * "<base>-<slug>" rule would turn `code-reviewer` into a nonexistent `code-opus`. */
const TWIN_SUFFIX = /^(.+)-(astra|fable)$/

/** astra-probe does two curls with --max-time 5 each. */
const PROBE_TIMEOUT_MS = 12_000
/** Bound the loopback lookup so a wedged serve cannot reintroduce an open-ended wait. */
const LOOKUP_TIMEOUT_MS = 5_000

export function fallbackAgent(agent: string): string | undefined {
  const m = TWIN_SUFFIX.exec(agent)
  return m ? `${m[1]}-opus` : undefined
}

type ProbeResult = { code: number | null; message: string }
type ChildMessage = { info: { role?: string; error?: unknown }; parts: Array<{ type?: string; text?: string }> }

export interface Deps {
  probe: () => Promise<ProbeResult>
  lastMessage: (sessionID: string) => Promise<ChildMessage | undefined>
}

function errorText(error: unknown): string {
  if (error && typeof error === "object") {
    const e = error as { name?: unknown; data?: { message?: unknown }; message?: unknown }
    if (typeof e.data?.message === "string" && e.data.message) return e.data.message
    if (typeof e.message === "string" && e.message) return e.message
    if (typeof e.name === "string" && e.name) return e.name
  }
  return String(error)
}

function fallbackAdvice(agent: string): string {
  const twin = fallbackAgent(agent)
  if (twin) return `Dispatch "${twin}" with the same prompt instead, and say in one clause that ${agent} was unavailable.`
  // The -opus twin IS the fallback. Its failure means stop-and-report
  // (assets/opencode/AGENTS.md); suggesting "another agent" would steer the
  // parent back to astra (devbox) or to an opt-in twin (cloudbox).
  if (agent.endsWith("-opus"))
    return `Do not substitute another agent. Stop and report that this ${agent} dispatch did not happen.`
  return `Report the failure; do not proceed as if it had answered.`
}

const TASK_BLOCK = /^<task id="([^"]+)" state="completed">\n(?:<summary>[\s\S]*?<\/summary>\n)?<task_result>\n([\s\S]*)\n<\/task_result>\n<\/task>$/

function makeHooks(deps: Deps) {
  return {
    "tool.execute.before": async (input: { tool: string; sessionID?: string; callID?: string }, output: { args: any }) => {
      if (input.tool !== "task") return
      const agent = output.args?.subagent_type
      if (typeof agent !== "string" || !agent.endsWith("-astra")) return

      let result: ProbeResult
      try {
        result = await deps.probe()
      } catch {
        return // fail open
      }
      if (result.code !== 1) return

      throw new Error(
        [
          `${agent} was NOT dispatched: its model is unavailable right now.`,
          `astra-probe: ${result.message.trim() || "DOWN"}`,
          fallbackAdvice(agent),
        ].join("\n"),
      )
    },

    "tool.execute.after": async (
      input: { tool: string; sessionID?: string; callID?: string; args: any },
      output: { title: string; output: string; metadata: any },
    ) => {
      // `output` is undefined on the slash-command subtask path when the task
      // itself failed (prompt.ts handleSubtask). A throw here becomes an Effect
      // defect that aborts handleSubtask before it finishes the message, so the
      // subtask re-runs. Hence the guard, and the catch-all: fail-open must
      // cover this hook's own bugs, not just the lookup.
      if (input?.tool !== "task" || !output) return
      try {
        await rewriteFailedTask(input, output)
      } catch {
        // fail open
      }
    },
  }

  async function rewriteFailedTask(
    input: { args: any },
    output: { title: string; output: string; metadata: any },
  ) {
    if (output.metadata?.background === true) return
    const sessionID = output.metadata?.sessionId
    if (typeof sessionID !== "string") return
    const m = TASK_BLOCK.exec(output.output ?? "")
    if (!m) return

    let last: ChildMessage | undefined
    try {
      last = await deps.lastMessage(sessionID)
    } catch {
      return // fail open
    }
    if (!last || last.info?.role !== "assistant" || !last.info.error) return

    const agent = typeof input.args?.subagent_type === "string" ? input.args.subagent_type : "the subagent"
    const model = output.metadata?.model
    const modelRef = model?.providerID && model?.modelID ? ` (${model.providerID}/${model.modelID})` : ""
    const partial = m[2].trim()

    output.output = [
      `<task id="${m[1]}" state="error">`,
      "<task_error>",
      `Subagent "${agent}"${modelRef} FAILED: its model call errored: ${errorText(last.info.error)}`,
      partial
        ? "This is NOT a result: the text below is TRUNCATED output from before the failure. Do not treat it as a complete review or answer."
        : "This is NOT a result. It produced no output; do not treat it as a review or answer.",
      fallbackAdvice(agent),
      ...(partial ? ["--- truncated partial output ---", partial] : []),
      "</task_error>",
      "</task>",
    ].join("\n")
  }
}

function runAstraProbe(): Promise<ProbeResult> {
  return new Promise((resolve) => {
    execFile("astra-probe", [], { timeout: PROBE_TIMEOUT_MS }, (err, stdout, stderr) => {
      const message = `${stdout ?? ""}${stderr ?? ""}`.trim()
      if (!err) return resolve({ code: 0, message })
      // Numeric code = the probe's own exit status. ENOENT / killed-on-timeout
      // are not verdicts, so they map to null and fail open.
      const code = typeof (err as any).code === "number" && !(err as any).killed ? (err as any).code : null
      resolve({ code, message })
    })
  })
}

const plugin: Plugin = async (ctx) =>
  makeHooks({
    probe: runAstraProbe,
    lastMessage: async (id) => {
      const res = await (ctx.client as any).session.messages({
        path: { id },
        query: { limit: 1 },
        signal: AbortSignal.timeout(LOOKUP_TIMEOUT_MS),
      })
      const data = res?.data
      if (!Array.isArray(data) || data.length === 0) return undefined
      return data[data.length - 1] as ChildMessage
    },
  }) as any

/**
 * v1 plugin shape: applyPlugin returns before reaching getLegacyPlugins, so the
 * named `internals` export below cannot get the file rejected (see the longer
 * rationale in shell-env.ts and test/plugin-loader-contract.test.ts).
 */
export default { id: "subagent-failure", server: plugin }

export const internals = { makeHooks, fallbackAgent }
