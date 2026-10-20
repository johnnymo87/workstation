import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  GOOSE_ID_PREFIX,
  buildGoosePigeonMap,
  findOnPath,
  gooseRows,
  honkStatePath,
  isGooseId,
  loadGooseRows,
  parseHonkList,
  resolveHonkBin,
  runHonkList,
  windowFloor,
  type HonkSession,
} from "../oc-session-list-goose.js";

function session(over: Partial<HonkSession> = {}): HonkSession {
  return {
    sessionId: "20261016_222",
    title: "Honk TUI",
    cwd: "/work/honk",
    held: false,
    running: false,
    updatedAt: "2026-10-19T22:00:00+00:00",
    lastMessageAt: null,
    archivedAt: null,
    sessionType: "acp",
    hasRecipe: false,
    pendingRequests: 0,
    lastError: null,
    ...over,
  };
}

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "oc-goose-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

/** A fake `honk` that ignores its args and runs `body` as a bash script. */
function fakeHonk(body: string): string {
  const p = join(dir, "honk");
  // Absolute bash: a Nix build sandbox has no /usr/bin/env.
  writeFileSync(p, `#!${findOnPath("bash")}\n${body}\n`);
  chmodSync(p, 0o755);
  return p;
}

function pigeonDb(): string {
  const p = join(dir, "pigeon.db");
  const db = new Database(p);
  db.exec(`
    CREATE TABLE sessions (
      session_id TEXT PRIMARY KEY,
      backend_kind TEXT,
      backend_session_id TEXT,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE session_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      notification_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      sent_at INTEGER NOT NULL,
      anchor_msg_id TEXT DEFAULT NULL
    );
    CREATE TABLE session_reads (
      session_id TEXT PRIMARY KEY,
      last_read_id INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
  `);
  db.close();
  return p;
}

describe("isGooseId", () => {
  it("accepts goose:<digits>_<digits> only (the shape every layer checks)", () => {
    expect(isGooseId("goose:20261016_222")).toBe(true);
    expect(isGooseId("goose:2026_1")).toBe(true);
    expect(isGooseId("20261016_222")).toBe(false);
    expect(isGooseId("ses_abc")).toBe(false);
    expect(isGooseId("goose:")).toBe(false);
    expect(isGooseId("goose:abc")).toBe(false);
    expect(isGooseId("goose:1_2;x")).toBe(false);
    expect(isGooseId("goose:20261016_222;rm")).toBe(false);
    expect(GOOSE_ID_PREFIX).toBe("goose:");
  });
});

describe("parseHonkList", () => {
  it("reads honk list --json", () => {
    const out = parseHonkList(JSON.stringify([session()]));
    expect(out).toEqual([session()]);
  });

  it("drops entries without a usable sessionId and defaults missing fields", () => {
    const out = parseHonkList(
      JSON.stringify([{ sessionId: "" }, { title: "x" }, { sessionId: "20261019_2" }, 7, null]),
    );
    expect(out).toEqual([
      {
        sessionId: "20261019_2",
        title: "",
        cwd: "",
        held: false,
        running: false,
        updatedAt: null,
        lastMessageAt: null,
        archivedAt: null,
        sessionType: null,
        hasRecipe: false,
        pendingRequests: null,
        lastError: null,
      },
    ]);
  });

  it("reads lastError only as an object with a string kind", () => {
    const err = { kind: "network", message: "connection reset", at: 1_760_000_000 };
    const parsed = (lastError: unknown) =>
      parseHonkList(JSON.stringify([{ sessionId: "20261019_2", lastError }]))[0].lastError;
    expect(parsed(err)).toEqual(err);
    expect(parsed({ kind: "rpc" })).toEqual({ kind: "rpc", message: "", at: null });
    expect(parsed(null)).toBeNull();
    expect(parsed(undefined)).toBeNull();
    expect(parsed({ message: "no kind" })).toBeNull();
    expect(parsed({ kind: 7 })).toBeNull();
    expect(parsed("network")).toBeNull();
  });

  it("throws on output that is not a JSON array", () => {
    expect(() => parseHonkList("not json")).toThrow();
    expect(() => parseHonkList(JSON.stringify({ sessions: [] }))).toThrow();
  });
});

