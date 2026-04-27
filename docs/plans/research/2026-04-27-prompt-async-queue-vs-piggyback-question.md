# Should `prompt_async` queue concurrent prompts, piggyback on the in-flight run, or stay as-is?

**Keywords:** Effect-TS, fiber-based concurrency, fire-and-forget HTTP semantics, per-resource serialization, work queue vs. coalescing, idempotent vs. distinct request payloads

## The situation

We just shipped a fix to `opencode-patched` (a fork of `anomalyco/opencode` at v1.14.28) that wraps every `/session/:sessionID/*` server route in a per-session `Instance` derived from the session's stored `directory`. Before the fix, when concurrent requests targeting the same session arrived from different `x-opencode-directory` headers, each request resolved to a different in-process `Instance` context, each saw an empty per-Instance `runners` map, each bypassed the session busy guard, and they all raced — corrupting the message tree and producing Anthropic 400 "assistant message prefill" errors.

Verified after-the-fix behavior with the same race repro:

```
Before (4 concurrent prompt_async POSTs from 4 distinct cwd headers):
  4 user rows + 8 assistant rows in 4 different cwds + 4 prefill 400 errors.

After (same repro):
  4 user rows + 1 assistant row in session.directory + 0 errors.
```

The 4 → 1 collapse on the assistant side is what we want to evaluate. We initially described it as "drop the racing prompts," but reading the runner code more carefully, that's not what's happening — it's actually piggyback semantics. We want a second opinion on whether to leave that as-is, switch to true queueing, or do something else entirely.

## Environment

- Language: TypeScript (Bun runtime), opencode is a TS monorepo built with Bun.
- Concurrency model: `effect` library (Effect-TS), version is whatever ships with opencode v1.14.28's `package.json`.
- Server: Hono.
- Persistence: SQLite for the message store (`~/.local/share/opencode/opencode.db`).
- Caller universe: a TUI (the user typing in a terminal), and a programmatic "pigeon" daemon that orchestrates messages between sibling sessions.
- Single-user tool. No multi-tenant concerns. The user is the only consumer of this fork.

## Code: how prompts arrive

The `/session/:sessionID/prompt_async` route handler returns 204 immediately and dispatches the work in the background. The fix we just shipped wraps the dispatch inside `withSessionInstance(sessionID, ...)` which derives the Instance from `Session.directory` (not the request header):

```ts
// patched apply.sh route handler
.post(
  "/:sessionID/prompt_async",
  // ...validators omitted
  async (c) => {
    const sessionID = c.req.valid("param").sessionID
    const body = c.req.valid("json")
    void withSessionInstance(sessionID, async () =>
      runRequest(
        "SessionRoutes.prompt_async",
        c,
        SessionPrompt.Service.use((svc) =>
          svc.prompt({ ...body, sessionID } as unknown as SessionPrompt.PromptInput),
        ),
      )
    ).catch((err) => {
      log.error("prompt_async failed", { sessionID, error: err })
      void Bus.publish(Session.Event.Error, {
        sessionID,
        error: new NamedError.Unknown({
          message: err instanceof Error ? err.message : String(err)
        }).toObject(),
      })
    })
    return c.body(null, 204)
  },
)
```

`withSessionInstance(sessionID, fn)` reads the session row, derives the `Instance` for that session's `directory`, and runs `fn` inside `Instance.provide({ directory, ... })`.

## Code: what `SessionPrompt.Service.prompt` does

`prompt(input)` always creates the user message first, then calls `loop(...)`:

```ts
const prompt: (input: PromptInput) => Effect.Effect<MessageV2.WithParts> = Effect.fn(
  "SessionPrompt.prompt"
)(function* (input: PromptInput) {
  const session = yield* sessions.get(input.sessionID)
  yield* revert.cleanup(session)
  const message = yield* createUserMessage(input)   // <-- user row written to SQLite EVERY TIME
  yield* sessions.touch(input.sessionID)

  const permissions: Permission.Ruleset = []
  for (const [t, enabled] of Object.entries(input.tools ?? {})) {
    permissions.push({ permission: t, action: enabled ? "allow" : "deny", pattern: "*" })
  }
  if (permissions.length > 0) {
    session.permission = permissions
    yield* sessions.setPermission({ sessionID: session.id, permission: permissions })
  }

  if (input.noReply === true) return message
  return yield* loop({ sessionID: input.sessionID })
})

const loop: (input: LoopInput) => Effect.Effect<MessageV2.WithParts> = Effect.fn(
  "SessionPrompt.loop"
)(function* (input: LoopInput) {
  return yield* state.ensureRunning(
    input.sessionID,
    lastAssistant(input.sessionID),
    runLoop(input.sessionID)
  )
})
```

