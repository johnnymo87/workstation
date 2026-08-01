import {
  OVERLAY_VERSION,
  type OverlayData,
  type SessionEntry,
  type StateMap,
} from "./session-state-impl"

export interface MergeOptions {
  now: number
  staleMs: number
  isAlive: (pid: number) => boolean
  /**
   * owners must be keyed by EVERY session id the caller wants arbitrated, including child/subagent sessions.
   * The routing daemon only stores rows for the ROOT of a session tree, so the caller is responsible
   * for resolving each session to its root and mapping the root's owner onto the child.
   * A missing entry here is not an error — it just means rule 1 cannot fire.
   */
  owners?: Record<string, string>
}

/**
 * Entry-level validation.
 *
 * lastActivity and activity are load-bearing for the merge, so they must be
 * checked or a same-version skewed entry decides the winner: compareCandidates
 * does `b.lastActivity - a.lastActivity`, a non-numeric value makes that NaN,
 * every NaN comparison is false, and the sort therefore collapses to whatever
 * order readdir returned.
 *
 * Deliberately applied PER ENTRY rather than per file. Rejecting a whole file
 * for one malformed entry does not just hide that entry -- it removes the
 * owning serve's file from the candidate set, so the owner-preference rule
 * finds no owner file and a stale (or dead) file from a different serve wins
 * the session instead. One skewed entry would resurrect outdated state for all
 * of its healthy siblings.
 *
 * That matters because the writer ships in a nix bundle that auto-updates every
 * 8 hours while the reader ships by a different vehicle. Any additive drift
 * within the same OVERLAY_VERSION -- a writer emitting an activity value the
 * reader has not learned yet -- would otherwise blind that serve completely
 * until the reader caught up. Dropping the unknown entry degrades one session;
 * dropping the file degrades every session on that serve.
 */
export function isValidEntry(entry: any): boolean {
  if (!entry || typeof entry !== "object") return false
  const e = entry as any
  if (!Array.isArray(e.pendingPermissions) || !Array.isArray(e.pendingQuestions)) return false
  if (typeof e.lastActivity !== "number" || !Number.isFinite(e.lastActivity)) return false
  if (typeof e.updatedAt !== "number" || !Number.isFinite(e.updatedAt)) return false
  if (e.activity !== "working" && e.activity !== "idle" && e.activity !== "retry") return false
  if (typeof e.error !== "boolean") return false
  return true
}

/** File-level validation only. Entry shape is filtered separately, per entry. */
export function isValidOverlay(f: any): f is OverlayData {
  if (!f || typeof f !== "object") return false
  if (f.version !== OVERLAY_VERSION) return false
  if (typeof f.pid !== "number") return false
  if (typeof f.serveId !== "string") return false
  if (typeof f.heartbeat !== "number") return false
  if (!f.sessions || typeof f.sessions !== "object" || Array.isArray(f.sessions)) return false
  return true
}

/** Returns a copy of the overlay with only the well-formed session entries. */
export function withValidEntriesOnly(f: OverlayData): OverlayData {
  const sessions: Record<string, any> = {}
  for (const [sid, entry] of Object.entries(f.sessions ?? {})) {
    if (isValidEntry(entry)) sessions[sid] = entry
  }
  return { ...f, sessions } as OverlayData
}

export interface PreparedFile {
  file: OverlayData
  serveId: string
  pid: number
  live: boolean
}

// Deterministic tie-breaker when lastActivity is equal:
// Sorts candidates descending by lastActivity, then serveId descending, then pid descending.
export function compareCandidates(
  c1: { file: PreparedFile; entry: SessionEntry },
  c2: { file: PreparedFile; entry: SessionEntry },
): number {
  if (c1.entry.lastActivity !== c2.entry.lastActivity) {
    return c2.entry.lastActivity - c1.entry.lastActivity
  }
  if (c1.file.serveId !== c2.file.serveId) {
    return c1.file.serveId > c2.file.serveId ? -1 : 1
  }
  return c2.file.pid - c1.file.pid
}

