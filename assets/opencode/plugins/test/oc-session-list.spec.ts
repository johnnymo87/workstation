import { describe, it, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, readdirSync, mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { queryBaseList } from "../oc-session-list-base.js";
import { parseCliArgs } from "../oc-session-list.js";
import {
  buildOwnersMap,
  queryWithState,
  runOrphanGc,
} from "../oc-session-list-state.js";
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

    expect(elapsed).toBeLessThan(100);
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

  it("against the REAL routing DB, asserts constructed owners map is NON-EMPTY and at least one CHILD session inherits root serve", () => {
    const realRoutingDb = "/home/dev/projects/pigeon/packages/daemon/data/pigeon-daemon.db";
    const realBaseDbPath = process.env.HOME + "/.local/share/opencode/opencode.db";

    if (!existsSync(realRoutingDb) || !existsSync(realBaseDbPath)) {
      console.log("Skipping real DB test: real DB files not found");
      return;
    }

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
