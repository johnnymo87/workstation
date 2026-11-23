# session-tags

Session tagging and stacked-area consumption visualization for OpenCode.

1. **List price, not money billed**: The chart axis represents list price consumed, not money billed.
2. **Cap and routing artifact**: Real spend is capped near $210/day by two $100 ceilings in claude-failover-proxy (`CFP_BUDGET_DOLLARS`, `CFP_ENTERPRISE_BUDGET_DOLLARS`), past which traffic spills to a flat-rate subscription at $0 marginal cost. Per-tag metered dollars would be a routing artifact, which is why the chart plots list price and draws metered only as a thin reference line.
3. **Stored cost**: The dollar figure is opencode's stored `$.cost`, not a recomputation against a rate book; `oc-cost --reconcile` is where rate-book disagreement gets surfaced.
4. **One tag per session**: Each session has at most one tag, because a stacked area's top edge must equal the total.
5. **Coverage comparison**: The coverage footer compares list price against CFP's notional Vertex cost over the days CFP has notional data for — the current day is always excluded, because `spend.json` carries no notional field. Measured agreement on a like-for-like window is ~100.4%.
6. **Usage**:

```bash
session-tags top --days 7            # find what to tag
session-tags set billing             # tag the current session
session-tags which ses_abc123        # tag / source / root-id / kind, tab-separated
                                # (kind = session|auto; source stays manual|auto)
session-tags sessions billing        # root session ids carrying a tag, one per line
session-tags report --days 7
session-tags serve                   # then, from the Mac, just open
                                # http://127.0.0.1:4710 (cloudbox) or :4711 (devbox)
                                # -- the socket-activated *-chart-tunnel
                                # LaunchAgents connect on demand
```

### Claude Max only: `--provider`, `--backend`, `--account-weeks`

To see consumption of the Claude Max subscription pool alone, in account-weeks (the unit its quota is budgeted in), per program tag.

- **`--provider <id>[,<id>...]`** (`report`, `top`, `serve`): keep only opencode messages whose `providerID` is listed, and goose sessions whose `provider_name` is listed. The lgtm and eternal-machinery ledgers have no provider field, so they are **excluded** whenever `--provider` is given. On `serve` the filter shapes the bands only; the cfp coverage, drift and cap-marker inputs stay all-provider, since they are compared with cfp's all-provider totals.
- **`--backend max|vertex`** (`report`): cloudbox's opencode reports `google-vertex-anthropic` for both Vertex and Max, so the split exists only in claude-failover-proxy's events. This builds the report **only** from `/var/lib/claude-failover-proxy/events.jsonl` (override with `--cfp-events`), joining each `usage` event (`backend`, notional `cost`) to its `route` event on `requestId` for the session. `ses_*` sessions resolve to their opencode root and tag, `YYYYMMDD_N` sessions to `goose:<id>`; a usage event with no route lands under `cfp:unrouted`. lgtm's goose runs use private goose roots whose ids can collide with goose-serve's, and the lgtm ledger records no goose session id, so a goose-shaped id is attributed to the nearest lgtm ledger row (within a day) unless goose-serve's own `usage_ledger` has a row for it within 10 minutes of the request; goose-shaped ids in no known ledger land under `cfp:goose-unknown`. Usage events with tokens but no positive `cost` are listed under "Unpriced models" (keyed by the route's model). If the events file starts after the window start (its retention is shorter), a warning is printed and the rate line counts from the file's first event. Dollars are the event's `cost`; opencode/goose/ledger rows are not read (they would double count). Cannot be combined with `--provider`.
- **`--account-weeks [DOLLARS]`** (`report`): adds an `acct-wk` column and a rate line (account-weeks per week over the elapsed window). The numerator is each row's **tokens priced at opus-5-5 list** ($4 input, $0.20 cache read, $5 cache write, $20 output per Mtok), divided by `DOLLARS`, since that is how the divisor was calibrated; the `total` column stays the row's own list-price dollars. On cloudbox it includes any usage-billed seat traffic, which draws no Max quota (the report says so under the table). The lgtm/EM ledgers do not feed it. The default divisor is `ACCOUNT_WEEK_USD` = 1520 list-price dollars (opus-5-5 rates) per Claude Max 20x account-week, calibrated in `docs/research/2026-11-23-claude-max-quota-budget.md` and refit by `workstation-ynoq.2`. Only meaningful with `--provider` or `--backend`; it warns on stderr otherwise.

```bash
# devbox: the Max pool is providerID/provider_name `anthropic`
session-tags report --days 7 --provider anthropic --account-weeks
session-tags top --days 7 --provider anthropic

# cloudbox: Max vs Vertex split comes from cfp
session-tags report --days 7 --backend max --account-weeks
session-tags report --days 7 --backend vertex
```

### Goose spend source

In addition to opencode sessions, `session-tags` reads Goose sessions from `~/.local/share/goose/sessions/sessions.db` (override with `--goose-db`). If the database does not exist or is unreadable, it is silently skipped.

