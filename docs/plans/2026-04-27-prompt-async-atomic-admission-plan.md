# `prompt_async` atomic admission (Option D-prime) implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `Runner.ensureRunning`'s implicit request-coalescing semantics for `prompt_async` with explicit atomic admission-or-rejection, eliminating orphaned user rows and silent permission mutations when concurrent prompts race the same session.

**Architecture:** Add a `tryAdmitPrompt(sessionID): Effect<boolean>` method to `SessionRunState.Service` that atomically claims the session's runner slot via a `SynchronizedRef` modify (no TOCTOU window). In `SessionPrompt.Service.prompt`, gate `createUserMessage` + `setPermission` + `loop` behind a successful `tryAdmitPrompt`. On rejection, throw `Session.BusyError` (already exists; already mapped to a 400 by `serverErrorMiddleware`) — but the `prompt_async` route will explicitly catch and log/publish it as a `Session.Event.Error` so the 204 fire-and-forget contract is preserved without surfacing the rejection as an HTTP error to the caller. `prompt` (the synchronous variant via `command` route) WILL surface `BusyError` as a 400, matching existing semantics for `startShell` (`session.shell` route).

**Tech stack:** TypeScript, Effect-TS (`SynchronizedRef`, `Effect.fn`), Bun test runner, opencode-patched patch stack (apply.sh).

---

## Context (read first)

Three documents define the problem space. Read them before touching code.

1. **The bug:** `~/projects/workstation/.plans/2026-04-27-task2-handoff.md` — RESOLVED section explains why concurrent `prompt_async` requests to the same session previously corrupted the message tree, why the in-flight `prefill-fix.patch` (already shipped in opencode-patched v1.14.28-patched) fixes the most acute symptom by binding all routes to `session.directory`, and the residual issue: `Runner.ensureRunning` silently coalesces distinct prompt payloads.

2. **The architectural decision:** `~/projects/workstation/docs/plans/research/2026-04-27-prompt-async-queue-vs-piggyback-answer.md` (the ChatGPT research; the matching question is in the same dir) — the full rationale for choosing D-prime (atomic admission) over A (leave it), B (queue), C (route-layer 409), or D (naive precheck-then-act, which has a TOCTOU race). The four risks of leaving the current behavior unchanged are enumerated there: future context pollution, misleading transcript, **side-effect leakage (permissions mutated by piggybacked prompts)**, and debugging ambiguity.

3. **The race specifics:** `~/projects/workstation/docs/plans/2026-04-21-opencode-prefill-fix-design.md` — describes the per-Instance runners-map keying that the prefill fix solved. We're now extending the *same* fix to also handle the case where 4 prompts arrive that all SUCCESSFULLY bind to the same Instance (post-prefill-fix) but still race because `Runner.ensureRunning` coalesces them.

**Key precondition:** This work is on top of opencode-patched v1.14.28-patched (which has `prefill-fix.patch` applied). The fix here is a NEW patch (`prompt-admission.patch`) that goes 7th in the apply.sh stack, AFTER `prefill-fix.patch`. Without prefill-fix, this work makes no sense (the runners map keying would still be wrong).

---

## Verified facts (do not re-investigate)

- `BusyError` already exists at `~/projects/opencode/packages/opencode/src/session/session.ts:364`. It's a plain JS class (not a `Data.TaggedError`). It's already exported as `Session.BusyError`. It's already mapped to HTTP 400 by `~/projects/opencode/packages/opencode/src/server/middleware.ts:29`.
- `SessionRunState.Service` already has `assertNotBusy(sessionID): Effect<void>` (`run-state.ts:70`). It's the naive precheck — it reads state and throws `BusyError` if busy. It does NOT atomically claim the slot. Calling it from `SessionPrompt.prompt` would have the TOCTOU race that ChatGPT specifically warned about.
- `Runner.ensureRunning` (`effect/runner.ts:103-131`) is a generic primitive used by both `prompt` (via `loop`) and `startShell`. We must not break `startShell`'s usage. The fix lives in `SessionRunState` (the wrapper) and `SessionPrompt.prompt` (the caller), NOT in the generic `Runner`.
- `SessionPrompt.prompt` (`session/prompt.ts`) currently does:
  ```ts
  const session = yield* sessions.get(input.sessionID)
  yield* revert.cleanup(session)
  const message = yield* createUserMessage(input)   // <-- writes to SQLite
  yield* sessions.touch(input.sessionID)            // <-- mutates session
  // ... permission mutation here ...
  if (input.noReply === true) return message
  return yield* loop({ sessionID: input.sessionID })  // <-- calls state.ensureRunning
  ```
  All four mutations happen BEFORE the runner is consulted. A piggybacked prompt currently writes a user row, touches the session, mutates permissions — and then never gets answered.