describe("gooseRows", () => {
  const now = Date.parse("2026-10-19T23:00:00Z");

  it("maps a session onto the row model", () => {
    const [row] = gooseRows([session({ running: true, lastMessageAt: "2026-10-19T22:05:00Z" })], {
      limit: 50,
      ids: null,
      unread: null,
      pigeonIds: null,
    });
    expect(row).toEqual({
      id: "goose:20261016_222",
      root_id: "goose:20261016_222",
      parent_id: null,
      title: "Honk TUI",
      directory: "/work/honk",
      time_updated: Date.parse("2026-10-19T22:05:00Z"),
      activity: "working",
      error: false,
      pendingPermissions: [],
      pendingQuestions: [],
      lastActivity: Date.parse("2026-10-19T22:05:00Z"),
      updatedAt: Date.parse("2026-10-19T22:05:00Z"),
      unread: null,
      unread_state: "unavailable",
      last_event_id: null,
      anchor_msg_id: null,
      origin: null,
      automated: false,
      pigeon_session_id: null,
      harness: "goose",
    });
    expect(now).toBeGreaterThan(row.lastActivity);
  });

  it("is idle unless honkd reports a turn in flight, held or not", () => {
    const rows = gooseRows(
      [
        session({ sessionId: "20261019_1", held: true, running: false }),
        session({ sessionId: "20261019_2", held: false, running: false }),
      ],
      { limit: 50, ids: null, unread: null, pigeonIds: null },
    );
    expect(rows.map((r) => r.activity)).toEqual(["idle", "idle"]);
  });

  it("sorts by goose's own key: lastMessageAt, else updatedAt; 0 when it does not parse", () => {
    const rows = gooseRows(
      [
        session({ sessionId: "20261019_1", updatedAt: "2026-10-19T22:10:00Z", lastMessageAt: "2026-10-19T22:05:00Z" }),
        session({ sessionId: "20261019_2", updatedAt: "2026-10-19T22:07:00Z", lastMessageAt: null }),
        session({ sessionId: "20261019_3", updatedAt: "garbage", lastMessageAt: null }),
      ],
      { limit: 50, ids: null, unread: null, pigeonIds: null },
    );
    expect(rows.map((r) => [r.id, r.lastActivity])).toEqual([
      ["goose:20261019_2", Date.parse("2026-10-19T22:07:00Z")],
      ["goose:20261019_1", Date.parse("2026-10-19T22:05:00Z")],
      ["goose:20261019_3", 0],
    ]);
  });

  it("a parked permission prompt makes the row blocked-shaped", () => {
    const [row] = gooseRows([session({ running: true, pendingRequests: 2 })], {
      limit: 50, ids: null, unread: null, pigeonIds: null,
    });
    expect(row.pendingPermissions).toEqual(["honk", "honk"]);
    const [none] = gooseRows([session({ pendingRequests: null })], { limit: 50, ids: null, unread: null, pigeonIds: null });
    expect(none.pendingPermissions).toEqual([]);
  });

  it("browse mode drops sessions older than the opencode window's floor; ids mode ignores it", () => {
    const s = [
      session({ sessionId: "20261019_1", updatedAt: "2026-10-19T01:00:00Z" }),
      session({ sessionId: "20261019_2", updatedAt: "2026-10-19T03:00:00Z" }),
    ];
    const floorMs = Date.parse("2026-10-19T02:00:00Z");
    expect(gooseRows(s, { limit: 50, ids: null, unread: null, pigeonIds: null, floorMs }).map((r) => r.id))
      .toEqual(["goose:20261019_2"]);
    expect(gooseRows(s, { limit: 50, ids: ["goose:20261019_1"], unread: null, pigeonIds: null, floorMs }).map((r) => r.id))
      .toEqual(["goose:20261019_1"]);
  });

  it("browse mode keeps a running or blocked session past the floor and the limit", () => {
    // Like opencode's overlay union: the row that needs you must not age out.
    const s = [
      session({ sessionId: "20261019_1", updatedAt: "2026-10-10T00:00:00Z", running: true }),
      session({ sessionId: "20261019_2", updatedAt: "2026-10-10T00:00:00Z", pendingRequests: 1 }),
      session({ sessionId: "20261019_3", updatedAt: "2026-10-19T03:00:00Z" }),
      session({ sessionId: "20261019_4", updatedAt: "2026-10-19T04:00:00Z" }),
      session({ sessionId: "20261019_5", updatedAt: "2026-10-10T00:00:00Z" }),
    ];
    const floorMs = Date.parse("2026-10-19T00:00:00Z");
    const rows = gooseRows(s, { limit: 1, ids: null, unread: null, pigeonIds: null, floorMs });
    expect(rows.map((r) => r.id).sort()).toEqual(["goose:20261019_1", "goose:20261019_2", "goose:20261019_4"]);
  });

  it("a failed last turn makes the row an error row, unless it is running again", () => {
    const lastError = { kind: "network", message: "connection reset", at: 1_760_000_000 };
    const opts = { limit: 50, ids: null, unread: null, pigeonIds: null };
    const [errored] = gooseRows([session({ lastError })], opts);
    expect(errored.error).toBe(true);
    expect(errored.activity).toBe("idle");
    // honkd clears the error when a run starts; until a stale list catches up,
    // working wins, since the picker puts error ahead of working.
    const [running] = gooseRows([session({ lastError, running: true })], opts);
    expect(running.error).toBe(false);
    expect(running.activity).toBe("working");
    const [clean] = gooseRows([session()], opts);
    expect(clean.error).toBe(false);
  });

  it("browse mode keeps an errored session past the limit and floor only if it failed after the floor", () => {
    const floorMs = Date.parse("2026-10-19T00:00:00Z");
    const failedAt = (iso: string) => ({ kind: "provider", message: "HTTP 500", at: Date.parse(iso) / 1000 });
    const s = [
      // Old session whose last turn failed after the floor: needs you.
      session({ sessionId: "20261019_1", updatedAt: "2026-10-10T00:00:00Z", lastError: failedAt("2026-10-19T01:00:00Z") }),
      // Its failure is older than the floor: windowed like any idle row.
      session({ sessionId: "20261019_2", updatedAt: "2026-10-10T00:00:00Z", lastError: failedAt("2026-10-18T00:00:00Z") }),
      session({ sessionId: "20261019_3", updatedAt: "2026-10-19T03:00:00Z" }),
      session({ sessionId: "20261019_4", updatedAt: "2026-10-19T04:00:00Z" }),
    ];
    const rows = gooseRows(s, { limit: 1, ids: null, unread: null, pigeonIds: null, floorMs });
    expect(rows.map((r) => r.id).sort()).toEqual(["goose:20261019_1", "goose:20261019_4"]);
    // No floor (the opencode window is not full): every errored row stays.
    const unfloored = gooseRows(s, { limit: 1, ids: null, unread: null, pigeonIds: null });
    expect(unfloored.map((r) => r.id).sort()).toEqual(["goose:20261019_1", "goose:20261019_2", "goose:20261019_4"]);
  });

  it("drops archived sessions in both modes", () => {
    const s = [session({ sessionId: "20261019_1", archivedAt: "2026-10-19T00:00:00Z" })];
    expect(gooseRows(s, { limit: 50, ids: null, unread: null, pigeonIds: null })).toEqual([]);
    expect(gooseRows(s, { limit: 50, ids: ["goose:20261019_1"], unread: null, pigeonIds: null })).toEqual([]);
  });

  it("browse mode: the `limit` most recent human sessions, then recipe runs windowed separately and marked automated", () => {
    // Recipe runs are ~70% of goose sessions. Windowed together they would push
    // every human chat out; left out entirely, ,fs id search (which fetches
    // everything and lifts hide_automated) could never find one by id.
    const s = [
      session({ sessionId: "20261019_1", updatedAt: "2026-10-19T01:00:00Z" }),
      session({ sessionId: "20261019_2", updatedAt: "2026-10-19T03:00:00Z" }),
      session({ sessionId: "20261019_3", updatedAt: "2026-10-19T04:00:00Z", hasRecipe: true }),
      session({ sessionId: "20261019_4", updatedAt: "2026-10-19T02:00:00Z" }),
      session({ sessionId: "20261019_5", updatedAt: "2026-10-19T05:00:00Z", hasRecipe: true }),
      session({ sessionId: "20261019_6", updatedAt: "2026-10-19T00:30:00Z", hasRecipe: true }),
    ];
    const rows = gooseRows(s, { limit: 2, ids: null, unread: null, pigeonIds: null });
    expect(rows.map((r) => [r.id, r.automated, r.origin, r.matched_ids])).toEqual([
      ["goose:20261019_2", false, null, undefined],
      ["goose:20261019_4", false, null, undefined],
      ["goose:20261019_5", true, "goose-recipe", undefined],
      ["goose:20261019_3", true, "goose-recipe", undefined],
    ]);
  });

  it("browse mode: recipe runs obey the window floor too", () => {
    const s = [
      session({ sessionId: "20261019_1", updatedAt: "2026-10-19T01:00:00Z", hasRecipe: true }),
      session({ sessionId: "20261019_2", updatedAt: "2026-10-19T03:00:00Z", hasRecipe: true }),
    ];
    const floorMs = Date.parse("2026-10-19T02:00:00Z");
    expect(gooseRows(s, { limit: 50, ids: null, unread: null, pigeonIds: null, floorMs }).map((r) => r.id))
      .toEqual(["goose:20261019_2"]);
  });

  it("ids mode: exactly the requested goose ids, recipe runs included, matched_ids set", () => {
    const s = [
      session({ sessionId: "20261019_1" }),
      session({ sessionId: "20261019_2", hasRecipe: true }),
      session({ sessionId: "20261019_3" }),
    ];
    const rows = gooseRows(s, {
      limit: 1,
      ids: ["goose:20261019_2", "goose:20261019_3", "goose:20261019_9", "ses_x"],
      unread: null,
      pigeonIds: null,
    });
    expect(rows.map((r) => [r.id, r.automated, r.origin, r.matched_ids])).toEqual([
      ["goose:20261019_2", true, "goose-recipe", ["goose:20261019_2"]],
      ["goose:20261019_3", false, null, ["goose:20261019_3"]],
    ]);
  });

  it("unread comes from pigeon through its gse_ id; anchors are never carried", () => {
    const unread = new Map([
      ["gse_a", { unread: 3, last_event_id: 41, anchor_msg_id: "msg_x" }],
    ]);
    const pigeonIds = new Map([["20261019_1", "gse_a"], ["20261019_2", "gse_b"]]);
    const rows = gooseRows(
      [session({ sessionId: "20261019_1" }), session({ sessionId: "20261019_2" }), session({ sessionId: "20261019_3" })],
      { limit: 50, ids: null, unread, pigeonIds },
    );
    expect(rows.map((r) => [r.unread, r.unread_state, r.last_event_id, r.anchor_msg_id, r.pigeon_session_id])).toEqual([
      [3, "counted", 41, null, "gse_a"],
      [null, "absent", null, null, "gse_b"],
      [null, "absent", null, null, null],
    ]);
  });
});

