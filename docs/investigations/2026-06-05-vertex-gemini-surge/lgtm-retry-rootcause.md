# lgtm / OpenCode retry amplification — root cause

Investigation date: 2026-06-05. Author: worker session `ses_1671e4e42ffeae5UKWFHuB1ZjR`
(opus, `~/projects/lgtm`). Companion docs in this dir: `HANDOFF.md`,
`overnight-surge-forensics.md`, `opencode-ancillary-calls-report.md`.

Read-only investigation. No code modified, no services restarted.

---

## TL;DR

The ~35× amplification of **successful** gemini-3.5-flash Vertex calls is caused by
**OpenCode core's per-step LLM retry policy, which is UNCAPPED in attempt count**.

- The amplifier is **not** an "application-level retry-rescheduler" and **not** in
  pigeon or lgtm. It is in the OpenCode binary itself.
- `Effect.retry(SessionRetry.policy(...))` wraps the **entire** model-stream effect
  for a single step and retries it **forever** (only stopping when the error stops
  classifying as "retryable"), with backoff capped at **30 s**.
  - Root cause: `packages/opencode/src/session/retry.ts:175-198` (`policy()` — no
    `Schedule.recurs`/max-attempts) applied at
    `packages/opencode/src/session/processor.ts:810-840`.
- Each retry **re-issues a brand-new Vertex streaming request** (counted by Vertex as
  status OK), but the assistant message — the thing the OpenCode DB records as a
  "step-start" — is created **once per step** (`prompt.ts:1347-1362`). So one DB step
  maps to many successful Vertex calls. That is the 35×.
- The Telegram `"🤖 Retry … Next attempt at …"` message is a **notifier**, not a
  scheduler: pigeon's opencode-plugin forwards OpenCode's `session.status{type:"retry"}`
  event verbatim (`pigeon/packages/opencode-plugin/src/index.ts:604-633`).

