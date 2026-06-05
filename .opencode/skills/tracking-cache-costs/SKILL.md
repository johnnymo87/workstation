---
name: tracking-cache-costs
description: Measures OpenCode prompt caching efficiency and API costs via SQLite analysis. Use when investigating API costs, evaluating cache hit rates, or checking if upstream caching fixes have landed.
---

# Tracking OpenCode Cache Costs

## Quick Check

```bash
oc-cost                              # last 14 days
oc-cost --days 30                    # custom window
oc-cost --since 2026-04-01           # date-bounded
oc-cost --json | jq '.cost_components.monthly_proj'
```

`oc-cost` is a packaged Python CLI in `pkgs/oc-cost/` that queries the
OpenCode SQLite database (`~/.local/share/opencode/opencode.db`) directly.
It replaces the older `analyze.mjs` script that used to live in this skill
directory.

Output sections:
- Daily cache read/write/uncached ratios
- Per-model cost breakdown (Anthropic API rates)
- Cost components — applies each model's own rates, not a dominant-model
  approximation
- Daily average and monthly projection
- Prompt size distribution (bucketed)
- Unpriced models (any model id not in `oc-cost`'s pricing table)

## Interpreting Results

Two independent signals — **check both, per provider.** Looking at only one hides real regressions.

### 1. Uncached % (the cost canary) = `input / (input + cache_read + cache_write)`

Catches caching *regressions* — re-sent context billed as full-price input instead of 10%-price cache reads.

| Uncached % | Assessment |
|------------|------------|
| 0–3%       | Healthy |
| 5–15%      | Degraded — breakpoint/anchor bug likely |
| >20%       | Severe — major cost impact |

**Watch Vertex hardest.** First-party `anthropic` has automatic top-level caching that *masks* a bad cache breakpoint (leaks only ~2–4%); `google-vertex-anthropic` and Bedrock have **no** such backstop, so the same bug runs 20–50% uncached there. A 2026-04/05 regression burned ~$5k almost entirely on Vertex **while write% stayed in the "healthy" band** — which is exactly why write% alone is insufficient.

### 2. Write % = `cache_write / (cache_read + cache_write)`

| Write % | Assessment | Action                                                     |
|---------|------------|------------------------------------------------------------|
| <10%    | Healthy    | No action needed                                           |
| 10-20%  | Moderate   | Check for short sessions or frequent subagent spawning     |
| 20-40%  | Poor       | Cache busting likely -- tool reordering or file tree churn |
| >40%    | Severe     | Investigate immediately, major cost impact                 |

**Root causes of high writes**: tool definition order instability (prefix-based cache busted by reordering), file tree changes in system prompt, only 4 cache breakpoints in current opencode, short sessions / subagent spawning.

A cache write costs 12.5× a read per token, so writes can be ~40% of the *dollar* total even at a single-digit write *token* rate — that's the normal cost of populating the cache, not a leak.

## Pricing Notes

- **Current Opus (4.6/4.7/4.8) and Sonnet 4.6**: flat pricing across the full 1M context window. No >200k surcharge. (Opus $5/$25/$0.50/$6.25, Sonnet $3/$15/$0.30/$3.75 per Mtok for input/output/cache_read/cache_write.)
- **Older models (Opus 4, 4.1)**: may have different pricing tiers for >200k context. `oc-cost` uses flat rates.
- **Vertex AI / Bedrock**: pricing may differ from Anthropic direct API rates. `oc-cost` uses Anthropic's published rates.
- Pricing source: https://docs.anthropic.com/en/docs/about-claude/pricing
- New models without an entry in the `PRICES` dict appear in `unpriced_models` and are excluded from the cost total. Add them to `pkgs/oc-cost/oc_cost.py`.

## Ad-Hoc Queries

For most investigations, prefer `oc-cost --json | jq` to hand-written queries:

```bash
# Top-line monthly projection
oc-cost --json | jq .cost_components.monthly_proj

# Per-model cost subtotals
oc-cost --json | jq '.by_model[] | {model, cost_usd}'

# Daily totals as TSV
oc-cost --json | jq -r '.daily[] | [.day, .msgs, .cache_read, .cache_write] | @tsv'
```

For shapes `oc-cost` doesn't expose, query the DB directly. There's **no `sqlite3` binary** on these hosts and the DB is a live multi-GB file — open it read-only from python:

```python
import sqlite3, json
db="/home/dev/.local/share/opencode/opencode.db"
cur=sqlite3.connect(f"file:{db}?mode=ro",uri=True,timeout=20).cursor()
agg={}
for (data,) in cur.execute("select data from message"):
    d=json.loads(data)
    if d.get("role")!="assistant": continue
    p=d.get("providerID","?"); t=d.get("tokens") or {}; c=t.get("cache") or {}
    inp=t.get("input",0)or 0; rd=c.get("read",0)or 0; wr=c.get("write",0)or 0
    if inp+rd+wr==0: continue            # skip no-token / synthetic rows
    a=agg.setdefault(p,{"in":0,"rd":0,"wr":0,"cost":0})
    a["in"]+=inp; a["rd"]+=rd; a["wr"]+=wr; a["cost"]+=d.get("cost") or 0
for p,a in sorted(agg.items(),key=lambda x:-x[1]["cost"]):
    tot=a["in"]+a["rd"]+a["wr"]
    print(f"{p:26} ${a['cost']:8.2f}  uncached={100*a['in']/tot:5.1f}%")
```

- **Always group by `providerID`** — the routes bill and cache differently:
  `anthropic` = direct Claude, `google-vertex-anthropic` = Claude on Vertex,
  `google-vertex` = Gemini (implicit caching only: `cache.write` is always 0 and
  ~20% uncached is *structural*, NOT a bug — opencode applies no explicit cache
  markers to Gemini).
- **The stored `cost` field is trustworthy** (verified to recompute exactly at
  flat Anthropic rates), so `sum(cost)` is a valid spend total without repricing.
- Other useful group keys in `data`: `modelID`, `path.cwd` (project),
  `session_id`, and `time.created` (ms epoch, for day buckets).

## Caching architecture & status

Caching now rides **upstream** `applyCaching` (in `packages/opencode/src/provider/transform.ts`), which anchors the cache breakpoint on the moving conversation tail (`non-system.slice(-2)`). It is gated to Anthropic-family providers only (`anthropic`, `google-vertex-anthropic`, ids containing claude/anthropic/alibaba, and bedrock) — **Gemini is intentionally excluded**, which is why `google-vertex` shows ~20% uncached / 0 writes.

The former fork patch (`caching.patch`, sibling repo `opencode-cached`) was **dropped and the repo archived 2026-06-02** after a fork-side stable-anchor "optimization" caused the ~$5k Vertex regression. The only surviving local caching patch is `cache-thinking-skip.patch` in `opencode-patched`. Full post-mortem: `docs/plans/2026-06-02-paring-back-opencode-cached-caching.md`.

Check for new upstream caching work:

```bash
gh pr list --repo anomalyco/opencode --search "cache in:title" --state merged --limit 5 --json number,title,mergedAt
```

Any PR touching `transform.ts` (especially `applyCaching`) signals caching changes.
