# oc-cost Tier-Aware Estimation + Reconciliation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `oc-cost`'s cost number an own-rate-book *estimate* that is per-request tier-aware, and add a recorded-vs-estimated *reconciliation* section that flags pricing discrepancies (e.g. OpenCode's models.dev-driven ~$2.4K over-count on Vertex opus).

**Architecture:** Replace the flat `PRICES` table with a `RATES` rate book keyed by `(providerID, model)` with an optional whole-request `tier`. Compute cost **per message** (messages are single-step, so message-level `input+cache.read+cache.write` is the request context), then aggregate. Add a reconciliation layer that sums OpenCode's recorded `$.cost` per `(provider, model)` and reports the delta. Estimate is the headline; recorded is shown alongside; unpriced models are visible, never silently $0.

**Tech Stack:** Python 3 stdlib (`sqlite3`, `argparse`, `unittest`), packaged via Nix (`pkgs/oc-cost/default.nix`). No new dependencies.

**Design doc:** `docs/plans/2026-06-01-oc-cost-tier-reconciliation-design.md`

**Working dir:** `pkgs/oc-cost/`. **Test command (from repo root):** `cd pkgs/oc-cost && python3 -m unittest test_oc_cost -v`. Baseline: 41 tests passing.

**Branch:** `oc-cost-tier-reconcile` (already created; design doc already committed here).

---

## Task 0: Pre-build verifications (no code; resolves design open items)

These three checks gate rate-book contents and the single-step assumption. Record outcomes in commit messages / as comments; they change only data, not structure.

**Step 0.1 — Single-step assumption (gates message-level granularity).**
Run (sqlite via `nix run nixpkgs#sqlite --`):
```sql
SELECT json_extract(m.data,'$.providerID') provider, json_extract(m.data,'$.modelID') model,
       COUNT(DISTINCT m.id) msgs,
       SUM(CASE WHEN json_extract(p.data,'$.type')='step-finish' THEN 1 ELSE 0 END) sf_parts
FROM message m JOIN part p ON p.message_id=m.id
WHERE json_extract(m.data,'$.role')='assistant'
GROUP BY provider, model HAVING msgs > 100 ORDER BY msgs DESC;
```
Expected: `sf_parts ≈ msgs` for all material models. **If any model has `sf_parts` ≫ `msgs`**, that model is multi-step → note it; for that model the estimator must aggregate `step-finish` parts instead of the message row (escalation, see Task 2 note). Default assumption: all single-step → stay message-level.

**Step 0.2 — Verify gemini-3.1-pro-preview's 200K tier is real** (it's the only tier we actually cross). Check Google's official Gemini pricing page (provider `google-vertex`, model `gemini-3.1-pro-preview`): does input context >200K change rates? Outcome:
- If real: encode the tier in Task 1's RATES.
- If it's the same models.dev parsing artifact (flat in reality): encode flat, add a comment.

**Step 0.3 — Confirm our Vertex endpoint is Global** (else rates carry +10%). Quick check: do recorded under-200K opus part costs match Global base ($5/$25) exactly? (We already saw `1.3445 == flat@$5/$25`, i.e. Global. Confirm no regional uplift.) If regional: bump the Vertex base rates by 10% in RATES and note it.

**Commit:** none (no code). Capture decisions in Task 1's commit message.

---

## Task 1: Rate book + per-message tier-aware cost function

**Files:**
- Modify: `pkgs/oc-cost/oc_cost.py` (replace `PRICES`/`price_for` with `RATES`/`rate_for`/`cost_for_message`)
- Test: `pkgs/oc-cost/test_oc_cost.py`

**Step 1.1 — Write failing tests.** Add a new test class:

