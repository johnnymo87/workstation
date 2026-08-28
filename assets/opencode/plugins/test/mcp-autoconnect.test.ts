import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import pluginModule, { internals } from "../mcp-autoconnect"

// mcp-autoconnect.ts uses opencode's v1 plugin shape (`export default { id,
// server }`), which is what makes the `internals` named export safe: the loader
// takes the v1 branch and never inspects named exports. See the comment on the
// default export, and test/plugin-loader-contract.test.ts which enforces it.
const { pendingReconnects, reconnectable, RETRY_COOLDOWN_MS } = internals

type Rule = { permission?: string; pattern?: string; action?: string }

/** The rule shape `oc-mcp-enable`'s build_permission_json actually emits. */
const allow = (server: string): Rule => ({ permission: `${server}_*`, pattern: "*", action: "allow" })
const deny = (server: string): Rule => ({ permission: `${server}_*`, pattern: "*", action: "deny" })

/** The real gate, as shipped in assets/opencode/opencode.base.json. */
const BASE_CONFIG = { tools: { "slack_*": false, "slack-ro_*": false } }
const ELIGIBLE = reconnectable(BASE_CONFIG)

describe("reconnectable (which servers may be auto-reconnected at all)", () => {
  it("derives the eligible set from the global tools deny gate", () => {
    expect([...ELIGIBLE].sort()).toEqual(["slack", "slack-ro"])
  })

  it("accepts an equivalent gate written under `permission` instead of `tools`", () => {
    expect([...reconnectable({ permission: { "atlassian_*": "deny" } })]).toEqual(["atlassian"])
  })

  it("does NOT make an UNGATED server eligible", () => {
    // This is the safety property of the plugin. datadog/pagerduty are not in
    // the tools gate, and their tool schemas 400 the entire request on Vertex
    // Gemini. 85 sessions in the live DB carry a stale datadog_* allow rule; if
    // eligibility came from the grant alone, one message to any of them would
    // reconnect datadog for its whole directory and wedge every Gemini turn
    // there -- permanently, since this plugin also defeats the serve restart
    // and the explicit disconnect that are today's only ways out.
    expect(reconnectable(BASE_CONFIG).has("datadog")).toBe(false)
    expect(reconnectable(BASE_CONFIG).has("pagerduty")).toBe(false)
  })

  it("ignores allow rules and non-wildcard keys", () => {
    expect([...reconnectable({ tools: { "slack_*": true, question: false } })]).toEqual([])
  })

  it("is empty for a host with no gated servers", () => {
    expect(reconnectable({}).size).toBe(0)
  })
})

