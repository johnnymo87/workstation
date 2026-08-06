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

### 1. A trigram index, in a sidecar, outside `opencode.db`

`~/.cache/oc-search/index.db` holds a contentless FTS5 table over
`part.data` with `tokenize="trigram case_sensitive 1"` and the default
`detail=full`, plus a small `part_meta` table carrying each row's
`session_id`, `time_created` and `type` so that answering a query does not
have to go back to the 13 GB database at all.

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

**Cost of the choice, measured on the real corpus rather than extrapolated:**
the finished index is **10.88 GB** for 1,576,152 rows (2.65× the 4.1 GB of
indexed text, close to the 2.8× the sample predicted). Building it took
roughly **80 minutes** — the final, uninterrupted 726,152 rows went in at 331
rows/s — on a host that was simultaneously serving a dozen opencode sessions
and a bazel build. Refreshes are incremental and take about a second an hour.

That is a real amount of disk, and this was learned the uncomfortable way:
during the build, free space on the host fell from 60 GB to 16 GB. Only ~11 GB
of that was the index (a concurrent bazel cache took the rest), but the margin
was thin enough to matter. So `--index`:

- estimates the space it needs from a bounded sample and refuses to start if it
  will not fit (the first version of this precheck used
  `SUM(length(data))`, which is itself the multi-minute full scan this package
  exists to avoid — it timed itself out);
- aborts with a readable message if free space falls below 5 GB mid-build,
  leaving a smaller but perfectly usable index;
- commits every 10,000 rows with `journal_size_limit` set, because FTS5 segment
  merges amplify a transaction far past the bytes inserted into it — at 50,000
  rows per commit the WAL was observed at 3.0 GB, and SQLite's default leaves
  the WAL at its high-water mark forever.

### 2. A stale index costs time, never truth

The index stores a **watermark**: the highest `part.rowid` it has seen.
Every search unions the index result with a direct scan of everything above
the watermark. That tail scan is bounded by rowid, and `part.rowid` is
monotonic in `time_created` (spot-checked every 100,000 rows across five
months), so it is a short walk at the end of the table rather than a scan.

Consequences worth stating plainly:

- An index that is a week behind returns the same rows as a fresh one. It just
  takes longer.
- An interrupted build leaves a smaller index, not a broken one: the watermark
  is committed in the same transaction as the rows it describes.
- The watermark row's identity is re-checked against the live database on
  every run. SQLite only ever recycles a rowid at the *top* of the table, so
  any deletion that could shadow indexed content necessarily disturbs the
  watermark row — and that invalidates the index loudly instead of silently
  losing matches.
- Sessions deleted from `opencode.db` disappear from results regardless of
  what the index still holds, because results are joined back to the live
  `session` table.

A user timer (`oc-search-index.timer`, hourly, `Nice=19`,
`IOSchedulingClass=idle`) keeps the tail short. It is an optimisation, not a
correctness requirement, and it runs `--index --if-exists`: it refreshes an
index somebody opted into and never creates one. Deciding to spend 11 GB is a
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

There is a remaining gap that this package cannot close: lgtm swallows the
failure and returns `""`. A packet built without session history is still
indistinguishable from one where the search legitimately found nothing. That
belongs in the lgtm repo, not here.

## Tests

    python3 pkgs/oc-search/test_oc_search.py

Run in CI as `checks.oc-search` in `flake.nix` (a `checks.*` entry, not a
`checkPhase` — see `users/dev/test-unwired-tests.sh` for why that distinction
is enforced).
