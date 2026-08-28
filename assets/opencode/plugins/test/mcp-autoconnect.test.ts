import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import pluginModule, { internals } from "../mcp-autoconnect"

// mcp-autoconnect.ts uses opencode's v1 plugin shape (`export default { id,
// server }`), which is what makes the `internals` named export safe: the loader
// takes the v1 branch and never inspects named exports. See the comment on the
// default export, and test/plugin-loader-contract.test.ts which enforces it.
const { pendingReconnects, RETRY_COOLDOWN_MS } = internals

type Rule = { permission?: string; pattern?: string; action?: string }

/** The rule shape `oc-mcp-enable`'s build_permission_json actually emits. */
const allow = (server: string): Rule => ({ permission: `${server}_*`, pattern: "*", action: "allow" })
const deny = (server: string): Rule => ({ permission: `${server}_*`, pattern: "*", action: "deny" })

describe("pendingReconnects", () => {
  const statuses = {
    slack: { status: "disabled" },
    "slack-ro": { status: "disabled" },
    atlassian: { status: "disabled" },
  }

  it("reconnects a server the session was granted but which is not connected", () => {
    expect(pendingReconnects([allow("slack")], statuses)).toEqual(["slack"])
  })

  it("ignores a granted server that is already connected", () => {
    expect(pendingReconnects([allow("slack")], { slack: { status: "connected" } })).toEqual([])
  })

  it("ignores servers the session was never granted", () => {
    expect(pendingReconnects([], statuses)).toEqual([])
    expect(pendingReconnects([{ permission: "question", pattern: "*", action: "deny" }], statuses)).toEqual([])
  })

  it("honours a revoke: the LAST matching rule wins, mirroring Permission.evaluate's findLast", () => {
    expect(pendingReconnects([allow("slack"), deny("slack")], statuses)).toEqual([])
    expect(pendingReconnects([deny("slack"), allow("slack")], statuses)).toEqual(["slack"])
  })

  it("tolerates the duplicate allow rules that repeated re-enabling leaves behind", () => {
    // Real sessions on cloudbox carry up to six identical slack_* allow rules,
    // one per manual oc-mcp-enable after a serve restart. That is the symptom
    // this plugin removes; it must not confuse the reader of the ruleset.
    expect(pendingReconnects([allow("slack"), allow("slack"), allow("slack")], statuses)).toEqual(["slack"])
  })

  it("does not confuse slack with slack-ro (hyphen is a legal server-name char)", () => {
    expect(pendingReconnects([allow("slack-ro")], statuses)).toEqual(["slack-ro"])
    expect(pendingReconnects([allow("slack")], statuses)).toEqual(["slack"])
  })

  it("returns every granted-but-down server, sorted", () => {
    expect(pendingReconnects([allow("slack"), allow("atlassian")], statuses)).toEqual(["atlassian", "slack"])
  })

  it("reconnects a server whose client FAILED, not just one that is disabled", () => {
    expect(pendingReconnects([allow("slack")], { slack: { status: "failed" } })).toEqual(["slack"])
  })
})

/** A fake of the plugin's opencode client, recording the calls made through it. */
function makeClient(opts: {
  statuses: Record<string, { status: string }>
  permission?: Rule[]
  connect?: (name: string) => Promise<unknown>
}) {
  const connects: string[] = []
  const sessionGets: string[] = []
  let statuses = opts.statuses
  const client = {
    mcp: {
      status: async () => ({ data: statuses }),
      connect: async ({ path }: { path: { name: string } }) => {
        connects.push(path.name)
        if (opts.connect) return opts.connect(path.name)
        statuses = { ...statuses, [path.name]: { status: "connected" } }
        return { data: statuses }
      },
    },
    session: {
      get: async ({ path }: { path: { id: string } }) => {
        sessionGets.push(path.id)
        return { data: { id: path.id, permission: opts.permission ?? [] } }
      },
    },
  }
  return { client, connects, sessionGets }
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

  it("reconnects a granted server before the turn starts", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual(["slack"])
  })

  it("does nothing, and does not even read the session, when everything is connected", async () => {
    const { client, connects, sessionGets } = makeClient({
      statuses: { slack: { status: "connected" } },
      permission: [allow("slack")],
    })
    await (await chatMessageHook(client))(...message())
    expect(connects).toEqual([])
    // The fast path matters: this hook runs on the critical path of every user
    // message in every session on the box.
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
      mcp: {
        status: async () => {
          throw new Error("serve is mid-restart")
        },
        connect: async () => ({}),
      },
      session: { get: async () => ({}) },
    }
    await expect((await chatMessageHook(client))(...message())).resolves.toBeUndefined()
  })

  it("NEVER rejects when the connect itself fails", async () => {
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      connect: async () => {
        throw new Error("npx: command not found")
      },
    })
    await expect((await chatMessageHook(client))(...message())).resolves.toBeUndefined()
    expect(connects).toEqual(["slack"])
  })

  it("backs off after a failure instead of retrying on every message", async () => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      connect: async () => {
        throw new Error("boom")
      },
    })
    const hook = await chatMessageHook(client)
    await hook(...message())
    await hook(...message())
    expect(connects).toEqual(["slack"])

    vi.setSystemTime(RETRY_COOLDOWN_MS)
    await hook(...message())
    expect(connects).toEqual(["slack", "slack"])
  })

  it("collapses concurrent turns in the same directory into one connect", async () => {
    let release: () => void = () => {}
    const gate = new Promise<void>((resolve) => (release = resolve))
    const { client, connects } = makeClient({
      statuses: { slack: { status: "disabled" } },
      permission: [allow("slack")],
      connect: async () => gate,
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
