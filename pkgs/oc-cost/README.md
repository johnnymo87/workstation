# oc-cost

Report OpenCode and Goose token usage and API cost from local SQLite databases
(`~/.local/share/opencode/opencode.db` and `~/.local/share/goose/sessions/sessions.db`).

Replaces the older `analyze.mjs` script under
`.agents/skills/tracking-cache-costs/`.

## Usage

    oc-cost                              # last 14 days, formatted text
    oc-cost --days 30                    # last 30 days
    oc-cost --since 2026-04-01           # from date to now
    oc-cost --since 2026-04-01 --until 2026-04-15
    oc-cost --reconcile                  # expand the per-model estimated-vs-recorded table
    oc-cost --by-kind                    # split primary vs subagent sessions
    oc-cost --json                       # machine-readable
    oc-cost --db /path/to/opencode.db    # override OpenCode DB location
    oc-cost --goose-db /path/to/sessions.db  # override Goose DB location
    oc-cost --no-goose                   # skip Goose accounting

`--days` and `--since/--until` are mutually exclusive.

## Two costs: estimated vs recorded

There are two dollar figures for any window, and they are NOT the same:

- **Estimated** — what `oc-cost` computes from token counts using its own
  maintained rate book (`RATES` in `oc_cost.py`). This is the **headline**
  number and the default truth.
- **Recorded** — `SUM($.cost)`, the per-message dollar value OpenCode itself
  wrote at message-creation time. OpenCode derives this from `models.dev`
  pricing, frozen per process, never recomputed.

`oc-cost` defaults to the **estimate** because the recorded value is provably
wrong for at least one high-spend model (see below). The recorded value is
shown alongside, and the **delta is the centerpiece**.

### Why estimate-primary (the headline finding)

`models.dev` incorrectly applies a 2× long-context (>200K) tier to *current-gen*
Claude-on-Vertex models. On the official Google Vertex AI pricing page (cross-
checked against AWS Bedrock and Anthropic first-party), Opus 4.6/4.7/4.8 and
Sonnet 4.6 are **flat** across the full context window — the ≤200K and >200K
rates are identical. `models.dev` read Google's generic "≥200K → long-context
rates" footnote without checking that these rows have matching values on both
sides.

Consequence: OpenCode's recorded `$.cost` for
`google-vertex-anthropic/claude-opus-4-7@default` **over-counts by ~$2,400**
(the requests that exceed 200K input were billed the phantom tier). `oc-cost`'s
flat rate is the correct one here; the DB's recorded cost is wrong. The
reconciliation table flags this automatically.

This is why recorded `$.cost` is not the default truth: the dominant failure
mode is trusting a systematically wrong upstream formula on a high-spend model.

## Rate book

Per-million-token rates live in the `RATES` dict in `oc_cost.py`, keyed by
`(providerID, model base id)` (the `@suffix` is stripped; lookup tries an exact
match, then the longest model-prefix match within the same provider). Update
manually when providers change rates or you start using a new model.

**Source of truth = official provider pricing pages, NOT `models.dev`.**
`models.dev` is only an OpenCode-compatibility snapshot and is wrong about
Vertex Claude tiering (above).

- Anthropic: <https://docs.anthropic.com/en/docs/about-claude/pricing>
- Google (Gemini, Vertex AI): <https://cloud.google.com/vertex-ai/generative-ai/pricing>
- OpenAI: <https://openai.com/api/pricing/>

### Whole-request tier semantics

Each rate entry has base rates and an **optional** `tier`. Tier selection is
**whole-request**, matching how OpenCode bills: for each message,

    context = input + cache.read + cache.write
    if entry has a tier and context >= tier.threshold:
        bill ALL token categories (incl. reasoning, at the output rate) at the tier rates
    else:
        bill at the base rates

The cost is computed per message in Python (SQL can't do per-model thresholds
cleanly) and then aggregated. `tokens.output` excludes reasoning, so billing
reasoning at the output rate does not double-count.

Only **verified** tiers are encoded; everything else is flat:

- **Claude (Anthropic + Vertex), current gen** — flat across the full window.
- **`openai/gpt-5.5`** — real 272K input tier (2× input / 1.5× output). In
  practice we never cross it, so its real-world tier exposure is ~$0.
