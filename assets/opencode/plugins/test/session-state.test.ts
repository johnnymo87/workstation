import { describe, it, expect } from "vitest"
import {
  applyEvent,
  effectiveState,
  emptyState,
  seedFromSnapshot,
  serializeOverlay,
  mergeOverlays,
  checkServePortFence,
  isPoolServeProcess,
  getOverlayFilename,
  generateInstanceStamp,
  shouldGoSilent,
  evictIdleSessions,
  type SessionEntry,
  fetchPendingSnapshot,
  type OverlayData,
  type StateMap,
} from "../session-state-impl"

const ev = (type: string, properties: any) => ({ type, properties })

describe("applyEvent", () => {
  it("busy -> working; idle -> idle", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(effectiveState(s.s1)).toBe("working")
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("idle")
  })

  it("permission.asked(id) -> blocked; replied(requestID) clears", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    expect(effectiveState(s.s1)).toBe("idle")
  })

  it("two permissions pend as a set; one reply keeps blocked", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p2" }))
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
  })

  it("question.asked(id) -> blocked; replied(requestID) clears", () => {
    let s = applyEvent(emptyState(), ev("question.asked", { sessionID: "s1", id: "q1" }))
    expect(effectiveState(s.s1)).toBe("blocked")
    s = applyEvent(s, ev("question.rejected", { sessionID: "s1", requestID: "q1" }))
    expect(effectiveState(s.s1)).toBe("idle")
  })

  it("abort-while-pending: idle clears pending sets", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("idle")
  })

  it("retry -> retry", () => {
    const s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "retry", attempt: 2, message: "429", next: 2000 } }))
    expect(effectiveState(s.s1)).toBe("retry")
  })

  it("error is STICKY: error then idle is still error", () => {
    let s = applyEvent(emptyState(), ev("session.error", { sessionID: "s1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }))
    expect(effectiveState(s.s1)).toBe("error")
  })

  it("error cleared by next busy (new turn)", () => {
    let s = applyEvent(emptyState(), ev("session.error", { sessionID: "s1" }))
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(effectiveState(s.s1)).toBe("working")
  })

  it("error with no sessionID is ignored", () => {
    expect(applyEvent(emptyState(), ev("session.error", {}))).toEqual({})
  })

  it("unrelated events create no entry and don't mutate", () => {
    const before = emptyState()
    expect(applyEvent(before, ev("message.part.updated", { sessionID: "s1" }))).toBe(before)
  })

  it("idle when already idle is a no-op (does not reset lastActivity)", () => {
    let time = 1000
    const clock = () => ++time
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }), clock)
    s = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }), clock)
    const t = s.s1.lastActivity
    const s2 = applyEvent(s, ev("session.status", { sessionID: "s1", status: { type: "idle" } }), clock)
    expect(s2).toBe(s)
    expect(s2.s1.lastActivity).toBe(t)
  })

  it("duplicate permission.asked or question.asked returns identical object reference (no-op)", () => {
    let time = 1000
    const clock = () => ++time
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }), clock)
    const t = s.s1.lastActivity
    const s2 = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }), clock)
    expect(s2).toBe(s)
    expect(s2.s1.lastActivity).toBe(t)

    let sq = applyEvent(emptyState(), ev("question.asked", { sessionID: "s1", id: "q1" }), clock)
    const sq2 = applyEvent(sq, ev("question.asked", { sessionID: "s1", id: "q1" }), clock)
    expect(sq2).toBe(sq)
  })

  it("permission.replied or question.replied/rejected for unknown requestID returns identical object reference", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    const s2 = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p_unknown" }))
    expect(s2).toBe(s)

    let sq = applyEvent(emptyState(), ev("question.asked", { sessionID: "s1", id: "q1" }))
    const sq2 = applyEvent(sq, ev("question.replied", { sessionID: "s1", requestID: "q_unknown" }))
    expect(sq2).toBe(sq)
  })

  it("permission.asked and question.asked require an id; replied/rejected require requestID", () => {
    const s = emptyState()
    expect(applyEvent(s, ev("permission.asked", { sessionID: "s1" }))).toBe(s)
    expect(applyEvent(s, ev("question.asked", { sessionID: "s1" }))).toBe(s)

    const sWithPerm = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(applyEvent(sWithPerm, ev("permission.replied", { sessionID: "s1" }))).toBe(sWithPerm)
    expect(applyEvent(sWithPerm, ev("question.replied", { sessionID: "s1" }))).toBe(sWithPerm)
    expect(applyEvent(sWithPerm, ev("question.rejected", { sessionID: "s1" }))).toBe(sWithPerm)
  })
})

