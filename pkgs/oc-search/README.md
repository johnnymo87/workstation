# oc-search

Search OpenCode session history for a substring, and get back the sessions
that contain it.

```
$ oc-search FbmEmployeeCutoffRepublishService
id                              title                                     directory                                      last_match           matches
------------------------------  ----------------------------------------  ---------------------------------------------  -------------------  -------
ses_0e1fd435dffemNguOIWpzb0ChF  Implement Task 1: republish service (@im   /home/dev/projects/mono/.worktrees/fbm-employ  2026-07-01 10:25:14  30
ses_0e1f35200ffeh8OCz65MM0vpfd  Code review Task 1 (@code-reviewer subag   /home/dev/projects/mono/.worktrees/fbm-employ  2026-07-01 10:20:53  8
...
```

## Usage

    oc-search DATA-4297                     # tool parts only (default)
    oc-search --types tool,text 'auth'      # widen the scope
    oc-search --all rules_oci               # every part type
    oc-search -- --some-dashy-string        # `--` protects a dashy query
    oc-search --json --limit 10 mono        # machine-readable

    oc-search --index                       # build / refresh the index
    oc-search --index --if-exists           # refresh only if one exists (timer)
    oc-search --index --rebuild             # start over
    oc-search --index-info                  # what state is the index in?
    oc-search --no-index mono               # ignore the index (a full scan)

Semantics are **byte-exact, case-sensitive substring match** — the same thing
`instr()` does — and are identical whether or not an index exists.

## Why this stopped being a one-line SQL query

The previous implementation was a bash + `sqlite3` heredoc embedded in
`users/dev/home.base.nix`. It ran an unindexed scan:

```sql
SELECT ... FROM part WHERE instr(p.data, 'query') > 0 AND json_extract(...) IN (...)
```

Measured on cloudbox, 2026-08-05, against the live `opencode.db`:

| Quantity | Value |
|---|---|
| `part` rows | 1,572,057 |
| `SUM(length(part.data))` | 4,105,562,053 (4.1 GB of JSON) |
| `opencode.db` on disk | 13.0 GB |
| ...of which freelist | 1,511,084 pages = 6.2 GB (47%) |
| `SELECT count(*), sum(length(data)) FROM part`, cold | **5m49s** (user CPU 6.1s) |
| `oc-search FbmEmployeeCutoffRepublishService`, end to end | **4m13s** |
| raw sequential read of the same file (`dd iflag=direct`) | 441 MB/s |

Three things fall out of those numbers, and all three contradict the obvious
guesses:

1. **It was not JSON parsing.** 6 seconds of user CPU against 349 seconds of
   wall clock. The query was waiting on I/O essentially the whole time.

2. **`--all` was never the problem.** The `--types` filter is a predicate
   evaluated *after* each row is read, not a way to read fewer rows. Every
   mode already read every byte of every part; `--all` is if anything the
   cheaper one, because it skips the `json_extract`. `--all` appearing to be
   "the slow mode" was page-cache warmth, not scope.

3. **The scan was latency-bound, not bandwidth-bound.** The same file streams
   at 441 MB/s, while SQLite's serial page-at-a-time walk achieved ~12–40
   MB/s. Nearly half the file is freelist, so live pages are scattered and
   read-ahead does not help.

Per-type breakdown, for anyone tempted to shrink the corpus:

| type | rows | bytes |
|---|---|---|
| tool | 398,663 | 2.95 GB |
| reasoning | 195,103 | 610 MB |
| text | 228,567 | 425 MB |
| step-finish | 362,154 | 77 MB |
| step-start | 362,905 | 27 MB |
| patch | 23,499 | 19 MB |

## What it does now

### 1. A trigram index, in a sidecar, outside `opencode.db` (schema v2)

`~/.cache/oc-search/index.db` holds a schema v2 sidecar index:
- `ft`: virtual table using `fts5(data, tokenize="trigram case_sensitive 1", content='', contentless_delete=1)`.
- `part_meta`: `rowid_ INTEGER PRIMARY KEY, part_id TEXT NOT NULL, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, type TEXT`.
- `tmax`: `bucket INTEGER PRIMARY KEY, max_tc INTEGER NOT NULL`, with `bucket = rowid >> 12` (`TMAX_SHIFT = 12`, 4k-rowid buckets ≈ 2h of data), tracking the per-bucket maximum `time_created`, never lowered.

