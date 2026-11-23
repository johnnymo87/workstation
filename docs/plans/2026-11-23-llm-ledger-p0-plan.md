# llm-ledger (phase 0) implementation plan

Bead: `workstation-4si2.1`. Design: `docs/plans/2026-11-23-llm-spend-metrics-design.md`
(its "Facts" and "Implementation constraints" sections are binding; where its
architecture sketch says "WAL", the constraints section wins: **DELETE**).

## Goal

A 5-minute timer on cloudbox that keeps `/var/lib/llm-ledger/ledger.db` (SQLite)
up to date from cfp's `events.jsonl` and the teamclaude canary's quota samples,
with a session→program snapshot and an hourly rollup, plus a raw gz archive of
every cfp line it reads. Grafana (phase 2) and quota-watch (phase 1) only read it.

## Data sources (verified on cloudbox 2026-11-23)

- `/var/lib/claude-failover-proxy/events.jsonl` (dev-owned, ~130 MB, 30 days).
  Types: `route`, `usage`, `keepwarm`, `boot`. `route` is written at request
  start and carries `requestId, ts, sessionId, model, desired, chosen, …`.
  `usage` is written at response end with the SAME `ts` as its route and carries
  `requestId, ts, durationMs, cost, usage{input,output,cacheRead,cacheWrite},
  status, backend` (and sometimes `headersMs`); it has no `model`. Up to ~360 s
  between a route line and its usage line. cfp trims daily by rewriting the file
  and `rename`-ing it (new inode; the trimmed file still holds every line younger
  than 30 days). Lines are appended whole, but a reader can see a partial last
  line.
- `/var/lib/teamclaude-pool-canary/quota-samples.jsonl` (root-owned 0644, read
  only) plus `archive/quota-samples-until-*.jsonl.gz`. One line per 5 min:
  `{"ts":"2026-11-22T22:00:00-05:00","healthy":6,"canary_healthy":5,
  "canary_serving":5,"roster":6,"current":"…","fwh":24,"accounts":[{"n":…,
  "s":"active","u5h":0,"u7d":0.99,"u7dF":0.05,"fw":false,"r7d":<ms>,
  "r5h":null},…]}`. Old lines lack some fields. The canary periodically moves
  all but the last 8640 lines into a new archive file (the live file is
  rewritten).
- Session metadata, read-only: opencode `~/.local/share/opencode/opencode.db`
  (`session(id, parent_id, directory, title)`), goose
  `~/.local/share/goose/sessions/sessions.db` (`sessions`, `usage_ledger`),
  tags `~/.local/share/oc-tags/tags.db`, lgtm ledger
  `~/.local/state/lgtm/goose-usage.jsonl`. All through `pkgs/oc-tags/oc_tags.py`
  helpers.
- Cost split by session shape over the live 30 days: `ses_*` $14.8k, goose-shaped
  (`YYYYMMDD_N`) $3.3k, unrouted $0.35.

## Schema (`ledger.db`)

`PRAGMA journal_mode=DELETE`, `PRAGMA busy_timeout=30000` on every writer
connection. All timestamps are INTEGER epoch **ms**.

