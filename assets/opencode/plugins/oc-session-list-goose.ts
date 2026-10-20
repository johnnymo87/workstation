import { Database } from "bun:sqlite";
import { spawn } from "node:child_process";
import { accessSync, constants, existsSync } from "node:fs";
import { delimiter, join } from "node:path";
import type { SessionRow } from "./oc-session-list-base.js";
import { buildUnreadMap, type SessionWithStateRow, type UnreadEntry } from "./oc-session-list-state.js";

/**
 * Goose sessions for the session pickers (bead honk-9qf.15.11; design in
 * docs/plans/2026-10-19-goose-sessions-in-pickers.md).
 *
 * The source is `honk list --json`, i.e. honkd's `session/list`: goose's own
 * session list plus honkd's `held`/`running`. honkd is the only place live goose
 * state exists, and a goose session can only be opened through honkd anyway, so
 * there is no fallback to reading goose's sessions.db: while honkd is down the
 * rows would only offer attaches that cannot work.
 *
 * Rows are built straight into the shape `queryWithState` produces, and the
 * caller appends them AFTER that call, so they never enter the overlay merge,
 * the owner map or the nodata tripwire -- all of which are written for opencode
 * serves and would misread a goose session as an outage.
 *
 * OPT-IN (`--goose`). The picker Lua passes it; nothing else gets goose rows.
 * The CLI and the Lua deploy separately (a running nvim keeps yesterday's
 * modules until it restarts), and a picker without the goose open path would
 * list rows that fail silently on Enter.
 */

/**
 * Picker ids for goose sessions are `goose:<goose-id>`: the namespace oc-tags
 * already uses in tags.db, so the stall-watch picker's tag join works as is.
 * The prefix is stripped only at the honk boundary (oc-auto-attach and
 * oc_auto_attach.lua).
 */
export const GOOSE_ID_PREFIX = "goose:";
// Same shape in all three dialects that check it (this TS RegExp, the bash ERE in
// oc-auto-attach, the Lua pattern in oc_auto_attach.lua). Lua patterns have no
// {n} quantifier, so `[0-9]+` is used everywhere rather than goose's 8-digit date.
const GOOSE_ID_RE = /^goose:[0-9]+_[0-9]+$/;

export function isGooseId(id: unknown): id is string {
  return typeof id === "string" && GOOSE_ID_RE.test(id);
}

/** One entry of `honk list --json` (honk's SessionEntry::to_json). */
export interface HonkSession {
  sessionId: string;
  title: string;
  cwd: string;
  held: boolean;
  running: boolean;
  updatedAt: string | null;
  lastMessageAt: string | null;
  archivedAt: string | null;
  sessionType: string | null;
  hasRecipe: boolean;
  /** goose->client requests (permission prompts) waiting; null from an older honk. */
  pendingRequests: number | null;
}

export interface GooseRow extends SessionWithStateRow {
  /** pigeon's own id for this session (`gse_...`), the key mark-read must use. */
  pigeon_session_id: string | null;
  harness: "goose";
}

/** Env var naming the honk executable. Unset means `honk` on PATH. */
export const HONK_ENV = "OC_SESSION_LIST_HONK";
// Measured 2026-10-19: 0.14-0.36 s for 20 of 20 calls in a row, but single
// calls of 1.7 s and 3.5 s also seen (goose-serve busy). The call runs in
// PARALLEL with the opencode DB work (main starts it first), so this bounds the
// total at max(timeout, DB time) -- well inside the picker's 5 s fetch budget --
// while 1.5 s would have dropped goose rows, with a warning, on a busy open.
export const HONK_TIMEOUT_MS = 2500;
export const RECIPE_ORIGIN = "goose-recipe";

const str = (v: unknown): string | null => (typeof v === "string" ? v : null);

