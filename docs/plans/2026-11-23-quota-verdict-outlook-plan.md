# Quota verdict and outlook (QC1) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (implementer → spec-reviewer → code-reviewer per task) to implement this plan task-by-task.

**Goal:** quota-watch publishes one verdict per run (`ample|tight|dry`). `llm-ledger quota-outlook` prints it as a JSON contract for stall-watch and agent-wait, and the Max Quota dashboard shows it as a band.

**Bead:** `eng-agent-platform-ul4.24.1`. It lives in the eng-agent-platform beads DB; run `bd` from `~/projects/eng-agent-platform`.

**Design:** `docs/plans/2026-11-23-quota-aware-coordinators-design.md` in eng-agent-platform, §1 and §Verification. Merged in eng-agent-platform #477. **The JSON contract in §1 is an interface other workers code against. Do not change field names or semantics.**

**Architecture:** The verdict is derived from the alert state that `step_alerts` already keeps: `pool_dry` maps to `dry`, `shortfall` maps to `tight`, and anything else is `ample`. There are no new thresholds and no new hysteresis. It is stored in the new `quota_watch_runs.verdict` column, which live runs and `quota-replay --record` both write; replay also backfills NULLs. `quota-outlook` reads the newest live row read-only and prints the contract. `llm-ledger` goes on dev's PATH through home-manager.

**Tech stack:** Python 3 stdlib (sqlite3, argparse, json, zoneinfo), unittest (the `llm-ledger-tests` flake check), Nix, and Grafana JSON (the `cloudbox-grafana-dashboards` check).

**Test commands** (from the worktree root):
- `cd pkgs/llm-ledger && python3 -m unittest test_quota_watch test_llm_ledger -v`
  - If the `oc_tags` import fails outside nix, use `nix build .#checks.aarch64-linux.llm-ledger-tests`.
- `nix build --no-link .#checks.aarch64-linux.llm-ledger-tests .#checks.aarch64-linux.cloudbox-grafana-dashboards`

---

### Task 1: Store the verdict (live and replay, with migration and backfill)

**Files:**
- Modify: `pkgs/llm-ledger/llm_ledger.py:35-46`, the `QUOTA_WATCH_SCHEMA_SQL` DDL. Add `verdict TEXT` after `source`.
- Modify: `pkgs/llm-ledger/quota_watch.py`:
  - a new `verdict_from_state(state) -> str`;
  - a new `ensure_verdict_column(conn)`;
  - `record_run` (559-620);
  - `record_replay_runs` (623-661);
  - `run_live` (~839-856);
  - `replay` (~930-1011).
- Test: `pkgs/llm-ledger/test_quota_watch.py`.

**What to build:**
1. **`verdict_from_state`:**
   ```python
   def verdict_from_state(state: dict) -> str:
       if state.get("pool_dry"): return "dry"
       if state.get("shortfall"): return "tight"
       return "ample"
   ```
   It takes the NEW state that `step_alerts` returns.
2. **`ensure_verdict_column(conn)`:** if `verdict` is not in `pragma table_info(quota_watch_runs)`, run `ALTER TABLE quota_watch_runs ADD COLUMN verdict TEXT`. Call it after the schema statements run, in both `record_run` and `record_replay_runs`. This is needed because `CREATE TABLE IF NOT EXISTS` never adds the column to the deployed DB.
3. **`record_run`:** accept `row["verdict"]`, which may be missing and then becomes None, and include it in the `INSERT OR REPLACE` column list. In `run_live`, set `run_row["verdict"] = verdict_from_state(new_state)`.
4. **Replay:**
   - Each replay row must carry the verdict that comes **after** `step_alerts` at that T. Today the row is appended *before* `step_alerts` (line ~930), so move the append after `new_alert_state` is computed, or patch the last element in afterwards.
   - The row tuple gains a 15th element, the verdict.
5. **`record_replay_runs`:**
   - Keep `INSERT OR IGNORE`, so live rows are never overwritten.
   - Then fill missing verdicts:
     `UPDATE quota_watch_runs SET verdict=? WHERE ts=? AND verdict IS NULL`.
   - This applies to **any source**. A NULL live row is filled by the replay value, which is acceptable: the replay recomputes it from the same inputs.
   - Print `recorded N rows, filled V verdicts`.
