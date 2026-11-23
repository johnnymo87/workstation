# P3: Grafana dashboards over the LLM ledger (workstation-4si2.4)

Design: `docs/plans/2026-11-23-llm-spend-metrics-design.md` (phase 3). P2 built
Grafana and the read-only datasource uid `llm-ledger` (`hosts/cloudbox/grafana.nix`).

## Goal

Two provisioned, non-editable dashboards:

1. **LLM spend** (uid `llm-spend`): spend by program over time with Max
   notional and cash (Vertex + Enterprise) kept apart, drill-down to model, sub
   and session, top sessions.
2. **Max quota** (uid `llm-quota`): pool headroom against burn, with
   quota-watch's 24 h forecast drawn forward in time, per-account `u7d`, and
   Max→Vertex spillover cash.

## Facts verified before writing this (2026-11-23, live)

- **Schema is not the design's sketch.** `requests` and `hourly` key sessions
  by `attr_key` (not `session_id`). `session_program(attr_key PK, tag, source,
  root, title, updated_at)` stores the **raw tag**. Every `hourly.attr_key` has
  a `session_program` row today (0 orphans), but queries still `LEFT JOIN` and
  `COALESCE(...,'unresolved')`.
- **program/sub from the raw tag.** Manual tags have no `/` (`lgtm`,
  `stall-watcher-runs`). Auto tags look like `auto:mono` or
  `auto:mono/chi1-lasership-flag-gap`. So:
  - `program = COALESCE(CASE WHEN instr(tag,'/')>0 THEN substr(tag,1,instr(tag,'/')-1) ELSE tag END,'unresolved')`
  - `sub = CASE WHEN instr(tag,'/')>0 THEN substr(tag,instr(tag,'/')+1) ELSE '' END`
- **`hourly` has every dimension a dashboard needs except host**
  (`hour, attr_key, backend, model, n, tokens, cost_usd`, 12k rows). All
  panels read `hourly`, so a 365-day range is cheap. Only cloudbox rows exist;
  phase 5 brings other hosts, so the host variable is **deferred to P5**.
- **frser 3.8.2 macros.** The backend substitutes only `$__from`/`$__to`
  (ms). `$__interval_ms` and template variables are substituted by the
  Grafana **frontend**: in dashboards they work; a raw `/api/ds/query` call
  must substitute them itself (verified: "missing named argument
  __interval_ms"). Numeric time columns are read as **seconds** and must be
  listed in `timeColumns`. `queryType: "time series"` does long→wide by the
  string columns (verified: `backend` became a label, one frame per value).
- **cfp backends:** `max` (notional), `vertex` and `enterprise` (cash;
  enterprise idle since 2026-11-09). All `status` are 200.
- **Forecast is Python-only.** quota-watch computes `H0`, `B`, `k`, `zero_h`,
  `vertex_usd`, `next_refill` each run (`quota_watch.py:run_live`) but persists
  only alert state. The high-water accumulator and carry-forward cannot be
  reproduced in SQL, so quota-watch must write its numbers to the ledger.
- **jmohrbacher is excluded automatically** (all-null `u7d`, `PoolTracker`),
  so H0 needs no account names.
- **SVG oracle.** `oc-tags report --days 7 --backend max` reads cfp events only
  and resolves tags the same way. On 2026-11-23 its 7-day max total was
  $5,604.67, equal to the ledger's to the cent; vertex differed by $4.50, the
  spend since the ledger's last 5-minute run. The all-source report (no
  `--backend`) read $8,318.56 against the ledger's $6,761 of cfp, because it
  also prices non-cfp sources.

## Tasks

### T1. quota-watch records its numbers (pkgs/llm-ledger)

1. `llm_ledger.SCHEMA_SQL` gains:
   ```sql
   CREATE TABLE IF NOT EXISTS quota_watch_runs (
     ts INTEGER PRIMARY KEY,          -- T, the quota_samples tick evaluated
     h0 REAL NOT NULL, burn_h REAL NOT NULL,
     burn_6h REAL, burn_24h REAL, spill_6h REAL, spill_24h REAL,
     k REAL, zero_h REAL NOT NULL, vertex_usd REAL,
     next_refill_ts INTEGER, next_refill_amt REAL,
     pool_n INTEGER NOT NULL, source TEXT NOT NULL);   -- 'live' | 'replay'
   CREATE TABLE IF NOT EXISTS quota_forecast (
     ts INTEGER PRIMARY KEY, headroom REAL NOT NULL, run_ts INTEGER NOT NULL);
   ```
   `quota_forecast` holds only the latest live run's path.
