Recommendation

I would not keep the current pure piggyback behavior as the intended semantic for distinct prompt bodies.

Given your constraints, my recommendation is:

Immediate fix: implement D’ = early busy/admission rejection before any user-row write, with warning logs and a Session.Event.Error, while preserving the external 204 contract.

Do not rely on the existing Runner.ensureRunning piggyback for prompts. It is request coalescing by sessionID, but your requests are not duplicates.

Add true bounded queueing later only when you actually need same-session programmatic batching. When you do, use an in-memory bounded FIFO queue per session, not unbounded queueing.

The most important correction: plain D as written may not be sufficient if the first request does not mark the session busy until after createUserMessage. To prevent orphan rows reliably, the “busy/admitted” state must be claimed atomically before persistence.

1. What is the current piggyback semantic?

Yes, the pattern is established, but under a different assumption. It is usually called request coalescing, singleflight, or duplicate suppression. Go’s singleflight, for example, ensures only one in-flight execution per key; duplicate callers wait and receive the same result. 
Go Packages
+1

That pattern is appropriate when the key fully represents the work, for example:

getSessionSummary(sessionID)
loadConfig(directory)
refreshAuthToken(accountID)
fetchModelList()

It is not appropriate when the key omits semantically distinct payloads:

prompt(sessionID, "A")
prompt(sessionID, "B")
prompt(sessionID, "C")

Your current key is effectively:

sessionID is running

But the real unit of work is closer to:

(sessionID, user-message payload, tools/permissions, noReply, model settings, etc.)

So the runner is coalescing things that are not duplicates. In Effect terms, the use of Deferred.await(st.run.done) is a normal fiber-friendly way to let multiple fibers await one result; Deferred is explicitly a one-time asynchronous variable that suspends awaiting fibers without blocking threads. 
Effect
 The issue is not the primitive. The issue is that the coalescing key is too coarse for prompts.

My read: Runner.ensureRunning is probably a reasonable generic “ensure the loop is running” primitive, but it is a poor admission controller for distinct prompt submissions.

2. What do other tools/APIs tend to do?

There is no universal industry standard for “concurrent prompt to same agent session,” but the common answers are reject, lock, serialize, or expose a separate run object. I would not treat silent coalescing of distinct prompt bodies as normal.

OpenAI’s Assistants API is a useful comparison: while a run is in a non-terminal state, the thread is locked; new messages cannot be added and new runs cannot be created on that thread. 
OpenAI Developers
 That is closer to busy reject / caller retries later than to coalescing.

OpenAI’s newer background-mode pattern creates an explicit asynchronous response object and lets the caller retrieve status/results later. 
OpenAI Developers
 That is closer to accepted job semantics, not “204 and maybe your distinct payload was folded into another run.”

Aider’s documented CLI flows are also not an async multi-prompt local-server model: --message sends one message, processes the reply, applies edits, and exits. 
Aider
+1
 Claude/Anthropic agent-style SDK docs describe resumable sessions and agent loops, but I do not see a public guarantee that concurrent same-session prompt submissions are coalesced safely. 
Claude API Docs

So the practical precedent is: same conversation/thread is a serialized resource. The caller either waits, gets rejected, or submits to an explicit queue/run abstraction. Silent distinct-payload coalescing is the surprising one.

3. Is 204 fire-and-forget + silent coalescing acceptable?

For an internal single-user API, it is operationally tolerable if documented and instrumented, but semantically it is weak.

204 says the request succeeded and has no response body. For async work, HTTP usually models this with 202 Accepted, which is intentionally noncommittal: the request has been accepted for processing, but processing may not be complete and may not ultimately be acted upon. 
RFC Editor
+1
 You cannot change the route contract, so you are stuck with 204, but that makes silent coalescing more surprising, not less.

The downstream surprise is simple:

POST prompt_async("clarify A") -> 204
POST prompt_async("clarify B") -> 204
POST prompt_async("clarify C") -> 204

A reasonable caller will infer:

All three prompt submissions were accepted.

Current behavior is closer to:

A was accepted.
B and C were partially side-effected, then their run work was discarded.

That is a dangerous semantic gap, especially for a programmatic daemon.

4. Effect-TS patterns for B and D
For B: bounded in-memory queue

Effect has a built-in Queue abstraction with offer and take; take retrieves the oldest value and suspends if the queue is empty. 
Effect
 It also has bounded, dropping, sliding, and unbounded queue variants. Bounded queues apply backpressure; dropping queues discard new values at capacity; sliding queues drop old values; unbounded queues have no capacity limit. 
Effect

The canonical shape is a per-session actor/mailbox:

TypeScript
type PromptJob = {
  input: PromptInput
  done: Deferred.Deferred<MessageV2.WithParts, PromptError>
}

const submitPrompt = Effect.fn("submitPrompt")(function* (input: PromptInput) {
  const done = yield* Deferred.make<MessageV2.WithParts, PromptError>()

  const offered = yield* Queue.offer(queue, { input, done })

  if (!offered) {
    return yield* Effect.fail(new QueueFullError({ sessionID: input.sessionID }))
  }

  yield* ensureWorkerRunning(input.sessionID)

  return yield* Deferred.await(done)
})

Worker shape:

