# Session switcher unread counts — implementation plan

> **For the implementing agent:** REQUIRED SUB-SKILL: use `superpowers:executing-plans`
> to implement this plan task-by-task.

**Goal:** Show a per-session unread count in the nvim session-switcher picker, ordered
Telegram-style — sessions needing you pinned on top, everything else by recency.

**Architecture:** Pigeon gains a durable `session_events` ledger, written in the same
transaction as `markSent` (so a row exists only if Telegram actually accepted the
message), plus a `session_reads` watermark. `oc-session-list` reads both **directly**
from pigeon's daemon DB — a file it already opens — and emits the final ordering. The
nvim picker renders and, on jump, POSTs the watermark forward.

**Tech stack:** TypeScript, better-sqlite3, vitest (pigeon daemon); TypeScript + Bun
sqlite (`oc-session-list`); Lua (nvim); Nix (`nix flake check`).

**Design:** `docs/plans/2026-08-18-session-switcher-unread-design.md` (revision 3).
Read it first — in particular *why* counting from `outbox` was reversed, since the
whole plan is downstream of that.

---

## Before you start

**Work in a worktree, never a primary checkout.** Both repos are shared by ~15 agent
sessions. `work <slug>` in each repo, or `git worktree add`. Never run
`git pull`/`stash`/`reset`/`checkout <ref>`/`restore`/`clean` in
`/home/dev/projects/{pigeon,workstation}`.

**Two repos, one forced order.** Pigeon must land first: the CLI cannot read a table
that does not exist. Tasks 1-8 are pigeon; 9-12 are workstation.

**Three inherited contracts you must not break** (from `workstation-7w9z`):

1. **The CLI owns ordering.** `model.build` preserves it; the picker must never re-sort.
2. **Branch on `row.attached`, not the facet you asked for.** A pierced row can be
   detached and pane-less.
3. **Surface warnings**, and render `nodata` at least as loudly as idle.

---

## Task 0: Measure post-#114 volume — **DONE**

Completed 2026-08-21; results are in the design doc under "The measured cost". Read
that section before Task 5 — the retention number and its justification both live
there. Summary, so this task is not re-run:

- **#114 did not detectably raise the entry rate** — mechanism (it batches narration
  into an entry that already existed) plus one consistent post-change day.
  Entries/session/day: 2.6–17.1 pre (mean ≈ 9.0), 7.6 on the first full day post. That
  single day cannot rule out a change smaller than ~2x, so **Task 8 re-measures it**
  against the live table.
- **88% of entries are still single-chunk.** The design's "multi-chunk is now the
  common case" was **false** and is struck through there.
- **168.6 bytes/row** including the index — not the ~100 this plan originally assumed.
- Median ~290 entries/day, busiest 940/day.
- **Retention is now `2 * SESSION_TTL_MS` (14d)** — written as a multiple so the two
  numbers move together, which is hygiene, *not* a guarantee. It secures "the ledger
  outlives the session" only for a session whose last activity was a delivery; an
  alive-but-silent session still ages out and renders `·`. No finite constant fixes
  that, and the session-scoped prune that would was rejected (see the design doc — it
  deletes the whole ledger if `sessions` is ever empty). Cost 2.2 MB at the busiest
  rate; 30d would have been 4.5 MB, so cost never discriminated.

Three things the original version of this task got wrong, recorded because each would
have silently produced a wrong number:

1. **There is no `sqlite3` on this host.** Use `bun` with `bun:sqlite` in readonly mode
   (`new Database(path, { readonly: true })`) — the live daemon is writing to that file.
2. **`swarm_messages` is not a proxy for Telegram deliveries.** It is a different
   population; using it is the same mistake that produced revision 1's fabricated
   "6% cancelled".
3. **The right instrument is the daemon's own log line** `outbox entry sent`, which
   fires once per delivered entry in the `allOk` branch — 1:1 with a future ledger row.
   It lives in a **separate journal namespace**: `journalctl --namespace=pigeon`.
   Without that flag the daemon appears to have stopped logging on 12 Aug, which is
   merely when `LogNamespace=pigeon` was added to the unit.

---

## Task 1: `session_events` + `session_reads` schema

