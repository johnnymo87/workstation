import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"

export function getSelfCmdline(filePath = "/proc/self/cmdline"): string {
  try {
    return readFileSync(filePath, "utf8")
  } catch {
    return ""
  }
}

// "unknown" is produced later by Task 2 for stale overlays
export type Activity = "working" | "blocked" | "idle" | "retry" | "error" | "unknown"

export interface SessionEntry {
  // Do NOT add "nodata" here to "align" this with SessionWithStateRow.activity.
  // nodata is READER-SYNTHESIZED (it means no writer was watching) and can never
  // be observed by a writer, so it must not enter the wire format. Adding it
  // would also silently break evictIdleSessions below, which treats any activity
  // !== "idle" as busy and would therefore never evict such an entry.
  activity: "working" | "idle" | "retry" // raw status axis
  error: boolean // sticky until next busy
  pendingPermissions: string[]
  pendingQuestions: string[]
  retry?: { attempt: number; next: number }
  lastActivity: number
  updatedAt: number
  revision?: number
  unknown?: boolean
}

export type StateMap = Record<string, SessionEntry>

export const emptyState = (): StateMap => ({})

const now = () => Date.now()

const fresh = (t: number): SessionEntry => ({
  activity: "idle",
  error: false,
  pendingPermissions: [],
  pendingQuestions: [],
  lastActivity: t,
  updatedAt: t,
  revision: 0,
})

export function applyEvent(
  prev: StateMap,
  event: { type: string; properties?: any },
  clock = now,
): StateMap {
  const p = event.properties ?? {}
  const sid: string | undefined = p.sessionID
  if (!sid) return prev

  const t = clock()
  const cur = prev[sid]
  const e: SessionEntry = cur ? { ...cur } : fresh(t)
  let changed = !cur

  const bump = () => {
    e.updatedAt = t
    e.lastActivity = t
    e.revision = (cur ? (cur.revision ?? 0) : 0) + 1
    changed = true
  }

  switch (event.type) {
    case "session.status": {
      const st = p.status?.type
      if (st === "idle") {
        if (
          e.activity === "idle" &&
          !e.pendingPermissions.length &&
          !e.pendingQuestions.length
        ) {
          // Idle when already idle with no pending permissions/questions is a no-op
          // (does not reset lastActivity)
          return prev
        }
        e.activity = "idle"
        e.pendingPermissions = []
        e.pendingQuestions = []
        e.retry = undefined
        bump()
      } else if (st === "busy") {
        e.activity = "working"
        e.error = false // new turn clears sticky error
        e.retry = undefined
        bump()
      } else if (st === "retry") {
        e.activity = "retry"
        e.retry = { attempt: p.status.attempt, next: p.status.next }
        bump()
      } else {
        return prev
      }
      break
    }
    // Asymmetry: .asked events carry key in properties.id
    case "permission.asked":
      if (!p.id) return prev
      if (e.pendingPermissions.includes(p.id)) return prev
      e.pendingPermissions = [...e.pendingPermissions, p.id]
      bump()
      break
    // Asymmetry: .replied / .rejected events carry key in properties.requestID
    case "permission.replied":
      if (!p.requestID) return prev
      if (!e.pendingPermissions.includes(p.requestID)) return prev
      e.pendingPermissions = e.pendingPermissions.filter((x) => x !== p.requestID)
      bump()
      break
    case "question.asked":
      if (!p.id) return prev
      if (e.pendingQuestions.includes(p.id)) return prev
      e.pendingQuestions = [...e.pendingQuestions, p.id]
      bump()
      break
    case "question.replied":
    case "question.rejected":
      if (!p.requestID) return prev
      if (!e.pendingQuestions.includes(p.requestID)) return prev
      e.pendingQuestions = e.pendingQuestions.filter((x) => x !== p.requestID)
      bump()
      break
    case "session.error":
      // session.error is sticky until next busy (new turn)
      e.error = true
      bump()
      break
    default:
      return prev
  }

  if (!changed) return prev
  return { ...prev, [sid]: e }
}

export function effectiveState(e?: SessionEntry): Activity {
  if (!e) return "idle"
  if (e.unknown) return "unknown"
  if (e.error) return "error"
  if (e.pendingPermissions.length || e.pendingQuestions.length) return "blocked"
  return e.activity
}