```python
class TestRateBookAndCostForMessage(unittest.TestCase):
    def test_rate_for_provider_model(self):
        e = oc_cost.rate_for("openai", "gpt-5.5")
        self.assertIsNotNone(e)
        self.assertEqual(e["input"], 5.0)
        self.assertEqual(e["tier"]["threshold"], 272000)

    def test_rate_for_strips_at_suffix(self):
        e = oc_cost.rate_for("google-vertex-anthropic", "claude-opus-4-7@default")
        self.assertIsNotNone(e)
        self.assertEqual(e["input"], 5.0)
        self.assertNotIn("tier", e)  # Vertex current-gen opus is FLAT

    def test_rate_for_unknown_returns_none(self):
        self.assertIsNone(oc_cost.rate_for("openai", "totally-unknown"))

    def test_flat_model_ignores_huge_context(self):
        # opus is flat: 1M cache_read at $0.50 regardless of context size
        toks = {"input": 0, "output": 0, "reasoning": 0,
                "cache": {"read": 1_000_000, "write": 0}}
        cost, tier = oc_cost.cost_for_message("google-vertex-anthropic",
                                              "claude-opus-4-7@default", toks)
        self.assertAlmostEqual(cost, 0.50, places=6)
        self.assertEqual(tier, "base")

    def test_gpt55_under_threshold_uses_base(self):
        # context = input + cache.read + cache.write = 271999 (< 272000)
        toks = {"input": 271999, "output": 0, "reasoning": 0,
                "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message("openai", "gpt-5.5", toks)
        self.assertAlmostEqual(cost, 271999 * 5.0 / 1e6, places=9)
        self.assertEqual(tier, "base")

    def test_gpt55_over_threshold_uses_tier_for_whole_request(self):
        # context = 272001 (>= 272000): ALL tokens at tier rates
        toks = {"input": 272001, "output": 1000, "reasoning": 500,
                "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message("openai", "gpt-5.5", toks)
        expected = (272001 * 10.0 + (1000 + 500) * 45.0) / 1e6
        self.assertAlmostEqual(cost, expected, places=9)
        self.assertEqual(tier, "long_context")

    def test_reasoning_billed_at_output_rate(self):
        toks = {"input": 0, "output": 1_000_000, "reasoning": 1_000_000,
                "cache": {"read": 0, "write": 0}}
        cost, _ = oc_cost.cost_for_message("openai", "gpt-5.5", toks)
        self.assertAlmostEqual(cost, 60.0, places=6)  # 2M * $30/M base

    def test_unknown_model_cost_is_none(self):
        toks = {"input": 100, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message("openai", "nope", toks)
        self.assertIsNone(cost)
        self.assertEqual(tier, "unpriced")
```

**Step 1.2 — Run, expect failure.** `cd pkgs/oc-cost && python3 -m unittest test_oc_cost.TestRateBookAndCostForMessage -v` → FAIL (`rate_for`/`cost_for_message` undefined).

**Step 1.3 — Implement.** In `oc_cost.py`, replace the `PRICES` dict and `price_for` with:

```python
# Per-million-token rates in USD, keyed by (providerID, model base id).
# Source of truth = official provider pricing pages (NOT models.dev, which
# wrongly tiers current-gen Vertex Claude). "tier" is optional; when present
# it is a WHOLE-REQUEST long-context tier applied to all token categories once
# context (input + cache.read + cache.write) >= threshold.
RATES: dict[tuple[str, str], dict] = {
    # --- Anthropic Claude: FLAT across full context (Anthropic + Vertex + Bedrock,
    #     current gen). models.dev's >200K Vertex tier is a parsing artifact. ---
    ("anthropic", "claude-opus-4-7"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-opus-4-8"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-opus-4-6"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-sonnet-4-6"):            {"input": 3, "output": 15, "cache_read": 0.30, "cache_write": 3.75},
    ("google-vertex-anthropic", "claude-opus-4-7"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-opus-4-8"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-opus-4-6"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-sonnet-4-6"): {"input": 3, "output": 15, "cache_read": 0.30, "cache_write": 3.75},
    # --- Google Gemini (Vertex) ---
    ("google-vertex", "gemini-3.5-flash"):  {"input": 1.5, "output": 9, "cache_read": 0.15, "cache_write": 1.5},
    # gemini-3.1-pro-preview: 200K tier per Task 0.2 outcome. If VERIFIED real:
    ("google-vertex", "gemini-3.1-pro-preview"): {
        "input": 2, "output": 12, "cache_read": 0.20, "cache_write": 2,
        "tier": {"threshold": 200000, "input": 4, "output": 18, "cache_read": 0.40, "cache_write": 4},
    },
    # --- OpenAI ---
    ("openai", "gpt-5.5"): {
        "input": 5, "output": 30, "cache_read": 0.50, "cache_write": 0,
        "tier": {"threshold": 272000, "input": 10, "output": 45, "cache_read": 1, "cache_write": 0},
    },
}


def rate_for(provider: str, model_id: str) -> Optional[dict]:
    """Look up a rate-book entry for (provider, model). Strips @suffix, tries
    exact match, then longest-prefix match on the model component within the
    same provider. Returns None if unknown."""
    base = model_id.split("@", 1)[0]
    if (provider, base) in RATES:
        return RATES[(provider, base)]
    best: Optional[tuple[str, str]] = None
    for (prov, key) in RATES:
        if prov == provider and base.startswith(key):
            if best is None or len(key) > len(best[1]):
                best = (prov, key)
    return RATES[best] if best else None


def cost_for_message(provider: str, model_id: str, tokens: dict) -> tuple[Optional[float], str]:
    """Return (cost_usd, tier_label) for one request. tier_label is one of
    'base' | 'long_context' | 'unpriced'. cost is None when unpriced.
    Whole-request tier selection: context = input + cache.read + cache.write."""
    entry = rate_for(provider, model_id)
    if entry is None:
        return None, "unpriced"
    inp = tokens.get("input", 0) or 0
    out = tokens.get("output", 0) or 0
    reasoning = tokens.get("reasoning", 0) or 0
    cache = tokens.get("cache", {}) or {}
    cr = cache.get("read", 0) or 0
    cw = cache.get("write", 0) or 0
    context = inp + cr + cw
    tier = entry.get("tier")
    if tier and context >= tier["threshold"]:
        r, label = tier, "long_context"
    else:
        r, label = entry, "base"
    cost = (inp * r["input"] + out * r["output"] + reasoning * r["output"]
            + cr * r["cache_read"] + cw * r["cache_write"]) / 1_000_000
    return cost, label
```