`opencode.db` is never written to. It is opened `mode=ro` with
`PRAGMA query_only=ON`, exactly as before.

**Why trigram, and why `detail=full`.** With `detail=full` a quoted FTS5
phrase over trigram tokens matches exactly the rows whose text contains the
literal string — so index results are identical to `instr()`, not an
approximation of it. Verified against `instr` on a 49k-row slice of the real
database: 230/230 for a rare identifier and 8,573/8,573 for a common one, no
false positives and no false negatives. The test suite re-checks this
exhaustively over every substring of a deliberately awkward corpus (>1,000
needles, each compared three ways: indexed, scanned, and raw `instr`).

The cheaper `detail=none` variant was measured too (0.63× the source size,
against 2.8× for `detail=full`) and **rejected**: it can only produce
candidates, which must then be verified by reading the candidates' `data`.
That is fine for a rare identifier and useless for a common one — `mono`, the
term lgtm actually searches for, occurs in 17.5% of parts, so verification
would have meant reading ~700 MB per query and we would be back where we
started.

**Why REPLACE-only writes (ghost postings).** On a contentless FTS5 table,
a plain `INSERT INTO ft(rowid, ...)` at an existing rowid leaves a permanent
ghost posting, even with `contentless_delete=1` (neither a subsequent REPLACE
nor a DELETE removes the orphaned posting later). Therefore, every write to
`ft` is `INSERT OR REPLACE`, and every removal is `DELETE FROM ft WHERE rowid=?`.
Upgrading from v1 to v2 recreates the index file to clear any prior ghost
postings.

**Historical measurements and disk costs:**
- *(Historical: 2026-08-05 on cloudbox, 1.57M rows):* the finished index was
  **10.88 GB** for 1,576,152 rows (2.65× the 4.1 GB of text) and took
  roughly **80 minutes** to build (uninterrupted 726k rows at 331 rows/s).
- *(October 2026 on cloudbox, 3.35M rows):* the v2 index is estimated at
  ~20 GB (7.2 KB/row) and takes roughly ~1.5–2.5h to build uncapped at idle I/O.
- Hourly refreshes reconcile changes and catch up the tail in seconds.

**The indexer (`--index`): reconcile sweep, recheck, catch-up.**
Each run executes under `fcntl.flock` on `~/.cache/oc-search/index.db.lock`
(a concurrent `--index` exits 0 with an in-progress message). The sequence:

1. **Identity sweep (`rowid <= W`):** ATTACHes the index read-only
   (`file:...mode=ro`) onto the source connection. (Never ATTACH the source to
   the index's read-write connection: holding source SELECTs inside an open
   index write transaction pins the source WAL and blocks checkpoints.)
   Executes two pinned covering-index plans:
   - Identity check: walks `part INDEXED BY sqlite_autoindex_part_1` left-joined
     with `idx.part_meta` (`p.rowid <= W AND pm.part_id IS NOT p.id`) to detect
     replaced or renumbered rows.
   - Deletes check: finds `part_meta` rows no longer in `part INDEXED BY sqlite_autoindex_part_1`
     via a list subquery.
    - Bounds: `RECONCILE_MAX = 50_000` changed-identity rows (renumber detector;
      exceeding forces a clean rebuild); `DELETE_MAX = 1_000_000` deleted rows
      and `DELETE_FRACTION_MAX = 0.10` (10% of `part_meta` row count, exceeding
      forces a clean rebuild, deleting the old file to free disk space instead of
      amplifying the WAL).
    - Chunked commits: deletes and rewrites are applied in committed chunks of
      `RECONCILE_COMMIT_EVERY = 5_000` rows, checking `shutil.disk_usage.free < MIN_FREE_BYTES`
      between chunks to stop safely if disk runs low.
    - Watermark re-point: if row W was deleted or changed, W is re-pointed
      safely to `MAX(rowid_)` of the remaining `part_meta` rows (ensuring it never
      points to a row deleted from `part_meta` after a partial or interrupted run).

2. **`time_updated` recheck:** walks the top `RECHECK_ROWS = 100_000` rowids
   at or below W. Any row whose live `time_updated` differs from `part_meta`
   (e.g. a tool part updated in place after running) is re-indexed.

