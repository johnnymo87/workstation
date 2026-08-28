import type { Plugin } from "@opencode-ai/plugin"

/**
 * mcp-autoconnect -- re-establish MCP client connections that a session was
 * already granted, at the START of the turn that needs them.
 *
 * THE BUG THIS FIXES (see docs/plans/2026-08-28-mcp-grant-liveness.md for the
 * full source walk). Granting an MCP server to a running session is two
 * operations with two DIFFERENT lifetimes:
 *
 *   1. `POST /mcp/<name>/connect` -- spawns the MCP client. Lives in opencode's
 *      per-DIRECTORY `InstanceState` on the serve process that owns the
 *      session (mcp/index.ts `State.clients`). It is process memory: it dies
 *      with a serve restart, an instance dispose (`POST /config` update,
 *      `POST /instance/dispose`) or a project/worktree reload.
 *   2. `PATCH /session/<id> {permission:[{permission:"<name>_*",...allow}]}` --
 *      a row in SQLite (`session.permission`). Durable forever.
 *
 * So the grant outlives the connection. After any serve restart the session
 * still *says* it may use `slack_*` while there is no slack client behind it,
 * and the tools silently vanish -- which is why long-running sessions on this
 * box accumulate three, five, six identical `slack_*` allow rules: one per
 * manual `oc-mcp-enable` re-run.
 *
 * THE FIX. `session.permission` is exactly the durable record of "this session
 * was granted <name>". This hook reads it back at `chat.message` and reconnects
 * anything granted-but-not-connected. No new state store, and revocation is
 * honoured for free (`oc-mcp-enable --revoke` appends a `deny`, which is then
 * the last matching rule).
 *
 * WHY `chat.message` AND NOT AN EVENT HOOK. Timing is the whole point. The
 * ordering in session/prompt.ts is:
 *
 *     prompt()
 *       -> createUserMessage()  ->  plugin.trigger("chat.message")   <-- HERE
 *       -> loop() -> runLoop()
 *            const session = yield* sessions.get(sessionID)   // permission SNAPSHOT
 *            while (true) { ... SessionTools.resolve(...) ... }
 *
 * `plugin.trigger` is awaited, and this hook runs BEFORE runLoop takes its
 * `session` snapshot and before step 1 resolves tools -- so a connection made
 * here is live for the CURRENT turn, not the next one. An `event` hook is
 * fire-and-forget and would race that snapshot.
 *
 * FAILURE POLICY. `plugin.trigger` wraps hooks in `Effect.promise`, so a
 * rejected promise is a DEFECT that kills the turn. Every path here is
 * therefore swallowed: a reconnect that cannot happen must degrade to "no
 * slack tools this turn", never to "your prompt died".
 */

type Rule = { permission?: string; pattern?: string; action?: string }
type StatusMap = Record<string, { status?: string } | undefined>

/** Bound on the two cheap in-process reads (session row, MCP status map). */
const READ_TIMEOUT_MS = 5_000
/** Bound on a connect. A stdio server shells out to npx/uvx, so seconds. */
const CONNECT_TIMEOUT_MS = 60_000
/** Do not re-attempt a server that just failed on every single message. */
const RETRY_COOLDOWN_MS = 60_000

/**
 * Servers this session is granted but which are not connected in this
 * directory right now.
 *
 * Grant detection is EXACT-STRING on `<name>_*`, deliberately, rather than a
 * reimplementation of opencode's `Wildcard.match`. That is the literal rule
 * shape both grant paths emit -- `oc-mcp-enable` (build_permission_json) and
 * `opencode-launch --mcp` (the prompt `tools` map, which prompt.ts converts to
 * `{permission: "<name>_*", pattern: "*", action: "allow"}`). Matching only
 * what our own tooling writes keeps this from guessing at a hand-written
 * ruleset it has no business auto-acting on.
 *
 * Last matching rule wins, mirroring `Permission.evaluate`'s `findLast`.
 */
