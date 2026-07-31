import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { applyEvent, effectiveState, emptyState, type StateMap } from "../session-state-impl"

/**
 * Fixture-driven tests against payloads captured from the DEPLOYED fleet.
 *
 * Every source citation in the design docs was read against the 1.15.10 source
 * tree, while the fleet runs 1.17.x and auto-updates every 8 hours. The reducer
 * is built on a payload asymmetry that is invisible in the type system:
 *
 *   .asked                       -> key in properties.id
 *   .replied / .rejected         -> key in properties.requestID
 *
 * If that ever drifts, the reducer silently stops clearing pending prompts and
 * every session it touches sticks on "blocked" forever. These fixtures are real
 * captured payloads, so a version bump that changes the shape breaks a test
 * instead of quietly breaking the picker.
 */

const doc = JSON.parse(
  readFileSync(join(__dirname, "fixtures/deployed-events.json"), "utf8"),
) as {
  _provenance: Record<string, string>
  events: Array<{ type: string; properties: any }>
}

const events = doc.events
const pick = (type: string) => events.filter((e) => e.type === type)
const one = (type: string) => {
  const found = pick(type)
  if (!found.length) throw new Error(`fixture missing event type: ${type}`)
  return found[0]
}

describe("deployed fixtures: provenance", () => {
  it("records the version the payloads came from", () => {
    expect(doc._provenance.opencodeVersion).toBe("1.17.13")
  })

  it("carries the event types the reducer depends on", () => {
    const types = new Set(events.map((e) => e.type))
    expect(types.has("session.status")).toBe(true)
    expect(types.has("question.asked")).toBe(true)
    expect(types.has("question.replied")).toBe(true)
  })
})

describe("deployed fixtures: the .asked / .replied key asymmetry", () => {
  it("question.asked carries the key in properties.id (NOT requestID)", () => {
    const asked = one("question.asked")
    expect(typeof asked.properties.id).toBe("string")
    expect(asked.properties.id).toMatch(/^que_/)
    expect(asked.properties.requestID).toBeUndefined()
  })

  it("question.replied carries the key in properties.requestID (NOT id)", () => {
    const replied = one("question.replied")
    expect(typeof replied.properties.requestID).toBe("string")
    expect(replied.properties.requestID).toMatch(/^que_/)
    expect(replied.properties.id).toBeUndefined()
  })

  it("the replied requestID refers to the same prompt as the asked id", () => {
    // Captured as a real ask/reply round trip, so the ids must line up.
    const askedIds = pick("question.asked").map((e) => e.properties.id)
    const repliedIds = pick("question.replied").map((e) => e.properties.requestID)
    expect(repliedIds.length).toBeGreaterThan(0)
    for (const rid of repliedIds) expect(askedIds).toContain(rid)
  })
})

describe("deployed fixtures: session.status shape", () => {
  it("nests the status under properties.status.type", () => {
    for (const e of pick("session.status")) {
      expect(typeof e.properties.sessionID).toBe("string")
      expect(typeof e.properties.status?.type).toBe("string")
      // The deployed union is exactly these three (verified in the 1.17.13
      // bundle: SessionProcessor only ever calls set({type:"busy"|"idle"|"retry"})).
      expect(["busy", "idle", "retry"]).toContain(e.properties.status.type)
    }
  })

  it("captured both a busy and an idle transition", () => {
    const kinds = pick("session.status").map((e) => e.properties.status.type)
    expect(kinds).toContain("busy")
    expect(kinds).toContain("idle")
  })
})

describe("deployed fixtures: the reducer consumes them correctly", () => {
  it("drives a real busy -> idle cycle to working then idle", () => {
    const statuses = pick("session.status")
    const busy = statuses.find((e) => e.properties.status.type === "busy")!
    const idle = statuses.find(
      (e) =>
        e.properties.status.type === "idle" &&
        e.properties.sessionID === busy.properties.sessionID,
    )!
    const sid = busy.properties.sessionID

    let s: StateMap = emptyState()
    s = applyEvent(s, busy)
    expect(effectiveState(s[sid])).toBe("working")

    s = applyEvent(s, idle)
    expect(effectiveState(s[sid])).toBe("idle")
  })

  it("blocks on a real question.asked and clears on the real question.replied", () => {
    const asked = one("question.asked")
    const sid = asked.properties.sessionID
    const replied = pick("question.replied").find(
      (e) => e.properties.requestID === asked.properties.id,
    )

    let s: StateMap = emptyState()
    s = applyEvent(s, asked)
    expect(s[sid].pendingQuestions).toEqual([asked.properties.id])
    expect(effectiveState(s[sid])).toBe("blocked")

    if (replied) {
      s = applyEvent(s, replied)
      expect(s[sid].pendingQuestions).toEqual([])
      expect(effectiveState(s[sid])).not.toBe("blocked")
    }
  })

  it("would NOT clear the prompt if the reducer read .id on the replied event", () => {
    // Regression guard for the asymmetry itself. If a future version made
    // .replied carry `id`, the fixture above changes and this test fails --
    // which is the point.
    const asked = one("question.asked")
    const replied = pick("question.replied").find(
      (e) => e.properties.requestID === asked.properties.id,
    )
    if (!replied) return
    expect((replied.properties as any).id).toBeUndefined()
  })

  it("ignores the standalone session.idle event (status is the busy axis)", () => {
    // Deployed emits BOTH session.status{idle} and a bare session.idle. The
    // reducer intentionally handles only the former; feeding it the latter from
    // a clean state must be a no-op rather than inventing an entry.
    const bare = pick("session.idle")
    if (!bare.length) return
    const before = emptyState()
    const after = applyEvent(before, bare[0])
    expect(after).toBe(before)
  })
})