- Test runner is **Bun** (`bun test --timeout 30000`). Existing test pattern in `packages/opencode/test/server/session-actions.test.ts` shows the canonical shape: `import { describe, expect, test } from "bun:test"`, wrap effects in `Effect.runPromise(... .pipe(Effect.provide(SessionNs.defaultLayer)))`.
- `prompt_async` route handler in `prefill-fix.patch` already wraps in `withSessionInstance(sessionID, ...)` and catches errors. We need to extend that catch to recognize `Session.BusyError` and treat it differently from generic errors (don't publish as `Session.Event.Error.Unknown`; publish as a typed busy-rejection event or simply log).
- `noReply: true` short-circuits `prompt` BEFORE the runner is consulted. With our new admission gate, `noReply: true` should ALSO be allowed regardless of busy state — it's just a user-message write, no LLM work. (We need to be careful: the `revert.cleanup` and `createUserMessage` and `setPermission` mutations should still gate on admission for the non-noReply path, but the noReply path may want different semantics. See Task 4 design discussion.)

---

## Implementation strategy

The patch is a **new opencode-patched patch file** named `prompt-admission.patch`, applied 7th in the stack (after `prefill-fix.patch`). It modifies two upstream files:

1. `packages/opencode/src/session/run-state.ts` — add `tryAdmitPrompt` and `releasePromptAdmission` methods to `SessionRunState.Interface`. The implementation uses `SynchronizedRef.modifyEffect` to atomically claim/release.

2. `packages/opencode/src/session/prompt.ts` — change `SessionPrompt.prompt(input)` to gate `createUserMessage` + `sessions.touch` + permission mutation + `loop` invocation behind `tryAdmitPrompt`. On rejection, throw `Session.BusyError(sessionID)`.

3. `packages/opencode-patched/patches/prefill-fix.patch` — modify the `prompt_async` route's `.catch(err => ...)` clause to recognize `Session.BusyError` and downgrade the log level / use a typed event publish. (Alternatively: add the catch logic in a SECOND patch file. For DRY, edit the existing prefill-fix.patch.)

The patch is authored against the v1.14.28 source tree (matching what opencode-patched currently builds). After authoring, smoke-test against a fresh v1.14.28 clone with the full apply.sh stack.

The end result is a NEW commit on opencode-patched main containing the new `prompt-admission.patch` + an updated `apply.sh` referencing it. Then re-dispatch the v1.14.28 build (which republishes the same v1.14.28-patched tag with new asset hashes) and re-trigger the workstation auto-update workflow.

**KNOWN GOTCHA from prior session:** the workstation auto-update workflow keys on the version string (`X.Y.Z`) extracted from `home.base.nix`. A same-version republish (still v1.14.28) will NOT trigger a new auto-PR. Two options:
- **(a) Hand-update `home.base.nix` hashes** via `nix-prefetch-url` for each platform asset. Manual but small (one-time).
- **(b) Wait for upstream v1.14.29** so the auto-update flow handles it. But that may be days/weeks. Defer indefinitely.

Recommend (a). Documented in Task 9.

---

## Task 1: Set up worktree

**Files:**
- Worktree branch on `~/projects/opencode-patched`.

**Step 1: Verify clean state on opencode-patched**

```bash
cd ~/projects/opencode-patched
git status --short
# Expected: empty (clean)
git log --oneline -3
# Expected: HEAD is c4f4027 "fix: rebase prefill-fix patch onto v1.14.28" (or later if other changes have landed)
```

**Step 2: Create a working branch**

```bash
cd ~/projects/opencode-patched
git checkout -b feat/prompt-admission
```

We work directly on a branch (not a worktree) because the patch authoring needs concurrent access to the opencode upstream worktree at `~/projects/opencode` — we don't gain isolation by branching twice.

**Step 3: Verify upstream worktree is at v1.14.28**

```bash
cd ~/projects/opencode
git status --short
# Expected: empty
git describe --tags
# Expected: v1.14.28
```

If not at v1.14.28, `git checkout v1.14.28`.

---

## Task 2: Write the failing test for `tryAdmitPrompt` (TDD red)

**Files:**
- Create: `~/projects/opencode/packages/opencode/test/session/run-state.test.ts`

**Step 1: Write the failing test**

Author the test in the upstream worktree. After we author the patch, this test will become part of the patch (or it will be excluded — see step 4). Either way, it's the verification gate.

```typescript
// packages/opencode/test/session/run-state.test.ts
import { afterEach, describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { Instance } from "../../src/project/instance"
import { Session as SessionNs } from "../../src/session"
import { SessionRunState } from "../../src/session/run-state"
import { Log } from "../../src/util"
import { tmpdir } from "../fixture/fixture"

void Log.init({ print: false })

function run<A, E>(fx: Effect.Effect<A, E, SessionRunState.Service | SessionNs.Service>) {
  return Effect.runPromise(
    fx.pipe(
      Effect.provide(SessionRunState.defaultLayer),
      Effect.provide(SessionNs.defaultLayer),
    ),
  )
}

afterEach(async () => {
  await Instance.disposeAll()
})

describe("SessionRunState.tryAdmitPrompt", () => {
  test("first admission succeeds, second is rejected while held", async () => {
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      await run(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const session = yield* sessions.create({ title: "test admission" })
        const state = yield* SessionRunState.Service

        const first = yield* state.tryAdmitPrompt(session.id)
        expect(first).toBe(true)

        const second = yield* state.tryAdmitPrompt(session.id)
        expect(second).toBe(false)

        // Releasing must allow re-admission.
        yield* state.releasePromptAdmission(session.id)

        const third = yield* state.tryAdmitPrompt(session.id)
        expect(third).toBe(true)

        yield* state.releasePromptAdmission(session.id)
      }))
    }})
  })

  test("admissions for different sessions are independent", async () => {
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      await run(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const a = yield* sessions.create({ title: "a" })
        const b = yield* sessions.create({ title: "b" })
        const state = yield* SessionRunState.Service

        const aOk = yield* state.tryAdmitPrompt(a.id)
        const bOk = yield* state.tryAdmitPrompt(b.id)
        expect(aOk).toBe(true)
        expect(bOk).toBe(true)

        yield* state.releasePromptAdmission(a.id)
        yield* state.releasePromptAdmission(b.id)
      }))
    }})
  })

  test("releasing a non-admitted session is a no-op (does not throw)", async () => {
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      await run(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const session = yield* sessions.create({ title: "noop release" })
        const state = yield* SessionRunState.Service
        // Should not throw.
        yield* state.releasePromptAdmission(session.id)
      }))
    }})
  })
})
```

Note: the test imports may need adjustment based on the actual `tmpdir` fixture and `Instance.provide` signature in v1.14.28. Inspect `~/projects/opencode/packages/opencode/test/fixture/fixture.ts` and `~/projects/opencode/packages/opencode/test/server/session-actions.test.ts` for the exact patterns. Adjust as needed but keep the structure: import bun:test → provide layers → call `tryAdmitPrompt` → assert.

**Step 2: Run the test to confirm it fails**

```bash
cd ~/projects/opencode
bun test packages/opencode/test/session/run-state.test.ts 2>&1 | tail -20
```

Expected: TypeScript compilation error or test failure with a message like `state.tryAdmitPrompt is not a function`. We have not implemented the method yet.

If the test PASSES somehow, something is wrong (maybe an old version of the file is cached). Investigate.

---

## Task 3: Implement `tryAdmitPrompt` and `releasePromptAdmission` on `SessionRunState`

**Files:**
- Modify: `~/projects/opencode/packages/opencode/src/session/run-state.ts`

**Step 1: Extend the `Interface`**

Open `run-state.ts`. Add two methods to the `Interface`:

```typescript
export interface Interface {
  readonly assertNotBusy: (sessionID: SessionID) => Effect.Effect<void>
  readonly cancel: (sessionID: SessionID) => Effect.Effect<void>
  readonly ensureRunning: (
    sessionID: SessionID,
    onInterrupt: Effect.Effect<MessageV2.WithParts>,
    work: Effect.Effect<MessageV2.WithParts>,
  ) => Effect.Effect<MessageV2.WithParts>
  readonly startShell: (
    sessionID: SessionID,
    onInterrupt: Effect.Effect<MessageV2.WithParts>,
    work: Effect.Effect<MessageV2.WithParts>,
  ) => Effect.Effect<MessageV2.WithParts>
  /**
   * Atomically attempt to claim the runner admission slot for this session.
   * Returns true if the caller is granted exclusive admission to begin a
   * prompt turn. Returns false if another caller already holds the
   * admission. Caller MUST invoke `releasePromptAdmission` exactly once
   * after a successful admission, OR the runner-state machinery (when the
   * actual `ensureRunning` work completes) must do so.
   *
   * This exists to provide the atomic claim-or-reject semantic that
   * `assertNotBusy` lacks (TOCTOU race). Use this when you need to gate
   * durable side effects on whether the prompt will actually run.
   */
  readonly tryAdmitPrompt: (sessionID: SessionID) => Effect.Effect<boolean>
  /**
   * Release a prior successful admission. Idempotent: releasing when not
   * admitted is a no-op. Always called from the rejection-path cleanup or
   * from the `ensureRunning` finalizer.
   */
  readonly releasePromptAdmission: (sessionID: SessionID) => Effect.Effect<void>
}
```

**Step 2: Implement the new methods inside the `layer`**

Inside `Layer.effect(Service, Effect.gen(function* () { ... }))`, alongside the existing `runner`, `assertNotBusy`, etc., add a new admission map and the two methods. Place after `assertNotBusy` and before `cancel`.

```typescript
    // Admission slots, keyed by sessionID. Distinct from `runners` because
    // admission is claimed BEFORE the runner is constructed (so that
    // createUserMessage and other prompt-side effects can be gated).
    // Once the actual runner work begins via ensureRunning, the runner
    // map takes over the busy bookkeeping; admission is released by the
    // prompt service in its finally clause.
    const admissions = new Set<SessionID>()

    const tryAdmitPrompt = Effect.fn("SessionRunState.tryAdmitPrompt")(function* (sessionID: SessionID) {
      // Both `runners` (existing prompt loop in flight) and `admissions`
      // (claim slot held but loop not yet started) count as busy.
      const data = yield* InstanceState.get(state)
      if (data.runners.has(sessionID)) return false
      if (admissions.has(sessionID)) return false
      admissions.add(sessionID)
      return true
    })

    const releasePromptAdmission = Effect.fn("SessionRunState.releasePromptAdmission")(function* (sessionID: SessionID) {
      admissions.delete(sessionID)
    })
```

Then add them to the returned service object:

```typescript
    return Service.of({
      assertNotBusy,
      cancel,
      ensureRunning,
      startShell,
      tryAdmitPrompt,
      releasePromptAdmission,
    })
```

**Step 3: Concurrency note (read carefully)**

`InstanceState.make` runs a function inside the Instance scope, and the returned `state` is per-Instance. Since `tryAdmitPrompt` checks both `data.runners` and `admissions`, and only mutates `admissions`, the operations on `admissions` happen on the JS event loop (single-threaded). Bun runs handlers serially. There's no preemption in JS. The `data.runners.has` followed by `admissions.add` is atomic in practice because no `await`/`yield*` falls between them (we only `yield* InstanceState.get` at the start, then it's all synchronous).