6. **Episode report.** With `--record`, or always, replay prints one summary line per `tight` and `dry` episode: start, end, duration, peak `vertex_usd` (the forecast), and actual spillover in the episode window plus 24 h. Actual spillover is the sum of cost over `requests JOIN route` where `route.desired='max' AND requests.backend='vertex'` and `requests.host=?`; reuse the spillover query `load_inputs` already uses.

**TDD steps:**
- Failing tests first:
  - `verdict_from_state` on all four combinations of `pool_dry` and `shortfall`; when both are set, the result is `dry`.
  - `ensure_verdict_column` on an old-schema DB adds the column and is idempotent.
  - `record_run` writes the verdict.
  - On a DB holding a live row with a NULL verdict plus no replay rows, `record_replay_runs` inserts the replay rows, fills the NULL, and does not overwrite a live row that already has a verdict.
  - A replay over synthetic inputs where the shortfall fires and clears records `tight` exactly for the fired span.
  - An episode-report test using synthetic spillover.
- Run them and watch them fail. Implement. Run and watch them pass. Commit:
  `[NO-JIRA] quota-watch: store a verdict per run (ample/tight/dry) with migration and backfill`

### Task 2: `llm-ledger quota-outlook`

**Files:**
- Modify: `pkgs/llm-ledger/llm_ledger.py`: a new subparser in `main` (~1557-1604) that dispatches to `quota_watch.outlook`.
- Modify: `pkgs/llm-ledger/quota_watch.py`: a new `outlook(db, now_ms=None) -> dict` and `format_line(d) -> str`.
- Test: `pkgs/llm-ledger/test_quota_watch.py` and `test_llm_ledger.py` (CLI).

**Contract (design §1, exact):** print one JSON object to stdout and always exit 0. The keys are `verdict, ts, age_s, h0, burn_h, zero_h, next_refill_ts, next_refill_amt, line`, plus `error` on failure. There is no `vertex_usd` key; leave dollars out of the line and out of the object.

**Behaviour:**
- **Opening the DB.** Use `sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)`, then `PRAGMA busy_timeout=5000`. On `sqlite3.OperationalError` whose message contains `readonly` or `rollback` (a hot journal: SQLITE_READONLY_ROLLBACK), sleep 1 s and retry once.
- **The query.** `SELECT ts,h0,burn_h,zero_h,next_refill_ts,next_refill_amt,verdict FROM quota_watch_runs WHERE source='live' ORDER BY ts DESC LIMIT 1`.
  - Guard a missing `verdict` column by catching the error and returning `unknown` with an `error`.
- **When the verdict is `unknown`:**
  - there is no row;
  - the verdict is NULL;
  - `age_s = (now_ms - ts)//1000` is over 1200;
  - any exception, which also sets `error=str(e)[:200]`.
- **When it is unknown, the numbers** are whatever was read, or null.
- **`line`.** Always at most 200 bytes. Format the time as `HH:MM` in America/New_York, taken from `ts`, or from now if there is no ts. Templates:
  - ample: `quota@{HH:MM}: AMPLE · headroom {h0:.2f} acct-wk · next refill {Ddd HH:MM} ET (+{amt:.2f})`; leave out the refill clause if there is none.
  - tight or dry: `quota@{HH:MM}: TIGHT — Max forecast dry ~{zero_h:.1f}h in next 24h (forecast over-predicts) · headroom {h0:.2f} acct-wk · next refill {Ddd HH:MM} ET (+{amt:.2f})`. Use `DRY` for dry.
  - unknown: `quota@{HH:MM}: unknown (outlook unavailable)`.
- **The binary.** `llm-ledger quota-outlook [--db PATH]`, with the default `DEFAULT_DB`. Do not add `--host`; it isn't needed.

**TDD:** cover each branch:
- fresh ample, tight and dry;
- stale;
- NULL verdict;
- no rows;
- a missing column;
- a nonexistent DB path, which gives `unknown`, an `error`, and exit 0;
- a replay-only DB, which gives `unknown`, because only `source='live'` counts;
- `line` ≤ 200 bytes over extreme values;
- the CLI prints valid JSON with exactly the contract keys.

