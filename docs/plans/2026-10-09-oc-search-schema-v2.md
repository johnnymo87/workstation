# oc-search schema v2: reconcile instead of rebuild, exact `--limit` stop

Bead: `workstation-gqt3.3` (epic `workstation-gqt3`). Code: `pkgs/oc-search/oc_search.py`.

## Problem

The sidecar index fully rebuilds about once a day. A rebuild runs at 200k rows/hour, so it takes ~15 hourly runs, and 170 of 426 runs since 09-22 ended incomplete. The cause is that any change to the watermark row W (the newest indexed part) invalidates everything (`index_validity`, `build_index` ~437-443). The chunk-boundary check (~562-579) does the same. 15 of 19 rebuilds were false alarms: an interior delete with no rowid reuse.

The daily rebuild also hides three correctness bugs:

1. **Parts are upserted in place.** They keep the same rowid and get new `data`/`time_updated`. A tool part that was indexed while still running is never re-indexed.
2. **Deleted parts keep their postings.** This applies to parts deleted inside sessions that still exist. Unlimited search over-counts them, and they can surface a session that no longer matches.
3. **A plain INSERT at an existing rowid leaves a ghost.** On a contentless FTS5 table this keeps the old postings, even with `contentless_delete=1`.

Separately, `--limit` (gqt3.1) picks sessions in insertion order, which is wrong across the 2026-06-07 reverse-chronological bulk block (rowids ~852k-955k). It returns 5 of 20 wrong for `cops-6234-proto --limit 20`.

## Measurements behind the design (cloudbox, 2026-10-09, warm)

| Probe | Result |
|---|---|
| `SELECT rowid,id FROM part INDEXED BY part_message_id_id_idx`, fully iterated | 2.78M rows in 1.5s (3.5s with `sum(length(id))`) |
| `SELECT count(*) FROM part INDEXED BY part_session_idx` | 0.38s |
| `time_updated`/`time_created` over the top 50k rowids (≈26h) | 0.036s |
| Parts in the top 50k updated >1 min after creation | 796, max 3.75h later |
| Parts in the top 500k updated >24h after creation | 0 |
| SQLite (nix python) | 3.50.4. `contentless_delete` needs ≥3.43 |
| Free disk / live index | 29G free, 6.2G index at watermark 1.45M of 3.35M (mid-rebuild) |

The first row is the key one. A **full** (rowid, id) identity comparison of the live table is a few seconds, because a covering index already exists. That changes the cost of the agreed design.

## Design

### Schema v2 (`INDEX_SCHEMA_VERSION = 2`)

```sql
CREATE VIRTUAL TABLE ft USING fts5(data, tokenize="trigram case_sensitive 1",
                                   content='', contentless_delete=1);
CREATE TABLE part_meta (rowid_ INTEGER PRIMARY KEY, part_id TEXT NOT NULL,
  session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL, type TEXT);
CREATE TABLE tmax (bucket INTEGER PRIMARY KEY, max_tc INTEGER NOT NULL);  -- bucket = rowid >> 14
```

- **Every write to `ft` is `INSERT OR REPLACE`; every removal is `DELETE ... WHERE rowid=?`.** A plain `INSERT INTO ft` must not appear anywhere (hazard 3 above). A test pins this.
- **`tmax` holds the per-bucket max of `time_created`, and is never lowered.** A delete leaves the bucket max stale-high, which is conservative for the stop rule. A replace raises it if needed. Queries compute the prefix max over ~205 rows.
- **The capability probe also creates a `contentless_delete=1` table, then REPLACEs and DELETEs a row.** The point is that an old SQLite fails loudly.
- **A v1 index fails the version check and is rebuilt once.**

### Indexer (`--index`): sweep, then recheck, then catch up

1. **Identity sweep over `rowid <= W`.** This is the full comparison, replacing the anchor walk on the write side. The index connection ATTACHes opencode.db read-only.
   - **Deleted:** `part_meta.rowid_` not present in `part INDEXED BY part_session_idx`. DELETE from `ft` and `part_meta`.
   - **Changed identity:** walk `part INDEXED BY part_message_id_id_idx` (rowid, id) where `part_meta.part_id` differs or is missing. Re-read the full row by rowid and replace it.
   - **Why the full sweep rather than the bounded anchor rollback:** it covers everything the anchor does — head deletes, top-of-table reuse, and a VACUUM INTO renumber (`workstation-yvxh.4`). It *also* fixes bug 2 (interior deletes), which the anchor cannot see. It costs seconds. Each statement runs to completion, so the source WAL read mark is held for seconds, not for the whole run (the o5s1.3 concern).
   - **Bound:** if the sweep finds more than `RECONCILE_MAX = 50_000` rows to fix, or more than 10% of `part_meta`, rebuild instead. A renumber lands here.
2. **`time_updated` recheck over the top `RECHECK_ROWS = 100_000` rowids at or below W.** That is about 2 days; the observed max lag is 3.75h. Replace any row whose live `time_updated` differs from `part_meta`. This fixes bug 1.
3. **Catch up the tail `(W, max]`,** exactly as today but with v2 columns and tmax. Normal runs stay capped at `--index-batch`. A rebuild, which is a fresh or version-mismatched index or `--rebuild`, is **uncapped**. It still commits every 10k rows, so an interruption leaves a smaller valid index.
4. **Chunk-boundary mismatch:** commit what has been indexed and return MORE REMAINS. Do not rebuild. The next run's sweep repairs the previous chunk.
5. After a run that wrote rows, run `INSERT INTO ft(ft, rank) VALUES('merge', 500)`. Never `optimize`.

