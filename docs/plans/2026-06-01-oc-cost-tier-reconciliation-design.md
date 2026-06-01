# oc-cost: tier-aware estimation + recorded-vs-estimated reconciliation

**Date:** 2026-06-01
**Status:** Design (approved, pre-implementation)
**Component:** `pkgs/oc-cost/` (Python CLI that reports OpenCode usage/cost from the local SQLite DB)

## 1. Background & motivation

The investigation that prompted this started as "include long-context (tiered) pricing in our
usage analysis." It uncovered that the real problem is different from — and more valuable than —
what we set out to fix.

### How cost flows in OpenCode

- OpenCode logs each assistant message to `~/.local/share/opencode/opencode.db`, table `message`,
  JSON `data` column. Tokens live under `$.tokens.{input,output,reasoning,cache.read,cache.write}`
  and a computed dollar cost under `$.cost`.
- OpenCode computes `$.cost` per `step-finish` part using a **whole-request tier selection**:
  `contextTokens = input + cache.read + cache.write`; if it exceeds a model's tier threshold, the
  higher rate set is applied to *all* token categories (reasoning billed at the output rate). Source:
  `packages/opencode/src/session/session.ts` (`getUsage`).
- Pricing comes from `models.dev` (`https://models.dev/api.json`), cached on disk, frozen into a
  per-instance provider catalog at process start. `$.cost` is written once at message-creation time
  and never recomputed.
- `oc-cost` today **ignores `$.cost`** and instead recomputes from token counts using its own
  hardcoded **flat** per-MTok rate table (`PRICES`), summing tokens per model and multiplying once.

### Verified findings (the reframe)