describe("seedFromSnapshot", () => {
  it("seedFromSnapshot marks sessions with already-pending permissions as blocked", () => {
    const s = seedFromSnapshot(emptyState(), {
      permissions: [{ sessionID: "s1", id: "p1" }],
      questions: [{ sessionID: "s2", id: "q1" }],
    })
    expect(effectiveState(s.s1)).toBe("blocked")
    expect(effectiveState(s.s2)).toBe("blocked")
    expect(s.s1.revision).toBe(0)
    expect(s.s2.revision).toBe(0)
  })

  it("seedFromSnapshot with unionOnly (default): snapshot for unseen session seeds pending prompts", () => {
    const s = seedFromSnapshot(emptyState(), {
      permissions: [{ sessionID: "s1", id: "p1" }],
      questions: [{ sessionID: "s2", id: "q1" }],
    })
    expect(effectiveState(s.s1)).toBe("blocked")
    expect(effectiveState(s.s2)).toBe("blocked")
    expect(s.s1.pendingPermissions).toEqual(["p1"])
    expect(s.s2.pendingQuestions).toEqual(["q1"])
    expect(s.s1.revision).toBe(0)
    expect(s.s2.revision).toBe(0)
  })

  it("seedFromSnapshot with unionOnly (default): snapshot for session already having event-derived entry is IGNORED entirely", () => {
    // Stream state where p1 was asked then replied to (pending empty), and new prompt p2 was asked
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p2" }))
    const initialRev = s.s1.revision

    // Late-landing snapshot that still lists p1 (which stream replied to) and does NOT list p2 (asked after snapshot)
    const seeded = seedFromSnapshot(s, {
      permissions: [{ sessionID: "s1", id: "p1" }],
    })

    // Must NOT resurrect p1, must NOT drop p2, must NOT stomp revision
    expect(seeded).toBe(s)
    expect(seeded.s1.pendingPermissions).toEqual(["p2"])
    expect(seeded.s1.revision).toBe(initialRev)
  })

  it("authoritative for sessions named in snapshot when unionOnly is false", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s2", id: "p2" }))

    s = seedFromSnapshot(s, {
      permissions: [{ sessionID: "s1", id: "p_new" }],
    }, { unionOnly: false })

    expect(s.s1.pendingPermissions).toEqual(["p_new"])
    expect(effectiveState(s.s1)).toBe("blocked")

    expect(s.s2.pendingPermissions).toEqual(["p2"])
    expect(effectiveState(s.s2)).toBe("blocked")
  })

  it("empty snapshot or no-change snapshot returns identical prev object reference", () => {
    const s0 = emptyState()
    const s1 = seedFromSnapshot(s0, {})
    expect(s1).toBe(s0)

    const state = seedFromSnapshot(s0, {
      permissions: [{ sessionID: "s1", id: "p1" }],
    })
    const state2 = seedFromSnapshot(state, {
      permissions: [{ sessionID: "s1", id: "p1" }],
    })
    expect(state2).toBe(state)
  })
})