describe("windowFloor", () => {
  const row = (id: string, root: string, t: number) =>
    ({ id, root_id: root, parent_id: null, title: "", directory: "/", time_updated: t });
  it("is the oldest tree-max time_updated when the window is full", () => {
    // tree a: max 50 (child newer than root); tree b: 30.
    const rows = [row("a", "a", 10), row("a1", "a", 50), row("b", "b", 30)];
    expect(windowFloor(rows, 2)).toBe(30);
  });
  it("is null when every root fit (the window has no edge)", () => {
    expect(windowFloor([row("a", "a", 10)], 2)).toBeNull();
    expect(windowFloor([], 0)).toBeNull();
  });
});

describe("buildGoosePigeonMap", () => {
  it("maps goose ids to pigeon ids, newest registration winning", () => {
    const p = pigeonDb();
    const db = new Database(p);
    db.exec(`
      INSERT INTO sessions VALUES ('gse_old', 'goose-acp', '20261019_1', 100);
      INSERT INTO sessions VALUES ('gse_new', 'goose-acp', '20261019_1', 200);
      INSERT INTO sessions VALUES ('ses_x', NULL, NULL, 300);
    `);
    db.close();
    const m = buildGoosePigeonMap(p);
    expect(m).not.toBeNull();
    expect([...m!.entries()]).toEqual([["20261019_1", "gse_new"]]);
  });

  it("is null when the DB or the column is missing", () => {
    expect(buildGoosePigeonMap(join(dir, "nope.db"))).toBeNull();
    const p = join(dir, "old.db");
    const db = new Database(p);
    db.exec(`CREATE TABLE sessions (session_id TEXT PRIMARY KEY)`);
    db.close();
    expect(buildGoosePigeonMap(p)).toBeNull();
  });
});

