# Fleet LLM ledger — phase 1 implementation plan

> **For Claude:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (implementer → spec-reviewer → code-reviewer per task).

**Goal:** devbox and Mac usage rows land in cloudbox's ledger and Grafana by host; cloudbox publishes its quota outlook through `johnnymo87/quota-telemetry` branch `outlook`; devbox's `llm-ledger quota-outlook` reads it, so devbox coordinator wakes carry the same `quota@` line.

**Design:** `docs/plans/2026-11-23-fleet-llm-ledger-design.md` (approved by adversarial-reviewer-opus, 2 rounds). Bead epic `eng-agent-platform-ul4.26`. Phase 2 (fleet `k`, Mac cash rows) is separate beads, not this plan.

**Tech:** Python 3 stdlib (sqlite3, unittest), Nix (NixOS system units on cloudbox, home-manager user units on devbox), git over ssh (`~/.ssh/id_ed25519_github`, present on cloudbox and devbox).

**Worktree:** `~/projects/workstation/.worktrees/fleet-ledger`, branch `fleet-ledger`. Never edit `~/projects/workstation` itself.

**Tests:** `cd <worktree> && HOME=$(mktemp -d) python3 pkgs/llm-ledger/test_llm_ledger.py` and `... test_quota_watch.py` (unittest; summary on stderr). `flake.nix` pins the counts (`Ran 68 tests`, `Ran 69 tests`, around line 2003–2019) — update them in the same commit as added tests. Dashboard lint: `PYTHONPATH=pkgs/llm-ledger:pkgs/oc-tags python3 hosts/cloudbox/check_grafana_dashboards.py hosts/cloudbox/grafana-dashboards`. Full: `nix flake check --keep-going` (never `--no-build`).

**Rules:** commit bare (no `-c user.*`); no account emails in this public repo (tests use `a@example.com`-style fakes); no `git stash/reset/checkout` in shared trees.

---

### Task 1: remote rows schema, importer, view

**Files:** `pkgs/llm-ledger/llm_ledger.py`, `pkgs/llm-ledger/test_llm_ledger.py`, `flake.nix` (test count).

1. Add to `SCHEMA_SQL` (keep `IF NOT EXISTS`; touch no existing table):
   ```sql
   CREATE TABLE IF NOT EXISTS remote_hourly (
     host TEXT NOT NULL, hour INTEGER NOT NULL, account TEXT NOT NULL,
     backend TEXT NOT NULL, model TEXT NOT NULL,
     requests INTEGER, input INTEGER, output INTEGER, cache_read INTEGER,
     cache_write_5m INTEGER, cache_write_1h INTEGER, cost_usd REAL,
     PRIMARY KEY (host, hour, account, backend, model));
   CREATE TABLE IF NOT EXISTS remote_hosts (
     host TEXT PRIMARY KEY, first_hour INTEGER, exported_through INTEGER,
     imported_at INTEGER NOT NULL);
   ```
2. `REMOTE_PRICES` — exact-key dict, $/MTok, copied from claude-failover-proxy `src/price.ts` standard tier: opus-5-5 (4, 20, 0.2, 5.0), sonnet-5-5 (2, 10, 0.1, 2.5), haiku-5-5 (0.1, 0.5, 0.01, 0.125), opus-5 (5, 25, 0.5, 6.25), fable-5-1 (10, 50, 0.25, 12.5), fable-5 (10, 50, 1.0, 12.5). Comment: source file and date; hourly aggregates can't apply haiku's 100k long-context tier (understates haiku); fable-5-2 has no cfp rate → unpriced. `price_remote(model, input, output, cache_read, cw5m, cw1h) -> float | None`: strip `@…` suffix, exact lookup, 1h writes at 2× input rate; None if unknown.
3. `import_remote(db_path, repo_dir, local_host, now_ms=None, warnings=None) -> dict`:
   - Take `LedgerLock(db_path, blocking=True)` but bounded: add a `timeout_s` option to LedgerLock (poll `LOCK_NB` every 0.5 s up to timeout, then raise `TimeoutError`); importer uses 120 s.
   - For each subdir `<host>` of `repo_dir` (skip dotdirs and `host == local_host`), each `*.jsonl` named `YYYY-Www.jsonl`: blob id = `git -C repo_dir hash-object <file>` (or sha1 of `"blob %d\0" + bytes`, computed in Python — prefer Python, no subprocess); skip if equal to `ingest_state['remote_blob:<host>/<name>']`.
   - Otherwise in one transaction: `DELETE FROM remote_hourly WHERE host=? AND hour>=week_start AND hour<week_end` (ISO week Monday 00:00Z..+7d, epoch ms), then insert each valid row. Row → `hour` = parse `hour_utc` (`"2026-11-23T00:00Z"`) to epoch ms; `account` = `row.get("account") or ""`; `backend` = `row.get("backend") or "max"` (**literal 'max', never NULL**); ints default 0; `cost_usd` = row's `cost_usd` if numeric, else `price_remote(...)` for backend `max`, else None. Rows whose `host` field ≠ dir name, or unparseable hour, or outside the file's week → skipped, counted `malformed`. Duplicate PK within file → sum? No: `INSERT OR REPLACE` and count `dupes`. Store new blob id.
   - `<host>/_exported_through.json` `{"host":..,"hour_utc":..}` → `remote_hosts.exported_through` = hour_utc ms + 3600000; `first_hour` = `MIN(hour)` for host; `imported_at` = now. Upsert every run for each host dir.
   - Then `ensure_fleet_objects(conn, local_host)` (step 4). Return `{files, rows, malformed, unpriced, dupes, hosts}`; print `import-remote files=… rows=… malformed=… unpriced=…`. Malformed/unpriced are counts, not warnings (exit 0). Missing repo dir → exit 1 with message.