1. **Whole-request, not marginal billing** for long-context tiers — confirmed for OpenAI gpt-5.x
   (">272K input → 2× input, 1.5× output for the full session") and Vertex Claude ("if input
   context ≥200K, all tokens charged at long-context rates"). OpenCode's model is correct.
2. **Threshold = input/prompt tokens incl. cached** (not output, not reasoning).
3. **Provider split, and models.dev is wrong about it.** Authoritative check (Google Cloud Vertex AI
   pricing page, cross-checked against AWS Bedrock and Anthropic first-party):
   - Current-gen Claude (**Opus 4.6/4.7/4.8, Sonnet 4.6**) is **FLAT** across the full context window
     on Vertex AI (identical rates ≤200K and >200K), on Bedrock, and on direct Anthropic.
   - Only **older** models (e.g. Sonnet 4.5) still carry the >200K premium (2× in / 1.5× out).
   - **models.dev incorrectly applies a 2× tier to all Claude-on-Vertex models** — it read Google's
     generic "≥200K → long-context rates" footnote and didn't check that current-gen rows have
     matching flat values on both sides.
4. **Consequence:** OpenCode's recorded `$.cost` for `google-vertex-anthropic/claude-opus-4-7@default`
   **over-counts by ~$2,433** (17.3% of its ~24.6K requests exceed 200K and were billed the phantom
   tier in the recorded number). Our flat `oc-cost` was actually *correct* for opus; the DB's
   recorded cost is the wrong one.
5. **Real tier exposure we actually incur is ~$0–$6:** gpt-5.5 has a genuine 272K tier but we never
   cross it (max observed context 271,547); gemini-3.1-pro-preview crosses 0.6% of the time (~$6, and
   its tier should itself be re-verified — possibly the same models.dev artifact); everything else is
   flat.
6. **Messages are effectively single-step** (`step-finish` parts ≈ assistant messages), so per-request
   context size is available at message granularity.
7. Some models record `$0` because OpenCode lacked pricing at the time (we fixed + backfilled
   gpt-5.5; `github-copilot`, `gpt-5.4`, `gpt-5.3-codex` still show `$0`).

### Conclusion that drives the design

The valuable artifact is not "tier math" (worth ~$6) but a **reconciliation** between our own
rate-book estimate and OpenCode's recorded `$.cost`. Reconciliation protects us **both ways**: it
catches under-counting from stale local rates *and* over-counting from a bad upstream source (the
opus case). Strategic advice (oracle): **do not make recorded `$.cost` the default truth** — the
dominant failure mode is trusting a systematically wrong upstream formula on a high-spend model.
Default to our own estimate; show recorded alongside; make the delta the centerpiece.

## 2. Goals / non-goals

**Goals**
- Headline cost = our own **estimate** from a maintained rate book (already mostly correct).
- **Reconciliation** section: estimated vs recorded `SUM($.cost)` per `(provider, model)`, with delta,
  delta%, and a prominent flag when the gap is material.
- Estimation is **per-request tier-aware** (whole-request selection), but only **verified** tiers are
  encoded; everything else is flat.
- **Unpriced** `(provider, model)` pairs are marked "unknown" and never silently counted as `$0`.

**Non-goals**
- No live pricing API calls (offline static rate book).
- No multi-basis FinOps vocabulary (`--basis actual|recorded|reprice`) — over-engineered for a
  single-user tool.
- No rate-book effective-dating yet (note as future escalation if rates change mid-window).
- No part-table refactor unless the pre-build check finds material multi-step models.
- Do **not** patch OpenCode; do **not** backfill/"fix" the inflated opus `$.cost` in the DB.
  Reconciliation merely reports it.

## 3. Design

### 3.1 Source & granularity
Continue reading the `message` table. Message-level `input + cache.read + cache.write` is the
per-request context because messages are single-step.

**Pre-build verification (gate):** confirm globally that no material (nonzero-cost) model has
`step-finish` parts ≫ messages. If one does, escalate just that model to part-level; otherwise stay
message-level.

### 3.2 Rate book (replaces flat `PRICES`)
Keyed by `(providerID, model)` (strip `@suffix`; exact then longest-prefix match). Each entry has base
rates and an **optional** `tier`:

```python
RATES = {
  ("google-vertex-anthropic", "claude-opus-4-7"):
      {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25},        # FLAT (verified)
  ("google-vertex-anthropic", "claude-opus-4-8"):
      {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25},        # FLAT (verified)
  ("google-vertex-anthropic", "claude-sonnet-4-6"):
      {"input": 3, "output": 15, "cache_read": 0.3, "cache_write": 3.75},        # FLAT (verified)
  ("anthropic", "claude-opus-4-7"):
      {"input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25},        # FLAT (verified)
  ("google-vertex", "gemini-3.5-flash"):
      {"input": 1.5, "output": 9, "cache_read": 0.15, "cache_write": 1.5},       # FLAT
  ("openai", "gpt-5.5"):
      {"input": 5, "output": 30, "cache_read": 0.5, "cache_write": 0,
       "tier": {"threshold": 272000, "input": 10, "output": 45,
                "cache_read": 1, "cache_write": 0}},                              # tier verified (OpenAI)
  # gemini-3.1-pro-preview: models.dev shows a 200K tier; VERIFY before encoding
  #   (could be the same models.dev parsing artifact). Until verified: encode FLAT base +
  #   leave a comment, OR encode the tier with a "needs-verification" note.
}
```
Notes:
- Regional/multi-region Vertex endpoints carry a flat +10% premium. Out of scope for v1 unless the
  pre-build check shows our traffic isn't Global; if so, add a region dimension to the key.
- Unknown pairs → `None` rate → model listed under "unpriced," excluded from the estimated total,
  shown in reconciliation.

### 3.3 Tier-aware estimation (per request, then aggregate)
```python
context = input + cache_read + cache_write
r = entry["tier"] if entry.get("tier") and context >= entry["tier"]["threshold"] else entry
cost = (input*r["input"] + output*r["output"] + reasoning*r["output"]
        + cache_read*r["cache_read"] + cache_write*r["cache_write"]) / 1e6
```
Computed per message in Python (SQL can't do per-model thresholds cleanly), aggregated to
model/day/kind. Reasoning at the output rate; `tokens.output` excludes reasoning (verified) so no
double-count.

### 3.4 Reconciliation (centerpiece)
New default section, per `(provider, model)`:

| provider/model | msgs | estimated $ | recorded $ | Δ$ | Δ% | flag |
|---|---|---|---|---|---|---|

- Flag when `abs(delta_pct) > 5%` OR `abs(delta_usd) > $5` (tunable constants).
- Separate **"unpriced / unknown"** list: recorded shown, estimated = n/a, with a clear caveat that
  these are excluded from the estimated total.
- A summary line: estimated total, recorded total, net delta.
- Expected real output: opus flagged (recorded ≫ estimated, models.dev phantom tier); unpriced
  models (`github-copilot`, `gpt-5.4`, `gpt-5.3-codex`) listed.

### 3.5 CLI surface (minimal)
- Default report: headline = estimated; reconciliation summary line always shown.
- `--reconcile`: expand the full per-model (optionally per-month) recorded-vs-estimated table.
- Everything else unchanged (`--days/--since/--until/--json/--by-kind/--db`).

## 4. Testing
Extend `test_oc_cost.py`:
- Tier selection just-under vs just-over threshold (gpt-5.5 at 271,999 vs 272,001).
- Flat model ignores context (large context → base rates).
- Reconciliation delta math (estimated vs recorded), flag threshold boundaries.
- Unpriced model: excluded from estimated total, listed, recorded still shown.
- Provider+model keying: `anthropic/claude-opus-4-7` vs `google-vertex-anthropic/claude-opus-4-7`
  resolve independently.

## 5. Open items before/while implementing
1. **Verify gemini-3.1-pro-preview's 200K tier** (real, or another models.dev artifact?). Cheap.
2. **Pre-build single-step check** (parts ≈ messages for all nonzero-cost models).
3. **Confirm our Vertex endpoint is Global** (else add the +10% region dimension).
4. Tunable flag thresholds (5% / $5) — adjust after first real run.

## 6. Rationale for key choices
- **Estimate-primary, not recorded-primary:** recorded `$.cost` is an OpenCode implementation
  artifact at message time, provably wrong for opus; weak as default truth under pricing-source
  conflict. (oracle)
- **Reconciliation as centerpiece:** the real uncertainty is pricing correctness, not SQL; the delta
  view is the protection. (oracle)
- **Small rate book, visible unknowns:** YAGNI line — enough to cover material spend, never silently
  zero. (oracle)
- **models.dev is not authoritative:** use official provider pages for the rate book; models.dev is
  only an OpenCode-compatibility snapshot. (librarian + ChatGPT)