describe("findOnPath", () => {
  it("finds an executable on PATH and nothing else", () => {
    const bin = fakeHonk("true");
    writeFileSync(join(dir, "plain"), "not executable");
    expect(findOnPath("honk", `/nonexistent:${dir}`)).toBe(bin);
    expect(findOnPath("plain", dir)).toBeNull();
    expect(findOnPath("honk", "")).toBeNull();
  });
});

describe("resolveHonkBin / runHonkList", () => {
  it("is absent, silently, when honk is neither installed nor set up", () => {
    expect(resolveHonkBin({ HOME: dir }, () => null)).toEqual({ kind: "absent" });
  });

  it("is an error when honk is set up here but not on PATH", () => {
    const state = honkStatePath({ HOME: dir })!;
    expect(state).toBe(join(dir, ".local", "state", "honk", "secret"));
    expect(honkStatePath({ XDG_STATE_HOME: "/x", HOME: dir })).toBe("/x/honk/secret");
    mkdirSync(join(dir, ".local", "state", "honk"), { recursive: true });
    writeFileSync(state, "s");
    expect(resolveHonkBin({ HOME: dir }, () => null).kind).toBe("error");
    expect(resolveHonkBin({ HONK_URL: "http://x" }, () => null).kind).toBe("error");
  });

  it("an explicit OC_SESSION_LIST_HONK that is not executable is an error, not absence", () => {
    const r = resolveHonkBin({ OC_SESSION_LIST_HONK: join(dir, "missing") }, () => null);
    expect(r.kind).toBe("error");
  });

  it("runs honk list --json and parses it", async () => {
    const bin = fakeHonk(`[ "$1 $2" = "list --json" ] || exit 9; echo '${JSON.stringify([session()])}'`);
    expect(await runHonkList(bin, 3000)).toEqual({ kind: "ok", sessions: [session()] });
  });

  it("reports a non-zero exit with honk's stderr", async () => {
    const bin = fakeHonk(`echo "connection failed: refused" >&2; exit 1`);
    const r = await runHonkList(bin, 3000);
    expect(r.kind).toBe("error");
    expect((r as { message: string }).message).toContain("connection failed: refused");
  });

  it("keeps only the first stderr line (the picker shows one warning per line)", async () => {
    const bin = fakeHonk(`printf '\\nerror: unexpected argument\\n\\nUsage: honk list\\n' >&2; exit 2`);
    const r = (await runHonkList(bin, 3000)) as { kind: string; message: string };
    expect(r.message).toBe("honk list exited 2: error: unexpected argument");
  });

  it("reports a binary that cannot be started", async () => {
    const r = await runHonkList(join(dir, "missing-honk"), 3000);
    expect(r.kind).toBe("error");
  });

  it("reports unparseable output", async () => {
    const bin = fakeHonk(`echo hello`);
    expect((await runHonkList(bin, 3000)).kind).toBe("error");
  });

  it("gives up after the timeout", async () => {
    const bin = fakeHonk(`sleep 5; echo '[]'`);
    const t0 = Date.now();
    const r = await runHonkList(bin, 300);
    expect(r.kind).toBe("error");
    expect((r as { message: string }).message).toContain("timed out");
    expect(Date.now() - t0).toBeLessThan(3000);
  });
});