describe("pendingReconnects", () => {
  const statuses = {
    slack: { status: "disabled" },
    "slack-ro": { status: "disabled" },
    datadog: { status: "disabled" },
  }

  it("reconnects a server the session was granted but which is not connected", () => {
    expect(pendingReconnects([allow("slack")], statuses, ELIGIBLE)).toEqual(["slack"])
  })

  it("refuses a granted server that is not eligible, however loudly it was granted", () => {
    expect(pendingReconnects([allow("datadog")], statuses, ELIGIBLE)).toEqual([])
  })

  it("ignores a granted server that is already connected", () => {
    expect(pendingReconnects([allow("slack")], { slack: { status: "connected" } }, ELIGIBLE)).toEqual([])
  })

  it("ignores servers the session was never granted", () => {
    expect(pendingReconnects([], statuses, ELIGIBLE)).toEqual([])
    expect(pendingReconnects([{ permission: "question", pattern: "*", action: "deny" }], statuses, ELIGIBLE)).toEqual([])
  })

  it("honours a revoke: the LAST matching rule wins, mirroring Permission.evaluate's findLast", () => {
    expect(pendingReconnects([allow("slack"), deny("slack")], statuses, ELIGIBLE)).toEqual([])
    expect(pendingReconnects([deny("slack"), allow("slack")], statuses, ELIGIBLE)).toEqual(["slack"])
  })

  it("tolerates the duplicate allow rules that repeated re-enabling leaves behind", () => {
    // Real sessions on cloudbox carry up to six identical slack_* allow rules,
    // one per manual oc-mcp-enable after a serve restart. That is the symptom
    // this plugin removes; it must not confuse the reader of the ruleset.
    expect(pendingReconnects([allow("slack"), allow("slack"), allow("slack")], statuses, ELIGIBLE)).toEqual(["slack"])
  })

  it("does not confuse slack with slack-ro (hyphen is a legal server-name char)", () => {
    expect(pendingReconnects([allow("slack-ro")], statuses, ELIGIBLE)).toEqual(["slack-ro"])
    expect(pendingReconnects([allow("slack")], statuses, ELIGIBLE)).toEqual(["slack"])
  })

  it("returns every granted-but-down eligible server, sorted", () => {
    expect(pendingReconnects([allow("slack"), allow("slack-ro")], statuses, ELIGIBLE)).toEqual(["slack", "slack-ro"])
  })

  it("reconnects a server whose client FAILED, not just one that is disabled", () => {
    expect(pendingReconnects([allow("slack")], { slack: { status: "failed" } }, ELIGIBLE)).toEqual(["slack"])
  })

  it("does NOT retry a server waiting on a human OAuth flow", () => {
    // Retrying needs_auth cannot succeed and re-raises opencode's
    // "MCP Authentication Required" toast on every single user message.
    expect(pendingReconnects([allow("slack")], { slack: { status: "needs_auth" } }, ELIGIBLE)).toEqual([])
    expect(
      pendingReconnects([allow("slack")], { slack: { status: "needs_client_registration" } }, ELIGIBLE),
    ).toEqual([])
  })
})

/**
 * A fake of the plugin's opencode client.
 *
 * Faithful to hey-api semantics on the point that matters: `ThrowOnError`
 * defaults to false, so a failed connect RESOLVES. And opencode's connect route
 * returns a bare `true` even when the handshake failed, because `MCP.create`
 * swallows the failure into a status. So "connect failed" is modelled as
 * `connect` resolving while `status` keeps reporting a non-connected state --
 * which is precisely what production does, and what a throwing fake would hide.
 */
function makeClient(opts: {
  statuses: Record<string, { status: string }>
  permission?: Rule[]
  config?: unknown
  /** Return the status the server ends up in. Default: connected. */
  onConnect?: (name: string) => string | Promise<string>
  /** Simulate a transport-level failure (network down, timeout). */
  throwOnConnect?: boolean
}) {
  const connects: string[] = []
  const sessionGets: string[] = []
  const configGets: string[] = []
  let statuses: Record<string, { status: string }> = { ...opts.statuses }
  const client = {
    config: {
      get: async () => {
        configGets.push("/config")
        return { data: opts.config ?? BASE_CONFIG }
      },
    },
    mcp: {
      status: async () => ({ data: statuses }),
      connect: async ({ path }: { path: { name: string } }) => {
        connects.push(path.name)
        if (opts.throwOnConnect) throw new Error("connection refused")
        const next = opts.onConnect ? await opts.onConnect(path.name) : "connected"
        statuses = { ...statuses, [path.name]: { status: next } }
        return { data: true }
      },
    },
    session: {
      get: async ({ path }: { path: { id: string } }) => {
        sessionGets.push(path.id)
        return { data: { id: path.id, permission: opts.permission ?? [] } }
      },
    },
  }
  return { client, connects, sessionGets, configGets }
}

async function chatMessageHook(client: unknown) {
  const hooks = await pluginModule.server({ client, directory: "/w" } as never)
  const hook = hooks["chat.message"]
  if (!hook) throw new Error("plugin did not register a chat.message hook")
  return hook
}

const message = (sessionID = "ses_test") => [{ sessionID }, {}] as unknown as [never, never]

