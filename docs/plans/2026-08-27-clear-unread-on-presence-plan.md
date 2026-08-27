# Clear unread on presence — Implementation Plan (phase 1a)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the two remaining gaps where the pigeon daemon has unambiguous
evidence a human was present but does not clear the session's unread badge.

**Architecture:** Daemon-only, two small additions to existing handlers. Clearing
already exists for the Telegram half; this adds the two TUI-side call sites that
were missed. **No new columns, no migration, no plugin change, no opencode
patch.**

**Tech Stack:** TypeScript, **vitest** (`vitest run` — *not* bun test),
better-sqlite3, raw `Request` handlers in `packages/daemon/src/app.ts`.

**Implements:** `docs/plans/2026-08-25-unread-navigation-design.md` (Revision 2),
phase 1a of the revised landing order. **Bead:** `workstation-v8jh`.

---

## What already exists — read this before writing any code

**Clearing on presence is already half-built and shipped.** pigeon PR #125
(`05d43f5`, "feat(unread): read watermark route and clear-on-inbound-action")
landed:

- `SessionEventsRepo.markAllRead(sessionId, now)`
  (`session-events-repo.ts:111-117`) — advances the watermark to `MAX(id)` for
  the session, no-op on an empty ledger.
- `Poller.dispatch` fires `onInboundForSession` for **every** Telegram-originated
  command carrying a `sessionId` — execute, kill, interrupt, compact, mcp_*,
  model_* — **before** the handler runs (`poller.ts:389-411`), wired to
  `markAllRead` at `index.ts:197-199`. Its own comment explains the placement:
  *"the single boundary every Telegram-originated command crosses — a typed reply
  and a question-card callback both arrive here as execute commands."*
  Pinned by `poller.test.ts:1155,1202`.
- `POST /sessions/:id/read` (`app.ts:1136-1160`) — the explicit watermark route
  the workstation picker already calls via `exec.clear_unread`
  (`session_switcher/exec.lua:226-239`).

**So the Telegram side is done, and phase 3's "mark all read" gesture already has
its endpoint** — it needs a keybinding, not new plumbing.

### A false finding this plan previously contained, recorded so nobody re-derives it

An earlier revision of this plan claimed that **Telegram replies never clear the
badge**, reasoning that a reply is delivered via `sendPrompt`, which records into
`injected_prompts` (`opencode-client.ts:327-328`), so `POST /mirror` classifies
the echo as injected and returns early.

**Every step of that is true and the conclusion is still false**, because
clearing for Telegram never depended on `/mirror` at all — it happens at
`poller.dispatch`, one layer earlier, and has since #125. A whole task was
written against this gap. It would have been production dead code: `markAllRead`
called a second time, in the same tick, for a session the poller had already
cleared.

The error was not a bad inference; it was **never asking whether the behaviour
already existed.** The investigation went straight to "where should clearing be
added" without first running `git log -S markAllRead`. Do that first.

---

## The two real gaps

Both are TUI-side, where no Telegram command exists to trigger the poller path.

| gap | why the badge survives today | fix |
|---|---|---|
| a human types a turn in the TUI | the echo reaches `POST /mirror`, which has no clearing | Task 1 |
| a human answers a question in the TUI | resolution reaches `POST /question-answered`; **no user text message is created at all**, so no `/mirror` ever fires | Task 2 |

Task 2's gap is the more surprising one and worth stating plainly: question
notifications are a major source of badges, and answering one at the keyboard is
about as unambiguous as presence gets, yet nothing currently clears it.

## Classifier: `injected_prompts` primary, envelope as backstop

The design doc proposes a text test — swarm payloads are wrapped in
`<swarm_message>…</swarm_message>` and `payloadHasCloseTag`
(`swarm/envelope.ts:75`) makes the boundary unforgeable.

`/mirror` already computes something stronger for its own purposes:
`injectedPrompts.consume(...)` (`app.ts:796`), a positive, hash-exact record of
every daemon injection. This plan keeps that as primary and adds the envelope
test as a **backstop**, because the hash path has one residual the envelope
closes: `INJECTED_PROMPTS_TTL_MS` is 15 minutes
(`injected-prompts-schema.ts:3`), and `consume()` returns false past the cutoff
(`injected-prompts-repo.ts:32`), so a `prompt_async` whose echo arrives late
loses its record.