describe("revision tracking", () => {
  it("two successive committing events on one session produce a strictly increasing revision", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    expect(s.s1.revision).toBe(1)
    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(s.s1.revision).toBe(2)
  })

  it("a no-op event does not change revision and returns identical object reference", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    const rev = s.s1.revision
    const s2 = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(s2).toBe(s)
    expect(s2.s1.revision).toBe(rev)
  })

  it("a seeded entry starts at revision 0 and a subsequent real event increments it above 0", () => {
    let s = seedFromSnapshot(emptyState(), {
      permissions: [{ sessionID: "s1", id: "p1" }],
    })
    expect(s.s1.revision).toBe(0)
    s = applyEvent(s, ev("permission.replied", { sessionID: "s1", requestID: "p1" }))
    expect(s.s1.revision).toBe(1)
  })

  it("revisions are independent per session", () => {
    let s = applyEvent(emptyState(), ev("session.status", { sessionID: "s1", status: { type: "busy" } }))
    s = applyEvent(s, ev("session.status", { sessionID: "s2", status: { type: "busy" } }))
    expect(s.s1.revision).toBe(1)
    expect(s.s2.revision).toBe(1)

    s = applyEvent(s, ev("permission.asked", { sessionID: "s1", id: "p1" }))
    expect(s.s1.revision).toBe(2)
    expect(s.s2.revision).toBe(1)
  })
})

describe("serializeOverlay", () => {
  it("stamps version and includes instanceStamp without adding an epoch field", () => {
    const input: OverlayData = {
      version: 1,
      instanceStamp: 12345678,
      pid: 1234,
      serveId: "serve-1",
      directory: "/path/to/project",
      heartbeat: 1000,
      sessions: {
        s1: {
          activity: "working",
          error: false,
          pendingPermissions: [],
          pendingQuestions: [],
          lastActivity: 500,
          updatedAt: 500,
        },
      },
    }
    const serialized = serializeOverlay(input)
    expect(serialized).toEqual(input)
    expect(serialized.version).toBe(1)
    expect(serialized.instanceStamp).toBe(12345678)
    expect((serialized as any).epoch).toBeUndefined()
  })
})

