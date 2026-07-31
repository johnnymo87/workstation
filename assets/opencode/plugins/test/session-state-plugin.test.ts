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
    process.env.OPENCODE_SERVE_ID = originalEnv
    vi.restoreAllMocks()
    try {
      fs.rmSync(testDir, { recursive: true, force: true })
    } catch {}
  })

  it("returns empty object when process is not a pool serve process", async () => {
    process.env.OPENCODE_SERVE_ID = undefined

    const ctx = {
      directory: "/path/to/project",
      serverUrl: "http://127.0.0.1:4096",
      client: {},
    } as any

    const result = await plugin(ctx, { cmdline: "/bin/opencode\x00run\x00", dir: overlayDir })
    expect(result).toEqual({})
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
      serverUrl: "http://127.0.0.1:4096",
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } },
    } as any

    const result = await plugin(ctx, { cmdline: poolCmdline, dir: overlayDir })
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

  it("goes silent when an existing file has same PID and a newer instanceStamp", async () => {
    process.env.OPENCODE_SERVE_ID = "serve-0"
    const poolCmdline = "/bin/opencode\x00serve\x00--port\x004096\x00"

    const mockFetch = vi.fn().mockResolvedValue({ ok: true, json: async () => [] })
    const ctx = {
      directory: testDir,
      serverUrl: "http://127.0.0.1:4096",
      client: { _client: { getConfig: () => ({ fetch: mockFetch }) } },
    } as any

    const instance1 = await plugin(ctx, { cmdline: poolCmdline, dir: overlayDir })

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