**Files:**
- Create: `packages/daemon/src/storage/session-events-schema.ts`
- Test: `packages/daemon/test/session-events-repo.test.ts`

Follow the existing pair convention (`swarm-schema.ts` + `swarm-repo.ts`,
`session-origin-schema.ts` + `session-origin-repo.ts`).

**Step 1: Write the failing test**

```ts
import { describe, expect, it } from "vitest";
import BetterSqlite3 from "better-sqlite3";
import { initSessionEventsSchema } from "../src/storage/session-events-schema";

describe("session events schema", () => {
  it("creates both tables and is idempotent", () => {
    const db = new BetterSqlite3(":memory:");
    initSessionEventsSchema(db);
    initSessionEventsSchema(db); // must not throw
    const names = db
      .prepare("SELECT name FROM sqlite_master WHERE type='table'")
      .all()
      .map((r: any) => r.name);
    expect(names).toContain("session_events");
    expect(names).toContain("session_reads");
  });

  it("never reuses an id after the newest row is deleted", () => {
    const db = new BetterSqlite3(":memory:");
    initSessionEventsSchema(db);
    const ins = db.prepare(
      "INSERT INTO session_events (session_id, notification_id, kind, sent_at) VALUES (?,?,?,?)",
    );
    ins.run("s1", "n1", "stop", 1000);
    const first = db.prepare("SELECT MAX(id) AS id FROM session_events").get() as any;
    db.exec("DELETE FROM session_events");
    ins.run("s1", "n2", "stop", 2000);
    const second = db.prepare("SELECT MAX(id) AS id FROM session_events").get() as any;
    expect(second.id).toBeGreaterThan(first.id);
  });
});
```

The second test is the load-bearing one: it pins `AUTOINCREMENT`. Without it SQLite
reuses `max(existing)+1`, and a pruned id could land *below* a stale watermark and be
silently invisible.

**Step 2: Run it and watch it fail**

```bash
cd packages/daemon && npx vitest run test/session-events-repo.test.ts
```
Expected: FAIL — cannot resolve `session-events-schema`.

**Step 3: Implement**

```ts
import type BetterSqlite3 from "better-sqlite3";
import { SESSION_TTL_MS } from "./schema";

/**
 * Derived from SESSION_TTL_MS, not chosen independently: the ledger must OUTLIVE the
 * session it describes, or a session that is still alive renders as unknown merely
 * because its events aged out. Deriving it keeps that invariant true if the TTL
 * changes. Sized by measurement (design doc, "The measured cost"): 2.2 MB at the
 * busiest day observed.
 */
export const SESSION_EVENTS_RETENTION_MS = 2 * SESSION_TTL_MS; // 14 days

export function initSessionEventsSchema(db: BetterSqlite3.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS session_events (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id      TEXT    NOT NULL,
      notification_id TEXT    NOT NULL,
      kind            TEXT    NOT NULL,
      sent_at         INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_session_events_session
      ON session_events(session_id, id);

    CREATE TABLE IF NOT EXISTS session_reads (
      session_id   TEXT PRIMARY KEY,
      last_read_id INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL
    );
  `);
}
```

`AUTOINCREMENT` is deliberate and must not be "simplified" to a bare
`INTEGER PRIMARY KEY`. Leave the comment saying so.

**Step 4: Verify green, then commit**

```bash
npx vitest run test/session-events-repo.test.ts
git add packages/daemon/src/storage/session-events-schema.ts packages/daemon/test/session-events-repo.test.ts
git commit -m "feat(unread): session_events ledger and session_reads watermark schema"
```

---

## Task 2: Repo — append, count, advance

**Files:**
- Create: `packages/daemon/src/storage/session-events-repo.ts`
- Modify: `packages/daemon/test/session-events-repo.test.ts`

**Step 1: Write the failing tests** (append to the file)

```ts
function seeded() {
  const db = new BetterSqlite3(":memory:");
  initSessionEventsSchema(db);
  return { db, repo: new SessionEventsRepo(db) };
}

it("counts only events above the watermark", () => {
  const { repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "stop", sentAt: 1 });
  const second = repo.append({ sessionId: "s1", notificationId: "n2", kind: "stop", sentAt: 2 });
  repo.advanceRead("s1", second, 100);
  repo.append({ sessionId: "s1", notificationId: "n3", kind: "stop", sentAt: 3 });
  expect(repo.unreadBySession().get("s1")?.unread).toBe(1);
});