describe("mergeOverlays", () => {
  const entry = (over: any = {}) => ({
    activity: "working",
    error: false,
    pendingPermissions: [],
    pendingQuestions: [],
    lastActivity: 10,
    updatedAt: 10,
    revision: 1,
    ...over,
  })
  const file = (
    serveId: string,
    pid: number,
    sessions: any,
    heartbeat = 1000,
    directory?: string,
    version = 1,
    instanceStamp = 100,
  ): OverlayData => ({ version, instanceStamp, serveId, pid, heartbeat, directory, sessions })
  const opts = (over: any = {}) => ({
    now: 1000,
    staleMs: 45000,
    isAlive: () => true,
    owners: {},
    ...over,
  })

  it("owner wins even when its wall clock is OLDER (migration)", () => {
    const old = file("serve-0", 1, {
      s1: entry({
        activity: "idle",
        pendingPermissions: [],
        lastActivity: 999,
        revision: 9,
      }),
    })
    const cur = file("serve-1", 2, {
      s1: entry({
        activity: "working",
        pendingPermissions: ["p1"],
        lastActivity: 10,
        revision: 1,
      }),
    })
    const m = mergeOverlays([old, cur], opts({ owners: { s1: "serve-1" } }))
    expect(m.s1.pendingPermissions).toEqual(["p1"])
  })

  it("higher revision does NOT win across files (revision is per-writer)", () => {
    const a = file("serve-0", 1, {
      s1: entry({ activity: "idle", lastActivity: 10, revision: 400 }),
    })
    const b = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 999, revision: 3 }),
    })
    const m = mergeOverlays([a, b], opts())
    expect(m.s1.activity).toBe("working")
  })

  it("no owner entry -> freshest lastActivity among live wins", () => {
    const a = file("serve-0", 1, {
      s1: entry({ activity: "idle", lastActivity: 500 }),
    })
    const b = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 900 }),
    })
    expect(mergeOverlays([a, b], opts()).s1.activity).toBe("working")
  })

  it("owner pointing at a DEAD serve does not win; a live observer speaks", () => {
    const dead = file("serve-0", 999, {
      s1: entry({ activity: "idle", lastActivity: 999 }),
    })
    const live = file("serve-1", 2, {
      s1: entry({
        activity: "working",
        pendingPermissions: ["p1"],
        lastActivity: 10,
      }),
    })
    const m = mergeOverlays(
      [dead, live],
      opts({ owners: { s1: "serve-0" }, isAlive: (pid: number) => pid === 2 }),
    )
    expect(m.s1.unknown).toBeFalsy()
    expect(m.s1.pendingPermissions).toEqual(["p1"])
  })

  it("dead pid and stale heartbeat -> entries flagged unknown, NOT dropped", () => {
    const deadPid = file("serve-0", 999, { s2: entry() })
    const stale = file("serve-1", 2, { s3: entry() }, 900)
    const m = mergeOverlays(
      [deadPid, stale],
      opts({ staleMs: 45, isAlive: (pid: number) => pid === 2 }),
    )
    expect(m.s2.unknown).toBe(true)
    expect(m.s3.unknown).toBe(true)
  })

  it("unknown entries clear pending sets (never assert a block nobody is holding)", () => {
    const dead = file("serve-0", 999, {
      s1: entry({
        pendingPermissions: ["p1"],
        pendingQuestions: ["q1"],
      }),
    })
    const m = mergeOverlays([dead], opts({ isAlive: () => false }))
    expect(m.s1.pendingPermissions).toEqual([])
    expect(m.s1.pendingQuestions).toEqual([])
  })

  it("prunes plain idle entries from live files (absent == idle), but preserves unknown entries", () => {
    const liveFile = file("serve-0", 1, {
      plainIdle: entry({ activity: "idle", error: false }),
      idleWithError: entry({ activity: "idle", error: true }),
      idleWithPerm: entry({
        activity: "idle",
        pendingPermissions: ["p1"],
      }),
      idleWithQuest: entry({
        activity: "idle",
        pendingQuestions: ["q1"],
      }),
      workingSession: entry({ activity: "working" }),
    })
    const deadFile = file("serve-1", 999, {
      deadPlainIdle: entry({ activity: "idle", error: false }),
    })

    const m = mergeOverlays(
      [liveFile, deadFile],
      opts({ isAlive: (pid: number) => pid === 1 }),
    )

    expect(m.plainIdle).toBeUndefined()
    expect(m.idleWithError).toBeDefined()
    expect(m.idleWithPerm).toBeDefined()
    expect(m.idleWithQuest).toBeDefined()
    expect(m.workingSession).toBeDefined()
    expect(m.deadPlainIdle).toBeDefined()
    expect(m.deadPlainIdle.unknown).toBe(true)
  })

  it("handles empty files array and handles missing owners map gracefully", () => {
    expect(mergeOverlays([], opts())).toEqual({})

    const f = file("serve-0", 1, { s1: entry({ activity: "working" }) })
    const m = mergeOverlays([f], {
      now: 1000,
      staleMs: 45000,
      isAlive: () => true,
    })
    expect(m.s1.activity).toBe("working")
  })

  it("breaks ties in equal lastActivity deterministically using serveId and pid", () => {
    const fileA = file("serve-0", 10, {
      s1: entry({ activity: "working", lastActivity: 500 }),
    })
    const fileB = file("serve-1", 20, {
      s1: entry({ activity: "retry", lastActivity: 500 }),
    })

    const m1 = mergeOverlays([fileA, fileB], opts())
    const m2 = mergeOverlays([fileB, fileA], opts())

    expect(m1.s1.activity).toEqual(m2.s1.activity)
  })

  it("D1 regression: live owner file for directory without sid suppresses stale non-owner entry", () => {
    const ownerFile = file("serve-0", 1, {}, 1000, "/path/to/repo")
    const staleFile = file("serve-1", 2, {
      s1: entry({
        activity: "idle",
        pendingPermissions: ["p1"],
        lastActivity: 2000,
      }),
    }, 1000, "/path/to/repo")

    const m = mergeOverlays([ownerFile, staleFile], opts({ owners: { s1: "serve-0" } }))
    expect(m.s1).toBeUndefined()
  })

  it("owner file for a DIFFERENT directory does NOT suppress session", () => {
    const ownerFileDiffDir = file("serve-0", 1, {}, 1000, "/path/other")
    const peerFile = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 2000 }),
    }, 1000, "/path/to/repo")

    const m = mergeOverlays([ownerFileDiffDir, peerFile], opts({ owners: { s1: "serve-0" } }))
    expect(m.s1).toBeDefined()
    expect(m.s1.activity).toBe("working")
  })

  it("rule 1 wins normally when owner file DOES contain sid", () => {
    const ownerFile = file("serve-0", 1, {
      s1: entry({ activity: "idle", pendingPermissions: ["p1"], lastActivity: 1000 }),
    }, 1000, "/path/to/repo")
    const peerFile = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 2000 }),
    }, 1000, "/path/to/repo")

    const m = mergeOverlays([ownerFile, peerFile], opts({ owners: { s1: "serve-0" } }))
    expect(m.s1.pendingPermissions).toEqual(["p1"])
  })

  it("crashed/dead owner falls through to rule 2", () => {
    const deadOwnerFile = file("serve-0", 999, {
      s1: entry({ activity: "idle", lastActivity: 500 }),
    }, 1000, "/path/to/repo")
    const peerFile = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 2000 }),
    }, 1000, "/path/to/repo")

    const m = mergeOverlays(
      [deadOwnerFile, peerFile],
      opts({ owners: { s1: "serve-0" }, isAlive: (pid: number) => pid === 2 }),
    )
    expect(m.s1.activity).toBe("working")
  })

  it("defensive merge: ignores file with version !== OVERLAY_VERSION", () => {
    const good = file("serve-0", 1, { s1: entry({ activity: "working" }) }, 1000, "/path", 1)
    const badVersion = file("serve-1", 2, { s1: entry({ activity: "idle" }) }, 1000, "/path", 999)
    const m = mergeOverlays([good, badVersion as any], opts())
    expect(m.s1.activity).toBe("working")
  })

  it("defensive merge: ignores malformed files (null, missing pid/serveId/heartbeat, missing sessions)", () => {
    const good = file("serve-0", 1, { s1: entry({ activity: "working" }) }, 1000)
    const garbage1 = null
    const garbage2 = "not an object"
    const missingPid = { version: 1, serveId: "s", heartbeat: 1000, sessions: {} }
    const missingServeId = { version: 1, pid: 1, heartbeat: 1000, sessions: {} }
    const missingHeartbeat = { version: 1, pid: 1, serveId: "s", sessions: {} }
    const missingSessions = { version: 1, pid: 1, serveId: "s", heartbeat: 1000 }
    const nonObjSessions = { version: 1, pid: 1, serveId: "s", heartbeat: 1000, sessions: "invalid" }

    const m = mergeOverlays(
      [good, garbage1, garbage2, missingPid, missingServeId, missingHeartbeat, missingSessions, nonObjSessions] as any,
      opts(),
    )
    expect(m.s1.activity).toBe("working")
  })

  it("defensive merge: ignores file whose entry lacks pendingPermissions or pendingQuestions array", () => {
    const good = file("serve-0", 1, { s1: entry({ activity: "working" }) }, 1000)
    const badEntry1 = file("serve-1", 2, { s1: { activity: "idle", pendingQuestions: [] } }, 1000) // missing pendingPermissions
    const badEntry2 = file("serve-2", 3, { s1: { activity: "idle", pendingPermissions: [] } }, 1000) // missing pendingQuestions

    const m = mergeOverlays([good, badEntry1 as any, badEntry2 as any], opts())
    expect(m.s1.activity).toBe("working")
  })

  it("handles undefined directory matching correctly", () => {
    const ownerFileUndefDir = file("serve-0", 1, {}, 1000, undefined)
    const peerFileUndefDir = file("serve-1", 2, {
      s1: entry({ activity: "working", lastActivity: 2000 }),
    }, 1000, undefined)

    const m = mergeOverlays([ownerFileUndefDir, peerFileUndefDir], opts({ owners: { s1: "serve-0" } }))
    expect(m.s1).toBeUndefined()
  })
})

