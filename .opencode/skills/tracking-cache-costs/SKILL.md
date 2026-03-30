---
name: tracking-cache-costs
description: Measures OpenCode prompt caching efficiency and API costs via SQLite analysis. Use when investigating API costs, evaluating cache hit rates, or checking if upstream caching fixes have landed.
---

# Tracking OpenCode Cache Costs

## Quick Check

```bash
node .opencode/skills/tracking-cache-costs/analyze.mjs
```

The script queries the OpenCode SQLite database directly (`~/.local/share/opencode/opencode.db`). If `sqlite3` is not on PATH, it auto-wraps with `nix-shell -p sqlite`.

Set the analysis window with `DAYS`:

```bash
DAYS=30 node .opencode/skills/tracking-cache-costs/analyze.mjs
```

Output includes:
- Daily cache read/write/uncached ratios
- Per-model cost breakdown (Anthropic API rates)
- Cost component analysis (cache reads vs writes vs uncached vs output)
- Daily average and monthly projection
- Prompt size distribution (bucketed)

## Interpreting Results

| Write % | Assessment | Action |
|---------|-----------|--------|
| <10% | Healthy | No action needed |
| 10-20% | Moderate | Check for short sessions or frequent subagent spawning |
| 20-40% | Poor | Cache busting likely -- tool reordering or file tree churn |
| >40% | Severe | Investigate immediately, major cost impact |

**Root causes of high writes**: tool definition order instability (prefix-based cache busted by reordering), file tree changes in system prompt, only 4 cache breakpoints in current opencode, short sessions / subagent spawning.

## Pricing Notes

- **Opus 4.6 and Sonnet 4.6**: flat pricing across the full 1M context window. No >200k surcharge.
- **Older models (Opus 4, 4.1)**: may have different pricing tiers for >200k context. The analysis script uses flat rates.
- **Vertex AI / Bedrock**: pricing may differ from Anthropic direct API rates. The script uses Anthropic's published rates.
- Pricing source: https://docs.anthropic.com/en/docs/about-claude/pricing

## Ad-Hoc Queries

For custom analysis, query the DB directly:

```bash
nix-shell -p sqlite --run "sqlite3 -header -column ~/.local/share/opencode/opencode.db \"
SELECT date(time_created/1000, 'unixepoch') as day,
  sum(json_extract(data, '$.tokens.cache.read')) as cache_read,
  sum(json_extract(data, '$.tokens.cache.write')) as cache_write,
  sum(json_extract(data, '$.tokens.input')) as uncached,
  ROUND(100.0 * sum(json_extract(data, '$.tokens.cache.read')) /
    (sum(json_extract(data, '$.tokens.cache.read')) + sum(json_extract(data, '$.tokens.cache.write')) + sum(json_extract(data, '$.tokens.input'))), 1) as read_pct
FROM message
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
GROUP BY day ORDER BY day DESC LIMIT 14;
\""
```

## Check Upstream Progress

### OpenCode caching (anomalyco/opencode)

```bash
gh pr list --repo anomalyco/opencode --search "cache" --state merged --limit 5 --json number,title,mergedAt
```

Key items:
- [PR #5422](https://github.com/anomalyco/opencode/pull/5422) -- provider-specific cache config (not merged)
- [Issue #5416](https://github.com/anomalyco/opencode/issues/5416) -- caching improvement request
- [Issue #5224](https://github.com/anomalyco/opencode/issues/5224) -- system prompt cache invalidation
- Any PR touching `packages/opencode/src/provider/transform.ts` signals caching work