it("excludes the user's own mirrored prompts", () => {
  const { repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "mirror", sentAt: 1 });
  repo.append({ sessionId: "s1", notificationId: "n2", kind: "swarm", sentAt: 2 });
  expect(repo.unreadBySession().get("s1")?.unread).toBe(1);
});

it("counts unknown kinds -- topic-visible is the safe default", () => {
  const { repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "something-new", sentAt: 1 });
  expect(repo.unreadBySession().get("s1")?.unread).toBe(1);
});

it("advanceRead is monotonic and absorbs out-of-order and duplicate writes", () => {
  const { repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "stop", sentAt: 1 });
  repo.append({ sessionId: "s1", notificationId: "n2", kind: "stop", sentAt: 2 });
  repo.advanceRead("s1", 2, 100);
  repo.advanceRead("s1", 1, 101); // stale generation
  repo.advanceRead("s1", 2, 102); // duplicate
  expect(repo.unreadBySession().get("s1")?.unread).toBe(0);
  expect(repo.lastReadId("s1")).toBe(2);
});

it("advanceRead works for a session with no row yet", () => {
  const { repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "stop", sentAt: 1 });
  repo.advanceRead("s1", 1, 100);
  expect(repo.unreadBySession().get("s1")?.unread).toBe(0);
});

// THE ONE THAT MATTERS MOST. A fully-pruned ledger with a surviving watermark must
// be ABSENT from the map, so the picker renders it as "unknown" and not as
// "read, nothing new". Returning 0 here is how revision 1's silent zero comes back.
it("a fully-pruned ledger with a surviving watermark is ABSENT, not zero", () => {
  const { db, repo } = seeded();
  repo.append({ sessionId: "s1", notificationId: "n1", kind: "stop", sentAt: 1 });
  repo.advanceRead("s1", 1, 100);
  db.exec("DELETE FROM session_events");
  const map = repo.unreadBySession();
  expect(map.has("s1")).toBe(false);
});
```

**Step 2: Run, watch them fail.**

**Step 3: Implement**

```ts
import type BetterSqlite3 from "better-sqlite3";

export interface AppendInput {
  sessionId: string;
  notificationId: string;
  kind: string;
  sentAt: number;
}

export interface UnreadRow {
  unread: number;
  lastEventId: number;
  lastEventAt: number;
}

export class SessionEventsRepo {
  constructor(private readonly db: BetterSqlite3.Database) {}

  append(input: AppendInput): number {
    const info = this.db
      .prepare(
        `INSERT INTO session_events (session_id, notification_id, kind, sent_at)
         VALUES (?, ?, ?, ?)`,
      )
      .run(input.sessionId, input.notificationId, input.kind, input.sentAt);
    return Number(info.lastInsertRowid);
  }

  /**
   * Grouped over session_events, NOT session_reads. A session whose ledger has been
   * fully pruned must be absent from this map so the caller renders "unknown" rather
   * than "read". Deriving presence from the watermark table reintroduces the silent
   * zero that killed revision 1 of the design.
   */
  unreadBySession(): Map<string, UnreadRow> {
    const rows = this.db
      .prepare(
        `SELECT e.session_id AS sessionId,
                COUNT(*) FILTER (WHERE e.id > COALESCE(r.last_read_id, 0)
                                   AND e.kind <> 'mirror') AS unread,
                MAX(e.id)      AS lastEventId,
                MAX(e.sent_at) AS lastEventAt
         FROM session_events e
         LEFT JOIN session_reads r ON r.session_id = e.session_id
         GROUP BY e.session_id`,
      )
      .all() as any[];
    return new Map(
      rows.map((r) => [
        String(r.sessionId),
        { unread: Number(r.unread), lastEventId: Number(r.lastEventId), lastEventAt: Number(r.lastEventAt) },
      ]),
    );
  }