If a future maintainer changes this to introduce an `await` between the check and the add, the atomicity breaks. **Add a comment explicitly noting this.**

```typescript
    const tryAdmitPrompt = Effect.fn("SessionRunState.tryAdmitPrompt")(function* (sessionID: SessionID) {
      const data = yield* InstanceState.get(state)
      // CRITICAL: between this point and `admissions.add(sessionID)` there
      // must be NO await/yield*. JS single-threaded execution gives us
      // atomicity here only because no fiber suspension occurs. If you
      // need to add async work, switch to SynchronizedRef or you will
      // re-introduce the TOCTOU race this method exists to prevent.
      if (data.runners.has(sessionID)) return false
      if (admissions.has(sessionID)) return false
      admissions.add(sessionID)
      return true
    })
```

**Step 4: Run the test, expect PASS**

```bash
cd ~/projects/opencode
bun test packages/opencode/test/session/run-state.test.ts 2>&1 | tail -20
```

Expected: 3 tests pass.

If a test fails, debug the test or the implementation. Do NOT proceed until all 3 pass.

**Step 5: Re-run full test suite to confirm no regressions**

```bash
cd ~/projects/opencode
bun test 2>&1 | tail -30
```

Expected: same baseline pass count + 3 new passing tests. No new failures.

If existing tests fail, your implementation has broken something. Investigate.

---

## Task 4: Write failing tests for `SessionPrompt.prompt` admission gating

**Files:**
- Create: `~/projects/opencode/packages/opencode/test/session/prompt-admission.test.ts`

**Step 1: Write the failing tests**