- **`google-vertex/gemini-3.1-pro-preview`** — real 200K tier, verified against
  the official Google Vertex pricing page.

Gemini Flash is priced under **two** provider ids from one shared definition:
`google-vertex` (cloudbox, macOS) and `google` — the direct Developer API,
which is the only Gemini route devbox has (no ADC, both Vertex providers
disabled) and which `vision-qa` uses. Google lists the same per-1M token prices
for both, so they share `GEMINI_FLASH_PHASES` / `GEMINI_35_FLASH`.

### Unpriced models

Unknown `(provider, model)` pairs have no rate-book entry. Their tokens are
**excluded from the estimated total** (never silently counted as `$0`) and they
are listed separately under "unpriced," with their recorded cost shown for
reference. Some models record `$0` because OpenCode lacked pricing at the time
(e.g. `github-copilot`, `gpt-5.4`).

## Reconciliation

The default report shows an estimated/recorded/net-delta summary line.
`--reconcile` expands the full per-`(provider, model)` table:

| provider/model | msgs | estimated $ | recorded $ | Δ$ | Δ% | flag |
|---|---|---|---|---|---|---|

A row is **flagged** when `abs(Δ$) > $5` **OR** `abs(Δ%) > 5%` (tunable
constants in `oc_cost.py`). Flagging both ways protects us in both directions:
it catches under-counting from stale local rates *and* over-counting from a bad
upstream source (the opus case).

## Goose

`oc-cost` also reads Goose LLM usage when `~/.local/share/goose/sessions/sessions.db` is present (or specified via `--goose-db`). To disable Goose accounting, pass `--no-goose`.

- **Source table**: queries the `usage_ledger` table joined with `sessions` to obtain session providers and parent session relationships.
- **Cache-inclusive input**: Goose records `input_tokens` inclusive of `cache_read_tokens` and `cache_write_tokens`. `oc-cost` calculates uncached input as `max(0, input - cache_read - cache_write)`.
- **Estimate vs ledger cost**: headline cost is calculated from `oc-cost`'s rate book (`RATES`), while Goose's ledger `cost` column is used as the recorded cost in reconciliation.
- **Unrecorded rows**: early Goose records lacked model pricing (`cost` is NULL). These are included in Estimated but excluded from reconciliation Δ (reconciliation compares like with like against `est_cost_recorded`), and surfaced with a note under reconciliation rather than flagged as rate-book drift.
- **Mocks and unknown providers**: test runs with mock providers (e.g. `mock-rolling`) appear as unpriced models (`goose:mock-rolling/...`) and are excluded from estimated totals.
- **Vertex reconciliation**: Goose on cloudbox reaches GCP Vertex AI through the same failover proxy as OpenCode, so its calls appear in the same audit log; `--vertex-reconcile` counts Goose Vertex calls alongside OpenCode calls under the mapped rate provider.
- **Imported sessions**: Goose's import_session copies accumulated totals, so the first call in a continued imported session writes a null-model `carried_forward` ledger row with the whole imported history, timestamped at that call; it is unpriced (no dollar effect) but its tokens land in that day's daily row and the 300k+ size bucket.

## Caveats

- **Gemini cache storage** is invisible to this tool. Google bills Gemini cache
  CREATION at the input rate (modelled correctly) AND a separate token-hour
  STORAGE fee for as long as the cache lives. oc-cost's schema only captures
  per-token rates, so reported Gemini cache cost is an UNDERCOUNT for long-lived
  caches.
- **Regional/multi-region Vertex endpoints** carry a flat +10% premium over the
  Global endpoint. The rate book assumes Global; add a region dimension to the
  key if that changes.
- **No rate-book effective-dating.** Rates are current as of the last manual
  edit; a mid-window provider price change is not modelled.
- **No live pricing API calls** — the rate book is a static, offline table by
  design.

## Design

See:
- `docs/plans/2026-06-01-oc-cost-tier-reconciliation-design.md` (current:
  tier-aware estimation + reconciliation)
- `docs/plans/2026-04-20-oc-cost-design.md` (original)