Commit: `[NO-JIRA] llm-ledger: quota-outlook JSON contract for coordinators`

### Task 3: PATH and the dashboard band

**Files:**
- Modify: `users/dev/home.cloudbox.nix`: add `(pkgs.callPackage ../../pkgs/llm-ledger { })` to `home.packages` (~line 362), with a comment explaining why it is there (quota-outlook for stall-watch, agent-wait and coordinators) and why it is NOT in systemPackages (that would restart teamclaude.service).
  - Check that it builds as a home-manager package (`nix build .#homeConfigurations.cloudbox.activationPackage`) and that `bin/llm-ledger` exists in it.
- Modify: `hosts/cloudbox/grafana-dashboards/llm-quota.json`: add a `state-timeline` panel titled "Coordinator quota verdict", placed right after the status row.
  - Query: `SELECT ts/1000 AS time, CASE verdict WHEN 'ample' THEN 0 WHEN 'tight' THEN 1 WHEN 'dry' THEN 2 END AS "Verdict" FROM quota_watch_runs WHERE ts >= $__from AND ts < $__to AND verdict IS NOT NULL ORDER BY ts`. Match the time-column conventions of the existing panels in this file: `timeColumns: ["time"]`, time in seconds, and the same `queryType` as the other time series.
  - Value mappings: 0 → ample (green), 1 → tight (orange), 2 → dry (red).
  - Keep `editable: false`. No account literals and no `@`.
- Modify: `hosts/cloudbox/check_grafana_dashboards.py` only if the new panel type or the new `verdict` column needs it:
  - the fixture DB is built from the ledger schema, so the column comes from Task 1's DDL;
  - if the lint has a panel-type allowlist, add `state-timeline`.

**Verify:** `nix build --no-link .#checks.aarch64-linux.cloudbox-grafana-dashboards` passes. Commit:
`[NO-JIRA] quota verdict: llm-ledger on dev's PATH, verdict band on the Max Quota dashboard`

### Task 4: Whole-branch verification (lead, not a subagent)

1. `nix build --no-link` of:
   - `.#checks.aarch64-linux.{llm-ledger-tests,cloudbox-grafana-dashboards,cloudbox-grafana-exposure}`;
   - `.#nixosConfigurations.cloudbox.config.system.build.toplevel`;
   - `.#homeConfigurations.cloudbox.activationPackage`.
2. Dry replay against a **copy** of the live ledger:
   `cp /var/lib/llm-ledger/ledger.db /tmp/opencode/l.db`, then `python3 -c` the replay with `record=True` against the copy.
   - Expect 3 tight episodes: 11-18 ~8.3 h, 11-19 ~7.9 h, 11-21 ~19.1 h.
   - Expect dry on about 1% of runs.
   - Every row gets a verdict.
   - The episode report prints.
   - `quota-outlook --db /tmp/opencode/l.db` returns `unknown` (the copy is stale) and has exactly the contract keys.
3. adversarial-reviewer-opus on `origin/main...HEAD`, given the design and this plan. Then the PR, shepherding, and a squash merge under the standing green light.
4. Deploy:
   - `git pull --ff-only` at `~/projects/workstation`;
   - `sudo nixos-rebuild dry-activate --flake .#cloudbox`, then `switch`, reporting unit restarts; teamclaude must NOT restart;
   - `nix run home-manager -- switch --flake .#cloudbox`.
5. Live checks:
   - Run the next live quota-watch (`sudo systemctl start llm-ledger`) and confirm it writes a verdict.
   - Run the real backfill: `llm-ledger quota-replay --since 2026-10-25 --record`.
   - `llm-ledger quota-outlook` from dev's PATH returns a fresh verdict.
   - The dashboard band query returns rows through `/api/ds/query`.
6. Close `eng-agent-platform-ul4.24.1` with a verdict-style reason, reconcile the epic prose with `bd note`, and run `bd dolt push`. Remove the worktree only after the merge.