  /** Monotonic: the comparison is in SQL, so concurrent/retried writes cannot regress it. */
  advanceRead(sessionId: string, lastEventId: number, now: number): void {
    this.db
      .prepare(
        `INSERT INTO session_reads (session_id, last_read_id, updated_at)
         VALUES (?, ?, ?)
         ON CONFLICT(session_id) DO UPDATE SET
           last_read_id = MAX(session_reads.last_read_id, excluded.last_read_id),
           updated_at   = excluded.updated_at`,
      )
      .run(sessionId, lastEventId, now);
  }

  lastReadId(sessionId: string): number {
    const row = this.db
      .prepare("SELECT last_read_id AS id FROM session_reads WHERE session_id = ?")
      .get(sessionId) as any;
    return row ? Number(row.id) : 0;
  }

  pruneOlderThan(cutoff: number): number {
    return this.db
      .prepare("DELETE FROM session_events WHERE sent_at < ?")
      .run(cutoff).changes;
  }
}
```

**Step 4: Green, then commit.**

---

## Task 3: Wire into storage

**Files:** `packages/daemon/src/storage/repos.ts`, `packages/daemon/src/storage/database.ts`

Call `initSessionEventsSchema(db)` where the other `init*Schema` calls happen, and expose
`sessionEvents` on the storage object beside `outbox` and `swarm`. Follow whatever
`swarm` does exactly.

**Verify:** `npx vitest run && npx tsc --noEmit`, then commit.

---

## Task 4: Write the ledger row at the moment of delivery

**Files:**
- Modify: `packages/daemon/src/storage/outbox-repo.ts:137-143`
- Modify: `packages/daemon/src/worker/outbox-sender.ts:617`
- Test: `packages/daemon/test/outbox-sender.test.ts`

This is the heart of the feature: a ledger row exists **only** because Telegram accepted
the message.

**Step 1: Write the failing tests**

```ts
it("records a ledger row when an entry is sent", async () => {
  // ...drive the sender so one entry succeeds...
  const map = storage.sessionEvents.unreadBySession();
  expect(map.get("s1")?.unread).toBe(1);
});

it("does not record a ledger row when a chunk fails", async () => {
  // ...make one chunk fail so allOk is false...
  expect(storage.sessionEvents.unreadBySession().has("s1")).toBe(false);
});