describe("loadGooseRows", () => {
  it("warns once and returns nothing when honk fails", async () => {
    const warns: string[] = [];
    const bin = fakeHonk(`echo boom >&2; exit 1`);
    const rows = await loadGooseRows({
      env: { OC_SESSION_LIST_HONK: bin },
      limit: 50,
      ids: null,
      routingDbPath: "",
      onWarn: (m) => warns.push(m),
    });
    expect(rows).toEqual([]);
    expect(warns.length).toBe(1);
    expect(warns[0]).toContain("goose sessions unavailable");
    expect(warns[0]).toContain("boom");
  });

  it("is silent and empty when honk is absent", async () => {
    const warns: string[] = [];
    const rows = await loadGooseRows({
      env: { HOME: dir },
      which: () => null,
      limit: 50,
      ids: null,
      routingDbPath: "",
      onWarn: (m) => warns.push(m),
    });
    expect(rows).toEqual([]);
    expect(warns).toEqual([]);
  });

  it("does not run honk at all in ids mode without goose ids", async () => {
    const marker = join(dir, "ran");
    const bin = fakeHonk(`touch ${marker}; echo '[]'`);
    const rows = await loadGooseRows({
      env: { OC_SESSION_LIST_HONK: bin },
      limit: 50,
      ids: ["ses_a"],
      routingDbPath: "",
      onWarn: () => {},
    });
    expect(rows).toEqual([]);
    expect(existsSync(marker)).toBe(false);
  });

  it("annotates unread from the routing DB", async () => {
    const p = pigeonDb();
    const db = new Database(p);
    db.exec(`
      INSERT INTO sessions VALUES ('gse_a', 'goose-acp', '20261016_222', 100);
      INSERT INTO session_events (session_id, notification_id, kind, sent_at) VALUES ('gse_a', 'n1', 'stop', 1);
      INSERT INTO session_events (session_id, notification_id, kind, sent_at) VALUES ('gse_a', 'n2', 'stop', 2);
    `);
    db.close();
    const bin = fakeHonk(`echo '${JSON.stringify([session()])}'`);
    const rows = await loadGooseRows({
      env: { OC_SESSION_LIST_HONK: bin },
      limit: 50,
      ids: null,
      routingDbPath: p,
      onWarn: () => {},
    });
    expect(rows.map((r) => [r.id, r.unread, r.unread_state, r.last_event_id, r.pigeon_session_id])).toEqual([
      ["goose:20261016_222", 2, "counted", 2, "gse_a"],
    ]);
  });

  it("unread is unavailable without a routing DB", async () => {
    const bin = fakeHonk(`echo '${JSON.stringify([session()])}'`);
    const rows = await loadGooseRows({
      env: { OC_SESSION_LIST_HONK: bin },
      limit: 50,
      ids: null,
      routingDbPath: join(dir, "missing.db"),
      onWarn: () => {},
    });
    expect(rows[0].unread_state).toBe("unavailable");
  });
});