/** Parse `honk list --json` stdout. Throws unless it is a JSON array. */
export function parseHonkList(stdout: string): HonkSession[] {
  const doc: unknown = JSON.parse(stdout);
  if (!Array.isArray(doc)) throw new Error("honk list --json did not print a JSON array");
  const out: HonkSession[] = [];
  for (const e of doc) {
    if (!e || typeof e !== "object") continue;
    const o = e as Record<string, unknown>;
    const sessionId = str(o.sessionId);
    if (!sessionId) continue;
    out.push({
      sessionId,
      title: str(o.title) ?? "",
      cwd: str(o.cwd) ?? "",
      held: o.held === true,
      running: o.running === true,
      updatedAt: str(o.updatedAt),
      lastMessageAt: str(o.lastMessageAt),
      archivedAt: str(o.archivedAt),
      sessionType: str(o.sessionType),
      hasRecipe: o.hasRecipe === true,
      pendingRequests:
        typeof o.pendingRequests === "number" && Number.isFinite(o.pendingRequests) ? o.pendingRequests : null,
    });
  }
  return out;
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** `command -v <name>` over $PATH, without a shell. */
export function findOnPath(name: string, pathVar: string | undefined = process.env.PATH): string | null {
  for (const dir of (pathVar ?? "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

export type HonkBin = { kind: "ok"; bin: string } | { kind: "absent" } | { kind: "error"; message: string };

/** Where honk keeps its secret (honk's resolve_secret): proof honk is set up here. */
export function honkStatePath(env: Record<string, string | undefined>): string | null {
  if (env.XDG_STATE_HOME) return join(env.XDG_STATE_HOME, "honk", "secret");
  if (env.HOME) return join(env.HOME, ".local", "state", "honk", "secret");
  return null;
}

/**
 * Find honk. Not installed and not set up is ABSENCE, and silent: only
 * cloudbox installs honk, and a warning on every picker open on every other
 * host would train the eye to ignore warnings. But a host where honk IS set up
 * (its secret exists, or HONK_URL/HONK_SECRET is set) and the binary is not on
 * PATH is breakage -- the stripped-PATH class this repo has been bitten by
 * (canonical-path.sh) -- so that warns. So does a configured path that does
 * not work.
 */
export function resolveHonkBin(
  env: Record<string, string | undefined>,
  which: (bin: string) => string | null = (b) => findOnPath(b, env.PATH),
): HonkBin {
  const configured = env[HONK_ENV];
  if (configured) {
    return isExecutable(configured)
      ? { kind: "ok", bin: configured }
      : { kind: "error", message: `${HONK_ENV}=${configured} is not executable` };
  }
  const found = which("honk");
  if (found) return { kind: "ok", bin: found };
  const state = honkStatePath(env);
  const setUp = !!env.HONK_URL || !!env.HONK_SECRET || (state !== null && existsSync(state));
  return setUp
    ? { kind: "error", message: "honk is set up on this host but not on PATH" }
    : { kind: "absent" };
}

export type HonkListResult = { kind: "ok"; sessions: HonkSession[] } | { kind: "error"; message: string };

/**
 * Run `<bin> list --json` with a hard timeout. Never rejects.
 *
 * Async so main() can start it BEFORE the opencode DB work and await it at the
 * merge: the two overlap instead of adding up.
 */
export function runHonkList(bin: string, timeoutMs: number = HONK_TIMEOUT_MS): Promise<HonkListResult> {
  return new Promise((resolve) => {
    let settled = false;
    const settle = (r: HonkListResult) => {
      if (settled) return;
      settled = true;
      resolve(r);
    };
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(bin, ["list", "--json"], { stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      settle({ kind: "error", message: `could not run ${bin}: ${String(err)}` });
      return;
    }
    let out = "";
    let err = "";
    child.stdout?.setEncoding("utf8");
    child.stderr?.setEncoding("utf8");
    child.stdout?.on("data", (d: string) => (out += d));
    child.stderr?.on("data", (d: string) => (err += d));
    const timer = setTimeout(() => {
      // Answer NOW rather than on 'close': a grandchild holding the pipes open
      // would otherwise keep us (and the process exit) waiting for it.
      try {
        child.kill("SIGKILL");
      } catch {}
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.unref();
      settle({ kind: "error", message: `honk list timed out after ${timeoutMs}ms` });
    }, timeoutMs);
    child.on("error", (e: Error) => {
      clearTimeout(timer);
      settle({ kind: "error", message: `could not run ${bin}: ${e.message}` });
    });
    child.on("close", (code: number | null, signal: string | null) => {
      clearTimeout(timer);
      if (code !== 0) {
        // First line only: the picker renders each stderr line as its own
        // warning, and clap's usage block would arrive as four.
        const first = err.split("\n").map((l) => l.trim()).find((l) => l !== "") ?? "";
        const how = signal ? `killed by ${signal}` : `exited ${code}`;
        settle({ kind: "error", message: `honk list ${how}${first ? `: ${first}` : ""}` });
        return;
      }
      try {
        settle({ kind: "ok", sessions: parseHonkList(out) });
      } catch (e) {
        settle({ kind: "error", message: `honk list printed unparseable output (${String(e)})` });
      }
    });
  });
}

/**
 * goose id -> pigeon session id (`gse_...`). pigeon stores the goose id in
 * `sessions.backend_session_id`; if a session was registered more than once,
 * the newest registration wins. Null when the DB, table or column is missing:
 * unread then reads `absent` (or `unavailable`, decided by buildUnreadMap).
 * Silent, because the opencode rows' path already reports a bad routing DB.
 */
export function buildGoosePigeonMap(routingDbPath: string): Map<string, string> | null {
  if (!routingDbPath || !existsSync(routingDbPath)) return null;
  let db: Database | undefined;
  try {
    db = new Database(routingDbPath, { readonly: true });
    const rows = db
      .query<{ session_id: string; backend_session_id: string }, []>(
        `SELECT session_id, backend_session_id FROM sessions
          WHERE backend_session_id IS NOT NULL AND backend_session_id <> ''
          ORDER BY updated_at ASC, session_id ASC`,
      )
      .all();
    const map = new Map<string, string>();
    for (const r of rows) map.set(r.backend_session_id, r.session_id); // later = newer wins
    return map;
  } catch {
    return null;
  } finally {
    try {
      db?.close();
    } catch {}
  }
}

function ms(v: string | null): number {
  if (!v) return 0;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : 0;
}

/** goose's own sort key (session_manager: last_message_at, else updated_at). */
function recency(s: HonkSession): number {
  return s.lastMessageAt ? ms(s.lastMessageAt) : ms(s.updatedAt);
}

/**
 * The oldest moment the opencode browse window still covers, or null when the
 * window is not full (every opencode root fit, so it has no edge).
 *
 * Goose rows older than this are left out of browse mode. Without it the two
 * harnesses would have different horizons: measured, the 200th opencode root
 * was 3.9 days old while 100 of 103 listable goose sessions were older than
 * that -- weeks-old probe sessions would fill the bottom of the list and imply
 * coverage opencode rows at the same age do not have.
 */
export function windowFloor(baseRows: SessionRow[], limit: number): number | null {
  const treeMax = new Map<string, number>();
  for (const r of baseRows) {
    const prev = treeMax.get(r.root_id);
    if (prev === undefined || r.time_updated > prev) treeMax.set(r.root_id, r.time_updated);
  }
  if (treeMax.size < limit || treeMax.size === 0) return null;
  return Math.min(...treeMax.values());
}

export interface GooseRowsOptions {
  /** Browse mode: how many human (non-recipe) sessions to keep. */
  limit: number;
  /** `--ids` mode: the requested ids (only `goose:` ones are used). null = browse. */
  ids: string[] | null;
  /** pigeon unread map keyed by pigeon session id; null = routing DB unreadable. */
  unread: Map<string, Pick<UnreadEntry, "unread" | "last_event_id">> | null;
  pigeonIds: Map<string, string> | null;
  /** Browse mode: drop sessions older than this (see windowFloor). null = no floor. */
  floorMs?: number | null;
}

/**
 * Turn honk's list into picker rows.
 *
 * Browse mode keeps the `limit` most recent NON-recipe sessions, then, in a
 * separate window of the same size and floor, the most recent recipe runs.
 * Recipe runs (lanes, stall-watch coordinators, some test runs) are 70% of
 * goose sessions and arrive every few minutes, so counting them against the
 * human window would push every human chat out of it. Recipe rows are marked
 * `automated` in both modes: the ordinary picker hides them, ,fs id search
 * finds them, and `--ids` (the stall-watch picker) returns exactly the ids
 * asked for.
 */
export function gooseRows(sessions: HonkSession[], opts: GooseRowsOptions): GooseRow[] {
  let picked: HonkSession[];
  const live = sessions.filter((s) => !s.archivedAt);
  if (opts.ids !== null) {
    const wanted = new Set(opts.ids.filter(isGooseId).map((id) => id.slice(GOOSE_ID_PREFIX.length)));
    picked = live.filter((s) => wanted.has(s.sessionId));
  } else {
    const floor = opts.floorMs ?? null;
    const window = (list: HonkSession[]) =>
      list
        .map((s) => ({ s, t: recency(s) }))
        .filter((x) => floor === null || x.t >= floor)
        .sort((a, b) => b.t - a.t || (a.s.sessionId < b.s.sessionId ? -1 : 1))
        .slice(0, Math.max(0, opts.limit))
        .map((x) => x.s);
    const human = live.filter((s) => !s.hasRecipe);
    // A session mid-turn or parked on a prompt is never windowed out -- the
    // goose counterpart of opencode's overlay-truth union.
    const needsYou = (s: HonkSession) => s.running || (s.pendingRequests ?? 0) > 0;
    // Recipe runs get a window of their own, so they never push a human chat
    // out of the human one. They are marked automated, so the ordinary picker
    // hides them; ,fs id search (everything fetched, hide_automated lifted)
    // is what reaches them.
    picked = [
      ...human.filter(needsYou),
      ...window(human.filter((s) => !needsYou(s))),
      ...window(live.filter((s) => s.hasRecipe)),
    ];
  }

  return picked.map((s): GooseRow => {
    const id = GOOSE_ID_PREFIX + s.sessionId;
    const t = recency(s);
    const pending = s.pendingRequests ?? 0;
    const pigeonId = opts.pigeonIds?.get(s.sessionId) ?? null;

    let unread: number | null = null;
    let unread_state: "counted" | "absent" | "unavailable" = "unavailable";
    let last_event_id: number | null = null;
    if (opts.unread !== null) {
      const entry = pigeonId ? opts.unread.get(pigeonId) : undefined;
      if (entry) {
        unread = entry.unread;
        unread_state = "counted";
        last_event_id = entry.last_event_id;
      } else {
        unread_state = "absent";
      }
    }

    const row: GooseRow = {
      id,
      root_id: id,
      parent_id: null,
      title: s.title,
      directory: s.cwd,
      time_updated: t,
      // honkd's view. A session driven outside honkd (the goose CLI) reads idle
      // even mid-turn; those are recipe runs, hidden from the browse list.
      activity: s.running ? "working" : "idle",
      error: false,
      // A permission prompt parked in honkd makes the row `blocked`: pinned to
      // the attention group and piercing the facet, like an opencode one. honkd
      // counts them without ids, hence the placeholder entries.
      pendingPermissions: Array.from({ length: pending }, () => "honk"),
      pendingQuestions: [],
      lastActivity: t,
      updatedAt: t,
      unread,
      unread_state,
      last_event_id,
      // honk has no scroll-to-message, and the picker would otherwise POST a
      // scroll for an opencode message id to the opencode front door.
      anchor_msg_id: null,
      origin: s.hasRecipe ? RECIPE_ORIGIN : null,
      automated: s.hasRecipe,
      pigeon_session_id: pigeonId,
      harness: "goose",
    };
    if (opts.ids !== null) row.matched_ids = [id];
    return row;
  });
}

export type GooseFetch = { kind: "skip" } | HonkListResult;

export interface StartGooseFetchOptions {
  env: Record<string, string | undefined>;
  which?: (bin: string) => string | null;
  ids: string[] | null;
  timeoutMs?: number;
}

/** Step 1, started before the opencode DB work: find honk and run it. */
export async function startGooseFetch(opts: StartGooseFetchOptions): Promise<GooseFetch> {
  // An --ids request that names no goose session must not depend on honkd at
  // all: the stall-watch picker asks for opencode ids on every open.
  if (opts.ids !== null && !opts.ids.some(isGooseId)) return { kind: "skip" };
  const bin = resolveHonkBin(opts.env, opts.which);
  if (bin.kind === "absent") return { kind: "skip" };
  if (bin.kind === "error") return { kind: "error", message: bin.message };
  return runHonkList(bin.bin, opts.timeoutMs ?? HONK_TIMEOUT_MS);
}

export interface FinishGooseRowsOptions {
  limit: number;
  ids: string[] | null;
  routingDbPath: string;
  floorMs?: number | null;
  onWarn: (msg: string) => void;
}

/** Step 2, at the merge: warn or map, and annotate unread. Never throws. */
export function finishGooseRows(fetched: GooseFetch, opts: FinishGooseRowsOptions): GooseRow[] {
  if (fetched.kind === "skip") return [];
  if (fetched.kind === "error") {
    opts.onWarn(`goose sessions unavailable: ${fetched.message} -- they are missing from this list`);
    return [];
  }
  const unread = buildUnreadMap(opts.routingDbPath, []);
  const pigeonIds = unread === null ? null : buildGoosePigeonMap(opts.routingDbPath);
  return gooseRows(fetched.sessions, {
    limit: opts.limit,
    ids: opts.ids,
    unread,
    pigeonIds,
    floorMs: opts.floorMs ?? null,
  });
}

/** Both steps in one call (tests, and any caller with nothing to overlap). */
export async function loadGooseRows(
  opts: StartGooseFetchOptions & FinishGooseRowsOptions,
): Promise<GooseRow[]> {
  return finishGooseRows(await startGooseFetch(opts), opts);
}
