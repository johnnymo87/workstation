import type { Database } from "bun:sqlite";

export interface SessionRow {
  id: string;
  title: string;
  parent_id: string | null;
  directory: string;
  time_updated: number;
  /**
   * The TRUE root of this session's tree, resolved by walking `parent_id` all
   * the way up (not a single-level `COALESCE(parent_id, id)` lift).
   *
   * Emitted deliberately: Task 8 folds children under their root, and without
   * this the root grouping is unobservable from the outside -- which is exactly
   * how the original 3-level test passed while the walk was crippled to one
   * level (caught by mutation testing, 2026-07-31).
   */
  root_id: string;
  /**
   * Only present in --ids mode on root rows: the requested session ids
   * (after trim/dedupe) that resolved into this root's tree (including the
   * root id itself if requested).
   */
  matched_ids?: string[];
}

export interface BaseListOptions {
  limit?: number;
}

/**
 * Resolve specific session ids to their FULL root trees (S6 overlay-truth union).
 *
 * Two properties this must not lose, both inherited from the same ancestry walk
 * `queryBaseList` uses:
 *
 *  1. ARCHIVED STAYS GONE. The anchor filters `time_archived IS NULL`, so an
 *     archived session is not a leaf and cannot be resurrected by a live overlay
 *     that still names it. Dropping that filter here would let the union quietly
 *     undo the base list's own exclusion.
 *  2. WHOLE TREE, NOT THE NAMED ROW. An overlay can name a CHILD whose root fell
 *     outside the recency window. Returning only that child would give the fold
 *     nothing to fold it into, and it would render as a root it is not.
 */
export function queryTreesForSessions(db: Database, sessionIds: string[]): SessionRow[] {
  const ids = [...new Set(sessionIds.filter((s) => typeof s === "string" && s !== ""))];
  if (ids.length === 0) return [];
  // Bound the statement: the candidate set comes from live overlay files, which
  // is small in practice, but an unbounded IN list is a footgun a future writer
  // bug could pull.
  const capped = ids.slice(0, 200);
  const placeholders = capped.map(() => "?").join(",");

  db.exec("PRAGMA busy_timeout = 5000;");

  const query = db.query<SessionRow, string[]>(`
    WITH RECURSIVE session_ancestry(leaf_id, curr_id, parent_id, depth) AS (
      SELECT id AS leaf_id, id AS curr_id, parent_id, 0 AS depth
      FROM session
      WHERE time_archived IS NULL

      UNION ALL

      SELECT sa.leaf_id, p.id, p.parent_id, sa.depth + 1
      FROM session_ancestry sa
      JOIN session p ON p.id = sa.parent_id
      WHERE sa.parent_id IS NOT NULL
        AND p.time_archived IS NULL
        AND sa.depth < 8
    ),
    leaf_root AS (
      SELECT leaf_id, curr_id AS root_id
      FROM (
        SELECT leaf_id, curr_id,
               ROW_NUMBER() OVER (PARTITION BY leaf_id ORDER BY depth DESC) AS rn
        FROM session_ancestry
      )
      WHERE rn = 1
    ),
    target_roots AS (
      SELECT DISTINCT root_id FROM leaf_root WHERE leaf_id IN (${placeholders})
    )
    SELECT s.id, s.title, s.parent_id, s.directory, s.time_updated, lr.root_id
    FROM leaf_root lr
    JOIN target_roots tr ON tr.root_id = lr.root_id
    JOIN session s ON s.id = lr.leaf_id
    ORDER BY s.time_updated DESC;
  `);

  return query.all(...capped);
}

/** Chunk size for `queryTreesForIds`: queryTreesForSessions' own per-statement cap. */
export const IDS_CHUNK = 200;
/** Hard cap on one `--ids` request. Past it the tail is dropped LOUDLY (onWarn). */
export const IDS_CAP = 2000;

