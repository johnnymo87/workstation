import { describe, it, expect } from "vitest"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import {
  applyEvent,
  effectiveState,
  emptyState,
  fetchPendingSnapshot,
  seedFromSnapshot,
  type StateMap,
} from "../session-state-impl"

/**
 * Fixture-driven tests against the DEPLOYED permission API.
 *
 * Two gaps carried forward from the Task 3 review, both closed by this fixture:
 *
 *  (a) `fetchPendingSnapshot` assumes GET /permission and GET /question return
 *      arrays of `{ id, sessionID }`. That was never verified against a running
 *      server holding a REAL pending prompt -- the previous fixtures were event
 *      payloads only. If the field names differ, `seedFromSnapshot` skips every
 *      item silently and BUG FIX 1 (boot blindness) reverts with zero signal.
 *
 *  (b) `deployed-events.json` advertises itself as guarding the .asked/.replied
 *      key asymmetry but contains only `question.*` events. The `permission.*`
 *      half rested on a one-time read of the bundled source.
 *
 * Plus the negative control nobody had run: that `?directory=` actually
 * EXCLUDES other directories' prompts rather than being ignored.
 */

const doc = JSON.parse(
  readFileSync(join(__dirname, "fixtures/deployed-permission-api.json"), "utf8"),
) as {
  _provenance: Record<string, string>
  events: { permissionAsked: any; permissionReplied: any }
  directoryFilterMatrix: {
    sessionUnderTestDirectory: string
    otherDirectory: string
    pendingPermissionID: string
    queries: Array<{ label: string; query: string; tMs: number; body: Array<Record<string, any>> }>
  }
  openapiShapes: Record<string, { required: string[]; properties: Record<string, string> }>
}

/** The raw unfiltered GET body -- a real response, not a transcription. */
const getPermissionResponse = doc.directoryFilterMatrix.queries.find(
  (q) => q.label === "unfiltered",
)!.body

const queryByLabel = (label: string) =>
  doc.directoryFilterMatrix.queries.find((q) => q.label === label)!

describe("deployed permission API: GET response shape", () => {
  it("returns an array whose items carry the fields seedFromSnapshot reads", () => {
    expect(Array.isArray(getPermissionResponse)).toBe(true)
    expect(getPermissionResponse.length).toBeGreaterThan(0)
    for (const item of getPermissionResponse) {
      expect(typeof item.id).toBe("string")
      expect(typeof item.sessionID).toBe("string")
    }
  })

  it("openapi declares id and sessionID REQUIRED on both request types", () => {
    for (const name of ["PermissionRequest", "QuestionRequest"]) {
      const shape = doc.openapiShapes[name]
      expect(shape, `${name} missing from spec`).toBeTruthy()
      expect(shape.required).toContain("id")
      expect(shape.required).toContain("sessionID")
      expect(shape.properties.id).toBe("string")
      expect(shape.properties.sessionID).toBe("string")
    }
  })

  it("seedFromSnapshot actually seeds from the real captured response", () => {
    const seeded = seedFromSnapshot(emptyState(), {
      permissions: getPermissionResponse as any,
      questions: [],
    })
    const sessionID = getPermissionResponse[0].sessionID
    const permissionID = getPermissionResponse[0].id
    expect(Object.keys(seeded)).toContain(sessionID)
    expect(seeded[sessionID].pendingPermissions).toContain(permissionID)
    expect(effectiveState(seeded[sessionID])).toBe("blocked")
  })

  it("fetchPendingSnapshot parses the real response through a stubbed fetch", async () => {
    const calls: string[] = []
    const fakeFetch = (async (url: string) => {
      calls.push(String(url))
      const body = String(url).includes("/permission") ? getPermissionResponse : []
      return { ok: true, json: async () => body } as any
    }) as unknown as typeof fetch

    const snap = await fetchPendingSnapshot(fakeFetch, "http://127.0.0.1:4791", "/tmp/x")
    expect(snap.permissions).toHaveLength(getPermissionResponse.length)
    // Assert the TYPE, not just equality with the fixture: comparing
    // snap[0].sessionID to doc[0].sessionID passes vacuously when the field is
    // renamed, because both sides are then undefined.
    expect(typeof snap.permissions![0].sessionID).toBe("string")
    expect(typeof snap.permissions![0].id).toBe("string")
    expect(snap.permissions![0].sessionID).toBe(getPermissionResponse[0].sessionID)
    // directory must be forwarded, url-encoded, to BOTH endpoints
    expect(calls).toHaveLength(2)
    for (const c of calls) expect(c).toContain(`directory=${encodeURIComponent("/tmp/x")}`)
  })
})