```typescript
// packages/opencode/test/session/prompt-admission.test.ts
import { afterEach, describe, expect, test } from "bun:test"
import { Effect } from "effect"
import { Instance } from "../../src/project/instance"
import { Session as SessionNs } from "../../src/session"
import { SessionPrompt } from "../../src/session/prompt"
import { SessionRunState } from "../../src/session/run-state"
import { Log } from "../../src/util"
import { tmpdir } from "../fixture/fixture"

void Log.init({ print: false })

afterEach(async () => {
  await Instance.disposeAll()
})

describe("SessionPrompt.prompt with admission gating", () => {
  test("racing prompt while one is in flight throws BusyError without writing user message", async () => {
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      const result = await Effect.runPromise(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const session = yield* sessions.create({ title: "race test" })
        const state = yield* SessionRunState.Service

        // Manually claim admission to simulate "first prompt is in flight".
        const claimed = yield* state.tryAdmitPrompt(session.id)
        expect(claimed).toBe(true)

        // Now attempt a second prompt.
        const promptSvc = yield* SessionPrompt.Service
        const messagesBefore = yield* sessions.messages({ sessionID: session.id, limit: 100 })
        const userCountBefore = messagesBefore.filter(m => m.info.role === "user").length

        let busyError: SessionNs.BusyError | null = null
        try {
          yield* promptSvc.prompt({
            sessionID: session.id,
            parts: [{ type: "text", text: "this should not write a user row" }],
          })
        } catch (e) {
          if (e instanceof SessionNs.BusyError) busyError = e
          else throw e
        }
        expect(busyError).not.toBeNull()
        expect(busyError!.sessionID).toBe(session.id)

        const messagesAfter = yield* sessions.messages({ sessionID: session.id, limit: 100 })
        const userCountAfter = messagesAfter.filter(m => m.info.role === "user").length

        // CRITICAL ASSERTION: no orphan user row was written for the rejected prompt.
        expect(userCountAfter).toBe(userCountBefore)

        // Cleanup admission for the test fixture.
        yield* state.releasePromptAdmission(session.id)

        return { busyError, userCountBefore, userCountAfter }
      }).pipe(
        Effect.provide(SessionPrompt.defaultLayer),
        Effect.provide(SessionRunState.defaultLayer),
        Effect.provide(SessionNs.defaultLayer),
      ))
      expect(result.userCountAfter).toBe(result.userCountBefore)
    }})
  })

  test("racing prompt does not mutate session permissions", async () => {
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      await Effect.runPromise(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const session = yield* sessions.create({ title: "perm leak test" })
        const state = yield* SessionRunState.Service
        const promptSvc = yield* SessionPrompt.Service

        const beforePerms = JSON.stringify(session.permission ?? [])

        // Claim admission first.
        yield* state.tryAdmitPrompt(session.id)

        // Try to send a prompt with a tools override (which would mutate permissions
        // if it ran).
        try {
          yield* promptSvc.prompt({
            sessionID: session.id,
            parts: [{ type: "text", text: "x" }],
            tools: { bash: false },  // would deny bash if it ran
          })
        } catch {
          // expected BusyError
        }

        const after = yield* sessions.get(session.id)
        const afterPerms = JSON.stringify(after.permission ?? [])

        // CRITICAL ASSERTION: permissions were not mutated by the rejected prompt.
        expect(afterPerms).toBe(beforePerms)

        yield* state.releasePromptAdmission(session.id)
      }).pipe(
        Effect.provide(SessionPrompt.defaultLayer),
        Effect.provide(SessionRunState.defaultLayer),
        Effect.provide(SessionNs.defaultLayer),
      ))
    }})
  })

  test("noReply: true bypasses admission gate (just persists user message)", async () => {
    // This test documents the explicit decision: noReply prompts are write-only,
    // so they don't need to claim a runner slot. Multiple concurrent noReply
    // prompts CAN coexist with a busy session and produce real user rows.
    await Instance.provide({ directory: await tmpdir(), init: () => Effect.void, fn: async () => {
      await Effect.runPromise(Effect.gen(function* () {
        const sessions = yield* SessionNs.Service
        const session = yield* sessions.create({ title: "noReply test" })
        const state = yield* SessionRunState.Service
        const promptSvc = yield* SessionPrompt.Service

        // Claim admission to make the session "busy".
        yield* state.tryAdmitPrompt(session.id)

        // Despite busy session, noReply: true should succeed and write a user row.
        const result = yield* promptSvc.prompt({
          sessionID: session.id,
          parts: [{ type: "text", text: "noReply payload" }],
          noReply: true,
        })
        expect(result.info.role).toBe("user")

        const messages = yield* sessions.messages({ sessionID: session.id, limit: 100 })
        const userCount = messages.filter(m => m.info.role === "user").length
        expect(userCount).toBe(1)

        yield* state.releasePromptAdmission(session.id)
      }).pipe(
        Effect.provide(SessionPrompt.defaultLayer),
        Effect.provide(SessionRunState.defaultLayer),
        Effect.provide(SessionNs.defaultLayer),
      ))
    }})
  })
})
```

**Step 2: Run tests to confirm they fail**

```bash
cd ~/projects/opencode
bun test packages/opencode/test/session/prompt-admission.test.ts 2>&1 | tail -30
```

Expected: 3 failures. The first 2 should fail because no admission gate exists yet — the prompt will write the user row anyway. The third (`noReply: true bypasses`) might already pass since `noReply: true` short-circuits before the existing `loop` call — but it should fail in the new world if you forget to special-case it. Either way, all 3 should be in a failed/inconsistent state until you implement Task 5.

---

## Task 5: Add the admission gate to `SessionPrompt.prompt`

**Files:**
- Modify: `~/projects/opencode/packages/opencode/src/session/prompt.ts`

**Step 1: Read the current `prompt` implementation**