**Step 1.4 — Migrate old tests.** The old `TestPriceFor` and the `price_for`-based assertions are obsolete. Replace `TestPriceFor` with the new class (Step 1.1). Keep the longest-prefix invariant as a test inside the new class (adapt `test_longest_prefix_wins...` to `rate_for` with a monkeypatched `RATES`). Update `TestCostComponents` in Task 2 (it depends on the aggregation refactor).

**Step 1.5 — Run.** `python3 -m unittest test_oc_cost.TestRateBookAndCostForMessage -v` → PASS.

**Step 1.6 — Commit.**
```bash
git add pkgs/oc-cost/oc_cost.py pkgs/oc-cost/test_oc_cost.py
git commit -m "feat(oc-cost): rate book keyed by (provider,model) with per-request tier logic

Replaces flat PRICES with RATES; whole-request long-context tier selection.
Records Task 0 verification outcomes: Vertex current-gen Claude FLAT (Global);
gpt-5.5 272K tier; gemini-3.1-pro 200K tier <real|artifact per 0.2>."
```

---

## Task 2: Per-message estimation aggregation

**Files:** Modify `oc_cost.py`; Test `test_oc_cost.py`.

**Step 2.1 — Failing test.** Add `TestEstimate`:

```python
class TestEstimate(unittest.TestCase):
    def test_aggregates_estimated_cost_per_provider_model(self):
        d0 = 1800000000000
        msgs = [
            assistant_msg("m1", "s1", d0+1, model="claude-opus-4-7@default",
                          provider="google-vertex-anthropic", cache_read=1_000_000),  # $0.50
            assistant_msg("m2", "s1", d0+2, model="gpt-5.5", provider="openai",
                          inp=272001, out=0),  # over 272k -> $2.72001
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_message_rows(conn, d0, d0 + DAY_MS)
        est = oc_cost.estimate(rows)
        by = {(r["provider"], r["model"]): r for r in est["by_model"]}
        self.assertAlmostEqual(by[("google-vertex-anthropic", "claude-opus-4-7@default")]["est_cost"], 0.50, places=6)
        self.assertAlmostEqual(by[("openai", "gpt-5.5")]["est_cost"], 272001*10.0/1e6, places=9)

    def test_unpriced_excluded_from_total_and_listed(self):
        d0 = 1800000000000
        msgs = [assistant_msg("m1","s1",d0+1, model="mystery", provider="weird", cache_read=1_000_000)]
        conn = make_test_db(msgs)
        est = oc_cost.estimate(oc_cost.query_message_rows(conn, d0, d0+DAY_MS))
        self.assertEqual(est["total_est"], 0.0)
        self.assertIn(("weird", "mystery"), est["unpriced"])
```

Note: `assistant_msg` must learn a `reasoning` kwarg and the `query_message_rows` reads provider/model/tokens/recorded cost per message. Extend the `assistant_msg` helper to accept `reasoning=0` and to include `cost` in the data (default 0).

**Step 2.2 — Run, expect FAIL.**

**Step 2.3 — Implement** `query_message_rows` (per-message rows incl. `recorded_cost = json_extract(data,'$.cost')`, provider, model, day, token fields) and `estimate(rows)` which loops calling `cost_for_message`, aggregating per `(provider, model)`: msgs, token volumes, `est_cost`, `recorded_cost` (sum), and a tier-count. Track `unpriced` set and `total_est` (priced only). Keep `query_daily` and `query_size_buckets` as-is for the volume/% and bucket sections.

**Step 2.4 — Run → PASS.**

**Step 2.5 — Retire/replace `compute_cost_components`** so the headline cost is `estimate()`-derived (per-request tier-aware), not the old flat per-model sum. Update `TestCostComponents` tests accordingly (or replace with `TestEstimate` equivalents). Remove now-dead `query_by_model_and_kind`/`compute_cost_components` flat-rate cost paths only if fully superseded; keep `--by-kind` working by routing its cost through `estimate()` per kind.

