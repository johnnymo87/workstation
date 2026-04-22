# Swarm IPC Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a pigeon-hosted swarm-IPC channel so OpenCode sessions on the same machine can send durable, replayable, optionally broadcast messages to one another, replacing today's racy `opencode-send` → `prompt_async` path.

**Architecture:** Senders POST to `pigeon` daemon (`POST /swarm/send`); daemon persists in its own SQLite (`swarm_messages` table), then a per-target arbiter delivers exactly one message at a time per target session via the existing `OpencodeClient.sendPrompt` (which posts `prompt_async` with the canonical `session.directory` resolved daemon-side). Receiver agents see messages as `<swarm_message v="1" ...>...</swarm_message>` user-message envelopes; they can also call a new `swarm.read` opencode tool for replay.

**Tech Stack:**
- pigeon daemon: TypeScript (Node + tsx), better-sqlite3, vitest, fetch-style HTTP handlers
- pigeon plugin: TypeScript, opencode plugin API
- workstation: Nix (home-manager) for the bash wrappers
- opencode-patched: separate fork; defense-in-depth patch comes AFTER the IPC ships and is its own plan

**See also:**
- Design doc: `docs/plans/2026-04-21-swarm-ipc-design.md`
- ChatGPT consult: `docs/plans/research/2026-04-21-swarm-ipc-design-{question,answer}.md`
- Background race investigation: `docs/plans/2026-04-21-opencode-prefill-fix-design.md`
- Pigeon repo: `~/projects/pigeon` (separate git repo on `johnnymo87/pigeon`)
- Workstation repo: `~/projects/workstation` (this repo, `johnnymo87/workstation`)

---

## Working environment

Tasks 1-12 happen in `~/projects/pigeon` (separate git repo). Tasks 13-15 happen in `~/projects/workstation` (this repo). Task 16 is a manual smoke test on the live cloudbox swarm. Commit per task in the right repo.

For pigeon work, run all commands from `packages/daemon/` unless otherwise noted:

```bash
cd ~/projects/pigeon/packages/daemon
npm test                    # vitest
npm run typecheck           # tsc --noEmit
```

After committing in pigeon, push when the user asks (do NOT auto-deploy; pigeon has a separate deployment flow we don't need to trigger).

For workstation work:

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#cloudbox   # apply wrapper changes
```

---

## Pre-flight (do once before Task 1)

Verify the working tree:

```bash
cd ~/projects/pigeon && git status && git log -1 --oneline
cd ~/projects/workstation && git status && git log -1 --oneline
```

Both should be clean and on `main`. If not, stash or commit first.

Verify pigeon tests pass at HEAD before we start:

```bash
cd ~/projects/pigeon/packages/daemon && npm test 2>&1 | tail -10
```

Expected: all green.

---

## Task 1: Add `swarm_messages` table + repository (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/daemon/src/storage/swarm-schema.ts`
- Modify: `packages/daemon/src/storage/database.ts` (call `initSwarmSchema(db)` from `openStorageDb`, expose `storage.swarm` repository)
- Create: `packages/daemon/src/storage/swarm-repo.ts`
- Test: `packages/daemon/test/swarm-repo.test.ts`

**Step 1: Write the failing test**

Create `packages/daemon/test/swarm-repo.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import { openStorageDb, type StorageDb } from "../src/storage/database";

function createStorage(): StorageDb {
  return openStorageDb(":memory:");
}

const BASE = {
  msgId: "msg_01h1",
  fromSession: "ses_a",
  toSession: "ses_b",
  channel: null as string | null,
  kind: "chat",
  priority: "normal" as const,
  replyTo: null as string | null,
  payload: "hello",
};

describe("SwarmRepository", () => {
  it("inserts and retrieves a message", () => {
    const s = createStorage();
    s.swarm.insert(BASE, 1_000);
    const m = s.swarm.getByMsgId("msg_01h1");
    expect(m).not.toBeNull();
    expect(m!.toSession).toBe("ses_b");
    expect(m!.state).toBe("queued");
    expect(m!.attempts).toBe(0);
    expect(m!.createdAt).toBe(1_000);
    s.db.close();
  });

  it("is idempotent on duplicate msgId", () => {
    const s = createStorage();
    s.swarm.insert(BASE, 1_000);
    s.swarm.insert({ ...BASE, payload: "different" }, 2_000);
    const m = s.swarm.getByMsgId("msg_01h1");
    expect(m!.payload).toBe("hello");
    expect(m!.createdAt).toBe(1_000);
    s.db.close();
  });

  it("returns ready messages for a target in createdAt order", () => {
    const s = createStorage();
    s.swarm.insert({ ...BASE, msgId: "m1" }, 1_000);
    s.swarm.insert({ ...BASE, msgId: "m2" }, 2_000);
    s.swarm.insert({ ...BASE, msgId: "m3", toSession: "ses_other" }, 3_000);
    const ready = s.swarm.getReadyForTarget("ses_b", 5_000);
    expect(ready.map((m) => m.msgId)).toEqual(["m1", "m2"]);
    s.db.close();
  });

  it("excludes already-handed-off messages from getReady", () => {
    const s = createStorage();
    s.swarm.insert(BASE, 1_000);
    s.swarm.markHandedOff("msg_01h1", 2_000);
    const ready = s.swarm.getReadyForTarget("ses_b", 5_000);
    expect(ready).toHaveLength(0);
    s.db.close();
  });

  it("respects next_retry_at for queued retries", () => {
    const s = createStorage();
    s.swarm.insert(BASE, 1_000);
    s.swarm.markRetry("msg_01h1", 1_500, 10_000);  // retry at 11_500
    expect(s.swarm.getReadyForTarget("ses_b", 11_000)).toHaveLength(0);
    expect(s.swarm.getReadyForTarget("ses_b", 11_500)).toHaveLength(1);
    s.db.close();
  });

  it("getInbox returns delivered messages for a session, ordered ascending", () => {
    const s = createStorage();
    s.swarm.insert({ ...BASE, msgId: "m1" }, 1_000);
    s.swarm.insert({ ...BASE, msgId: "m2" }, 2_000);
    s.swarm.markHandedOff("m1", 1_500);
    s.swarm.markHandedOff("m2", 2_500);
    const inbox = s.swarm.getInbox("ses_b", null);
    expect(inbox.map((m) => m.msgId)).toEqual(["m1", "m2"]);
    const since = s.swarm.getInbox("ses_b", "m1");
    expect(since.map((m) => m.msgId)).toEqual(["m2"]);
    s.db.close();
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-repo 2>&1 | tail -15
```
Expected: import error or `s.swarm` is undefined.

**Step 3: Implement schema**

Create `packages/daemon/src/storage/swarm-schema.ts`:

```ts
import type BetterSqlite3 from "better-sqlite3";

export const SWARM_RETENTION_MS = 7 * 24 * 60 * 60 * 1000; // 7 days

export function initSwarmSchema(db: BetterSqlite3.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS swarm_messages (
      msg_id TEXT PRIMARY KEY,
      from_session TEXT NOT NULL,
      to_session TEXT,
      channel TEXT,
      kind TEXT NOT NULL,
      priority TEXT NOT NULL DEFAULT 'normal',
      reply_to TEXT,
      payload TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'queued',
      attempts INTEGER NOT NULL DEFAULT 0,
      next_retry_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      handed_off_at INTEGER
    );

    CREATE INDEX IF NOT EXISTS idx_swarm_target_state
      ON swarm_messages(to_session, state, next_retry_at, created_at);
    CREATE INDEX IF NOT EXISTS idx_swarm_inbox
      ON swarm_messages(to_session, state, msg_id);
    CREATE INDEX IF NOT EXISTS idx_swarm_channel
      ON swarm_messages(channel, state, created_at);
  `);
}
```

**Step 4: Implement repository**

Create `packages/daemon/src/storage/swarm-repo.ts`:

```ts
import type BetterSqlite3 from "better-sqlite3";

type Row = Record<string, unknown>;

export type Priority = "urgent" | "normal" | "low";

