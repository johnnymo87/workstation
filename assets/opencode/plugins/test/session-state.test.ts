import { describe, it, expect } from "vitest"
import { applyEvent, effectiveState, emptyState, seedFromSnapshot } from "../session-state-impl"

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

  it("authoritative for sessions named in snapshot, leaving unmentioned sessions untouched", () => {
    let s = applyEvent(emptyState(), ev("permission.asked", { sessionID: "s1", id: "p1" }))
    s = applyEvent(s, ev("permission.asked", { sessionID: "s2", id: "p2" }))

    s = seedFromSnapshot(s, {
      permissions: [{ sessionID: "s1", id: "p_new" }],
    })

    expect(s.s1.pendingPermissions).toEqual(["p_new"])
    expect(effectiveState(s.s1)).toBe("blocked")

    expect(s.s2.pendingPermissions).toEqual(["p2"])
    expect(effectiveState(s.s2)).toBe("blocked")

    s = seedFromSnapshot(s, {
      questions: [{ sessionID: "s1", id: "q1" }],
    })
    expect(s.s1.pendingPermissions).toEqual([])
    expect(s.s1.pendingQuestions).toEqual(["q1"])
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