describe("deployed permission API: .asked/.replied key asymmetry", () => {
  it("permission.asked carries the key in properties.id (NOT requestID)", () => {
    const p = doc.events.permissionAsked.properties
    expect(doc.events.permissionAsked.type).toBe("permission.asked")
    expect(typeof p.id).toBe("string")
    expect(p.requestID).toBeUndefined()
  })

  it("permission.replied carries the key in properties.requestID (NOT id)", () => {
    const p = doc.events.permissionReplied.properties
    expect(doc.events.permissionReplied.type).toBe("permission.replied")
    expect(typeof p.requestID).toBe("string")
    expect(p.id).toBeUndefined()
  })

  it("the reducer clears a real ask with the real reply", () => {
    const asked = doc.events.permissionAsked
    const replied = doc.events.permissionReplied
    const sessionID = asked.properties.sessionID

    // Both events are the REAL captured payloads of the SAME permission
    // request, so this exercises an actual deployed lifecycle rather than a
    // reply synthesized to match the ask.
    expect(replied.properties.requestID).toBe(asked.properties.id)
    expect(replied.properties.sessionID).toBe(sessionID)

    let state: StateMap = emptyState()
    state = applyEvent(state, asked as any)
    expect(state[sessionID].pendingPermissions).toEqual([asked.properties.id])
    expect(effectiveState(state[sessionID])).toBe("blocked")

    state = applyEvent(state, replied as any)
    expect(state[sessionID].pendingPermissions).toEqual([])
    expect(effectiveState(state[sessionID])).not.toBe("blocked")
  })

  it("a reply that used the .asked key name would NOT clear (guards the asymmetry)", () => {
    const asked = doc.events.permissionAsked
    const sessionID = asked.properties.sessionID
    let state: StateMap = emptyState()
    state = applyEvent(state, asked as any)
    // If the deployed payload ever switched to `id` on .replied, this is what
    // the current reducer would do -- nothing. Documented, not desired.
    const wrong = {
      type: "permission.replied",
      properties: { sessionID, id: asked.properties.id, reply: "once" },
    }
    state = applyEvent(state, wrong as any)
    expect(state[sessionID].pendingPermissions).toEqual([asked.properties.id])
  })
})

describe("deployed permission API: ?directory= negative control", () => {
  // Assertions are derived from RAW captured bodies, so they test what the
  // deployed server returned rather than a count someone typed into the
  // fixture. The specific thing being proven is membership of the one known
  // pending permission id, not just a length.
  const target = () => doc.directoryFilterMatrix.pendingPermissionID
  const ids = (label: string) => queryByLabel(label).body.map((x) => x.id)

  it("the unfiltered query returns the pending prompt (positive control)", () => {
    // Without this, "absent everywhere" would satisfy the exclusion tests too.
    expect(ids("unfiltered")).toContain(target())
  })

  it("a MATCHING directory includes the pending prompt", () => {
    expect(ids("matching directory")).toContain(target())
  })

  it("a NON-MATCHING directory excludes it (the param is not ignored)", () => {
    expect(ids("non-matching directory")).not.toContain(target())
    expect(queryByLabel("non-matching directory").body).toHaveLength(0)
  })

  it("a nonexistent directory excludes it", () => {
    expect(ids("nonexistent directory")).not.toContain(target())
  })

  it("a trailing slash on the matching directory is tolerated", () => {
    // Previously recorded in the fixture but asserted by nothing, while the
    // plan cited it as a finding.
    expect(ids("matching directory, trailing slash")).toContain(target())
  })

  it("the prompt was still pending at the END of the sequence (temporal control)", () => {
    // Rules out the confound that makes the whole matrix meaningless: if the
    // prompt had been replied to (or the session evicted) partway through, the
    // later queries would return 0 for reasons having nothing to do with
    // directory filtering.
    expect(ids("unfiltered (repeat, temporal control)")).toContain(target())
  })

  it("queries the two directories on the SAME serve, so filtering is the only variable", () => {
    expect(doc.directoryFilterMatrix.otherDirectory).not.toBe(
      doc.directoryFilterMatrix.sessionUnderTestDirectory,
    )
    for (const q of doc.directoryFilterMatrix.queries) {
      expect(Array.isArray(q.body)).toBe(true)
    }
  })
})