describe("isPoolServeProcess", () => {
  it("returns true for a real pool serve cmdline with valid serveId", () => {
    const cmdline = "/home/dev/.nix-profile/bin/opencode\x00serve\x00--port\x004096\x00--hostname\x00127.0.0.1\x00"
    expect(isPoolServeProcess(cmdline, "serve-0")).toBe(true)
  })

  it("returns false for nested opencode run process", () => {
    const cmdline = "/home/dev/.nix-profile/bin/opencode\x00run\x00some-args\x00"
    expect(isPoolServeProcess(cmdline, "serve-0")).toBe(false)
  })

  it("returns false for opencode without serve argument", () => {
    const cmdline = "/bin/opencode\x00"
    expect(isPoolServeProcess(cmdline, "serve-0")).toBe(false)
  })

  it("returns false when serveId is missing or empty", () => {
    const cmdline = "/home/dev/.nix-profile/bin/opencode\x00serve\x00"
    expect(isPoolServeProcess(cmdline, undefined)).toBe(false)
    expect(isPoolServeProcess(cmdline, "")).toBe(false)
    expect(isPoolServeProcess(cmdline, "   ")).toBe(false)
  })

  it("returns false for empty or invalid cmdline", () => {
    expect(isPoolServeProcess("", "serve-0")).toBe(false)
  })
})