- **Ledger cost and pricing**: Spend is read from `usage_ledger`. When cost is recorded in the ledger, that cost is used. When cost is null, it is calculated from model rates using cache-adjusted token counts (in goose, `input_tokens` includes cache read and write tokens; uncached input is `input - cache_read - cache_write`).
- **Session IDs**: Goose sessions are identified by `goose:<id>`. Child sessions roll up to their root session via `parent_session_id`.
- **Tag resolution**: Explicit session tags in `tags.db` take precedence. Untagged roots fall back to `auto:goose/<slug>`, where slug is the recipe title (from `recipe_json`), session name, or session type.
- **Bulk tagging by directory**:

```bash
session-tags set alpha-runs --goose-dir /path/to/project
session-tags set alpha-runs --goose-dir /path/to/dir1 --goose-dir /path/to/dir2 --since 1788874200000
```

`--goose-dir` performs a one-shot write to `tags.db` for all matching goose sessions whose working directory matches (path-normalised) and whose `created_at` timestamp is at or after `--since` (if provided). It is a one-shot operation that writes session tags, not a stored directory rule.

### lgtm goose spend source

lgtm's goose review turns and goose gather runs each run in a private `GOOSE_PATH_ROOT` that lgtm later deletes, so none of that spend is in any `sessions.db` above. lgtm records it in an append-only ledger, `~/.local/state/lgtm/goose-usage.jsonl` (override with `--lgtm-ledger`; schema in lgtm's `src/gooseUsageLedger.ts`), and `session-tags` counts it in both `report` and the chart.

- **Tag**: `lgtm-runs`, the same tag lgtm's opencode reviews carry, unless `tags.db` names the root. Roots are `lgtm-goose:<review session>` and `lgtm-goose:gather:<repo>#<pr>`.
- **Dedupe**: rows are deduped on `key`, first wins. File order is not time order: lgtm backfills old rows late, and windowing uses each row's `at`.
- **Cost**: lgtm's `costUsd`. A zero-cost row with tokens is repriced from the rate table when it carries a cache split (gather), and otherwise listed under "Unpriced models".
- **Not double-counted**: these runs never touch goose-serve's database, and lgtm's opencode sessions never write the ledger.
- **Late rows**: lgtm can append a row days after the spend (a superseded review session's last turn, the one-shot gather backfill), so a finished day's bar can grow after the fact.
- **Loud on schema drift**: a keyed row with an unknown `v`, `kind` or timestamp is not counted and is reported on stderr.
- **Known gaps**: ledger spend, like goose-serve spend, is left out of the Claude-only cfp coverage and cap numerators even though goose traffic goes through cfp, so coverage reads low; `oc-cost` does not read the ledger. `--lgtm-ledger ""` turns the source off.

### eternal-machinery spend source

eternal-machinery (EM) runtime agent spend (port 4318) and benchmark spend (port 4319, codex port 2455) are recorded in monthly JSONL shards in `~/.local/state/eternal-machinery/spend/spend-YYYY-MM.jsonl` (override with `OC_TAGS_EM_LEDGER_DIR` or `--em-ledger-dir`).

- **Tag**: `em-agents:<name>` for role agents, `em-bench:<name>` for role bench, unless `tags.db` names the root. Root IDs are `em:<spend>` (e.g. `em:agents/warrior_f`).
- **Dedupe**: rows are deduped on `key`, first wins.
- **Streaming**: streams line by line over only the monthly shards touched by the requested window.
- **Cost**: calculated from model rates with goose cache semantics (`input + cache_read + cache_write` as inclusive input). Zero-token rows (`http_error`, `proxy_error`) cost $0 and do not show as unpriced. Unknown models appear under "Unpriced models".
- **Footer**: displays EM proxy error count and per-port ledger freshness (`EM ledger: last row Nh ago (:4318), Nd ago (:4319)`).
- **Missing directory**: by default, an absent ledger directory is silently ignored (normal on cloudbox). When `OC_TAGS_EM_LEDGER_EXPECTED=1` is set (enabled on devbox via `oc-tags-serve.nix`), a missing directory renders a footer line `EM ledger: <dir> missing` to expose a missing proxy or mount.
- **Chart folding**: `fold=<prefix>[,<prefix>]` query parameter (or `--fold` in `report`) sums `<prefix>:*` tags into a single band before ranking (e.g. `fold=em-agents,em-bench`).
- **Claude cap/coverage**: EM rows do not enter `claude_day` or cfp coverage calculations.

### Directory rules (removed)

Directory rules (`dir_tag`, `session-tags set --dir`) were removed; precedence is session tag > `auto:`. If `session-tags` warns about retired rules in `dir_tag`, convert each matching session to an explicit `session-tags set <tag> <session>` after snapshotting `tags.db`, then delete the rows:

```bash
python3 -c "import sqlite3,os; c=sqlite3.connect(os.path.expanduser('~/.local/share/oc-tags/tags.db')); c.execute('DELETE FROM dir_tag'); c.commit()"
```