export interface SwarmMessageRecord {
  msgId: string;
  fromSession: string;
  toSession: string | null;
  channel: string | null;
  kind: string;
  priority: Priority;
  replyTo: string | null;
  payload: string;
  state: "queued" | "handed_off" | "failed";
  attempts: number;
  nextRetryAt: number | null;
  createdAt: number;
  updatedAt: number;
  handedOffAt: number | null;
}

export interface InsertSwarmInput {
  msgId: string;
  fromSession: string;
  toSession: string | null;
  channel: string | null;
  kind: string;
  priority: Priority;
  replyTo: string | null;
  payload: string;
}

function asRecord(row: Row): SwarmMessageRecord {
  return {
    msgId: String(row.msg_id),
    fromSession: String(row.from_session),
    toSession: (row.to_session as string | null) ?? null,
    channel: (row.channel as string | null) ?? null,
    kind: String(row.kind),
    priority: String(row.priority) as Priority,
    replyTo: (row.reply_to as string | null) ?? null,
    payload: String(row.payload),
    state: String(row.state) as SwarmMessageRecord["state"],
    attempts: Number(row.attempts),
    nextRetryAt: (row.next_retry_at as number | null) ?? null,
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
    handedOffAt: (row.handed_off_at as number | null) ?? null,
  };
}

export class SwarmRepository {
  constructor(private readonly db: BetterSqlite3.Database) {}

  insert(input: InsertSwarmInput, now = Date.now()): void {
    this.db
      .prepare(
        `INSERT INTO swarm_messages
           (msg_id, from_session, to_session, channel, kind, priority, reply_to, payload,
            state, attempts, next_retry_at, created_at, updated_at, handed_off_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, NULL, ?, ?, NULL)
         ON CONFLICT(msg_id) DO NOTHING`,
      )
      .run(
        input.msgId,
        input.fromSession,
        input.toSession,
        input.channel,
        input.kind,
        input.priority,
        input.replyTo,
        input.payload,
        now,
        now,
      );
  }

  getByMsgId(msgId: string): SwarmMessageRecord | null {
    const row = this.db
      .prepare("SELECT * FROM swarm_messages WHERE msg_id = ?")
      .get(msgId) as Row | null;
    return row ? asRecord(row) : null;
  }

  getReadyForTarget(toSession: string, now: number, limit = 1): SwarmMessageRecord[] {
    const rows = this.db
      .prepare(
        `SELECT * FROM swarm_messages
         WHERE to_session = ?
           AND state = 'queued'
           AND (next_retry_at IS NULL OR next_retry_at <= ?)
         ORDER BY created_at ASC
         LIMIT ?`,
      )
      .all(toSession, now, limit) as Row[];
    return rows.map(asRecord);
  }

  listTargetsWithReady(now: number): string[] {
    const rows = this.db
      .prepare(
        `SELECT DISTINCT to_session
         FROM swarm_messages
         WHERE state = 'queued'
           AND to_session IS NOT NULL
           AND (next_retry_at IS NULL OR next_retry_at <= ?)`,
      )
      .all(now) as Array<{ to_session: string }>;
    return rows.map((r) => r.to_session);
  }

  markHandedOff(msgId: string, now = Date.now()): void {
    this.db
      .prepare(
        `UPDATE swarm_messages
         SET state = 'handed_off', handed_off_at = ?, updated_at = ?, next_retry_at = NULL
         WHERE msg_id = ?`,
      )
      .run(now, now, msgId);
  }

  markRetry(msgId: string, now: number, backoffMs: number): void {
    this.db
      .prepare(
        `UPDATE swarm_messages
         SET attempts = attempts + 1, next_retry_at = ?, updated_at = ?, state = 'queued'
         WHERE msg_id = ?`,
      )
      .run(now + backoffMs, now, msgId);
  }

  markFailed(msgId: string, now = Date.now()): void {
    this.db
      .prepare(
        `UPDATE swarm_messages
         SET state = 'failed', updated_at = ?, next_retry_at = NULL
         WHERE msg_id = ?`,
      )
      .run(now, msgId);
  }

  getInbox(toSession: string, sinceMsgId: string | null): SwarmMessageRecord[] {
    if (sinceMsgId === null) {
      const rows = this.db
        .prepare(
          `SELECT * FROM swarm_messages
           WHERE to_session = ? AND state = 'handed_off'
           ORDER BY msg_id ASC`,
        )
        .all(toSession) as Row[];
      return rows.map(asRecord);
    }
    const rows = this.db
      .prepare(
        `SELECT * FROM swarm_messages
         WHERE to_session = ? AND state = 'handed_off' AND msg_id > ?
         ORDER BY msg_id ASC`,
      )
      .all(toSession, sinceMsgId) as Row[];
    return rows.map(asRecord);
  }

  cleanupOlderThan(cutoff: number): number {
    const result = this.db
      .prepare(
        `DELETE FROM swarm_messages
         WHERE state IN ('handed_off', 'failed') AND updated_at < ?`,
      )
      .run(cutoff);
    return result.changes;
  }
}
```

**Step 5: Wire into `database.ts`**

Modify `packages/daemon/src/storage/database.ts`:

```ts
// near the top, add:
import { initSwarmSchema } from "./swarm-schema";
import { SwarmRepository } from "./swarm-repo";

// in the StorageDb interface, add:
//   swarm: SwarmRepository;

// in openStorageDb (or whichever function calls initSchema), add after initSchema(db):
initSwarmSchema(db);

// where the other repositories are constructed, add:
//   swarm: new SwarmRepository(db),
```

(Read the existing `database.ts` first to mirror its exact pattern; the exact wiring depends on whether it uses an interface vs class.)

**Step 6: Run test to verify it passes**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-repo 2>&1 | tail -15
npm run typecheck 2>&1 | tail -10
```
Expected: all green, no type errors.

**Step 7: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/storage/swarm-schema.ts \
        packages/daemon/src/storage/swarm-repo.ts \
        packages/daemon/src/storage/database.ts \
        packages/daemon/test/swarm-repo.test.ts
git commit -m "feat(swarm): add swarm_messages SQLite table + repository

First piece of the pigeon-hosted swarm IPC channel. Adds a separate
schema file (initSwarmSchema) and a SwarmRepository keyed by msgId
with per-target ready-set semantics, retry/backoff state, and a
cursor-based getInbox for replay.

