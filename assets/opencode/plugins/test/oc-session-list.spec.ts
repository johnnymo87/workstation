import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, readdirSync, mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { queryBaseList, queryTreesForSessions } from "../oc-session-list-base.js";
import { main, parseCliArgs } from "../oc-session-list.js";
import {
  attentionCandidates,
  buildOriginMap,
  buildOwnersMap,
  buildUnreadMap,
  HIDDEN_ORIGINS,
  isAutomatedOrigin,
  KNOWN_VISIBLE_ORIGINS,
  queryWithState,
  runOrphanGc,
  type SessionWithStateRow,
  unacknowledgedOrigins,
} from "../oc-session-list-state.js";
import { foldRows } from "../oc-session-list-fold.js";
import { OVERLAY_VERSION } from "../session-state-impl.js";

const REAL_OVERLAY_DIR = process.env.HOME
  ? `${process.env.HOME}/.local/share/opencode/session-state.d`
  : "";

function getRealOverlayListing(): string[] {
  if (!REAL_OVERLAY_DIR || !existsSync(REAL_OVERLAY_DIR)) return [];
  return readdirSync(REAL_OVERLAY_DIR).sort();
}

function createTestDb(): Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE session (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      parent_id TEXT,
      slug TEXT NOT NULL,
      directory TEXT NOT NULL,
      title TEXT NOT NULL,
      version TEXT NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL,
      time_archived INTEGER
    );
  `);
  return db;
}

function createTestOriginDb(path: string): Database {
  const db = new Database(path);
  db.exec(`
    CREATE TABLE session_origin (
      session_id TEXT PRIMARY KEY,
      origin TEXT NOT NULL,
      notify_policy TEXT NOT NULL DEFAULT 'all',
      declared_at INTEGER NOT NULL DEFAULT 0
    );
  `);
  return db;
}

describe("oc-session-list base query", () => {
  it("resolves 3-level nesting (grandchild -> child -> root) to the true root and ranks by recency", () => {
    const db = createTestDb();

    // Root session (updated long ago)
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('root_1', 'p1', NULL, 'root-1', '/proj', 'Root Session', '1.0', 1000, 1000, NULL)
    `);

    // Child session (updated slightly later)
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('child_1', 'p1', 'root_1', 'child-1', '/proj', 'Child Session', '1.0', 1000, 2000, NULL)
    `);

    // Grandchild session (updated most recently)
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('grandchild_1', 'p1', 'child_1', 'grandchild-1', '/proj', 'Grandchild Session', '1.0', 1000, 3000, NULL)
    `);

    // Unrelated older root session
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('root_2', 'p1', NULL, 'root-2', '/proj', 'Older Root', '1.0', 500, 500, NULL)
    `);

    const rows = queryBaseList(db, { limit: 10 });

    expect(rows.length).toBe(4);

    const root1TreeIds = rows.slice(0, 3).map((r) => r.id);
    expect(root1TreeIds).toContain("root_1");
    expect(root1TreeIds).toContain("child_1");
    expect(root1TreeIds).toContain("grandchild_1");

    expect(rows[0].id).toBe("grandchild_1");
    expect(rows[3].id).toBe("root_2");

    const rootOf = Object.fromEntries(rows.map((r) => [r.id, r.root_id]));
    expect(rootOf["root_1"]).toBe("root_1");
    expect(rootOf["child_1"]).toBe("root_1");
    expect(rootOf["grandchild_1"]).toBe("root_1");
    expect(rootOf["root_2"]).toBe("root_2");
  });

  it("a recently-active GRANDCHILD keeps its older root's whole tree in the top-N", () => {
    const db = createTestDb();
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived) VALUES
        ('root_1', 'p1', NULL, 'root-1', '/proj', 'Root', '1.0', 1000, 1000, NULL),
        ('child_1', 'p1', 'root_1', 'child-1', '/proj', 'Child', '1.0', 1000, 2000, NULL),
        ('grandchild_1', 'p1', 'child_1', 'gc-1', '/proj', 'Grandchild', '1.0', 1000, 3000, NULL),
        ('root_2', 'p1', NULL, 'root-2', '/proj', 'Other Root', '1.0', 500, 500, NULL)
    `);

    const rows = queryBaseList(db, { limit: 1 });

    expect(rows.map((r) => r.id).sort()).toEqual(["child_1", "grandchild_1", "root_1"]);
    expect(new Set(rows.map((r) => r.root_id))).toEqual(new Set(["root_1"]));
  });

  it("excludes archived sessions (time_archived IS NOT NULL)", () => {
    const db = createTestDb();

    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('active_1', 'p1', NULL, 'active-1', '/proj', 'Active Session', '1.0', 1000, 2000, NULL)
    `);

    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('archived_1', 'p1', NULL, 'archived-1', '/proj', 'Archived Session', '1.0', 1000, 3000, 3001)
    `);

    const rows = queryBaseList(db, { limit: 10 });

    expect(rows.length).toBe(1);
    expect(rows[0].id).toBe("active_1");
  });

  it("handles parent_id cycles safely without hanging or throwing", () => {
    const db = createTestDb();

    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('cycle_a', 'p1', 'cycle_b', 'cycle-a', '/proj', 'Cycle A', '1.0', 1000, 2000, NULL);
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('cycle_b', 'p1', 'cycle_a', 'cycle-b', '/proj', 'Cycle B', '1.0', 1000, 2500, NULL);
    `);

    const start = Date.now();
    const rows = queryBaseList(db, { limit: 10 });
    const elapsed = Date.now() - start;

    // Assert TERMINATION, not wall time: a 100ms budget is flaky on a loaded
    // box. The failure mode this guards is an unbounded walk, which does not
    // finish at all.
    expect(elapsed).toBeLessThan(5000);
    expect(rows.length).toBe(2);
  });

  it("respects the limit option for distinct root trees", () => {
    const db = createTestDb();

    for (let i = 1; i <= 5; i++) {
      db.exec(`
        INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
        VALUES ('root_${i}', 'p1', NULL, 'root-${i}', '/proj', 'Root ${i}', '1.0', 1000, ${i * 1000}, NULL)
      `);
    }

    const rows = queryBaseList(db, { limit: 2 });

    expect(rows.length).toBe(2);
    expect(rows[0].id).toBe("root_5");
    expect(rows[1].id).toBe("root_4");
  });

  it("treats child with missing parent as its own root", () => {
    const db = createTestDb();

    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('orphan_child', 'p1', 'non_existent_parent', 'orphan', '/proj', 'Orphan Child', '1.0', 1000, 2000, NULL)
    `);

    const rows = queryBaseList(db, { limit: 10 });

    expect(rows.length).toBe(1);
    expect(rows[0].id).toBe("orphan_child");
  });
});

describe("parseCliArgs", () => {
  it("parses --limit and --db flags correctly", () => {
    const opts = parseCliArgs(["--limit", "25", "--db", "/tmp/test.db"]);
    expect(opts.limit).toBe(25);
    expect(opts.dbPath).toBe("/tmp/test.db");
    expect(opts.help).toBe(false);
  });

  it("parses --limit=N and --db=PATH formats", () => {
    const opts = parseCliArgs(["--limit=10", "--db=/tmp/other.db"]);
    expect(opts.limit).toBe(10);
    expect(opts.dbPath).toBe("/tmp/other.db");
  });

  it("parses --with-state, --routing-db, --overlay-dir, --gc flags", () => {
    const opts = parseCliArgs([
      "--with-state",
      "--routing-db", "/tmp/pigeon.db",
      "--overlay-dir", "/tmp/overlays",
      "--gc",
    ]);
    expect(opts.withState).toBe(true);
    expect(opts.routingDbPath).toBe("/tmp/pigeon.db");
    expect(opts.overlayDir).toBe("/tmp/overlays");
    expect(opts.gc).toBe(true);
  });

  it("parses --routing-db=PATH and --overlay-dir=PATH inline formats", () => {
    const opts = parseCliArgs([
      "--routing-db=/tmp/pigeon2.db",
      "--overlay-dir=/tmp/overlays2",
    ]);
    expect(opts.routingDbPath).toBe("/tmp/pigeon2.db");
    expect(opts.overlayDir).toBe("/tmp/overlays2");
  });

  it("parses --help flag", () => {
    const opts = parseCliArgs(["--help"]);
    expect(opts.help).toBe(true);
  });
});

