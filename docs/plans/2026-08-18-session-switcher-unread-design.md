# Session switcher: unread counts and Telegram-shaped ordering — design

**Date:** 2026-08-18
**Status:** Design — approved section by section, ready for implementation planning.
**Repos touched:** `pigeon` (daemon: watermark table + two endpoints), `workstation`
(`pkgs/oc-session-list`, `assets/nvim/lua/user/session_switcher/`)
**Bead:** extends `workstation-7w9z` (S7 / Task 9, the Telescope picker)

## Motivation

`docs/plans/2026-07-12-opencode-session-switcher-design.md` designed the switcher
as a **navigator**: find a session by semantic state, jump to its pane or attach
a TUI. Everything through S6 (PR #295) implements that.

Daily use of the Telegram forum-topic view produced a different opinion about
what the surface should feel like. Telegram is not a navigator — it is a list
you live in, sorted by recency, where a per-conversation **unread count** tells
you where to look. At ~15 concurrent sessions that badge is the thing that makes
the list usable, and the switcher has no equivalent.

This design adds the two Telegram properties to the picker that is already the
epic's next task, and nothing else:

1. **Unread counts** per session.
2. **Recency ordering**, with sessions that need you pinned above it.

It is deliberately *not* a rewrite toward a chat client. The picker stays a
picker; you still jump. Only what it shows and how it sorts changes.

## Scope decisions, and the ones that were rejected

| Decision | Chosen | Rejected alternative |
|---|---|---|
| Surface | The planned nvim Telescope picker (`workstation-7w9z`) | A standalone always-on TUI; a tmux sidebar. Both are new surfaces; the picker already exists and is next in line. |
| What the badge counts | The event set Telegram already shows | Every assistant message (a long autonomous run inflates it to noise); completed turns only; needs-you only. |
| Ordering | Needs-you pinned on top, then `updated_at` desc | Pure recency (a blocked session sinks); unread as primary sort (a chatty session permanently outranks a quiet one that needs you). |
| Read state | Watermark in pigeon's DB, cleared by a picker jump **or** a Telegram reply | Purely local nvim state; explicit mark-read only. |
| Unread source | Pigeon daemon over HTTP | Reading pigeon's SQLite directly from `oc-session-list` — a cross-repo schema coupling with no contract to catch a migration. |

## Two assumptions that were checked and turned out to be false

Both were load-bearing, and both were caught before implementation.

**1. "Reading in Telegram can clear the CLI badge, and vice versa."** This was
the originally-chosen behaviour. It is not implementable. Pigeon talks to
`api.telegram.org/bot${botToken}/…` — the **Bot API**, which exposes no read
receipts: a bot cannot learn that a human read a message, and cannot clear a
chat's unread badge on the user's behalf. Read-state sync across clients is an
MTProto (user-account) capability.

What a bot *can* observe is an action taken in a topic. So the design keeps the
useful half: **a Telegram reply advances the same watermark**, because replying
proves you read it. Telegram's own badge and ours remain independent, and that
is a property of the platform, not a shortcut.

**2. "Outbox rows have a monotonic id to use as the watermark."** They do not.
`outbox.notification_id` is a `TEXT PRIMARY KEY`. SQLite's implicit `rowid` is
monotonic but **`VACUUM` can renumber rowids** on a table whose primary key is
not `INTEGER` — which would silently corrupt every badge, occasionally, in a way
that would take days to attribute.

The watermark is therefore a **composite** `(created_at, notification_id)`
compared lexicographically. No migration to a live high-volume table, exact
tie-breaking, and no dependency on a rowid that can move.

## Architecture

Three components, each owning exactly one thing.

**Pigeon daemon — owns unread truth.** It already owns `outbox`, which *is* the
set of events Telegram shows (stop notifications, questions, swarm messages,
typed prompts), and it is the only writer to that DB. Gains one table and two
endpoints.

**`oc-session-list` — owns ordering and merging.** Unchanged contract from S6:
the CLI orders, `model.build` preserves, and the picker never re-sorts. Gains a
`--with-unread` flag, the pigeon fetch, and the grouping rule.

**The picker — owns rendering and the jump.** Renders the badge, and triggers
the read write on jump.

### Data model

```sql
CREATE TABLE IF NOT EXISTS session_reads (
  session_id               TEXT PRIMARY KEY,
  last_read_at             INTEGER NOT NULL,  -- outbox.created_at
  last_read_notification_id TEXT NOT NULL,    -- tie-break within the same ms
  updated_at               INTEGER NOT NULL
);
```

Unread for a session is the count of `outbox` rows where

```
(created_at, notification_id) > (last_read_at, last_read_notification_id)
```

subject to three exclusions, each load-bearing:

1. **Only rows actually delivered to Telegram.** The outbox has failed and
   cancelled states (the 2026-08-10 visibility design measured 6% cancelled).
   The badge must mirror what is *visible in the topic*, or it promises a
   message that cannot be found.
2. **Not your own messages.** Typed prompts and Telegram replies appear in the
   topic, but in Telegram your own message never makes a chat unread.
3. **Swarm messages do count.** They are genuinely new information, and they are
   the reason a topic can show work with no visible cause.

A session with no rows at all — pigeon has never seen it — is **not** zero. See
rendering.

### Endpoints

- `GET /sessions/unread` → `{ session_id: { unread: int, last_event_at: int } }`
  for all known sessions.
- `POST /sessions/{id}/read` with `{ at, notification_id }` → advances the
  watermark to the **lexicographic max** of current and incoming.

Monotonic advance is what makes two writers safe: the picker jump and the
Telegram reply path may race, arrive out of order, or retry, and the result is
identical.

## Ordering and rendering

**Groups.** Needs-you pinned on top, then everything else, each ordered by
`updated_at` descending.

The needs-you signal comes from the switcher's **existing overlay**, which
already holds authoritative permission/question state — *not* from pigeon's
`pending_questions`. Two sources for one signal would eventually disagree, and
the resulting bug would be invisible.

**Recency key** is the session's own `time_updated`, which `oc-session-list`
already has. Last-outbox-event time is more literally Telegram-faithful, but
sessions pigeon has never seen would then have no sort key and need
special-casing; session time tracks the same reality for every row.

**Three visually distinct states**, and the third is the one that gets lost:

| Render | Meaning |
|---|---|
| `(3)` | three unread |
| *(no badge)* | read, nothing new |
| `?` | pigeon has no data for this session |

`?` inherits an existing contract from S6: render `nodata` at least as loudly as
idle. Folding it into a blank cell makes an outage quieter than the bug it
exists to catch — a dead pigeon daemon must not look like a quiet fleet. It is
also the same "absence is not proof" rule the switcher already applies to
sessions that are undiscoverable because they are in a non-tmux or nested nvim
(`workstation-095u`).

### Clearing the badge

Two events, and only two:

1. **A picker jump** advances the watermark to the highest `(created_at,
   notification_id)` the picker **actually displayed** — not to "now". If three
   messages arrive between render and keypress, clearing to now would silently
   mark as read three messages that were never seen. Clearing to the displayed
   mark leaves them unread, which is correct and self-healing.
2. **A Telegram reply** in the topic advances the same watermark in-process.

Attaching and focusing a tab deliberately do **not** clear it, which keeps the
write path to exactly two well-defined events.

## Failure modes

| Condition | Behaviour |
|---|---|
| Pigeon daemon down | Picker works exactly as today — unread is strictly additive. Badges render `?`; the condition surfaces through the existing warnings channel. ~250 ms timeout on the fetch, degrade rather than hang. The picker owns the generation token because `cli.fetch` has no cancellation. |
| Watermark write fails | The jump happens anyway; never block navigation on a bookkeeping write. Badge stays until the next successful clear. No retry queue — monotonic advance makes a lost write self-healing. |
| Pigeon knows sessions opencode does not | The merge stays a left join on the opencode base list. (The 2026-08-10 measurement found 12 of 185 swarm targets had no local session row.) Ignored rather than rendered as ghosts. |
| Session never registered with pigeon | Renders `?`, not `0`. |

## Testing

The new logic is pure and table-driven, which is where the weight goes.

`pkgs/oc-session-list/test.sh` (extends):

- the three exclusions — undelivered rows do not count, own messages do not
  count, swarm messages do
- lexicographic watermark: ties in `created_at`, out-of-order writes, duplicate
  writes, and that advance is `max`, never backward
- clear-to-displayed-mark: a message arriving between render and jump stays
  unread
- degrade: daemon down → `?` plus a warning, and the jump still works

`assets/nvim/test-session-switcher-model.lua` (extends): grouping and the three
render states.

Anything touching a live daemon stays out of the nix sandbox — there is no
network there — so the daemon is injected as a fixture. **Any new test file must
be wired into a `checks.*` entry or an explicit workflow step**, or
`checks.test-reachability` fails CI; `checkPhase` is not an accepted channel.

## Interaction with the "all completed turns" experiment

A parallel experiment (pigeon session `ses_fe9733ef1ffelsSIiXde56blyy`) is
looking at showing **every** completed agent turn in a topic rather than only the
final stop message, because intermediate turns are currently invisible and get
missed.

That changes what lands in `outbox`, and therefore changes these unread counts
directly. This is coherent — both features read the same "what did I miss" set —
but it means the badge numbers will jump when that experiment ships, and the two
should land in a known order. The volume question belongs to that experiment: the
2026-08-10 design measured swarm traffic alone saturating the outbox governor's
per-minute window budget in bursts, and more rows per turn compounds it.

## Out of scope

- Reading or replying to a session from inside the picker. The picker stays a
  picker; this is the chat-client design, and it is not this.
- A standalone always-on TUI or tmux sidebar.
- True bidirectional read sync with Telegram (needs MTProto; see above).
- Any change to the semantic-state model itself — attention, blocked/working/idle
  are consumed as they are.
