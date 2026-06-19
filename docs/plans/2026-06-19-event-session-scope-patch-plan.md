# opencode `/event` session-scope patch — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an optional `?session_ids=a,b,c` filter to opencode v1.17.7's `GET /event` SSE stream so a subscriber receives only events for the named sessions (plus always-global lifecycle events), shipped as a new patch in `~/projects/opencode-patched`.

**Architecture:** opencode's `/event` handler already filters the in-stream event queue by `directory`/`workspaceID` (`handlers/event.ts`). We add a second `Stream.filter` keyed on the event's session aggregate (`event.data.sessionID`), driven by a `session_ids` query param read via `HttpServerRequest.ParsedSearchParams`. Events without a string `sessionID` (e.g. `server.connected`, `server.heartbeat`, `server.instance.disposed`) always pass. The change is a one-file source edit + a test, captured as `event-session-scope.patch` and registered in `patches/apply.sh`.

**Why:** prerequisite (bead `workstation-x8wi`) for the pool-of-K-serves replace (design: `workstation/docs/plans/2026-06-19-pool-replace-design.md` §2), which assigns sessions to serves by `session_id` and needs per-session SSE so each serve only fans out its own shard. Validated substrate = upstream opencode **v1.17.7** + the `~/projects/opencode-patched` patch set.

**Tech Stack:** TypeScript, Effect (`effect/unstable/http`, `effect/Stream`), Bun test (`bun:test`), `git apply` patch set. Bun ≥ 1.3.14 (`/tmp/bun-new/bun` on cloudbox).

**Repos:**
- Source/dev checkout: a scratch **worktree of upstream opencode at tag `v1.17.7`** (from `~/projects/opencode`, remote `fork`/`upstream`).
- Patch home: `~/projects/opencode-patched` (`patches/event-session-scope.patch` + `patches/apply.sh`).
- This plan + the design live in `~/projects/workstation` (local-only; do not push without the user).

**Key references (read before starting):**
- Current handler: `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts` (v1.17.7).
- Event group/query: `.../httpapi/groups/event.ts` (`EventPaths`, query = `WorkspaceRoutingQuery`).
- Query-read pattern: `.../handlers/pty.ts:193` (`yield* HttpServerRequest.ParsedSearchParams`).
- Session aggregate: `packages/core/src/session/event.ts:31` (`aggregate: "sessionID"`); bridge `packages/opencode/src/event-v2-bridge.ts:50` (`event.data[aggregate]`).
- Test harness to mirror: `packages/opencode/test/server/httpapi-event.test.ts` + `httpapi-layer.ts` (`requestInDirectory`, `response.json`, `response.stream`, `response.status`).
- Patch workflow: `~/projects/opencode-patched/.opencode/skills/patch-refresh.md`; `patches/apply.sh`.

---

## Task 0: Prepare a clean v1.17.7 dev checkout + green baseline

**Files:** none (environment setup).

**Step 1: Create a scratch worktree at v1.17.7**

```bash
cd ~/projects/opencode
git worktree add /tmp/oc-evt v1.17.7
cd /tmp/oc-evt
git switch -c event-session-scope   # working branch in the worktree
```
Expected: a detached-free working branch on the `v1.17.7` tree.

**Step 2: Install deps**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun install
```
Expected: completes without error.

**Step 3: Run the existing event test (baseline must be green)**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun test packages/opencode/test/server/httpapi-event.test.ts
```
Expected: PASS (3 tests: "serves event stream", "keeps the event stream open…", "delivers instance events…").

**Step 4: Typecheck baseline**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun --cwd packages/opencode typecheck
```
Expected: no errors. (If the clean tree has pre-existing typecheck noise, record it so we don't blame our change.)

No commit (scratch worktree).

---

## Task 1: Spike — confirm event shapes + test-helper URL composition

**Why:** before writing assertions we must verify (a) `requestInDirectory` appends `?directory=…` and how to add `session_ids` to the same URL, (b) `POST /session` returns `{ id }` via `yield* response.json`, and (c) a freshly-created session's `session.created` event carries `data.sessionID`.

**Files:** temporary scratch test `packages/opencode/test/server/_spike-event.test.ts` (deleted at end of task).

**Step 1: Write a throwaway probe test** that opens the unfiltered stream, creates a session, and logs the raw event payloads + the created-session body:

```ts
import { describe } from "bun:test"
import { Effect, Queue, Stream } from "effect"
import { EventPaths } from "../../src/server/routes/instance/httpapi/groups/event"
import { resetDatabase } from "../fixture/db"
import { disposeAllInstances, TestInstance } from "../fixture/fixture"
import { testEffect } from "../lib/effect"
import { httpApiLayer, requestInDirectory } from "./httpapi-layer"