/**
 * Validate and stamp liveness onto overlay files.
 *
 * Extracted so that `queryWithState`'s nodata predicate can ask "is this serve
 * still reporting?" using THE SAME definition of live that decides the merge.
 * Reimplementing `isAlive(pid) && now - heartbeat <= staleMs` at the join site
 * would let the two drift apart on any future change (EPERM nuance,
 * instanceStamp fencing, staleMs semantics) -- and a reader that disagrees with
 * itself about liveness produces exactly the wrong-confidence bug this module
 * exists to prevent.
 */
export function prepareFiles(
  files: OverlayData[],
  { now, staleMs, isAlive }: Pick<MergeOptions, "now" | "staleMs" | "isAlive">,
): PreparedFile[] {
  const validFiles = (Array.isArray(files) ? files.filter(isValidOverlay) : []).map(
    withValidEntriesOnly,
  )
  return validFiles.map((f) => ({
    file: f,
    serveId: f.serveId,
    pid: f.pid,
    live: isAlive(f.pid) && now - f.heartbeat <= staleMs,
  }))
}

export function mergeOverlays(
  files: OverlayData[],
  { now, staleMs, isAlive, owners = {} }: MergeOptions,
): StateMap {
  const prepared: PreparedFile[] = prepareFiles(files, { now, staleMs, isAlive })

  // Collect all session IDs across all files
  const sessionIds = new Set<string>()
  for (const pf of prepared) {
    if (pf.file.sessions) {
      for (const sid of Object.keys(pf.file.sessions)) {
        sessionIds.add(sid)
      }
    }
  }

  const result: StateMap = {}

  for (const sid of sessionIds) {
    const candidates: Array<{ file: PreparedFile; entry: SessionEntry }> = []
    for (const pf of prepared) {
      const entry = pf.file.sessions?.[sid]
      if (entry) {
        candidates.push({ file: pf, entry })
      }
    }

    if (candidates.length === 0) continue

    const ownerServeId = owners[sid]
    let winner: { file: PreparedFile; entry: SessionEntry } | undefined

    // Rule 1: A live file whose serveId === owners[sid] for session's directory wins outright.
    // If live owner exists for the directory but does not mention sid, owner claims idle (emit nothing).
    if (ownerServeId) {
      const sessionDirectories = new Set<string | undefined>()
      for (const c of candidates) {
        sessionDirectories.add(c.file.file.directory)
      }
      const ownerFiles = prepared.filter(
        (pf) =>
          pf.live &&
          pf.serveId === ownerServeId &&
          sessionDirectories.has(pf.file.directory),
      )
      if (ownerFiles.length > 0) {
        const ownerLiveCandidates = candidates.filter(
          (c) => c.file.live && c.file.serveId === ownerServeId,
        )
        if (ownerLiveCandidates.length > 0) {
          ownerLiveCandidates.sort(compareCandidates)
          winner = ownerLiveCandidates[0]
        } else {
          // Live owner is authoritative for this directory and says nothing -> session is idle
          continue
        }
      }
    }

    // Rule 2: Else the live file with the greatest lastActivity
    if (!winner) {
      const liveCandidates = candidates.filter((c) => c.file.live)
      if (liveCandidates.length > 0) {
        liveCandidates.sort(compareCandidates)
        winner = liveCandidates[0]
      }
    }

    // Rule 3: Else the dead file with the greatest lastActivity
    if (!winner) {
      const deadCandidates = candidates.filter((c) => !c.file.live)
      if (deadCandidates.length > 0) {
        deadCandidates.sort(compareCandidates)
        winner = deadCandidates[0]
      }
    }

    if (!winner) continue

    let finalEntry: SessionEntry
    if (!winner.file.live) {
      finalEntry = {
        ...winner.entry,
        unknown: true,
        pendingPermissions: [],
        pendingQuestions: [],
      }
    } else {
      finalEntry = { ...winner.entry }
    }

    // Prune plain idle entries (absent == idle) unless flagged unknown
    const isPlainIdle =
      finalEntry.activity === "idle" &&
      finalEntry.pendingPermissions.length === 0 &&
      finalEntry.pendingQuestions.length === 0 &&
      !finalEntry.error &&
      !finalEntry.unknown

    if (!isPlainIdle) {
      result[sid] = finalEntry
    }
  }

  return result
}