describe("getOverlayFilename", () => {
  it("produces filename with serveId and sha256 dirhash", () => {
    const name = getOverlayFilename("serve-0", "/home/dev/projects/workstation")
    expect(name).toMatch(/^serve-0-[0-9a-f]{16}\.json$/)
  })

  it("produces distinct filenames for same-prefix directory paths", () => {
    const name1 = getOverlayFilename("serve-0", "/a/b")
    const name2 = getOverlayFilename("serve-0", "/a/bc")
    expect(name1).not.toEqual(name2)
  })
})

describe("generateInstanceStamp", () => {
  it("strictly increases on successive calls even with identical clock timestamp", () => {
    const staticClock = () => 100000
    const stamp1 = generateInstanceStamp(staticClock)
    const stamp2 = generateInstanceStamp(staticClock)
    expect(stamp2).toBeGreaterThan(stamp1)
  })
})

describe("shouldGoSilent", () => {
  it("returns true when existing pid matches our pid AND existing stamp is strictly newer", () => {
    expect(
      shouldGoSilent({
        existingPid: 100,
        existingStamp: 200,
        existingHeartbeat: 1_000_000,
        ourPid: 100,
        ourStamp: 100,
        now: 1_000_000,
      }),
    ).toBe(true)
  })

  it("returns false when existing pid matches our pid BUT existing stamp is older or equal", () => {
    expect(
      shouldGoSilent({ existingPid: 100, existingStamp: 50, ourPid: 100, ourStamp: 100 }),
    ).toBe(false)
    expect(
      shouldGoSilent({ existingPid: 100, existingStamp: 100, ourPid: 100, ourStamp: 100 }),
    ).toBe(false)
  })

  it("returns FALSE when existing pid does NOT match our pid (foreign writer must not silence us)", () => {
    expect(
      shouldGoSilent({ existingPid: 999, existingStamp: 200, ourPid: 100, ourStamp: 100 }),
    ).toBe(false)
  })

  it("returns FALSE when the superseding writer is STALE (pid reuse after a crash)", () => {
    // A crashed long-lived process can leave a file whose stamp is far greater
    // than a freshly-started instance's. If its pid gets recycled onto us, an
    // unqualified stamp comparison would make the REAL writer silence itself
    // forever against a dead predecessor. Only a live writer may take over.
    expect(
      shouldGoSilent({
        existingPid: 100,
        existingStamp: 9_999_999,
        existingHeartbeat: 1_000_000 - 10 * 60 * 1000, // 10 min stale
        ourPid: 100,
        ourStamp: 100,
        now: 1_000_000,
      }),
    ).toBe(false)
  })

  it("returns false when the existing file has no heartbeat at all", () => {
    expect(
      shouldGoSilent({ existingPid: 100, existingStamp: 200, ourPid: 100, ourStamp: 100, now: 1_000_000 }),
    ).toBe(false)
  })

  it("returns false when existing file is missing or corrupt (undefined pid/stamp)", () => {
    expect(shouldGoSilent({ existingPid: undefined, existingStamp: 200, ourPid: 100, ourStamp: 100 })).toBe(false)
    expect(shouldGoSilent({ existingPid: 100, existingStamp: undefined, ourPid: 100, ourStamp: 100 })).toBe(false)
  })
})

