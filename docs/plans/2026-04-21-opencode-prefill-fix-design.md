# Fix: rebind `/session/:sessionID/*` routes to `session.directory`

## Session state (resume context, 2026-04-21)

**What landed:**

- Workstation commit `be175cc` shipped: `users/dev/home.base.nix` adds a
  per-target-session flock to `opencode-send` (default on, `--no-lock` /
  `OPENCODE_SEND_NO_LOCK=1` to disable). Already pushed to
  `johnnymo87/workstation` main and applied to cloudbox via
  `home-manager switch`.
- All 5 swarm sessions were broadcast a "use --cwd <target's-own-dir>"
  protocol switch and resumed without errors. Worker error counts went to
  zero post-broadcast; the only remaining "prefill" errors in the
  coordinator session are from MY OWN diagnostic test pings during the
  flock smoke test, not from the workers.
- `opencode-patched` (the actual upstream-binary fork) HAS NOT been
  patched yet. The design in this doc is the next step.

**Active swarm session IDs (so a fresh session can verify):**

- Coordinator: `ses_24e8ff295ffeyV8o35YuK63g2u` at
  `/home/dev/projects/mono`
- Worker mono backend: `ses_24e4c9b3effeoQgQNFIYDYm130` at
  `/home/dev/projects/mono/.worktrees/COPS-6107`
- Worker protos: `ses_24e4c9873ffexUz2X45WnfIPob` at
  `/home/dev/projects/protos/.worktrees/COPS-6107`
- Worker FE: `ses_24e4c9593ffe3amAM6XAaHGvp2` at
  `/home/dev/projects/internal-frontends/.worktrees/COPS-6107`
- Worker dbt: `ses_24e4c9321ffeyC4cOmdwqqCU0H` at
  `/home/dev/projects/data_recipe/.worktrees/COPS-6107`

**Outstanding work for the post-compaction session:**

1. **Get the PR-ready patch sketch from ChatGPT.** A briefing was
   queued to chatgpt-relay but the user paused us before it returned.
   Briefing file is at
   `docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-question.md`.
   Resume by running:

   ```
   ask-question -f docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-question.md \
                -o docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-answer.md \
                -t 1500000
   ```

   The user said they'd unblock the relay and signal when ready. Do not
   re-send until they confirm.

2. **Write the actual `prefill-fix.patch`** for `opencode-patched` once
   ChatGPT returns its diff sketch (or, if it doesn't add value, ship
   the design in this doc as-is). Add it alongside `vim.patch` in
   `~/projects/opencode-patched/patches/` and update `apply.sh` to apply
   it after the vim patch. Then the auto-update workflow will rebuild.

3. **Open an upstream issue / PR against `anomalyco/opencode`** (NOT
   `sst/opencode` — that's a different project) with the shell repro
   (4 concurrent `prompt_async` from 4 distinct `x-opencode-directory`
   headers → multiple parallel turns + 400 "prefill" from Claude).
   ChatGPT confirmed no existing upstream issue names this exact
   failure mode.

**Key facts learned (don't re-investigate):**

- The bug is in upstream `anomalyco/opencode` HEAD too, not just our
  patched fork. `SessionRunState.runners` is created via
  `InstanceState.make()` which keys per-`Instance.directory`. Verified
  at v1.14.19 in `packages/opencode/src/session/run-state.ts` (line ~33)
  and `packages/opencode/src/effect/instance-state.ts` (line ~65,
  `ScopedCache.get(self.cache, yield* directory)`).
- The HTTP middleware at
  `packages/opencode/src/server/routes/instance/middleware.ts`
  derives the Instance from `x-opencode-directory` header.
- `opencode-patched` builds against tag `v${version}` of
  `anomalyco/opencode` (the upstream — NOT `sst/opencode`). Build CI is
  `~/projects/opencode-patched/.github/workflows/build-release.yml`.
- Anthropic Claude Opus 4.7 / Opus 4.6 / Sonnet 4.6 do NOT support
  assistant-message prefill — confirmed by ChatGPT against Anthropic
  docs. Vertex's generic Claude page says otherwise but is stale.
- The flock alone is INSUFFICIENT once parallel `Instance` loops are
  already running: leftover loops will keep iterating and replying
  with their own cwds. The fixed-cwd protocol is the durable
  workaround.
- `Instance.directory` once cached is sticky. To clear stale Instance
  loops you'd need to restart `opencode-serve` (or wait for them to
  naturally drain).

**Files to read in the new session:**

- `docs/plans/2026-04-21-opencode-prefill-fix-design.md` (this file
  below the header) — the patch design.
- `docs/plans/research/2026-04-21-opencode-multi-instance-prefill-question.md`
  — the ChatGPT briefing that started this investigation.
- `docs/plans/research/2026-04-21-opencode-multi-instance-prefill-answer.md`
  — ChatGPT's first reply (root-cause confirmation + fix ranking +
  topology recommendation).