Schema is intentionally separate from the existing Telegram outbox
table so swarm stays a first-class subsystem (per the design doc:
docs/plans/2026-04-21-swarm-ipc-design.md, refinement #1)."
```

---

## Task 2: XML envelope serializer (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/daemon/src/swarm/envelope.ts`
- Test: `packages/daemon/test/swarm-envelope.test.ts`

**Step 1: Write the failing test**

Create `packages/daemon/test/swarm-envelope.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { renderEnvelope, type EnvelopeFields } from "../src/swarm/envelope";

const FIELDS: EnvelopeFields = {
  v: "1",
  kind: "task.assign",
  from: "ses_a",
  to: "ses_b",
  channel: null,
  msgId: "msg_01h",
  replyTo: null,
  priority: "normal",
};

describe("renderEnvelope", () => {
  it("renders a minimal envelope with text payload", () => {
    const out = renderEnvelope(FIELDS, "hello world");
    expect(out).toContain('<swarm_message');
    expect(out).toContain('v="1"');
    expect(out).toContain('kind="task.assign"');
    expect(out).toContain('from="ses_a"');
    expect(out).toContain('to="ses_b"');
    expect(out).toContain('msg_id="msg_01h"');
    expect(out).toContain('priority="normal"');
    expect(out).toContain("hello world");
    expect(out).toContain("</swarm_message>");
  });

  it("includes channel when set", () => {
    const out = renderEnvelope({ ...FIELDS, to: null, channel: "workers" }, "hi");
    expect(out).toContain('channel="workers"');
    expect(out).not.toContain('to=""');
  });

  it("includes replyTo when set", () => {
    const out = renderEnvelope({ ...FIELDS, replyTo: "msg_prev" }, "hi");
    expect(out).toContain('reply_to="msg_prev"');
  });

  it("escapes attribute values", () => {
    const out = renderEnvelope({ ...FIELDS, kind: 'has"quote' }, "hi");
    expect(out).toContain('kind="has&quot;quote"');
  });

  it("preserves payload exactly (no XML escaping in body)", () => {
    // We choose NOT to XML-escape the body because LLMs read it as
    // free text and over-escaping (`&amp;` instead of `&`) hurts
    // legibility. The receiver agent reads the body as everything
    // between the open and close tags.
    const payload = "raw <html> & ' \" stuff";
    const out = renderEnvelope(FIELDS, payload);
    expect(out).toContain(payload);
  });

  it("rejects payloads containing the close tag", () => {
    expect(() => renderEnvelope(FIELDS, "evil </swarm_message> bypass")).toThrow();
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd ~/projects/pigeon/packages/daemon && npm test -- swarm-envelope 2>&1 | tail -10
```
Expected: import error.

**Step 3: Implement**

Create `packages/daemon/src/swarm/envelope.ts`:

```ts
export type Priority = "urgent" | "normal" | "low";

export interface EnvelopeFields {
  v: string;
  kind: string;
  from: string;
  to: string | null;
  channel: string | null;
  msgId: string;
  replyTo: string | null;
  priority: Priority;
}

function escAttr(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

const CLOSE_TAG = "</swarm_message>";

export function renderEnvelope(fields: EnvelopeFields, payload: string): string {
  if (payload.includes(CLOSE_TAG)) {
    throw new Error("payload must not contain the literal close tag");
  }

  const attrs: string[] = [
    `v="${escAttr(fields.v)}"`,
    `kind="${escAttr(fields.kind)}"`,
    `from="${escAttr(fields.from)}"`,
  ];
  if (fields.to !== null) attrs.push(`to="${escAttr(fields.to)}"`);
  if (fields.channel !== null) attrs.push(`channel="${escAttr(fields.channel)}"`);
  attrs.push(`msg_id="${escAttr(fields.msgId)}"`);
  if (fields.replyTo !== null) attrs.push(`reply_to="${escAttr(fields.replyTo)}"`);
  attrs.push(`priority="${escAttr(fields.priority)}"`);

  return `<swarm_message ${attrs.join(" ")}>\n${payload}\n${CLOSE_TAG}`;
}
```

**Step 4: Run test to verify it passes**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-envelope 2>&1 | tail -10
npm run typecheck 2>&1 | tail -5
```
Expected: green.

**Step 5: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/swarm/envelope.ts packages/daemon/test/swarm-envelope.test.ts
git commit -m "feat(swarm): XML envelope serializer for in-transcript routing fields

Receivers see swarm messages as user-message bodies in their transcript.
The envelope wraps the payload in <swarm_message v=\"1\" ...> so agents
can recognize and parse routing fields (sender, msg_id, reply_to, etc.)
before reasoning over the payload.

Attribute values are XML-escaped; payload body is intentionally NOT
escaped (LLMs read it as free text). Payload must not contain the
literal close tag — checked explicitly to prevent envelope smuggling."
```

---

## Task 3: Session→directory registry (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/daemon/src/swarm/registry.ts`
- Test: `packages/daemon/test/swarm-registry.test.ts`

**Step 1: Write the failing test**

Create `packages/daemon/test/swarm-registry.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import { SessionDirectoryRegistry } from "../src/swarm/registry";

function fakeFetch(responses: Array<Response | Error>) {
  let i = 0;
  return vi.fn(async (..._args: unknown[]) => {
    const r = responses[i++];
    if (!r) throw new Error("unexpected fetch call");
    if (r instanceof Error) throw r;
    return r;
  });
}

describe("SessionDirectoryRegistry", () => {
  it("fetches and caches session.directory", async () => {
    const fetchFn = fakeFetch([
      new Response(JSON.stringify({ id: "ses_a", directory: "/home/dev/projects/mono" }), { status: 200 }),
    ]);
    const reg = new SessionDirectoryRegistry({
      baseUrl: "http://x",
      ttlMs: 60_000,
      fetchFn,
      nowFn: () => 1_000,
    });

    const dir1 = await reg.resolve("ses_a");
    const dir2 = await reg.resolve("ses_a");
    expect(dir1).toBe("/home/dev/projects/mono");
    expect(dir2).toBe("/home/dev/projects/mono");
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });

  it("refetches after TTL", async () => {
    const fetchFn = fakeFetch([
      new Response(JSON.stringify({ id: "ses_a", directory: "/old" }), { status: 200 }),
      new Response(JSON.stringify({ id: "ses_a", directory: "/new" }), { status: 200 }),
    ]);
    let now = 1_000;
    const reg = new SessionDirectoryRegistry({
      baseUrl: "http://x",
      ttlMs: 5_000,
      fetchFn,
      nowFn: () => now,
    });
    expect(await reg.resolve("ses_a")).toBe("/old");
    now = 10_000;  // past TTL
    expect(await reg.resolve("ses_a")).toBe("/new");
  });

  it("throws on 404 (and does not cache the failure)", async () => {
    const fetchFn = fakeFetch([
      new Response("not found", { status: 404 }),
      new Response(JSON.stringify({ id: "ses_a", directory: "/d" }), { status: 200 }),
    ]);
    const reg = new SessionDirectoryRegistry({
      baseUrl: "http://x",
      ttlMs: 60_000,
      fetchFn,
      nowFn: () => 1_000,
    });
    await expect(reg.resolve("ses_a")).rejects.toThrow(/404|not found/i);
    expect(await reg.resolve("ses_a")).toBe("/d");  // recovers
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd ~/projects/pigeon/packages/daemon && npm test -- swarm-registry 2>&1 | tail -10
```
Expected: import error.

**Step 3: Implement**

Create `packages/daemon/src/swarm/registry.ts`:

```ts
export interface RegistryOptions {
  baseUrl: string;            // opencode serve base, e.g. http://127.0.0.1:4096
  ttlMs: number;
  fetchFn?: typeof fetch;
  nowFn?: () => number;
}

interface CacheEntry {
  directory: string;
  expiresAt: number;
}

export class SessionDirectoryRegistry {
  private readonly baseUrl: string;
  private readonly ttlMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly nowFn: () => number;
  private readonly cache = new Map<string, CacheEntry>();

  constructor(opts: RegistryOptions) {
    this.baseUrl = opts.baseUrl.replace(/\/$/, "");
    this.ttlMs = opts.ttlMs;
    this.fetchFn = opts.fetchFn ?? fetch;
    this.nowFn = opts.nowFn ?? (() => Date.now());
  }

  async resolve(sessionId: string): Promise<string> {
    const now = this.nowFn();
    const hit = this.cache.get(sessionId);
    if (hit && hit.expiresAt > now) return hit.directory;

    const res = await this.fetchFn(`${this.baseUrl}/session/${encodeURIComponent(sessionId)}`, {
      method: "GET",
    });
    if (!res.ok) {
      throw new Error(`session lookup failed: ${res.status} ${await res.text()}`);
    }
    const body = (await res.json()) as { id?: string; directory?: string };
    if (!body.directory) {
      throw new Error(`session response missing directory: ${JSON.stringify(body)}`);
    }
    this.cache.set(sessionId, { directory: body.directory, expiresAt: now + this.ttlMs });
    return body.directory;
  }

  invalidate(sessionId: string): void {
    this.cache.delete(sessionId);
  }
}
```

**Step 4: Run test + typecheck**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-registry 2>&1 | tail -10
npm run typecheck 2>&1 | tail -5
```

**Step 5: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/swarm/registry.ts packages/daemon/test/swarm-registry.test.ts
git commit -m "feat(swarm): canonical session->directory resolver with TTL cache

Resolves session_id -> directory by hitting opencode serve once and
caching for 5 minutes (configurable). The arbiter uses this to set
x-opencode-directory canonically per target session, so all
swarm-routed prompt_async requests for a given session land in the
same Instance context. This is the precondition that lets the
single-writer arbiter actually fix the prefill race architecturally.

Failures (404, network errors) do NOT cache — caller can retry."
```

---

## Task 4: Per-target arbiter (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/daemon/src/swarm/arbiter.ts`
- Test: `packages/daemon/test/swarm-arbiter.test.ts`

The arbiter ensures at most one in-flight `prompt_async` per target
session id at a time, using the SwarmRepository as the durable
queue. It composes:
1. SwarmRepository (state)
2. SessionDirectoryRegistry (canonical directory)
3. Envelope renderer (wire format)
4. OpencodeClient.sendPrompt (delivery transport)

**Step 1: Write the failing test**

Create `packages/daemon/test/swarm-arbiter.test.ts`:

```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { openStorageDb, type StorageDb } from "../src/storage/database";
import { SwarmArbiter } from "../src/swarm/arbiter";

interface DeliveryCall {
  sessionId: string;
  directory: string;
  prompt: string;
  at: number;
}

function makeFixture() {
  const storage: StorageDb = openStorageDb(":memory:");
  const calls: DeliveryCall[] = [];
  let now = 1_000;
  let inFlightDelay = 0;
  let throwOnce: Error | null = null;

  const opencodeClient = {
    sendPrompt: vi.fn(async (sessionId: string, directory: string, prompt: string) => {
      const startedAt = now;
      if (throwOnce) {
        const e = throwOnce; throwOnce = null;
        throw e;
      }
      // Simulate the call taking time so concurrent calls would overlap
      // if the arbiter were broken.
      if (inFlightDelay > 0) {
        await new Promise((r) => setTimeout(r, inFlightDelay));
      }
      calls.push({ sessionId, directory, prompt, at: startedAt });
    }),
  };

  const registry = {
    resolve: vi.fn(async (sessionId: string) => `/dir/${sessionId}`),
  };

  const arbiter = new SwarmArbiter({
    storage,
    opencodeClient: opencodeClient as any,
    registry: registry as any,
    nowFn: () => now,
  });

  return {
    storage,
    arbiter,
    opencodeClient,
    registry,
    calls,
    setNow(v: number) { now = v; },
    setInFlightDelay(v: number) { inFlightDelay = v; },
    setThrowOnce(e: Error) { throwOnce = e; },
  };
}

describe("SwarmArbiter", () => {
  let fixture: ReturnType<typeof makeFixture> | null = null;

  afterEach(() => {
    fixture?.storage.db.close();
    fixture = null;
  });

  it("delivers a single queued message and marks it handed_off", async () => {
    fixture = makeFixture();
    const { storage, arbiter, calls } = fixture;

    storage.swarm.insert({
      msgId: "m1",
      fromSession: "ses_a",
      toSession: "ses_b",
      channel: null,
      kind: "chat",
      priority: "normal",
      replyTo: null,
      payload: "hi",
    }, 1_000);

    await arbiter.processOnce();

    expect(calls).toHaveLength(1);
    expect(calls[0].sessionId).toBe("ses_b");
    expect(calls[0].directory).toBe("/dir/ses_b");
    expect(calls[0].prompt).toContain("<swarm_message");
    expect(calls[0].prompt).toContain("hi");

    expect(storage.swarm.getByMsgId("m1")!.state).toBe("handed_off");
  });

  it("serializes deliveries per target — never two in flight at once", async () => {
    fixture = makeFixture();
    const { storage, arbiter, calls } = fixture;

    fixture.setInFlightDelay(20);
    for (let i = 1; i <= 4; i++) {
      storage.swarm.insert({
        msgId: `m${i}`,
        fromSession: `ses_caller_${i}`,
        toSession: "ses_b",
        channel: null,
        kind: "chat",
        priority: "normal",
        replyTo: null,
        payload: `payload-${i}`,
      }, 1_000 + i);
    }

    // Run processOnce concurrently 4x; the arbiter must internally serialize
    // per-target so we end up with 4 sequential calls (NOT 4 in flight).
    await Promise.all([
      arbiter.processOnce(),
      arbiter.processOnce(),
      arbiter.processOnce(),
      arbiter.processOnce(),
    ]);

    expect(calls).toHaveLength(4);
    // Verify createdAt order
    expect(calls.map((c) => c.prompt.match(/payload-\d+/)?.[0])).toEqual([
      "payload-1", "payload-2", "payload-3", "payload-4",
    ]);
  });

  it("retries on opencode 5xx with backoff", async () => {
    fixture = makeFixture();
    const { storage, arbiter } = fixture;

    storage.swarm.insert({
      msgId: "m1",
      fromSession: "ses_a",
      toSession: "ses_b",
      channel: null,
      kind: "chat",
      priority: "normal",
      replyTo: null,
      payload: "hi",
    }, 1_000);

    fixture.setThrowOnce(new Error("sendPrompt failed: 500"));
    await arbiter.processOnce();

    const after = storage.swarm.getByMsgId("m1")!;
    expect(after.state).toBe("queued");
    expect(after.attempts).toBe(1);
    expect(after.nextRetryAt).not.toBeNull();
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd ~/projects/pigeon/packages/daemon && npm test -- swarm-arbiter 2>&1 | tail -10
```
Expected: import error.

**Step 3: Implement**

Create `packages/daemon/src/swarm/arbiter.ts`:

```ts
import type { StorageDb } from "../storage/database";
import type { OpencodeClient } from "../opencode-client";
import type { SessionDirectoryRegistry } from "./registry";
import { renderEnvelope } from "./envelope";

export interface ArbiterOptions {
  storage: StorageDb;
  opencodeClient: OpencodeClient;
  registry: SessionDirectoryRegistry;
  nowFn?: () => number;
  log?: (msg: string, fields?: Record<string, unknown>) => void;
}

const MAX_ATTEMPTS = 10;
const BACKOFF_SCHEDULE = [1_000, 2_000, 5_000, 15_000, 60_000];

function backoffFor(attempts: number): number {
  return BACKOFF_SCHEDULE[Math.min(attempts, BACKOFF_SCHEDULE.length - 1)] ?? 60_000;
}

export class SwarmArbiter {
  private readonly storage: StorageDb;
  private readonly opencodeClient: OpencodeClient;
  private readonly registry: SessionDirectoryRegistry;
  private readonly nowFn: () => number;
  private readonly log: (msg: string, fields?: Record<string, unknown>) => void;

  // One in-flight promise per target session — collapses concurrent processOnce
  // calls into a single per-target queue.
  private readonly inflight = new Map<string, Promise<void>>();

  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(opts: ArbiterOptions) {
    this.storage = opts.storage;
    this.opencodeClient = opts.opencodeClient;
    this.registry = opts.registry;
    this.nowFn = opts.nowFn ?? (() => Date.now());
    this.log = opts.log ?? ((m, f) => console.log(`[swarm-arbiter] ${m}`, f ?? ""));
  }

  start(intervalMs = 500): void {
    this.timer = setInterval(() => { void this.processOnce(); }, intervalMs);
  }

  stop(): void {
    if (this.timer) { clearInterval(this.timer); this.timer = null; }
  }

  async processOnce(): Promise<void> {
    const now = this.nowFn();
    const targets = this.storage.swarm.listTargetsWithReady(now);
    await Promise.all(targets.map((t) => this.drainTarget(t)));
  }

  private async drainTarget(target: string): Promise<void> {
    const existing = this.inflight.get(target);
    if (existing) {
      await existing;
      return;
    }
    const work = this.drainTargetInner(target).finally(() => this.inflight.delete(target));
    this.inflight.set(target, work);
    return work;
  }

  private async drainTargetInner(target: string): Promise<void> {
    while (true) {
      const now = this.nowFn();
      const next = this.storage.swarm.getReadyForTarget(target, now, 1)[0];
      if (!next) return;

      try {
        const directory = await this.registry.resolve(target);
        const prompt = renderEnvelope(
          {
            v: "1",
            kind: next.kind,
            from: next.fromSession,
            to: next.toSession,
            channel: next.channel,
            msgId: next.msgId,
            replyTo: next.replyTo,
            priority: next.priority,
          },
          next.payload,
        );
        await this.opencodeClient.sendPrompt(target, directory, prompt);
        this.storage.swarm.markHandedOff(next.msgId, this.nowFn());
        this.log("delivered", { msgId: next.msgId, target });
      } catch (err) {
        const after = this.storage.swarm.getByMsgId(next.msgId);
        const attempts = (after?.attempts ?? 0) + 1;
        if (attempts >= MAX_ATTEMPTS) {
          this.storage.swarm.markFailed(next.msgId, this.nowFn());
          this.log("failed (max attempts)", { msgId: next.msgId, error: String(err) });
        } else {
          this.storage.swarm.markRetry(next.msgId, this.nowFn(), backoffFor(attempts));
          this.log("retry scheduled", { msgId: next.msgId, attempts, error: String(err) });
        }
        return;  // stop draining this target until next tick
      }
    }
  }
}
```

**Step 4: Run test + typecheck**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-arbiter 2>&1 | tail -10
npm run typecheck 2>&1 | tail -5
```

**Step 5: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/swarm/arbiter.ts packages/daemon/test/swarm-arbiter.test.ts
git commit -m "feat(swarm): per-target arbiter with at-most-one in-flight delivery

The arbiter is the architectural fix for the prompt_async race: for any
given target session, at most one prompt_async call is in flight at any
moment. Concurrent processOnce calls collapse via per-target inflight
promise tracking; the directory used per call comes from the canonical
session->directory registry, never from the original sender.

Retry schedule: [1s, 2s, 5s, 15s, 60s] capped at 10 attempts. Failures
mark the row 'failed' and the arbiter moves on."
```

---

## Task 5: HTTP routes — `POST /swarm/send` and `GET /swarm/inbox` (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Modify: `packages/daemon/src/app.ts` (add two route handlers)
- Test: `packages/daemon/test/swarm-routes.test.ts`

**Step 1: Read the existing app.ts pattern first**

Read `packages/daemon/src/app.ts` lines 92-200 to see the
pattern for adding routes (it's a flat fetch-style handler, not
Hono — match the existing style).

**Step 2: Write the failing test**

Create `packages/daemon/test/swarm-routes.test.ts`:

```ts
import { afterEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { openStorageDb, type StorageDb } from "../src/storage/database";

describe("POST /swarm/send", () => {
  let storage: StorageDb | null = null;

  afterEach(() => {
    if (storage) { storage.db.close(); storage = null; }
  });

  function newApp(now = 1_000) {
    storage = openStorageDb(":memory:");
    return { app: createApp(storage, { nowFn: () => now }), storage };
  }

  it("returns 202 and persists a swarm message", async () => {
    const { app, storage: s } = newApp();
    const res = await app(new Request("http://localhost/swarm/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        from: "ses_a",
        to: "ses_b",
        kind: "chat",
        priority: "normal",
        payload: "hello",
      }),
    }));
    expect(res.status).toBe(202);
    const body = await res.json() as { accepted: boolean; msg_id: string };
    expect(body.accepted).toBe(true);
    expect(body.msg_id).toMatch(/^msg_/);

    const stored = s.swarm.getByMsgId(body.msg_id);
    expect(stored).not.toBeNull();
    expect(stored!.payload).toBe("hello");
  });

  it("respects caller-supplied msg_id (idempotency)", async () => {
    const { app, storage: s } = newApp();
    for (let i = 0; i < 2; i++) {
      const res = await app(new Request("http://localhost/swarm/send", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          msg_id: "msg_caller",
          from: "ses_a",
          to: "ses_b",
          kind: "chat",
          payload: i === 0 ? "first" : "second",
        }),
      }));
      expect(res.status).toBe(202);
    }
    const stored = s.swarm.getByMsgId("msg_caller");
    expect(stored!.payload).toBe("first");
  });

  it("rejects without `from` or without (`to` xor `channel`)", async () => {
    const { app } = newApp();
    const res = await app(new Request("http://localhost/swarm/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ from: "ses_a", payload: "x" }),
    }));
    expect(res.status).toBe(400);
  });
});

describe("GET /swarm/inbox", () => {
  let storage: StorageDb | null = null;
  afterEach(() => { if (storage) { storage.db.close(); storage = null; } });

  it("returns delivered messages for a session, supports `since`", async () => {
    storage = openStorageDb(":memory:");
    const app = createApp(storage, { nowFn: () => 1_000 });

    storage.swarm.insert({
      msgId: "m1", fromSession: "ses_a", toSession: "ses_b",
      channel: null, kind: "chat", priority: "normal", replyTo: null, payload: "p1",
    }, 1_000);
    storage.swarm.insert({
      msgId: "m2", fromSession: "ses_a", toSession: "ses_b",
      channel: null, kind: "chat", priority: "normal", replyTo: null, payload: "p2",
    }, 2_000);
    storage.swarm.markHandedOff("m1", 1_500);
    storage.swarm.markHandedOff("m2", 2_500);

    const res = await app(new Request("http://localhost/swarm/inbox?session=ses_b"));
    expect(res.status).toBe(200);
    const body = await res.json() as { messages: Array<{ msg_id: string }> };
    expect(body.messages.map((m) => m.msg_id)).toEqual(["m1", "m2"]);

    const since = await app(new Request("http://localhost/swarm/inbox?session=ses_b&since=m1"));
    const sinceBody = await since.json() as { messages: Array<{ msg_id: string }> };
    expect(sinceBody.messages.map((m) => m.msg_id)).toEqual(["m2"]);
  });
});
```

**Step 3: Run test to verify it fails**

```bash
cd ~/projects/pigeon/packages/daemon && npm test -- swarm-routes 2>&1 | tail -10
```
Expected: 404 Not Found from app.

**Step 4: Implement routes in `packages/daemon/src/app.ts`**

Add a small helper at the top (or inline in the handler):

```ts
import { randomUUID } from "node:crypto";

function makeMsgId(): string {
  // ULID-ish but using uuid for simplicity. Sortable=false; that's OK because
  // the inbox `since` cursor uses msg_id ordering only as a tiebreak — the
  // primary order is createdAt-via-msg_id (we generate IDs at insert time
  // with a sortable timestamp prefix to keep getInbox order deterministic).
  return `msg_${Date.now().toString(36)}_${randomUUID().slice(0, 8)}`;
}
```

Add two `if` blocks alongside the existing routes (immediately after
the `/health` block is fine):

```ts
if (request.method === "POST" && url.pathname === "/swarm/send") {
  const body = await readJsonBody(request);
  const from = typeof body.from === "string" ? body.from : "";
  const to = typeof body.to === "string" ? body.to : null;
  const channel = typeof body.channel === "string" ? body.channel : null;
  const kind = typeof body.kind === "string" ? body.kind : "chat";
  const priority = (typeof body.priority === "string" ? body.priority : "normal") as "urgent" | "normal" | "low";
  const replyTo = typeof body.reply_to === "string" ? body.reply_to : null;
  const payload = typeof body.payload === "string" ? body.payload : "";
  const callerMsgId = typeof body.msg_id === "string" ? body.msg_id : null;

  if (!from) return Response.json({ error: "from is required" }, { status: 400 });
  if (!to && !channel) return Response.json({ error: "to or channel is required" }, { status: 400 });
  if (to && channel) return Response.json({ error: "exactly one of to or channel must be set" }, { status: 400 });
  if (!payload) return Response.json({ error: "payload is required" }, { status: 400 });

  const msgId = callerMsgId ?? makeMsgId();
  storage.swarm.insert({
    msgId, fromSession: from, toSession: to, channel, kind, priority, replyTo, payload,
  }, nowFn());

  return Response.json({ accepted: true, msg_id: msgId }, { status: 202 });
}

if (request.method === "GET" && url.pathname === "/swarm/inbox") {
  const sessionId = url.searchParams.get("session");
  if (!sessionId) return Response.json({ error: "session is required" }, { status: 400 });
  const since = url.searchParams.get("since");
  const messages = storage.swarm.getInbox(sessionId, since);
  return Response.json({
    messages: messages.map((m) => ({
      msg_id: m.msgId,
      from: m.fromSession,
      to: m.toSession,
      channel: m.channel,
      kind: m.kind,
      priority: m.priority,
      reply_to: m.replyTo,
      payload: m.payload,
      created_at: m.createdAt,
      handed_off_at: m.handedOffAt,
    })),
  });
}
```

**Step 5: Run test + typecheck**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-routes 2>&1 | tail -10
npm run typecheck 2>&1 | tail -5
npm test 2>&1 | tail -10  # full suite to ensure no regression
```

**Step 6: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/app.ts packages/daemon/test/swarm-routes.test.ts
git commit -m "feat(swarm): POST /swarm/send + GET /swarm/inbox endpoints

Senders post to /swarm/send and get back {accepted, msg_id} (HTTP 202).
The msg_id is the idempotency key — repeat sends with the same id are
no-ops. Receivers (or replay tools) GET /swarm/inbox?session=X[&since=cursor]
to read delivered messages in msg_id order.

Validation: from is required; exactly one of (to, channel) must be set;
payload non-empty. Broadcast (channel) routing is accepted in the API
but not yet wired into the arbiter — Task 6 handles that."
```

---

## Task 6: Wire arbiter into daemon startup

**Repo:** `~/projects/pigeon`

**Files:**
- Modify: `packages/daemon/src/index.ts` (boot the arbiter alongside OutboxSender)
- Modify: `packages/daemon/src/config.ts` if there's an opencode-base-url setting (probably already exists; verify and reuse)

**Step 1: Read `packages/daemon/src/index.ts` lines 1-80** to find:
- where `OpencodeClient` is constructed (or how to get its baseUrl)
- where `OutboxSender` is constructed and started
- where the HTTP server is started

**Step 2: Add imports + construction near OutboxSender:**

```ts
import { SwarmArbiter } from "./swarm/arbiter";
import { SessionDirectoryRegistry } from "./swarm/registry";
```

Near where `OutboxSender` is constructed:

```ts
const opencodeBaseUrl = config.opencodeUrl ?? "http://127.0.0.1:4096";
const opencodeClient = new OpencodeClient({ baseUrl: opencodeBaseUrl });
const sessionRegistry = new SessionDirectoryRegistry({
  baseUrl: opencodeBaseUrl,
  ttlMs: 5 * 60 * 1000,
});
const swarmArbiter = new SwarmArbiter({
  storage,
  opencodeClient,
  registry: sessionRegistry,
});
swarmArbiter.start(500);
```

And in the shutdown handler (alongside `outboxSender.stop()`):

```ts
swarmArbiter.stop();
```

**Step 3: Verify it boots**

```bash
cd ~/projects/pigeon/packages/daemon
npm run typecheck 2>&1 | tail -5
npm test 2>&1 | tail -10  # full suite
```

(No new test for boot wiring; the arbiter is unit-tested in Task 4.)

**Step 4: Commit**

```bash
cd ~/projects/pigeon
git add packages/daemon/src/index.ts
git commit -m "feat(swarm): boot SwarmArbiter alongside OutboxSender on daemon startup

The arbiter polls every 500ms for ready swarm messages (faster than the
5s OutboxSender because swarm traffic is more interactive). Shares the
same storage handle and opencodeClient. Stops cleanly on shutdown."
```

---

## Task 7: End-to-end integration test (TDD)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/daemon/test/swarm-routes.integration.test.ts`

This is the test that proves the architectural race fix: fire 4
concurrent `POST /swarm/send` calls from "different cwds" (different
`from` ids; the daemon ignores cwd) targeting the same session, and
assert that the arbiter calls `prompt_async` exactly 4 times,
strictly sequentially (no overlap).

**Step 1: Write the integration test**

```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { openStorageDb, type StorageDb } from "../src/storage/database";
import { SwarmArbiter } from "../src/swarm/arbiter";

describe("swarm routes e2e", () => {
  let storage: StorageDb | null = null;
  let arbiter: SwarmArbiter | null = null;

  afterEach(() => {
    arbiter?.stop();
    if (storage) { storage.db.close(); storage = null; }
    arbiter = null;
  });

  it("serializes per-target deliveries even under concurrent ingest", async () => {
    storage = openStorageDb(":memory:");
    const app = createApp(storage, { nowFn: () => Date.now() });

    const inflight: Array<{ target: string; startedAt: number; finishedAt?: number }> = [];

    const opencodeClient = {
      sendPrompt: vi.fn(async (target: string, _dir: string, _prompt: string) => {
        const rec = { target, startedAt: Date.now() };
        inflight.push(rec);
        await new Promise((r) => setTimeout(r, 30));
        rec.finishedAt = Date.now();
      }),
    };

    const registry = {
      resolve: vi.fn(async (sessionId: string) => `/dir/${sessionId}`),
    };

    arbiter = new SwarmArbiter({
      storage,
      opencodeClient: opencodeClient as any,
      registry: registry as any,
    });

    // Fire 4 sends concurrently to the same target
    const sends = await Promise.all(
      [1, 2, 3, 4].map((i) =>
        app(new Request("http://localhost/swarm/send", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            from: `ses_caller_${i}`,
            to: "ses_target",
            kind: "chat",
            payload: `payload ${i}`,
          }),
        })),
      ),
    );
    for (const s of sends) expect(s.status).toBe(202);

    // Drive arbiter until all are handed_off (or timeout)
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      await arbiter.processOnce();
      const ready = storage.swarm.listTargetsWithReady(Date.now());
      if (ready.length === 0) break;
      await new Promise((r) => setTimeout(r, 50));
    }

    expect(opencodeClient.sendPrompt).toHaveBeenCalledTimes(4);

    // Critical assertion: no two calls to the same target were in flight
    // simultaneously. We sort by startedAt and check finishedAt[i] <= startedAt[i+1].
    const sorted = [...inflight]
      .filter((r) => r.target === "ses_target")
      .sort((a, b) => a.startedAt - b.startedAt);
    for (let i = 0; i < sorted.length - 1; i++) {
      expect(sorted[i].finishedAt).toBeDefined();
      expect(sorted[i].finishedAt!).toBeLessThanOrEqual(sorted[i + 1].startedAt);
    }
  });
});
```

**Step 2: Run + commit**

```bash
cd ~/projects/pigeon/packages/daemon
npm test -- swarm-routes.integration 2>&1 | tail -10
cd ~/projects/pigeon
git add packages/daemon/test/swarm-routes.integration.test.ts
git commit -m "test(swarm): e2e proves architectural race fix

Fires 4 concurrent POST /swarm/send calls targeting the same session
and asserts that the arbiter dispatches them strictly sequentially —
no two prompt_async calls in flight to the same target at the same
time. This is the prompt_async race we fought in COPS-6107, fixed
architecturally by the daemon-as-single-writer property."
```

---

## Task 8: `swarm.read` opencode tool (in opencode-plugin)

**Repo:** `~/projects/pigeon`

**Files:**
- Create: `packages/opencode-plugin/src/swarm-tool.ts`
- Modify: `packages/opencode-plugin/src/index.ts` (register the tool)
- Test: `packages/opencode-plugin/test/swarm-tool.test.ts` (or alongside existing plugin tests if there's a pattern)

**Step 1: Read existing plugin code first**

```bash
cat ~/projects/pigeon/packages/opencode-plugin/src/index.ts | head -60
ls ~/projects/pigeon/packages/opencode-plugin/test/ 2>&1
```

The plugin is a function the opencode runtime calls to register
tools/hooks. Mirror the existing pattern.

**Step 2: Implement `swarm-tool.ts`**

```ts
/**
 * swarm.read — opencode tool that fetches the current session's
 * swarm inbox from pigeon. Receivers call this when they want to
 * see backlog or check for messages they haven't seen pushed yet.
 *
 * Args:
 *   since: optional msg_id cursor; default = the cursor stored in
 *          the plugin's per-session state from the last call.
 */

export interface SwarmReadOptions {
  daemonBaseUrl: string;        // e.g. http://127.0.0.1:4731
  sessionId: string;            // injected by plugin per-session
  fetchFn?: typeof fetch;
}

export interface SwarmInboxMessage {
  msg_id: string;
  from: string;
  kind: string;
  priority: string;
  payload: string;
  reply_to: string | null;
  created_at: number;
}

export async function swarmRead(opts: SwarmReadOptions, since?: string): Promise<SwarmInboxMessage[]> {
  const fetchFn = opts.fetchFn ?? fetch;
  const url = new URL("/swarm/inbox", opts.daemonBaseUrl);
  url.searchParams.set("session", opts.sessionId);
  if (since) url.searchParams.set("since", since);
  const res = await fetchFn(url.toString());
  if (!res.ok) {
    throw new Error(`swarm.read failed: ${res.status} ${await res.text()}`);
  }
  const body = (await res.json()) as { messages: SwarmInboxMessage[] };
  return body.messages;
}
```

**Step 3: Register the tool in plugin index.ts**

Look at how the existing question-queue/message-tail register
themselves; add a similar registration that exposes `swarm.read` as
a tool the LLM can call. The exact opencode plugin API for tool
registration is whatever the existing code uses — match it.

(If the plugin doesn't currently register tools and only does
event hooks, this becomes a v0.5 task. For MVP shipping, callers
can hit `GET /swarm/inbox` directly via a bash wrapper instead.)

**Step 4: Test + commit**

```bash
cd ~/projects/pigeon/packages/opencode-plugin
npm test 2>&1 | tail -10
npm run typecheck 2>&1 | tail -5

cd ~/projects/pigeon
git add packages/opencode-plugin/src/swarm-tool.ts packages/opencode-plugin/src/index.ts \
        packages/opencode-plugin/test/swarm-tool.test.ts  # if created
git commit -m "feat(plugin): swarm.read tool for inbox replay

Exposes /swarm/inbox as a tool the receiving agent can call. Lets
agents check backlog (e.g. after coming back from a long task) or
fetch low-priority messages that weren't pushed via prompt_async."
```

---

## Task 9: `pigeon-send` bash wrapper (in workstation)

**Repo:** `~/projects/workstation`

**Files:**
- Modify: `users/dev/home.base.nix` (add `home.file.".local/bin/pigeon-send"`)

**Step 1: Read the existing `opencode-send` block** (lines 748-1039 of
`users/dev/home.base.nix`) to mirror its style: same shape of CLI, same
error-handling patterns, same use of `pkgs.curl` / `pkgs.jq`.

**Step 2: Add a new `home.file` block right after the
`opencode-send` block:**

```nix
  home.file.".local/bin/pigeon-send" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      DAEMON_URL="''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}"

      CURL="${pkgs.curl}/bin/curl"
      JQ="${pkgs.jq}/bin/jq"

      show_help() {
        cat <<'HELP_EOF'
      Usage:
        pigeon-send [OPTIONS] <to-session-id> <payload>
        pigeon-send [OPTIONS] <to-session-id> -        # read payload from stdin

      Send a swarm message to another opencode session via the local
      pigeon daemon. The daemon delivers asynchronously with retry,
      exactly-once-per-msg-id semantics.

      Options:
        --from <id>        Sender session id (default: $OPENCODE_SESSION_ID)
        --kind <kind>      Message kind (default: chat). Examples:
                           task.assign, status.update, clarification.request,
                           clarification.reply, artifact.handoff
        --priority <p>     urgent | normal (default) | low
        --reply-to <id>    Quote a previous msg_id for threading
        --msg-id <id>      Caller-supplied idempotency key
        --url <url>        Daemon URL (default: $PIGEON_DAEMON_URL or
                           http://127.0.0.1:4731)
        -h, --help         Show this help

      Environment:
        OPENCODE_SESSION_ID  Auto-set by the shell-env plugin in opencode
                             sessions; used as the default --from
        PIGEON_DAEMON_URL    Override daemon URL

      Examples:
        pigeon-send ses_abc "frontend tests are failing on COPS-6107"
        echo "long status update" | pigeon-send --kind status.update ses_abc -
        pigeon-send --priority urgent --kind task.assign \
                    --reply-to msg_def ses_abc "please run the diff"
      HELP_EOF
      }

      to=""
      from="''${OPENCODE_SESSION_ID:-}"
      kind="chat"
      priority="normal"
      reply_to=""
      msg_id=""
      payload=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -h|--help) show_help; exit 0 ;;
          --from)     from="$2";     shift 2 ;;
          --from=*)   from="''${1#*=}";   shift ;;
          --kind)     kind="$2";     shift 2 ;;
          --kind=*)   kind="''${1#*=}";   shift ;;
          --priority) priority="$2"; shift 2 ;;
          --priority=*) priority="''${1#*=}"; shift ;;
          --reply-to) reply_to="$2"; shift 2 ;;
          --reply-to=*) reply_to="''${1#*=}"; shift ;;
          --msg-id)   msg_id="$2";   shift 2 ;;
          --msg-id=*) msg_id="''${1#*=}"; shift ;;
          --url)      DAEMON_URL="$2"; shift 2 ;;
          --url=*)    DAEMON_URL="''${1#*=}"; shift ;;
          --) shift; break ;;
          -*)
            if [[ "$1" == "-" ]]; then break; fi
            echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
          *) break ;;
        esac
      done

      if [[ $# -lt 1 ]]; then
        echo "Error: <to-session-id> is required" >&2; show_help >&2; exit 1
      fi
      to="$1"; shift

      if [[ $# -lt 1 ]]; then
        echo "Error: <payload> is required (or pass '-' for stdin)" >&2; exit 1
      fi
      if [[ "$1" == "-" ]]; then payload="$(cat)"; else payload="$1"; fi

      if [[ -z "$from" ]]; then
        echo "Error: --from required (or set OPENCODE_SESSION_ID)" >&2; exit 1
      fi
      if [[ -z "$payload" ]]; then
        echo "Error: payload is empty" >&2; exit 1
      fi

      body="$( "$JQ" -nc \
        --arg from "$from" \
        --arg to "$to" \
        --arg kind "$kind" \
        --arg priority "$priority" \
        --arg reply_to "$reply_to" \
        --arg msg_id "$msg_id" \
        --arg payload "$payload" \
        '{from: $from, to: $to, kind: $kind, priority: $priority, payload: $payload}
          + (if $reply_to == "" then {} else {reply_to: $reply_to} end)
          + (if $msg_id == "" then {} else {msg_id: $msg_id} end)' )"

      resp_file="/tmp/pigeon-send-resp.$$"
      http_status="$( "$CURL" -sS -o "$resp_file" -w '%{http_code}' \
        -X POST -H "Content-Type: application/json" \
        --data "$body" \
        "$DAEMON_URL/swarm/send" )" || {
          echo "Error: POST to pigeon daemon failed" >&2
          rm -f "$resp_file"; exit 1
        }

      if [[ "$http_status" -lt 200 || "$http_status" -ge 300 ]]; then
        echo "Error: pigeon daemon returned HTTP $http_status" >&2
        cat "$resp_file" >&2; echo >&2
        rm -f "$resp_file"; exit 1
      fi

      msg_id_out="$( "$JQ" -r '.msg_id // ""' < "$resp_file" )"
      rm -f "$resp_file"
      echo "Queued $msg_id_out -> $to (kind=$kind priority=$priority, ''${#payload} chars)"
    '';
  };
```

**Step 3: Apply via home-manager and smoke-test on cloudbox**

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5

# verify the wrapper exists and shows help
~/.local/bin/pigeon-send --help | head -5
```

**Step 4: Commit**

```bash
cd ~/projects/workstation
git add users/dev/home.base.nix
git commit -m "feat(swarm): add pigeon-send bash wrapper

Mirror of opencode-send but talks to the pigeon daemon at
\$PIGEON_DAEMON_URL (default http://127.0.0.1:4731) instead of
opencode serve directly. Returns a queued msg_id for ack."
```

---

## Task 10: Repoint `opencode-send` to use pigeon for `ses_*` targets

**Repo:** `~/projects/workstation`

**Files:**
- Modify: `users/dev/home.base.nix` — modify `opencode-send` block

**Step 1: Add a `--direct` flag and a default-pigeon-routing branch**

Add option parsing for `--direct` (default off). When the target id
starts with `ses_` AND `--direct` is NOT set AND the daemon is up,
exec `pigeon-send` with the message and exit. Otherwise, fall through
to existing direct-to-opencode-serve path (with the flock).

Insert near the top of send mode (right after the cwd defaulting
block, around line 948 in current `home.base.nix`):

```bash
# Auto-route via pigeon when target looks like an opencode session id
# (ses_*) and pigeon daemon is reachable. Override with --direct.
if [[ "$direct_mode" != "1" && "$session_id" =~ ^ses_ ]]; then
  if "$CURL" -sf -m 2 "''${PIGEON_DAEMON_URL:-http://127.0.0.1:4731}/health" >/dev/null 2>&1; then
    exec pigeon-send --from "''${OPENCODE_SESSION_ID:-unknown}" "$session_id" "$message"
  fi
fi
```

Add the `--direct` arg to the option parser:

```bash
--direct)
  direct_mode=1
  shift
  ;;
```

And initialize `direct_mode=0` near the other defaults.

**Step 2: Update the help text**

Add to `show_help`:

```
  --direct           Skip pigeon routing and POST directly to opencode
                     serve (legacy/debug only)
```

**Step 3: Apply + smoke test**

```bash
cd ~/projects/workstation
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5

# Should now route through pigeon by default
opencode-send --help | grep -A1 'direct' | head -5

# direct mode still works as before
opencode-send --direct ses_doesnotexist "test" 2>&1 | head -3
```

**Step 4: Commit**

```bash
cd ~/projects/workstation
git add users/dev/home.base.nix
git commit -m "feat(swarm): default opencode-send to route via pigeon for ses_* targets

When the target id matches ^ses_ AND the pigeon daemon is reachable
AND the user did not pass --direct, exec pigeon-send instead of POSTing
to opencode serve. This means existing scripts and skills using
opencode-send transparently get durable delivery, retry, replay, and
single-writer race protection.

--direct is the escape hatch for debugging or legacy use."
```

---

## Task 11: `swarm-messaging` skill doc for agents

**Repo:** `~/projects/workstation`

**Files:**
- Create: `assets/opencode/skills/swarm-messaging/SKILL.md`

The skill teaches receiving agents how to recognize and parse the
`<swarm_message>` envelope, when senders should use `pigeon-send`,
and when receivers should call `swarm.read`.

**Content sketch (~80 lines):**

```markdown
---
name: swarm-messaging
description: Use when sending messages to other opencode sessions on the same machine (swarm coordination), or when you receive a <swarm_message> envelope in a user-message turn.
---

# Swarm Messaging

Pigeon hosts a durable, replayable message channel between opencode
sessions on the same machine. Use `pigeon-send` to send and the
`<swarm_message>` envelope to recognize messages you receive.

## Sending

```bash
pigeon-send <to-session-id> "your message"
```

The wrapper pulls your own session id from `$OPENCODE_SESSION_ID`
(injected by the shell-env plugin) so you don't have to specify
`--from`.

Common kinds:
- `chat` (default) — informal back-and-forth
- `task.assign` — coordinator asks a worker to do something
- `status.update` — worker reports progress
- `clarification.request` — needs an answer to proceed
- `clarification.reply` — answers a `request`
- `artifact.handoff` — pointer to a file/PR/diff

Set `--priority urgent` for blocking work; default is `normal`.
Use `--reply-to <msg_id>` to thread.

## Receiving

When a swarm message arrives, you'll see a user-message turn whose
text is the envelope:

```xml
<swarm_message v="1" kind="task.assign"
               from="ses_abc..." to="ses_def..."
               msg_id="msg_..." priority="normal">
The actual payload here.
</swarm_message>
```

Steps:
1. Parse the envelope. The routing fields tell you who sent it and
   whether it threads off a previous message.
2. Reason over the payload as the actual instruction.
3. If you reply via `pigeon-send`, set `--reply-to <their msg_id>`
   so the thread connects.

## Replay

If you suspect you missed messages (e.g. you were busy on a long
tool call), call the `swarm.read` tool with no args to fetch your
backlog.

## Don't

- Don't talk to opencode serve's `/session/<id>/prompt_async` directly
  for cross-session messaging. That route races. Always go through
  `pigeon-send` (or `opencode-send` which auto-routes).
- Don't paste the envelope back as your own message — receivers will
  see two layers of envelope and get confused.
```

**Commit:**

```bash
cd ~/projects/workstation
git add assets/opencode/skills/swarm-messaging/SKILL.md
git commit -m "docs(swarm): swarm-messaging skill for agents

Teaches receiving agents how to parse the <swarm_message> envelope
and senders when to use pigeon-send / swarm.read."
```

---

## Task 12: Live smoke test on cloudbox swarm

**Repo:** none (manual)

Pre-conditions:
- Pigeon daemon restarted with the new code (Task 6 wired the arbiter
  into startup)
- `pigeon-send` + updated `opencode-send` deployed via home-manager
- `swarm-messaging` SKILL deployed

**Steps:**

1. From any local shell on cloudbox, send a test message to the
   coordinator session:
   ```bash
   pigeon-send --kind chat ses_24e8ff295ffeyV8o35YuK63g2u \
     "smoke test from $(hostname): pigeon swarm IPC online"
   ```
2. Verify the coordinator session receives the message in its
   transcript wrapped in a `<swarm_message>` envelope.
3. Inbox check:
   ```bash
   curl -s "http://127.0.0.1:4731/swarm/inbox?session=ses_24e8ff295ffeyV8o35YuK63g2u" \
     | jq '.messages | length'
   ```
4. Concurrency stress test — fire 10 sends in parallel:
   ```bash
   for i in $(seq 1 10); do
     pigeon-send ses_24e8ff295ffeyV8o35YuK63g2u "concurrent test $i" &
   done
   wait
   ```
   Verify NO prefill 400 errors in the coordinator's logs.
5. Send via legacy `opencode-send` (without `--direct`) and verify
   it auto-routes through pigeon (check the coordinator transcript
   shows the envelope, not a raw user message).

If all 5 work: ship.

If any fail: roll back (`opencode-send --direct` is the escape;
disable the daemon-arbiter and the swarm tables stay quiescent).

---

## Task 13: Ship the route-rebind defense-in-depth patch

**Repo:** `~/projects/opencode-patched`

This is the patch we drafted in
`docs/plans/2026-04-21-opencode-prefill-fix-design.md` and
`docs/plans/research/2026-04-21-opencode-prefill-patch-sketch-answer.md`.

It is **defense in depth** — the swarm IPC fixes the race
architecturally for daemon-routed traffic, but humans can still
type `opencode-send --direct ses_X "..."` from a wrong cwd. The
patch protects against that.

This is its own multi-step plan; see the design doc. Sequence:
1. Adapt ChatGPT's diff to the v1.14.19 file layout
   (`packages/opencode/src/server/routes/instance/session.ts`,
   not `routes/session.ts`).
2. Use a per-handler wrapper helper (NOT top-level middleware,
   because Hono `c.req.param` returns undefined in `.use()`-registered
   middleware — see the design doc for details).
3. Add the Bun test from ChatGPT's sketch.
4. Drop the patch into `patches/prefill-fix.patch` in
   `opencode-patched`, update `apply.sh`.
5. Push, let CI build, then bump version + hashes in
   `users/dev/home.base.nix` once the binary is published.

This whole task can be its own follow-up plan
(`docs/plans/2026-04-22-opencode-prefill-patch-plan.md` or similar)
to keep this swarm-IPC plan focused.

---

## Done definition

- All Task 1-7 tests green in pigeon (`npm test` from
  `packages/daemon` passes including new files)
- All Task 8 plugin code typechecks; if registration of `swarm.read`
  as a tool isn't possible without bigger plugin changes, document
  that as v0.5 follow-up
- `pigeon-send --help` works (Task 9)
- `opencode-send` auto-routes for `ses_*` and `--direct` bypasses
  (Task 10)
- Skill deployed and visible in `opencode skill list` or equivalent
  (Task 11)
- All 5 smoke-test steps pass on cloudbox (Task 12)
- Route-rebind patch is filed as a follow-up plan (Task 13)

After landing the swarm-IPC plan, broadcast a switch-protocol
message to all 5 swarm members: "from now on use `pigeon-send`
(or `opencode-send` without `--direct`) — don't pass `--cwd`
anymore, the daemon resolves the canonical directory itself."