describe("evictIdleSessions", () => {
  const entry = (over: any = {}) => ({
    activity: "idle",
    error: false,
    pendingPermissions: [],
    pendingQuestions: [],
    lastActivity: 1000,
    updatedAt: 1000,
    revision: 1,
    ...over,
  })

  it("evicts plain-idle session older than maxAgeMs", () => {
    const prev: StateMap = {
      oldIdle: entry({ lastActivity: 1000 }),
    }
    const next = evictIdleSessions(prev, 1000 + 45 * 60 * 1000 + 1)
    expect(next.oldIdle).toBeUndefined()
  })

  it("keeps old session if it has pending permissions, pending questions, or sticky error", () => {
    const prev: StateMap = {
      oldWithPerm: entry({ lastActivity: 1000, pendingPermissions: ["p1"] }),
      oldWithQuest: entry({ lastActivity: 1000, pendingQuestions: ["q1"] }),
      oldWithError: entry({ lastActivity: 1000, error: true }),
    }
    const next = evictIdleSessions(prev, 1000 + 45 * 60 * 1000 + 1)
    expect(next.oldWithPerm).toBeDefined()
    expect(next.oldWithQuest).toBeDefined()
    expect(next.oldWithError).toBeDefined()
  })

  it("keeps recent session (newer than maxAgeMs)", () => {
    const prev: StateMap = {
      recentIdle: entry({ lastActivity: 5000 }),
    }
    const next = evictIdleSessions(prev, 6000)
    expect(next.recentIdle).toBeDefined()
  })
})

describe("fetchPendingSnapshot", () => {
  it("fetches permissions and questions and returns snapshot", async () => {
    const mockFetch = (async (url: string) => {
      if (url.includes("/permission")) {
        return { ok: true, json: async () => [{ sessionID: "s1", id: "p1" }] }
      }
      if (url.includes("/question")) {
        return { ok: true, json: async () => [{ sessionID: "s2", id: "q1" }] }
      }
      return { ok: false }
    }) as typeof fetch

    const snapshot = await fetchPendingSnapshot(mockFetch, "http://127.0.0.1:4096", "/path/to/project")
    expect(snapshot.permissions).toEqual([{ sessionID: "s1", id: "p1" }])
    expect(snapshot.questions).toEqual([{ sessionID: "s2", id: "q1" }])
  })

  it("handles fetch errors gracefully without throwing", async () => {
    const failingFetch = (async () => {
      throw new Error("network error")
    }) as typeof fetch

    const snapshot = await fetchPendingSnapshot(failingFetch, "http://127.0.0.1:4096", "/path/to/project")
    expect(snapshot).toEqual({})
  })
})


