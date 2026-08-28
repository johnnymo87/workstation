# Phase 1b: anchor and excerpt capture

**Status:** plan, not yet implemented. **Repo:** `pigeon` only.
**Design:** `docs/plans/2026-08-25-unread-navigation-design.md` (Revision 2),
sections 3 and 4, and open questions 1, 3, 4, 5, 6.
**Depends on:** phase 1a (pigeon #131), shipped and running.
**Blocks:** phase 2 (the `tui.message.scroll` opencode patch) and phase 4 (the
drill-down). Neither is started.

This phase writes two columns and produces **no user-visible behaviour change**.
That is deliberate and worth stating plainly, because it means the phase cannot
be validated by using the product — only by inspecting rows. The acceptance
check at the end is a SQL query, not a gesture.

**Revision 2 of this plan.** Adversarial review found two blockers and four
substantive errors, including two places where revision 1 asserted something
false. Those are corrected in place and marked, because the false claims are
more instructive than their corrections.

---

## What changed since the design was written

The design's section 4 prescribes a plugin change:

> Add `lastUserMessageId` per session to `message-tail`, and thread it through
> `notifyStop` → `/stop` body → `outbox` → `session_events.anchor_msg_id`.

**That work is unnecessary, and this plan does not do it.** Phase 1a — written
after the design and shipped in pigeon #131 — already put the anchor in the
daemon's hands. Verified 2026-08-28 against `origin/main`:

- `daemon-client.ts:319-325` already posts `{sessionId, messageId, text}` to
  `/mirror`. The `messageId` is the **user** message id.
- `app.ts:771-779` already requires it (400 without it).
- `app.ts:813-816` already **classifies the turn**: `wasInjected ||
  !text.trim() || payloadHasCloseTag(text)` early-returns.

The saving is the entire plugin change: no `message-tail` state, no `/stop`
wire-format change, no plugin redeploy, and therefore none of the
"plugin changes reach long-running serves only at restart" lag the design warns
about — nothing in the plugin changes.

### The classification is *near*-total, not total

Revision 1 of this plan said "anything reaching line 843 is **by construction**
a user-role turn the daemon did not inject." That overstates it. There is a
known residual, documented in the plugin's own comments:

`message-tail.ts:248-255` buffers a part as *user* text when
`roleInfo === undefined && part.messageID !== currentAssistantMsgId` — i.e.
before role news has arrived. The cancel-on-`message.updated` guard at 191-197
only rescues this if the role arrives within `debounceMs`. When it does not
(the `messageRoles` eviction leak the file names explicitly), `/mirror` receives
an **assistant** message id, which passes classification and would be stored as
the anchor.

**Consequence: a silent no-scroll in phase 2** — `getChildren().find()` misses,
and the jump lands at the bottom exactly like today. That is the correct
degrade direction, and it is the same limitation upstream's own
`messages_last_user` accepts. Inherit it knowingly rather than claim it away.

### Placement is already proven

`markAllRead` at `app.ts:843` sits below the injected/envelope early-return and
**above** `shouldEmitAncillaryFor` (line 849). The comment block at 832-842
records that both directions are load-bearing and pinned by
`mirror-route.test.ts`. Writing the anchor at the same point inherits that
coverage: it fires for `notify`-policy `none`/`errors-only` sessions and for
quiet (lgtm) sessions, exactly like the clear does.

### `/stop` cannot supply the anchor, and neither can `/question` or swarm

`/stop` (`app.ts:895-921`) receives `session_id`, `message`, `summary`, `event`,
`label`, `title`, `error_kind` — **and no message id of any kind.**

This forces one uniform rule rather than three per-kind ones, and answers the
design's **open question 4**:

> **The anchor for every kind is the session's last human-authored user message
> id, as of enqueue time.**

| kind | why that anchor is right |
|---|---|
| `stop` | the human turn that *started* the run; land where their request was |
| `question` | the agent is asking them something; land at their last turn so the intervening work is visible |
| `swarm` | a peer message arrived; the design explicitly says peer turns are **not** anchors, so the last human turn is correct by definition |

### The rule is really "last human turn authored **in the TUI**"

`opencode-client.ts:328` — `sendPrompt` records **every** daemon-injected prompt
in `injected_prompts` before posting it. Telegram replies reach opencode through
exactly that path, so a Telegram reply is classified *injected* at `app.ts:813`
and **never updates the anchor**.

This is not a defect to fix here, but it must be stated:

- Telegram replies still **clear** the badge — that half lives at
  `poller.dispatch` (#125) and is unaffected.
- So after a Telegram exchange the badge is clear; the next notification's
  anchor is the last **TUI** turn, which may be hours of transcript back.
- Direction is safe (re-read, never skip), but "far too early" is a real
  usability cost for Telegram-driven sessions.

**Deferred to phase 2, deliberately:** whether a very stale anchor is worse than
no anchor. Phase 2 has the information to decide (it knows what is on screen);
this phase does not. Recording the fact is the deliverable here.

Other human turns that never reach `/mirror`, all failing toward NULL or a
too-early anchor: image/file-only prompts (`message-tail.ts:378-388` returns
when `textParts.length === 0`), an open circuit breaker
(`daemon-client.ts:314` returns without posting), and subagent sessions
(Exclusion 1, `message-tail.ts:368-376` — correct, they do not notify).

---

## The hazard this plan exists to avoid

**Capture the anchor at ENQUEUE. Never read it at delivery.**

`session_events` rows are appended in `commitDelivery`
(`worker/outbox-sender.ts:157-180`), at **delivery** time, which is
retry-skewed and governor-delayed.

```
1. agent finishes    -> /stop enqueues an outbox entry. Correct anchor = H1.
2. human types H2    -> /mirror: markAllRead + last_human_msg_id = H2.
                        markAllRead is SELECT MAX(id) FROM session_events
                        (session-events-repo.ts:111-117), so it CANNOT cover a
                        row that has not been appended yet.
3. stop delivered    -> row appended, AUTOINCREMENT id > watermark,
                        so it counts as UNREAD.
4. anchor read now   -> H2, which is AFTER the content the row notifies about.
```

The user lands **past** the thing they were told about. Rare, timing-dependent,
and invisible in casual testing — the exact silent failure class this feature
exists to remove.

Therefore the anchor is captured when the outbox entry is created and **carried
on the outbox row** into `commitDelivery`, which copies and never looks up.

### The same hazard through the side door: upsert on conflict

`outbox-repo.ts:72-81` is an upsert whose conflict arm is
`ON CONFLICT(notification_id) DO UPDATE SET ... WHERE outbox.state = 'failed'`,
and **the SET list deliberately omits `payload`** — a requeued failed row keeps
its original content.

`enqueueSwarmTelegramNotice` (`telegram-notice.ts:56`) uses
`notificationId = w:${msgId}`, and swarm **requeue** re-fires the notice for the
same id. If the first delivery failed and a human typed meanwhile, adding
`anchor_msg_id = excluded.anchor_msg_id` to the SET would pair a **newer anchor
with the older payload** — reintroducing the hazard above through a path none of
revision 1's tests covered.

**`anchor_msg_id` and `excerpt` must NOT appear in the conflict arm**, matching
`payload`'s existing semantics: the row's content is fixed at first enqueue.

`/stop` and `/question` pre-check `getByNotificationId` and early-return
(`app.ts:1060-1073`), so for them the conflict is a race only. Swarm has no such
pre-check, which is why this is reachable rather than theoretical.

---

## Schema

`schema.ts:162` already calls `runAdditiveMigrations(db)` with the default
`additiveColumns` array, and `isDuplicateColumnError` makes re-running safe.
Append to that array:

```
ALTER TABLE sessions ADD COLUMN last_human_msg_id TEXT DEFAULT NULL
ALTER TABLE outbox   ADD COLUMN anchor_msg_id     TEXT DEFAULT NULL
ALTER TABLE outbox   ADD COLUMN excerpt           TEXT DEFAULT NULL
```

`session_events` is initialised separately (`database.ts:58`) and currently runs
no migrations. Add a call using the same exported helper with its own **local**
statements array, mirroring `swarm-schema.ts:55-74`:

```
ALTER TABLE session_events ADD COLUMN anchor_msg_id TEXT DEFAULT NULL
ALTER TABLE session_events ADD COLUMN excerpt       TEXT DEFAULT NULL
```

**The session_events statements must stay OUT of the shared `additiveColumns`
array, and the reason must be written down.** `initSchema` runs at
`database.ts:56`, before `initSessionEventsSchema` at 58. On a **fresh** DB the
`session_events` table does not exist yet, and `no such table` is *not* matched
by `isDuplicateColumnError` (which is message-matched and fails safe by
rethrowing) — so consolidating the arrays crashes daemon startup on every new
database. Pin the why in a comment so that "simplification" fails loudly.

Verified not implicated: `sessions`, `outbox` and `session_events` are all
outside `ROUTING_DDL` (`route-schema.ts:30ff`), whose digest the serve pool
validates at startup.

**No index.** Neither column is ever a predicate; both are read by primary key
alongside the row they annotate.

---

## Tasks

### Task 1 — schema columns

Add the five `ALTER TABLE` statements. Extend `initSessionEventsSchema` to call
`runAdditiveMigrations` with its own local array plus the comment above.

**Tests.** Assert all five columns exist via `PRAGMA table_info`. Then call the
init functions a **second time** on the same handle and assert no throw. Also
assert a **fresh** DB initialises cleanly — that is the regression the ordering
comment protects.

### Task 2 — record the anchor on a human turn

Beside `storage.sessionEvents.markAllRead(sessionId, now)` at `app.ts:843`,
persist `messageId` as the session's `last_human_msg_id`. Add a repo method
rather than inlining SQL.

**Use a monotonic `MAX()` write, not a plain UPDATE.** Revision 1 specified a
plain UPDATE and justified it as "the newest human turn always wins". That
conflates *newest* with *last to arrive*: two `postMirror` calls are independent
async HTTP requests, so H1's can land after H2's and regress the anchor by a
turn. Message ids are ascending, sortable, fixed-width (`msg_` + 26 chars, with
an embedded ms timestamp — design "Message identity"), so a lexicographic
`MAX(last_human_msg_id, ?)` implements newest-wins robustly and for free, and
mirrors the discipline of `advanceRead` sitting one line above. Forks mint later
ids, so it cannot wedge.

**A session row may not exist.** `/stop` 404s on an unknown session; `/mirror`
does not (line 854 tolerates `undefined`). The update must no-op silently rather
than throw or insert — a `/mirror` that starts 500ing breaks mirroring *and*
phase 1a's clearing, both live.

**Tests.**
- a human turn records the id
- an **injected** turn records nothing (returns before 843)
- an **enveloped** (`<swarm_message>`) turn records nothing
- a whitespace-only turn records nothing
- a second, later human turn overwrites the first
- **an out-of-order arrival (H2 then H1) leaves H2 in place** — pins the
  monotonic property; would pass vacuously under a plain UPDATE only if the ids
  happen to arrive in order, which is why it must be written out of order
- `/mirror` for an unknown session still returns 200 and does not throw
- a quiet (lgtm) session still records — pins the write's position above 849

### Task 3 — capture anchor and excerpt at enqueue

Widen `outbox.upsert` to accept optional `anchorMsgId` and `excerpt`, **absent
from the conflict arm** (see above). Pass from all four enqueue sites:

| site | excerpt source |
|---|---|
| `app.ts:880` `mirror` | `text` (the human's own prompt) |
| `app.ts:996` `stop` | `message \|\| summary \|\| "Task completed"` |
| `app.ts:1153` `question` | the question text |
| `telegram-notice.ts:56` `swarm` | `record.payload` |
| `telegram-notice.ts:115` swarm **cancel** | see below |

**The stop precedence is `message || summary`, not `summary ?? message`.**
Revision 1 had it backwards. Verified: `app.ts:971` and `978` both compute
`message || summary || "Task completed"`, and 978 is what the notification
actually renders. An excerpt that disagrees with the delivered notification
would make the future drill-down show different text than the Telegram message
it refers to.

**Swarm cancel (`telegram-notice.ts:115`)** notifies about a *retracted*
message; its `record.payload` is the content being withdrawn. Store **no
excerpt** for cancels rather than an excerpt of something the user is being told
to disregard.

**Question wizard mode:** `questions` is an array. Use the first question's
text; state it explicitly so the choice is not re-litigated.

**Capture pre-format.** By `commitDelivery` the payload is HTML with entities,
escapes, a session prefix and chunk headers. Truncate to 150 chars from the
plain source and apply `.toWellFormed()` — `slice(0, 150)` can split a surrogate
pair and store a lone surrogate. Precedent in the file being edited:
`telegram-notice.ts:46` already does `record.payload.toWellFormed()`.

**Tests.** Per kind: the outbox row carries the expected anchor and a plain
excerpt. Plus:
- **stop precedence with BOTH `message` and `summary` set** → excerpt equals
  `message`. This is the test that would have caught revision 1's inversion.
- an input containing `&` and `<` yields an excerpt with no `&amp;`/`<b>`/
  session-prefix artefacts — fails loudly against "just slice the payload".
- an emoji straddling char 150 yields a well-formed string.
- **conflict-arm immutability:** upsert with anchor A → mark failed → upsert the
  same `notificationId` with anchor B → assert **A** survives.

### Task 4 — carry through delivery

Widen `commitDelivery`'s `entry` parameter (`outbox-sender.ts:157-163`) and pass
to `sessionEvents.append`. Widen `AppendInput` and the `INSERT` in
`session-events-repo.ts`. `entry` at the call site (line 662) is the fetched
outbox row, so no extra query.

**`commitDelivery` copies. It must not read `sessions`.** The obvious
"simplification" — look the anchor up here — reintroduces the enqueue/delivery
hazard.

**Tests.**
- a delivered notification produces a `session_events` row whose `anchor_msg_id`
  and `excerpt` equal the outbox row's. **Use non-NULL values**, or `NULL ==
  NULL` passes vacuously against a thread-through that drops both.
- **the interleaving test:** enqueue with anchor `H1`; set
  `last_human_msg_id = H2`; deliver; assert the row still says **`H1`**. Fails
  against a delivery-time implementation, passes against enqueue-time.
- a NULL anchor (pre-migration row) delivers fine and stores NULL.

### Task 5 — null-safety review, no new code

Grep every read of `session_events` and confirm none assumes the columns are
present. `unreadBySession` selects specific columns and is unaffected — verify
rather than assume. Backfill is explicitly **not** done (design open question 5);
NULL means "do not scroll", which is today's behaviour.

---

## An obligation this phase hands to phase 2

Revision 1 of this plan claimed mirror rows "can never be the oldest uncleared
row". **That is false**, and the correction matters because the false version
would have deleted a warning the design deliberately included.

`/mirror` runs `markAllRead` at line 843 *before* enqueueing its own row at 880.
Since `markAllRead` is `SELECT MAX(id)` over rows that already exist, and the
mirror row is appended later at delivery, **a mirror row routinely lands above
the watermark**. `mirror` is excluded from the *count* (`UNCOUNTED_KINDS`,
`session-events-repo.ts:14`) but not from the ledger.

So an "oldest uncleared" query in phase 2 or 4 that omits the kind filter **will
select mirror rows**, and the drill-down will disagree with the badge — exactly
what the design's "Oldest uncleared must skip uncounted kinds" section warns
about. Writing anchors on mirror rows stays (uniformity is cheaper than a
special case); the filter is phase 2's obligation.

## Open questions this plan does NOT close

- **#2 attach/scroll race** — phase 2.
- **#3 compaction.** A compacted-away anchor makes `getChildren().find()` return
  undefined and the TUI not scroll: today's behaviour. Phase 2 must not add a
  retry loop. No storage change here.
- **#7 two TUIs on one session** — phase 2, believed benign.

Two timing facts phase 2 should not be surprised by, neither worth code here:

- **Enqueue can race the anchor's own write.** `last_human_msg_id` is written
  only after the plugin's debounced flush completes its HTTP round trip. A
  `/question` fired mid-turn, or a fast-failing `/stop`, can enqueue before it
  lands and capture the *previous* turn's id, or NULL. Off by one turn, in the
  safe direction. Do not write tests that assume exact-turn anchoring under
  tight timing.
- **Telegram-driven sessions carry a stale anchor**, per the section above.

## Acceptance

After deploy and one daemon restart:

```sql
SELECT kind, COUNT(*), COUNT(anchor_msg_id), COUNT(excerpt)
FROM session_events WHERE id > (SELECT MAX(id) - 200 FROM session_events)
GROUP BY kind;
```

Rows written *after* the restart should show non-NULL anchors for sessions that
have had a TUI human turn since. Rows for sessions whose last TUI turn predates
the deploy show NULL **forever** — expected, not a defect.

**Revision 1 also proposed asserting every anchor starts `msg_`, and called a
failure "the assistant-id trap". That check is vacuous:** assistant message ids
start `msg_` too — the design's own trap section describes `currentMessageId`,
an assistant id, in exactly that format. The prefix check can only catch storing
a *notification* or *session* id. No daemon-side check can distinguish an
assistant id from a user id; only phase 2's `find()` miss can, and it does so
silently. Keep the prefix assertion for what it actually catches, and drop the
claim about the trap.

## Landing

One PR to `pigeon`. Squash. **No auto-merge on pigeon** — merge by hand once
`typecheck + tests` is green, then verify by content on `origin/main`.

Deploy needs a daemon restart, which an opencode session cannot perform (`sudo`
and `systemctl restart` are both denied). Either ask, or let the nightly 03:00
restart pick it up. Until then the running daemon keeps writing NULLs — harmless.