export interface Snapshot {
  permissions?: Array<{ sessionID: string; id: string }>
  questions?: Array<{ sessionID: string; id: string }>
}

export interface SeedOptions {
  unionOnly?: boolean
  clock?: () => number
}

// NOTE: seedFromSnapshot is a seed/startup primitive.
// By default (unionOnly: true), it only seeds sessions that have no event-derived entry in prev yet.
// If a session already exists in prev, it is skipped so a late snapshot cannot drop or resurrect prompts.
export function seedFromSnapshot(
  prev: StateMap,
  snapshot: Snapshot,
  clockOrOptions?: SeedOptions | (() => number),
): StateMap {
  let unionOnly = true
  let clock: () => number = now

  if (typeof clockOrOptions === "function") {
    clock = clockOrOptions
  } else if (clockOrOptions && typeof clockOrOptions === "object") {
    if (clockOrOptions.unionOnly !== undefined) {
      unionOnly = clockOrOptions.unionOnly
    }
    if (clockOrOptions.clock) {
      clock = clockOrOptions.clock
    }
  }

  const permissionsBySession: Record<string, string[]> = {}
  const questionsBySession: Record<string, string[]> = {}
  const sessionsInSnapshot = new Set<string>()

  if (snapshot.permissions) {
    for (const item of snapshot.permissions) {
      if (!item.sessionID || !item.id) continue
      sessionsInSnapshot.add(item.sessionID)
      if (!permissionsBySession[item.sessionID]) {
        permissionsBySession[item.sessionID] = []
      }
      if (!permissionsBySession[item.sessionID].includes(item.id)) {
        permissionsBySession[item.sessionID].push(item.id)
      }
    }
  }

  if (snapshot.questions) {
    for (const item of snapshot.questions) {
      if (!item.sessionID || !item.id) continue
      sessionsInSnapshot.add(item.sessionID)
      if (!questionsBySession[item.sessionID]) {
        questionsBySession[item.sessionID] = []
      }
      if (!questionsBySession[item.sessionID].includes(item.id)) {
        questionsBySession[item.sessionID].push(item.id)
      }
    }
  }

  if (sessionsInSnapshot.size === 0) return prev

  const t = clock()
  let changed = false
  const next: StateMap = { ...prev }

  for (const sid of sessionsInSnapshot) {
    const cur = next[sid]
    if (cur && unionOnly) {
      // unionOnly: skip sessions already present in prev
      continue
    }

    const targetPermissions = permissionsBySession[sid] ?? []
    const targetQuestions = questionsBySession[sid] ?? []

    if (!cur) {
      next[sid] = {
        ...fresh(t),
        pendingPermissions: targetPermissions,
        pendingQuestions: targetQuestions,
        revision: 0,
      }
      changed = true
    } else {
      const samePermissions =
        cur.pendingPermissions.length === targetPermissions.length &&
        cur.pendingPermissions.every((val, idx) => val === targetPermissions[idx])
      const sameQuestions =
        cur.pendingQuestions.length === targetQuestions.length &&
        cur.pendingQuestions.every((val, idx) => val === targetQuestions[idx])
      const sameRevision = cur.revision === 0

      if (!samePermissions || !sameQuestions || !sameRevision) {
        next[sid] = {
          ...cur,
          pendingPermissions: targetPermissions,
          pendingQuestions: targetQuestions,
          revision: 0,
          updatedAt: t,
        }
        changed = true
      }
    }
  }

  return changed ? next : prev
}

export const OVERLAY_VERSION = 1

export interface OverlayData {
  version: number
  instanceStamp: number
  pid: number
  serveId: string
  directory?: string
  heartbeat: number
  sessions: StateMap
}

export function serializeOverlay({
  version = OVERLAY_VERSION,
  instanceStamp,
  pid,
  serveId,
  directory,
  heartbeat,
  sessions,
}: Partial<OverlayData> & Omit<OverlayData, "version">): OverlayData {
  return {
    version,
    instanceStamp: instanceStamp ?? 0,
    pid,
    serveId,
    directory,
    heartbeat,
    sessions,
  }
}

export function isPoolServeProcess(cmdline: string, serveId?: string): boolean {
  if (!serveId || !serveId.trim()) return false
  if (!cmdline) return false
  const tokens = cmdline.split("\x00")
  return tokens.length > 1 && tokens[1] === "serve"
}