const it = testEffect(httpApiLayer)
describe("spike", () => {
  it.instance("dump", () => Effect.gen(function* () {
    const { directory } = yield* TestInstance
    const created = yield* requestInDirectory("/session", directory, { method: "POST" })
    const body = yield* created.json
    console.log("CREATED_BODY", JSON.stringify(body))
    const resp = yield* requestInDirectory(EventPaths.event, directory)
    const reader = yield* Queue.unbounded<Uint8Array>()
    yield* resp.stream.pipe(Stream.runForEach((v) => Queue.offer(reader, v)), Effect.forkScoped)
    const created2 = yield* requestInDirectory("/session", directory, { method: "POST" })
    console.log("CREATED2_BODY", JSON.stringify(yield* created2.json))
    for (let i = 0; i < 4; i++) {
      const v = yield* Queue.take(reader).pipe(Effect.timeoutOrElse({ duration: "1 second", orElse: () => Effect.succeed(new Uint8Array()) }))
      if (v.length) console.log("EVT", new TextDecoder().decode(v).replace(/^data: /, "").trim())
    }
  }), { git: true, config: { formatter: false, lsp: false } })
})
```

**Step 2: Run it and capture output**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun test packages/opencode/test/server/_spike-event.test.ts 2>&1 | grep -E "CREATED_BODY|CREATED2_BODY|EVT"
```
**Record:** the exact `session.created` payload — confirm `properties.sessionID` (wire) ⇔ `event.data.sessionID` (handler) holds the new session's id. Note any global events emitted on session create that have NO `sessionID` (these must keep passing). Confirm `requestInDirectory`'s URL form (read `httpapi-layer.ts:29`) so Task 2 can compose `EventPaths.event` + `session_ids` + `directory`.

**Step 3: Delete the spike test**

```bash
rm /tmp/oc-evt/packages/opencode/test/server/_spike-event.test.ts
```

No commit. Carry the recorded facts into Task 2/Task 3.

---

## Task 2: Write the failing test (session-scoped filtering)

**Files:**
- Modify (test): `packages/opencode/test/server/httpapi-event.test.ts`

**Step 1: Add a session-scoped stream helper + two tests.** Append inside the existing `describe("event HttpApi", …)`. Adjust the URL composition to match Task 1's finding about `requestInDirectory` (the snippet below assumes it appends `directory` as a query param and that extra query params on the path survive — confirm/adjust):

```ts
const openSessionScopedStream = (directory: string, sessionIds: string[]) =>
  Effect.gen(function* () {
    const path = `${EventPaths.event}?session_ids=${encodeURIComponent(sessionIds.join(","))}`
    const response = yield* requestInDirectory(path, directory)
    const reader = yield* Queue.unbounded<Uint8Array>()
    yield* response.stream.pipe(Stream.runForEach((v) => Queue.offer(reader, v)), Effect.forkScoped)
    return { response, reader }
  })

it.instance(
  "filters out events for sessions not in session_ids",
  () =>
    Effect.gen(function* () {
      const { directory } = yield* TestInstance

      // A control (unfiltered) stream proves the event we expect to be filtered DOES exist.
      const control = yield* openEventStream(directory)
      expect(yield* readEvent(control.reader)).toMatchObject({ type: "server.connected" })

      // Session we will watch.
      const createdWatched = yield* requestInDirectory("/session", directory, { method: "POST" })
      expect(createdWatched.status).toBe(200)
      const watched = (yield* createdWatched.json) as { id: string }
      // control sees the watched session's created event
      expect(yield* readEvent(control.reader)).toMatchObject({ type: "session.created" })

      // Stream scoped to ONLY the watched session.
      const scoped = yield* openSessionScopedStream(directory, [watched.id])
      expect(yield* readEvent(scoped.reader)).toMatchObject({ type: "server.connected" })

      // Create a DIFFERENT session.
      const createdOther = yield* requestInDirectory("/session", directory, { method: "POST" })
      expect(createdOther.status).toBe(200)

      // Control sees the OTHER session's created event…
      expect(yield* readEvent(control.reader)).toMatchObject({ type: "session.created" })
      // …but the scoped stream must stay silent (other session filtered out).
      const status = yield* Queue.take(scoped.reader).pipe(
        Effect.as("event" as const),
        Effect.timeoutOrElse({ duration: "250 millis", orElse: () => Effect.succeed("silent" as const) }),
      )
      expect(status).toBe("silent")
    }),
  { git: true, config: { formatter: false, lsp: false } },
)

it.instance(
  "still delivers global lifecycle events to a session-scoped stream",
  () =>
    Effect.gen(function* () {
      const { directory } = yield* TestInstance
      // A session id that does not exist: only global events should pass.
      const { reader } = yield* openSessionScopedStream(directory, ["ses_nonexistent"])
      expect(yield* readEvent(reader)).toMatchObject({ type: "server.connected", properties: {} })
    }),
  { git: true, config: { formatter: false, lsp: false } },
)
```