```sql
CREATE TABLE route (            -- every cfp route line, kept
  request_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, session_id TEXT,
  model TEXT, desired TEXT, chosen TEXT);
CREATE TABLE requests (         -- one row per cfp usage line
  request_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, host TEXT NOT NULL,
  session_id TEXT,              -- raw cfp sessionId (NULL if no route seen)
  attr_key TEXT NOT NULL,       -- join key into session_program (see below)
  backend TEXT, model TEXT,
  input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
  cost_usd REAL, status INTEGER, duration_ms INTEGER);
CREATE INDEX requests_ts ON requests(ts, attr_key, backend, model, cost_usd);
CREATE INDEX requests_attr_ts ON requests(attr_key, ts);
CREATE TABLE session_program (
  attr_key TEXT PRIMARY KEY, tag TEXT NOT NULL,   -- raw effective tag
  source TEXT NOT NULL,                           -- 'manual' | 'auto'
  root TEXT, title TEXT, updated_at INTEGER NOT NULL);
CREATE INDEX session_program_tag ON session_program(tag, attr_key);
CREATE TABLE hourly (
  hour INTEGER NOT NULL,        -- epoch ms of the UTC hour start
  attr_key TEXT NOT NULL, backend TEXT NOT NULL, model TEXT NOT NULL,
  n INTEGER, input INTEGER, output INTEGER, cache_read INTEGER,
  cache_write INTEGER, cost_usd REAL,
  PRIMARY KEY (hour, attr_key, backend, model));
CREATE TABLE quota_pool (
  ts INTEGER PRIMARY KEY, healthy INTEGER, canary_healthy INTEGER,
  canary_serving INTEGER, roster INTEGER, current TEXT, fwh REAL);
CREATE TABLE quota_samples (
  ts INTEGER NOT NULL, account TEXT NOT NULL, s TEXT, u5h REAL, u7d REAL,
  u7d_fable REAL, fw INTEGER, r7d INTEGER, r5h INTEGER,
  PRIMARY KEY (ts, account));
CREATE TABLE ingest_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

`backend`/`model` in `hourly` use `''` for NULL so the primary key works.
`model` comes from the route; `backend` ALWAYS from the usage event.

### `attr_key` (what a request is attributed to)

- `ses_*` session id → the raw session id. The snapshot maps it to its root's tag,
  so reparenting and retagging both take effect without touching `requests`.
- goose-shaped id (`^\d{8}_\d+$`) → decided at ingest, because lgtm's private
  goose runs reuse goose-serve's id scheme (see `load_cfp_aggregate` in
  oc_tags.py):
  - an lgtm ledger row claims it (same rules as `load_cfp_aggregate`) → that lgtm
    root key (`lgtm-goose:…`);
  - otherwise, the id exists in goose-serve's sessions.db → `goose:<sid>`;
  - otherwise `cfp:goose-unknown`.
  Because lgtm backfills its ledger late, every run re-decides `attr_key` for
  goose-shaped requests with `ts` in the last `--goose-recheck-hours` (default
  72) and recomputes the hours whose rows changed.
- any other / missing session id → `cfp:unrouted`.

### `session_program` snapshot (every run, after ingest)

For every DISTINCT `attr_key` in `requests`: upsert a row, never delete one.
- `ses_*`: if the id exists in opencode.db: `root = root_of(id)`,
  `(tag, source) = effective_tag(root, directory(root), session_tags)`. If the id
  is absent from opencode.db: if a row already exists in `session_program`, leave it
  untouched (it was resolved while the session existed); if no row exists, attribute it
  exactly as `load_cfp_aggregate` does: `root = sid`, `(tag, source) = effective_tag(sid, None, session_tags)`,
  `title = None`.
- `goose:<sid>`: only if `sid` exists in sessions.db: root = `root_of` within
  goose; tag = tags.db's `goose:<root>` (manual) else `goose_auto_key(...)`
  (auto), exactly as `load_cfp_aggregate` does.
- `lgtm-goose:*`: tags.db override (manual) else `lgtm-runs` (manual).
- `cfp:*`: tag = the key itself, source `manual`.
Only rows whose `(tag, source, root, title)` changed are written.

## Commands (`llm-ledger`)

- `llm-ledger run` — takes an exclusive `fcntl` lock on `<db dir>/.lock`
  (non-blocking; exit 0 with a message if held), then in order:
  1. **cfp tail.** State in `ingest_state`: `cfp_inode`, `cfp_offset`,
     `cfp_archived_through_ts`. If the file's inode differs from the stored one
     or its size is below the stored offset, restart at offset 0 (the trimmed
     file still holds every unread line). Read from the offset up to the LAST
     `\n` only. Parse each line; route → `INSERT OR IGNORE INTO route`; usage →
     `INSERT OR IGNORE INTO requests` with session/model from the `route` table
     (or `NULL`/`cfp:unrouted` if absent). A route arriving for an existing
     request whose `session_id IS NULL` fills it in. Malformed lines are skipped
     and counted. The new offset and inode are committed in the SAME transaction
     as the rows.
  2. **raw archive.** The bytes consumed in step 1 are appended (as a new gzip
     member) to `<raw dir>/cfp-events-<UTC ingest date>.jsonl.gz` BEFORE the DB
     commit. After an inode restart, only lines with `ts >
     cfp_archived_through_ts - 600000` are archived again, so the daily trim
     doesn't duplicate the whole file into the archive (duplicates inside that
     10-minute overlap are harmless: every import is idempotent).
  3. **quota samples.** Import each `archive/*.jsonl.gz` not yet recorded in
     `ingest_state` (key `quota_archive:<basename>`), then the live file, skipping
     live lines whose `ts` is ≤ the newest `quota_pool.ts`. ISO `ts` → epoch ms.
     `INSERT OR IGNORE`. `fw` stored as 0/1/NULL.
  4. **goose recheck** (see `attr_key`).
  5. **hourly rollup** for every hour touched by new or changed requests:
     delete those hours, re-insert from `requests` grouped by
     `(hour, attr_key, backend, model)`.
  6. **session_program snapshot.**
  Prints a one-line summary (new routes, new requests, malformed, quota rows,
  rechecked, hours rebuilt, snapshot rows written, elapsed).
- `llm-ledger import-events FILE…` — same parsing for plain or `.gz` files
  (e.g. the 2026-11-23 snapshot, or a rebuild from the raw archive); never touches
  the tail state; also runs the rollup for touched hours and the snapshot. Copies
  nothing.
- Common options: `--db` (default `/var/lib/llm-ledger/ledger.db`), `--events`,
  `--raw-dir` (default `<db dir>/raw`), `--samples` / `--samples-archive`,
  `--opencode-db`, `--goose-db`, `--tags-db`, `--lgtm-ledger`, `--host`
  (default `socket.gethostname()`), `--goose-recheck-hours`.

## Tasks

### Task 1 — extract the cfp session resolver in oc_tags.py (refactor)

`load_cfp_aggregate` contains the goose/lgtm/opencode resolution as closures.
Extract it to a module-level class `CfpSessionResolver` (constructor takes the
opencode db path, goose db path, the session-tags map, lgtm ledger path, the
time window and the set of session ids; it loads exactly what the closures load
today) with:
- `goose_claim(sid, ts) -> tuple[str, str, str, str] | None`: the lgtm row
  `(root, tag, source, title)` that claims a goose-shaped request, or `None`
  (same `GOOSE_LEDGER_JOIN_MS` / `LGTM_JOIN_MS` rules);
- `in_goose_serve(sid) -> bool`;
- `resolve(sid, ts) -> (root, tag, source, title, directory)`, equal to today's
  behaviour.
`load_cfp_aggregate` uses it and its output is unchanged. All 301 existing tests
still pass; add tests for the three methods. Update the pinned test count in
`flake.nix` (`checks.oc-tags-tests`).

### Task 2 — `pkgs/llm-ledger`: schema, cfp ingest, tail, raw archive, import-events

New package `pkgs/llm-ledger/` with `llm_ledger.py` (imports `oc_tags`),
`test_llm_ledger.py` (stdlib `unittest`, run as
`python3 pkgs/llm-ledger/test_llm_ledger.py`; HOME redirected to a temp dir
before importing, as test_oc_tags.py does), `default.nix`. Implements the schema,
`attr_key` at ingest, the tail with inode/offset/partial-line handling, the raw
archive and `import-events`. Required tests include: route+usage join; backend
from usage when route `chosen` differs; usage without route → `cfp:unrouted`,
later route fills it; partial last line not consumed then consumed next run;
inode change → restart at 0 without duplicate rows and without re-archiving old
lines; truncation (size < offset); idempotent re-import; malformed lines counted;
journal_mode is `delete` and busy_timeout ≥ 30000; `.gz` import.

### Task 3 — quota samples import

Step 3 above. Tests: ISO with both `-04:00` and `-05:00` offsets; archives
imported once; live-file skip by newest ts; old lines missing fields; `null`
`u7d` kept as NULL; a rewritten live file (canary archive+trim) neither loses nor
duplicates rows.

### Task 4 — goose recheck, hourly rollup, session_program snapshot, `run`

Steps 4–6 and the lock. Tests: rollup sums match `requests` per hour after
incremental runs and after a goose re-attribution; snapshot maps a child
`ses_` to its root's tag, picks up a retag on the next run, keeps a row whose
session was deleted, resolves `goose:<sid>` through the goose root and tags.db,
lgtm keys default to `lgtm-runs`; a held lock exits 0 without writing.

### Task 5 — Nix: package, flake check, cloudbox module

- `flake.nix`: expose `llm-ledger` like `oc-tags`; add
  `checks.llm-ledger-tests` modelled on `checks.oc-tags-tests` (pinned count,
  tzdata).
- `pkgs/llm-ledger/default.nix`: install `llm_ledger.py` as `bin/llm-ledger`
  with `../oc-tags/oc_tags.py` beside it in the store so the import resolves.
- `hosts/cloudbox/llm-ledger.nix`, imported from `configuration.nix`:
  - `users.groups.llm-ledger = {}` (grafana joins it in phase 2).
  - tmpfiles: `d /var/lib/llm-ledger 2750 dev llm-ledger -` and
    `d /var/lib/llm-ledger/raw 2750 dev llm-ledger -` (setgid so new files
    inherit the group).
  - `systemd.services.llm-ledger`: oneshot, `User=dev`, `Group=dev`,
    `SupplementaryGroups=llm-ledger`, `UMask=0027`, `MemoryMax=1G`,
    `ExecStart=… llm-ledger run`. (Phase 1 will append quota-watch to the same
    unit, after the writer.)
  - `systemd.timers.llm-ledger`: `OnCalendar=*:2/5` (two minutes after the
    canary's `*:0/5`), `Persistent=true`.
  - On failure: alert through `opencode-drift-alert` the way the other cloudbox
    canaries do (OnFailure unit), so a broken ledger doesn't go silent.

### After merge (controller)

Deploy. Run manual commands as dev (never sudo) via the store path
(`systemctl cat llm-ledger` shows it) or `nix run .#llm-ledger --`. Run
`import-events` only after the first timer run has created the DB (so it gets
0640):
`llm-ledger import-events ~/.local/state/llm-ledger/cfp-archive/events-snapshot-2026-11-23.jsonl.gz`.
Copy the snapshot into `raw/` as dev:
`cp ~/.local/state/llm-ledger/cfp-archive/events-snapshot-2026-11-23.jsonl.gz /var/lib/llm-ledger/raw/`.
Verify: request count ≈ usage lines; Σ cost by backend matches a direct parse of
events.jsonl; timer runs clean twice; the file permissions are `dev:llm-ledger 0640`.