TypeScript
const worker = Effect.forever(
  Queue.take(queue).pipe(
    Effect.flatMap((job) =>
      runOnePromptTurn(job.input).pipe(
        Effect.exit,
        Effect.flatMap((exit) => Deferred.done(job.done, exit)),
      ),
    ),
  ),
)

For your route, the returned value is still discarded because prompt_async returns 204, but the Deferred remains useful for tests, sync routes, logs, and internal correctness.

Important queue guidance:

Use bounded FIFO, not unbounded.

Do not use request coalescing for distinct prompts.

If full, reject/drop before createUserMessage.

Do not make abort wait behind prompt jobs. Abort/cancel should stay control-plane and preemptive.

Be careful with shell/init/permission paths. I would not initially force all commands through the prompt queue unless you audit their semantics.

For D: early busy rejection

Effect’s error channel is the right place for this. Effect models expected failures in the Effect<Success, Error, Requirements> type, and typed/tagged errors can be handled with patterns such as catchTag. 
Effect

Conceptually:

TypeScript
class BusyError extends Data.TaggedError("BusyError")<{
  sessionID: string
}> {}

const prompt = Effect.fn("SessionPrompt.prompt")(function* (input) {
  const admitted = yield* state.tryAdmitPrompt(input.sessionID)

  if (!admitted) {
    return yield* Effect.fail(new BusyError({ sessionID: input.sessionID }))
  }

  return yield* runAdmittedPrompt(input).pipe(
    Effect.ensuring(state.releasePrompt(input.sessionID)),
  )
})

But this is the crucial bit: tryAdmitPrompt must atomically claim the session before createUserMessage.

A naive implementation like this is not enough:

TypeScript
yield* assertNotBusy(sessionID)
const message = yield* createUserMessage(input)
return yield* loop(...)

Why? Because in your current flow the first prompt may not set runner state to Running until after createUserMessage, sessions.touch, permission updates, etc. A second prompt can slip through the precheck before the first has entered ensureRunning.

So the safer minimal fix is not just D. It is:

D’ = atomically admit/reject prompt before any durable side effect.

You can implement that with the existing SynchronizedRef style. SynchronizedRef is designed for effectful, sequential updates to shared state in concurrent environments. 
Effect

5. The failure mode to worry about most

The biggest failure is silent semantic loss of distinct prompt content.

The orphaned rows are not merely cosmetic. They are evidence that the system accepted durable side effects for prompts that did not receive corresponding assistant turns. The likely downstream risks are:

Future context pollution: if the next run builds context from SQLite history, those orphaned user messages may enter a later LLM call mixed with unrelated user intent.

Misleading transcript: the UI/database says the user said four things, but the assistant answered one.

Side-effect leakage: your prompt path mutates permissions before the runner is consulted. A piggybacked prompt with different tools can still alter session permissions even though its prompt body is not actually run.

Debugging ambiguity: logs show success-ish 204s, no Anthropic error, and a transcript that looks plausible until someone notices missing assistant turns.

Unbounded queueing is also a real risk, but it is easier to control with a queue cap. Silent loss plus durable transcript mutation is the more correctness-threatening failure.

6. Option assessment
Option	My take
A. Leave as-is	Defensible only as a temporary “we know current callers do not race” position. Add warning logs immediately if you choose this. But I would not document piggyback as the intended prompt semantic.
B. True queueing	Correct if future pigeon workflows intentionally batch same-session prompts. Use bounded FIFO. Queue full should produce a logged/domain error before DB write. Avoid unbounded queues.
C. Route-layer 409	Clean HTTP semantics, but violates your hard 204 constraint. Could be used for a new strict endpoint, not this one.
D. Early reject before user message	Best near-term choice, but only if implemented as atomic admission before persistence. A simple assertNotBusy precheck may still race.
E. Move createUserMessage into scheduled work	Semantically attractive because persistence aligns with actual execution. But it is a larger refactor: noReply, permissions, revert.cleanup, sessions.touch, and assumptions inside runLoop need careful audit.
F. Something else	Add an explicit batch endpoint or caller-side pigeon queue. If the daemon wants to send three clarifications, it may be better to combine them into one user message intentionally rather than rely on transport-level races.
My concrete recommendation
Now

Implement D’:

prompt_async still returns 204.
Background effect attempts to atomically admit a prompt turn.
If admitted:
  create user message
  apply prompt-local side effects
  run loop
If busy:
  do not create user message
  log warn
  publish Session.Event.Error BusyError

Add tests for:

4 concurrent prompt_async requests
=> 1 admitted prompt
=> 1 user row
=> 1 assistant row
=> 3 BusyError logs/events
=> no orphan user rows

Also test the race window specifically: make createUserMessage artificially slow and verify that only one request can pass admission.

Later, only if needed

If pigeon needs same-session batching, implement B as bounded per-session FIFO:

4 concurrent prompt_async requests
=> 4 queued jobs
=> 4 user rows
=> 4 sequential assistant turns

Use a small cap first, for example 8 or 16. If full, fail the background job with QueueFullError before persistence and publish/log it. Since the HTTP caller still receives 204, logs/events are your only visibility unless you add a separate job-status mechanism.

What I would not do

I would not leave the current semantics as “documented piggyback” for prompts. Piggyback is valid for duplicate work. These are not duplicates. The current behavior is effectively over-coalescing by session, and the orphan rows make that visible.