export type ServePortFenceVerdict = "match" | "mismatch" | "unarmed"

export interface ServePortFenceResult {
  verdict: ServePortFenceVerdict
  /** Why the fence reached this verdict. Carried so the caller can log a
   *  disarmed fence: an unarmed guard is worth exactly nothing, and the
   *  population most likely to present an unreadable serverUrl or a scrubbed
   *  declared port is the nested-serve population this fence exists to stop. */
  reason: string
}

const LOOPBACK_HOSTS = new Set(["localhost", "::1", "[::1]", "::ffff:127.0.0.1"])

function isLoopbackHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/^\[|\]$/g, "")
  if (LOOPBACK_HOSTS.has(h) || LOOPBACK_HOSTS.has(hostname.toLowerCase())) return true
  // 127.0.0.0/8
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h)
}

/**
 * Overlay-writer half of the REGISTRY PORT FENCE (bead pigeon-13p).
 *
 * `opencode-serve-start` EXPORTS OPENCODE_SERVE_EXPECTED_PORT, so every child
 * of a pool serve inherits the slot's declared port. A throwaway
 * `opencode serve` spawned from inside a hosted session therefore carries
 * (say) serve-2's declared 4098 while binding a port of its own -- the
 * 2026-07-25 hijack signature.
 *
 * The routing layer already refuses to REGISTER on that mismatch, but only for
 * a process that claims a routing slot. A nested serve with OPENCODE_ROUTING_DB
 * scrubbed makes no claim, never trips that fence, and still passes this
 * plugin's cmdline check (its argv[1] really is "serve") -- so it would write
 * to the inherited serveId's overlay filename under a different pid. Two live
 * writers then alternate whole-file overwrites, and the same-pid-only silence
 * rule never fires because the pids differ.
 *
 * Comparing against this process's own --port would catch nothing: the
 * throwaway binds the port it asked for. The comparison has to be against the
 * INHERITED declaration.
 *
 * Unset = unarmed, matching the wrapper's own convention, so a plugin update
 * and a wrapper update can land in either order without blacking out the writer.
 */
export function checkServePortFence(
  serverUrl: string | URL | undefined,
  expectedPort: string | undefined,
): ServePortFenceResult {
  const declared = expectedPort?.trim()
  if (!declared) {
    return { verdict: "unarmed", reason: "no declared port (OPENCODE_SERVE_EXPECTED_PORT unset)" }
  }

  let u: URL
  try {
    const parsed = typeof serverUrl === "string" ? new URL(serverUrl) : serverUrl
    if (!parsed) return { verdict: "unarmed", reason: "no serverUrl" }
    u = parsed
  } catch {
    // An unparseable serverUrl is a reason to stay quiet, not to go inert:
    // going inert on a shape we do not understand would black out the writer
    // fleet-wide on an upstream change to ctx.serverUrl. Logged by the caller.
    return { verdict: "unarmed", reason: `unparseable serverUrl: ${String(serverUrl)}` }
  }
  if (!u.port) {
    return { verdict: "unarmed", reason: `serverUrl has no port: ${String(serverUrl)}` }
  }

  // Host IS checked, but only for loopback-ness, never for an exact string.
  //
  // The original justification for ignoring the host entirely was wrong: a pool
  // serve holding 127.0.0.1:4098 does NOT prevent another process binding
  // ::1:4098 or 10.x:4098, because those are different addresses. Verified by
  // experiment. A port-only fence therefore returns "match" for a nested serve
  // that simply picks a different interface, which is precisely the process
  // this fence exists to stop.
  //
  // Comparing the host exactly would be the brittle option -- if ctx.serverUrl
  // ever reported "localhost" or "::1" for a real pool serve, an exact check
  // would read as mismatch and take the writer inert fleet-wide. Loopback
  // equivalence gets the safety without the brittleness: the wrapper pins
  // --hostname 127.0.0.1, so a pool serve is always loopback by construction,
  // and any non-loopback bind cannot be one.
  if (!isLoopbackHost(u.hostname)) {
    return {
      verdict: "mismatch",
      reason: `serving on non-loopback host ${u.hostname}; a pool serve always binds loopback`,
    }
  }

  return u.port === declared
    ? { verdict: "match", reason: `bound port ${u.port} matches declared ${declared}` }
    : { verdict: "mismatch", reason: `bound port ${u.port} != declared ${declared}` }
}