**How late is "late" is not established.** It depends on whether opencode creates
the user-message row at `prompt_async` *receipt* or at turn *dequeue*. If at
receipt, the echo arrives within the plugin's 500 ms debounce
(`message-tail.ts:130`) and the TTL never expires in practice. That is not
answerable from pigeon's source. **Do not write a code comment asserting this
happens "routinely"** — say the window exists and is unquantified.

This is belt-and-braces on top of the design's classifier, **not** a correction of
a design error. The design's envelope-only test would also work here.

## Accepted residuals

- **Retry re-clear (pre-existing, and the largest of these).** `markAllRead`
  advances to max id *at call time*: monotone, but **not idempotent across
  time**. A persistently failing handler is redispatched roughly once per 60 s
  lease until the worker's 24 h cleanup, and each attempt re-clears at a later
  mark — marking read anything delivered in between. Documented in
  `poller.ts:393-402` and accepted there; the tracked fix is to clamp to the
  command's `created_at`. Stated here because this plan describes the system's
  clearing behaviour, and an earlier revision wrongly implied the only over-clear
  window was sub-second.
- **The enter-to-`/mirror` window.** ~500 ms debounce plus one HTTP hop. A `stop`
  for the *current* turn cannot exist there, but a retry-skewed `stop` from the
  previous turn can commit in it — in which case clearing is semantically
  correct anyway, since the human just read that output. A `swarm` or `question`
  row landing in the same window is cleared unseen. Costs a bookmark, not
  content. **Do not** attempt an `sent_at <= T` refinement: `sent_at` is delivery
  time and retry-skewed (design doc line 58).
- **Non-daemon automation reads as human.** A session launched by the
  `opencode-launch` CLI (lgtm does this) has a prompt the daemon never recorded
  and never enveloped. Bounded, does not self-heal; already documented in
  `ancillary-gate.ts`. Moot at launch specifically, because the ledger is empty
  and `markAllRead` no-ops.
- **A human who pastes a literal `</swarm_message>`** into a TUI prompt gets no
  mirror and no clear. Realistic on this host, since pigeon is developed here.
  Self-heals on the next turn. Swarm payloads cannot legitimately contain the
  close tag (`envelope.ts:83-87` rejects at both enqueue and render), so a human
  paste is the only source.
- **`postMirror` failing means no clear.** Fails toward "still unread" — correct
  direction.

---

## Task 1: `/mirror` clears on a human-authored TUI turn

**Files:**
- Modify: `packages/daemon/src/app.ts` (`POST /mirror`, ~lines 790-810)
- Test: `packages/daemon/test/mirror-route.test.ts`

**Placement is load-bearing in both directions.** `markAllRead` must sit **below**
the `wasInjected || !text.trim()` early-return (or injected prompts would clear)
and **above** the `shouldEmitAncillaryFor` quiet gate (or a session with
notify-policy `none`/`errors-only` would never clear — coupling badge state to
Telegram delivery policy, which are unrelated concerns).

**Step 1: Write the failing tests**

Append to the existing `describe("POST /mirror route", ...)` block. The harness is
`newApp(now)` with a module-level `storage`; reuse the file's existing `mirror()`
helper where it fits.