4. `ensure_fleet_objects(conn, local_host)`:
   - View SQL (host literal escaped with `''`):
     ```sql
     CREATE VIEW fleet_hourly AS
       SELECT hour, '<local_host>' AS host, attr_key, backend, model, n,
              input, output, cache_read, cache_write, cost_usd FROM hourly
       UNION ALL
       SELECT hour, host, 'fleet:' || host, backend, model, requests,
              input, output, cache_read, cache_write_5m + cache_write_1h, cost_usd
       FROM remote_hourly;
     ```
     Compare with `SELECT sql FROM sqlite_master WHERE type='view' AND name='fleet_hourly'`; `DROP VIEW IF EXISTS` + create only when different.
   - For each distinct host in `remote_hosts`: upsert `session_program(attr_key='fleet:<host>', tag='fleet:<host>', source='fleet', root=NULL, title='<host> (all usage)', updated_at=now)`.
   - Also call it from `run_ingest` after the snapshot step with the run's host, so a fresh DB has the view. Verify `step_session_program_snapshot` / `load_session_tags` do not delete or rewrite `source='fleet'` rows (read lines ~118–157, ~1133–1277); if they would, exclude `fleet:%` there and test it.
5. CLI: `import-remote --repo DIR [--db DEFAULT_DB] [--host gethostname()]`.
6. Tests (TestCase `TestImportRemote`, temp dirs, fake emails): first import inserts and prices opus row exactly (hand-computed); re-import unchanged file → 0 files; changed file replaces only that week; own-host dir skipped; missing backend → `'max'`; null account → `""`; unknown model → cost NULL + `unpriced=1`; row with `cost_usd` keeps it; malformed lines counted; watermark → `exported_through = hour+1h` ms; view returns local + remote rows with `fleet:<host>` attr and host; view not recreated when SQL unchanged (sqlite_master rowid stable); synthetic session_program row present and survives a snapshot run; lock timeout raises when another fd holds the lock.
7. Update flake count, run both suites, commit: `[NO-JIRA] llm-ledger: import quota-telemetry rows; fleet_hourly view`.

### Task 2: quota-outlook reads a published copy (`--from-json`)

**Files:** `pkgs/llm-ledger/{llm_ledger.py,quota_watch.py,test_llm_ledger.py,test_quota_watch.py}`, `flake.nix`.

Reuse closed draft #947: `git show 8339786a -- pkgs/llm-ledger/` (branch `origin/devbox-quota-outlook-remote`; take ONLY `pkgs/llm-ledger/*` hunks — not `users/dev/quota-outlook-remote.nix`, `home.nix`, its plan doc, or its flake.nix change beyond test counts). That gives `outlook_from_json`, `_outlook_from_row`, `_unknown_outlook`, the `--from-json` flag, `LLM_LEDGER_OUTLOOK_JSON`, and tests. Then add:
- Default resolution in `main`: no `--from-json`, no `--db`, no env, and `DEFAULT_DB` does not exist → `from_json = DEFAULT_OUTLOOK_JSON = ~/.local/state/llm-ledger/outlook.json` (expanduser at call time). DB present → unchanged DB path (cloudbox).
- Missing file → `unknown` with error `no published outlook at <path>`.
- Tests: resolution order (explicit --db wins over env; env wins over default; DB absent → default file; DB present → DB), missing file, fresh copy → same verdict and line as source, stale copy (>1200 s) → unknown, extra keys (`published_at`, `host_share_24h`) ignored.
Commit: `[NO-JIRA] llm-ledger quota-outlook: read a published outlook (from #947)`.

### Task 3: publish payload and fleet alerts

**Files:** `pkgs/llm-ledger/{llm_ledger.py,quota_watch.py,test_*.py}`, `flake.nix`.

