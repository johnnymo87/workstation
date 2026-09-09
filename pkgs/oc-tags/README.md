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
oc-tags set --dir '/home/dev/projects/mono/.worktrees/fbm-*' fbm
oc-tags report --days 7
oc-tags serve                   # then, from the Mac, just open
                                # http://127.0.0.1:4710 -- the socket-activated
                                # cloudbox-chart-tunnel LaunchAgent connects on demand
```
