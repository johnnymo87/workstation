---
name: tracking-cache-costs
description: Measures OpenCode prompt caching efficiency using ccusage-opencode. Use when investigating API costs, evaluating cache hit rates, or checking if upstream caching fixes have landed.
---

# Tracking OpenCode Cache Costs

## Quick Check

```bash
ccusage-opencode daily
```

**Known limitation (as of v18.0.8):** ccusage-opencode cannot read data from OpenCode >= 1.2.2, which migrated storage from JSON files to SQLite. Data stops at the migration date. Fix is pending in [ryoppippi/ccusage PR #850](https://github.com/ryoppippi/ccusage/pull/850) -- check if merged before trusting ccusage output.

### Direct SQLite workaround

Until ccusage-opencode ships the SQLite fix, query the DB directly:

```bash
nix-shell -p sqlite --run "sqlite3 ~/.local/share/opencode/opencode.db \"
SELECT date(time_created/1000, 'unixepoch') as day,
  sum(json_extract(data, '$.tokens.cache.read')) as cache_read,
  sum(json_extract(data, '$.tokens.cache.write')) as cache_write,
  sum(json_extract(data, '$.tokens.input')) as uncached,
  ROUND(100.0 * sum(json_extract(data, '$.tokens.cache.write')) /
    (sum(json_extract(data, '$.tokens.cache.read')) + sum(json_extract(data, '$.tokens.cache.write')) + sum(json_extract(data, '$.tokens.input'))), 1) as write_pct,
  ROUND(100.0 * sum(json_extract(data, '$.tokens.cache.read')) /
    (sum(json_extract(data, '$.tokens.cache.read')) + sum(json_extract(data, '$.tokens.cache.write')) + sum(json_extract(data, '$.tokens.input'))), 1) as read_pct
FROM message
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
GROUP BY day ORDER BY day;
\""
```

Before/after comparison (patch deployed vs pre-patch):

```bash
nix-shell -p sqlite --run "sqlite3 ~/.local/share/opencode/opencode.db \"
SELECT
  CASE WHEN date(time_created/1000, 'unixepoch') <= '2026-02-17' THEN 'BEFORE' ELSE 'AFTER' END as period,
  ROUND(100.0 * sum(json_extract(data, '$.tokens.cache.write')) /
    (sum(json_extract(data, '$.tokens.cache.read')) + sum(json_extract(data, '$.tokens.cache.write')) + sum(json_extract(data, '$.tokens.input'))), 1) as write_pct,
  ROUND(100.0 * sum(json_extract(data, '$.tokens.cache.read')) /
    (sum(json_extract(data, '$.tokens.cache.read')) + sum(json_extract(data, '$.tokens.cache.write')) + sum(json_extract(data, '$.tokens.input'))), 1) as read_pct
FROM message
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
GROUP BY period;
\""
```

## Full Analysis

Run the analysis script for per-day cache efficiency breakdown and savings estimate:

```bash
node .opencode/skills/tracking-cache-costs/analyze.mjs
```

**Note:** This script depends on ccusage-opencode, so it shares the SQLite limitation above. Use the direct queries for post-1.2.2 data until the fix lands.

Output includes: daily cache read/write/uncached ratios, cost breakdown at model-specific rates, and projected monthly savings if cache writes were reduced.

Adjust the `REDUCTION` env var to model different improvement scenarios (default: 0.44 = 44%, per PR #5422's benchmark):

```bash
REDUCTION=0.30 node .opencode/skills/tracking-cache-costs/analyze.mjs
```

## Interpreting Results

| Write % | Assessment | Action |
|---------|-----------|--------|
| <10% | Healthy | No action needed |
| 10-20% | Moderate | Check for short sessions or frequent subagent spawning |
| 20-40% | Poor | Cache busting likely -- tool reordering or file tree churn |
| >40% | Severe | Investigate immediately, major cost impact |

**Root causes of high writes**: tool definition order instability (prefix-based cache busted by reordering), file tree changes in system prompt, only 4 cache breakpoints in current opencode, short sessions / subagent spawning.

## Check Upstream Progress

### OpenCode caching (anomalyco/opencode)

```bash
gh pr view 5422 --repo anomalyco/opencode --json state,comments --jq '{state, lastComment: .comments[-1].body[:200]}'
gh pr list --repo anomalyco/opencode --search "cache" --state merged --limit 5 --json number,title,mergedAt
```

Key items:
- [PR #5422](https://github.com/anomalyco/opencode/pull/5422) -- provider-specific cache config (not merged)
- [Issue #5416](https://github.com/anomalyco/opencode/issues/5416) -- caching improvement request
- [Issue #5224](https://github.com/anomalyco/opencode/issues/5224) -- system prompt cache invalidation
- Any PR touching `packages/opencode/src/provider/transform.ts` signals caching work

### ccusage-opencode SQLite support (ryoppippi/ccusage)

```bash
gh pr view 850 --repo ryoppippi/ccusage --json state,comments --jq '{state, lastComment: .comments[-1].body[:200]}'
```

- [PR #850](https://github.com/ryoppippi/ccusage/pull/850) -- SQLite support for OpenCode >= 1.2.2 (not merged as of v18.0.8)
- [Issue #845](https://github.com/ryoppippi/ccusage/issues/845) -- original report
- When merged: update version in `pkgs/ccusage-opencode/default.nix` and the analyze.mjs script will work again for current data