/**
 * `oc-session-list --ids`: the FULL root trees of an explicit set of session
 * ids, independent of the recency window.
 *
 * A thin loop over queryTreesForSessions, so it inherits both of that
 * function's properties -- archived stays gone, a child id brings its whole
 * tree -- instead of re-deriving them. The loop exists because that function
 * silently keeps only the first 200 ids of a call: fine for its overlay-union
 * caller, wrong for a caller that names its set explicitly (a program's tagged
 * sessions plus its item sessions can exceed 200). Each statement stays
 * bounded at IDS_CHUNK; the whole request is capped at IDS_CAP, and exceeding
 * the cap WARNS rather than truncating in silence.
 *
 * Rows are deduped by id (two chunks can name members of one tree) and
 * returned newest-first, the order a single queryTreesForSessions call uses.
 */
export function queryTreesForIds(
  db: Database,
  sessionIds: string[],
  onWarn?: (msg: string) => void,
): SessionRow[] {
  let ids = [
    ...new Set(
      sessionIds
        .filter((s) => typeof s === "string")
        .map((s) => s.trim())
        .filter((s) => s !== ""),
    ),
  ];
  if (ids.length > IDS_CAP) {
    onWarn?.(`--ids named ${ids.length} sessions; only the first ${IDS_CAP} were resolved`);
    ids = ids.slice(0, IDS_CAP);
  }
  const byId = new Map<string, SessionRow>();
  for (let i = 0; i < ids.length; i += IDS_CHUNK) {
    for (const row of queryTreesForSessions(db, ids.slice(i, i + IDS_CHUNK))) {
      if (!byId.has(row.id)) byId.set(row.id, row);
    }
  }
  const matchedByRoot = new Map<string, string[]>();
  for (const id of ids) {
    const row = byId.get(id);
    if (row) {
      let list = matchedByRoot.get(row.root_id);
      if (!list) {
        list = [];
        matchedByRoot.set(row.root_id, list);
      }
      list.push(id);
    }
  }
  for (const [rootId, matched] of matchedByRoot) {
    const rootRow = byId.get(rootId);
    if (rootRow) {
      rootRow.matched_ids = matched;
    }
  }
  return [...byId.values()].sort(
    (a, b) => b.time_updated - a.time_updated || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
  );
}

export function queryBaseList(db: Database, options?: BaseListOptions): SessionRow[] {
  const limit = options?.limit ?? 50;

  db.exec("PRAGMA busy_timeout = 5000;");

  const query = db.query<SessionRow, [number]>(`
    WITH RECURSIVE session_ancestry(leaf_id, curr_id, parent_id, depth) AS (
      SELECT id AS leaf_id, id AS curr_id, parent_id, 0 AS depth
      FROM session
      WHERE time_archived IS NULL

      UNION ALL

      SELECT sa.leaf_id, p.id, p.parent_id, sa.depth + 1
      FROM session_ancestry sa
      JOIN session p ON p.id = sa.parent_id
      WHERE sa.parent_id IS NOT NULL
        AND p.time_archived IS NULL
        -- Depth bound is load-bearing for CYCLE SAFETY, not just convention.
        -- Removing it makes a parent_id cycle spin forever inside SQLite's
        -- native call, which bun's per-test timeout CANNOT interrupt: the
        -- cycle test hangs the runner rather than failing (verified by
        -- mutation, 2026-07-31). Bounded at 8, matching the in-repo convention.
        AND sa.depth < 8
    ),
    leaf_root AS (
      SELECT leaf_id, curr_id AS root_id
      FROM (
        SELECT leaf_id, curr_id,
               ROW_NUMBER() OVER (PARTITION BY leaf_id ORDER BY depth DESC) AS rn
        FROM session_ancestry
      )
      WHERE rn = 1
    ),
    tree AS (
      SELECT lr.root_id, s.id, s.title, s.parent_id, s.directory, s.time_updated
      FROM leaf_root lr
      JOIN session s ON s.id = lr.leaf_id
    ),
    root_recency AS (
      SELECT root_id, MAX(time_updated) AS max_time_updated
      FROM tree
      GROUP BY root_id
      ORDER BY max_time_updated DESC
      LIMIT ?
    )
    SELECT t.id, t.title, t.parent_id, t.directory, t.time_updated, t.root_id
    FROM root_recency rr
    JOIN tree t ON t.root_id = rr.root_id
    ORDER BY rr.max_time_updated DESC, t.time_updated DESC;
  `);

  return query.all(limit);
}