describe("buildOwnersMap", () => {
  it("maps root sessions and their children to desired_serve_id from session_assignment", () => {
    const rdb = new Database(":memory:");
    rdb.exec(`
      CREATE TABLE session_assignment (
        session_id TEXT PRIMARY KEY,
        directory_key TEXT,
        desired_serve_id TEXT NOT NULL,
        owner_generation INTEGER,
        state TEXT,
        last_active_at INTEGER,
        updated_at INTEGER
      );
      INSERT INTO session_assignment (session_id, desired_serve_id, state)
      VALUES ('root_1', 'serve-1', 'assigned');
    `);

    const baseRows = [
      { id: "root_1", title: "Root 1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "root_1" },
      { id: "child_1", title: "Child 1", parent_id: "root_1", directory: "/p", time_updated: 1000, root_id: "root_1" },
      { id: "unassigned_root", title: "Other", parent_id: null, directory: "/p", time_updated: 1000, root_id: "unassigned_root" },
    ];

    // Create temp db file for test
    const tmpFile = join(tmpdir(), `test-pigeon-${Date.now()}.db`);
    const fileDb = new Database(tmpFile);
    fileDb.exec(`
      CREATE TABLE session_assignment (
        session_id TEXT PRIMARY KEY,
        directory_key TEXT,
        desired_serve_id TEXT NOT NULL,
        owner_generation INTEGER,
        state TEXT,
        last_active_at INTEGER,
        updated_at INTEGER
      );
      INSERT INTO session_assignment (session_id, desired_serve_id, state)
      VALUES ('root_1', 'serve-1', 'assigned');
    `);
    fileDb.close();

    try {
      const owners = buildOwnersMap(tmpFile, baseRows);
      expect(owners["root_1"]).toBe("serve-1");
      expect(owners["child_1"]).toBe("serve-1"); // CHILD INHERITED ROOT SERVE
      expect(owners["unassigned_root"]).toBeUndefined();
    } finally {
      if (existsSync(tmpFile)) rmSync(tmpFile);
    }
  });

  // Machine-dependent: needs a live pigeon daemon DB and a real opencode.db
  // under $HOME, so it can never run in a build sandbox.
  //
  // `it.skipIf` rather than an early `return`: returning made this a counted
  // PASS while asserting nothing, so if the pigeon DB path ever moved the test
  // would retire itself silently and permanently, with no counter anywhere
  // showing the loss. As a skip it is visible, and the plugin-bun check in
  // flake.nix pins the skip count at exactly 1 so a SECOND silent skip cannot
  // slip in behind it.
  const realRoutingDb = `${process.env.HOME ?? ""}/projects/pigeon/packages/daemon/data/pigeon-daemon.db`;
  const realBaseDbPath = `${process.env.HOME ?? ""}/.local/share/opencode/opencode.db`;
  const realDbsPresent = existsSync(realRoutingDb) && existsSync(realBaseDbPath);

  it.skipIf(!realDbsPresent)("against the REAL routing DB, asserts constructed owners map is NON-EMPTY and at least one CHILD session inherits root serve", () => {
    const baseDb = new Database(realBaseDbPath, { readonly: true });
    const baseRows = queryBaseList(baseDb, { limit: 1000 });
    baseDb.close();

    expect(baseRows.length).toBeGreaterThan(0);

    const owners = buildOwnersMap(realRoutingDb, baseRows);

    // Assert non-empty
    expect(Object.keys(owners).length).toBeGreaterThan(0);

    // Find at least one child session in baseRows that inherited its root's desired_serve_id
    let childInheritedCount = 0;
    for (const row of baseRows) {
      if (row.id !== row.root_id && owners[row.id]) {
        expect(owners[row.id]).toBe(owners[row.root_id]);
        childInheritedCount++;
      }
    }

    expect(childInheritedCount).toBeGreaterThan(0);
  });
});

describe("queryWithState & overlay merge", () => {
  it("annotates base rows with overlay state and enforces DB-authoritative existence", () => {
    const baseRows = [
      { id: "s1", title: "S1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "s1" },
      { id: "s2", title: "S2", parent_id: null, directory: "/p", time_updated: 2000, root_id: "s2" },
    ];

    const tempDir = join(tmpdir(), `test-overlay-${Date.now()}`);
    mkdirSync(tempDir, { recursive: true });

    try {
      const overlayFile = join(tempDir, "serve-1-hash.json");
      writeFileSync(
        overlayFile,
        JSON.stringify({
          version: OVERLAY_VERSION,
          instanceStamp: 1,
          pid: process.pid,
          serveId: "serve-1",
          directory: "/p",
          heartbeat: Date.now(),
          sessions: {
            s1: {
              activity: "working",
              error: false,
              pendingPermissions: ["p1"],
              pendingQuestions: [],
              lastActivity: 5000,
              updatedAt: 5000,
            },
            // GHOST session: present in overlay, NOT in base rows
            ghost_session: {
              activity: "working",
              error: false,
              pendingPermissions: [],
              pendingQuestions: [],
              lastActivity: 5000,
              updatedAt: 5000,
            },
          },
        })
      );

      const result = queryWithState(baseRows, {
        overlayDir: tempDir,
        now: Date.now(),
        staleMs: 45000,
        isAlive: () => true,
        owners: { s1: "serve-1", s2: "serve-1" },
      });

      // DB-authoritative length check
      expect(result.length).toBe(2);
      expect(result.find((r) => r.id === "ghost_session")).toBeUndefined();

      // s1 annotated
      const s1 = result.find((r) => r.id === "s1")!;
      expect(s1.activity).toBe("working");
      expect(s1.pendingPermissions).toEqual(["p1"]);

      // s2 (no overlay entry) defaults to idle
      const s2 = result.find((r) => r.id === "s2")!;
      expect(s2.activity).toBe("idle");
      expect(s2.pendingPermissions).toEqual([]);
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it("propagates unknown: true for overlay state from dead pid / stale heartbeat", () => {
    const baseRows = [
      { id: "s1", title: "S1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "s1" },
    ];

    const tempDir = join(tmpdir(), `test-overlay-dead-${Date.now()}`);
    mkdirSync(tempDir, { recursive: true });

    try {
      const overlayFile = join(tempDir, "serve-1-hash.json");
      writeFileSync(
        overlayFile,
        JSON.stringify({
          version: OVERLAY_VERSION,
          instanceStamp: 1,
          pid: 999999,
          serveId: "serve-1",
          directory: "/p",
          heartbeat: Date.now() - 100000, // stale
          sessions: {
            s1: {
              activity: "working",
              error: false,
              pendingPermissions: ["p1"],
              pendingQuestions: [],
              lastActivity: 5000,
              updatedAt: 5000,
            },
          },
        })
      );

      const result = queryWithState(baseRows, {
        overlayDir: tempDir,
        now: Date.now(),
        staleMs: 45000,
        isAlive: (pid) => pid !== 999999, // 999999 is dead
      });

      expect(result.length).toBe(1);
      expect(result[0].unknown).toBe(true);
      expect(result[0].pendingPermissions).toEqual([]); // unknown clears pendings
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });
});

describe("runOrphanGc", () => {
  it("TRIPWIRE: real overlay directory is NOT touched or altered by tests", () => {
    const listingBefore = getRealOverlayListing();

    // Run GC against a temp dir (NOT real dir)
    const tempDir = join(tmpdir(), `test-gc-tripwire-${Date.now()}`);
    mkdirSync(tempDir, { recursive: true });
    try {
      runOrphanGc(tempDir);
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }

    const listingAfter = getRealOverlayListing();
    expect(listingAfter).toEqual(listingBefore);
  });

  it("unlinks dead-pid + old heartbeat (>10m) files, but preserves live pids, fresh heartbeats, and torn writes", () => {
    const tempDir = join(tmpdir(), `test-gc-rules-${Date.now()}`);
    mkdirSync(tempDir, { recursive: true });

    const now = 1000000;
    const oldHeartbeat = now - 11 * 60 * 1000; // 11 min old
    const freshHeartbeat = now - 5 * 60 * 1000; // 5 min old

    try {
      // 1. Dead PID + Old heartbeat -> SHOULD BE UNLINKED
      const deadOldFile = join(tempDir, "dead-old.json");
      writeFileSync(
        deadOldFile,
        JSON.stringify({ pid: 999111, heartbeat: oldHeartbeat, version: OVERLAY_VERSION, serveId: "s1", sessions: {} })
      );

      // 2. Dead PID + Fresh heartbeat -> SHOULD NOT BE UNLINKED
      const deadFreshFile = join(tempDir, "dead-fresh.json");
      writeFileSync(
        deadFreshFile,
        JSON.stringify({ pid: 999111, heartbeat: freshHeartbeat, version: OVERLAY_VERSION, serveId: "s1", sessions: {} })
      );

      // 3. Live PID + Old heartbeat -> SHOULD NOT BE UNLINKED
      const liveOldFile = join(tempDir, "live-old.json");
      writeFileSync(
        liveOldFile,
        JSON.stringify({ pid: process.pid, heartbeat: oldHeartbeat, version: OVERLAY_VERSION, serveId: "s1", sessions: {} })
      );

      // 4. Corrupt JSON / torn write -> SHOULD NOT BE UNLINKED
      const corruptFile = join(tempDir, "corrupt.json");
      writeFileSync(corruptFile, '{"pid": 999111, "heartbeat": 1000, "sessions": {'); // truncated syntax

      // 5. Missing numeric pid/heartbeat -> SHOULD NOT BE UNLINKED
      const missingFieldsFile = join(tempDir, "missing-fields.json");
      writeFileSync(missingFieldsFile, JSON.stringify({ serveId: "s1" }));

      const unlinked = runOrphanGc(tempDir, {
        now,
        isAlive: (pid) => pid === process.pid,
      });

      expect(unlinked).toEqual([deadOldFile]);

      expect(existsSync(deadOldFile)).toBe(false);
      expect(existsSync(deadFreshFile)).toBe(true);
      expect(existsSync(liveOldFile)).toBe(true);
      expect(existsSync(corruptFile)).toBe(true);
      expect(existsSync(missingFieldsFile)).toBe(true);
    } finally {
      rmSync(tempDir, { recursive: true, force: true });
    }
  });
});

describe("ownership degradation is LOUD, never silent", () => {
  // An empty owners map disables mergeOverlays' Rule 1 (live owner wins) and
  // silently drops every session onto wall-clock ordering. ~53% of sessions on
  // this fleet are children that depend on the root-keyed join, so this must
  // never happen quietly.
  const rows = [
    { id: "s1", title: "t", parent_id: null, directory: "/d", time_updated: 1, root_id: "s1" },
  ];

  it("warns when the routing db is missing", () => {
    const warnings: string[] = [];
    const owners = buildOwnersMap("/definitely/not/here.db", rows, (m) => warnings.push(m));
    expect(owners).toEqual({});
    expect(warnings.length).toBe(1);
    expect(warnings[0]).toContain("wall-clock");
  });

  it("warns when the db exists but no ownership row matches any session", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-owners-"));
    try {
      const p = join(dir, "routing.db");
      const db = new Database(p);
      db.exec(`CREATE TABLE session_assignment (session_id TEXT PRIMARY KEY, desired_serve_id TEXT NOT NULL)`);
      db.exec(`INSERT INTO session_assignment VALUES ('someone_else', 'serve-9')`);
      db.close();

      const warnings: string[] = [];
      const owners = buildOwnersMap(p, rows, (m) => warnings.push(m));
      expect(owners).toEqual({});
      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("no ownership rows matched");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("stays SILENT on the healthy path (a warning that always fires is noise)", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-owners-ok-"));
    try {
      const p = join(dir, "routing.db");
      const db = new Database(p);
      db.exec(`CREATE TABLE session_assignment (session_id TEXT PRIMARY KEY, desired_serve_id TEXT NOT NULL)`);
      db.exec(`INSERT INTO session_assignment VALUES ('s1', 'serve-2')`);
      db.close();

      const warnings: string[] = [];
      const owners = buildOwnersMap(p, rows, (m) => warnings.push(m));
      expect(owners).toEqual({ s1: "serve-2" });
      expect(warnings).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

/**
 * S3: "no reporter" must not masquerade as "authoritatively idle".
 *
 * On 2026-08-01 the writer plugin was un-deployed fleet-wide for ~9 hours. Every
 * overlay file vanished, and this reader printed 886 rows of confident `idle` --
 * indistinguishable from a genuinely quiet machine. A human caught it only by
 * noticing an empty directory.
 *
 * The predicate is REPORTER-LEVEL, not per-(serve, directory). The writer emits
 * one file per (serveId, directory) and only for directories with a live app
 * instance, so a live serve simply having no file for some directory is the
 * normal steady state after instance eviction -- measured at 11% of real rows on
 * a perfectly healthy fleet (and 62% under a directory-matching rule). Firing on
 * that would make nodata the majority state and kill the tripwire by saturation.
 * A live serve with ZERO files, by contrast, means its writer is broken.
 *
 * Measured base rates for this rule against the real fleet:
 *   healthy 0.0% | total outage 100.0% | serve-1 writer down 6.6% | serve-2 down 17.2%
 */
describe("S3: nodata (no reporter) vs authoritative idle", () => {
  const mkdir = (tag: string) => mkdtempSync(join(tmpdir(), `s3-${tag}-`));
  const overlay = (
    dir: string,
    name: string,
    o: { serveId: string; directory?: string; pid?: number; heartbeat?: number; sessions?: any },
  ) => {
    writeFileSync(
      join(dir, `${name}.json`),
      JSON.stringify({
        version: OVERLAY_VERSION,
        instanceStamp: 1,
        pid: o.pid ?? process.pid,
        serveId: o.serveId,
        directory: o.directory,
        heartbeat: o.heartbeat ?? Date.now(),
        sessions: o.sessions ?? {},
      }),
    );
  };
  const row = (id: string, directory = "/a", time_updated = 1000) => ({
    id, title: id, parent_id: null, directory, time_updated, root_id: id,
  });

  it("reports nodata when NO overlay file exists at all (the 2026-08-01 outage)", () => {
    const dir = mkdir("outage");
    try {
      const result = queryWithState([row("s1")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1" },
      });
      expect(result[0].activity).toBe("nodata");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("reports idle -- NOT nodata -- when the owner serve is live but has no file for THIS directory", () => {
    // The 11%-of-real-rows case. The owning serve is demonstrably writing; it
    // just has no instance loaded for /a, which means the session is not running.
    const dir = mkdir("otherdir");
    try {
      overlay(dir, "serve-1-b", { serveId: "serve-1", directory: "/b", sessions: {} });
      const result = queryWithState([row("s1", "/a")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1" },
      });
      expect(result[0].activity).toBe("idle");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("isolates a partial outage to the sessions owned by the silent serve", () => {
    const dir = mkdir("partial");
    try {
      // serve-2 is writing; serve-1 (owner of s1) has emitted nothing.
      overlay(dir, "serve-2-a", { serveId: "serve-2", directory: "/a", sessions: {} });
      const result = queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1", s2: "serve-2" },
      });
      expect(result.find((r) => r.id === "s1")!.activity).toBe("nodata");
      expect(result.find((r) => r.id === "s2")!.activity).toBe("idle");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("treats a DEAD owner file as no reporter, not as a live one", () => {
    const dir = mkdir("dead");
    try {
      overlay(dir, "serve-1-a", { serveId: "serve-1", directory: "/a", pid: 999999, sessions: {} });
      const result = queryWithState([row("s1")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: (pid) => pid !== 999999,
        owners: { s1: "serve-1" },
      });
      expect(result[0].activity).toBe("nodata");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("falls back to fleet health when ownership is unknown, rather than flooding", () => {
    // 66.5% of real rows have no assignment row. Calling them all nodata would
    // drown the signal, so an unowned row trusts any live writer in the fleet.
    const dir = mkdir("noowner");
    try {
      overlay(dir, "serve-9-z", { serveId: "serve-9", directory: "/z", sessions: {} });
      const writing = queryWithState([row("s1")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true, owners: {},
      });
      expect(writing[0].activity).toBe("idle");
    } finally { rmSync(dir, { recursive: true, force: true }); }

    const empty = mkdir("noowner-silent");
    try {
      const silent = queryWithState([row("s1")], {
        overlayDir: empty, now: Date.now(), staleMs: 45000, isAlive: () => true, owners: {},
      });
      expect(silent[0].activity).toBe("nodata");
    } finally { rmSync(empty, { recursive: true, force: true }); }
  });

  it("keeps nodata and unknown mutually exclusive and preserves ordering keys", () => {
    // unknown = stale data from a dead source (activity still carries a last-known
    // value). nodata = no source at all. A row must never claim both.
    const dir = mkdir("exclusive");
    try {
      const result = queryWithState([row("s1", "/a", 4242)], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1" },
      });
      expect(result[0].activity).toBe("nodata");
      expect(result[0].unknown).toBeUndefined();
      expect(result[0].lastActivity).toBe(4242);
      expect(result[0].error).toBe(false);
      expect(result[0].pendingPermissions).toEqual([]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("warns on a total outage when no live writer is reporting for any session", () => {
    const dir = mkdir("total-outage");
    try {
      const warnings: string[] = [];
      const result = queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, now: Date.now(), staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1", s2: "serve-2" }, onWarn: (m) => warnings.push(m),
      });
      // Preconditions: both rows merged to nodata because no live writer exists
      expect(result.length).toBe(2);
      expect(result[0].activity).toBe("nodata");
      expect(result[1].activity).toBe("nodata");
      // Total outage warning fires with exact message
      expect(warnings).toContain(
        "no live writer is reporting for any of the 2 session(s) -- the writer fleet may be down; state below is not trustworthy",
      );
      // Partial outage warning does not fire
      expect(warnings.some((w) => w.includes("own session(s) but are not writing"))).toBe(false);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("warns on a partial outage naming silent owning serves via session_assignment", () => {
    const dir = mkdir("partial-outage");
    const routingPath = join(dir, "routing.db");
    const routing = new Database(routingPath);
    routing.exec(`
      CREATE TABLE session_assignment (
        session_id TEXT PRIMARY KEY,
        desired_serve_id TEXT
      );
      CREATE TABLE session_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        sent_at INTEGER NOT NULL
      );
      CREATE TABLE session_reads (
        session_id TEXT PRIMARY KEY,
        last_read_id INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE session_origin (
        session_id TEXT PRIMARY KEY,
        origin TEXT NOT NULL
      );
    `);
    routing.exec(`INSERT INTO session_assignment VALUES ('s1', 'serve-1'), ('s2', 'serve-2')`);
    routing.close();

    try {
      // serve-1 is live and reporting; serve-2 is silent (no overlay file).
      overlay(dir, "serve-1-a", { serveId: "serve-1", directory: "/a", sessions: {} });
      const warnings: string[] = [];
      const result = queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, routingDbPath: routingPath, now: Date.now(), staleMs: 45000, isAlive: () => true,
        onWarn: (m) => warnings.push(m),
      });
      // Preconditions: s1 is idle (served by live serve-1), s2 is nodata (owned by silent serve-2)
      expect(result.find((r) => r.id === "s1")?.activity).toBe("idle");
      expect(result.find((r) => r.id === "s2")?.activity).toBe("nodata");
      // Total outage warning does NOT fire (fleet is partially reporting)
      expect(warnings.some((w) => w.includes("the writer fleet may be down"))).toBe(false);
      // Partial outage warning fires and specifically names silent serve-2
      const partialWarn = warnings.find((w) => w.includes("own session(s) but are not writing any live state"));
      expect(partialWarn).toBeDefined();
      expect(partialWarn).toContain("serve-2");
      expect(partialWarn).toBe(
        "serve-2 own session(s) but are not writing any live state -- their writers may be down (1 row(s) reported nodata)",
      );
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("stays silent regarding outage warnings on the healthy path where all owner serves report", () => {
    const dir = mkdir("healthy");
    const routingPath = join(dir, "routing.db");
    const routing = new Database(routingPath);
    routing.exec(`
      CREATE TABLE session_assignment (
        session_id TEXT PRIMARY KEY,
        desired_serve_id TEXT
      );
      CREATE TABLE session_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        sent_at INTEGER NOT NULL
      );
      CREATE TABLE session_reads (
        session_id TEXT PRIMARY KEY,
        last_read_id INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE TABLE session_origin (
        session_id TEXT PRIMARY KEY,
        origin TEXT NOT NULL
      );
    `);
    routing.exec(`INSERT INTO session_assignment VALUES ('s1', 'serve-1'), ('s2', 'serve-2')`);
    routing.close();

    try {
      // Both serve-1 and serve-2 are live and reporting
      overlay(dir, "serve-1-a", { serveId: "serve-1", directory: "/a", sessions: {} });
      overlay(dir, "serve-2-a", { serveId: "serve-2", directory: "/a", sessions: {} });
      const warnings: string[] = [];
      const result = queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, routingDbPath: routingPath, now: Date.now(), staleMs: 45000, isAlive: () => true,
        onWarn: (m) => warnings.push(m),
      });
      // Preconditions: both merged to idle
      expect(result.find((r) => r.id === "s1")?.activity).toBe("idle");
      expect(result.find((r) => r.id === "s2")?.activity).toBe("idle");
      // Neither warning fires
      expect(warnings.some((w) => w.includes("the writer fleet may be down"))).toBe(false);
      expect(warnings.some((w) => w.includes("own session(s) but are not writing any live state"))).toBe(false);
      expect(warnings).toEqual([]);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

/**
 * S3 (round 2, from adversarial review): the serve-level predicate alone is
 * blind to the failure that ACTUALLY happened first -- issue #234 / S0.
 *
 * opencode binds plugins per app INSTANCE. Instances created before a plugin
 * deploy stay writer-less for the life of the serve, while instances created
 * after it write normally on the SAME serve. So a serve can be "reporting"
 * (files for post-deploy directories) while being permanently blind to its
 * pre-deploy ones -- and those are the long-running, actively-worked
 * directories, i.e. exactly the sessions worth seeing.
 *
 * A pure per-(serve, directory) rule catches this but fires on 62% of real rows
 * because instance eviction leaves dormant sessions with no file, forever. The
 * discriminator is RECENCY: if a row was touched in the last FRESH_MS, an
 * instance was loaded for its directory that recently, so a missing file means
 * "not watching", not "evicted". Dormant rows fall back to the serve-level rule.
 *
 * Measured false-alarm rate of this hybrid on the healthy live fleet:
 *   1m 0.00% | 5m 0.00% | 15m 0.00% | 60m 0.00% | 240m 0.27%
 */
describe("S3: per-instance blindness (the #234 failure class)", () => {
  const mkdir = (tag: string) => mkdtempSync(join(tmpdir(), `s3b-${tag}-`));
  const NOW = 1_000_000_000_000;
  const overlay = (dir: string, name: string, o: any) =>
    writeFileSync(join(dir, `${name}.json`), JSON.stringify({
      version: OVERLAY_VERSION, instanceStamp: 1, pid: o.pid ?? process.pid,
      serveId: o.serveId, directory: o.directory,
      heartbeat: o.heartbeat ?? NOW, sessions: o.sessions ?? {},
    }));
  const row = (id: string, directory: string, time_updated: number) => ({
    id, title: id, parent_id: null, directory, time_updated, root_id: id,
  });
  const q = (rows: any[], dir: string, extra: any = {}) => queryWithState(rows, {
    overlayDir: dir, now: NOW, staleMs: 45000, isAlive: () => true,
    owners: { s1: "serve-1" }, ...extra,
  });

  it("reports nodata for a RECENTLY ACTIVE session whose owner writes for other dirs but not this one", () => {
    const dir = mkdir("blind");
    try {
      // serve-1's post-deploy instance writes /b; its pre-deploy /a instance is blind.
      overlay(dir, "serve-1-b", { serveId: "serve-1", directory: "/b" });
      const r = q([row("s1", "/a", NOW - 60_000)], dir); // touched 1 min ago
      expect(r[0].activity).toBe("nodata");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("still reports idle for a DORMANT session in the same shape (eviction is not blindness)", () => {
    const dir = mkdir("dormant");
    try {
      overlay(dir, "serve-1-b", { serveId: "serve-1", directory: "/b" });
      const r = q([row("s1", "/a", NOW - 6 * 60 * 60 * 1000)], dir); // 6h old
      expect(r[0].activity).toBe("idle");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("treats a live owner file with NO directory field as covering any directory", () => {
    const dir = mkdir("wildcard");
    try {
      overlay(dir, "serve-1-nodir", { serveId: "serve-1", directory: undefined });
      const r = q([row("s1", "/a", NOW - 60_000)], dir);
      expect(r[0].activity).toBe("idle");
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

describe("S3: outage warnings survive stale files (review finding 3)", () => {
  const mkdir = (tag: string) => mkdtempSync(join(tmpdir(), `s3c-${tag}-`));
  const NOW = 1_000_000_000_000;
  const overlay = (dir: string, name: string, o: any) =>
    writeFileSync(join(dir, `${name}.json`), JSON.stringify({
      version: OVERLAY_VERSION, instanceStamp: 1, pid: o.pid ?? process.pid,
      serveId: o.serveId, directory: o.directory,
      heartbeat: o.heartbeat ?? NOW, sessions: o.sessions ?? {},
    }));
  const row = (id: string, directory = "/a", time_updated = NOW - 6 * 60 * 60 * 1000) => ({
    id, title: id, parent_id: null, directory, time_updated, root_id: id,
  });

  it("warns when files EXIST but none are live -- the un-deploy leaves stale files behind", () => {
    // A stale-worktree home-manager switch removes the PLUGIN, not the files.
    // The serves keep running, so orphan GC (which requires a dead pid) never
    // collects them; heartbeats simply age out. Sessions named in those stale
    // files merge as `unknown`, so they are NOT nodata -- which made a
    // nodataCount === baseRows.length trigger silent during a total outage.
    const dir = mkdir("stale");
    try {
      overlay(dir, "serve-1-a", {
        serveId: "serve-1", directory: "/a", heartbeat: NOW - 600_000,
        sessions: { s1: { activity: "working", error: false, pendingPermissions: [], pendingQuestions: [], lastActivity: NOW - 600_000, updatedAt: NOW - 600_000 } },
      });
      const warnings: string[] = [];
      const r = queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, now: NOW, staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1", s2: "serve-1" }, onWarn: (m) => warnings.push(m),
      });
      expect(r.find((x) => x.id === "s1")!.unknown).toBe(true);   // stale data, not nodata
      expect(r.find((x) => x.id === "s2")!.activity).toBe("nodata");
      expect(warnings.some((w) => /no live writer/i.test(w))).toBe(true);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("names the specific serves that owe state but are not writing (partial outage)", () => {
    const dir = mkdir("partial");
    try {
      overlay(dir, "serve-2-a", { serveId: "serve-2", directory: "/a" });
      const warnings: string[] = [];
      queryWithState([row("s1"), row("s2")], {
        overlayDir: dir, now: NOW, staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1", s2: "serve-2" }, onWarn: (m) => warnings.push(m),
      });
      expect(warnings.some((w) => /serve-1/.test(w) && !/serve-2/.test(w))).toBe(true);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("stays silent when the fleet is healthy, even with some nodata rows", () => {
    const dir = mkdir("quiet");
    try {
      overlay(dir, "serve-1-a", { serveId: "serve-1", directory: "/a" });
      const warnings: string[] = [];
      queryWithState([row("s1")], {
        overlayDir: dir, now: NOW, staleMs: 45000, isAlive: () => true,
        owners: { s1: "serve-1" }, onWarn: (m) => warnings.push(m),
      });
      expect(warnings.some((w) => /no live writer|not writing/i.test(w))).toBe(false);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

// ---------------------------------------------------------------------------
// S6 (Task 8): fold + row model, and the overlay-truth union.
// ---------------------------------------------------------------------------

describe("S6: effective_state and the child fold", () => {
  const srow = (o: Partial<SessionWithStateRow> & { id: string }): SessionWithStateRow => ({
    title: o.id,
    parent_id: null,
    directory: "/live",
    time_updated: 1000,
    root_id: o.id,
    activity: "idle",
    error: false,
    pendingPermissions: [],
    pendingQuestions: [],
    lastActivity: 1000,
    updatedAt: 1000,
    unread: null,
    unread_state: "absent",
    last_event_id: null,
    anchor_msg_id: null,
    origin: null,
    automated: false,
    ...o,
  });
  // Only "/gone" is missing, so a fixture opts INTO the dir-missing path.
  const statDir = (d: string) => d !== "/gone";
  const fold = (rows: SessionWithStateRow[]) => foldRows(rows, { statDir });

  it("emits roots only, and a blocked CHILD marks the parent without masquerading as its own state", () => {
    const out = fold([
      srow({ id: "r1" }),
      srow({ id: "c1", parent_id: "r1", root_id: "r1", pendingPermissions: ["edit"] }),
    ]);

    // Non-vacuous: exactly one row survives AND it is the root, not the child.
    expect(out.length).toBe(1);
    expect(out[0].id).toBe("r1");
    expect(out[0].child_count).toBe(1);
    expect(out[0].child_state).toBe("blocked");
    // The whole point of the fold: the parent must NOT claim to be blocked itself.
    expect(out[0].effective_state).toBe("idle");
  });

  it("a childless root reports child_state null -- so the assertion above cannot pass vacuously", () => {
    const out = fold([srow({ id: "lonely" })]);
    expect(out.length).toBe(1);
    expect(out[0].child_state).toBeNull();
    expect(out[0].child_count).toBe(0);
  });

  it("lifts the parent's SORT into the child's tier, or the fold would bury the blocked row", () => {
    const out = fold([
      srow({ id: "busy", activity: "working" }),
      srow({ id: "quiet" }),
      srow({ id: "kid", parent_id: "quiet", root_id: "quiet", pendingQuestions: ["q?"] }),
    ]);

    expect(out.map((r) => r.id)).toEqual(["quiet", "busy"]);
    expect(out[0].sort_rank).toBeLessThan(out[1].sort_rank);
  });

  it("folds a GRANDCHILD's state up to the true root (depth > 1, which live data never exercises)", () => {
    const out = fold([
      srow({ id: "gr" }),
      srow({ id: "mid", parent_id: "gr", root_id: "gr" }),
      srow({ id: "grand", parent_id: "mid", root_id: "gr", error: true }),
    ]);

    expect(out.length).toBe(1);
    expect(out[0].id).toBe("gr");
    expect(out[0].child_count).toBe(2);
    expect(out[0].child_state).toBe("error");
    expect(out[0].sort_rank).toBe(0);
  });

  it("takes the WORST child, not the first or last one seen", () => {
    const out = fold([
      srow({ id: "r" }),
      srow({ id: "a", parent_id: "r", root_id: "r", activity: "working" }),
      srow({ id: "b", parent_id: "r", root_id: "r", error: true }),
      srow({ id: "c", parent_id: "r", root_id: "r", activity: "idle" }),
    ]);
    expect(out[0].child_state).toBe("error");
    expect(out[0].child_count).toBe(3);
  });

  it("resolves effective_state by precedence, not by whichever field it looked at first", () => {
    const seen = (r: SessionWithStateRow) => fold([r])[0].effective_state;

    // unknown outranks everything: its data came from a dead writer, so every
    // other field on the row is last-known rather than current.
    expect(seen(srow({ id: "u", unknown: true, error: true, activity: "working" }))).toBe("unknown");
    expect(seen(srow({ id: "e", error: true, pendingPermissions: ["x"] }))).toBe("error");
    expect(seen(srow({ id: "b1", pendingPermissions: ["x"] }))).toBe("blocked");
    expect(seen(srow({ id: "b2", pendingQuestions: ["x"] }))).toBe("blocked");
    expect(seen(srow({ id: "rt", activity: "retry" }))).toBe("retry");
    expect(seen(srow({ id: "w", activity: "working" }))).toBe("working");
    expect(seen(srow({ id: "n", activity: "nodata" }))).toBe("nodata");
    expect(seen(srow({ id: "i" }))).toBe("idle");
  });

  it("sorts an error row above a non-attention row that is far more recent", () => {
    const out = fold([
      srow({ id: "busy_recent", activity: "working", lastActivity: 9999 }),
      srow({ id: "err_stale", error: true, lastActivity: 100 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["err_stale", "busy_recent"]);
    expect(out[0].attention).toBe(true);
    expect(out[1].attention).toBe(false);
  });

  it("sorts a blocked row above a non-attention row that is far more recent", () => {
    const out = fold([
      srow({ id: "idle_recent", lastActivity: 9999 }),
      srow({ id: "blocked_stale", pendingQuestions: ["approve?"], lastActivity: 100 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["blocked_stale", "idle_recent"]);
    expect(out[0].attention).toBe(true);
    expect(out[1].attention).toBe(false);
  });

  it("orders within the attention group by descending tree-max lastActivity", () => {
    const out = fold([
      srow({ id: "err_older", error: true, lastActivity: 500 }),
      srow({ id: "blocked_newer", pendingPermissions: ["run"], lastActivity: 1000 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["blocked_newer", "err_older"]);
    expect(out[0].attention).toBe(true);
    expect(out[1].attention).toBe(true);
  });

  it("orders within the non-attention group by descending tree-max lastActivity (recent idle beats stale working)", () => {
    const out = fold([
      srow({ id: "stale_working", activity: "working", lastActivity: 100 }),
      srow({ id: "recent_idle", activity: "idle", lastActivity: 5000 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["recent_idle", "stale_working"]);
    expect(out[0].attention).toBe(false);
    expect(out[1].attention).toBe(false);
  });

  it("sorts a stale nodata row BELOW a recent idle row (deliberate regression of old privilege)", () => {
    const out = fold([
      srow({ id: "stale_nodata", activity: "nodata", lastActivity: 100 }),
      srow({ id: "recent_idle", activity: "idle", lastActivity: 5000 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["recent_idle", "stale_nodata"]);
    expect(out[0].attention).toBe(false);
    expect(out[1].attention).toBe(false);
  });

  it("lifts an idle parent into the attention group when its child is blocked, sorting above recent non-attention roots", () => {
    const out = fold([
      srow({ id: "recent_working", activity: "working", lastActivity: 9999 }),
      srow({ id: "idle_parent", activity: "idle", lastActivity: 100 }),
      srow({ id: "blocked_child", parent_id: "idle_parent", root_id: "idle_parent", pendingQuestions: ["q?"], lastActivity: 100 }),
    ]);
    expect(out.map((r) => r.id)).toEqual(["idle_parent", "recent_working"]);
    expect(out[0].attention).toBe(true);
    expect(out[0].effective_state).toBe("idle");
    expect(out[0].child_state).toBe("blocked");
    expect(out[1].attention).toBe(false);
  });

  it("keeps a dir-gone row's state TRUTHFUL but demotes it so blocked is NOT in the attention group", () => {
    const out = fold([
      srow({ id: "gone", pendingQuestions: ["q?"], directory: "/gone", lastActivity: 9999 }),
      srow({ id: "real", pendingQuestions: ["q?"], directory: "/live", lastActivity: 1 }),
    ]);

    const gone = out.find((r) => r.id === "gone")!;
    const real = out.find((r) => r.id === "real")!;
    expect(gone.dir_missing).toBe(true);
    expect(gone.effective_state).toBe("blocked");
    expect(gone.attention).toBe(false);
    expect(real.dir_missing).toBe(false);
    expect(real.effective_state).toBe("blocked");
    expect(real.attention).toBe(true);
    // Real blocked row is in attention group, so it sorts before gone despite older lastActivity
    expect(out.map((r) => r.id)).toEqual(["real", "gone"]);
  });

  it("keeps a dir-gone ERROR row's state TRUTHFUL but demotes it so error is NOT in the attention group", () => {
    const out = fold([
      srow({ id: "gone_err", error: true, directory: "/gone", lastActivity: 9999 }),
      srow({ id: "real_err", error: true, directory: "/live", lastActivity: 1 }),
    ]);

    const gone = out.find((r) => r.id === "gone_err")!;
    const real = out.find((r) => r.id === "real_err")!;
    expect(gone.dir_missing).toBe(true);
    expect(gone.effective_state).toBe("error");
    expect(gone.attention).toBe(false);
    expect(real.dir_missing).toBe(false);
    expect(real.effective_state).toBe("error");
    expect(real.attention).toBe(true);
    // Real error row is in attention group, so it sorts before gone despite older lastActivity
    expect(out.map((r) => r.id)).toEqual(["real_err", "gone_err"]);
  });

  it("does not let a dir-gone CHILD lift its parent into the attention group either", () => {
    const out = fold([
      srow({ id: "p1" }),
      srow({ id: "k1", parent_id: "p1", root_id: "p1", pendingQuestions: ["q?"], directory: "/gone" }),
      srow({ id: "p2", pendingQuestions: ["q?"] }),
    ]);
    // p2 is genuinely blocked; p1's only blocked child is dir_missing so demoted.
    expect(out.map((r) => r.id)).toEqual(["p2", "p1"]);
    expect(out.find((r) => r.id === "p1")!.child_state).toBe("blocked");
    expect(out.find((r) => r.id === "p1")!.attention).toBe(false);
    expect(out.find((r) => r.id === "p2")!.attention).toBe(true);
  });

  it("dates a root by its whole TREE, so a working subagent does not sink its silent parent (tree-max lastActivity, NOT root's own time_updated)", () => {
    const out = fold([
      srow({ id: "old", time_updated: 100, lastActivity: 100 }),
      srow({ id: "kid", parent_id: "old", root_id: "old", time_updated: 5000, lastActivity: 5000 }),
      srow({ id: "recent", time_updated: 900, lastActivity: 900 }),
    ]);
    expect(out.find((r) => r.id === "old")!.lastActivity).toBe(5000);
    expect(out.map((r) => r.id)).toEqual(["old", "recent"]);
  });

  it("emits the attention boolean matching group membership across all states", () => {
    const out = fold([
      srow({ id: "err", error: true }),
      srow({ id: "blk", pendingQuestions: ["?"] }),
      srow({ id: "ret", activity: "retry" }),
      srow({ id: "wrk", activity: "working" }),
      srow({ id: "nod", activity: "nodata" }),
      srow({ id: "unk", unknown: true }),
      srow({ id: "idl" }),
    ]);
    const byId = new Map(out.map((r) => [r.id, r]));
    expect(byId.get("err")!.attention).toBe(true);
    expect(byId.get("blk")!.attention).toBe(true);
    expect(byId.get("ret")!.attention).toBe(false);
    expect(byId.get("wrk")!.attention).toBe(false);
    expect(byId.get("nod")!.attention).toBe(false);
    expect(byId.get("unk")!.attention).toBe(false);
    expect(byId.get("idl")!.attention).toBe(false);
  });

  it("does not allow unread count to alter ordering within attention or non-attention groups", () => {
    // In non-attention group: recent idle with 0 unread beats older idle with 99 unread
    const nonAttention = fold([
      srow({ id: "older_with_unread", lastActivity: 1000, unread: 99, unread_state: "counted" }),
      srow({ id: "newer_read", lastActivity: 2000, unread: 0, unread_state: "counted" }),
    ]);
    expect(nonAttention.map((r) => r.id)).toEqual(["newer_read", "older_with_unread"]);

    // In attention group: recent error with 0 unread beats older error with 99 unread
    const attention = fold([
      srow({ id: "older_err_unread", error: true, lastActivity: 1000, unread: 99, unread_state: "counted" }),
      srow({ id: "newer_err_read", error: true, lastActivity: 2000, unread: 0, unread_state: "counted" }),
    ]);
    expect(attention.map((r) => r.id)).toEqual(["newer_err_read", "older_err_unread"]);
  });

  it("stats each distinct directory once, however many rows share it", () => {
    const calls: string[] = [];
    foldRows(
      [srow({ id: "a" }), srow({ id: "b" }), srow({ id: "c", directory: "/other" })],
      { statDir: (d) => { calls.push(d); return true; } },
    );
    expect(calls.sort()).toEqual(["/live", "/other"]);
  });

  it("orders ties deterministically rather than by input order", () => {
    const a = fold([srow({ id: "z" }), srow({ id: "y" })]).map((r) => r.id);
    const b = fold([srow({ id: "y" }), srow({ id: "z" })]).map((r) => r.id);
    expect(a).toEqual(b);
    expect(a).toEqual(["y", "z"]);
  });

  it("returns [] for no rows -- paired with a non-empty case so it cannot pass by always returning []", () => {
    expect(fold([])).toEqual([]);
    expect(fold([srow({ id: "one" })]).length).toBe(1);
  });
});

describe("S6: overlay-truth union (attention rows outside the recency window)", () => {
  const mk = (tag: string) => mkdtempSync(join(tmpdir(), `s6-${tag}-`));
  const writeOverlay = (
    dir: string,
    name: string,
    o: { serveId: string; pid?: number; heartbeat?: number; sessions: any },
  ) => {
    writeFileSync(
      join(dir, `${name}.json`),
      JSON.stringify({
        version: OVERLAY_VERSION,
        instanceStamp: 1,
        pid: o.pid ?? process.pid,
        serveId: o.serveId,
        heartbeat: o.heartbeat ?? Date.now(),
        sessions: o.sessions,
      }),
    );
  };
  const working = (lastActivity = 5000) => ({
    activity: "working",
    error: false,
    pendingPermissions: [],
    pendingQuestions: [],
    lastActivity,
    updatedAt: lastActivity,
  });
  const insert = (db: Database, id: string, parent: string | null, t: number, archived: number | null = null) =>
    db.exec(
      `INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
       VALUES ('${id}', 'p', ${parent ? `'${parent}'` : "NULL"}, '${id}', '/w', '${id}', '1.0', 1, ${t}, ${archived === null ? "NULL" : archived})`,
    );

  it("pulls in a blocked/working session the recency LIMIT dropped -- and drops it again without the lookup", () => {
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "forgotten", null, 10); // far outside a limit=1 window
    const dir = mk("union");
    try {
      writeOverlay(dir, "s1", { serveId: "serve-1", sessions: { forgotten: working() } });
      const base = queryBaseList(db, { limit: 1 });
      expect(base.map((r) => r.id)).toEqual(["recent"]); // the row IS outside the window

      // Two-sided: without the lookup the attention row is genuinely absent...
      const without = queryWithState(base, { overlayDir: dir, owners: {} });
      expect(without.map((r) => r.id)).not.toContain("forgotten");

      // ...and with it, present.
      const withUnion = queryWithState(base, {
        overlayDir: dir,
        owners: {},
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      expect(withUnion.map((r) => r.id)).toContain("forgotten");
      // It went through the MERGE, not merely appended: it carries live state.
      expect(withUnion.find((r) => r.id === "forgotten")!.activity).toBe("working");
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("refuses to resurrect an ARCHIVED session, while its unarchived twin proves the overlay loaded", () => {
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "archived_one", null, 10, 12345);
    insert(db, "live_one", null, 10);
    const dir = mk("archived");
    try {
      writeOverlay(dir, "s1", {
        serveId: "serve-1",
        sessions: { archived_one: working(), live_one: working() },
      });
      const rows = queryWithState(queryBaseList(db, { limit: 1 }), {
        overlayDir: dir,
        owners: {},
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      const ids = rows.map((r) => r.id);
      expect(ids).not.toContain("archived_one");
      // The paired positive: same file, same code path, so "absent" above is a
      // decision about archiving rather than an overlay that never parsed.
      expect(ids).toContain("live_one");
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("unions the WHOLE TREE when the overlay names a child, so the fold has a root to fold into", () => {
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "old_root", null, 10);
    insert(db, "old_kid", "old_root", 20);
    const dir = mk("tree");
    try {
      writeOverlay(dir, "s1", { serveId: "serve-1", sessions: { old_kid: working() } });
      const rows = queryWithState(queryBaseList(db, { limit: 1 }), {
        overlayDir: dir,
        owners: {},
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      const ids = rows.map((r) => r.id);
      expect(ids).toContain("old_kid");
      expect(ids).toContain("old_root"); // the root came too
      expect(rows.find((r) => r.id === "old_kid")!.root_id).toBe("old_root");

      // And the fold turns that into one root row carrying the child's state.
      const folded = foldRows(rows, { statDir: () => true });
      const root = folded.find((r) => r.id === "old_root")!;
      expect(root.child_state).toBe("working");
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("ignores STALE files, so an un-deploy's orphaned overlays cannot flood the list", () => {
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "ghost", null, 10);
    const dir = mk("stale");
    try {
      // Dead pid + ancient heartbeat: the un-deploy shape (files linger, serve gone).
      writeOverlay(dir, "s1", {
        serveId: "serve-1",
        pid: 999999,
        heartbeat: 0,
        sessions: { ghost: working() },
      });
      const rows = queryWithState(queryBaseList(db, { limit: 1 }), {
        overlayDir: dir,
        owners: {},
        isAlive: () => false,
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      expect(rows.map((r) => r.id)).not.toContain("ghost");
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("unions only attention states -- a live-but-idle session stays out", () => {
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "sleepy", null, 10);
    insert(db, "busy", null, 10);
    const dir = mk("idle");
    try {
      writeOverlay(dir, "s1", {
        serveId: "serve-1",
        sessions: {
          sleepy: { ...working(), activity: "idle" },
          busy: working(),
        },
      });
      const rows = queryWithState(queryBaseList(db, { limit: 1 }), {
        overlayDir: dir,
        owners: {},
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      const ids = rows.map((r) => r.id);
      expect(ids).not.toContain("sleepy");
      expect(ids).toContain("busy"); // paired positive: the file was read
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("never duplicates a row a lookup hands back twice (or hands back one we already had)", () => {
    // Today's queryTreesForSessions cannot produce an overlap -- queryBaseList
    // returns whole trees, so a candidate's root is either fully in the window
    // or fully out. This pins the CONTRACT rather than that coincidence: a
    // lookup is allowed to be sloppy, and the union must still be a set. Without
    // it the dedupe is unexercised code that a future lookup change would break
    // into a picker showing the same session twice.
    const db = createTestDb();
    insert(db, "recent", null, 9000);
    insert(db, "outside", null, 10);
    const dir = mk("dupe");
    try {
      writeOverlay(dir, "s1", { serveId: "serve-1", sessions: { outside: working() } });
      const base = queryBaseList(db, { limit: 1 });
      const dupRow = { id: "outside", title: "outside", parent_id: null, directory: "/w", time_updated: 10, root_id: "outside" };
      const rows = queryWithState(base, {
        overlayDir: dir,
        owners: {},
        // Returns the same row twice AND a row already in the base list.
        unionLookup: () => [dupRow, dupRow, base[0]],
      });
      const ids = rows.map((r) => r.id);
      expect(ids).toContain("outside");
      expect(ids.filter((i) => i === "outside").length).toBe(1);
      expect(ids.filter((i) => i === "recent").length).toBe(1);
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("names candidates from LIVE files only, deduped and ordered", () => {
    const live = {
      file: { serveId: "s1", pid: 1, heartbeat: 0, sessions: { b: working(), a: { ...working(), activity: "retry" }, z: { ...working(), activity: "idle" } } },
      serveId: "s1", pid: 1, live: true,
    } as any;
    const dead = {
      file: { serveId: "s2", pid: 2, heartbeat: 0, sessions: { ghost: working() } },
      serveId: "s2", pid: 2, live: false,
    } as any;
    expect(attentionCandidates([live, dead])).toEqual(["a", "b"]);
  });
});

describe("S6: --fold CLI flag", () => {
  it("parses --fold and implies --with-state (folding unmerged rows would be silently empty)", () => {
    const opts = parseCliArgs(["--fold"]);
    expect(opts.fold).toBe(true);
    expect(opts.withState).toBe(true);
    expect(parseCliArgs(["--with-state"]).fold).toBe(false);
  });
});

describe("S6: the union lands BEFORE ownership is resolved", () => {
  it("arbitrates a unioned session by its OWNER, not merely by the newest file", () => {
    // Two live writers disagree about the same unioned session. Rule 1 says a
    // live OWNER wins outright; Rule 2 (no owner known) says newest wins. They
    // are made to disagree here, so the assertion can only pass if the unioned
    // row was present when buildOwnersMap ran. Appending unioned rows after
    // ownership -- the tempting refactor -- silently drops them to Rule 2.
    const db = createTestDb();
    db.exec(
      `INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
       VALUES ('recent','p',NULL,'recent','/w','recent','1.0',1,9000,NULL)`,
    );
    db.exec(
      `INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
       VALUES ('outside','p',NULL,'outside','/w','outside','1.0',1,10,NULL)`,
    );

    const dir = mkdtempSync(join(tmpdir(), "s6-owner-"));
    const routingPath = join(dir, "routing.db");
    const routing = new Database(routingPath);
    routing.exec(`CREATE TABLE session_assignment (session_id TEXT PRIMARY KEY, desired_serve_id TEXT)`);
    routing.exec(`INSERT INTO session_assignment VALUES ('outside','serve-owner')`);
    routing.close();

    const entry = (activity: string, lastActivity: number) => ({
      activity, error: false, pendingPermissions: [], pendingQuestions: [], lastActivity, updatedAt: lastActivity,
    });
    const file = (name: string, serveId: string, e: any) =>
      writeFileSync(join(dir, name), JSON.stringify({
        version: OVERLAY_VERSION, instanceStamp: 1, pid: process.pid, serveId,
        directory: "/w", heartbeat: Date.now(), sessions: { outside: e },
      }));
    // The owner is OLDER, so "newest wins" and "owner wins" give different answers.
    file("owner.json", "serve-owner", entry("working", 100));
    file("other.json", "serve-other", entry("retry", 5000));

    try {
      const rows = queryWithState(queryBaseList(db, { limit: 1 }), {
        overlayDir: dir,
        routingDbPath: routingPath,
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });
      const outside = rows.find((r) => r.id === "outside");
      expect(outside).toBeDefined();
      expect(outside!.activity).toBe("working"); // owner won; Rule 2 would say "retry"
    } finally {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("buildUnreadMap & unread counts (Task 9)", () => {
  const baseRows = [
    { id: "root_1", title: "Root 1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "child_1", title: "Child 1", parent_id: "root_1", directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "root_2", title: "Root 2", parent_id: null, directory: "/p", time_updated: 2000, root_id: "root_2" },
  ];

  function createTestRoutingDb(path: string): Database {
    const db = new Database(path);
    db.exec(`
      CREATE TABLE session_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        sent_at INTEGER NOT NULL
      );
      CREATE TABLE session_reads (
        session_id TEXT PRIMARY KEY,
        last_read_id INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);
    return db;
  }

  function createTestRoutingDbWithAnchor(path: string): Database {
    const db = new Database(path);
    db.exec(`
      CREATE TABLE session_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        sent_at INTEGER NOT NULL,
        anchor_msg_id TEXT
      );
      CREATE TABLE session_reads (
        session_id TEXT PRIMARY KEY,
        last_read_id INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
    `);
    return db;
  }

  it("a session with events above the watermark reports that count", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'stop', 100),
          (2, 'root_1', 'swarm', 200),
          (3, 'root_1', 'stop', 300);
        INSERT INTO session_reads (session_id, last_read_id, updated_at) VALUES
          ('root_1', 1, 150);
      `);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).not.toBeNull();
      const entry = unreadMap!.get("root_1");
      expect(entry).toBeDefined();
      expect(entry!.unread).toBe(2);
      expect(entry!.last_event_id).toBe(3);
      expect(entry!.last_event_at).toBe(300);
      expect(warnings).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("kind='mirror' rows are excluded from the count", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'swarm', 100),
          (2, 'root_1', 'mirror', 200),
          (3, 'root_1', 'mirror', 250),
          (4, 'root_1', 'stop', 300);
      `);
      db.close();

      const unreadMap = buildUnreadMap(p, baseRows);
      expect(unreadMap).not.toBeNull();
      const entry = unreadMap!.get("root_1");
      expect(entry).toBeDefined();
      expect(entry!.unread).toBe(2); // events 1 and 4 only, 2 & 3 excluded
      expect(entry!.last_event_id).toBe(4);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("absent session yields unread_state 'absent' and unread null, NOT 0 (prevents silent-zero regression)", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      // Only root_1 has events in ledger; root_2 is completely absent
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'stop', 100);
      `);
      db.close();

      const unreadMap = buildUnreadMap(p, baseRows);
      expect(unreadMap).not.toBeNull();
      expect(unreadMap!.has("root_2")).toBe(false);

      const rows = queryWithState(baseRows, {
        routingDbPath: p,
      });

      const root2 = rows.find((r) => r.id === "root_2");
      expect(root2).toBeDefined();
      expect(root2!.unread_state).toBe("absent");
      expect(root2!.unread).toBeNull();
      expect(root2!.unread).not.toBe(0);
      expect(root2!.last_event_id).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a session whose ledger rows are ALL at or below the watermark reports unread: 0 with unread_state: 'counted'", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'stop', 100),
          (2, 'root_1', 'swarm', 200);
        INSERT INTO session_reads (session_id, last_read_id, updated_at) VALUES
          ('root_1', 2, 250);
      `);
      db.close();

      const rows = queryWithState(baseRows, {
        routingDbPath: p,
      });

      const root1 = rows.find((r) => r.id === "root_1");
      expect(root1).toBeDefined();
      expect(root1!.unread_state).toBe("counted");
      expect(root1!.unread).toBe(0);
      expect(root1!.last_event_id).toBe(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a session whose ledger rows are ALL kind='mirror' reports unread: 0 with unread_state: 'counted' and non-null last_event_id", () => {
    // Deliberate judgement: mirror events are the session's own outbound messages mirrored
    // back into the ledger and are never unread-worthy. The session is counted and up to date
    // (rendering empty badge rather than '?'), with a valid last_event_id pointing to the mirror event.
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'mirror', 100),
          (2, 'root_1', 'mirror', 200);
      `);
      db.close();

      const rows = queryWithState(baseRows, {
        routingDbPath: p,
      });

      const root1 = rows.find((r) => r.id === "root_1");
      expect(root1).toBeDefined();
      expect(root1!.unread_state).toBe("counted");
      expect(root1!.unread).toBe(0);
      expect(root1!.last_event_id).toBe(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("an unreadable/missing routing DB yields unread_state: 'unavailable' for every row, emits a warning, and STILL returns base list", () => {
    const warnings: string[] = [];
    const missingPath = "/definitely/not/a/real/routing.db";

    const unreadMap = buildUnreadMap(missingPath, baseRows, (m) => warnings.push(m));
    expect(unreadMap).toBeNull();
    expect(warnings.length).toBeGreaterThanOrEqual(1);
    expect(warnings.some((w) => w.includes("routing db not found") || w.includes("unavailable"))).toBe(true);

    const rows = queryWithState(baseRows, {
      routingDbPath: missingPath,
      onWarn: (m) => warnings.push(m),
    });

    expect(rows.length).toBe(baseRows.length);
    for (const r of rows) {
      expect(r.unread_state).toBe("unavailable");
      expect(r.unread).toBeNull();
      expect(r.last_event_id).toBeNull();
    }
  });

  it("a routing DB lacking the session_events table yields unread_state: 'unavailable', emits warning, and returns base list", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = new Database(p);
      db.exec(`CREATE TABLE some_other_table (id INTEGER PRIMARY KEY)`);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).toBeNull();
      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("no session_events table");

      const rows = queryWithState(baseRows, {
        routingDbPath: p,
        onWarn: (m) => warnings.push(m),
      });

      expect(rows.length).toBe(baseRows.length);
      for (const r of rows) {
        expect(r.unread_state).toBe("unavailable");
        expect(r.unread).toBeNull();
        expect(r.last_event_id).toBeNull();
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("last_event_id is emitted and equals MAX(id) for that session", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (2, 'root_1', 'stop', 100),
          (7, 'root_1', 'swarm', 200),
          (15, 'root_1', 'stop', 300);
      `);
      db.close();

      const rows = queryWithState(baseRows, {
        routingDbPath: p,
      });

      const root1 = rows.find((r) => r.id === "root_1");
      expect(root1).toBeDefined();
      expect(root1!.last_event_id).toBe(15);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a CHILD row carrying unread events triggers a warning", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'child_1', 'swarm', 100),
          (2, 'child_1', 'stop', 200);
      `);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).not.toBeNull();
      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("child session child_1 carries 2 unread event(s)");
      expect(warnings[0]).toContain("root-only");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a ledger session_id absent from baseRows does NOT trigger the child warning", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'outside_child', 'swarm', 100),
          (2, 'outside_child', 'stop', 200);
      `);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).not.toBeNull();
      expect(warnings).toEqual([]); // No warnings for sessions not in baseRows
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("event with id 0 is not counted when watermark is unread / COALESCE(r.last_read_id, 0)", () => {
    // Note: unreachable in production because the ledger's id column is INTEGER PRIMARY KEY
    // AUTOINCREMENT and therefore starts at 1. COALESCE(r.last_read_id, 0) treating 0 as the
    // "unread / no watermark" sentinel is safe here, but do not copy this pattern to schemas
    // where rowid/id 0 can legitimately occur.
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (0, 'root_1', 'stop', 100);
      `);
      db.close();

      const unreadMap = buildUnreadMap(p, baseRows);
      expect(unreadMap).not.toBeNull();
      const entry = unreadMap!.get("root_1");
      expect(entry).toBeDefined();
      // id 0 is <= 0, so COUNT(*) FILTER (WHERE e.id > COALESCE(r.last_read_id, 0)) gives 0
      expect(entry!.unread).toBe(0);
      expect(entry!.last_event_id).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("stays SILENT on the healthy path (no unexpected warnings)", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'stop', 100);
      `);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).not.toBeNull();
      expect(warnings).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("extracts oldest uncleared non-mirror non-null anchor_msg_id", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDbWithAnchor(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at, anchor_msg_id) VALUES
          (1, 'root_1', 'stop', 100, 'msg_old_cleared'),
          (2, 'root_1', 'mirror', 200, 'msg_mirror'),
          (3, 'root_1', 'stop', 300, NULL),
          (4, 'root_1', 'stop', 400, 'msg_oldest_unread'),
          (5, 'root_1', 'swarm', 500, 'msg_newer_unread');
        INSERT INTO session_reads (session_id, last_read_id, updated_at) VALUES
          ('root_1', 1, 150);
      `);
      db.close();

      const unreadMap = buildUnreadMap(p, baseRows);
      expect(unreadMap).not.toBeNull();
      const entry = unreadMap!.get("root_1");
      expect(entry).toBeDefined();
      expect(entry!.unread).toBe(3); // events 3, 4, 5 (2 is mirror, 1 is cleared)
      expect(entry!.anchor_msg_id).toBe("msg_oldest_unread"); // event 4 is oldest uncleared non-mirror with non-null anchor
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("missing anchor_msg_id column degrades to anchor_msg_id: null with unread counts intact", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDb(p); // has no anchor_msg_id column
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at) VALUES
          (1, 'root_1', 'stop', 100),
          (2, 'root_1', 'stop', 200);
      `);
      db.close();

      const warnings: string[] = [];
      const unreadMap = buildUnreadMap(p, baseRows, (m) => warnings.push(m));
      expect(unreadMap).not.toBeNull();
      const entry = unreadMap!.get("root_1");
      expect(entry).toBeDefined();
      expect(entry!.unread).toBe(2);
      expect(entry!.anchor_msg_id).toBeNull();
      expect(warnings).toEqual([]);

      const rows = queryWithState(baseRows, { routingDbPath: p });
      const root1 = rows.find((r) => r.id === "root_1");
      expect(root1).toBeDefined();
      expect(root1!.unread_state).toBe("counted");
      expect(root1!.unread).toBe(2);
      expect(root1!.anchor_msg_id).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("queryWithState threads anchor_msg_id onto SessionWithStateRow", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-unread-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestRoutingDbWithAnchor(p);
      db.exec(`
        INSERT INTO session_events (id, session_id, kind, sent_at, anchor_msg_id) VALUES
          (1, 'root_1', 'stop', 100, 'msg_anchor_123');
      `);
      db.close();

      const rows = queryWithState(baseRows, { routingDbPath: p });
      const root1 = rows.find((r) => r.id === "root_1");
      expect(root1).toBeDefined();
      expect(root1!.unread_state).toBe("counted");
      expect(root1!.unread).toBe(1);
      expect(root1!.anchor_msg_id).toBe("msg_anchor_123");

      const root2 = rows.find((r) => r.id === "root_2");
      expect(root2).toBeDefined();
      expect(root2!.unread_state).toBe("absent");
      expect(root2!.anchor_msg_id).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("buildOriginMap & automated origins (Task 1)", () => {
  const baseRows = [
    { id: "root_1", title: "Root 1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "child_1", title: "Child 1", parent_id: "root_1", directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "root_2", title: "Root 2", parent_id: null, directory: "/p", time_updated: 2000, root_id: "root_2" },
  ];

  it("maps lgtm origin and classifies it as automated", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('root_1', 'lgtm', 'errors-only', 1000);
      `);
      db.close();

      const warnings: string[] = [];
      const originMap = buildOriginMap(p, baseRows, (m) => warnings.push(m));
      expect(originMap).not.toBeNull();
      expect(originMap!.get("root_1")).toBe("lgtm");
      expect(isAutomatedOrigin(originMap!.get("root_1"))).toBe(true);
      expect(warnings).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("coerces a non-string origin to string, keeping OriginMap's declared type honest", () => {
    // SQLite is dynamically typed and `origin` is free-form TEXT with no CHECK
    // constraint, so a writer CAN land a number here. Without coercion it flows
    // into a Map<string,string> and out through `origin: string | null` as a
    // JSON number -- both declared types quietly false. The odd value must
    // still trip the tripwire, since it is exactly the case worth reporting.
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('root_num', 123, 'errors-only', 1000);
      `);
      db.close();

      const warnings: string[] = [];
      const originMap = buildOriginMap(p, baseRows, (m) => warnings.push(m));
      expect(typeof originMap!.get("root_num")).toBe("string");
      expect(originMap!.get("root_num")).toBe("123");
      expect(isAutomatedOrigin(originMap!.get("root_num"))).toBe(false);
      expect(warnings.filter((w) => w.includes("123")).length).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("maps unknown origin, marks isAutomatedOrigin false, and trips warning exactly once across three rows sharing that origin", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('root_1', 'custom-pipeline', 'all', 1000),
          ('root_2', 'custom-pipeline', 'none', 1000),
          ('root_3', 'custom-pipeline', 'errors-only', 1000);
      `);
      db.close();

      const warnings: string[] = [];
      const originMap = buildOriginMap(p, baseRows, (m) => warnings.push(m));
      expect(originMap).not.toBeNull();
      expect(originMap!.get("root_1")).toBe("custom-pipeline");
      expect(originMap!.get("root_2")).toBe("custom-pipeline");
      expect(originMap!.get("root_3")).toBe("custom-pipeline");
      expect(isAutomatedOrigin(originMap!.get("root_1"))).toBe(false);
      expect(isAutomatedOrigin(originMap!.get("root_2"))).toBe(false);
      expect(isAutomatedOrigin(originMap!.get("root_3"))).toBe(false);

      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("custom-pipeline");
      expect(warnings[0]).toContain("HIDDEN_ORIGINS");
      expect(warnings[0]).toContain("KNOWN_VISIBLE_ORIGINS");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("notify_policy variations (all, errors-only, none) do NOT change the verdict", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('s_all', 'lgtm', 'all', 1000),
          ('s_err', 'lgtm', 'errors-only', 1000),
          ('s_none', 'lgtm', 'none', 1000),
          ('u_all', 'other-tool', 'all', 1000),
          ('u_none', 'other-tool', 'none', 1000);
      `);
      db.close();

      const originMap = buildOriginMap(p, baseRows);
      expect(originMap).not.toBeNull();
      expect(isAutomatedOrigin(originMap!.get("s_all"))).toBe(true);
      expect(isAutomatedOrigin(originMap!.get("s_err"))).toBe(true);
      expect(isAutomatedOrigin(originMap!.get("s_none"))).toBe(true);
      expect(isAutomatedOrigin(originMap!.get("u_all"))).toBe(false);
      expect(isAutomatedOrigin(originMap!.get("u_none"))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns null and emits a warning when routing DB does not exist", () => {
    const warnings: string[] = [];
    const missingPath = "/definitely/not/a/real/origin_routing.db";

    const originMap = buildOriginMap(missingPath, baseRows, (m) => warnings.push(m));
    expect(originMap).toBeNull();
    expect(warnings.length).toBe(1);
    expect(warnings[0]).toContain("routing db not found");
  });

  it("returns null and emits a warning when routing DB lacks session_origin table", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "routing.db");
      const db = new Database(p);
      db.exec(`CREATE TABLE unrelated_table (id INTEGER PRIMARY KEY);`);
      db.close();

      const warnings: string[] = [];
      const originMap = buildOriginMap(p, baseRows, (m) => warnings.push(m));
      expect(originMap).toBeNull();
      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("no session_origin table");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns null and emits a warning when reading routing DB throws", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-origin-"));
    try {
      const p = join(dir, "corrupt.db");
      writeFileSync(p, "not a valid sqlite database file");

      const warnings: string[] = [];
      const originMap = buildOriginMap(p, baseRows, (m) => warnings.push(m));
      expect(originMap).toBeNull();
      expect(warnings.length).toBe(1);
      expect(warnings[0]).toContain("failed to read");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("unacknowledgedOrigins pure helper & KNOWN_VISIBLE_ORIGINS", () => {
  it("an origin in visible set produces no tripwire warning (omitted from unacknowledged list)", () => {
    const hidden = new Set(["lgtm"]);
    const visible = new Set(["custom-visible-bot", "my-pipeline"]);
    const origins = ["custom-visible-bot", "lgtm", "unrecognized-tool", "custom-visible-bot"];
    const unack = unacknowledgedOrigins(origins, hidden, visible);
    expect(unack).toEqual(["unrecognized-tool"]);
  });

  it("an origin in neither set is returned, and duplicates collapse to a single entry in deterministic sorted order", () => {
    const hidden = new Set(["lgtm"]);
    const visible = new Set(["acknowledged"]);
    const origins = ["zeta-bot", "alpha-bot", "zeta-bot", "alpha-bot", "acknowledged", "lgtm", ""];
    const unack = unacknowledgedOrigins(origins, hidden, visible);
    expect(unack).toEqual(["alpha-bot", "zeta-bot"]);
  });

  it("an origin in visible set remains automated: false (acknowledged-visible does NOT mean hidden)", () => {
    const visibleOrigin = "custom-visible-bot";
    // Even when an origin is acknowledged in KNOWN_VISIBLE_ORIGINS, isAutomatedOrigin returns false
    expect(isAutomatedOrigin(visibleOrigin)).toBe(false);
  });
});

describe("annotate rows with origin and automated (Task 2)", () => {
  const baseRows = [
    { id: "root_1", title: "Root 1", parent_id: null, directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "child_1", title: "Child 1", parent_id: "root_1", directory: "/p", time_updated: 1000, root_id: "root_1" },
    { id: "root_2", title: "Root 2", parent_id: null, directory: "/p", time_updated: 2000, root_id: "root_2" },
  ];

  it("rows get origin and automated fields, and row with no origin gets null/false", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-annotate-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('root_1', 'lgtm', 'all', 1000);
      `);
      db.close();

      const rows = queryWithState(baseRows, { routingDbPath: p });
      const root1 = rows.find((r) => r.id === "root_1");
      const root2 = rows.find((r) => r.id === "root_2");

      expect(root1).toBeDefined();
      expect(root1!.origin).toBe("lgtm");
      expect(root1!.automated).toBe(true);

      expect(root2).toBeDefined();
      expect(root2!.origin).toBeNull();
      expect(root2!.automated).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a child whose root_id is an lgtm root is marked automated (keyed on root_id, not id)", () => {
    const dir = mkdtempSync(join(tmpdir(), "oc-annotate-"));
    try {
      const p = join(dir, "routing.db");
      const db = createTestOriginDb(p);
      // ONLY root_1 is in session_origin, child_1 is NOT in session_origin
      db.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('root_1', 'lgtm', 'all', 1000);
      `);
      db.close();

      const rows = queryWithState(baseRows, { routingDbPath: p });
      const child1 = rows.find((r) => r.id === "child_1");

      expect(child1).toBeDefined();
      expect(child1!.origin).toBe("lgtm");
      expect(child1!.automated).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("a row arriving via the UNION path is annotated with origin and automated", () => {
    const db = createTestDb();
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived) VALUES
        ('recent', 'p', NULL, 'recent', '/w', 'recent', '1.0', 1, 9000, NULL),
        ('outside_union', 'p', NULL, 'outside_union', '/w', 'outside_union', '1.0', 1, 10, NULL);
    `);

    const overlayDir = mkdtempSync(join(tmpdir(), "oc-union-overlay-"));
    const originDir = mkdtempSync(join(tmpdir(), "oc-union-origin-"));
    try {
      // Write overlay for outside_union session
      writeFileSync(
        join(overlayDir, "s1.json"),
        JSON.stringify({
          version: OVERLAY_VERSION,
          instanceStamp: 1,
          pid: process.pid,
          serveId: "serve-1",
          heartbeat: Date.now(),
          sessions: {
            outside_union: {
              activity: "working",
              error: false,
              pendingPermissions: [],
              pendingQuestions: [],
              lastActivity: 5000,
              updatedAt: 5000,
            },
          },
        }),
      );

      // Write session_origin for outside_union
      const p = join(originDir, "routing.db");
      const originDb = createTestOriginDb(p);
      originDb.exec(`
        INSERT INTO session_origin (session_id, origin, notify_policy, declared_at) VALUES
          ('outside_union', 'lgtm', 'all', 1000);
      `);
      originDb.close();

      const base = queryBaseList(db, { limit: 1 });
      expect(base.map((r) => r.id)).toEqual(["recent"]); // outside_union is outside recency limit

      const rows = queryWithState(base, {
        overlayDir,
        routingDbPath: p,
        unionLookup: (sids) => queryTreesForSessions(db, sids),
      });

      const unionRow = rows.find((r) => r.id === "outside_union");
      expect(unionRow).toBeDefined();
      expect(unionRow!.origin).toBe("lgtm");
      expect(unionRow!.automated).toBe(true);
    } finally {
      db.close();
      rmSync(overlayDir, { recursive: true, force: true });
      rmSync(originDir, { recursive: true, force: true });
    }
  });

  it("when routing DB is unavailable, every row gets automated: false and origin: null (fails open)", () => {
    const missingPath = "/definitely/not/a/real/routing.db";
    const rows = queryWithState(baseRows, {
      routingDbPath: missingPath,
    });

    expect(rows.length).toBe(baseRows.length);
    for (const r of rows) {
      expect(r.origin).toBeNull();
      expect(r.automated).toBe(false);
    }
  });
});
