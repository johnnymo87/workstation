import type { Database } from "bun:sqlite";

export interface SessionRow {
  id: string;
  title: string;
  parent_id: string | null;
  directory: string;
  time_updated: number;
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
    SELECT t.id, t.title, t.parent_id, t.directory, t.time_updated
    FROM root_recency rr
    JOIN tree t ON t.root_id = rr.root_id
    ORDER BY rr.max_time_updated DESC, t.time_updated DESC;
  `);

  return query.all(limit);
}