2. `forecast()` takes an optional `path: list | None = None`; when given it
   appends `(t, h)` for T and every 5-min step. Return value unchanged.
3. `run_live`, after alerts are processed and before the summary line, calls a
   new `record_run(db, row, path)`:
   - opens the DB read-write (`timeout=30`), runs the two `CREATE TABLE IF NOT
     EXISTS`, `INSERT OR REPLACE` the run row (`source='live'`), `DELETE FROM
     quota_forecast` and inserts the path, all in one transaction;
   - is **best-effort**: `sqlite3.Error`/`OSError` prints
     `quota-watch: could not record run: …` to stderr and the run still exits
     0. Alerting must never depend on the dashboard write.
4. `quota-replay --record`: after replay, `INSERT OR IGNORE` one row per tick
   (`source='replay'`, no path) in one transaction, so live rows win. Used
   once after deploy to backfill from 2026-10-25 (first date with `r7d`).
5. Unit: `llm-quota-watch` gets `/var/lib/llm-ledger` in `ReadWritePaths`
   (dev owns the dir and the file; DELETE journal needs the dir writable).
   The ordering (llm-ledger → OnSuccess → quota-watch) means the two writers
   never overlap on the timer.
6. Tests (update the `Ran N tests` gate in `flake.nix`): path length and
   values; `record_run` writes both tables and replaces the path; a
   read-only/locked DB makes `record_run` warn and `run_live` still return 0;
   `--record` does not overwrite a `live` row.

### T2. Dashboards, provisioning and the guard

Files: `hosts/cloudbox/grafana-dashboards/{llm-spend,llm-quota}.json` (JSON
only: the provider reads this directory), `hosts/cloudbox/check_grafana_dashboards.py`,
edits to `hosts/cloudbox/grafana.nix` and `flake.nix`.

**frser target shape** (from its `module.js`): the frontend sets
`queryText = templateSrv.replace(rawQueryText)`, so every target carries
`rawQueryText` (the source of truth; `queryText` identical), `queryType`
(`"table"` | `"time series"`), `timeColumns` (list), `refId`, `datasource`.
A query variable's `query` is a plain SQL string; one column gives the values
(or two named `__text`/`__value`). Grafana 12 still polyfills
`Array.prototype.toArray`, which frser's `metricFindQuery` uses.

**Provisioning** (`services.grafana.provision.dashboards.settings.providers`):
one file provider, `options.path` = the dashboards dir in the store,
`allowUiUpdates = false`, `disableDeletion = true`, folder `LLM`. Every
dashboard JSON has `"editable": false`, a fixed `uid`, and every target's
datasource is `{"type":"frser-sqlite-datasource","uid":"llm-ledger"}`.

**Conventions for every query**

- Read `hourly` aliased `h`, joined `LEFT JOIN session_program sp ON
  sp.attr_key = h.attr_key`.
- Filter `h.hour >= $__from AND h.hour < $__to` (the first partial hour of the
  range is dropped; say so in panel descriptions where it matters).
- Time series: `(h.hour/$__interval_ms)*$__interval_ms/1000 AS time`,
  `timeColumns: ["time"]`, `queryType: "time series"`, panel `interval: "1h"`
  (min interval) so a bucket is never smaller than the rollup.
- Variable filters: `h.backend IN (${backend:sqlstring})`,
  `h.model IN (${model:sqlstring})`, `<program expr> IN (${program:sqlstring})`.
- **Max and cash are never added.** A query returns either `backend='max'`
  ("Max $, notional") or `backend IN ('vertex','enterprise')` ("cash $"), or
  keeps them in separate columns/series named so. No panel title or unit
  says "spent" over both.
- No account name appears in any JSON. quota-sample account names come from
  the data (series labels), never from literals.

**Variables (llm-spend):** `backend`, `model` (DISTINCT over `hourly`),
`program` (DISTINCT program expr over `session_program`, plus
`'unresolved'`), all multi-value with All.

**llm-spend panels**

