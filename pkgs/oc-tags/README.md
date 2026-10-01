# oc-tags

Session tagging and stacked-area consumption visualization for OpenCode.

1. **List price, not money billed**: The chart axis represents list price consumed, not money billed.
2. **Cap and routing artifact**: Real spend is capped near $210/day by two $100 ceilings in claude-failover-proxy (`CFP_BUDGET_DOLLARS`, `CFP_ENTERPRISE_BUDGET_DOLLARS`), past which traffic spills to a flat-rate subscription at $0 marginal cost. Per-tag metered dollars would be a routing artifact, which is why the chart plots list price and draws metered only as a thin reference line.
3. **Stored cost**: The dollar figure is opencode's stored `$.cost`, not a recomputation against a rate book; `oc-cost --reconcile` is where rate-book disagreement gets surfaced.
4. **One tag per session**: Each session has at most one tag, because a stacked area's top edge must equal the total.
5. **Coverage comparison**: The coverage footer compares list price against CFP's notional Vertex cost over the days CFP has notional data for — the current day is always excluded, because `spend.json` carries no notional field. Measured agreement on a like-for-like window is ~100.4%.
6. **Usage**:

```bash
oc-tags top --days 7            # find what to tag
oc-tags set billing             # tag the current session
oc-tags which ses_abc123        # tag / source / root-id / kind, tab-separated
                                # (kind = session|auto; source stays manual|auto)
oc-tags sessions billing        # root session ids carrying a tag, one per line
oc-tags report --days 7
oc-tags serve                   # then, from the Mac, just open
                                # http://127.0.0.1:4710 -- the socket-activated
                                # cloudbox-chart-tunnel LaunchAgent connects on demand
```

### Goose spend source

In addition to opencode sessions, `oc-tags` reads Goose sessions from `~/.local/share/goose/sessions/sessions.db` (override with `--goose-db`). If the database does not exist or is unreadable, it is silently skipped.

- **Ledger cost and pricing**: Spend is read from `usage_ledger`. When cost is recorded in the ledger, that cost is used. When cost is null, it is calculated from model rates using cache-adjusted token counts (in goose, `input_tokens` includes cache read and write tokens; uncached input is `input - cache_read - cache_write`).
- **Session IDs**: Goose sessions are identified by `goose:<id>`. Child sessions roll up to their root session via `parent_session_id`.
- **Tag resolution**: Explicit session tags in `tags.db` take precedence. Untagged roots fall back to `auto:goose/<slug>`, where slug is the recipe title (from `recipe_json`), session name, or session type.
- **Bulk tagging by directory**:

```bash
oc-tags set alpha-runs --goose-dir /path/to/project
oc-tags set alpha-runs --goose-dir /path/to/dir1 --goose-dir /path/to/dir2 --since 1788874200000
```

`--goose-dir` performs a one-shot write to `tags.db` for all matching goose sessions whose working directory matches (path-normalised) and whose `created_at` timestamp is at or after `--since` (if provided). It is a one-shot operation that writes session tags, not a stored directory rule.

### Directory rules (removed)

Directory rules (`dir_tag`, `oc-tags set --dir`) were removed; precedence is session tag > `auto:`. If `oc-tags` warns about retired rules in `dir_tag`, convert each matching session to an explicit `oc-tags set <tag> <session>` after snapshotting `tags.db`, then delete the rows:

```bash
python3 -c "import sqlite3,os; c=sqlite3.connect(os.path.expanduser('~/.local/share/oc-tags/tags.db')); c.execute('DELETE FROM dir_tag'); c.commit()"
```