- `docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-question.md`
  — the still-pending second ask-question briefing (PR-ready patch
  sketch).
- `~/projects/opencode/packages/opencode/src/session/run-state.ts`,
  `~/projects/opencode/packages/opencode/src/effect/instance-state.ts`,
  `~/projects/opencode/packages/opencode/src/server/routes/instance/{session,middleware}.ts`,
  `~/projects/opencode/packages/opencode/src/project/instance.ts`
  (use `git show v1.14.19:<path>` to inspect the build-target version).

---

## Problem (one-paragraph recap)

The HTTP middleware at `packages/opencode/src/server/routes/instance/middleware.ts`
selects the active `Instance` from `x-opencode-directory` (or `?directory=`)
on EVERY request. Session-scoped state (the `runners` map in
`SessionRunState.layer`, backed by `InstanceState.make`) is keyed via
`InstanceState.context.directory`. Result: two `prompt_async` requests
targeting the same session id but coming from different
`x-opencode-directory` values resolve to two different `Instance`
contexts, see two different empty `runners` maps, both bypass the busy
guard, and both run the prompt loop concurrently against the same
SQLite session — corrupting the message tree and producing 400
"assistant message prefill" from Claude.

## Fix

For every `/session/:sessionID/*` route handler, **rebind the request's
`Instance` context to `session.directory` BEFORE invoking any
session-scoped service**. The session record's directory is the
authoritative owner of the session; the caller-supplied header is
irrelevant for already-existing sessions.

Routes that LIST sessions (`GET /session`), CREATE sessions
(`POST /session`), or otherwise don't operate on a specific existing
session id stay on the header-derived directory.

## Implementation sketch (v1.14.19 layout)

### A. New helper in `packages/opencode/src/server/routes/instance/session.ts`

```ts
import { Instance } from "@/project/instance"
import { InstanceBootstrap } from "@/project/bootstrap"
import { AppRuntime } from "@/effect/app-runtime"
import * as Session from "@/session/session"

/**
 * Re-enter the Instance corresponding to the session's stored directory
 * BEFORE running session-scoped work. This prevents the per-Instance
 * busy guard (SessionRunState.runners, backed by InstanceState) from
 * being bypassed when a request arrives with an x-opencode-directory
 * that differs from the session's owning directory.
 *
 * Returns the result of invoking `fn` under the session-owned Instance.
 * Throws 404 if the session does not exist.
 */
async function withSessionInstance<R>(
  sessionID: string,
  fn: () => Promise<R>,
): Promise<R> {
  // Read the session row OUTSIDE Instance.provide. The session table is
  // shared across Instances (single SQLite db), so a quick lookup is fine
  // here. We bypass the Effect runtime to keep the helper simple — the
  // fn() callback will get its own Effect context via runRequest.
  const info = await AppRuntime.runPromise(
    Effect.gen(function* () {
      const sessions = yield* Session.Service
      return yield* sessions.get(sessionID as any)
    }),
  )

  return Instance.provide({
    directory: info.directory,
    init: () => AppRuntime.runPromise(InstanceBootstrap),
    fn,
  })
}
```

### B. Wrap every `/:sessionID/...` route's handler body

Before:

```ts
.post("/:sessionID/prompt_async", …, async (c) => {
  const sessionID = c.req.valid("param").sessionID
  const body = c.req.valid("json")
  void runRequest(
    "SessionRoutes.prompt_async", c,
    SessionPrompt.Service.use((svc) => svc.prompt({ ...body, sessionID })),
  ).catch(...)
  return c.body(null, 204)
})
```

After:

```ts
.post("/:sessionID/prompt_async", …, async (c) => {
  const sessionID = c.req.valid("param").sessionID
  const body = c.req.valid("json")
  // Detach: don't await, but rebind to session.directory before runRequest.
  void withSessionInstance(sessionID, () =>
    runRequest(
      "SessionRoutes.prompt_async", c,
      SessionPrompt.Service.use((svc) => svc.prompt({ ...body, sessionID })),
    ),
  ).catch(...)
  return c.body(null, 204)
})
```

Apply the same wrapper to:

