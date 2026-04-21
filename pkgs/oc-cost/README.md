# oc-cost

Report OpenCode token usage and API cost from the local SQLite database
(`~/.local/share/opencode/opencode.db`).

Replaces the older `analyze.mjs` script under
`.opencode/skills/tracking-cache-costs/`.

## Usage

    oc-cost                              # last 14 days, formatted text
    oc-cost --days 30                    # last 30 days
    oc-cost --since 2026-04-01           # from date to now
    oc-cost --since 2026-04-01 --until 2026-04-15
    oc-cost --json                       # machine-readable
    oc-cost --db /path/to/opencode.db    # override DB location

`--days` and `--since/--until` are mutually exclusive.

## Pricing

Per-model rates are hardcoded in `oc_cost.py` (`PRICES` dict). Update
manually when providers change rates or you start using a new model.

Sources:
- Anthropic: <https://docs.anthropic.com/en/docs/about-claude/pricing>
- Google (Gemini, Vertex AI): <https://cloud.google.com/vertex-ai/generative-ai/pricing>

Unknown models appear as `(no rate)` in text output and in the
`unpriced_models` list of JSON output. Their tokens are excluded from the
cost total.

### Caveats

- **Anthropic >200k context surcharge** is not modelled. Opus 4.6/4.7 and
  Sonnet 4.6 use flat pricing across the full 1M window so this doesn't
  matter for them. Older models (Opus 4, 4.1) and Gemini 3.x have a >200k
  tier that this tool ignores.
- **Gemini cache storage** is invisible to this tool. Google bills Gemini
  cache CREATION at the input rate (modelled correctly) AND a separate
  token-hour STORAGE fee (~$4.50/MTok-hour) for as long as the cache
  lives. oc-cost's schema only captures per-token rates, so reported
  Gemini cache cost is an UNDERCOUNT for long-lived caches.
- **Vertex AI / Bedrock vs Anthropic direct** may have small rate
  differences. oc-cost uses each provider's published rates for the
  model id as it appears in the DB.

## Design

See `docs/plans/2026-04-20-oc-cost-design.md`.