function pendingReconnects(ruleset: Rule[], statuses: StatusMap): string[] {
  const out: string[] = []
  for (const name of Object.keys(statuses)) {
    if (statuses[name]?.status === "connected") continue
    let granted = false
    for (const rule of ruleset) {
      if (rule?.permission !== `${name}_*`) continue
      granted = rule.action === "allow"
    }
    if (granted) out.push(name)
  }
  return out.sort()
}

function withTimeout<T>(work: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms)
    work.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error) => {
        clearTimeout(timer)
        reject(error)
      },
    )
  })
}

const plugin: Plugin = async (ctx) => {
  const client = ctx.client as any

  /** name -> epoch ms of the last attempt that did not end connected. */
  const cooldown = new Map<string, number>()
  /**
   * name -> in-flight connect. Two sessions in the same directory can prompt at
   * the same time, and both would otherwise fire a connect for the same server;
   * `createAndStore` would spawn two clients and close one, for no reason.
   */
  const inflight = new Map<string, Promise<void>>()

  async function connectOnce(name: string) {
    const existing = inflight.get(name)
    if (existing) return existing
    const attempt = (async () => {
      try {
        await withTimeout(client.mcp.connect({ path: { name } }), CONNECT_TIMEOUT_MS, `mcp connect ${name}`)
        cooldown.delete(name)
        console.error(`[mcp-autoconnect] reconnected MCP server "${name}" in ${ctx.directory}`)
      } catch (error) {
        cooldown.set(name, Date.now())
        console.error(`[mcp-autoconnect] failed to reconnect MCP server "${name}": ${String(error)}`)
      } finally {
        inflight.delete(name)
      }
    })()
    inflight.set(name, attempt)
    return attempt
  }

  async function reconcile(sessionID: string) {
    const status: any = await withTimeout<any>(client.mcp.status(), READ_TIMEOUT_MS, "mcp status")
    const statuses: StatusMap = status?.data ?? {}
    // Everything configured is already up: skip the session read entirely.
    // This is the common case on a warm serve, and keeps the added cost of the
    // hook at one in-process call per user message.
    if (!Object.values(statuses).some((s) => s?.status !== "connected")) return

    const session: any = await withTimeout<any>(
      client.session.get({ path: { id: sessionID } }),
      READ_TIMEOUT_MS,
      "session get",
    )
    const ruleset: Rule[] = session?.data?.permission ?? []
    if (ruleset.length === 0) return

    const now = Date.now()
    const wanted = pendingReconnects(ruleset, statuses).filter((name) => {
      const last = cooldown.get(name)
      return last === undefined || now - last >= RETRY_COOLDOWN_MS
    })
    if (wanted.length === 0) return

    // Serial, not concurrent: reconnects are rare (once per serve restart per
    // server) and this runs on the critical path of a user turn, so bounding
    // the worst case at a predictable sum beats saving a second.
    for (const name of wanted) await connectOnce(name)
  }

  return {
    "chat.message": async (input) => {
      try {
        await reconcile(input.sessionID)
      } catch (error) {
        // Never let a reconnect failure become a defect: plugin.trigger wraps
        // this in Effect.promise, where a rejection dies the whole turn.
        console.error(`[mcp-autoconnect] reconcile failed: ${String(error)}`)
      }
    },
  }
}

/**
 * v1 plugin shape. `readV1Plugin` takes the default-export object and
 * `applyPlugin` returns before it ever reaches `getLegacyPlugins`, which throws
 * `Plugin export is not a function` on the first named export that is not a
 * function -- rejecting the WHOLE FILE, with one log line and an otherwise
 * healthy serve. The `internals` export below is only safe because of this.
 * See the longer rationale in shell-env.ts, which that failure actually hit.
 *
 * `id` is mandatory: resolvePluginId() throws `Path plugin ... must export id`
 * for file-sourced plugins without one (shared.ts:313-316).
 */
export default { id: "mcp-autoconnect", server: plugin }

export const internals = { pendingReconnects, withTimeout, READ_TIMEOUT_MS, CONNECT_TIMEOUT_MS, RETRY_COOLDOWN_MS }
