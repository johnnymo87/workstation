import type { Plugin } from "@opencode-ai/plugin"
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { wrapFetchWithAuth } from "./serve-auth"
import {
  applyEvent,
  emptyState,
  evictIdleSessions,
  fetchPendingSnapshot,
  generateInstanceStamp,
  getOverlayFilename,
  getSelfCmdline,
  isPoolServeProcess,
  OVERLAY_VERSION,
  seedFromSnapshot,
  serializeOverlay,
  shouldGoSilent,
  type StateMap,
} from "./session-state-impl"

const HEARTBEAT_MS = 15_000
const RECONCILE_MS = 60_000

const plugin: Plugin = async (ctx, opts?: any) => {
  const serveId = process.env.OPENCODE_SERVE_ID
  const cmdline = opts?.cmdline ?? getSelfCmdline()

  if (!isPoolServeProcess(cmdline, serveId)) {
    return {}
  }

  const dir = join(homedir(), ".local/share/opencode/session-state.d")
  mkdirSync(dir, { recursive: true })

  const filename = getOverlayFilename(serveId!, ctx.directory)
  const file = join(dir, filename)

  const ourStamp = generateInstanceStamp()
  let sessions: StateMap = emptyState()
  let isSilent = false

  let heartbeatTimer: NodeJS.Timeout | undefined
  let reconcileTimer: NodeJS.Timeout | undefined

  const flush = () => {
    if (isSilent) return

    try {
      if (existsSync(file)) {
        const raw = readFileSync(file, "utf8")
        const existing = JSON.parse(raw)
        if (
          shouldGoSilent({
            existingPid: existing?.pid,
            existingStamp: existing?.instanceStamp,
            ourPid: process.pid,
            ourStamp,
          })
        ) {
          isSilent = true
          if (heartbeatTimer) clearInterval(heartbeatTimer)
          if (reconcileTimer) clearInterval(reconcileTimer)
          return
        }
      }
    } catch {
      // Ignore read or JSON parse errors
    }

    sessions = evictIdleSessions(sessions)

    const tmp = `${file}.${process.pid}.tmp`
    const overlayData = serializeOverlay({
      version: OVERLAY_VERSION,
      instanceStamp: ourStamp,
      pid: process.pid,
      serveId: serveId!,
      directory: ctx.directory,
      heartbeat: Date.now(),
      sessions,
    })

    try {
      writeFileSync(tmp, JSON.stringify(overlayData))
      renameSync(tmp, file)
    } catch {
      // Best-effort write
    }
  }

  flush()

  heartbeatTimer = setInterval(flush, HEARTBEAT_MS)
  if (typeof (heartbeatTimer as any).unref === "function") {
    ;(heartbeatTimer as any).unref()
  }

  const sdkClientConfig: any = (ctx.client as any)._client?.getConfig?.()
  const rawFetch: typeof fetch = sdkClientConfig?.fetch ?? globalThis.fetch
  const fetchFn = wrapFetchWithAuth(rawFetch)

  const reconcile = async () => {
    if (isSilent) return
    try {
      const snapshot = await fetchPendingSnapshot(fetchFn, ctx.serverUrl, ctx.directory)
      const next = seedFromSnapshot(sessions, snapshot, { unionOnly: true })
      if (next !== sessions) {
        sessions = next
        flush()
      }
    } catch {
      // Silent catch
    }
  }

  // Fire-and-forget initial reconcile (do NOT await!)
  void reconcile()

  reconcileTimer = setInterval(reconcile, RECONCILE_MS)
  if (typeof (reconcileTimer as any).unref === "function") {
    ;(reconcileTimer as any).unref()
  }

  process.once("exit", () => {
    try {
      if (heartbeatTimer) clearInterval(heartbeatTimer)
      if (reconcileTimer) clearInterval(reconcileTimer)
      if (!isSilent) {
        rmSync(file, { force: true })
      }
    } catch {
      // Best-effort exit cleanup
    }
  })

  return {
    event: async ({ event }) => {
      if (isSilent) return
      if (event?.type === "session.deleted") {
        const sid = (event.properties as any)?.sessionID
        if (sid && sessions[sid]) {
          const next = { ...sessions }
          delete next[sid]
          sessions = next
          flush()
        }
        return
      }
      const next = applyEvent(sessions, event)
      if (next !== sessions) {
        sessions = next
        flush()
      }
    },
  }
}

export default plugin