1. `llm-ledger outlook-publish-json [--db] [--host]` prints one JSON object: `quota_watch.outlook(db)` plus `published_at` (now ms), `source_host`, and `fleet`: `{"<host>": {"share_24h": float|null, "exported_through": ms|null}}` for the local host and each `remote_hosts` host. Share = host's Max usage in opus-list-price token units (`oc_tags.opus_list_cost(input, output, cache_read, cache_write)` summed from `fleet_hourly WHERE backend='max'`) ÷ fleet total, window = 24 h ending at `W = min(now, min(exported_through of remote hosts))`. Nulls if total 0 or view missing. **No $ fields** (assert in test that no key contains `usd` and `vertex_usd` absent). Exit 0 always (errors → `{"verdict":"unknown",...}` like quota-outlook).
2. quota-watch `run_live` gains, with alert files in state dir:
   - `--alert-stale-hosts` (comma list, default `devbox`): for each, if `remote_hosts.exported_through` missing or `now − exported_through > 3 h` → alert `fleet-stale` (ttl 3600, max 14400) naming host and age, text says devbox export or GitHub key may be broken and the devbox verdict sync shares that key; clears when fresh. Missing `remote_hosts` table → treat as no rows (alert).
   - `--outlook-pushed-file PATH` (optional): file whose mtime is the last successful push; if given and missing or older than 15 min → alert `outlook-stale` ("devbox reads quota unknown after 20 min"). Clears when fresh.
   - Follow the existing blind-alert pattern at `quota_watch.py:736-790` (same alert_cmd argv and dry-run printing).
3. Tests for share (window ends at watermark; no $ keys), fleet-stale fire/clear, outlook-stale fire/clear/absent flag.
Commit: `[NO-JIRA] llm-ledger: outlook publish payload; fleet-stale and outlook-stale alerts`.

### Task 4: cloudbox units

**Files:** `hosts/cloudbox/llm-ledger.nix` (or new `hosts/cloudbox/llm-fleet.nix` imported from `configuration.nix`), flake check if one asserts unit shape.