So the user message is unconditionally persisted before the runner is consulted.

## Code: the runner (the busy guard mechanism we want to discuss)

`SessionRunState.ensureRunning(sessionID, onInterrupt, work)` ultimately delegates to `Runner.ensureRunning`:

```ts
// effect/runner.ts
export type State<A, E> =
  | { readonly _tag: "Idle" }
  | { readonly _tag: "Running"; readonly run: RunHandle<A, E> }
  | { readonly _tag: "Shell"; readonly shell: ShellHandle<A, E> }
  | { readonly _tag: "ShellThenRun"; readonly shell: ShellHandle<A, E>; readonly run: PendingHandle<A, E> }

const ensureRunning = (work: Effect.Effect<A, E>) =>
  SynchronizedRef.modifyEffect(
    ref,
    Effect.fnUntraced(function* (st) {
      switch (st._tag) {
        case "Running":
        case "ShellThenRun":
          // Already running — DO NOT start `work`. Await the in-flight run's deferred.
          return [Deferred.await(st.run.done), st] as const
        case "Shell": {
          // A shell command is in flight — schedule `work` to run AFTER the shell completes.
          const run = {
            id: next(),
            done: yield* Deferred.make<A, E | Cancelled>(),
            work,
          } satisfies PendingHandle<A, E>
          return [Deferred.await(run.done), { _tag: "ShellThenRun", shell: st.shell, run }] as const
        }
        case "Idle": {
          // Nothing running — start `work`, return its deferred.
          const done = yield* Deferred.make<A, E | Cancelled>()
          const run = yield* startRun(work, done)
          return [Deferred.await(done), { _tag: "Running", run }] as const
        }
      }
    }),
  ).pipe(/* ... */)
```

So the actual semantics for `prompt_async` racing are:

- 1st prompt arrives: state goes `Idle → Running`. Its `work` (the `runLoop`) is started. It awaits the completion deferred.
- 2nd prompt arrives ~1ms later: state is `Running`. Its `work` (a NEW `runLoop` with the 2nd prompt's text) is **discarded**. The caller awaits the FIRST prompt's deferred. When it resolves, the 2nd caller gets the same `MessageV2.WithParts` back.
- Same for 3rd and 4th: all piggyback on the first run's deferred.

But because `prompt_async` already returned 204 to the caller, the "result" the piggyback awaiters get is silently dropped on the floor. Net effect on observable state:

- 4 user rows written to SQLite (by `createUserMessage`, BEFORE the runner is consulted).
- 1 `runLoop` actually executes — the one driven by the FIRST prompt's input.
- The FIRST prompt gets answered. The 2nd/3rd/4th prompts' TEXT is sitting in SQLite as user rows but was never fed to the LLM.

In other words, when 4 prompts race the same session via `prompt_async`, only the first one gets a response — but the other three's text contents are persisted in user rows that are now orphaned (no assistant turn ever responded to them).

Note this is the SAME-SESSION race. Different sessions get fully independent runners and run in parallel.

## What `prompt_async` is for — the two real-world use patterns

1. **TUI typing.** A human types a prompt and hits enter. They cannot physically race themselves on a single session (there's only one input area, and the TUI debounces). For this pattern, the orphaned-user-rows-on-race scenario can't happen.

2. **Programmatic batch / pigeon swarm coordination.** A coordinator daemon may want to batch multiple prompts at the same session within milliseconds. Today, swarm peers are separate sessions, so racing the same session doesn't happen. But future workflows could plausibly batch ("here are 3 follow-up clarifications, send them all") — and that future code would silently lose 2 of 3 prompts while the user rows accumulate in the DB.

The user is currently the only consumer of this fork, and current swarm patterns don't trigger this. But we want to make a deliberate choice rather than rely on "we don't trigger it today."

## What we're considering (don't bias the researcher — list options neutrally)

- **A. Leave as-is (piggyback).** Document the behavior. Add a warning log when `ensureRunning` returns the existing deferred so we can detect when racing actually occurs in the wild. Accept that orphaned user rows are a possible artifact.

- **B. True queueing.** Change `Runner.ensureRunning` (or wrap it in `SessionPrompt.Service.prompt`) so that when state is `Running`, the new prompt is enqueued and drained when the runner becomes idle. Each queued prompt eventually drives its own `runLoop`. The 4-prompt race produces 4 sequential assistant turns. Open design questions: cap the queue size? At what limit, drop or 503? Do command/abort/init share the queue?

- **C. Reject on busy at the route layer.** Don't even call `prompt(...)` if `assertNotBusy` would throw. Return a 409 from `prompt_async` (which means changing the route's contract — it can't return 204 unconditionally anymore, breaking the fire-and-forget shape). Caller is responsible for retry/queueing.

- **D. Reject inside `prompt`, BEFORE creating the user message.** Add an `assertNotBusy` check early in `prompt(...)` that throws `BusyError` before `createUserMessage` runs. The caller still gets 204 (since the route already returned), but the dropped prompt produces a logged error and no orphaned user row. Doesn't help the caller know to retry, but cleans up the DB residue.

- **E. Defer `createUserMessage` to inside `runLoop`.** Move user-row creation into the work that the runner schedules, so racing prompts that get piggybacked don't leave orphaned rows. Combined with A or C, this would make piggyback semantics cleaner.

- **F. Something else we haven't thought of.**

## Specific questions for the researcher

1. **Is the piggyback semantic in `Runner.ensureRunning` an established pattern in Effect-TS or fiber-based concurrency libraries?** Where does it come from — is there a name for it (e.g., "request coalescing", "result deduplication"), and what's it typically used for? Is it a good fit for `prompt_async` semantics where each caller's PAYLOAD is distinct?

2. **In other CLI/agent tools that expose async prompt endpoints (Anthropic SDK, OpenAI SDK clients, Claude Code itself, Aider, Cursor's local server, etc.), how do they handle concurrent prompts to the same session?** Is there an industry-standard answer, or does it vary by tool?

3. **Is "fire-and-forget HTTP returns 204, but the work was silently coalesced with another in-flight request" considered an acceptable HTTP semantic for an internal API?** Where might this surprise downstream callers?

4. **For options B (queueing) and D (early reject without orphan rows), what are the canonical Effect-TS patterns?** Specifically:
   - For B: is there a built-in queue primitive (Effect's `Queue`?) that integrates with the existing `SynchronizedRef`-based runner state machine without a major rewrite?
   - For D: is there a clean way to add an `assertNotBusy` check inside an `Effect.fn` that early-returns a domain error?

5. **What's the failure mode we should worry MOST about** — the orphaned user rows (option A's residue), the silent loss of prompts B/C/D's CONTENT (regardless of which option), the resource cost of unbounded queueing (option B), or something else?

6. **Would you recommend any option? Why?** Recognize that we can also do nothing (A), and that "do nothing for now and revisit if we hit a real workflow that needs it" is a defensible answer.

## Constraints

- The fix must NOT break the `/session/:sessionID/prompt_async` route's 204 contract. Existing TUI clients depend on it.
- The fix must NOT require upstream `anomalyco/opencode` to change. We patch our local fork only.
- We do not want to introduce a new persistent queue (e.g., Redis, BullMQ, etc.). In-memory only. The fork is single-process.
- Effect-TS patterns preferred over hand-rolled fiber management — the rest of the codebase uses Effect, and inconsistency would hurt maintainability.
- No new dependencies if avoidable.

## What we know for sure (verified)

- Reading the full `Runner.ensureRunning` implementation in `effect/runner.ts` confirms the piggyback semantic.
- Reading `SessionPrompt.prompt` confirms `createUserMessage` runs before the runner is consulted, so all 4 user rows are written to SQLite even when 3 prompts piggyback.
- Verified empirically: 4 concurrent `prompt_async` POSTs to the same session id (with our prefill fix in place) produce 4 user rows + 1 assistant row + zero errors. Serve log shows exactly one `session.prompt step=0/step=1/exiting` cycle for the test session.

## What we're uncertain about

- Whether the piggyback is intentional design by the original opencode author or an accidental consequence of `Runner` being a generic primitive that wasn't specifically designed for prompts.
- Whether the orphaned user rows cause downstream problems we haven't observed yet (e.g., does the next assistant turn see them in its context window? probably yes, which means racing prompts could pollute future LLM input even if they don't trigger their own turns).
- Whether real future workflows will actually hit this race, or whether it's a theoretical concern.
