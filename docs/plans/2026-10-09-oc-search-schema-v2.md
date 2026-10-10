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

## Revisions after oracle consult (ses_edd3bb088fferJx9mx1S0bw2nY) — these override the sections above

1. **Disk precheck.**
   - Estimate a rebuild from the live row count (`count(*)` via `sqlite_autoindex_part_1`, 0.15s) times the bytes per row of the existing index. Use the measured 7.2 KB/row when there is no index to measure.
   - Today's estimate (sample of the oldest rows × rowid span × 2.8 × 1.5 = 42G) would refuse the rebuild every hour.
   - The incremental `MIN_FREE_BYTES` guard stays.
   - **Rollout gate:** deploy only when free space is at least ~35G, or after workstation-qpb7. It was 21.5G at 18:40.
2. **Sweep shape (WAL pin).**
   - Never ATTACH the source to the index's read-write connection. A source read inside an open index write transaction pins the source WAL; the oracle verified this.
   - Instead, ATTACH the index **read-only** onto the source connection and run the sweep there as plain SELECTs with `LIMIT bound+1`.
   - All writes go through the index connection.
   - The checkpoint test is extended to cover the sweep and reconcile phases.
3. **Pinned plans.** Two queries, each with a test asserting its plan via EXPLAIN QUERY PLAN:
   - Identity: `FROM part p INDEXED BY sqlite_autoindex_part_1 LEFT JOIN idx.part_meta pm ON pm.rowid_=p.rowid WHERE p.rowid<=? AND pm.part_id IS NOT p.id` (asserts `COVERING INDEX`).
   - Deletes: `rowid_ NOT IN (SELECT +rowid FROM part INDEXED BY sqlite_autoindex_part_1)` (asserts `LIST SUBQUERY`).
4. **Reconcile bounds and mode.**
   - `RECONCILE_MAX` counts only rows whose identity changed. That is the renumber detector.
   - Deletes get their own, much higher bound (`DELETE_MAX = 1_000_000`).
   - Bounds are injectable.
   - `build_index` returns `mode: "noop"|"reconcile"|"rebuild"`, and the tests assert it.
5. **`--limit` stop.**
   - Dirty rows at or below W fold their live `(rowid>>14, time_created)` into the prefix, the same way the tail does.
   - Total order is `(last_match desc, id desc)`, in both `decorate` and `search_recent`.
   - Stop only when the N-th picked time is **strictly greater** than the bound.
   - The window `(lo,hi]` uses `bucket(lo)`.
6. **Query path.**
   - All index-side reads run inside one `BEGIN … COMMIT` read transaction on the read-only index connection.
   - **The anchor walk is replaced by a window diff.** Over the top `RECHECK_ROWS` at or below W, in one statement, the dirty set is:
     - rows whose `part_id` or `time_updated` differs from part_meta;
     - part_meta rows missing from the source;
     - source rows missing from part_meta.
   - At least one identity-matching row in the window means everything below it is clean. If none match, the index is unusable.
   - The dirty set goes in a temp table on the index connection. Never put it on the source connection: that connection is `query_only`.
   - Docs: an interior delete can also produce an extra session row with a wrong `last_match` in unlimited search, not only an over-count.
   - If the sweep deletes the W row, re-point the watermark to the highest remaining part_meta row.
7. **No cap on `--index` at all.** `--index-batch` stays as an option, defaulting to unlimited. Without that, an interrupted rebuild would resume capped.
8. **`fcntl.flock` on `index.db.lock`.** A second concurrent `--index` exits 0 with a message.
   - Query code catches `sqlite3.DatabaseError` around index use and falls back.
   - Expected downtime after deploy: unlimited searches use tail scans for ~1-3h. `--limit` is unaffected.
9. **No `'merge'` command**, because automerge and deletemerge already cover it. Still no `optimize`.
   - The no-plain-INSERT rule is pinned both by a source-grep test and by a behaviour test.
   - v1 → v2 recreates the file.
