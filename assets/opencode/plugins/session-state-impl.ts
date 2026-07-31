export type Activity = "working" | "blocked" | "idle" | "retry" | "error" | "unknown"

export interface SessionEntry {
  activity: "working" | "idle" | "retry" // raw status axis
  error: boolean // sticky until next busy
  pendingPermissions: string[]
  pendingQuestions: string[]
  retry?: { attempt: number; next: number }
  lastActivity: number
  updatedAt: number
  revision?: number
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
      e.pendingPermissions = [...new Set([...e.pendingPermissions, p.id])]
      bump()
      break
    // Asymmetry: .replied / .rejected events carry key in properties.requestID
    case "permission.replied":
      e.pendingPermissions = e.pendingPermissions.filter((x) => x !== p.requestID)
      bump()
      break
    case "question.asked":
      e.pendingQuestions = [...new Set([...e.pendingQuestions, p.id])]
      bump()
      break
    case "question.replied":
    case "question.rejected":
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
  if (e.error) return "error"
  if (e.pendingPermissions.length || e.pendingQuestions.length) return "blocked"
  return e.activity
}

export interface Snapshot {
  permissions?: Array<{ sessionID: string; id: string }>
  questions?: Array<{ sessionID: string; id: string }>
}

export function seedFromSnapshot(
  prev: StateMap,
  snapshot: Snapshot,
  clock = now,
): StateMap {
  const t = clock()
  const next: StateMap = { ...prev }

  const getOrCreate = (sid: string): SessionEntry => {
    if (!next[sid]) {
      next[sid] = {
        ...fresh(t),
        revision: 0,
      }
    } else {
      next[sid] = { ...next[sid], revision: next[sid].revision ?? 0 }
    }
    return next[sid]
  }

  if (snapshot.permissions) {
    for (const item of snapshot.permissions) {
      if (!item.sessionID || !item.id) continue
      const entry = getOrCreate(item.sessionID)
      if (!entry.pendingPermissions.includes(item.id)) {
        entry.pendingPermissions = [...entry.pendingPermissions, item.id]
        entry.updatedAt = t
      }
    }
  }

  if (snapshot.questions) {
    for (const item of snapshot.questions) {
      if (!item.sessionID || !item.id) continue
      const entry = getOrCreate(item.sessionID)
      if (!entry.pendingQuestions.includes(item.id)) {
        entry.pendingQuestions = [...entry.pendingQuestions, item.id]
        entry.updatedAt = t
      }
    }
  }

  return next
}
