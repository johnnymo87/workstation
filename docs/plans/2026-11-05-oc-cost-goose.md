# oc-cost: count goose sessions alongside opencode

Bead: `eng-agent-platform-c87c.3` (epic `eng-agent-platform-c87c`, oc-* tools goose-friendly).

## Goal

`oc-cost` reads only `opencode.db`. Goose spend (cloudbox runs goose on
`gcp_vertex_ai` Claude every day) is invisible to it. After this change every
section of the report (daily, per-model estimate, reconciliation, size buckets,
`--by-kind`) includes goose LLM calls from goose's `usage_ledger`, labelled so
they are never confused with opencode rows.

## Measured (cloudbox, 2026-11-05)

- `~/.local/share/goose/sessions/sessions.db`, table `usage_ledger`: one row per
  LLM call. Columns: `session_id, created_timestamp` (unix **seconds**), `model,
  input_tokens, output_tokens, total_tokens, cache_read_tokens,
  cache_write_tokens, cost, cost_source, is_compaction`. No provider column; the
  provider is `sessions.provider_name` of the row's session. 0 orphan rows.
- `input_tokens` INCLUDES cache read and write (0 rows have input < read+write).
  Uncached input = `input - cache_read - cache_write`. Same semantics session-tags
  uses (`pkgs/oc-tags/oc_tags.py` `compute_goose_cost`).
- No reasoning split (`total = input + output` on 17258/17344 rows).
- Providers seen: `gcp_vertex_ai` (claude-sonnet-4-6, claude-opus-5-5,
  claude-haiku-5-5, gemini-3.5-flash), `anthropic` (claude-opus-5-5), plus
  `mock-*` providers from goose test runs that leaked into the real DB
  (2026-10-16..20, all `session_type='hidden'`, null cost, real token counts).
- `cost` is goose's own estimate (`cost_source='estimated'`) and is NULL on 2109
  opus-5-5 rows from 2026-09-25..10-09 (goose had no price yet). Where present it
  matches oc-cost's rate book: 6561 recent opus-5-5 rows, goose $704.42, oc-cost
  rates $704.4.
- `sessions.accumulated_cost` is NOT used (null on most sessions; bead note).

## Design

Pricing follows oc-cost's existing model, not session-tags': **estimate from
oc-cost's own `RATES` is the headline, goose's ledger `cost` is the "recorded"
figure** shown in reconciliation. session-tags' goose rate table says its own
source of truth is oc-cost's `RATES`, so reusing session-tags' pricing would
invert that. What is reused from session-tags is the ledger reader's semantics
(table, timestamp unit, cache-inclusive input, provider via `sessions`,
read-only connection, warn-and-continue on a goose read failure).