10. **SDD and tests.**
    - A minimal differential harness (indexed vs `--no-index`) lands in Task 1. Each later task grows its op generator: ties, reverse-ordered block, top reuse, small `READ_CHUNK`/`COMMIT_EVERY`, interrupted build.
    - The fixture gains `part_session_idx`.
    - Tests that flip:
      - `test_watermark_row_replaced_invalidates_the_index`
      - `test_rowid_reuse_between_chunks_forces_a_rebuild`
      - `test_bulk_inserted_block_picks_by_insertion_order`
    - New tests: W deleted gives a re-pointed watermark; plan assertions; checkpoint not busy during the sweep; flock; an interrupted rebuild finishes in the next run.

### Revised task list

1. **Schema, build, and harness.**
   - v2 schema; `contentless_delete`; REPLACE-only writes, with both the grep test and the behaviour test; tmax.
   - Capability probe; v1 recreated as v2.
   - No cap; new disk estimate; flock; `mode` in the result.
   - Fixture indexes; `update_part`/`delete_part` helpers.
   - Differential harness: insert-only ops plus build.
2. **Indexer reconcile.**
   - Pinned-plan sweep on the source connection with the index ATTACHed read-only.
   - Identity bound vs delete bound; `time_updated` recheck; watermark re-point.
   - Chunk-boundary mismatch becomes MORE REMAINS.
   - Flip the two invalidation tests. Extend the checkpoint test.
   - Harness ops: update, interior delete, session delete, top reuse, interrupted build.
3. **Query path.** Single read transaction; window-diff dirty set; the temp table excluded from FTS and rescanned live; DatabaseError fallback. Harness: queries between builds.
4. **Exact `--limit`.** tmax prefix plus tail and dirty folding; total order; strict stop; TAIL_EXACT_MAX heuristic; flip the bulk test. Harness: ties, reverse block, `--limit` equal to the unlimited `[:N]`.
5. **Unit and docs.** `SuccessExitStatus=3`, README, docstring, home.base.nix comment.

## Revisions after adversarial review

1. **TAIL_EXACT_MAX 200k → 50k:**
   Cold-cache measurement on the real database: a 200k-row tail GROUP BY took ~18s against a 25s total budget. Reduced to 50k to ensure fast tail aggregation before fallback to heuristic stop.
2. **TMAX_SHIFT 14 → 12:**
   16k-rowid buckets (TMAX_SHIFT=14) spanned ≈ 7.7h of data, causing exact mode to recount 17-46 sessions vs 10. 4k buckets (TMAX_SHIFT=12) span ≈ 2h, making exact stopping significantly tighter.
3. **Reconcile delete disk amplification guard & chunked commits:**
   - Fractional delete bound: `DELETE_FRACTION_MAX = 0.10` of `part_meta`'s row count (in addition to `DELETE_MAX`). Exceeding it forces a clean rebuild (which unlinks the file first, reclaiming disk space instead of exploding the WAL).
   - Deletes and rewrites are applied in committed chunks (`RECONCILE_COMMIT_EVERY = 5_000` rows), with an active disk check between chunks (`shutil.disk_usage(index_dir).free < MIN_FREE_BYTES`).
   - Safe watermark re-pointing ensures `watermark_rowid` in `meta` never points to a row deleted from `part_meta` after a partial or interrupted run. An interrupted reconcile leaves the index query-safe and resumes cleanly on the next run.
4. **Disk precheck estimates:**
   - When an explicit `--index-batch` is passed, rows estimate is capped at the batch for both rebuild and catch-up.
   - For catch-up, pending rows are estimated cheaply via `min(rowid span, max(0, live count via sqlite_autoindex_part_1 - part_meta count))`, avoiding expensive table page scans.
5. **Documented limits:**
   - (i) A part updated more than `RECHECK_ROWS` (~47h at ~51k rowids/day) after creation is never re-indexed now that rebuilds are rare (v1's daily rebuild used to mask this; opencode's compaction prune, `compaction.ts`, rewrites old tool parts and is disabled on cloudbox via `"prune": false` — enabling it would make old parts stale).
   - (ii) `tmax` is never lowered, so a bogus future `time_created` would disable early stopping until `oc-search --index --rebuild`.