```ts
it("clears the unread watermark when a human types in the TUI", async () => {
  const app = newApp();
  storage!.sessionEvents.append({
    sessionId: "ses_1", notificationId: "n1", kind: "stop", sentAt: 1_000,
  });
  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(0);

  await app(new Request("http://localhost/mirror", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId: "ses_1", messageId: "msg_1", text: "what about the retry path?" }),
  }));

  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(
    storage!.sessionEvents.maxEventIdForSession("ses_1"),
  );
});

it("does NOT clear when the turn was an injected prompt", async () => {
  const app = newApp();
  storage!.sessionEvents.append({
    sessionId: "ses_1", notificationId: "n1", kind: "stop", sentAt: 1_000,
  });
  const text = "injected by a peer";
  storage!.injectedPrompts.record("ses_1", hashPrompt(text), 1_000);

  await app(new Request("http://localhost/mirror", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId: "ses_1", messageId: "msg_1", text }),
  }));

  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(0);
});

it("does not clear or mirror an enveloped turn whose injected_prompts record expired", async () => {
  const app = newApp();
  storage!.sessions.upsert({ sessionId: "ses_1", notify: true }, 1_000);
  storage!.sessionEvents.append({
    sessionId: "ses_1", notificationId: "n1", kind: "stop", sentAt: 1_000,
  });
  // No injected_prompts row at all: the TTL-expiry / hash-miss case.
  const text = '<swarm_message from="ses_x">do the thing</swarm_message>';

  const res = await app(new Request("http://localhost/mirror", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId: "ses_1", messageId: "msg_1", text }),
  }));

  // Asserting BOTH pins the latent mirror-leak fix, not just the clearing.
  expect(await res.json()).toEqual({ mirrored: false });
  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(0);
});

it("clears for a quiet-origin session even though it does not mirror", async () => {
  // PLACEMENT GUARD. Fails if markAllRead drifts below shouldEmitAncillaryFor.
  const app = newApp();
  storage!.sessions.upsert({ sessionId: "ses_lgtm", notify: true }, 1_000);
  storage!.sessionOrigins.record(
    { sessionId: "ses_lgtm", origin: "lgtm", notifyPolicy: "errors-only", source: "declared" },
    1_000,
  );
  storage!.sessionEvents.append({
    sessionId: "ses_lgtm", notificationId: "n1", kind: "stop", sentAt: 1_000,
  });

  const res = await app(new Request("http://localhost/mirror", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sessionId: "ses_lgtm", messageId: "msg_1", text: "hello" }),
  }));

  expect(await res.json()).toEqual({ mirrored: false, reason: "quiet_origin" });
  expect(storage!.sessionEvents.lastReadId("ses_lgtm")).toBeGreaterThan(0);
});
```

**Step 2: Run to verify they fail**

Run: `cd packages/daemon && npx vitest run test/mirror-route.test.ts`
Expected: tests 1, 3 (the `mirrored` half), and 4 FAIL. Test 2 passes already —
it is a placement guard against clearing drifting *above* the early-return, not a
test of new behaviour. Note that distinction rather than assuming test 2 is
broken.

**Step 3: Implement**

Import at the top of `app.ts`:

```ts
import { payloadHasCloseTag } from "./swarm/envelope";
```

In the `/mirror` handler:

```ts
const wasInjected = storage.injectedPrompts.consume(sessionId, hash, now);

// payloadHasCloseTag is a BACKSTOP, not the primary test. injected_prompts is
// authoritative and hash-exact; the envelope catches the case where its record
// expired (INJECTED_PROMPTS_TTL_MS, 15 min) before the echo arrived. How often
// that happens is UNQUANTIFIED -- it depends on whether opencode creates the
// user-message row at prompt_async receipt or at turn dequeue, which is not
// knowable from this repo. The envelope boundary cannot be forged by payload
// content (envelope.ts rejects a close tag at both enqueue and render), so it is
// safe to trust here.
//
// This also closes a latent mirror leak: such a turn previously posted to
// Telegram as a human message. Pinned by the "does not clear or mirror an
// enveloped turn" test.
if (wasInjected || !text.trim() || payloadHasCloseTag(text)) {
  return Response.json({ mirrored: false });
}

// A human typed this into the TUI. Authoring a turn is evidence they read what
// preceded it, so advance the read watermark.
//
// PLACEMENT IS LOAD-BEARING, in both directions:
//  - BELOW the early-return above, or injected prompts would clear.
//  - ABOVE shouldEmitAncillaryFor, or a session with notify-policy
//    'none'/'errors-only' would never clear. Badge state and Telegram delivery
//    policy are unrelated concerns and must not be coupled.
// Pinned by the "clears for a quiet-origin session" test.
storage.sessionEvents.markAllRead(sessionId, now);

if (!shouldEmitAncillaryFor(storage, sessionId, now)) {
```

**Step 4: Run to verify they pass**

Run: `cd packages/daemon && npx vitest run test/mirror-route.test.ts test/injected-prompts-route.test.ts test/mirror-polish.test.ts test/swarm-telegram-notice.test.ts`
Expected: all green. The last three are the existing `/mirror` consumers; the
envelope term is a behaviour change, so they must be run, not assumed.

**Step 5: Commit**

```bash
git add packages/daemon/src/app.ts packages/daemon/test/mirror-route.test.ts
git commit -m "Clear the unread watermark when a human types in the TUI"
```

---

## Task 2: `/question-answered` clears the watermark