**Step 2: Run the tests, verify the new one FAILS (filter not yet implemented)**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun test packages/opencode/test/server/httpapi-event.test.ts -t "filters out events"
```
Expected: FAIL — without the filter the scoped stream receives the other session's `session.created`, so `status` is `"event"`, not `"silent"`. (The "global lifecycle" test should already PASS since `server.connected` is unconditional — that's fine; it guards against over-filtering.)

No commit yet.

---

## Task 3: Implement the session filter in the handler

**Files:**
- Modify: `packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts`

**Step 1: Import `HttpServerRequest`.** Change the existing import line:

```ts
import { HttpServerResponse } from "effect/unstable/http"
```
to:
```ts
import { HttpServerRequest, HttpServerResponse } from "effect/unstable/http"
```

**Step 2: Read `session_ids` and add the filter inside `eventResponse`.** After the existing `const workspaceID = yield* InstanceState.workspaceID` line, add:

```ts
    // Optional per-session filter (?session_ids=a,b,c). When present, only events
    // whose session aggregate (event.data.sessionID) is in the set are forwarded;
    // events without a string sessionID (server.*, lifecycle) always pass.
    const searchParams = yield* HttpServerRequest.ParsedSearchParams
    const sessionIdsRaw = searchParams["session_ids"]
    const sessionIdsStr = Array.isArray(sessionIdsRaw) ? sessionIdsRaw.join(",") : sessionIdsRaw
    const sessionIds =
      typeof sessionIdsStr === "string" && sessionIdsStr.trim().length > 0
        ? new Set(
            sessionIdsStr
              .split(",")
              .map((s) => s.trim())
              .filter((s) => s.length > 0),
          )
        : undefined
```

Then add a `Stream.filter` to the existing `stream` pipeline, immediately AFTER the current directory/workspace `Stream.filter(...)` and BEFORE the `Stream.map(...)`:

```ts
      Stream.filter((event) => {
        if (sessionIds === undefined) return true
        const sid = (event.data as Record<string, unknown> | undefined)?.["sessionID"]
        if (typeof sid !== "string") return true // global / non-session event: always pass
        return sessionIds.has(sid)
      }),
```

(Do NOT filter the separate `disposed` stream — `server.instance.disposed` is a lifecycle signal that must always reach the client.)

**Step 3: Run the new tests, verify they PASS**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun test packages/opencode/test/server/httpapi-event.test.ts
```
Expected: PASS — all original tests + "filters out events for sessions not in session_ids" + "still delivers global lifecycle events…".

**Step 4: Typecheck**

```bash
cd /tmp/oc-evt
/tmp/bun-new/bun --cwd packages/opencode typecheck
```
Expected: no new errors.

No commit (we ship a patch, not a worktree commit — Task 4).

---

## Task 4: Capture the change as a patch + register it

**Files:**
- Create: `~/projects/opencode-patched/patches/event-session-scope.patch`
- Modify: `~/projects/opencode-patched/patches/apply.sh`

**Step 1: Generate the patch (source + test) from the worktree diff**

```bash
cd /tmp/oc-evt
git add -A
git diff --cached -- \
  packages/opencode/src/server/routes/instance/httpapi/handlers/event.ts \
  packages/opencode/test/server/httpapi-event.test.ts \
  > ~/projects/opencode-patched/patches/event-session-scope.patch
```
Expected: a non-empty `git diff`-format patch touching exactly those two files. (Inspect it: only the import line, the `sessionIds` block, the new `Stream.filter`, and the test additions.)

**Step 2: Register the patch in `apply.sh`.** Add `event-session-scope` to the END of the `PATCHES=(…)` array (it touches files no other patch touches, so order is unconstrained), and add a header bullet:

```
#   7. event-session-scope.patch (local) - optional ?session_ids=a,b,c filter on GET /event
#                                           (pool-of-K-serves per-session SSE; bead workstation-x8wi)
```

**Step 3: (Optional) Verify the test file path exists in the patch context.** If carrying the test in the patch causes friction in any build flow that asserts a clean tree, fall back to a **source-only** patch (drop the test hunk) and keep the test in `~/projects/opencode-patched/docs/` for refresh verification. Default: keep both.

No commit yet (Task 6).

---

## Task 5: Verify the patch applies cleanly on a FRESH v1.17.7 tree

**Files:** none (verification).

**Step 1: Fresh worktree + run apply.sh (full stack)**

```bash
cd ~/projects/opencode
git worktree add /tmp/oc-verify v1.17.7
~/projects/opencode-patched/patches/apply.sh /tmp/oc-verify
```
Expected: every patch reports `✓ … applied`, ending with `✓ All patches applied successfully` and a `git status --short` that includes the two `/event` files. (`apply.sh` runs `git apply --check` first, so a context drift fails loud here.)