export function getOverlayFilename(serveId: string, directory?: string): string {
  const dirhash = createHash("sha256").update(directory ?? "").digest("hex").slice(0, 16)
  return `${serveId}-${dirhash}.json`
}

let lastStamp = 0
export function generateInstanceStamp(clock: () => number = Date.now): number {
  const t = clock()
  if (t > lastStamp) {
    lastStamp = t
  } else {
    lastStamp += 1
  }
  return lastStamp
}

// A superseding writer must be demonstrably ALIVE before we stand down. Without
// this, a stale file left by a crashed process whose pid got recycled onto us
// could silence the real writer permanently: same pid, and a stamp from a
// long-lived predecessor that is trivially greater than a freshly-started
// instance's. Requiring a fresh heartbeat means only a writer that is actually
// still flushing can take the file away from us.
export const LIVE_WRITER_MS = 60_000

export function shouldGoSilent(opts: {
  existingPid?: number
  existingStamp?: number
  existingHeartbeat?: number
  ourPid: number
  ourStamp: number
  now?: number
  liveWriterMs?: number
}): boolean {
  if (opts.existingPid === undefined || opts.existingStamp === undefined) {
    return false
  }
  // Never stand down for a foreign pid -- that is the D4 hazard, where a stray
  // process could permanently silence the real serve's writer.
  if (opts.existingPid !== opts.ourPid) return false
  if (opts.existingStamp <= opts.ourStamp) return false

  const now = opts.now ?? Date.now()
  const liveWindow = opts.liveWriterMs ?? LIVE_WRITER_MS
  if (opts.existingHeartbeat === undefined) return false
  return now - opts.existingHeartbeat <= liveWindow
}

export const IDLE_EVICTION_MS = 45 * 60 * 1000
// Hard cap for entries that still claim to be working/retrying. Only reached
// when an idle event was lost; a genuine turn does not run this long.
export const WORKING_EVICTION_MS = 6 * 60 * 60 * 1000

export function evictIdleSessions(
  prev: StateMap,
  clock: (() => number) | number = Date.now,
  maxAgeMs = IDLE_EVICTION_MS,
  workingMaxAgeMs = WORKING_EVICTION_MS,
): StateMap {
  const t = typeof clock === "number" ? clock : clock()
  let changed = false
  const next: StateMap = {}

  for (const [sid, entry] of Object.entries(prev)) {
    const age = t - entry.lastActivity
    const hasPending =
      entry.pendingPermissions.length > 0 || entry.pendingQuestions.length > 0
    const hasError = entry.error

    // `activity` MUST be consulted. lastActivity only advances on events the
    // reducer handles, and a long autonomous turn emits `session.status{busy}`
    // once and then nothing the reducer cares about. Evicting on age alone
    // therefore deletes sessions that are still mid-turn, and since the reader
    // treats absent as idle, the longest-running sessions -- exactly the ones
    // the picker exists to surface -- would report "idle" while working.
    const isWorking = entry.activity !== "idle"

    // The flip side: if an `idle` event is ever missed, a stuck-`working` entry
    // would otherwise live forever. A turn still "working" after this long is
    // far more likely to be a lost idle event than a real turn, so a much
    // longer hard cap still collects it.
    const evictable = isWorking ? age > workingMaxAgeMs : age > maxAgeMs

    if (evictable && !hasPending && !hasError) {
      changed = true
    } else {
      next[sid] = entry
    }
  }

  return changed ? next : prev
}

export async function fetchPendingSnapshot(
  fetchFn: typeof fetch,
  serverUrl: string | URL,
  directory?: string,
): Promise<Snapshot> {
  try {
    const baseUrl = (typeof serverUrl === "string" ? serverUrl : serverUrl.href).replace(/\/$/, "")
    const dirParam = directory ? `?directory=${encodeURIComponent(directory)}` : ""
    const [permRes, questRes] = await Promise.all([
      fetchFn(`${baseUrl}/permission${dirParam}`),
      fetchFn(`${baseUrl}/question${dirParam}`),
    ])
    if (!permRes.ok || !questRes.ok) return {}
    const permissions = await permRes.json()
    const questions = await questRes.json()
    return {
      permissions: Array.isArray(permissions) ? permissions : [],
      questions: Array.isArray(questions) ? questions : [],
    }
  } catch {
    return {}
  }
}
