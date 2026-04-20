# oc-cost: OpenCode Usage & Cost CLI

**Goal:** A first-class CLI on the user's `$PATH` that reports OpenCode token
usage and API cost from the local SQLite database. Replaces the ad-hoc
`analyze.mjs` script in `.opencode/skills/tracking-cache-costs/`.

**Architecture:** A single Python file at `pkgs/oc-cost/oc_cost.py`, packaged
via Nix (`stdenv.mkDerivation` with a substituted `python3` shebang). Source
lives inline in the workstation repo. Deployed by adding `oc-cost` to the user
package list in `users/dev/home.base.nix`.

## Why not existing tools

We evaluated `@ccusage/opencode` (an npm package that historically supported
OpenCode). It still expects messages to live in
`~/.local/share/opencode/storage/message/{sessionID}/msg_*.json`, but recent
OpenCode releases migrated to a SQLite database at
`~/.local/share/opencode/opencode.db`. ccusage now finds zero data on a
current install.

The upstream issue ([ryoppippi/ccusage#845](https://github.com/ryoppippi/ccusage/issues/845))
has been open since February with **four unmerged fix PRs** (#943, #879, #850,
#887). Maintainer is unresponsive on this thread. Waiting for an upstream fix
is not viable.

We already have a working SQLite-based analyzer at
`.opencode/skills/tracking-cache-costs/analyze.mjs`. The new CLI is largely a
Python port of that script with two correctness fixes, flexible time windows,
JSON output, and proper packaging.

## Database

Single global SQLite DB at `~/.local/share/opencode/opencode.db`. Relevant
schema:

```sql
CREATE TABLE message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  time_created integer NOT NULL,  -- unix milliseconds
  time_updated integer NOT NULL,
  data text NOT NULL              -- JSON blob
);
```

Token usage lives inside the `data` JSON for assistant messages:

```json
{
  "role": "assistant",
  "modelID": "claude-opus-4-6",
  "providerID": "anthropic",
  "tokens": {
    "input": 234,
    "output": 1567,
    "cache": { "read": 12345, "write": 4567 }
  }
}
```

Only assistant messages have token data. We filter on
`json_extract(data, '$.tokens.cache.read') IS NOT NULL`, which excludes
non-Anthropic models (they do not report cache tokens this way). v1 retains
this filter to preserve cost-math accuracy and parity with `analyze.mjs`.

## Usage

```bash
oc-cost                              # last 14 days, formatted text
oc-cost --days 30                    # last 30 days
oc-cost --since 2026-04-01           # from date to now
oc-cost --since 2026-04-01 --until 2026-04-15
oc-cost --json                       # machine-readable
oc-cost --db /path/to/opencode.db    # override DB location
```

`--days` and `--since/--until` are mutually exclusive (argparse mutex group).

## Output sections (text mode)

Same four sections as `analyze.mjs` today:

1. **Daily breakdown:** date, message count, cache read/write/uncached %
2. **Per-model cost breakdown:** msgs, cache read/write/output tokens, model
   subtotal cost
3. **Cost components:** cache reads, cache writes, uncached input, output;
   total, daily average, monthly projection
4. **Prompt size distribution:** message count and percentage per token-size
   bucket (0-50k, 50-100k, 100-150k, 150-200k, 200-300k, 300k+)

## Output schema (JSON mode)

```json
{
  "meta": {
    "db_path": "/home/dev/.local/share/opencode/opencode.db",
    "window": {
      "start": "2026-04-06T00:00:00Z",
      "end":   "2026-04-20T23:59:59Z"
    },
    "active_days": 14
  },
  "daily": [
    {"day": "2026-04-06", "msgs": 142, "cache_read": 1234567,
     "cache_write": 89012, "uncached": 3456, "output": 78901}
  ],
  "by_model": [
    {"model": "claude-opus-4-6", "msgs": 89,
     "cache_read": 12345678, "cache_write": 234567,
     "uncached": 5432, "output": 87654, "cost_usd": 12.34}
  ],
  "cost_components": {
    "cache_reads": 1.23, "cache_writes": 4.56, "uncached_input": 0.78,
    "output": 9.01, "total": 15.58,
    "daily_avg": 1.11, "monthly_proj": 33.39,
    "unpriced_models": []
  },
  "size_buckets": [
    {"bucket": "0-50k", "msgs": 12, "min_size": 1234, "max_size": 49000}
  ]
}
```

Numeric fields are raw (token counts as integers, USD as floats); no formatted
strings. Empty windows produce a valid document with empty arrays and exit 0.

## Two correctness improvements over analyze.mjs

1. **Per-model cost component math.** `analyze.mjs` computes the cost
   components panel using the dominant model's rates, applied to grand-total
   token counts. With mixed Opus + Sonnet usage this attributes Sonnet tokens
   at Opus rates. **Fix:** sum each component (cache_read, cache_write,
   uncached, output) across models using each model's own rate.
2. **Unknown-model handling.** `analyze.mjs` includes unknown-model token
   counts in the grand totals but adds `0` to the cost (no rate available),
   so cost percentages do not sum cleanly. **Fix:** exclude unknown-rate rows
   from grand totals and surface them via a separate "Unpriced models" line
   (text) or `unpriced_models` array (JSON).

## Pricing

Hardcoded Python dict mirroring `analyze.mjs`'s table, covering the Claude
Opus / Sonnet / Haiku families currently in use. Model IDs are normalized by
stripping `@suffix` (e.g. `@default`), then matched exact-first, then by
prefix. Unknown models are surfaced (see fix #2) rather than silently zeroed
or guessed.

Pricing source: <https://docs.anthropic.com/en/docs/about-claude/pricing>.
Updated manually when Anthropic changes rates or a new model lands.

## Architecture

### File layout

```
pkgs/oc-cost/
├── default.nix         # Nix derivation
├── oc_cost.py          # The whole tool, no third-party deps
├── test_oc_cost.py     # unittest-based tests
└── README.md           # Short usage notes
```

### Module layout inside `oc_cost.py`

| Component | Responsibility |
|---|---|
| `PRICES` dict | Per-model rates (input / output / cache_write / cache_read) |
| `price_for(model_id)` | Strip `@suffix`, exact match, then prefix fallback |
| `parse_args()` | argparse with `--days` / `--since` / `--until` mutex, `--json`, `--db` |
| `resolve_window(args, now_ms)` | Returns `(start_ms, end_ms)` |
| `connect(db_path)` | `sqlite3` read-only connection (`file:...?mode=ro`) |
| `query_daily / query_by_model / query_size_buckets` | One SQL query each, bound params |
| `compute_cost_components(by_model)` | Sums per-model costs by component |
| `render_text(report)` / `render_json(report)` | Output formatters |
| `main()` | Wiring |

### Data flow

```
argv ─► parse_args ─► resolve_window ─► sqlite3.connect(ro)
                                              │
                       ┌──────────────────────┼──────────────────────┐
                       ▼                      ▼                      ▼
                 query_daily          query_by_model       query_size_buckets
                       │                      │                      │
                       └──────────► compute_cost_components ◄────────┘
                                              │
                                       build report dict
                                              │
                              ┌───────────────┴───────────────┐
                              ▼                               ▼
                        render_text                     render_json
```

### Nix packaging

```nix
{ stdenv, python3 }:
stdenv.mkDerivation {
  pname = "oc-cost";
  version = "0.1.0";
  src = ./.;
  installPhase = ''
    install -Dm755 oc_cost.py $out/bin/oc-cost
    substituteInPlace $out/bin/oc-cost \
      --replace-fail '#!/usr/bin/env python3' '#!${python3}/bin/python3'
  '';
  meta.mainProgram = "oc-cost";
}
```

This pattern (inline `src = ./.;`) is new for this repo — every existing
`pkgs/<x>/default.nix` fetches from elsewhere — but is justified because
`oc-cost` is original code tightly coupled to OpenCode's DB schema. If the
tool grows or we want to share it, splitting to a sibling repo is a mechanical
30-minute change (move files, swap `src = ./.;` for `fetchFromGitHub`, add to
`projects.nix`).

## Error handling

| Failure | Response |
|---|---|
| `opencode.db` does not exist | Exit 1, `Database not found: <path>. Set --db or check OPENCODE_DATA_DIR.` |
| DB exists but `message` table missing | Exit 1, `Not an OpenCode database (missing 'message' table): <path>` |
| DB locked | Catch `OperationalError`, exit 2, `Database busy. Retry in a moment.` |
| Empty result set in window | Exit 0, friendly message; JSON mode emits empty arrays |
| Malformed `--since` / `--until` | argparse error, non-zero exit |
| `--days` combined with `--since/--until` | argparse mutex error |
| `--days <= 0` | argparse `type=positive_int` rejects |

No try/except around queries themselves — let unexpected SQLite errors crash
with a stack trace, which is more useful than a swallowed message.

## Testing

Single test file `pkgs/oc-cost/test_oc_cost.py`, runnable via
`python3 -m unittest pkgs/oc-cost/test_oc_cost.py`. No external test data;
fixtures build in-memory SQLite DBs with synthetic messages.

Coverage:

1. `price_for` — exact match, `@default` suffix stripping, prefix fallback,
   unknown returns `None`
2. `resolve_window` — `--days N` correctness, date parsing, mutex enforcement
3. `query_daily` against synthetic 3-day fixture — verifies sums, day
   grouping, time-window filtering
4. `query_by_model` — ordering by `cache_read DESC`, multi-model aggregation
5. **Correctness fix #1:** mixed Opus+Sonnet fixture, verify component costs
   equal sum-of-per-model contributions, not dominant-rate × grand-total
6. **Correctness fix #2:** mixed priced+unpriced fixture, verify unpriced
   tokens excluded from `cost_components.total` and surfaced in
   `unpriced_models`
7. JSON output schema — round-trip through `json.loads`, assert documented
   key set

## Deployment to cloudbox

Three-step rollout, each independently verifiable:

1. **Land the package**
   - Add `pkgs/oc-cost/{default.nix, oc_cost.py, test_oc_cost.py, README.md}`
   - Wire into the Nix package set (location TBD during implementation —
     match how `beads` / `gws` are exposed)
   - Add to user package list in `users/dev/home.base.nix`
   - Verify locally: `nix build .#oc-cost`
2. **Apply on cloudbox**
   - `nix run home-manager -- switch --flake .#dev`
   - Verify: `which oc-cost && oc-cost --days 7` returns real data
3. **Retire `analyze.mjs`**
   - Delete `.opencode/skills/tracking-cache-costs/analyze.mjs`
   - Rewrite `.opencode/skills/tracking-cache-costs/SKILL.md`:
     - Replace "Quick Check" with `oc-cost` invocation
     - Keep "Interpreting Results" table (analyzer-agnostic)
     - Keep "Pricing Notes" section
     - Mention `oc-cost --json | jq` as the easier path for ad-hoc queries;
       keep the raw SQL example as a fallback
     - Keep upstream-progress section

Two commits on a feature branch (one per step 1+3 grouping), one PR.

## Verification before claiming done

- `nix build .#oc-cost` succeeds
- `python3 -m unittest pkgs/oc-cost/test_oc_cost.py` — all green
- `oc-cost --days 14` output matches
  `node .opencode/skills/tracking-cache-costs/analyze.mjs` output **except**
  for the two intentional correctness improvements (eyeballed on the same
  window)
- `oc-cost --days 14 --json | jq .` parses and contains documented top-level
  keys
- `oc-cost --days 0` rejected by argparse; `oc-cost --since 2099-01-01` exits
  cleanly with the empty-window message

## Out of scope for v1 (deliberately YAGNI)

- Weekly / monthly aggregations (calendar grouping)
- Per-session views ("most expensive 10 sessions")
- LiteLLM fallback for unknown models (network dep, fragile per ccusage #900)
- Pricing config files
- Compact / responsive table layouts (`--compact`)
- Splitting source to a sibling repo

Each of these is a 30-minute follow-up if it later proves useful. Not
shipping them now keeps v1 small enough to verify by hand.

## Risks

| Risk | Mitigation |
|---|---|
| `opencode-patched` updates the DB schema | We rely on behavior, not codegen. Schema break crashes loudly; fix in same session as the opencode-patched bump. |
| Pricing drifts when Anthropic changes rates | Hardcoded table, manual update. Document expected staleness in README. |
| New model has no entry | `(no rate)` in text, `unpriced_models` in JSON — visible signal to add. |
| Python adds to nix closure | Negligible — `python3` already pulled in by other packages on this host. |