3. **Tail catch-up (`rowid > W`):** reads source chunks in batches of
   `READ_CHUNK = 2,000` rows and commits every `COMMIT_EVERY = 10,000` rows with
   `journal_size_limit = 64 MB`.
   - Chunk-boundary mismatch: if a rowid changes under the scan at a chunk
     boundary (rowid reuse after a delete), catch-up commits progress so far
     and exits 3 (`MORE REMAINS`). It does not rebuild; the next run's sweep
     repairs the chunk.
   - Uncapped runs: tail catch-up is uncapped by default (`DEFAULT_INDEX_BATCH = None`),
     so an initial build, schema migration, or `--rebuild` completes in one run.
     `--index-batch N` remains available for explicit batching.

4. **Disk precheck:** estimates space from live row count (`count(*)` via
   index, ~0.15s) times measured bytes/row of existing index (or 7.2 KB/row
   fallback), crediting the existing index on a rebuild. When an explicit `--index-batch`
   is provided, rows are capped at the batch for both rebuild and catch-up. For catch-up,
   pending rows are estimated cheaply via `min(rowid span, max(0, live count via sqlite_autoindex_part_1 - part_meta count))`.
   It aborts before starting if free disk does not cover the estimate plus `MIN_FREE_BYTES` (5 GB),
   and aborts mid-run if free space drops below 5 GB.

### 2. A stale index costs time, never truth

The index stores a **watermark**: the highest `part.rowid` it has seen.
`part.rowid` is monotonic in `time_created` across almost the entire table
(with the historical exception of the 2026-06-07 bulk-inserted block,
rowids ~852k-955k, where ~100k parts were inserted in reverse order).

**The query path: single read snapshot & window-diff dirty set.**
Queries never write to the index or source:
- All index reads run inside a single `BEGIN ... COMMIT` read transaction
  on a read-only index connection, preventing double-counting if the indexer
  commits mid-query.
- Over the top `RECHECK_ROWS = 100_000` rowids at or below the watermark,
  a single statement computes the **dirty set**:
  - rows where `part_id` or `time_updated` differs between `part` and `part_meta`;
  - `part_meta` rows missing from the source (deleted);
  - source rows missing from `part_meta` (top-of-table reuse or unindexed inserts).
- The dirty rowids are loaded into a temporary table on the index connection.
  Index queries exclude them (`ft.rowid NOT IN temp.dirty`). The live scan
  covers the unindexed tail (`rowid > W`) plus the dirty rowids (`rowid IN temp.dirty`).
- **When is the index unusable?** If no row in the window matches identity
  (indicating a total table renumbering), or if index metadata is invalid
  (e.g. `tmax_shift` mismatch, corrupt DB), the index is marked unusable.
  Queries fall back to the 16-way parallel live scan with a warning.
- Watermark row changes do NOT force a rebuild; the window diff and dirty set
  handle them seamlessly until the next indexer run reconciles.
- **Documented staleness:** an interior part deleted strictly below the
  recheck window (`rowid < W - RECHECK_ROWS`) since the last indexer run can
  over-count matches or surface an extra session row in UNLIMITED search
  until the next hourly sweep removes it. `--limit` is never affected because
  it recounts matches live against `opencode.db`.
- Sessions deleted from `opencode.db` disappear immediately because results
  join the live `session` table.

A user timer (`oc-search-index.timer`, hourly, `Nice=19`,
`IOSchedulingClass=idle`) keeps the tail short. It is an optimisation, not a
correctness requirement, and it runs `--index --if-exists`: it refreshes an
index somebody opted into and never creates one. Deciding to spend ~20 GB is a
human's call, made once per host by running `oc-search --index`.

### 3. The fallback is parallel, and it is loud

With no usable index, oc-search still answers — by scanning — but:

- the scan is split across 16 connections by rowid range, which is legitimate
  because every row falls in exactly one half-open range. Since the bottleneck
  is I/O latency rather than bandwidth, this recovers a large multiple of the
  serial rate;
- it prints a warning to stderr **before** starting, naming the fix;
- it enforces its own deadline (default 25s when stdout is not a TTY, none
  when it is, `--timeout` to override) and exits **2** with an explanation.

That last point is the fix for a specific bug, below.

## Before and after

All timings on cloudbox against the live 13 GB `opencode.db`. "cold" means the
page cache was dropped (`posix_fadvise(DONTNEED)`) over the database *and* the
index immediately beforehand; "warm" is a repeat run. "before" is the shipped
bash implementation, run from the same shell on the same data.

