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
  getPermissionResponse: Array<Record<string, any>>
  events: { permissionAsked: any; permissionReplied: any }
  directoryFilterMatrix: {
    sessionUnderTestDirectory: string
    results: Array<{ query: string; count: number }>
  }
  openapiShapes: Record<string, { required: string[]; properties: Record<string, string> }>
}

describe("deployed permission API: GET response shape", () => {
  it("returns an array whose items carry the fields seedFromSnapshot reads", () => {
    expect(Array.isArray(doc.getPermissionResponse)).toBe(true)
    expect(doc.getPermissionResponse.length).toBeGreaterThan(0)
    for (const item of doc.getPermissionResponse) {
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
      permissions: doc.getPermissionResponse as any,
      questions: [],
    })
    const sessionID = doc.getPermissionResponse[0].sessionID
    const permissionID = doc.getPermissionResponse[0].id
    expect(Object.keys(seeded)).toContain(sessionID)
    expect(seeded[sessionID].pendingPermissions).toContain(permissionID)
    expect(effectiveState(seeded[sessionID])).toBe("blocked")
  })

  it("fetchPendingSnapshot parses the real response through a stubbed fetch", async () => {
    const calls: string[] = []
    const fakeFetch = (async (url: string) => {
      calls.push(String(url))
      const body = String(url).includes("/permission") ? doc.getPermissionResponse : []
      return { ok: true, json: async () => body } as any
    }) as unknown as typeof fetch

    const snap = await fetchPendingSnapshot(fakeFetch, "http://127.0.0.1:4791", "/tmp/x")
    expect(snap.permissions).toHaveLength(doc.getPermissionResponse.length)
    // Assert the TYPE, not just equality with the fixture: comparing
    // snap[0].sessionID to doc[0].sessionID passes vacuously when the field is
    // renamed, because both sides are then undefined.
    expect(typeof snap.permissions![0].sessionID).toBe("string")
    expect(typeof snap.permissions![0].id).toBe("string")
    expect(snap.permissions![0].sessionID).toBe(doc.getPermissionResponse[0].sessionID)
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
    const sessionID = asked.properties.sessionID
    // Build the reply using whichever key the CAPTURED reply actually used, so
    // this stays coupled to the fixture. Hardcoding "requestID" here would make
    // the test pass even after the deployed payload drifted.
    const repliedKey = Object.keys(doc.events.permissionReplied.properties).find(
      (k) => k === "requestID" || k === "id",
    )!
    const replied = {
      type: "permission.replied",
      properties: {
        sessionID,
        [repliedKey]: asked.properties.id,
        reply: "once",
      },
    }

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
  const results = () =>
    Object.fromEntries(doc.directoryFilterMatrix.results.map((r) => [r.query, r.count]))

  it("a MATCHING directory includes the pending prompt", () => {
    const dir = doc.directoryFilterMatrix.sessionUnderTestDirectory
    expect(results()[`?directory=${dir}`]).toBe(1)
  })

  it("a NON-MATCHING directory excludes it (param is not ignored)", () => {
    const nonMatching = doc.directoryFilterMatrix.results.filter(
      (r) => r.query.includes("projB") || r.query.includes("nonexistent"),
    )
    expect(nonMatching.length).toBeGreaterThan(0)
    for (const r of nonMatching) {
      expect(r.count, `${r.query} should be filtered out`).toBe(0)
    }
  })

  it("the unfiltered query still returns the prompt (positive control)", () => {
    // Without this, "0 everywhere" would also pass the test above.
    expect(results()["(none)"]).toBe(1)
  })
})
