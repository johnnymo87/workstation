import { describe, it, expect, beforeEach } from "bun:test";
import { Database } from "bun:sqlite";
import { queryBaseList } from "../oc-session-list-base.js";
import { parseCliArgs } from "../oc-session-list.js";

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

    // Expect 4 rows total
    expect(rows.length).toBe(4);

    // First group of rows must belong to root_1 tree (since grandchild_1 updated at 3000 > root_2 updated at 500)
    const root1TreeIds = rows.slice(0, 3).map((r) => r.id);
    expect(root1TreeIds).toContain("root_1");
    expect(root1TreeIds).toContain("child_1");
    expect(root1TreeIds).toContain("grandchild_1");

    // The most recently updated session in the top root tree must be grandchild_1 (3000)
    expect(rows[0].id).toBe("grandchild_1");

    // The last row must be root_2
    expect(rows[3].id).toBe("root_2");
  });

  it("excludes archived sessions (time_archived IS NOT NULL)", () => {
    const db = createTestDb();

    // Active session
    db.exec(`
      INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated, time_archived)
      VALUES ('active_1', 'p1', NULL, 'active-1', '/proj', 'Active Session', '1.0', 1000, 2000, NULL)
    `);

    // Archived session
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

    // Cyclic sessions: A -> B -> A
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

  it("parses --help flag", () => {
    const opts = parseCliArgs(["--help"]);
    expect(opts.help).toBe(true);
  });
});