| query | before | after, no index (16-way scan) | after, indexed, cold | after, indexed, warm |
|---|---|---|---|---|
| `FbmEmployeeCutoffRepublishService` (default `tool` scope) | **5m20.9s** | — | **15.1s** | **5.6s** |
| `--types tool,text mono` (the lgtm query) | **6m14.5s** | **1m21.5s** | **18.4s** | **0.46s** |
| `--all fbm-delete-employee-republish` | killed at 120s, no output | — | **15.4s** | — |

That is 21× cold / 57× warm on the first, and 20× cold / 813× warm on lgtm's.
The fallback scan alone — no index at all — is 4.6× the old one.

**The results are identical, not merely similar.** Both queries were run under
both implementations and the session-id sets compared:

    query 1:  361 sessions before, 361 after, 0 differing
    lgtm:   6,902 sessions before, 6,902 after, 0 differing

Note what the cold numbers say about where the remaining time goes: 18.4s cold
versus 0.46s warm for `mono` is all I/O against a 10.9 GB index whose posting
lists for a common trigram are large. A rare term is cheaper. Neither is
anywhere near a caller's timeout.

## The lgtm failure

The lgtm PR-review daemon builds its review context by shelling out
(`src/context.ts`, `buildSessionHistorySection`) to:

    oc-search --types tool,text <repo-name>

through a helper whose default timeout is 30 seconds and which **swallows
failures on purpose** because context building is best-effort. On 2026-08-05
its journal showed:

    shell.run failed: oc-search --types tool,text mono -- Command failed: oc-search --types tool,text mono

Reproduced exactly, with node, against the shipped binary:

```
FAIL after 30034 ms
message: Command failed: oc-search --types tool,text mono
code: null signal: SIGTERM killed: true
```

So it was **a timeout**, not an OOM and not a non-zero exit on no-match. Note
what the log line does *not* contain: any reason. stderr was empty because
nothing had gone wrong from oc-search's point of view — it was still working
when node killed it. Every review dispatched in that state was built without
its session-history section, and nothing anywhere said so.

Both halves are addressed, and both were re-run through the same node harness
against the built package:

**Speed.** The exact call now succeeds:

```
OK 10130 ms, stdout len 1035600
```

**Loudness.** Forced back onto the scan path (`--index-path /nonexistent`),
this is what lgtm's journal line would now read:

```
shell.run failed: oc-search --types tool,text mono -- Command failed: oc-search --index-path /nonexistent/index.db --types tool,text mono
oc-search: no usable index at /nonexistent/index.db: scanning every part row (16-way). This reads gigabytes and takes minutes on a cold cache. Build the index once with `oc-search --index`.
oc-search: aborted after 25s: full scan of /home/dev/.local/share/opencode/opencode.db did not finish. Run `oc-search --index` once to make this fast.

code: 2 signal: null killed: false
```

`code: 2 signal: null` rather than `code: null signal: SIGTERM` is the whole
point: oc-search now ends its own run, at 25s, before the caller's 30s budget
expires, and says why. Node's `execFile` concatenates the child's stderr into
the error message, so the reason travels into the consumer's log by itself.

### `--limit`: exact stop rule with `tmax` (beads workstation-gqt3.1 & workstation-gqt3.3)

The index did not stay a fix. Between 09-15 and 10-09 lgtm logged 97
`aborted after 25s: index query` lines, several of them while the index was
complete. Two causes:

- the unlimited query aggregates every match, and a common needle like `mono`
  has millions of postings in a ~20 GB index, cold under bazel I/O;
- when an index was mid-rebuild, unlimited queries fell back to a large tail scan.

And lgtm keeps the first 2,000 characters, about ten rows, of a 1.8 MB answer.

`--limit N` walks newest-first and stops as soon as the top N sessions are
guaranteed found (`search_recent`):
- It scans the unindexed tail top-down in growing rowid windows, then reads
  index postings in descending rowid order, recounting each chosen session
  live via `part_session_idx`.

**Exact stop rule:**
Walking down at rowid position p, any session not yet encountered has all its
matching parts at or below p. Its `last_match` timestamp is therefore bounded
by the maximum `time_created` of all rows at or below p:
- For indexed rows (`rowid <= W`), prefix maximums are retrieved from the `tmax`
  table (`bucket = rowid >> 12`, `TMAX_SHIFT = 12`).