it("markSent is idempotent -- a second call cannot inflate the count", () => {
  storage.outbox.markSent("n1", 1000);
  storage.outbox.markSent("n1", 1001);
  expect(storage.sessionEvents.unreadBySession().get("s1")?.unread).toBe(1);
});
```

**Step 2: Run, watch them fail.**

**Step 3: Implement — guard the update, then append in the same transaction**

`markSent` is currently unguarded and safe only by call-site discipline (one caller,
inside a reentrancy-guarded loop, only when every chunk succeeded). A future second
caller would silently double every count. Guard it:

```ts
markSent(id: string, now = Date.now()): boolean {
  const info = this.db
    .prepare(
      `UPDATE outbox SET state = 'sent', next_retry_at = NULL, updated_at = ?
       WHERE notification_id = ? AND state != 'sent'`,
    )
    .run(now, id);
  return info.changes > 0;
}
```

Then at `outbox-sender.ts:617`, inside `if (allOk)`, wrap both writes in one
transaction so the ledger row and the state transition are atomic:

```ts
if (allOk) {
  this.storage.transaction(() => {
    if (this.storage.outbox.markSent(entry.notificationId, now)) {
      this.storage.sessionEvents.append({
        sessionId: entry.sessionId,
        notificationId: entry.notificationId,
        kind: entry.kind,
        sentAt: now,
      });
      // Log INSIDE the guard, not after the block. This log line is the only
      // instrument that measures delivery volume (Task 0 used it, Task 8 will).
      // Leaving it unconditional while the append is guarded would make the two
      // diverge in exactly the scenario the guard exists for -- a second
      // markSent caller -- and the instrument would silently stop being 1:1
      // with the ledger at the moment it started mattering most.
      this.log("outbox entry sent", { /* ...existing fields... */ });
    }
  });
}
```

If `storage` has no `transaction` helper, use better-sqlite3's `db.transaction(fn)()`
directly; it is synchronous, so this adds no new failure mode.

**Note the one seam, and do not try to fix it here:** `markSent` runs *after* Telegram
accepts, so a crash in between loses the ledger row for a visible message. That is the
outbox's pre-existing at-least-once behaviour.

**Step 4: Green, then commit.**

---

## Task 5: Retention

**Files:** `packages/daemon/src/index.ts` (beside the existing outbox cleanup call),
test in `packages/daemon/test/session-events-repo.test.ts`.

**Step 1: Failing test** — rows older than the cutoff go; newer stay; a surviving
watermark does not resurrect them.

**Step 2-4:** Call `pruneOlderThan(now - SESSION_EVENTS_RETENTION_MS)` on the same
hourly `setInterval` in `index.ts` that calls `cleanupOlderThan`. The constant is
`2 * SESSION_TTL_MS` from Task 1 — do not re-derive or inline a literal here. Commit.

That tick was verified to actually fire (~22.5x/day against a ceiling of 24; 18% of
daemon runs are too short to ever tick). Unlike the swarm cleanup, which spares
`queued` rows, every ledger row is prunable, so the predicate is a bare `sent_at <
cutoff`.

---

## Task 6: `POST /sessions/{id}/read`

**Files:** `packages/daemon/src/app.ts` (beside the existing session routes), test in
`packages/daemon/test/app.test.ts`.

**Step 1: Failing tests**

- advances the watermark and returns 200
- a stale (lower) `last_event_id` is accepted but does not regress the watermark
- a malformed/absent body is a 400, not a 500

**Step 3: Implement.** Body `{ last_event_id: number }`; call
`storage.sessionEvents.advanceRead(id, lastEventId, Date.now())`. There is no auth on
the daemon's loopback surface today; do not invent one here.

**Step 4:** Green, commit.

---

## Task 7: Clear on any inbound user action

**Files:** `packages/daemon/src/app.ts` — the inbound paths (reply, slash command, and
the **callback/swipe answer on a question card**).

**Why all three:** answering a question card is a callback, not a reply. If only replies
cleared, the needs-you pin would clear from the switcher overlay while the badge kept
contradicting it — the most common interaction of all producing the most confusing state.

**Step 1: Failing test** — for each inbound kind, the watermark advances to that
session's current `MAX(id)`.

**Step 3: Implement** a single helper called from all three, advancing to the current
max ledger id for that session.

**Step 4:** Green. Run the whole daemon suite (`npx vitest run`) and `npx tsc --noEmit`.
Commit, open the pigeon PR, and **land it before starting Task 8.**

---

## Task 8: Verify the deployed daemon actually writes rows

Not a code task. After the pigeon PR merges and the daemon restarts:

```bash
# No sqlite3 on this host, and the daemon is writing to this file -- read-only.
bun -e 'import{Database}from"bun:sqlite";
  const db=new Database(process.env.OPENCODE_ROUTING_DB,{readonly:true});
  console.log(db.query("SELECT COUNT(*) n, MAX(sent_at) newest FROM session_events").get());'
```

Expected: a growing count. If it is zero after ten minutes of fleet activity, stop —
Task 4 is not reaching its write point, and everything downstream would be built on an
empty table.

**Then do the re-measurement Task 0 could not.** Task 0's "#114 did not raise the entry
rate" rests on a single post-change day against a pre-range spanning 6.6× — consistent
with the mechanism, but underpowered on its own. This table is the well-powered version
and it costs one query:

```bash
bun -e 'import{Database}from"bun:sqlite";
  const db=new Database(process.env.OPENCODE_ROUTING_DB,{readonly:true});
  console.log(db.query("SELECT date(sent_at/1000,\"unixepoch\") d, COUNT(*) n FROM session_events GROUP BY d ORDER BY d DESC LIMIT 14").all());'
