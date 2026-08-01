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
}

export interface BaseListOptions {
  limit?: number;
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