**Correction to the prior HANDOFF theory (lines 29-34):** a retry does *not* re-run
the whole session or "re-execute all prior gemini steps." It re-runs the *single
failing step's* stream, uncapped. The hypothesis is right in spirit (a retry re-does
work that then succeeds, inflating successful-call counts) but wrong in mechanism and
location (it's OpenCode-core per-step stream retry, not an app-level session re-runner).

**Top 2 fixes:** (1) cap the retry attempts in `retry.ts:180` (smallest change that
stops a runaway); (2) shrink the gemini blast radius / move it off the constrained
`google-vertex` quota (gemini is the default model + gather + both reviewer subagents +
compaction, all on one quota; opus is on a separate quota and reconciled 1:1).

---

## 1. Where the "🤖 Retry … Next attempt at …" message comes from

The Telegram text is emitted by pigeon's OpenCode plugin, in the `session.status`
event handler:

`pigeon/packages/opencode-plugin/src/index.ts:604-633`
```ts
if (eventType === "session.status") {
  const status = props?.status as { type?: string; attempt?: number; message?: string; next?: number } | undefined
  if (!sessionID || !status || status.type !== "retry") return
  ...
  const retryMsg = `Retry #${status.attempt ?? "?"}: ${status.message ?? "unknown error"}`
  const nextAt = status.next ? new Date(status.next).toLocaleTimeString() : "unknown"
  notifyStop({ sessionId: sessionID, event: "Retry",
    message: `${retryMsg}\nNext attempt at ${nextAt}`, ... })
}
```

This is purely a **notifier**. `status.attempt`, `status.message`, and `status.next`
are fields of a `session.status` event that OpenCode core publishes; pigeon does not
generate, schedule, or perform the retry. Note also this branch has **no dedup guard**
(unlike the `session.idle`/`session.error` branches which gate on
`sessionManager.shouldNotify`), so every retry attempt produces its own Telegram
message — a stuck step retrying every 30 s for hours floods Telegram. The single
`"Retry #1"` the human saw is one sample from that stream.

### Pigeon's own retries are message-delivery only, and capped

Pigeon's daemon does have retry machinery, but it retries **delivery of swarm /
Telegram messages**, never LLM work, and it is **capped at 10 attempts** with backoff:

`pigeon/packages/daemon/src/swarm/arbiter.ts:14-21,102-127`
```ts
const MAX_ATTEMPTS = 10;
const BACKOFF_SCHEDULE = [1_000, 2_000, 5_000, 15_000, 60_000];
...
await this.opencodeClient.sendPrompt(target, directory, prompt);
this.storage.swarm.markHandedOff(next.msgId, this.nowFn());   // success → never redeliver
...
} catch (err) {
  ... if (attempts >= MAX_ATTEMPTS) markFailed(...) else markRetry(..., backoffFor(attempts));
}
```

On success it marks the message handed-off and stops; it only retries on *delivery
failure* (the prompt never reached the model → no gemini calls). The outbox sender
(`pigeon/packages/daemon/src/worker/outbox-sender.ts`) is the same shape. **Pigeon is
conclusively ruled out as the amplifier.**

---

## 2. The actual retry: what it does, exactly

### 2a. It wraps the *whole stream* of a *single step* and retries it

`packages/opencode/src/session/processor.ts:780-843` (the per-step `process()`):
```ts
yield* Effect.gen(function* () {
  ctx.currentText = undefined           // <- discards any partial output on each attempt
  ctx.reasoningMap = {}
  yield* status.set(ctx.sessionID, { type: "busy" })
  const stream = llm.stream(streamInput) // <- a FRESH Vertex streaming request each attempt
  yield* stream.pipe(Stream.tap((e) => handleEvent(e)), Stream.takeUntil(...), Stream.runDrain)
}).pipe(
  Effect.onInterrupt(...),
  Effect.catchCauseIf(...),
  Effect.retry(                          // <- retries the ENTIRE effect above
    SessionRetry.policy({
      provider: input.model.providerID,
      parse,
      set: (info) => /* publish session.status {type:"retry", attempt, message, next} */,
    }),
  ),
  Effect.catch(halt),
  Effect.ensuring(cleanup()),
)
```

Key consequences:
- A retry re-invokes `llm.stream(streamInput)` — i.e. **a complete new request to
  Vertex** with the same message history. It is **not** a resume; partial output is
  thrown away (`ctx.currentText = undefined`, line 787).
- It re-runs **only the current step**, not the prior steps. (So "re-executing all
  prior gemini steps" is not what happens.)

### 2b. The retry policy has NO attempt cap

`packages/opencode/src/session/retry.ts:175-198`:
```ts
export function policy(opts: {...}) {
  return Schedule.fromStepWithMetadata(
    Effect.succeed((meta) => {
      const error = opts.parse(meta.input)
      const retry = retryable(error, opts.provider)
      if (!retry) return Cause.done(meta.attempt)          // <- ONLY termination condition
      return Effect.gen(function* () {
        const wait = delay(meta.attempt, ...)
        const now = yield* Clock.currentTimeMillis
        yield* opts.set({ attempt: meta.attempt, message: retry.message, action: retry.action, next: now + wait })
        return [meta.attempt, Duration.millis(wait)]
      })
    }),
  )
}
```

There is **no `Schedule.recurs(N)`**, no `Schedule.intersect` with a max-count, no
attempt ceiling. The schedule terminates **only** when `retryable()` returns
`undefined` (the error is no longer classified retryable). For a persistently
retryable condition (a flapping stream, a recurring "overloaded"/"exhausted"/network
error), it loops **indefinitely**.

Confirmed by the unit test of the *delay* curve — backoff caps at 30 s without a
`retry-after` header, and keeps firing:

`packages/opencode/test/session/retry.test.ts:35-39`
```ts
const delays = Array.from({ length: 10 }, (_, i) => SessionRetry.delay(i + 1, error))
expect(delays).toStrictEqual([2000, 4000, 8000, 16000, 30000, 30000, 30000, 30000, 30000, 30000])
```

`retry.ts:25-65` (`delay()`): exponential `2000·2^(n-1)` capped at
`RETRY_MAX_DELAY_NO_HEADERS = 30_000` ms when no header; honors `retry-after[-ms]`
otherwise (up to a 32-bit-ms ceiling, ~24 days). So a step stuck on a header-less
retryable error retries **every 30 s, forever**.

### 2c. What counts as "retryable" (the trigger surface is broad)

`packages/opencode/src/session/retry.ts:67-151` (`retryable()`):
- 5xx server errors — **always**, even when `isRetryable` is false
  (`retry.ts:74`; broadened by upstream commit `4ca809ef4` "retry 5xx server errors
  even when isRetryable is unset", #22511).
- `"Overloaded"` / provider-overloaded (`retry.ts:121`).
- JSON error `code` containing `"exhausted"` or `"unavailable"` →
  `"Provider is overloaded"` (`retry.ts:144`). **This is the 429/RESOURCE_EXHAUSTED
  path** — confirmed by test `retry.test.ts:127-130`
  (`{ code: "resource_exhausted" }` → retryable).
- Plain-text "rate limit" / "too many requests" / "rate increased too quickly"
  (`retry.ts:126-135`).
- Transport faults: ECONNRESET, header timeouts, ZlibError (tests
  `retry.test.ts:167-173,233-245,377-389`).

Context-overflow errors are explicitly *not* retried (`retry.ts:69`), and 4xx with
`isRetryable=false` are *not* retried (`retry.test.ts:221-231`) — so a malformed
request (e.g. the gemini-empty-parts 400) does **not** loop.

### 2d. No idempotency / no guard against re-running completed work

There is no dedup or "already produced output" guard. On each attempt the step starts
its stream from scratch (`ctx.currentText = undefined`, `processor.ts:787`). The
assistant message object is reused (`processor.ts:111`, `ctx.assistantMessage =
input.assistantMessage`), but the model is re-called in full.

---

## 3. Why this produces ~35× SUCCESSFUL calls with ~flat DB step counts

### 3a. The accounting: one DB "step-start" = one assistant message

The step loop creates exactly one assistant message per step and writes it to the DB
**once**, before calling the processor:

`packages/opencode/src/session/prompt.ts:1252` — `while (true) { ... }` (the step loop)
`packages/opencode/src/session/prompt.ts:1347-1362`:
```ts
const msg: MessageV2.Assistant = { id: MessageID.ascending(), role: "assistant", ... time: { created: Date.now() }, sessionID }
yield* sessions.updateMessage(msg)        // <- THIS is the DB "step-start"
...
const handle = yield* processor.create({ assistantMessage: msg, sessionID, model })
...
const result = yield* handle.process({ ... })  // <- inside here: uncapped Effect.retry of llm.stream
```

So:
- **DB gemini step-starts** = number of assistant messages created ≈ **2,033** (the
  measured figure).
- **Successful Vertex gemini calls** = number of `llm.stream()` invocations =
  Σ over steps of (1 + retry_attempts) ≈ **72,500** (the measured figure).
- Ratio 72,500 / 2,033 ≈ **35.7×** = the average number of Vertex requests issued per
  DB step. The excess is concentrated in the minority of steps that got stuck and
  retried tens-to-thousands of times.

Order-of-magnitude sanity check: the window is 2026-06-04 15:00 → 06-05 07:00 UTC
(16 h = 57,600 s). A single stuck step retrying every 30 s burns ~1,920 successful
Vertex calls (more early on, when delays are 2/4/8/16 s). ~70,000 excess calls ≈ a few
dozen stuck step-instances across the night — entirely plausible given lgtm dispatches
gemini work every 10 minutes (see §4).

### 3b. Why the amplified calls are SUCCESSFUL (status OK), not RESOURCE_EXHAUSTED

This is the crux that the earlier "quota retry storm" theory got wrong (only ~7 hard
429s were logged). `Effect.retry` only fires when the **client** observes a failure.
The amplifying failures are ones where **Vertex logs the HTTP/gRPC call as OK** but the
client still sees a retryable error:

1. **In-band / mid-stream errors under HTTP 200.** Gemini/Vertex streaming opens the
   response with 200 OK (Vertex's audit row = status OK), then emits an error event
   in the SSE body partway through (server_error, overloaded, or a streamed
   `resource_exhausted`). The AI SDK surfaces this as a mid-stream error;
   `retryable()` classifies it (`retry.ts:121,144`) → full stream re-issued → another
   200-logged call → repeat.
2. **Connection drops / header timeouts** (ECONNRESET, header-timeout) after the
   request has started — also retryable (`retry.test.ts:167-173,377-389`), also leaves
   a started/200 request in Vertex's log.
3. **Post-stream / finish-step throws classified retryable.** The active
   `tool-fix.patch` in `opencode-patched` exists specifically because "the finish-step
   handler in processor.ts throws during a retryable error" — i.e. a step whose
   underlying Vertex call **succeeded** can still throw in post-processing and be
   retried, re-issuing the whole (successful) stream.

All three fit every datum: many status-OK Vertex calls, ~zero RESOURCE_EXHAUSTED (the
audit log only counts the rare *pre-stream* 429s as RESOURCE_EXHAUSTED), and a flat DB
step count.

**Residual uncertainty (kept honest):** I did not capture the actual error payloads
from that night, so I cannot say *which* of the three trigger conditions dominated.
The exact error string is what the companion "durable LLM-audit log capture" work item
(HANDOFF worker 2) is being built to record. This does **not** affect the root cause or
the fix: regardless of trigger, the defect is that the retry is **uncapped and wraps a
full Vertex call**, so any persistently-retryable condition inflates successful calls
without bound.

### 3c. Why opus reconciles 1:1

opus runs on `google-vertex-anthropic` (`dispatch.ts:11`,
`google-vertex-anthropic/claude-opus-4-8@default`) — a different gateway/quota than
gemini's `google-vertex`. It is far less likely to hit the overloaded/exhausted/flap
conditions that trip the retry loop, so its steps mostly run once → DB messages ≈
Vertex calls. The retry *code path* is identical for opus; it simply rarely *fires*.

### 3d. Verified in the deployed binary (not just source)

The running server is `opencode-patched-1.15.13.2`
(`/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2/bin`). Grepping
the built artifact:
- contains `RETRY_MAX_DELAY_NO_HEADERS` and `fromStepWithMetadata` (the uncapped
  policy), and
- contains **zero** `Schedule.recurs` occurrences.
- The `opencode-patched` patch stack (`cache-aligned-compaction`, `tool-fix`,
  `gemini-empty-parts`, etc.) does **not** modify the retry policy.

`git log` of `retry.ts` / `processor.ts` and `git log -S "Schedule.recurs"` over
`session/` show **no attempt cap was ever present** — the uncapped behavior is the
upstream design, relying solely on `retryable()` eventually returning `undefined`. So
this is not a fork regression; it is an inherited upstream defect that the gemini quota
pressure exposes.

---

## 4. lgtm's role: work source + gemini blast radius + leaky stop-gap

lgtm does not contain the retry, but it is the **engine** that keeps minting the gemini
work that the uncapped retry then amplifies, and its own safety net is leaky.

### 4a. Gemini is everywhere; all on one constrained quota

- gather model: `google-vertex/gemini-3.5-flash` (`lgtm/src/gather.ts:10`).
- review model: opus (`lgtm/src/dispatch.ts:11`) — but opus reviews **fan out** gemini
  subagents:
  - `code-reviewer` → `model: google-vertex/gemini-3.5-flash`
    (`~/.config/opencode/agents/code-reviewer.md`).
  - `spec-reviewer` → `model: google-vertex/gemini-3.5-flash`
    (`~/.config/opencode/agents/spec-reviewer.md`).
- OpenCode **global default model**: `google-vertex/gemini-3.5-flash`
  (`~/.config/opencode/opencode.json:154`).
- **compaction** agent model: `google-vertex/gemini-3.5-flash`
  (`~/.config/opencode/opencode.json:8`).

Every one of these shares the single `google-vertex` quota. Gather runs by default
(`lgtm/src/index.ts:98`, `LGTM_ENABLE_GATHER !== "false"`). lgtm runs **every 10
minutes** (systemd `lgtm-run.timer`). So all night long lgtm produced a steady stream
of gemini steps (gather sessions + reviewer subagents + their compactions) against a
quota tight enough to trigger overloaded/exhausted/flap conditions — each of which the
uncapped retry turns into a burst of successful calls.

### 4b. gather.ts timeout→DELETE is the only lgtm stop-gap, and it leaks

`lgtm/src/gather.ts:172-215` (esp. **199-210**):
```ts
const done = await waitForSentinel(join(worktreeDir, GATHER_SENTINEL_FILENAME), { timeoutMs, intervalMs });
if (done) return "ran";