1. Stats for the range: Max $ (notional), Vertex $ (cash), Enterprise $
   (cash), requests.
2. Time series, stacked: **cash $ per program**.
3. Time series, stacked: **Max notional $ per program**.
4. Table by program: `program, max_usd, cash_usd, requests`, sorted by
   `cash_usd + max_usd` for ordering only (the sum is not displayed); data link
   sets `var-program`.
5. Table by program/sub (sub = the `auto:` slug).
6. Table by model: `model, backend, requests, input, output, cache_read,
   cache_write, usd`.
7. Top 25 sessions: `attr_key, title, program, max_usd, cash_usd, requests,
   first, last`.

**llm-quota panels** (default range `now-7d` → `now+1d`, so the forecast is
visible)

1. Stats from the newest `quota_watch_runs` row: headroom (account-weeks),
   burn/h, dry hours in the next 24 h, forecast Vertex $, k(local), next
   refill (time and amount), age of the row (stale > 15 min goes red).
2. Time series: `h0` (bucket avg) and the `quota_forecast` path as a second,
   dashed series.
3. Time series: `burn_h` and `zero_h`.
4. Time series: per-account `u7d` from `quota_samples` (non-null only), with a
   threshold line at 0.98 (where teamclaude stops) and 0.90 (warning).
5. Time series: Max→Vertex spillover cash per hour (`requests JOIN route` on
   `request_id`, `desired='max' AND backend='vertex'`) — the cash a dry pool
   costs. Reads `requests`, bounded by `$__from/$__to`.

**Guard `cloudbox-grafana-dashboards`** (flake check, runs
`check_dashboards.py` in a runCommand):

- Lint: JSON parses; uids unique; `editable == false`; every target uses
  datasource uid `llm-ledger`; no `@` anywhere; no SQL literal comparison on an
  account column (`account\s*(=|IN|LIKE)`); every query that reads `requests`,
  `hourly` or `quota_samples` contains both `$__from` and `$__to` (variable
  queries exempt).
- Execute: build an in-memory DB from `llm_ledger.SCHEMA_SQL` (which includes
  the T1 tables) with a few fixture rows, substitute `$__from`, `$__to`,
  `$__interval_ms` and every variable (All → the fixture's values,
  `sqlstring`-quoted), and run every panel and variable query. Any SQLite
  error fails the check.
- The provisioning: the provider in the rendered config points at the store
  path holding these files and has `allowUiUpdates = false`.

## Verification after deploy

1. `systemctl start llm-ledger` (quota-watch follows); `quota_watch_runs`
   gains a `live` row and `quota_forecast` 289 rows. Then
   `llm-ledger quota-replay --since 2026-10-25 --record` as dev.
2. Every panel query through `/api/ds/query`, with `$__interval_ms` and
   variables substituted, for 7, 30 and 365 days: status 200, each under 2 s
   (a reader must stay far from the writer's 30 s busy timeout). The ledger holds
   ~31 days so the 365-day timing is not yet meaningful; record spillover (the
   one query on `requests`) as a P5 scaling risk with its current timing.
3. **Agreement, gap defined in advance.** Immediately after an llm-ledger run,
   compare per tag by rebuilding the tag as
   `program || CASE WHEN sub<>'' THEN '/'||sub ELSE '' END` from the
   program/sub query over oc-tags' exact window (ET midnight 7 days ago .. now,
   see calculate_window in pkgs/oc-tags/oc_tags.py) with
   `oc-tags report --days 7 --backend max` and `--backend vertex`:
   - per-backend totals within max($1, 0.5%);
   - per-tag within max($1, 1%); a larger difference must be explained by
     a retag between snapshot and report, or it is a bug;
   - the all-source report is **expected to exceed** the ledger's cfp total
     (non-cfp sources); it is recorded, not tested.
4. `/api/dashboards/uid/llm-spend` and `llm-quota` return `meta.provisioned == true`;
   anonymous requests still 401.

## Decisions

- **Program vs sub**: `program = tag` before the first `'/'`, because `'/'` separates the `auto:` slug.
- **Tag folding**: oc-tags' `':'` fold is a rendering option and is not applied.
- **Spillover host filtering**: spillover is not host-filtered yet (P5 decides).

## Out of scope

Host variable (P5), program/session alerts (P4), per-account attribution of
requests (P6), replacing the SVG charts.