**Step 2.6 — Commit** (`feat(oc-cost): per-request tier-aware estimation aggregation`).

---

## Task 3: Reconciliation (estimated vs recorded)

**Files:** Modify `oc_cost.py`; Test `test_oc_cost.py`.

**Step 3.1 — Failing test.** `TestReconcile`:

```python
class TestReconcile(unittest.TestCase):
    def test_flags_material_delta(self):
        # estimated $5.00, recorded $7.43 -> delta +$2.43, ~48% -> flagged
        by_model = [{"provider": "google-vertex-anthropic", "model": "claude-opus-4-7@default",
                     "msgs": 10, "est_cost": 5.00, "recorded_cost": 7.43}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        row = rec["rows"][0]
        self.assertAlmostEqual(row["delta"], 2.43, places=2)
        self.assertTrue(row["flagged"])  # 48% > 5%

    def test_small_delta_not_flagged(self):
        by_model = [{"provider":"openai","model":"gpt-5.5","msgs":5,"est_cost":100.0,"recorded_cost":101.0}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        self.assertFalse(rec["rows"][0]["flagged"])  # 1% and $1 both under thresholds
```

**Step 3.2 — Run → FAIL. Step 3.3 — Implement** `reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)`: per row compute `delta = recorded - est`, `delta_pct`, `flagged = abs(delta) > usd_threshold and abs(delta_pct) > pct_threshold` (both, to avoid flagging tiny-but-high-% rows); return rows + totals. **Step 3.4 — Run → PASS. Step 3.5 — Commit.**

---

## Task 4: Rendering + CLI wiring

**Files:** Modify `oc_cost.py`; Test `test_oc_cost.py`.

**Step 4.1 — Failing tests** for: (a) `render_json` includes a `reconciliation` key and `by_model` rows carry `est_cost`/`recorded_cost`; (b) `parse_args(["--reconcile"])` sets `args.reconcile = True`.

**Step 4.2 — Run → FAIL. Step 4.3 — Implement:**
- Add `--reconcile` flag (default False) to `parse_args`.
- `main()`: build `rows = query_message_rows(...)`, `est = estimate(rows)`, `rec = reconcile(est["by_model"])`; put `est`, `reconciliation` into `report`.
- `render_text`: headline cost from `est["total_est"]`; always print a reconciliation **summary** line (`estimated $X | recorded $Y | Δ $Z`); when `--reconcile`, print the per-`(provider,model)` table with Δ/Δ%/flag and a separate **"Unpriced (excluded from estimate)"** list. Keep daily and size-bucket sections.
- `render_json`: add `reconciliation` and the unpriced list; keep existing keys (update `TestRenderJson` schema test).

**Step 4.4 — Run → PASS. Step 4.5 — Commit.**

---

## Task 5: Full suite, real-DB smoke test, docs

**Step 5.1 — Full unit suite green:** `cd pkgs/oc-cost && python3 -m unittest test_oc_cost -v` → all PASS (no leftover references to `PRICES`/`price_for`/`compute_cost_components` if removed).

**Step 5.2 — Real-DB smoke test (read-only):**
```bash
python3 pkgs/oc-cost/oc_cost.py --since 2026-05-01 --reconcile
```
Expected: runs without error; the reconciliation table **flags `google-vertex-anthropic/claude-opus-4-7@default`** (recorded ≫ estimated, the models.dev phantom tier) and **lists unpriced models** (`github-copilot`, `gpt-5.4`, `gpt-5.3-codex`). Sanity-check estimated opus ≈ flat (no phantom tier).

**Step 5.3 — Nix build check:** `nix build --no-link .#... ` (oc-cost package) OR `nix run nixpkgs#python3 -- -m py_compile pkgs/oc-cost/oc_cost.py`. Confirm it still packages (pure stdlib, `default.nix` unchanged).

**Step 5.4 — Update `pkgs/oc-cost/README.md`:** document the rate book (provider+model keyed, official-page sourced), the tier semantics (whole-request), the reconciliation section + `--reconcile`, and the known finding that OpenCode's recorded `$.cost` over-counts Vertex opus via a models.dev tiering error.

**Step 5.5 — Commit** (`docs(oc-cost): document reconciliation + rate book provenance`).

---

## Execution notes / guardrails
- TDD throughout: failing test → run-fail → implement → run-pass → commit.
- Do NOT mutate the DB (read-only `mode=ro` already enforced in `connect`).
- Keep unpriced models visible; never fold "unknown" into $0.
- Defer (YAGNI, note only): region (+10%) dimension, rate-book effective-dating, part-level estimation (unless Task 0.1 finds a multi-step material model).
- If Task 0.2 finds gemini-3.1-pro is actually flat, drop its `tier` block (encode flat) — the only behavioral consequence is ~$6.