1. **Reader.** `query_goose_rows(goose_db_path, start_ms, end_ms) -> (rows,
   kind_map)`. Read-only (`mode=ro`, `busy_timeout`), one transaction.
   `usage_ledger LEFT JOIN sessions`, `created_timestamp*1000 BETWEEN start_ms
   AND end_ms` (same inclusive bounds as `_BASE_WHERE`). Each row is shaped like
   `query_message_rows` output:
   - `session_id = "goose:" + id`
   - `provider = "goose:" + (provider_name or "unknown")` — display and grouping
     key; never collides with an opencode provider.
   - `rate_provider` = rate-book provider (see 2), or None.
   - `model` = ledger model (None stays None).
   - `day` = UTC date of the timestamp (matches opencode's `date(...,'unixepoch')`).
   - `input` = max(0, input - cache_read - cache_write); `cache_read`,
     `cache_write`, `output` (nulls -> 0); `reasoning = 0`.
   - `recorded_cost` = ledger cost or 0.0; `recorded_missing` = cost IS NULL.
   - `backend = "goose"`.
   `kind_map`: `"goose:"+id -> "subagent" if parent_session_id else "primary"`.
   All ledger rows in the window are included, mocks too: an unknown provider is
   unpriced, which oc-cost already surfaces loudly instead of counting as $0.
2. **Provider mapping** `goose_rate_provider(provider_name, model)`:
   `gcp_vertex_ai` -> `google-vertex-anthropic` for `claude*` models, else
   `google-vertex`; `anthropic`, `google`, `openai` map to themselves; anything
   else -> None (unpriced).
3. **estimate()** prices with `row.get("rate_provider", row["provider"])` (also
   for the `priced` flag) so opencode rows are unchanged. `by_model` rows gain
   `backend` (opencode rows: `"opencode"`) and `unrecorded_msgs` (count of
   `recorded_missing` rows; 0 for opencode). The unpriced list keeps its
   `[provider, model]` shape, so goose entries read `["goose:mock-rolling", ...]`.
4. **Daily and size buckets.** The SQL queries stay. Goose rows are merged in
   Python: daily by `day` (sum msgs, cache_read, cache_write, uncached=input,
   output, re-sorted by day); size buckets with the same boundaries
   (prompt_size = input + cache_read + cache_write), merged by bucket (sum msgs,
   min of min, max of max) and ordered by the fixed bucket order.
5. **--by-kind**: goose rows are classified with the goose kind_map merged into
   the opencode one.
6. **--vertex-reconcile counts goose Vertex calls.** Goose on cloudbox reaches
   Vertex through the same claude-failover-proxy as opencode, so its calls are
   in the same audit log. estimate()'s by_model rows gain `rate_provider`
   (opencode rows: same as provider; goose rows: the mapped one, may be None).
   db_call_counts_by_vertex_model matches on `row.get("rate_provider") or
   row.get("provider") or ""` starting with `google-vertex`.
7. **CLI.** `--goose-db PATH` (default
   `~/.local/share/goose/sessions/sessions.db`, via a module constant
   `_DEFAULT_GOOSE_DB` that tests can patch), `--no-goose`. `--db` given
   without `--goose-db` skips goose (so `--db other.db` never mixes in this
   host's live goose DB). Only when neither `--db` nor `--goose-db` is given
   does the default goose path apply. `--no-goose` still wins over everything.
   An explicitly passed `--goose-db` path that does not exist prints
   `Warning: goose DB not found: <path>` to stderr and continues; the DEFAULT
   path missing stays silent. A goose read error prints
   `Warning: goose usage not counted: <err>` to stderr and the report continues.
   The opencode DB stays required, unchanged.
8. **Output.**
   - JSON: `meta.goose_db_path` (path read, or null when skipped/missing/failed);
     `by_model[].backend`, `by_model[].unrecorded_msgs`,
     `by_model[].rate_provider`, `by_model[].est_cost_recorded`. No other key changes.
   - Reconciliation: compares like with like. A goose row whose ledger cost is
     NULL has no recorded figure, so it must not create a Δ. by_model rows gain
     `est_cost_recorded`: the estimate summed over rows that are NOT
     recorded_missing (for opencode rows it equals est_cost). reconcile()
     computes delta and delta_pct (and therefore flagged) from
     `row.get("est_cost_recorded", est_cost)` vs recorded_cost; total_delta =
     sum of deltas. Headline est_cost and total_est remain unchanged.
   - Text: heading `Usage Report (opencode + goose)` when goose rows were read,
     else unchanged `OpenCode Usage Report`. Goose labels show as
     `goose:gcp_vertex_ai/claude-opus-5-5`. Summary line: `Estimated: $X   |
     Recorded: $Y   |   Δ (recorded−estimated, rows with a recorded cost): $Z`.
     Under the reconciliation summary, when any priced row has unrecorded
     msgs: `  Note: N goose messages have no recorded cost (goose had no price
     then); they are in Estimated but not in Δ.`
     Footer adds `Goose database: <path>` when read.
9. **No rename.** Epic precedent c87c.1 kept `oc-revive`; `oc-cost` stays.
   Description strings (argparse, `default.nix` meta, README) say opencode and goose.

## Tests (pkgs/oc-cost/test_oc_cost.py; hermetic)

- A `make_goose_db` helper writing a temp file with `sessions` (id,
  parent_session_id, provider_name) and `usage_ledger`.
- Reader: cache-inclusive input conversion; seconds->day; window bounds;
  `goose:` prefixes; null cost -> recorded 0 + recorded_missing; kind_map.
- Mapping: the four cases plus unknown -> None.
- estimate(): goose vertex claude row priced via `google-vertex-anthropic`,
  `backend`/`unrecorded_msgs` fields; opencode rows get `backend="opencode"`.
- Merges: daily and size-bucket merges, including a day/bucket only goose has.
- main(): JSON end to end with both DBs (totals add; `meta.goose_db_path`);
  `--no-goose`; missing goose DB is silent; corrupt goose DB warns and exits 0;
  text heading/label/note/footer.
- Existing integration tests must not read the real goose DB: patch
  `_DEFAULT_GOOSE_DB` to a nonexistent path in their setUp.
- Bump the pinned count in `flake.nix` `checks.oc-cost-tests` in the same commit.

## Docs

README: a "Goose" section (source table, cache-inclusive input, estimate vs
ledger cost, unrecorded rows, mocks show as unpriced, vertex-reconcile is
opencode-only). `.agents/skills/tracking-cache-costs/SKILL.md`: one line that
goose is included. Do not fix that skill's unrelated stale jq examples here.