**Files:**
- Modify: `packages/daemon/src/app.ts` (`POST /question-answered`, ~lines 1124-1133)
- Test: `packages/daemon/test/` — locate the existing `/question-answered` suite
  first (`grep -rl "question-answered" test/`); add there rather than creating a
  new file.

**Why this is a real gap, not a duplicate of the poller path.** A question
answered *in Telegram* arrives as an execute command and is already cleared by
`poller.dispatch`. A question answered *in the TUI* produces **no user text
message at all** — so no `/mirror`, and no Telegram command. Nothing clears it
today. The plugin notifies the daemon at `daemon-client.ts:259`
(`notifyQuestionAnswered`, called from plugin `index.ts:728`), which is the only
signal that the human acted.

Double-firing for the Telegram case is harmless: `markAllRead` is monotone, and
the poller already ran in the same tick.

**Step 1: Write the failing test**

```ts
it("clears the unread watermark when a question is answered", async () => {
  const app = newApp();
  storage!.sessionEvents.append({
    sessionId: "ses_1", notificationId: "n1", kind: "question", sentAt: 1_000,
  });
  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(0);

  await app(new Request("http://localhost/question-answered", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ session_id: "ses_1" }),
  }));

  expect(storage!.sessionEvents.lastReadId("ses_1")).toBe(
    storage!.sessionEvents.maxEventIdForSession("ses_1"),
  );
});

it("still returns 400 without a session_id, and clears nothing", async () => {
  const app = newApp();
  const res = await app(new Request("http://localhost/question-answered", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  }));
  expect(res.status).toBe(400);
});
```

**Step 2: Run to verify the first fails**

Run: `cd packages/daemon && npx vitest run test/<file>.test.ts -t "question"`
Expected: the clearing test FAILS; the 400 test passes already.

**Step 3: Implement**

```ts
const deleted = storage.pendingQuestions.delete(sessionId);

// Answering a question is evidence the human was present -- and for a question
// answered in the TUI this is the ONLY such signal: it creates no user text
// message, so /mirror never fires and no Telegram command reaches the poller.
// A question answered in Telegram is already cleared at poller.dispatch; this
// double-fire is harmless because markAllRead is monotone.
storage.sessionEvents.markAllRead(sessionId, nowFn());

return Response.json({ ok: true, cleared: deleted });
```

Use the handler's existing clock (`nowFn()`), not `Date.now()` — check what the
surrounding routes use.

**Step 4: Run to verify it passes**

Run: `cd packages/daemon && npx vitest run test/<file>.test.ts`

**Step 5: Commit**

```bash
git commit -m "Clear the unread watermark when a question is answered"
```

---

## Task 3: full suite, typecheck, PR

**Step 1:** `cd packages/daemon && npx vitest run` — full daemon suite green.
**Step 2:** `cd /home/dev/projects/pigeon && npm run typecheck` — clean.
**Step 3:** PR. pigeon has **no auto-merge**; merge by hand. Per
`workstation-gcah`, the nightly restarts pigeon but never pulls, so after merging
the deploy root needs a manual `git pull --ff-only` and a daemon restart before
this takes effect.

---

## Deliberately not in this PR

- **`anchor_msg_id` / `excerpt` columns + migration** — they serve scroll-to-unread
  and the drill-down, not clearing. Phase 1b.
- **Any plugin change.** Both call sites already receive what they need.
- **Clamping the retry re-clear** to the command's `created_at` — pre-existing,
  tracked separately at `poller.ts:400-402`, and orthogonal to these two gaps.
- **Removing auto-clear-on-jump** (workstation). Must not ship before this does.
  It must travel with a session-level "mark all read" gesture, which needs only a
  keybinding onto the existing `exec.clear_unread`.
- **The `tui.message.scroll` opencode patch.** Phase 2.

## Post-deploy verification

The tests cannot make these checks; do them on the running daemon.

1. Session with a badge → **type a turn in its TUI** → badge clears.
2. Session with a badge from a `question` → **answer it in the TUI** → badge
   clears. (This is the Task 2 gap; it does not clear today.)
3. Session with a badge → **reply in Telegram** → badge clears. This already
   worked before this PR; it is a regression check, not a new-behaviour check.
4. Session with a badge → **jump to it and do not type** → badge **survives**.
   **Expected to FAIL until phase 3**, because auto-clear-on-jump is still wired
   in workstation. Stated so the failure is not mistaken for a defect in this PR.