- `StateDirectory`-style dir `/var/lib/llm-fleet` (tmpfiles `d /var/lib/llm-fleet 0700 dev dev -`), subdirs `telemetry` (clone of main) and `outlook` (publish repo).
- Common env: `HOME=/home/dev`, `PATH` = git, openssh, coreutils; `GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15"`. Remote `git@github.com:johnnymo87/quota-telemetry.git` (ssh config on cloudbox maps github.com to `~/.ssh/id_ed25519_github`).
- `llm-fleet-import.service` (oneshot, User=dev, Group=dev, SupplementaryGroups llm-ledger, UMask 0027, Nice 10, TimeoutStartSec 5min, MemoryMax 512M, OnFailure → `llm-fleet-import-failure` modelled on `llm-ledger-failure` with drift-alert backoff 3600/21600): script clones if absent (`git clone --quiet --single-branch --branch main`), else `timeout 90 git -C … fetch --quiet origin main && git -C … reset --quiet --hard origin/main` (this is a private automation clone, not a shared worktree), then `llm-ledger import-remote --repo /var/lib/llm-fleet/telemetry --host cloudbox`. Timer `OnCalendar=*:14/15`, `Persistent=true`.
- `llm-outlook-publish.service` (oneshot, User=dev): add to `llm-quota-watch` `unitConfig.OnSuccess = [ "llm-outlook-publish.service" ]`. Script: init `/var/lib/llm-fleet/outlook` once (`git init -q`, `git remote add origin …`); each run: `llm-ledger outlook-publish-json > outlook.json.tmp && mv`; `git checkout -q --orphan next` (or `git symbolic-ref HEAD refs/heads/next` + `git rm -rq --cached .` as needed), `git add outlook.json`, `git commit -q -m "outlook <published_at>"` (bare — identity from dev's git config; commit signing config applies, key is passphrase-less); up to 3 tries `timeout 30 git push -q -f origin HEAD:refs/heads/outlook` with `sleep 5` between; on success `touch /var/lib/llm-fleet/outlook-pushed`; delete the local branch history each run so the repo stays one commit (`git branch -D` old / `git reflog expire --expire=now --all && git gc --prune=now -q` daily is optional). Exit 0 even after 3 failed tries (alerting is by age, Task 3) but log loudly.
- quota-watch ExecStart adds `--outlook-pushed-file /var/lib/llm-fleet/outlook-pushed --alert-stale-hosts devbox`; add `/var/lib/llm-fleet` to nothing writable (it only stats the file; `ProtectHome` is fine since it's under /var/lib). Ensure `ReadOnlyPaths`/ProtectSystem=strict still lets it stat (it does).
- Do not change any other unit. Build: `nix build .#nixosConfigurations.cloudbox.config.system.build.toplevel`.
Commit: `[NO-JIRA] cloudbox: llm-fleet-import and llm-outlook-publish units`.

### Task 5: devbox reader

**Files:** `users/dev/home.devbox.nix` (or `users/dev/quota-telemetry.nix` devbox block), `flake.nix` if needed.

- `home.packages`: `(pkgs.callPackage ../../pkgs/llm-ledger { })` on devbox (check it builds for aarch64/x86 as devbox needs — `platforms.unix`).
- `systemd.user.services.llm-outlook-sync` (oneshot, Nice 10, TimeoutStartSec 90s, PATH git/openssh/coreutils/python3, same GIT_SSH_COMMAND): keep a clone at `%h/.local/state/llm-ledger/outlook-repo` (`git clone --quiet --depth 1 --branch outlook` if absent; else `timeout 60 git fetch --quiet --depth 1 origin outlook`); `git show FETCH_HEAD:outlook.json` (or `origin/outlook`) into a temp file; validate with `python3 -c` that it is a JSON object ≤ 65536 bytes; `mv` atomically to `%h/.local/state/llm-ledger/outlook.json`. Invalid → keep previous file, exit 1. Timer `OnCalendar=*:0/2`, `Persistent=true`, WantedBy timers.target.
- No OnFailure alert (cloudbox's `fleet-stale` covers the shared key; the reader goes `unknown` by age).
Commit: `[NO-JIRA] devbox: llm-ledger on PATH and llm-outlook-sync`.

### Task 6: Grafana fleet view

**Files:** `hosts/cloudbox/grafana-dashboards/llm-spend.json`, `llm-quota.json`, `hosts/cloudbox/check_grafana_dashboards.py`.

- Every `FROM hourly h` → `FROM fleet_hourly h`, in `queryText` AND `rawQueryText`; add `AND h.host IN (${host:sqlstring})`.
- Variables: `backend`, `model` queries → `fleet_hourly`; new `host` variable `SELECT DISTINCT host FROM fleet_hourly ORDER BY host`, multi, includeAll, default All (copy the `backend` variable's JSON shape).
- Cash: `h.backend IN ('vertex','enterprise')` → `h.backend <> 'max'` (agy shows); label "Cash $ (Vertex/agy/enterprise)". The stat panel's per-backend columns: keep Max and replace the Vertex/Enterprise pair with one `Cash $` column.
- "Top 25 sessions": add `AND h.attr_key NOT LIKE 'fleet:%'`.
- New panel "Spend by host": timeseries, `GROUP BY time, host`, Max notional and cash as separate queries (A: backend='max', B: backend<>'max').
- New panel "Max usage share by host (list-price token units)": bar/pie over range, `SUM(input*4+output*20+cache_read*0.2+cache_write*5)/1e6` grouped by host for backend='max' (opus list basis; title says so).
- `llm-quota.json`: stat "Fleet freshness" `SELECT host, (strftime('%s','now')*1000 - exported_through)/60000.0 AS minutes_behind FROM remote_hosts` (no time filter needed; ensure lint allows it — lint only requires filters for requests/hourly/quota_samples; extend that regex to `fleet_hourly` and `remote_hourly`).
- Lint: fixture DB comes from `llm_ledger.SCHEMA_SQL`; create the view in the fixture (`llm_ledger.ensure_fleet_objects(conn, 'cloudbox')`) and add a remote_hourly fixture row so queries execute against it.
Run lint; commit: `[NO-JIRA] Grafana: fleet_hourly by host; cash includes agy`.

### Task 7: PR, review, deploy, verify (lead, not implementer)

1. Full `nix flake check --keep-going`. Push; open **draft** PR (shepherding-pull-requests skill; adversarial-reviewer-opus on the diff); mark ready when green; Jonathan's standing auto-merge applies.
2. cloudbox after merge: pull root checkout (`git -C ~/projects/workstation pull --ff-only`), `sudo nixos-rebuild dry-activate --flake .#cloudbox` — proceed only if none of goose-serve, honkd, pigeon-daemon, claude-failover-proxy/cfp, teamclaude, opencode-serve@* would restart; then switch. Start `llm-fleet-import` once by hand; check `fleet_hourly` has devbox rows; wait for a publish; `git ls-remote … outlook`.
3. devbox: tell the eternal-machinery coordinator (gse_c82dc1cc-cd47-50fd-a5a2-7860b54abc20) in one line; `swarm_launch` machine devbox, dir workstation: pull, `home-manager build`, diff units, switch detached via `systemd-run --user`, start `llm-outlook-sync`, run `llm-ledger quota-outlook` and `./sw quota` in eng-agent-platform; report both lines.
4. Mac: diagnose why `mac/` never appeared (swarm_launch macbook if available: `launchctl print gui/$(id -u)/…quota-telemetry-export`, logs `~/Library/Logs/quota-telemetry-export.*.log`, whether home-switch has run since #939); else steps for Jonathan.
5. Close beads; update epic notes.