```

Compare against Task 0's median of ~290/day and busiest 940/day. Sustained rates far
above that mean the retention sizing in the design should be revisited — though 940/day
sustained was already priced in at 2.2 MB.

---

## Task 9: `oc-session-list` reads the ledger

**Files:**
- Modify: `assets/opencode/plugins/oc-session-list.ts`
- Test: `test/oc-session-list.spec.ts`

The CLI **already opens pigeon's daemon DB** (`routingDbPath` from
`OPENCODE_ROUTING_DB`, `oc-session-list.ts:21-26`). Reuse it. Do **not** add an HTTP GET,
a timeout, or any concurrency machinery — the walk is synchronous `bun:sqlite`, so a
"concurrent" fetch would silently be serial anyway.

**Step 1: Failing tests**

- a session with events above the watermark reports that count
- `kind='mirror'` rows are excluded
- a session absent from `session_events` reports **unknown**, not `0` (assert on a
  distinct value such as `unread: null`, never `0`)
- the routing DB being unreadable yields a **warning** plus unknown for every row, and
  still returns the base list

**Step 3: Implement.** Run the query from the design against the existing connection,
join onto the base list, and emit `unread`, `lastEventId`, and a presence flag.

**Step 4:** Green (`bun test test/oc-session-list.spec.ts`), commit.

---

## Task 10: Ordering, CLI-side

**Files:** `assets/opencode/plugins/oc-session-list-fold.ts`, same spec file.

**Step 1: Failing tests**

- a row in the attention set (`blocked` **and** `error`, not questions only) sorts above
  every non-attention row regardless of recency
- within each group, ordering is by the fold's existing **tree-max `lastActivity`**
  (`oc-session-list-fold.ts:176-180`) — a parent silent for a day whose subagent worked
  five seconds ago is recent. Do **not** switch to the session's own `time_updated`.
- unread count never affects ordering; it is a badge only

**Step 3: Implement** the two-group ordering here, in the CLI. **Not in `model.lua`** —
contract 1 says the CLI owns ordering and the picker must never re-sort. The design names
`M.ATTENTION` for the *set*; it is applied CLI-side.

**Step 4:** Green, commit.

---

## Task 11: The picker

**Files:**
- Modify: `assets/nvim/lua/user/session_switcher/model.lua`,
  `assets/nvim/lua/user/session_switcher/cli.lua`, and the picker from `workstation-7w9z`
- Test: `assets/nvim/test-session-switcher-model.lua`

**Step 1: Failing tests** — the four render states:

| Render | Meaning |
|---|---|
| `(3)` | three unread |
| *(no badge)* | read, nothing new |
| `·` | no ledger for this session (aged out / never registered) |
| `?` + warning | the routing DB is unreadable — unknown fleet-wide |

`·` and `?` must be distinguishable. `?` is chronic-noise-free precisely because
per-session absence gets its own quieter glyph; collapsing them trains you to ignore the
one that signals an outage.

Also assert: `model.build` **preserves CLI order** (contract 1), and a `dir_missing` row
is read-only so a refused selection fires **no** watermark write.

**Step 3: Implement** rendering, plus on jump: `POST /sessions/{id}/read` with the
`last_event_id` **from the snapshot that was displayed** — never "now". A stale mark is
merely older, and `MAX()` absorbs it, so the error direction is always "under-clear."
The write must be fire-and-forget: never block the jump on it.

**Step 4:** Run `bash assets/nvim/test-session-switcher.sh`, commit.

---

## Task 12: Wire the tests into CI

**Files:** `flake.nix`

Any new test file must be executed by a `checks.*` entry or an explicit workflow step, or
`checks.test-reachability` fails CI. `checkPhase` is **not** an accepted channel.

- Extend the existing `oc-session-list` and session-switcher checks rather than adding
  new ones where possible.
- **Pin the assertion count** in each check you touch (`grep -c '^  PASS: '`), and update
  the pinned number. A suite that runs nothing also prints `ALL PASS`.

**Verify:**

```bash
nix build --no-link .#checks.aarch64-linux.test-reachability
nix build --no-link .#checks.aarch64-linux.<each check you touched>
```

Commit, open the workstation PR, and shepherd it (`shepherding-pull-requests`).

---

## Definition of done

- `session_events` grows on the live daemon (Task 8 verified by query, not by assumption).
- The picker shows counts, pins the attention set, and orders the rest by tree-max recency.
- Jumping clears; answering a question card in Telegram clears.
- A fully-pruned ledger renders `·`, never `0` — there is a named test for this.
- `nix flake check` passes with updated pinned counts.
- The design doc's retention figure is a measured number expressed as a multiple of the
  TTL (`2 * SESSION_TTL_MS`), not "to be re-measured", and the doc is explicit about
  what that does and does not guarantee. **(Done — Task 0.)**
