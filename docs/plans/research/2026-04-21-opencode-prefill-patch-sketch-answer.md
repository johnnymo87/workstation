I could not fetch johnnymo87/opencode-patched@b312928e9 directly from here, so this is a patch sketch against the current upstream shape and the files you named. The main drift is that the old header-based directory binding has already moved out of server.ts into packages/opencode/src/server/routes/instance/middleware.ts, where request directory still comes from ?directory / x-opencode-directory before calling Instance.provide. Instance.provide still caches instance context by resolved directory, and SessionRunState still keeps its runners map inside per-instance state keyed by sessionID. That is the split-brain condition behind the race you described. 
GitHub
+2
GitHub
+2

1) Main patch sketch

I would implement option (a), but locally inside routes/session.ts: add a second middleware that only runs for /:sessionID and /:sessionID/*, looks up the session, then re-enters Instance.provide({ directory: session.directory }) for the remainder of that request. That is the smallest fix because it leaves global instance selection alone for non-session routes, avoids threading a helper through every handler, and makes it hard to forget a future session route. It also leaves Instance.state keying untouched, which matches your constraint. Session-scoped handlers in the current file include abort, share, diff, message, prompt_async, and command, so a path-scoped middleware catches all of them in one place. 
GitHub
+2
GitHub
+2

Diff 1 — packages/opencode/src/server/routes/session.ts
Diff
--- a/packages/opencode/src/server/routes/session.ts
+++ b/packages/opencode/src/server/routes/session.ts
@@
-import { Hono } from "hono"
+import { Hono, type MiddlewareHandler } from "hono"
@@
+import { AppRuntime } from "@/effect/app-runtime"
+import { InstanceBootstrap } from "@/project/bootstrap"
+import { Instance } from "@/project/instance"
+import { AppFileSystem } from "@opencode-ai/shared/filesystem"
@@
 import * as Session from "@/session"
 import { SessionID } from "@/session/schema"
 import * as SessionPrompt from "@/session/prompt"
@@
+/**
+ * Rebind session-scoped requests to the persisted session directory.
+ *
+ * Why:
+ * - global InstanceMiddleware selects instance by caller-supplied header/query
+ * - SessionRunState busy/runner state is stored inside per-instance state
+ * - the same sessionID can therefore land in multiple instance contexts
+ */
+function SessionInstanceMiddleware(): MiddlewareHandler {
+  return async (c, next) => {
+    const sessionID = c.req.param("sessionID") as SessionID | undefined
+    if (!sessionID) return next()
+
+    // Assumes Session.get(sessionID) is already the cheap row lookup you mentioned
+    // in your fork. If your fork still has project-scoped Session.get(), swap this
+    // for the same directory-by-sessionID lookup helper already used in your prompt path.
+    const session = await Session.get(sessionID)
+
+    return Instance.provide({
+      directory: AppFileSystem.resolve(session.directory),
+      init: () => AppRuntime.runPromise(InstanceBootstrap),
+      fn: () => next(),
+    })
+  }
+}
+
 export const SessionRoutes = lazy(() =>
   new Hono()
     .get(
       "/",
@@
     .get(
       "/status",
@@
     .post(
       "/",
@@
+    // IMPORTANT:
+    // Anything below this line is session-scoped and must run in the
+    // persisted session.directory instance context, not the caller header context.
+    .use("/:sessionID", SessionInstanceMiddleware())
+    .use("/:sessionID/*", SessionInstanceMiddleware())
+
     .get(
       "/:sessionID",
@@
     .get(
       "/:sessionID/children",
@@
     .get(
       "/:sessionID/todo",
@@
     .delete(
       "/:sessionID",
@@
     .patch(
       "/:sessionID",
@@
     .post(
       "/:sessionID/init",
@@
     .post(
       "/:sessionID/fork",
@@
     .post(
       "/:sessionID/abort",
@@
     .post(
       "/:sessionID/share",
@@
     .get(
       "/:sessionID/diff",
@@
     .delete(
       "/:sessionID/share",
@@
     .post(
       "/:sessionID/summarize",
@@
     .get(
       "/:sessionID/message",
@@
     .get(
       "/:sessionID/message/:messageID",
@@
     .delete(
       "/:sessionID/message/:messageID",
@@
     .post(
       "/:sessionID/message",
@@
     .post(
       "/:sessionID/prompt_async",
@@
     .post(
       "/:sessionID/command",
@@
 )

That is the whole fix in the current upstream layout. No server.ts change is required there, because the header-based binding is already centralized in InstanceMiddleware. 
GitHub
+1

Optional Diff 2 — prompt_async detach/catch

Current upstream prompt_async returns 204 immediately and then calls SessionPrompt.prompt(...) without await or catch. That does not cause the race, but it does make BusyError / provider errors easy to lose. 
GitHub

Diff
--- a/packages/opencode/src/server/routes/session.ts
+++ b/packages/opencode/src/server/routes/session.ts
@@
   async (c) => {
     c.status(204)
     c.header("Content-Type", "application/json")
     return stream(c, async () => {
       const sessionID = c.req.valid("param").sessionID
       const body = c.req.valid("json")
-      SessionPrompt.prompt({ ...body, sessionID })
+      void SessionPrompt.prompt({ ...body, sessionID }).catch((error) => {
+        // replace with your existing logger if preferred
+        console.error("session.prompt_async failed", { sessionID, error })
+      })
     })
   },
 )

I would keep that as a separate commit.

2) Why this rebinding mechanism, not the other two

I would not move this into the global middleware.

The global middleware runs for everything and currently chooses the instance from request header/query. Teaching it to special-case /session/:id/... means either parsing route structure before routing or doing a session lookup on every request path that might become session-scoped. That is more invasive and makes the “session routes are different” policy less visible. 
GitHub
+1

I also would not use a per-handler wrapper like withSessionInstance(c, fn) unless you absolutely have to. It is easy to miss one route now or later. A session-only middleware inserted once in routes/session.ts keeps the diff small and covers abort, share, message, prompt_async, command, and any future /:sessionID/... handler automatically. 
GitHub
+2
GitHub
+2

3) What to do about x-opencode-directory on session routes

My recommendation is:

Keep honoring caller-supplied directory on non-session routes, especially POST /session and other collection routes.

Stop letting caller-supplied directory choose the backing instance for any existing session route.

I do not think you lose a clearly valid supported use case by doing that. In the current code, session execution state is tied to instance context; prompt/instruction internals also read instance context for cwd/path-style behavior, so “same session, different caller directory header” is not a clean “tool cwd override” mechanism today. It is selecting a different backing instance, which is exactly the bug. 
GitHub
+2
GitHub
+2

The part I would mark TBD rather than guess is this: if your fork deliberately uses x-opencode-directory on POST /session/:id/prompt_async as an informal way to run subagent tools in alternate worktrees, that should become an explicit prompt/tool parameter, not an implicit switch of the whole request’s Instance context. I would not preserve that behavior in this PR, because preserving it keeps the race.

A practical policy statement for the PR is:

On /:sessionID/... routes, session.directory wins for instance selection. x-opencode-directory may still exist as request metadata, but it must not determine the backing Instance for an already-created session.

4) Which routes should be rebound

Your suspicion is right: everything under /session/:sessionID and /session/:sessionID/* should be rebound, and POST /session should not.

In the current file, the collection routes are GET /session/, GET /session/status, and POST /session; those should stay on caller/global instance context. The session-scoped routes include at least GET /:sessionID, GET /:sessionID/children, GET /:sessionID/todo, DELETE /:sessionID, PATCH /:sessionID, POST /:sessionID/init, POST /:sessionID/fork, POST /:sessionID/abort, POST /:sessionID/share, GET /:sessionID/diff, DELETE /:sessionID/share, POST /:sessionID/summarize, message endpoints, POST /:sessionID/prompt_async, and POST /:sessionID/command. abort absolutely needs the rebind, because cancellation consults the same per-instance run-state map. 
GitHub
+4
GitHub
+4
GitHub
+4

There does not appear to be a GET /:sessionID/status route in current upstream; the only status route I saw is collection-level GET /session/status, so I would leave that one alone. 
GitHub

5) Failing Bun test

I cannot promise this is copy-paste exact against b312928e9 because I could not inspect that fork directly. This is the smallest realistic test I can give you that exercises the actual SessionRoutes() router and fails before the rebind patch. The most likely edits are the alias import path style and, in older layouts, the exact POST /session request body. The current test fixtures do already provide temp-dir helpers and a TestLLMServer, although this specific test does not need the fake LLM because it mocks SessionPrompt.prompt. 
GitHub

File: packages/opencode/test/server/session-directory-rebind.test.ts

TypeScript
import { describe, expect, it, mock } from "bun:test"
import { Hono } from "hono"
import z from "zod"

import { tmpdir } from "../fixture/fixture"
import { Instance } from "@/project/instance"
import { InstanceMiddleware } from "@/server/routes/instance/middleware"

// Load the real module first so we can preserve every export except prompt/PromptInput.
const realSessionPrompt = await import("@/session/prompt")

let entered = 0
let busyRejected = 0
let releaseGate!: () => void
let gate = new Promise<void>((resolve) => {
  releaseGate = resolve
})

/**
 * This mock intentionally reproduces the current bug surface:
 * "busy" is tracked per Instance.directory, not globally per session ID.
 *
 * Before the patch:
 *   each request keeps the caller's x-opencode-directory instance,
 *   so the same sessionID can enter once per directory.
 *
 * After the patch:
 *   all /session/:sessionID/* requests are rebound to session.directory,
 *   so only one call enters and the rest fail busy.
 */
const activeByDirectory = new Map<string, Set<string>>()

mock.module("@/session/prompt", () => ({
  ...realSessionPrompt,

  // Keep the prompt_async route validator simple and deterministic for this test.
  PromptInput: z.object({
    text: z.string().default("hi"),
  }),

  prompt: async ({ sessionID }: { sessionID: string }) => {
    // If your fork exposes this differently, rename to the equivalent current-instance cwd getter.
    const directory = Instance.directory

    let active = activeByDirectory.get(directory)
    if (!active) {
      active = new Set<string>()
      activeByDirectory.set(directory, active)
    }

    if (active.has(sessionID)) {
      busyRejected++
      throw new Error(`Session.BusyError:${sessionID}`)
    }

    active.add(sessionID)
    entered++

    try {
      await gate
    } finally {
      active.delete(sessionID)
    }

    return { id: "msg_test" } as any
  },
}))

// Import after mock.module so SessionRoutes sees the mocked prompt implementation.
const { SessionRoutes } = await import("@/server/routes/session")

describe("session route instance rebinding", () => {
  it("does not split busy state across caller-supplied x-opencode-directory headers", async () => {
    await using sessionDir = await tmpdir({ git: true })
    await using alt1 = await tmpdir({ git: true })
    await using alt2 = await tmpdir({ git: true })
    await using alt3 = await tmpdir({ git: true })

    entered = 0
    busyRejected = 0
    activeByDirectory.clear()
    gate = new Promise<void>((resolve) => {
      releaseGate = resolve
    })

    const app = new Hono()
      .use("*", InstanceMiddleware())
      .route("/session", SessionRoutes())

    // Create the session in sessionDir.
    const createRes = await app.request("http://test/session", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-opencode-directory": sessionDir.path,
      },
      body: JSON.stringify({
        title: "directory rebind race test",
      }),
    })

    expect(createRes.ok).toBe(true)
    const created = (await createRes.json()) as { id: string }
    const sessionID = created.id

    const dirs = [sessionDir.path, alt1.path, alt2.path, alt3.path]

    // Fire concurrent prompt_async calls with distinct caller directories.
    const responses = await Promise.all(
      dirs.map((dir, i) =>
        app.request(`http://test/session/${sessionID}/prompt_async`, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-opencode-directory": dir,
          },
          body: JSON.stringify({
            text: `prompt ${i}`,
          }),
        }),
      ),
    )

    // prompt_async currently returns immediately.
    for (const res of responses) {
      expect(res.status).toBe(204)
    }

    // Let detached prompt tasks start.
    await Bun.sleep(25)

    // BEFORE the patch:
    //   entered === 4
    //   busyRejected === 0
    //
    // AFTER the patch:
    //   all requests re-enter the same session.directory-backed Instance
    //   entered === 1
    //   busyRejected === 3
    expect(entered).toBe(1)
    expect(busyRejected).toBe(dirs.length - 1)

    releaseGate()
    await Bun.sleep(10)
  })
})

Two notes on that test:

Because prompt_async currently detaches the prompt work and returns 204 immediately, the assertion is on mock counters, not HTTP status. That matches current upstream behavior. 
GitHub

If your fork’s prompt_async already awaits enough to surface Session.BusyError, you can tighten the assertions to expect one 204 and N-1 400s instead.

6) Short PR description

Title

fix(server): bind session routes to persisted session.directory

Body

Markdown
## Summary

Session-scoped API routes were still running inside the caller-selected
`Instance` context from `x-opencode-directory` / `?directory`.

That allowed concurrent requests for the same `sessionID` to land in
different per-directory `InstanceState`s, splitting `SessionRunState`
busy/runner tracking and permitting overlapping prompt turns.

This patch adds a session-only middleware in `routes/session.ts` that,
for all `/:sessionID` and `/:sessionID/*` routes, reloads the session
and re-enters `Instance.provide({ directory: session.directory })`
before executing the handler.

## Why this fix

- small, narrow diff
- leaves global instance selection untouched for non-session routes
- leaves `Instance.state` keying unchanged
- covers all existing and future session-scoped routes in one place

## Behavior change

For existing session routes, `session.directory` now wins over
caller-supplied `x-opencode-directory` when selecting the backing
`Instance` context.

`POST /session` and other non-session routes still use the caller's
directory as before.

## Extra

Included a regression test that fires concurrent `prompt_async` requests
for one session with different `x-opencode-directory` headers and
asserts that only one run becomes active.

My confidence is high on the shape of the fix and medium on the exact import names / body schema at your fork commit. The one thing I would explicitly flag as TBD is whether your local Session.get(sessionID) can already run before the rebind; your note suggests yes, but if not, the middleware should call the same direct session-row lookup helper your existing prompt path already uses rather than project-scoped Session.get().