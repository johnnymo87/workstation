# OpenCode multi-instance prefill race — please produce the PR-ready patch sketch

This is a follow-up to the earlier briefing about the OpenCode swarm bug
where concurrent `prompt_async` requests to one session from different
`x-opencode-directory` headers split the busy guard and produce concurrent
LLM turns, ending in 400 "does not support assistant message prefill" from
Claude Opus 4.7 on Vertex.

Your earlier reply offered to "turn that into a PR-ready patch sketch
against the current OpenCode route/middleware layout." Please produce it.

## Patch scope (preferred)

**Fix #1 in your ranking — rebind session-scoped routes to `session.directory`
instead of caller-supplied `x-opencode-directory`.** That was your
recommended smallest narrow PR.

If the current upstream code has refactored to `Runner` / `SessionRunState`,
please target that layout. Our local fork is `johnnymo87/opencode-patched`
on commit `b312928e9` (recently rebased on upstream `sst/opencode`).

## What we need in the patch sketch

1. **Concrete diff(s)** for the relevant files. We're happy with
   `--- a/...` / `+++ b/...` style hunks; even pseudo-diffs are fine if
   line numbers will drift. Real TS code preferred.
2. **The rebinding mechanism.** Specifically: how should a route handler
   that received `Instance.provide({directory: header.directory})` from
   the global middleware re-enter `Instance.provide({directory:
   session.directory})` for `/session/:id/...` paths? Should this be:
   a. A second middleware that runs only for matched session routes
      (e.g. `app.use('/session/:sessionID/*', sessionInstanceMiddleware)`)?
   b. A wrapper `withSessionInstance(c, fn)` invoked by each session route?
   c. A change to the global middleware to detect the path and look up
      the session before resolving directory?
   Please pick one and justify briefly.
3. **What to do for routes that currently accept either `x-opencode-directory`
   OR derive from session.** Today, `prompt_async` accepts
   `x-opencode-directory` to set the per-tool-call cwd in the **current**
   prompt's tools. If we rebind everything to `session.directory`, do we
   lose any legitimate use case? (Subagents calling tools in alternate
   worktrees? Something the TUI does?)
4. **Cancellation, status, share, command, and any other session-scoped
   routes** — confirm the list of routes that should be rebound (we
   suspect everything under `/session/:sessionID/*` except possibly POST
   `/session` itself).
5. **A failing test.** Bun test using a mock provider that:
   - creates a session
   - fires N concurrent `prompt_async` POSTs with N distinct
     `x-opencode-directory` headers
   - asserts that only one run becomes active and the rest are queued
     (or rejected with `Session.BusyError`).
   Please give us the file path and full TS source.
6. **A short PR description** suitable for opening on `sst/opencode`.

## Constraints / nice-to-haves

- The patch should be reviewable in <300 lines diff.
- Don't refactor `Instance.state` keying. Leave that machinery alone.
- We can ship to our fork same-day; upstream PR is "soonish."
- If you want to also include the trivial `prompt_async` await/detach-log
  fix as a separate hunk, that's welcome but should not gate the main fix.

## Specific things to be honest about

- If you can't confidently produce a real diff because the upstream code
  has drifted from what we quoted, say so and produce **the smallest
  pseudo-diff that captures the structure** — we'll adapt to the real
  layout. We'd rather have a correct approach with placeholder line
  numbers than incorrect diffs that look real.
- If you're uncertain whether some session-scoped route legitimately
  needs caller-supplied directory, flag it as TBD rather than guessing.

Source files we already know are involved (commit `b312928e9`):

- `packages/opencode/src/server/server.ts` — global Hono middleware that
  reads `x-opencode-directory` and calls `Instance.provide`.
- `packages/opencode/src/server/routes/session.ts` — `prompt_async` and
  other `/session/:sessionID/*` routes.
- `packages/opencode/src/session/prompt.ts` — `SessionPrompt` namespace,
  `state`, `start`, `loop`, `prompt`.
- `packages/opencode/src/project/instance.ts` — `Instance.provide`,
  `Instance.state`.
- `packages/opencode/src/project/state.ts` — `State.create`.

The session row in SQLite has a `directory` field, so reading it back is
cheap; we already use `Session.get(sessionID)` in the prompt path.

Please produce the patch sketch.
