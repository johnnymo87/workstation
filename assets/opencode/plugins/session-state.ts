import type { Plugin } from "@opencode-ai/plugin"
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import {
  applyEvent,
  checkServePortFence,
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
    // Loud on the false-negative path only. If OPENCODE_SERVE_ID is set we are
    // almost certainly inside a pool serve, so failing the cmdline check means
    // the launch shape changed (a wrapper, a re-exec, an interpreter launch
    // like `bun /path/index.js serve`) and the writer has just gone inert --
    // fleet-wide, silently, with no overlays and therefore no signal at all.
    // The fleet auto-updates every 8 hours, so this needs to be discoverable
    // from the log rather than by noticing the picker is empty.
    if (serveId) {
      console.error(
        `[session-state] inert: OPENCODE_SERVE_ID=${serveId} is set but this process does not look like a pool serve ` +
          `(cmdline[1] != "serve"). No session-state overlay will be written. cmdline=${JSON.stringify(cmdline.slice(0, 200))}`,
      )
    }
    return {}
  }

  // Second gate: the port fence. isPoolServeProcess above only checks that
  // argv[1] == "serve" and that OPENCODE_SERVE_ID is set -- both of which are
  // TRUE for a throwaway `opencode serve` spawned from inside a session hosted
  // by a pool serve, because the wrapper EXPORTS the slot's identity to every
  // child. Such a process would write this slot's overlay filename under a
  // different pid, giving two live writers alternating whole-file overwrites
  // (the same-pid-only silence rule cannot fire when the pids differ).
  //
  // The routing layer's identical fence does not cover this: it only refuses to
  // register for a process that CLAIMS a routing slot, and a nested serve with
  // OPENCODE_ROUTING_DB scrubbed never claims one.
  //
  // Injectable for the same reason `cmdline` and `dir` are: the test runner
  // inherits this variable from whichever pool serve hosts the session running
  // the suite, so reading process.env directly makes every plugin-level test
  // depend on ambient production state and go inert under a port that has
  // nothing to do with the test.
  const expectedPort = opts?.expectedPort ?? process.env.OPENCODE_SERVE_EXPECTED_PORT
  const fence = checkServePortFence(ctx.serverUrl, expectedPort)
  if (fence.verdict === "unarmed") {
    // Every other inert/degraded path in this plugin is loud, for the same
    // reason: a state writer that quietly stops enforcing something is the
    // worst outcome, because nothing downstream can tell. A disarmed fence is
    // worth exactly nothing, and the population most likely to present a
    // scrubbed declared port or an unreadable serverUrl is the nested-serve
    // population this fence exists to stop -- someone who scrubs
    // OPENCODE_SERVE_EXPECTED_PORT but keeps OPENCODE_SERVE_ID re-arms the
    // hijack while disarming the guard. Keep writing, but say so.
    console.error(
      `[session-state] port fence UNARMED for OPENCODE_SERVE_ID=${serveId}: ${fence.reason}. ` +
        `A nested serve that inherited this slot's identity would not be detected.`,
    )
  }
  if (fence.verdict === "mismatch") {
    console.error(
      `[session-state] inert: OPENCODE_SERVE_ID=${serveId} declares port ` +
        `${expectedPort} but this process is serving on ${String(ctx.serverUrl)} (${fence.reason}). ` +
        `This is a nested/throwaway serve that inherited the slot's identity, not the pool member for that slot. ` +
        `Writing would corrupt ${serveId}'s overlay with a second writer. Scrub OPENCODE_SERVE_ID before spawning a throwaway serve.`,
    )
    return {}
  }

  // Overlay directory is injectable so tests never touch the LIVE one. On
  // cloudbox `serve-0` is a real pool serve, so a test that scans the real
  // directory for `serve-0-*.json` can pick up (assert on, and then delete) a
  // running serve's overlay. Tests pass an explicit temp dir; production takes
  // the default.
  const dir =
    opts?.dir ??
    process.env.OPENCODE_SESSION_STATE_DIR ??
    join(homedir(), ".local/share/opencode/session-state.d")

  // The one syscall in this factory that ran unguarded. Everything below is
  // already try/caught, so a failure here (ENOSPC, EROFS, a bad injected dir)
  // was the single way this factory could throw. Measured on 1.17.13: opencode
  // SWALLOWS a throwing plugin factory -- the module is imported, the factory
  // runs and throws, and session creation still succeeds with an empty log --
  // so this would not have taken the host down. It would instead have made the
  // writer vanish in total silence, which for a state writer is the worse
  // outcome: absent state reads as "no information", indistinguishable from a
  // serve that simply has no sessions. Fail loudly and stay inert instead.
  try {
    mkdirSync(dir, { recursive: true })
  } catch (err) {
    console.error(
      `[session-state] cannot create overlay dir ${dir}; writer inert for this instance:`,
      err,
    )
    return {}
  }

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
            existingHeartbeat: existing?.heartbeat,
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

  // Plain fetch, deliberately: the reconcile only ever talks to THIS serve over
  // loopback, and the pool serves require no auth today (no
  // OPENCODE_SERVER_PASSWORD in the unit, no /run/secrets/opencode_server_password,
  // and an unauthenticated GET against a pool serve returns 200). Importing
  // wrapFetchWithAuth from ./serve-auth would add a *deployment* dependency on a
  // sibling plugin file that is not deployed to ~/.config/opencode/plugins at
  // all -- and opencode swallows failed sibling imports, so it would break
  // silently. If auth is ever turned on, the reconcile fails closed (the fetch
  // throws/401s, the catch swallows it, and the writer keeps serving
  // event-derived state) rather than corrupting anything.
  //
  // INJECTABLE, and that is not a nicety. The tests used to hand a mock fetch
  // in via `client._client.getConfig()`, which this function never read -- so
  // every `npm test` run fired two REAL requests at whatever was listening on
  // ctx.serverUrl. On cloudbox that is a live pool serve, which then created an
  // instance for the test's throwaway directory and left an overlay behind. The
  // mock was decoration; the network call was real. Same shape as the earlier
  // bug where a test scanned and deleted the LIVE overlay directory.
  const fetchFn: typeof fetch = opts?.fetch ?? globalThis.fetch

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