- For the unindexed tail (`rowid > W`), a single query computes per-bucket
  `MAX(time_created)` and folds it into the prefix bound.
- Any dirty rows at or below W fold their live `time_created` into the bound.
- Search stops when the N-th picked session's `last_match` is strictly greater
  than the prefix bound at position p.

**Preconditions for the exact rule:**
1. A usable index exists.
2. The unindexed tail is at most `TAIL_EXACT_MAX = 50_000` rows.
If there is no usable index, or if the tail exceeds 50,000 rows (e.g. during an
initial index build or massive unindexed backlog), `search_recent` falls back
to the heuristic insertion-order stop.

**Total order:** Sessions are ordered by `(last_match DESC, id DESC)`. This
deterministic total order ensures tie-breaking matches between `--limit N`
and the first N rows of an unlimited search.

**Motivating example: the June 7 bulk block.**
`part.rowid` is monotonic in `time_created` across almost all 3.3M+ rows,
with one historical exception: rowids ~852k-955k, where ~100k parts from 05-31
to 06-07 were bulk-inserted on 06-07 in roughly reverse chronological order.
Under the insertion-order heuristic, `--types tool,text cops-6234-proto --limit 20`
returned 5 of 20 wrong sessions. Under v2's exact stop rule bounded by `tmax`,
it returns the exact newest 20 sessions.

Measured on cloudbox (2026-10-09), with the index about 40% built (watermark 1.25M of 3.35M rowids):

| query | unlimited | `--limit` | `--limit --no-index` |
|---|---|---|---|
| `--types tool,text mono`, limit 10 | 7.2s warm | **0.26s** | **0.26s** |
| `--all "recipe card pipeline"` (rare, 3 sessions), limit 5 | 2.2s warm | 2.9s | — |

A needle that never reaches N sessions reads the same rows as the unlimited
search, in a few more passes. The cost is roughly 1.3x warm.

Output details:
- table column widths follow the rows shown;
- counts and `last_match` come from live recounts: `--limit` is always exact,
  and deleted parts/sessions never consume a slot. (In unlimited search, an
  interior part deleted strictly below `W - RECHECK_ROWS` since the last
  indexer run can over-count until the next hourly sweep).

The recounts run serially, and each costs the session's size in bytes. The
largest session (36.5k parts, 76 MB) takes 3.5s warm. Today's lgtm top-10
sets total 19-40 MB.

There is a remaining gap that this package cannot close: lgtm swallows the
failure and returns `""`. A packet built without session history is still
indistinguishable from one where the search legitimately found nothing. That
belongs in the lgtm repo, not here.

### Documented limits

1. **Parts updated past `RECHECK_ROWS`:** A part updated more than `RECHECK_ROWS`
   (~47h at ~51k rowids/day) after creation is never re-indexed now that rebuilds
   are rare. (v1's daily rebuild used to mask this; opencode's compaction prune,
   `compaction.ts`, rewrites old tool parts and is disabled on cloudbox via
   `"prune": false` — enabling it would make old parts stale).
2. **`tmax` is monotonic:** `tmax` is never lowered, so a bogus future
   `time_created` would disable early stopping until `oc-search --index --rebuild`.

## Rollout and upgrade to v2

A v1 index is recognized by schema version (`INDEX_SCHEMA_VERSION = 2`) and
recreated as v2 by the next timer run, in place, in one uncapped run.
- After deploy, start the unit immediately (`systemctl --user start oc-search-index`) rather than waiting up to an hour.
- Building the ~3.35M row index takes ~1.5–2.5h at idle I/O (`Nice=19`, `IOSchedulingClass=idle`).
- Disk requirement: the precheck needs roughly 23 GB available (free + the v1 file being replaced) or the unit refuses with exit 1 and the v1 index stays unusable to v2 (unlimited searches full-scan, `--limit` heuristic) until disk frees.
- During the rebuild, unlimited searches scan a shrinking tail; `--limit` stays fast throughout.

## Tests

    python3 pkgs/oc-search/test_oc_search.py

Run in CI as `checks.oc-search` in `flake.nix` (a `checks.*` entry, not a
`checkPhase` — see `users/dev/test-unwired-tests.sh` for why that distinction
is enforced).