describe("mcp-autoconnect chat.message hook", () => {
  beforeEach(() => {
    // The plugin logs reconnects/failures to stderr; keep the suite quiet but
    // still assertable.
    vi.spyOn(console, "error").mockImplementation(() => {})
  })
  afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it("reconnects a granted, eligible server before the turn starts", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual(["slack"])
  })

  it("refuses to reconnect an UNGATED server even when the session granted it", async () => {
    const { client, connects, sessionGets } = makeClient({
      statuses: { datadog: { status: "disabled" } },
      permission: [allow("datadog")],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual([])
    // Nothing eligible is down, so it should not even read the session.
    expect(sessionGets).toEqual([])
  })

  it("does nothing at all on a host with no gated servers configured", async () => {
    const { client, connects, sessionGets } = makeClient({
      statuses: { datadog: { status: "disabled" } },
      permission: [allow("datadog")],
      config: {},
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual([])
    expect(sessionGets).toEqual([])
  })

  it("reads the config once and caches it across turns", async () => {
    // Safe because a POST /config disposes the instance, which rebuilds the
    // plugin. Asserted so a future refactor cannot silently make it per-message.
    const { client, configGets } = makeClient({
      statuses: { slack: { status: "connected" } },
      permission: [allow("slack")],
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    await hook(...message())
    expect(configGets).toHaveLength(1)
  })

  it("skips the session read when every eligible server is already connected", async () => {
    const { client, connects, sessionGets } = makeClient({
      statuses: { slack: { status: "connected" }, "slack-ro": { status: "connected" } },
      permission: [allow("slack")],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual([])
    expect(sessionGets).toEqual([])
  })

  it("does not connect a server the session has no grant for", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual([])
  })

  it("is idempotent across turns: a reconnected server is not connected again", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    await hook(...message())
    expect(connects).toEqual(["slack"])
  })

  it("NEVER rejects when the client throws -- a rejection here dies the whole turn", async () => {
    // plugin.trigger wraps hooks in Effect.promise, where a rejected promise is
    // a defect, not a recoverable error. This is the single most important
    // property of the hook.
    const client = {
      config: {
        get: async () => {
          throw new Error("serve is mid-restart")
        },
      },
      mcp: { status: async () => ({}), connect: async () => ({}) },
      session: { get: async () => ({}) },
    }
    await expect((await chatMessageHook(client))(...message())).resolves.toBeUndefined()
  })

  it("NEVER rejects when the connect itself throws", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      throwOnConnect: true,
    })
    await expect((await chatMessageHook(client))(...message())).resolves.toBeUndefined()
    expect(connects).toEqual(["slack"])
  })

  it("treats a RESOLVED connect that did not connect as a failure", async () => {
    // The production failure shape: MCP.create swallows a bad token into a
    // `failed` status and the route still returns 200/true. A fake that threw
    // would never exercise this, and the backoff below would be dead code.
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      onConnect: () => "failed",
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    await hook(...message())
    expect(connects).toEqual(["slack"])
  })

  it("backs off after a silently-failed connect instead of respawning npx every message", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      onConnect: () => "failed",
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    await hook(...message())
    expect(connects).toEqual(["slack"])

    vi.setSystemTime(RETRY_COOLDOWN_MS)
    await hook(...message())
    expect(connects).toEqual(["slack", "slack"])
  })

  it("clears the backoff once a later connect actually succeeds", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
    let outcome = "failed"
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      onConnect: () => outcome,
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    outcome = "connected"
    vi.setSystemTime(RETRY_COOLDOWN_MS)
    await hook(...message())
    await hook(...message())
    expect(connects).toEqual(["slack", "slack"])
  })

  it("collapses concurrent turns in the same directory into one connect", async () => {
    let release: () => void = () => {}
    const gate = new Promise<void>((resolve) => (release = resolve))
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      onConnect: async () => {
        await gate
        return "connected"
      },
    })
    const hook = await chatMessageHook(client)
    const a = hook(...message("ses_a"))
    const b = hook(...message("ses_b"))
    release()
    await Promise.all([a, b])
    expect(connects).toEqual(["slack"])
  })
})

describe("withTimeout", () => {
  it("rejects a call that never settles, so a wedged serve cannot stall a turn", async () => {
    await expect(internals.withTimeout(new Promise(() => {}), 5, "probe")).rejects.toThrow(/probe timed out/)
  })

  it("passes a value through untouched", async () => {
    await expect(internals.withTimeout(Promise.resolve(42), 1000, "probe")).resolves.toBe(42)
  })
})
