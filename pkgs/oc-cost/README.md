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

Anthropic per-model rates are hardcoded in `oc_cost.py` (`PRICES` dict).
Update manually when Anthropic changes rates or you start using a new model.
Source: <https://docs.anthropic.com/en/docs/about-claude/pricing>.

Unknown models appear as `(no rate)` in text output and in the
`unpriced_models` list of JSON output. Their tokens are excluded from the
cost total.

## Design

See `docs/plans/2026-04-20-oc-cost-design.md`.