describe("evictIdleSessions: activity is load-bearing (adversarial review, HIGH)", () => {
  const mk = (over: Partial<SessionEntry> = {}): SessionEntry => ({
    activity: "idle",
    error: false,
    pendingPermissions: [],
    pendingQuestions: [],
    lastActivity: 0,
    updatedAt: 0,
    revision: 1,
    ...over,
  })

  it("keeps a session that is still WORKING long past the idle cap", () => {
    // The real shape of the bug: a long autonomous turn emits
    // session.status{busy} once and then nothing the reducer handles, so
    // lastActivity is frozen at the start of the turn. Evicting on age alone
    // reports the longest-running sessions as idle.
    const s = { s1: mk({ activity: "working", lastActivity: 0 }) }
    const after = evictIdleSessions(s, 46 * 60 * 1000)
    expect(after.s1).toBeDefined()
    expect(after.s1.activity).toBe("working")
  })

  it("keeps a session in RETRY long past the idle cap", () => {
    const s = { s1: mk({ activity: "retry", lastActivity: 0 }) }
    expect(evictIdleSessions(s, 46 * 60 * 1000).s1).toBeDefined()
  })

  it("still evicts a plain-idle session past the idle cap", () => {
    const s = { s1: mk({ activity: "idle", lastActivity: 0 }) }
    expect(evictIdleSessions(s, 46 * 60 * 1000).s1).toBeUndefined()
  })

  it("eventually evicts a stuck-working session at the hard cap (lost idle event)", () => {
    const s = { s1: mk({ activity: "working", lastActivity: 0 }) }
    expect(evictIdleSessions(s, 5 * 60 * 60 * 1000).s1).toBeDefined()
    expect(evictIdleSessions(s, 7 * 60 * 60 * 1000).s1).toBeUndefined()
  })

  it("never evicts a blocked or errored session regardless of age", () => {
    const blocked = { s1: mk({ activity: "idle", pendingPermissions: ["p1"], lastActivity: 0 }) }
    const errored = { s2: mk({ activity: "idle", error: true, lastActivity: 0 }) }
    expect(evictIdleSessions(blocked, 99 * 60 * 60 * 1000).s1).toBeDefined()
    expect(evictIdleSessions(errored, 99 * 60 * 60 * 1000).s2).toBeDefined()
  })
})

describe("checkServePortFence (nested-serve hijack guard)", () => {
  // Mirrors the REGISTRY PORT FENCE in opencode-serve-start (bead pigeon-13p).
  // OPENCODE_SERVE_EXPECTED_PORT is EXPORTED by the pool serve wrapper, so a
  // throwaway `opencode serve` spawned from inside a hosted session inherits
  // this slot's declared port while binding a port of its own. That is the
  // 2026-07-25 hijack signature. The routing layer refuses to REGISTER in that
  // case, but only for a process that claims a routing slot -- a nested serve
  // with OPENCODE_ROUTING_DB scrubbed makes no claim, never trips that fence,
  // and would still write to this slot's overlay filename under a different
  // pid, producing two live writers alternating whole-file overwrites.
  it("reports match when the bound port equals the declared port", () => {
    expect(checkServePortFence("http://127.0.0.1:4098", "4098")).toBe("match")
  })

  it("reports mismatch for a nested serve that bound its own port", () => {
    expect(checkServePortFence("http://127.0.0.1:47037", "4098")).toBe("mismatch")
  })

  it("is unarmed when the declared port is absent (fence not yet deployed)", () => {
    // Matches the wrapper's own convention: unset = unarmed, so the plugin and
    // the wrapper can land in either order without blacking out the writer.
    expect(checkServePortFence("http://127.0.0.1:4098", undefined)).toBe("unarmed")
    expect(checkServePortFence("http://127.0.0.1:4098", "")).toBe("unarmed")
  })

  it("is unarmed when the server url is unusable rather than guessing", () => {
    expect(checkServePortFence(undefined, "4098")).toBe("unarmed")
    expect(checkServePortFence("not a url", "4098")).toBe("unarmed")
  })

  it("accepts a URL object as well as a string", () => {
    expect(checkServePortFence(new URL("http://127.0.0.1:4098"), "4098")).toBe("match")
    expect(checkServePortFence(new URL("http://127.0.0.1:4099"), "4098")).toBe("mismatch")
  })

  it("tolerates whitespace around the declared port", () => {
    expect(checkServePortFence("http://127.0.0.1:4098", " 4098 ")).toBe("match")
  })

  it("compares the PORT only, deliberately ignoring the host", () => {
    // Host is intentionally not part of the fence. The declared value is a bare
    // port, and the failure mode of over-matching here is severe and silent:
    // if ctx.serverUrl ever reports "localhost" or "::1" instead of 127.0.0.1,
    // a host comparison would read as mismatch and take the writer inert across
    // the whole fleet. The under-matching risk is negligible in exchange --
    // a nested serve cannot bind this slot's port anyway, because the real pool
    // serve is already holding it.
    expect(checkServePortFence("http://10.0.0.5:4098", "4098")).toBe("match")
    expect(checkServePortFence("http://localhost:4098", "4098")).toBe("match")
  })
})
