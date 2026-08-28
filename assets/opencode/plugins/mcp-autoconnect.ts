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
 * Statuses that mean "connecting again cannot help". `needs_auth` and
 * `needs_client_registration` require a human to complete an OAuth flow
 * (`mcp/index.ts` create() -> UnauthorizedError), so retrying only re-raises
 * the "MCP Authentication Required" toast on every single user message.
 */
const UNREACHABLE_STATUSES = new Set(["needs_auth", "needs_client_registration"])

/**
 * Servers eligible for AUTOMATIC reconnection: those the global config gates
 * off with a `<name>_*` deny.
 *
 * This restriction is the safety property of the whole plugin, and it is not
 * cosmetic. Connecting is per-DIRECTORY, so a reconnect exposes a server's
 * tools to every session in that directory. For a gated server that is
 * harmless -- `resolveTools` (session/llm/request.ts) strips the tools again
 * from any session without its own `<name>_*` allow rule, so exposure stays
 * session-scoped. For an UNGATED server it is not harmless at all: the tools
 * land in every co-directory session's request, which for `pagerduty_*` and
 * `datadog_*` means every Vertex-Gemini turn in that directory 400s on the
 * tool schema (see .opencode/skills/opencode-agents/SKILL.md).
 *
 * That hazard is live, not theoretical: grants never expire, and this box's
 * session DB currently holds 85 sessions with a `datadog_*` allow rule across
 * 22 directories. Without this gate, one scheduled wake to any one of them
 * would reconnect datadog for its whole directory -- permanently, since the
 * plugin would also defeat the serve restart and the explicit `disconnect`
 * that are today's only ways out.
 *
 * To opt a server in, add `"<name>_*": false` to the `tools` map in
 * assets/opencode/opencode.base.json. That is the same edit that makes its
 * exposure session-scoped in the first place, so the two cannot drift apart.
 */
function reconnectable(config: { tools?: Record<string, unknown>; permission?: Record<string, unknown> }): Set<string> {
  const names = new Set<string>()
  for (const [key, value] of Object.entries(config?.tools ?? {})) {
    if (value === false && key.endsWith("_*")) names.add(key.slice(0, -2))
  }
  for (const [key, value] of Object.entries(config?.permission ?? {})) {
    if (value === "deny" && key.endsWith("_*")) names.add(key.slice(0, -2))
  }
  return names
}

/**
 * Servers this session is granted, eligible for auto-reconnect, and not
 * connected in this directory right now.
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
function pendingReconnects(ruleset: Rule[], statuses: StatusMap, eligible: Set<string>): string[] {
  const out: string[] = []
  for (const name of Object.keys(statuses)) {
    if (!eligible.has(name)) continue
    const status = statuses[name]?.status
    if (status === "connected") continue
    if (status && UNREACHABLE_STATUSES.has(status)) continue
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
  /**
   * The eligible set, resolved once. Safe to cache for the life of the plugin:
   * the plugin itself lives in per-directory `InstanceState`, and the only way
   * config changes at runtime is `POST /config`, which disposes the instance
   * (handlers/config.ts `markInstanceForDisposal`) and so rebuilds this plugin.
   */
  let eligible: Set<string> | undefined

  const readStatuses = async (): Promise<StatusMap> => {
    const res: any = await withTimeout<any>(client.mcp.status(), READ_TIMEOUT_MS, "mcp status")
    return res?.data ?? {}
  }

  async function connectOnce(name: string, sessionID: string) {
    const existing = inflight.get(name)
    if (existing) return existing
    const attempt = (async () => {
      try {
        await withTimeout(client.mcp.connect({ path: { name } }), CONNECT_TIMEOUT_MS, `mcp connect ${name}`)
        // A resolved promise is NOT success. `MCP.create` swallows a failed
        // handshake into a *status* (mcp/index.ts create()), the route returns
        // a bare `true` either way (handlers/mcp.ts connect()), and the hey-api
        // SDK defaults to ThrowOnError=false so even a 5xx resolves. Re-read
        // the status map -- otherwise a permanently broken server (bad token,
        // missing binary, hung `npx` fetch) is retried on EVERY user message,
        // spawning a child process each time, which is exactly what the
        // cooldown below exists to prevent.
        const after = await readStatuses()
        if (after[name]?.status === "connected") {
          cooldown.delete(name)
          console.error(`[mcp-autoconnect] reconnected MCP server "${name}" for ${sessionID} in ${ctx.directory}`)
        } else {
          cooldown.set(name, Date.now())
          console.error(
            `[mcp-autoconnect] connect returned but MCP server "${name}" is ${after[name]?.status ?? "missing"} ` +
              `(session ${sessionID}, ${ctx.directory}); backing off ${RETRY_COOLDOWN_MS}ms`,
          )
        }
      } catch (error) {
        cooldown.set(name, Date.now())
        console.error(
          `[mcp-autoconnect] failed to reconnect MCP server "${name}" for ${sessionID}: ${String(error)}`,
        )
      } finally {
        inflight.delete(name)
      }
    })()
    inflight.set(name, attempt)
    return attempt
  }

  async function reconcile(sessionID: string) {
    if (!eligible) {
      const cfg: any = await withTimeout<any>(client.config.get(), READ_TIMEOUT_MS, "config get")
      eligible = reconnectable(cfg?.data ?? {})
    }
    // No gated server configured on this host (devbox has no slack): nothing
    // this plugin is allowed to reconnect, so never touch the session at all.
    if (eligible.size === 0) return

    const statuses = await readStatuses()
    const candidates = [...eligible].filter((name) => {
      // `MCP.status` reports every CONFIGURED server, so a name missing from
      // the map is gated in config but not configured on this host -- there is
      // nothing to connect.
      if (!(name in statuses)) return false
      const status = statuses[name]?.status
      return status !== "connected" && !(status && UNREACHABLE_STATUSES.has(status))
    })
    // Everything we are allowed to reconnect is already up (or unreachable
    // without a human): skip the session read. Note this does NOT fire in the
    // common cold case -- slack ships `enabled: false`, so on a fresh instance
    // it is `disabled` and we do read the session row. The steady cost of this
    // hook is therefore two loopback HTTP calls per user message on a host with
    // slack configured, and zero on one without.
    if (candidates.length === 0) return

    const session: any = await withTimeout<any>(
      client.session.get({ path: { id: sessionID } }),
      READ_TIMEOUT_MS,
      "session get",
    )
    const ruleset: Rule[] = session?.data?.permission ?? []
    if (ruleset.length === 0) return

    const now = Date.now()
    const wanted = pendingReconnects(ruleset, statuses, eligible).filter((name) => {
      const last = cooldown.get(name)
      return last === undefined || now - last >= RETRY_COOLDOWN_MS
    })
    if (wanted.length === 0) return

    // Serial, not concurrent: reconnects are rare (once per serve restart per
    // server) and this runs on the critical path of a user turn, so bounding
    // the worst case at a predictable sum beats saving a second.
    for (const name of wanted) await connectOnce(name, sessionID)
  }

  return {
    "chat.message": async (input) => {
      try {
        await reconcile(input.sessionID)
      } catch (error) {
        // Never let a reconnect failure become a defect: plugin.trigger wraps
        // this in Effect.promise, where a rejection dies the whole turn.
        console.error(`[mcp-autoconnect] reconcile failed for ${input.sessionID}: ${String(error)}`)
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

export const internals = {
  pendingReconnects,
  reconnectable,
  withTimeout,
  READ_TIMEOUT_MS,
  CONNECT_TIMEOUT_MS,
  RETRY_COOLDOWN_MS,
}