// Timed out: best-effort kill of the stray session so it isn't left
// burning tokens after we've moved on to the review.
if (parsed?.sessionId) {                         // (1) guard: only if we parsed an id
  await fetch(`${OPENCODE_URL}/session/${parsed.sessionId}`, {
    method: "DELETE", signal: AbortSignal.timeout(5_000),
  }).catch((err) => { log(... "failed to kill stray gather session" ...) }); // (2) swallowed
}
return "timeout";
```

Default `GATHER_TIMEOUT_MS = 120_000` (`gather.ts:154-159`). Problems:

1. **Orphan on unparsed launch output.** The DELETE only fires `if (parsed?.sessionId)`.
   When `opencode-launch` stdout doesn't parse (`gather.ts:188-191` logs a warning and
   returns no id), the stuck gemini gather session is **never killed** and keeps
   retrying uncapped indefinitely — exactly the "burning tokens" the comment fears.
2. **Best-effort, error-swallowed DELETE.** 5 s timeout, `.catch` swallow; if it
   fails/times out, nothing retries it.
3. **120 s window vs 30 s uncapped backoff.** Even when DELETE works, a stuck step
   already burned ~4-8 Vertex calls before the 120 s timeout; an orphaned one burns
   ~2/min for hours.
4. **Subagents are uncovered.** This stop-gap only protects *gather* sessions. The
   gemini `code-reviewer`/`spec-reviewer` subagents live inside opus review sessions;
   lgtm does not own or time-bound their lifecycle, so a stuck gemini subagent step
   retries uncapped until its parent opus session finishes or is killed.

DELETE *can* abort a running generation when it lands: `DELETE /session/:id` →
`Session.remove` → `cancelBackgroundJobs` interrupts the running job
(`opencode/.../session/session.ts:595-616,874-889`). But that only helps for the gather
case, only when the id was parsed, and only if the call succeeds.

### 4c. lgtm's re-awaken is gated — not a runaway

For completeness: lgtm's tier-0 re-awaken (`dispatch.ts:157-191` →
pigeon `/swarm/send`) re-prompts an existing session only on **head-changed** or
**review-rerequested** (`discover.ts:1245-1302`, `bucketRereviewCandidate`). It is not
triggered by 429s and does not loop. It can add gemini work (a re-review fans out
subagents again), but it is bounded by actual PR state changes and is **not** the
amplifier.

---

## 5. Recommended fixes (smallest-first)

### Fix 1 — Cap the per-step retry attempts (stops the runaway; smallest change)
**Where:** `opencode/packages/opencode/src/session/retry.ts:175-198` (and/or the
application site `processor.ts:810`). Since the deployed server is
`opencode-patched`, ship this as a new patch in
`~/projects/opencode-patched/patches/` (none of the existing patches touch retry).

Convert the unbounded schedule into a bounded one, e.g. stop after N attempts:
```ts
// inside policy()'s step fn:
if (!retry || meta.attempt > MAX_RETRIES) return Cause.done(meta.attempt)
```
or compose a ceiling: `SessionRetry.policy(...)` ⨯ `Schedule.recurs(MAX_RETRIES)` at
`processor.ts:810`. A cap of ~5-8 turns an unbounded 30 s-interval loop into a bounded
burst and eliminates the 35×. This is the single change that prevents recurrence.

**Also add jitter** to `delay()` (`retry.ts:60,64`) so concurrent stuck sessions don't
synchronize their 30 s re-issues (thundering herd against the same quota).

### Fix 2 — Shrink / relocate the gemini blast radius (config-only, no code)
Gemini is the default model + gather + both reviewer subagents + compaction, all on the
constrained `google-vertex` quota. Either:
- raise the `google-vertex` gemini-3.5-flash quota for this principal, **or**
- move the high-frequency gemini surfaces to a higher-quota Vertex
  region/project/endpoint, **or**
- set explicit non-gemini models for `compaction` and the global default
  (`~/.config/opencode/opencode.json:8,154`) so a runaway can't recruit the default
  model too.

This removes the *condition* (quota pressure) that fires the retry loop, complementing
Fix 1 which removes the *unboundedness*.

### Fix 3 — Defense-in-depth in lgtm (lifecycle + circuit breaker)
- **Never launch an unkillable session.** In `gather.ts:188-191`, treat unparsed
  launch output as a hard failure (or kill by tmux session
  `LGTM_TMUX_SESSION = "lgtm"`), so there is always a handle to stop it. Make the kill
  robust (small retry; consider `POST /session/:id/abort` — the dedicated abort
  endpoint — in addition to `DELETE`).
- **Bound subagent / review wall-clock**, or otherwise reap stuck gemini subagents
  inside opus reviews (currently unmanaged, §4b-4).
- **Global cost/rate circuit-breaker:** track gemini Vertex spend/call-rate per cycle
  and stop dispatching when a threshold is exceeded, surfacing via the existing pigeon
  `/alert` path (lgtm already has watchdog→pigeon alerting). This caps blast radius
  even if a new uncapped path appears.

### Fix 4 — Pigeon notifier dedup (observability hygiene, not cost)
Add a `shouldNotify`-style guard to the `session.status` retry branch
(`pigeon/.../opencode-plugin/src/index.ts:604-633`) so an uncapped retry loop doesn't
flood Telegram with one message per attempt. Strictly a symptom-quieting change — do
**not** rely on it instead of Fix 1.

---

## 6. Evidence index (file:line)

| Claim | Citation |
|---|---|
| Telegram retry msg is a notifier of `session.status{type:"retry"}` | `pigeon/packages/opencode-plugin/src/index.ts:604-633` |
| Pigeon retry branch has no dedup guard | same, vs `index.ts:393,502` (`shouldNotify`) |
| Pigeon arbiter retries delivery only, capped at 10 | `pigeon/packages/daemon/src/swarm/arbiter.ts:14,102-127` |
| Retry policy is uncapped (no `Schedule.recurs`) | `opencode/packages/opencode/src/session/retry.ts:175-198`, esp. 184 |
| Backoff caps at 30 s w/o header | `retry.ts:25-65`; test `retry.test.ts:35-39` |
| 429/resource_exhausted is retryable | `retry.ts:144`; test `retry.test.ts:127-130` |
| 5xx always retried (broadened) | `retry.ts:74`; upstream commit `4ca809ef4` (#22511) |
| Retry wraps the whole stream; partial output discarded | `processor.ts:780-843`, esp. 787,790,810 |
| One assistant message (DB step-start) per step | `prompt.ts:1252` (loop), `1347-1362` (create+`updateMessage`) |
| assistantMessage created once, reused across retries | `processor.ts:111` |
| DELETE cancels running job | `opencode/.../session/session.ts:595-616,874-889` |
| Deployed binary = uncapped (0 `Schedule.recurs`) | `/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2` |
| gather model = gemini | `lgtm/src/gather.ts:10` |
| gather enabled by default | `lgtm/src/index.ts:98` |
| gather timeout→DELETE leak | `lgtm/src/gather.ts:172-215` (esp. 188-191, 199-210) |
| review model = opus (separate quota) | `lgtm/src/dispatch.ts:11` |
| reviewer subagents = gemini | `~/.config/opencode/agents/code-reviewer.md`, `agents/spec-reviewer.md` |
| default + compaction model = gemini | `~/.config/opencode/opencode.json:8,154` |
| re-awaken gated (not a runaway) | `lgtm/src/discover.ts:1245-1302`; `lgtm/src/dispatch.ts:157-191` |

---

## 7. Side note (security, out of scope for this bug)

While reading `~/.config/opencode/opencode.json` I observed a Slack `xoxp-` user OAuth
token stored in plaintext in that file (around line 150). Not related to the retry
surge, but it should be rotated and moved to a secret store. (Token value intentionally
not reproduced here.)
