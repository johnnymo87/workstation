# Session switcher: unread counts and Telegram-shaped ordering — design

**Date:** 2026-08-18
**Status:** **Revision 3** (2026-08-19) — substrate reversed after adversarial
review 1, then revision 2 reviewed again and corrected. Revision 1 (PR #393) is
superseded; see "What review 1 killed" and "What review 2 corrected".
**Repos touched:** `pigeon` (daemon: event ledger + watermark + one endpoint),
`workstation` (`assets/opencode/plugins/oc-session-list{,-fold}.ts`,
`assets/nvim/lua/user/session_switcher/`; `pkgs/oc-session-list/` holds only the
derivation and its test)
**Bead:** extends `workstation-7w9z` (S7 / Task 9, the Telescope picker)

## Motivation

`docs/plans/2026-07-12-opencode-session-switcher-design.md` designed the switcher
as a **navigator**: find a session by semantic state, jump to its pane or attach
a TUI. Everything through S6 (PR #295) implements that.

Daily use of the Telegram forum-topic view produced a different opinion. Telegram
is not a navigator — it is a list you live in, sorted by recency, where a
per-conversation **unread count** tells you where to look. At ~15 concurrent
sessions that badge is what makes the list usable, and the switcher has no
equivalent.

This adds two Telegram properties to the picker that is already the epic's next
task, and nothing else:

1. **Unread counts** per session.
2. **Recency ordering**, with sessions that need you pinned above it.

The picker stays a picker; you still jump. Only what it shows and how it sorts
changes.

## What review 1 killed

Revision 1 computed unread by counting rows in pigeon's `outbox` above a
watermark. **That cannot work, and the failure is silent in the worst direction.**

```
OUTBOX_RETENTION_MS = 60 * 60 * 1000;   // schema.ts:8
DELETE FROM outbox WHERE (state = 'sent' AND updated_at < ?) ...
```

The outbox is a **delivery queue, not a message store**: sent rows are deleted
after an hour. Counting from it means the badge decays to zero, so the single
most important case — returning in the morning to 15 sessions — reports *nothing
unread anywhere*, which is indistinguishable from "you have read everything." A
zero that asserts "nothing happened" is worse than no badge at all, and it is the
exact failure mode this document lectures about for the `?` glyph.

Telegram's badge persists because **Telegram** stores the messages. Revision 1
borrowed the badge semantics without the storage underneath.

Two further corrections from the same review:

- **`outbox` has no `cancelled` state.** Its states are `queued`, `sending`,
  `sent`, `failed` (`outbox-repo.ts`). Revision 1 cited "6% cancelled" as an
  outbox fact; that figure is from `swarm_messages`, a different table. It was a
  fabricated fact in a document whose stated purpose is recording falsified
  assumptions.
- **`created_at` is the wrong clock.** Delivery lags creation: the outbox
  governor holds bursts and `markRetry` does not touch `created_at`. A burst
  created at t0 but *delivered* after a clear at t1 would sort below the
  watermark and never be counted — permanently invisible, on the common path
  rather than an edge.

## What review 2 corrected

Revision 2 survived a second adversarial review with no design-killer, but four
things needed fixing and one of them was the same class of bug as review 1's:

1. **The silent zero could return.** Revision 2 never said where session
   *presence* was derived from. If it came from `session_reads`, a session whose
   ledger had fully aged out but whose watermark survived would report
   `unread: 0` — "read, nothing new" — which is revision 1's exact failure at a
   30-day horizon. Presence is now pinned to `EXISTS` in `session_events`.
2. **The concurrency claim was false**, and withdrawn; the reads move to the
   direct DB access `oc-session-list` already has.
3. **The "all turns" work had already merged**, which forces the unit-of-unread
   statement and invalidates the retention sizing.
4. **Sort ownership was left implicit**, inviting a picker-side sort that would
   violate the inherited S6 contract.

It also verified every file/line citation in revision 2 and found no fresh
fabrications, and confirmed the `AUTOINCREMENT` reasoning, the `markSent` write
point, the `·`/`?` split, and that pigeon should remain the owner.

## Substrate: a durable event ledger

Pigeon gains a table that records what was **actually delivered to a topic**,
written at the moment of delivery.

```sql
CREATE TABLE IF NOT EXISTS session_events (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id      TEXT    NOT NULL,
  notification_id TEXT    NOT NULL,
  kind            TEXT    NOT NULL,
  sent_at         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_session_events_session ON session_events(session_id, id);

CREATE TABLE IF NOT EXISTS session_reads (
  session_id   TEXT PRIMARY KEY,
  last_read_id INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
```

Three properties fall out of owning the table, and each removes complexity that
revision 1 needed:

- **`AUTOINCREMENT` gives a genuinely monotonic, never-reused id.** The composite
  `(created_at, notification_id)` watermark is gone; the watermark is one
  integer. `AUTOINCREMENT` rather than a bare `INTEGER PRIMARY KEY` specifically
  so that pruning old rows can never let a later row reuse an id below a stale
  watermark.
- **"Delivered" is true by construction.** The row exists only because delivery
  succeeded, so there is no `state` predicate to get wrong and no coupling to
  outbox states at all.
- **`sent_at` is the delivery clock**, not the creation clock, which is what the
  governor/retry interleaving requires.

**Write point.** In the same transaction as `markSent` (`outbox-repo.ts:137`),
which is a synchronous better-sqlite3 `UPDATE` on the same database — so the
ledger row and the state transition are atomic together, with no new failure
mode between them.

**Guard the write.** `markSent` is currently unguarded
(`UPDATE outbox SET state = 'sent' … WHERE notification_id = ?`,
`outbox-repo.ts:137-143`) and is safe today only by call-site discipline: one
caller (`outbox-sender.ts:617`), reached only when every chunk succeeded, inside
a reentrancy-guarded loop. Add `AND state != 'sent'` and insert the ledger row
only when `changes > 0`, so a future second caller cannot silently inflate every
count.

**Honest limit.** `markSent` runs *after* the Telegram API accepts. A crash
between acceptance and `markSent` loses the ledger row for a message that is
visible in the topic. That is the outbox's pre-existing at-least-once seam, not a
new one — the same crash already risks a duplicate send on retry. Named rather
than hidden.

**Retention.** The ledger stores metadata only — no payload — so rows are tiny.
It must outlive pigeon's `SESSION_TTL_MS` (7d), or the chronic-`?` problem below
simply moves. Proposed 30 days, pruned by session, with the size re-measured
before the number is fixed.

**Why pigeon still owns it.** Revision 1's reason ("it already has the data") is
gone, so this was re-decided rather than inherited. Two reasons survive: the
clear path is inherently pigeon's (opencode's DB can see a reply, because an
injected prompt becomes a user message, but it **cannot** see a callback answer
on a question card — the most common clear of all), and the thing being counted
is *what was delivered to a topic*, which opencode's message DB does not know.

**The honest consequence, so nobody mistakes this for a general facility:** this
badge is defined as "what Telegram was shown." If Telegram stops being the way
these sessions are read, this feature *should* die with it rather than be
retargeted.

## What counts as unread

**The unit is a delivered event — a turn — not a Telegram message.** Since
`#114` (below) a turn's narration is batched into one outbox entry that Telegram
renders as several messages, and the ledger writes **one row per entry**. So this
badge will read *lower* than Telegram's own unread badge for the same session.
That is intended, and stating it is what stops the number being distrusted on day
one.

`unread(session) = count(session_events WHERE session_id = ? AND id > last_read_id)`,
minus one read-time exclusion:

- **Your own messages do not count.** Typed prompts are mirrored into the topic
  as `kind='mirror'` (`app.ts:890`); in Telegram your own message never makes a
  chat unread. Telegram replies never enter the outbox at all (inbound, echo
  suppressed via `injectedPrompts.consume`), so they need no exclusion.
- **Swarm messages do count** (`kind='swarm'`, including retractions). They are
  genuinely new information and the reason a topic can show work with no visible
  cause.
- **Unknown kinds count.** The default is "topic-visible," so a kind added later
  is loud rather than silently invisible. (`kind='card'` is vestigial — nothing
  inserts it — but the rule is what matters.)

The exclusion is applied at **read** time, not write time: the ledger records
everything delivered, so a change of policy re-reads history instead of losing
it.

## Reads are a direct DB read; only the write is an endpoint

Revision 2 specified `GET /sessions/unread` and worried about running it
concurrently with the CLI's own walk. Both were wrong.

**`oc-session-list` already opens pigeon's daemon DB directly** — `routingDbPath`
from `OPENCODE_ROUTING_DB`, with the comment "pigeon's unified daemon DB is the
same file the serves open" (`assets/opencode/plugins/oc-session-list.ts:21-26`).
The cross-repo coupling that revision 1 rejected as *new* already exists and is
documented. So the counts are read in the same synchronous walk the CLI already
does:

```sql
SELECT e.session_id,
       COUNT(*) FILTER (WHERE e.id > COALESCE(r.last_read_id, 0)
                          AND e.kind <> 'mirror') AS unread,
       MAX(e.id)      AS last_event_id,
       MAX(e.sent_at) AS last_event_at
FROM session_events e
LEFT JOIN session_reads r USING (session_id)
GROUP BY e.session_id;
```

This deletes the HTTP GET, the 250 ms timeout, and the concurrency question
entirely. Revision 2 claimed the fetch would run "concurrently" with the walk;
`oc-session-list` is single-threaded Bun over a **synchronous** `bun:sqlite`, so a
fetch could not have progressed during the walk and the claim would have
degraded silently to serial. It is withdrawn rather than fixed.

**Presence is `EXISTS` in `session_events`, never in `session_reads`.** The query
above groups over the ledger, so a session with no surviving ledger rows produces
no row at all and renders `·`. Deriving presence from `session_reads` (or from
`sessions`) would return `unread: 0` for a session whose ledger has been fully
pruned — reintroducing revision 1's silent zero at a 30-day horizon instead of a
one-hour one. This is the single most important sentence in the document.

**Writes stay an endpoint**, because the daemon owns its DB:

- `POST /sessions/{id}/read` with `{ last_event_id }` → advances the watermark to
  `max(current, incoming)` in one UPSERT with the comparison in SQL, atomic across
  restarts and safe for a session with no row yet.

`?` therefore means "the routing DB is unreadable," which is an outage state the
CLI already understands, rather than a bespoke fetch failure.

## Ordering and rendering

**Groups.** Needs-you pinned on top, then everything else, each by recency
descending.

**The CLI emits the final order** — S6 contract 1, "the CLI OWNS ORDERING… the
picker must not re-sort." The grouping is computed CLI-side, where severity and
the unread data both already are. `model.lua` keeps only its pierce/render role;
the `M.ATTENTION` reference below names the *set*, not the place it is applied.
Citing a Lua table is how an implementation ends up sorting in the picker and
violating the contract.

**Needs-you** comes from the switcher's **existing overlay**, not pigeon's
`pending_questions` — two sources for one signal would eventually disagree
invisibly, and `pending_questions` has a 4h TTL with no error states. It is the
whole `M.ATTENTION` set (`model.lua:50`), i.e. **blocked *and* error**, not
questions only: an error row already pierces facets, so pinning a narrower set
would let pierce and pin disagree.

**Recency key** is the fold's existing tree-max `lastActivity`
(`oc-session-list-fold.ts:176-180`), *not* the session's own `time_updated`.
Revision 1 said `time_updated` and would have regressed a deliberate behaviour:
"a root silent for a day while its subagent worked five seconds ago is a
recently-active tree."

**Four render states**, and the split between the last two is the point:

| Render | Meaning |
|---|---|
| `(3)` | three unread |
| *(no badge)* | read, nothing new |
| `·` | pigeon has no ledger for this session (aged out, or never registered) |
| `?` + warning | the pigeon fetch itself failed — badges are unknown fleet-wide |

Revision 1 collapsed the last two into `?`. That would have made `?` chronic —
pigeon expires sessions at 7d, so every older session would show it permanently —
which trains the eye to ignore the glyph that exists to signal an outage. Outage
is detectable at the *fetch*, not per row, so the two are genuinely different
observations and must look different. The S6 "render `nodata` as loudly as idle"
contract attaches to the outage case.

## Clearing the badge

Two paths, both advancing to a specific id rather than to "now":

1. **A picker jump** advances to the `last_event_id` from the snapshot the picker
   **actually displayed**. Messages that arrive between render and keypress stay
   unread. A stale generation's mark is merely *older*, so `max()` absorbs it and
   the error direction is always "under-clear," which self-heals.
2. **Any inbound user action on the topic** — a reply, a slash command, or a
   **swipe/callback answer on a question card** — advances to that session's
   current max ledger id. Revision 1 said "a reply," which would have missed the
   most common interaction of all: answering a question card is a callback, not a
   reply, so the needs-you pin would clear from the overlay while the badge
   stubbornly contradicted it.

Attaching or focusing a tab deliberately does not clear, keeping the write path
to exactly these two events. A `dir_missing` row is read-only (S6 contract 6), so
a refused selection must not fire a clear.

## Failure modes

| Condition | Behaviour |
|---|---|
| Pigeon daemon down / fetch times out | Picker works exactly as today — unread is strictly additive, and **ordering never depends on the pigeon fetch** (needs-you comes from the overlay, recency from the local fold). Badges render `?` with a warning. ~250 ms timeout, and the fetch runs **concurrently** with the existing CLI walk, which already costs 120-250 ms; serially it would double picker latency. |
| Watermark write fails | The jump happens anyway — never block navigation on bookkeeping. Self-heals at the next clear **for a session you touch again**; a session you never open again keeps a stale badge. Stated plainly rather than claimed as fully self-healing. |
| Ledger row lost (crash between Telegram accept and `markSent`) | That message is never counted. Pre-existing outbox seam; not introduced here. |
| Day one / no backfill | Historical rows are already deleted by the 1h prune, so no backfill is possible. Sessions with no ledger rows render `·`, **not** `0`, and self-heal as events accrue. |
| Ledger fully pruned, watermark survives | Renders `·`. Guaranteed by grouping over `session_events` rather than `session_reads` — see above. This is the path by which revision 1's silent zero could return. |
| Ledger partially pruned below a stale watermark | **Undercount, never a false zero**: surviving rows below the watermark are excluded correctly, and any newer event still counts. Acceptable; recorded so it is not rediscovered as a bug. |
| A session becomes active again long after its ledger aged out | Correct by construction — `AUTOINCREMENT` means new ids are above any stale watermark. |
| Pigeon knows sessions opencode does not | Merge stays a left join on the opencode base list (12 of 185 swarm targets had no local session row). Ignored, not rendered as ghosts. |

## Testing

Ownership follows the code, which revision 1 got wrong in a way this repo has
been actively fighting all week: it put the exclusion and watermark tests in
`pkgs/oc-session-list/test.sh`, but that logic is **pigeon SQL**. Testing it
CLI-side would have exercised a fixture reimplementation while the daemon's real
query drifted free — the mirror-drift defect `workstation-dimz` exists to kill.

- **pigeon daemon suite**, against real sqlite: the read-time exclusion, the
  monotonic `max()` advance (out-of-order, duplicate, missing-row), ledger write
  atomicity with `markSent`, and — the one that matters most — **a fully-pruned
  ledger with a surviving watermark must render `·`, not `0`**.
  Revision 2's test list instead guarded "pruning never lowers an id below a live
  watermark," which `AUTOINCREMENT` makes impossible; it was a test aimed at a
  non-threat while the real one went uncovered.
- **`pkgs/oc-session-list/test.sh`**: merge against the base list, grouping and
  order, degrade to `?` + warning, and the `·` vs `?` distinction.
- **`assets/nvim/test-session-switcher-model.lua`**: the four render states and
  the two groups; the `SEVERITY`/`M.STATES` mirror guard (`model.lua:39-45`) must
  survive the reordering.

Anything needing a live daemon stays out of the nix sandbox (no network) and is
injected as a fixture. **Any new test file must be wired into a `checks.*` entry
or an explicit workflow step**, or `checks.test-reachability` fails CI;
`checkPhase` is not an accepted channel.

## The "all turns" change already shipped — this is downstream of it

Revision 2 described this as a parallel experiment that "may" ship. It **shipped
first**: pigeon `545e65f`, "Show all of a turn's agent narration in Telegram, not
just the final step" (#114, branch `telegram-all-turns`), merged 2026-08-19
10:11 -0400 — from the session launched to explore it.

Two consequences, neither optional:

1. **Multi-chunk entries are now the common case**, which is what forces the
   unit-of-unread statement above.
2. **The 30-day retention figure was reasoned against pre-#114 traffic and is
   therefore unfounded.** Re-measure ledger growth against post-#114 volume
   before fixing it. Rows are metadata-only so growth is unlikely to be the
   binding constraint — the outbox governor's per-minute send budget still is —
   but the number should come from a measurement, not from this sentence.

## Out of scope

- Reading or replying to a session from inside the picker. The picker stays a
  picker.
- A standalone always-on TUI or tmux sidebar. If persistent glance-ability is
  missed later, the cheapest right thing is a tmux status-line aggregate
  (`N unread / M need-you`) off the same endpoint — an addition, not a rehost.
- True bidirectional read sync with Telegram. Pigeon uses the **Bot API**, which
  exposes no read receipts and cannot clear a chat's unread badge; that is an
  MTProto (user-account) capability. The implementable half is kept: an inbound
  action advances our watermark. The two badges remain independent, and that is a
  property of the platform, not a shortcut.
- Any change to the semantic-state model itself.