**Rebuilds happen in place, not beside the old index.** Free space is 29G, against a ~20G expected index, so the "beside if free > 2× expected" branch would never fire on the one host that runs this, and it would be untested code. While a rebuild runs, the partial index is valid up to its watermark, so queries scan a shrinking tail; the `--limit` path stays fast regardless. **Dropped from the bead's design:** build beside and rename.

**Unit:** `SuccessExitStatus=3` on `oc-search-index.service`. MORE REMAINS stays exit 3 for humans, but stops marking the unit failed and degrading home-manager activation.

### Query path: read-only, with a dirty set

`index_validity` now returns `(usable, watermark, dirty: set[int], floor_ok: int)`:

- **Anchor (read-only).** If W's live id differs, walk `part_meta` downward from W until a row's live id matches, for at most 50k rows. Rowids in `(anchor, W]` are **dirty**. If no anchor is found within the bound, the index is unusable, falling back as today.
- **Updated rows.** For the top `RECHECK_ROWS` at or below the anchor, rows whose live `time_updated` differs from `part_meta`, or which are missing from it, are **dirty**.
- **Index results exclude dirty rowids** (`ft.rowid NOT IN dirty`, via a temp table). The live scan covers the tail above W, plus the dirty rowids (`rowid IN dirty`, scanned by PK).
- **Accepted, documented staleness:** an interior part deleted since the last indexer run (≤1h) can still over-count in unlimited search. Session deletes are already dropped by `decorate`, and `--limit` recounts against the live table, so neither is affected.

### Exact `--limit` stop rule

Walking down at position p, every session not yet met has all its matches at or below p, so its last match is at most `prefix_tmax(bucket(p))`. Keep the top N picked sessions by time, and stop only when the N-th picked time is at least the prefix max at the current position.

- **Index region (rows at or below W):** prefix max from `tmax`.
- **Tail region (W, max]:** before walking the tail, one query gets `SELECT rowid>>14, MAX(time_created) ... WHERE rowid > W GROUP BY 1`, merged into the same prefix. This is bounded: if the tail exceeds `TAIL_EXACT_MAX = 200_000` rows (no index, or mid-rebuild), skip the exact rule and keep today's insertion-order stop. The README and docstring say so.
- `test_bulk_inserted_block_picks_by_insertion_order` flips to asserting the exact newest N with an index. The no-index variant keeps the current assertion.
- **Not in scope:** parallel recounts (bead note b).

## Rollout

Merge, then `pull-workstation`. The next timer run sees v1, rebuilds in place uncapped (~1.5-2.5h at idle I/O), and finishes in one run. Queries keep working throughout. After it completes:

- confirm `--index-info` is up to date;
- run the indexed vs `--no-index` comparison for 3 needles;
- confirm `cops-6234-proto --limit 20` equals the first 20 rows of the unlimited search.

## Tasks (SDD, TDD each)

1. **v2 schema and build.**
   - `part_meta` columns, `contentless_delete=1`, `INSERT OR REPLACE` everywhere, and tmax maintenance.
   - Capability probe.
   - Uncapped rebuild; a v1 index is rebuilt once.
   - Test helpers `update_part` (bumps `time_updated`, rewrites data) and `delete_part`. `add_part` takes `time_updated`.
   - Tests: duplicate-rowid replace leaves no ghost; v1 to v2 rebuild happens once; tmax equals the true per-bucket max after a build.
2. **Indexer reconcile.**
   - Sweep: deletes and changed identity, plus the RECONCILE_MAX bound into a rebuild.
   - `time_updated` recheck.
   - Chunk-boundary mismatch becomes MORE REMAINS.
   - `merge`.
   - Tests:
     - deleting the head row with live rows above it gives a reconcile, not a rebuild;
     - true top-of-table reuse;
     - update after indexing;
     - mid-session part delete;
     - renumber (a mass rowid shift) gives a rebuild;
     - chunk-boundary mismatch gives MORE REMAINS with no rebuild, and the next run repairs it.
3. **Query path: anchor and dirty set** for unlimited and `--limit` search. Tests:
   - head delete, then a query before reindexing: correct results, index still used;
   - update with no reindex: the new text is found and the old text is not;
   - no anchor within the bound: falls back.
4. **Exact `--limit` stop via tmax.** Tests:
   - flip the bulk-block test;
   - a reverse-order block inside the tail;
   - a tail larger than TAIL_EXACT_MAX keeps the heuristic.
5. **Randomized differential test, unit, and docs.**
   - Seeded random sequences of insert, update, interior delete, session delete, top reuse, build, and search. After each build, indexed results must equal `--no-index` exactly, for both unlimited and `--limit` search.
   - Between builds, the same holds except for the documented interior-delete over-count. That op is excluded in the no-build variant.
   - `SuccessExitStatus=3`, README, and module docstring.