**Step 2: Build/typecheck the patched tree**

```bash
cd /tmp/oc-verify
/tmp/bun-new/bun install
/tmp/bun-new/bun --cwd packages/opencode typecheck
/tmp/bun-new/bun test packages/opencode/test/server/httpapi-event.test.ts
```
Expected: typecheck clean; event tests PASS on the fully-patched stack (confirms no interaction with the other 6 patches).

**Step 3: Clean up worktrees**

```bash
cd ~/projects/opencode
git worktree remove /tmp/oc-verify
git worktree remove /tmp/oc-evt --force
```

---

## Task 6: Commit in opencode-patched

**Files:** the new patch + `apply.sh`.

**Step 1: Review + commit**

```bash
cd ~/projects/opencode-patched
git add patches/event-session-scope.patch patches/apply.sh
git status
git diff --cached
git commit -m "feat(v1.17.7): add event-session-scope.patch (?session_ids= filter on /event)

Optional per-session SSE filter for the pool-of-K-serves replace
(workstation bead x8wi; design 2026-06-19-pool-replace-design.md §2).
Events without a string sessionID (server.*, lifecycle) always pass."
```
Expected: one commit. **Do not push** unless the user asks (mirror the workstation-local caution; confirm push policy for opencode-patched first).

**Step 2: Update the bead**

```bash
cd ~/projects/workstation
bd update workstation-x8wi --status in_progress --append-notes "Patch authored: opencode-patched/patches/event-session-scope.patch (handler ParsedSearchParams + Stream.filter on event.data.sessionID; global events always pass). Tests in httpapi-event.test.ts. Verified clean apply + green on fresh v1.17.7 worktree via apply.sh. Plan: workstation/docs/plans/2026-06-19-event-session-scope-patch-plan.md."
```

---

## Task 7 (optional): Draft an upstream PR description

Per `patch-refresh.md`, opportunistically draft (do not block on) an upstream PR proposing `?session_ids=` for `GET /event` (a generally useful capability). Save to `~/projects/opencode-patched/docs/` as a behavioral reference for future refreshes. No code push.

---

## Done criteria
- [ ] `event-session-scope.patch` applies cleanly via `apply.sh` on a fresh `v1.17.7` worktree.
- [ ] All `httpapi-event.test.ts` tests pass on the fully-patched stack (incl. the 2 new ones).
- [ ] `bun --cwd packages/opencode typecheck` clean.
- [ ] `apply.sh` PATCHES + header updated; committed in opencode-patched (unpushed pending user).
- [ ] Bead `workstation-x8wi` updated; this unblocks the pigeon-router per-session path (`workstation-zao4`).

## Notes for the executor
- The one genuine unknown is resolved in **Task 1** (spike): confirm `requestInDirectory`'s URL composition and that `session.created` carries `data.sessionID`. Adjust the Task 2 helper/asserts to the recorded reality before implementing.
- Keep the change minimal (YAGNI): no schema/middleware edits required — `ParsedSearchParams` reads the raw query. Only add `session_ids` to `groups/event.ts`'s query schema if OpenAPI documentation is explicitly wanted (extra scope; default = skip).
- Comma-separated `?session_ids=a,b,c` is the contract (matches the design + the router's discovery payload). Repeated `?session_ids=a&session_ids=b` is also tolerated (the handler joins arrays).

## As-built notes (from execution 2026-06-19)
- **Param presence, not non-emptiness, gates the filter.** Final handler logic: `sessionIdsRaw !== undefined` → build a `Set` (empty when the value is empty). So **absent** `session_ids` → no filter (all session events pass); **present-but-empty** `?session_ids=` → empty set → only global/lifecycle events pass (all session events blocked). This refines the original Task 3 snippet (which treated empty as "no filter") — an explicit empty set logically means "no sessions", which is the correct behavior for a pool serve that currently owns zero sessions. Surfaced by code review; covered by the test "blocks all session events if session_ids is present but empty".
- **Spike finding (URL composition):** `requestInDirectory` passes the directory via an `x-opencode-directory` **header**, and the default `request` helper in `httpapi-layer.ts` **strips query params** (`HttpClientRequest.setUrl(url.pathname)`). Tests therefore use a local `requestInDirectoryWithSearch` helper that preserves `url.pathname + url.search`. (A future cleanup could hoist this into `httpapi-layer.ts`.)
- **Event shapes confirmed:** `session.created`/`session.deleted` carry the id at wire `properties.sessionID` ⇔ handler `event.data.sessionID`. `server.connected` has empty `properties` and no `sessionID` (always passes). Positive delivery is asserted via DELETE → `session.deleted` reaching the scoped stream.