Locate `const prompt: (input: PromptInput) => Effect.Effect<MessageV2.WithParts>` in `prompt.ts`. Identify the exact lines (it's roughly the first ~25 lines of the function, ending with `return yield* loop({ sessionID: input.sessionID })`).

**Step 2: Modify `prompt` to gate side effects on admission**

The new shape, with admission claim BEFORE any durable side effect:

```typescript
const prompt: (input: PromptInput) => Effect.Effect<MessageV2.WithParts> = Effect.fn("SessionPrompt.prompt")(
  function* (input: PromptInput) {
    const session = yield* sessions.get(input.sessionID)

    // noReply prompts are write-only (just persist the user message). They
    // don't claim a runner slot — multiple concurrent noReply submissions
    // are fine. They still cleanup revert state so the next real prompt
    // sees a clean tree.
    if (input.noReply === true) {
      yield* revert.cleanup(session)
      const message = yield* createUserMessage(input)
      yield* sessions.touch(input.sessionID)
      return message
    }

    // For real prompts that drive a runLoop, atomically claim admission
    // BEFORE any durable side effect (user row write, session touch,
    // permission mutation). On failure, throw BusyError without writing
    // anything. This eliminates the orphan-row + permission-leak symptoms
    // that plain Runner.ensureRunning piggybacking would otherwise cause.
    const admitted = yield* state.tryAdmitPrompt(input.sessionID)
    if (!admitted) {
      throw new Session.BusyError(input.sessionID)
    }

    // From here on, we MUST release the admission. Use a try/finally
    // pattern via Effect.ensuring so cleanup runs on both success and
    // failure.
    const work = Effect.gen(function* () {
      yield* revert.cleanup(session)
      const message = yield* createUserMessage(input)
      yield* sessions.touch(input.sessionID)

      const permissions: Permission.Ruleset = []
      for (const [t, enabled] of Object.entries(input.tools ?? {})) {
        permissions.push({ permission: t, action: enabled ? "allow" : "deny", pattern: "*" })
      }
      if (permissions.length > 0) {
        session.permission = permissions
        yield* sessions.setPermission({ sessionID: session.id, permission: permissions })
      }

      return yield* loop({ sessionID: input.sessionID })
    })

    return yield* work.pipe(Effect.ensuring(state.releasePromptAdmission(input.sessionID)))
  },
)
```

**Step 3: Verify imports**

`Session` and `state` must be in scope. They are (already imported above for the existing implementation). The `state` reference is the `SessionRunState.Service` already destructured at the top of the layer body.

**Step 4: Run the prompt-admission tests, expect PASS**

```bash
cd ~/projects/opencode
bun test packages/opencode/test/session/prompt-admission.test.ts 2>&1 | tail -20
```

Expected: 3 tests pass.

If they fail, debug. Common issues:
- Forgot to `import * as Session from "./session"` for the BusyError class — it should already be imported but verify.
- `state.tryAdmitPrompt` not found — verify Task 3 was committed and the test sees the updated file.

**Step 5: Run full test suite to confirm no regressions**

```bash
cd ~/projects/opencode
bun test 2>&1 | tail -30
```

Expected: baseline pass count + new tests pass. No new failures.

**Particularly important to verify:**
- `packages/opencode/test/server/session-actions.test.ts` (if it tests prompt behavior).
- `packages/opencode/test/cli/cmd/tui/prompt-part.test.ts` (TUI integration).
- `packages/opencode/test/server/httpapi-session.test.ts` (HTTP integration).

If any of these regress, the admission gate is too aggressive or the `noReply` short-circuit is wrong. Investigate before proceeding.

---

## Task 6: Update `prompt_async` route's catch clause to handle `BusyError` cleanly

**Files:**
- Modify: `~/projects/opencode/packages/opencode/src/server/routes/instance/session.ts` (the route handler that the prefill-fix patch already wraps with `withSessionInstance`)

**Step 1: Locate the `prompt_async` handler**

It's around `session.ts:891` in v1.14.28 (where `prefill-fix.patch` wraps it with `withSessionInstance`). Look for the route definition `.post("/:sessionID/prompt_async", ...`.

**Step 2: Modify the `.catch` clause to recognize `BusyError`**

Currently the catch logs the error and publishes `Session.Event.Error` with `NamedError.Unknown`. For `BusyError`, that produces a noisy 500-style event for what is actually expected backpressure. Instead:

```typescript
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
    ),
  ).catch((err) => {
    if (err instanceof Session.BusyError) {
      // Expected backpressure: another prompt is in flight on this session.
      // Log at info level (not error) and publish a typed busy event that
      // listeners can subscribe to without thinking it's a crash.
      log.info("prompt_async rejected (session busy)", { sessionID })
      void Bus.publish(Session.Event.Error, {
        sessionID,
        error: new NamedError.Unknown({ message: err.message }).toObject(),
      })
      return
    }
    log.error("prompt_async failed", { sessionID, error: err })
    void Bus.publish(Session.Event.Error, {
      sessionID,
      error: new NamedError.Unknown({
        message: err instanceof Error ? err.message : String(err),
      }).toObject(),
    })
  })
  return c.body(null, 204)
},
```

The route still returns 204 (the contract is preserved). The difference is that `BusyError` no longer pollutes the error log — it's a normal control-flow event.

**Note on the typed event:** ideally we'd add a `Session.Event.Busy` event type with a clean payload, but that's a larger surface-area change (schema, listeners, etc.). For now, reuse `Session.Event.Error` with the `BusyError`'s message. If/when downstream listeners need to distinguish busy from real errors, refactor at that point.

**Step 3: Manually verify the change applies cleanly**

This change goes into the existing `prefill-fix.patch`, NOT a new patch. We're modifying that patch by re-deriving it from the upstream tree.

We'll handle the patch regeneration in Task 7.

---

## Task 7: Regenerate the `prefill-fix.patch` and author the new `prompt-admission.patch`

**Files:**
- Modify: `~/projects/opencode-patched/patches/prefill-fix.patch`
- Create: `~/projects/opencode-patched/patches/prompt-admission.patch`
- Modify: `~/projects/opencode-patched/patches/apply.sh`

**Step 1: Apply the existing prefill-fix.patch to a clean v1.14.28 worktree as the baseline**

```bash
cd ~/projects/opencode
git status --short
# Expected: empty
git checkout v1.14.28
# Apply the existing prefill-fix.patch as the baseline
git apply ~/projects/opencode-patched/patches/prefill-fix.patch
```

The worktree now reflects the v1.14.28 + prefill-fix state. This is what the new patch builds on top of.

**Step 2: Apply the prompt_async route catch update on top**

Manually edit `packages/opencode/src/server/routes/instance/session.ts` to apply the catch-clause change from Task 6 Step 2. This is a small in-file edit on top of what prefill-fix already did.

**Step 3: Apply the prompt.ts and run-state.ts changes**

Re-apply the changes from Tasks 3 and 5 to the worktree:
- `packages/opencode/src/session/run-state.ts` — add `tryAdmitPrompt` and `releasePromptAdmission`.
- `packages/opencode/src/session/prompt.ts` — add the admission gate.

**Step 4: Add the test files**

Copy the new test files from Tasks 2 and 4 into the worktree at:
- `packages/opencode/test/session/run-state.test.ts`
- `packages/opencode/test/session/prompt-admission.test.ts`

**Step 5: Generate a single combined diff**

```bash
cd ~/projects/opencode
# Generate the diff of EVERYTHING (both prefill-fix's existing changes
# AND our new admission changes).
git diff > /tmp/combined.patch

# Now split it into two patches.
# We want:
#   prefill-fix.patch: the existing prefill-fix changes ONLY.
#   prompt-admission.patch: the new admission changes ONLY.
```

The cleanest split: temporarily reset, re-apply the OLD prefill-fix.patch alone, regenerate IT alone (verify byte-identical to the existing one), then in a second pass, layer the admission changes on top and diff.

```bash
cd ~/projects/opencode
git checkout -- .
# Reset
git apply ~/projects/opencode-patched/patches/prefill-fix.patch
git diff > /tmp/prefill-fix-regenerated.patch
diff /tmp/prefill-fix-regenerated.patch ~/projects/opencode-patched/patches/prefill-fix.patch
# Expected: minor whitespace/header differences only, OR identical.
```

If the regeneration drifts non-trivially from the original, your worktree state is wrong; investigate.

Then layer the admission changes:

```bash
# (apply admission changes on top of the prefill-fix-applied tree)
# Re-apply the changes from Tasks 3, 5, 6, 2, 4 (run-state.ts, prompt.ts,
# server route, two test files).
git diff > /tmp/all-changes.patch
# Now subtract the prefill changes to isolate admission:
diff /tmp/prefill-fix-regenerated.patch /tmp/all-changes.patch | grep "^>" | sed 's/^> //' > /tmp/prompt-admission-rough.patch
```

In practice, the cleaner path is to MAINTAIN A WORKING TREE of just the admission changes by checking out a fresh tree, applying ONLY prefill-fix, then making changes ONLY for admission, then `git diff` to capture admission alone. This avoids the diff-of-diffs awkwardness:

```bash
cd ~/projects/opencode
git checkout -- .
git checkout v1.14.28
git apply ~/projects/opencode-patched/patches/prefill-fix.patch
# Now make ONLY the admission changes. Verify nothing else is touched.
# ... edit the 5 files ...
git status --short
# Expected: 4 modified + 2 untracked (the 2 test files)
git add -A
git diff HEAD > ~/projects/opencode-patched/patches/prompt-admission.patch
# Verify the patch:
head -20 ~/projects/opencode-patched/patches/prompt-admission.patch
```

**Step 6: Update apply.sh to apply the new patch as #7**

Edit `~/projects/opencode-patched/patches/apply.sh`. Add a 7th patch-apply block after the prefill-fix block (currently #6). Pattern matches the existing blocks: define `PROMPT_ADMISSION_PATCH`, check it exists, run `git apply --check`, on failure print diagnostics, run `git apply`, log success.

```bash
# In apply.sh, after the prefill-fix block:

# --- Patch 7: Prompt admission gate (eliminates orphan user rows when racing) ---

echo "Applying prompt-admission.patch..."
if ! git apply --check "$PROMPT_ADMISSION_PATCH" 2>/dev/null; then
  echo ""
  echo "❌ PROMPT ADMISSION PATCH FAILED TO APPLY"
  echo ""
  echo "Attempting to apply for diagnostics..."
  git apply "$PROMPT_ADMISSION_PATCH" 2>&1 || true
  echo ""
  echo "Failed files:"
  find . -name "*.rej" -type f 2>/dev/null || echo "  None found"
  echo ""
  echo "The prompt admission patch may need updating for this upstream version."
  echo "Refs: workstation/docs/plans/2026-04-27-prompt-async-atomic-admission-plan.md"
  exit 1
fi

git apply "$PROMPT_ADMISSION_PATCH"
echo "✓ Prompt admission patch applied"
```

Also add `PROMPT_ADMISSION_PATCH="$SCRIPT_DIR/prompt-admission.patch"` to the variable definitions at the top, plus the existence check.

**Step 7: Smoke-test the full apply.sh stack on a fresh v1.14.28 clone**

```bash
rm -rf /tmp/admission-smoke
git clone --depth 1 --branch v1.14.28 https://github.com/anomalyco/opencode.git /tmp/admission-smoke
cd /tmp/admission-smoke
~/projects/opencode-patched/patches/apply.sh "$PWD" 2>&1 | tail -20
echo "exit=$?"
```

Expected: All 7 patches apply with the final summary `✓ All patches applied successfully`. Exit 0.

If it fails at the admission patch, your patch authoring has drift; iterate.

**Step 8: Run `bun test` on the smoke checkout to verify the patched tests pass**

```bash
cd /tmp/admission-smoke
bun install --frozen-lockfile 2>&1 | tail -5
bun test packages/opencode/test/session/run-state.test.ts packages/opencode/test/session/prompt-admission.test.ts 2>&1 | tail -20
```

Expected: 6 tests pass (3 from each file).

**Step 9: Cleanup**

```bash
rm -rf /tmp/admission-smoke /tmp/prefill-fix-regenerated.patch /tmp/all-changes.patch /tmp/prompt-admission-rough.patch /tmp/combined.patch
cd ~/projects/opencode
git checkout -- .
find . -name "*.rej" -type f -delete
git status --short  # MUST be clean
```

---

## Task 8: Commit and push opencode-patched

**Files:**
- Modify: `~/projects/opencode-patched/patches/apply.sh`
- Create: `~/projects/opencode-patched/patches/prompt-admission.patch`

**Step 1: Verify staged changes are exactly what's expected**

```bash
cd ~/projects/opencode-patched
git status --short
# Expected:
#   M patches/apply.sh
#   ?? patches/prompt-admission.patch
git diff --stat patches/apply.sh
# Expected: ~20 line additions (the new patch-7 block + variable defs)
wc -l patches/prompt-admission.patch
# Expected: roughly 200-400 lines depending on test verbosity
```

**Step 2: Commit**

```bash
cd ~/projects/opencode-patched
git checkout -b feat/prompt-admission || git checkout feat/prompt-admission  # may already exist from Task 1
git add patches/apply.sh patches/prompt-admission.patch
git commit -m "feat: add prompt admission patch — atomic claim gates user-row write

Adds prompt-admission.patch as patch #7 in the apply.sh stack.

Eliminates the orphan-user-row + permission-leak symptoms that occur
when concurrent prompt_async POSTs race the same session. After the
prefill-fix patch (#6) bound all routes to session.directory, racing
prompts still hit the same Instance — and Runner.ensureRunning's
piggyback semantics (singleflight-style coalescing) silently dropped
the racing prompts AFTER createUserMessage and setPermission had
already written to the DB. Net effect: 4 user rows persisted, 1
assistant turn ran on the FIRST prompt's content, the other 3 user
rows were orphaned, and any tools/permissions in the racing prompts
were applied to the session despite never being acted on by the LLM.

This patch adds tryAdmitPrompt(sessionID) to SessionRunState — an
atomic claim primitive distinct from assertNotBusy, which only
prechecks (TOCTOU race window). SessionPrompt.prompt now gates
createUserMessage + sessions.touch + permission mutation + loop
behind tryAdmitPrompt. On rejection, throws BusyError BEFORE any
durable side effect. The prompt_async route catches BusyError and
logs at info level (not error) since this is expected backpressure,
not a crash.

noReply: true continues to bypass the gate (it's write-only — just
persists a user message, no LLM work) so swarm coordinators that
inject context messages while a session is busy still work.

See workstation/docs/plans/2026-04-27-prompt-async-atomic-admission-plan.md
for the full design rationale, the ChatGPT research that informed
the choice of D-prime over alternatives (queue, leave-as-is, etc.),
and the test coverage strategy."
```

**Step 3: Push and merge**

```bash
git push -u origin feat/prompt-admission

# Open PR, get auto-merge:
gh pr create --title "feat: prompt-admission patch — atomic claim gates user-row write" \
  --body "See commit message + workstation/docs/plans/2026-04-27-prompt-async-atomic-admission-plan.md for design rationale." \
  --label "patch"

# Or just merge to main directly since user is sole consumer:
git checkout main
git merge --ff-only feat/prompt-admission
git push origin main
```

The user is sole consumer of opencode-patched, so direct merge to main is acceptable. Pick whichever workflow matches recent precedent on the repo.

---

## Task 9: Dispatch the v1.14.28-patched rebuild and update workstation hashes

**Files:**
- Modify: `~/projects/workstation/users/dev/home.base.nix` (manually, since auto-update won't fire for same-version)

**Step 1: Dispatch the build**

```bash
gh -R johnnymo87/opencode-patched workflow run build-release.yml --field version=1.14.28
```

This republishes `v1.14.28-patched` with new asset hashes (the binaries now contain the admission gate). The release tag and version string don't change — softprops/action-gh-release@v2 overwrites the existing release.

**Step 2: Watch the run**

```bash
sleep 15
gh -R johnnymo87/opencode-patched run list --limit 1
gh -R johnnymo87/opencode-patched run watch
```

Expected: build succeeds (~3-5 min). The release is updated in place.

**Step 3: Update workstation hashes manually**

The workstation auto-update workflow keys on the version string. Since we're republishing the same `1.14.28` version, the workflow will see "current=1.14.28, latest=1.14.28" → no PR.

We need to update the 4 platform asset hashes by hand. The pattern (from prior auto-PR commits) is to edit `users/dev/home.base.nix` lines containing the SHA256 hashes. Find the relevant section:

```bash
cd ~/projects/workstation
grep -A 10 "platforms = {" users/dev/home.base.nix | head -30
```

For each of the 4 platforms (`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`), compute the new SHA256:

```bash
nix-prefetch-url --type sha256 \
  https://github.com/johnnymo87/opencode-patched/releases/download/v1.14.28-patched/opencode-linux-x64.tar.gz
nix-prefetch-url --type sha256 \
  https://github.com/johnnymo87/opencode-patched/releases/download/v1.14.28-patched/opencode-linux-arm64.tar.gz
nix-prefetch-url --type sha256 \
  https://github.com/johnnymo87/opencode-patched/releases/download/v1.14.28-patched/opencode-darwin-x64.zip
nix-prefetch-url --type sha256 \
  https://github.com/johnnymo87/opencode-patched/releases/download/v1.14.28-patched/opencode-darwin-arm64.zip
```

Replace the four hash strings in `users/dev/home.base.nix` with these new values.

**Step 4: Apply via home-manager**

```bash
nix run home-manager -- switch --flake /home/dev/projects/workstation#cloudbox 2>&1 | tail -10
```

**Step 5: Verify the new binary**

```bash
~/.nix-profile/bin/opencode --version
# Expected: 1.14.28 (same string, but binary content changed)
```

To prove the patch is in:

```bash
~/.nix-profile/bin/opencode --version
# strings/grep on the binary won't help (it's a Bun bundle), but:
# if you can trigger a busy-rejection in a test, the log message
# "prompt_async rejected (session busy)" should appear.
```

---

## Task 10: Restart `opencode serve` and verify admission behavior in production

**Files:** None modified. This is verification-only.

**Step 1: Restart serve**

The currently-running `opencode serve` (which is hosting the executing session) is the OLD binary. Killing it triggers TUI auto-respawn into the NEW binary (verified in prior session).

```bash
SERVE_PID=$(pgrep -fa "opencode serve --port 4096" | head -1 | awk '{print $1}')
echo "killing serve PID $SERVE_PID"
kill "$SERVE_PID"
sleep 2
pgrep -fa "opencode serve --port 4096" | head -1
# Expected: a NEW PID, listening on :4096, exe pointing to the new opencode-patched-1.14.28 nix store path
NEW_PID=$(pgrep -fa "opencode serve --port 4096" | head -1 | awk '{print $1}')
ls -la /proc/$NEW_PID/exe
```

**Step 2: Verify the new binary is in service**

```bash
for i in $(seq 1 20); do
  curl -sf -m 2 "http://127.0.0.1:4096/openapi.json" -o /dev/null && echo "serve-up after ${i}s" && break
  sleep 1
done
```

**Step 3: Re-run the prefill repro and verify behavior**

The existing repro (4 concurrent prompt_async POSTs from 4 distinct cwds) should now produce DIFFERENT message-DB output than the post-prefill-fix-only behavior:

```
PRE-admission (current shipped state):
  4 user rows + 1 assistant row + zero errors
  (3 user rows are orphaned)

POST-admission (this plan's outcome):
  1 user row + 1 assistant row + zero errors
  (the 3 racing prompts threw BusyError before writing user rows, server log shows
   3 "prompt_async rejected (session busy)" info-level entries)
```

Run the repro per `~/projects/workstation/.plans/2026-04-27-task2-prefill-fix.md` lines 56-79. Save output to `/tmp/repro-after-admission.txt`.

**Step 4: Diff against the prior repro**

```bash
diff /tmp/repro-after-fix.txt /tmp/repro-after-admission.txt
```

Expected differences: 4 → 1 user rows. Same 1 assistant row.

```bash
# Also check serve logs for the new info-level rejections:
LATEST_LOG=$(ls -t ~/.local/share/opencode/log/*.log | head -1)
grep "prompt_async rejected" "$LATEST_LOG" | tail -5
# Expected: 3 entries from the test run
```

**Step 5: If verification fails**

If still 4 user rows in the post-admission output: the patch isn't in the binary. Confirm by checking the build's CI log shows `✓ Prompt admission patch applied`.

If user rows are 1 but the 3 rejections aren't in the log: the catch clause in the route isn't recognizing `BusyError`. Verify Task 6's edit landed in the patch.

---

## Task 11: Final landing — handoff doc + commit + push

**Files:**
- Modify: `~/projects/workstation/.plans/2026-04-27-task2-handoff.md`
- Modify: `~/projects/workstation/users/dev/home.base.nix` (already modified in Task 9)

**Step 1: Edit the handoff doc**

Update the existing RESOLVED section to reflect that the candidate follow-up has now shipped. Add a paragraph noting:
- This plan was executed (link to `docs/plans/2026-04-27-prompt-async-atomic-admission-plan.md`).
- Net effect: orphan user rows on race are now eliminated (1 user row + 1 assistant row, was 4 + 1).
- The "candidate follow-up" paragraph in the handoff can be deleted or marked [DONE].

**Step 2: Commit and push workstation**

```bash
cd ~/projects/workstation
git add .plans/2026-04-27-task2-handoff.md users/dev/home.base.nix
git status --short
# Expected: 2 files modified, no others.
git commit -m "feat(opencode-patched): ship prompt-admission patch (eliminates orphan user rows)

Updates home.base.nix with new SHA256 hashes for opencode-patched
v1.14.28-patched (republished with the prompt-admission patch
applied — see opencode-patched commit <SHA>).

Updates .plans/2026-04-27-task2-handoff.md to mark the candidate
follow-up as DONE; pre-existing 4-user-rows-on-race symptom is
now fully resolved.

See docs/plans/2026-04-27-prompt-async-atomic-admission-plan.md
for the full implementation plan."
git pull --rebase
git push
git status  # MUST show "up to date with origin"
```

---

## Out of scope

- **True queueing (Option B from the ChatGPT analysis).** This is the "later, only if pigeon needs same-session batching" deferral. Build the bounded FIFO when there's a real workflow that needs it — don't speculate now.
- **Adding a typed `Session.Event.Busy` event.** For now we reuse `Session.Event.Error` with a message that contains "is busy". If/when downstream listeners need to distinguish busy from real crashes for routing (e.g., suppressing busy in error UIs), refactor at that time.
- **Upstreaming to anomalyco/opencode.** This patch is reasonable to file as a PR upstream. Out of scope for this work but worth a follow-up issue.
- **Refactoring `Runner.ensureRunning`.** ChatGPT's analysis identified that the singleflight semantic is poorly-fitting for prompt-style work but appropriate for genuinely-idempotent work. We're working around it at the `SessionPrompt.prompt` layer. The generic `Runner` stays as-is.
- **The TUI's behavior when prompt_async is rejected.** Today the TUI doesn't fire concurrent prompts to the same session, so it won't observe the new info-level log lines. If a future TUI feature does (e.g., "send" while a prior send is still streaming), we'll want to surface the rejection visibly. Not today.

## Risk and rollback

- **Patch fails to apply on a future upstream version.** Same risk as every other patch in the stack. Mitigation: this patch touches 2 src files (`run-state.ts`, `prompt.ts`) and 1 server route file (`session.ts`) plus 2 test files. Drift on `prompt.ts` and `session.ts` is most likely. Re-port using `git apply -3 --index` (3-way merge).
- **The admission gate breaks an existing test or workflow we didn't anticipate.** Run the FULL bun test suite in Task 5 Step 5 before authoring the patch. If a test fails, the patch is wrong; iterate.
- **`noReply: true` semantics turn out to be subtly different from what we coded.** Reading prompt.ts carefully: `noReply` short-circuits AFTER `createUserMessage` and `sessions.touch`, but SKIPS the loop. Our patch preserves that. If somewhere else in the codebase relies on `noReply` going through the runner, that's a regression. Search the codebase: `grep -rn "noReply" packages/opencode/src` — should find `prompt.ts` only. If others, audit.
- **Rollback:** revert the opencode-patched commit, re-dispatch v1.14.28-patched build, update workstation hashes back. Same procedure as Task 9 in reverse.

## Why this plan exists (for future Claude)

The prefill-fix patch (already shipped in v1.14.28-patched) eliminated the most acute symptom of concurrent same-session prompts: prefill 400 errors and assistant rows in the wrong cwd. But it left a residual issue: when racing prompts all bind to the same Instance (as they should, post-fix), `Runner.ensureRunning` silently coalesces them, so the racing prompts' user rows are persisted but never answered by the LLM. ChatGPT's research (`/tmp/research-prompt-async-queue-vs-piggyback-answer.md`) confirmed this is a correctness bug rather than an acceptable design point — particularly because the racing prompts can also mutate session permissions silently.

This plan implements "Option D-prime" from that research: atomic admission gating BEFORE any durable side effect. The naive "Option D" (precheck via `assertNotBusy` then create the user message) was rejected because of a TOCTOU race window between the precheck and the runner state transition.
