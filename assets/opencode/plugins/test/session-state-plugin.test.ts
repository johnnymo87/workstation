import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import plugin from "../session-state"

describe("session-state plugin integration", () => {
  const testDir = path.join(os.tmpdir(), `session-state-test-${Date.now()}`)
  const overlayDir = path.join(os.tmpdir(), `session-state-overlay-${Date.now()}-${Math.random().toString(36).slice(2)}`)
  const originalEnv = process.env.OPENCODE_SERVE_ID

  beforeEach(() => {
    fs.mkdirSync(testDir, { recursive: true })
  })

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.OPENCODE_SERVE_ID
    else process.env.OPENCODE_SERVE_ID = originalEnv
    vi.restoreAllMocks()
    try {
      fs.rmSync(testDir, { recursive: true, force: true })
    } catch {}
  })

  it("returns empty object when process is not a pool serve process", async () => {
    delete process.env.OPENCODE_SERVE_ID

    const ctx = {
      directory: "/path/to/project",
      serverUrl: "http://127.0.0.1:1",
      client: {},
    } as any

    const result = await plugin(ctx, { cmdline: "/bin/opencode\x00run\x00", dir: overlayDir, fetch: vi.fn(), expectedPort: "1" })
    expect(result).toEqual({})
  })

  it("goes inert for a NESTED serve that inherited the slot's identity", async () => {
    // The 2026-07-25 hijack signature: a throwaway `opencode serve` spawned
    // from inside a session hosted by serve-2. It inherits OPENCODE_SERVE_ID
    // and the slot's declared port (the wrapper exports both), and its argv[1]
    // really is "serve" -- so it passes isPoolServeProcess and would write
    // serve-2's overlay filename under a different pid. Only the port it
    // actually bound gives it away.
    process.env.OPENCODE_SERVE_ID = "serve-2"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x0047037\x00"

    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:47037", // bound its own port
      client: {},
    } as any

    const result = await plugin(ctx, {
      cmdline: poolCmdline,
      dir: overlayDir,
      fetch: vi.fn(),
      expectedPort: "4098", // inherited from serve-2
    })

    expect(result).toEqual({})
    // and critically: no overlay file was created for the hijacked slot
    const files = fs.existsSync(overlayDir) ? fs.readdirSync(overlayDir) : []
    expect(files.filter((f) => f.startsWith("serve-2"))).toEqual([])
  })

  it("still activates when the fence is UNARMED (wrapper not yet updated)", async () => {
    // Unset = unarmed, matching opencode-serve-start's own convention, so a
    // plugin update and a wrapper update can land in either order without
    // blacking out the writer fleet-wide.
    process.env.OPENCODE_SERVE_ID = "serve-0"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x004096\x00"
    const mockFetch = vi.fn().mockResolvedValue({ ok: true, json: async () => [] })
    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:1",
      client: {},
    } as any

    // Genuinely remove the variable rather than passing `expectedPort:
    // undefined`, which does NOT mean "unarmed" -- it means "fall back to
    // process.env", and the suite inherits a real declared port from whichever
    // pool serve hosts the session running these tests. That fallback is the
    // production path, so this exercises it honestly.
    const saved = process.env.OPENCODE_SERVE_EXPECTED_PORT
    delete process.env.OPENCODE_SERVE_EXPECTED_PORT
    try {
      const result = await plugin(ctx, {
        cmdline: poolCmdline,
        dir: overlayDir,
        fetch: mockFetch,
      })
      expect(result.event).toBeDefined()
    } finally {
      if (saved === undefined) delete process.env.OPENCODE_SERVE_EXPECTED_PORT
      else process.env.OPENCODE_SERVE_EXPECTED_PORT = saved
    }
  })

  it("activates when OPENCODE_SERVE_ID is set and process is pool serve, writing overlay on events", async () => {
    process.env.OPENCODE_SERVE_ID = "serve-0"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x004096\x00"

    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:1",
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } },
    } as any

    const result = await plugin(ctx, { cmdline: poolCmdline, dir: overlayDir, fetch: mockFetch, expectedPort: "1" })
    expect(result.event).toBeDefined()

    // Send busy event
    await result.event!({
      event: {
        type: "session.status",
        properties: { sessionID: "s1", status: { type: "busy" } },
      } as any,
    })

    // Find created json overlay file in ~/.local/share/opencode/session-state.d
    const files = fs.readdirSync(overlayDir).filter((f) => f.startsWith("serve-0-") && f.endsWith(".json"))
    expect(files.length).toBeGreaterThan(0)

    const overlayFile = path.join(overlayDir, files[0])
    const data = JSON.parse(fs.readFileSync(overlayFile, "utf8"))

    expect(data.serveId).toBe("serve-0")
    expect(data.directory).toBe(testDir)
    expect(data.sessions.s1).toBeDefined()
    expect(data.sessions.s1.activity).toBe("working")

    // Send session.deleted
    await result.event!({
      event: {
        type: "session.deleted",
        properties: { sessionID: "s1" },
      } as any,
    })

    const updatedData = JSON.parse(fs.readFileSync(overlayFile, "utf8"))
    expect(updatedData.sessions.s1).toBeUndefined()

    // Clean up created test overlay file
    try {
      fs.rmSync(overlayFile, { force: true })
    } catch {}
  })

  // Regression guard. The seed/reconcile used globalThis.fetch while these
  // tests handed their mock in through `client._client.getConfig()` -- a
  // channel the plugin never read. The mocks passed, and the suite quietly
  // fired two real requests at whatever was on ctx.serverUrl (on cloudbox: a
  // live pool serve, which then spun up an instance for the temp directory and
  // left an overlay behind). Assert the injected fetch is ACTUALLY the one
  // used, and that the global is untouched, or the isolation is decorative.
  it("uses the injected fetch and never touches globalThis.fetch", async () => {
    process.env.OPENCODE_SERVE_ID = "serve-0"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x004096\x00"

    const injected = vi.fn().mockResolvedValue({ ok: true, json: async () => [] })
    const globalSpy = vi.spyOn(globalThis, "fetch")

    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:1",
      client: {},
    } as any

    await plugin(ctx, { cmdline: poolCmdline, dir: overlayDir, fetch: injected, expectedPort: "1" })
    await new Promise((r) => setTimeout(r, 50))

    expect(injected).toHaveBeenCalled()
    expect(globalSpy).not.toHaveBeenCalled()
    globalSpy.mockRestore()
  })

  it("goes silent when an existing file has same PID and a newer instanceStamp", async () => {
    process.env.OPENCODE_SERVE_ID = "serve-0"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x004096\x00"

    const mockFetch = vi.fn().mockResolvedValue({ ok: true, json: async () => [] })
    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:1",
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } },
    } as any

    const instance1 = await plugin(ctx, { cmdline: poolCmdline, dir: overlayDir, fetch: mockFetch, expectedPort: "1" })

    const files = fs.readdirSync(overlayDir).filter((f) => f.startsWith("serve-0-") && f.endsWith(".json"))
    expect(files.length).toBeGreaterThan(0)
    const overlayFile = path.join(overlayDir, files[0])

    // Manually overwrite overlay file simulating a newer instance with same PID
    const fileContent = JSON.parse(fs.readFileSync(overlayFile, "utf8"))
    fileContent.instanceStamp = fileContent.instanceStamp + 1000
    fileContent.sessions = { s_newer: { activity: "working", pendingPermissions: [], pendingQuestions: [] } }
    fs.writeFileSync(overlayFile, JSON.stringify(fileContent))

    // Send an event to instance1 -- should go silent and NOT overwrite fileContent
    await instance1.event!({
      event: {
        type: "session.status",
        properties: { sessionID: "s_old", status: { type: "busy" } },
      } as any,
    })

    const currentData = JSON.parse(fs.readFileSync(overlayFile, "utf8"))
    expect(currentData.sessions.s_newer).toBeDefined()
    expect(currentData.sessions.s_old).toBeUndefined()

    // Clean up
    try {
      fs.rmSync(overlayFile, { force: true })
    } catch {}
  })
})