- `GET /:sessionID` (read)
- `GET /:sessionID/children`
- `POST /:sessionID/abort`
- `DELETE /:sessionID` (remove)
- `POST /:sessionID/share`, `DELETE /:sessionID/share`
- `POST /:sessionID/init`
- `POST /:sessionID/fork`
- `POST /:sessionID/summary` (summarize)
- `POST /:sessionID/summarize`
- `GET /:sessionID/message`, `GET /:sessionID/message/:messageID`
- `DELETE /:sessionID/message/:messageID/part/:partID`
- `PATCH /:sessionID/message/:messageID/part/:partID`
- `POST /:sessionID/prompt`
- `POST /:sessionID/prompt_async`
- `POST /:sessionID/command`
- `POST /:sessionID/shell`
- `POST /:sessionID/revert`
- `POST /:sessionID/unrevert`
- (plus any others under `/:sessionID/...`)

NOT to be wrapped:

- `GET /` (list)
- `POST /` (create — directory not yet bound)

### C. Test: Bun test with a mock provider

`packages/opencode/test/session/concurrent-prompts.test.ts`:

```ts
import { describe, test, expect } from "bun:test"
import { startTestServer, makeMockProvider } from "../helpers/server"
import { fetch } from "undici"

describe("/session/:id/prompt_async — concurrent multi-cwd race", () => {
  test("two concurrent prompts from different directories serialize, not parallelize", async () => {
    const provider = makeMockProvider({
      // pause inside the LLM call so the second request can race
      delayMs: 200,
      respondWith: "ok",
    })
    const { baseUrl } = await startTestServer({ providers: [provider] })

    // Create a session at directory A.
    const created = await fetch(`${baseUrl}/session`, {
      method: "POST",
      headers: { "x-opencode-directory": "/tmp/dirA" },
    }).then(r => r.json() as any)

    const sid = created.id
    const body = JSON.stringify({
      parts: [{ type: "text", text: "hi" }],
    })

    // Fire 4 concurrent prompts with 4 distinct directories.
    const results = await Promise.all([
      "/tmp/dirA", "/tmp/dirB", "/tmp/dirC", "/tmp/dirD"
    ].map(dir =>
      fetch(`${baseUrl}/session/${sid}/prompt_async`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-opencode-directory": dir,
        },
        body,
      }).then(r => r.status)
    ))

    expect(results).toEqual([204, 204, 204, 204])

    // Wait for the loop to drain.
    await waitForIdle(baseUrl, sid)

    // Inspect messages: there must be exactly ONE assistant child per user
    // message (no fan-out from concurrent runs).
    const msgs = await fetch(`${baseUrl}/session/${sid}/message`)
      .then(r => r.json() as any[])

    const userMessages = msgs.filter(m => m.info.role === "user")
    for (const u of userMessages) {
      const children = msgs.filter(m => m.info.parentID === u.info.id)
      expect(children.length).toBeLessThanOrEqual(1)
    }

    // Every assistant message must have path.cwd === session.directory.
    const assistants = msgs.filter(m => m.info.role === "assistant")
    for (const a of assistants) {
      expect(a.info.path?.cwd).toBe("/tmp/dirA")
    }

    // No prefill 400 errors.
    const errored = assistants.filter(a => a.info.error?.data?.message?.includes("prefill"))
    expect(errored.length).toBe(0)
  })
})
```

## Why this is the smallest fix

- `InstanceState` keying stays unchanged (no risk of breaking unrelated
  state caches).
- The HTTP middleware stays unchanged (still header-derived for `POST
  /session` and listing routes).
- The `SessionRunState.runners` map stays unchanged.
- Only session-scoped routes change behavior, and only by selecting a
  better directory before doing work — which they should ALREADY have
  been doing.

## Knock-on benefits

- Tools called by a session always run under the session's owning cwd
  (matches `session.directory` semantics that the rest of the codebase
  already assumes).
- `Permission.containsPath` checks for session-scoped operations
  consistently use the session's worktree, not the caller's.
- `SessionRunState.cancel(sessionID)` from any caller hits the right
  Instance (today, cancel from a different cwd would silently target an
  empty runners map).

## Open questions for ChatGPT

1. Best place to slot the helper: a per-route wrapper, or middleware
   matched against `/session/:sessionID/*`?
2. Should `withSessionInstance` cache the `Session.Service.get` result
   for a short TTL to avoid one extra SQLite read per request?
3. Are there session-scoped routes that legitimately need the
   caller-supplied directory (e.g. forking into a different worktree)?
