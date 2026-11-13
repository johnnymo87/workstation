"""Tests for oc-cost. Run: python3 -m unittest pkgs/oc-cost/test_oc_cost.py"""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
import json
import sqlite3

# Allow `import oc_cost` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_cost  # noqa: E402

# main() defaults to the real goose DB; no test may read it.
oc_cost._DEFAULT_GOOSE_DB = "/nonexistent/path/to/goose.db"


class TestParseArgs(unittest.TestCase):
    def test_defaults(self):
        args = oc_cost.parse_args([])
        self.assertEqual(args.days, 14)
        self.assertIsNone(args.since)
        self.assertIsNone(args.until)
        self.assertFalse(args.json)
        self.assertIsNone(args.db)

    def test_days(self):
        args = oc_cost.parse_args(["--days", "30"])
        self.assertEqual(args.days, 30)

    def test_days_must_be_positive(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "0"])
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "-1"])

    def test_since_until(self):
        args = oc_cost.parse_args(["--since", "2026-04-01", "--until", "2026-04-15"])
        self.assertEqual(args.since, "2026-04-01")
        self.assertEqual(args.until, "2026-04-15")

    def test_days_mutex_with_since(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "7", "--since", "2026-04-01"])

    def test_days_mutex_with_until(self):
        with self.assertRaises(SystemExit):
            oc_cost.parse_args(["--days", "7", "--until", "2026-04-15"])

    def test_json_flag(self):
        args = oc_cost.parse_args(["--json"])
        self.assertTrue(args.json)

    def test_db_path(self):
        args = oc_cost.parse_args(["--db", "/tmp/x.db"])
        self.assertEqual(args.db, "/tmp/x.db")


class TestResolveWindow(unittest.TestCase):
    # Pinned "now" for deterministic tests: 2026-04-20T12:00:00Z
    NOW_MS = 1776686400000  # see: date -u -d "2026-04-20T12:00:00Z" +%s%3N

    def test_days_default(self):
        args = oc_cost.parse_args([])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(end, self.NOW_MS)
        self.assertEqual(start, self.NOW_MS - 14 * 86_400_000)

    def test_days_custom(self):
        args = oc_cost.parse_args(["--days", "7"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(end - start, 7 * 86_400_000)

    def test_since_only(self):
        args = oc_cost.parse_args(["--since", "2026-04-01"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        # 2026-04-01T00:00:00Z = 1775001600000
        self.assertEqual(start, 1775001600000)
        self.assertEqual(end, self.NOW_MS)

    def test_since_and_until(self):
        args = oc_cost.parse_args(["--since", "2026-04-01", "--until", "2026-04-15"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(start, 1775001600000)            # 2026-04-01
        # --until is *exclusive* end-of-day: 2026-04-16T00:00:00Z
        self.assertEqual(end, 1775001600000 + 15 * 86_400_000)

    def test_until_only(self):
        args = oc_cost.parse_args(["--until", "2026-04-15"])
        start, end = oc_cost.resolve_window(args, self.NOW_MS)
        self.assertEqual(start, 0)
        self.assertEqual(end, 1775001600000 + 15 * 86_400_000)  # 2026-04-16T00:00:00Z

    def test_malformed_since(self):
        args = oc_cost.parse_args(["--since", "not-a-date"])
        with self.assertRaises(ValueError):
            oc_cost.resolve_window(args, self.NOW_MS)



def make_test_db(messages: list[dict], sessions: list[dict] | None = None) -> sqlite3.Connection:
    """Build an in-memory SQLite DB matching opencode.db's schema.

    Each `messages` dict needs keys: id, session_id, time_created (ms),
    and message-data fields (role, modelID, providerID, tokens). We wrap
    the message-data fields into a JSON string for the `data` column.

    If `sessions` is provided, also create a `session` table populated
    with those rows (each must have `id`, `parent_id` keys; parent_id
    may be None for primary sessions). When `sessions` is None, no
    session table is created -- callers exercising query_by_kind must
    pass sessions explicitly.
    """
    conn = sqlite3.connect(":memory:")
    conn.execute(
        """
        CREATE TABLE message (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            time_created integer NOT NULL,
            time_updated integer NOT NULL,
            data text NOT NULL
        )
        """
    )
    if sessions is not None:
        conn.execute(
            """
            CREATE TABLE session (
                id text PRIMARY KEY,
                parent_id text
            )
            """
        )
        for s in sessions:
            conn.execute(
                "INSERT INTO session (id, parent_id) VALUES (?, ?)",
                (s["id"], s.get("parent_id")),
            )
    for m in messages:
        data = {k: v for k, v in m.items() if k not in ("id", "session_id", "time_created")}
        conn.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) "
            "VALUES (?, ?, ?, ?, ?)",
            (m["id"], m["session_id"], m["time_created"], m["time_created"], json.dumps(data)),
        )
    conn.commit()
    conn.row_factory = sqlite3.Row
    return conn


def assistant_msg(
    msg_id: str,
    session_id: str,
    time_ms: int,
    model: str = "claude-opus-4-6",
    provider: str = "anthropic",
    cache_read: int = 0,
    cache_write: int = 0,
    inp: int = 0,
    out: int = 0,
    reasoning: int = 0,
    cost: float = 0.0,
) -> dict:
    return {
        "id": msg_id,
        "session_id": session_id,
        "time_created": time_ms,
        "role": "assistant",
        "modelID": model,
        "providerID": provider,
        "cost": cost,
        "tokens": {
            "input": inp,
            "output": out,
            "reasoning": reasoning,
            "cache": {"read": cache_read, "write": cache_write},
        },
    }


DAY_MS = 86_400_000


class TestQueryDaily(unittest.TestCase):
    def test_groups_by_day_and_sums_tokens(self):
        # Three messages on day 0, one on day 1.
        d0 = 1800000000000  # arbitrary base
        msgs = [
            assistant_msg("m1", "s1", d0 + 1000, cache_read=100, cache_write=10, inp=5, out=20),
            assistant_msg("m2", "s1", d0 + 2000, cache_read=200, cache_write=20, inp=5, out=40),
            assistant_msg("m3", "s2", d0 + 3000, cache_read=300, cache_write=30, inp=5, out=60),
            assistant_msg("m4", "s1", d0 + DAY_MS + 1000, cache_read=50, cache_write=5, inp=1, out=10),
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_daily(conn, d0, d0 + 2 * DAY_MS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["msgs"], 3)
        self.assertEqual(rows[0]["cache_read"], 600)
        self.assertEqual(rows[0]["cache_write"], 60)
        self.assertEqual(rows[0]["uncached"], 15)
        self.assertEqual(rows[0]["output"], 120)
        self.assertEqual(rows[1]["msgs"], 1)

    def test_excludes_messages_without_cache_read(self):
        d0 = 1800000000000
        good = assistant_msg("m1", "s1", d0 + 1000, cache_read=100, inp=5, out=20)
        # User message; should be filtered by role.
        user = {
            "id": "u1", "session_id": "s1", "time_created": d0 + 1500,
            "role": "user", "tokens": {"input": 0, "output": 0, "cache": {"read": 0}},
        }
        # Assistant but no cache.read field — non-Anthropic provider.
        no_cache = {
            "id": "m2", "session_id": "s1", "time_created": d0 + 2000,
            "role": "assistant", "modelID": "gpt-5", "providerID": "openai",
            "tokens": {"input": 100, "output": 50},  # no cache key
        }
        conn = make_test_db([good, user, no_cache])
        rows = oc_cost.query_daily(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["msgs"], 1)

    def test_filters_by_window(self):
        d0 = 1800000000000
        before = assistant_msg("m0", "s1", d0 - 1000, cache_read=999)
        inside = assistant_msg("m1", "s1", d0 + 1000, cache_read=100, inp=5)
        after = assistant_msg("m2", "s1", d0 + DAY_MS + 1, cache_read=999)
        conn = make_test_db([before, inside, after])
        rows = oc_cost.query_daily(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["cache_read"], 100)


class TestQuerySizeBuckets(unittest.TestCase):
    def test_buckets(self):
        d0 = 1800000000000
        # prompt_size = cache_read + cache_write + input
        msgs = [
            assistant_msg("a", "s", d0 + 1, cache_read=10_000),    # 0-50k
            assistant_msg("b", "s", d0 + 2, cache_read=60_000),    # 50-100k
            assistant_msg("c", "s", d0 + 3, cache_read=120_000),   # 100-150k
            assistant_msg("d", "s", d0 + 4, cache_read=180_000),   # 150-200k
            assistant_msg("e", "s", d0 + 5, cache_read=250_000),   # 200-300k
            assistant_msg("f", "s", d0 + 6, cache_read=400_000),   # 300k+
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_size_buckets(conn, d0, d0 + DAY_MS)
        buckets = {r["bucket"]: r["msgs"] for r in rows}
        self.assertEqual(buckets["0-50k"], 1)
        self.assertEqual(buckets["50-100k"], 1)
        self.assertEqual(buckets["100-150k"], 1)
        self.assertEqual(buckets["150-200k"], 1)
        self.assertEqual(buckets["200-300k"], 1)
        self.assertEqual(buckets["300k+"], 1)


class TestByKind(unittest.TestCase):
    """Tests for the migrated --by-kind path: session_kind_map +
    summarize_by_kind run the new tier-aware estimate() per kind."""

    def test_session_kind_map_classifies(self):
        d0 = 1800000000000
        sessions = [
            {"id": "p1", "parent_id": None},
            {"id": "sub1", "parent_id": "p1"},
        ]
        conn = make_test_db([assistant_msg("m1", "p1", d0 + 1, cache_read=1)], sessions=sessions)
        kmap = oc_cost.session_kind_map(conn)
        self.assertEqual(kmap["p1"], "primary")
        self.assertEqual(kmap["sub1"], "subagent")

    def test_summarize_by_kind_estimates_per_kind(self):
        d0 = 1800000000000
        # Two primary messages (opus, flat $0.50 each via 1M cache_read) and
        # one subagent message (gpt-5.5, 1M input -> $5.00).
        rows = oc_cost.query_message_rows(
            make_test_db([
                assistant_msg("m1", "p1", d0 + 1, model="claude-opus-4-7@default",
                              provider="google-vertex-anthropic", cache_read=1_000_000),
                assistant_msg("m2", "p2", d0 + 2, model="claude-opus-4-7@default",
                              provider="google-vertex-anthropic", cache_read=1_000_000),
                assistant_msg("m3", "sub1", d0 + 3, model="gpt-5.5", provider="openai",
                              inp=1_000_000),
            ]),
            d0, d0 + DAY_MS,
        )
        kmap = {"p1": "primary", "p2": "primary", "sub1": "subagent"}
        summary = oc_cost.summarize_by_kind(rows, kmap)
        by = {s["kind"]: s for s in summary}
        # Primary listed before subagent.
        self.assertEqual([s["kind"] for s in summary], ["primary", "subagent"])
        self.assertEqual(by["primary"]["sessions"], 2)
        self.assertEqual(by["primary"]["msgs"], 2)
        self.assertAlmostEqual(by["primary"]["cost_usd"], 1.00, places=6)  # 2 * $0.50
        self.assertEqual(by["subagent"]["sessions"], 1)
        self.assertEqual(by["subagent"]["msgs"], 1)
        # 1M input >= 272K threshold -> long_context tier ($10/M) -> $10.00.
        self.assertAlmostEqual(by["subagent"]["cost_usd"], 10.00, places=6)

    def test_summarize_by_kind_unknown_session_defaults_primary(self):
        d0 = 1800000000000
        rows = oc_cost.query_message_rows(
            make_test_db([assistant_msg("m1", "orphan", d0 + 1, cache_read=100)]),
            d0, d0 + DAY_MS,
        )
        summary = oc_cost.summarize_by_kind(rows, {})  # empty map
        self.assertEqual(len(summary), 1)
        self.assertEqual(summary[0]["kind"], "primary")
        self.assertEqual(summary[0]["sessions"], 1)


class TestParseArgsByKind(unittest.TestCase):
    def test_by_kind_default_false(self):
        args = oc_cost.parse_args([])
        self.assertFalse(args.by_kind)

    def test_by_kind_flag(self):
        args = oc_cost.parse_args(["--by-kind"])
        self.assertTrue(args.by_kind)


class TestRenderJsonByKind(unittest.TestCase):
    def test_by_kind_in_json_when_present(self):
        report = {
            "meta": {
                "db_path": "/x.db",
                "window": {"start": "2026-01-01T00:00:00Z", "end": "2026-01-02T00:00:00Z"},
                "active_days": 1,
                "reconcile": False,
            },
            "daily": [],
            "estimate": {"total_est": 0.5, "by_model": [], "unpriced": []},
            "reconciliation": {"rows": [], "total_est": 0.5,
                               "total_recorded": 0.5, "total_delta": 0.0},
            "size_buckets": [],
            "by_kind": [
                {"kind": "primary",  "sessions": 1, "msgs": 1,
                 "cache_read": 100, "cache_write": 10, "uncached": 0, "output": 5,
                 "recorded_cost": 0.5, "cost_usd": 0.50},
            ],
        }
        out = oc_cost.render_json(report)
        parsed = json.loads(out)
        self.assertIn("by_kind", parsed)
        self.assertEqual(parsed["by_kind"][0]["kind"], "primary")


class TestRenderJson(unittest.TestCase):
    def test_schema(self):
        report = {
            "meta": {
                "db_path": "/x/y.db",
                "window": {"start": "2026-04-06T00:00:00Z", "end": "2026-04-20T00:00:00Z"},
                "active_days": 14,
                "reconcile": False,
            },
            "daily": [{"day": "2026-04-06", "msgs": 1, "cache_read": 100,
                       "cache_write": 10, "uncached": 5, "output": 20}],
            "estimate": {
                "total_est": 0.5,
                "by_model": [{"provider": "anthropic", "model": "claude-opus-4-6",
                              "msgs": 1, "input": 5, "output": 20, "reasoning": 0,
                              "cache_read": 100, "cache_write": 10,
                              "est_cost": 0.5, "recorded_cost": 0.5,
                              "tiers": {"base": 1, "long_context": 0, "unpriced": 0},
                              "priced": True}],
                "unpriced": [],
            },
            "reconciliation": {
                "rows": [{"provider": "anthropic", "model": "claude-opus-4-6",
                          "msgs": 1, "est_cost": 0.5, "recorded_cost": 0.5,
                          "delta": 0.0, "delta_pct": 0.0, "flagged": False}],
                "total_est": 0.5, "total_recorded": 0.5, "total_delta": 0.0,
            },
            "size_buckets": [{"bucket": "0-50k", "msgs": 1, "min_size": 100, "max_size": 100}],
        }
        out = oc_cost.render_json(report)
        parsed = json.loads(out)
        self.assertEqual(set(parsed.keys()),
                         {"meta", "daily", "estimate", "reconciliation", "size_buckets"})
        self.assertEqual(parsed["estimate"]["total_est"], 0.5)
        self.assertEqual(parsed["reconciliation"]["total_delta"], 0.0)

    def test_render_json_rejects_non_finite(self):
        # delta_pct must be sanitized BEFORE render_json; a raw inf would make
        # allow_nan=False raise, which is the safety net we want.
        bad = {"reconciliation": {"rows": [{"delta_pct": float("inf")}]}}
        with self.assertRaises(ValueError):
            oc_cost.render_json(bad)


class TestConnect(unittest.TestCase):
    def test_missing_db_raises_systemexit(self):
        with self.assertRaises(SystemExit):
            oc_cost.connect("/nonexistent/path/to/opencode.db")

    def test_wrong_schema_raises_systemexit(self):
        # Create a real (but empty) sqlite file with no `message` table.
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            path = f.name
        try:
            conn = sqlite3.connect(path)
            conn.execute("CREATE TABLE other (x int)")
            conn.commit()
            conn.close()
            with self.assertRaises(SystemExit):
                oc_cost.connect(path)
        finally:
            import os
            os.unlink(path)


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

    def test_opus_5_5_priced_exactly_not_by_opus_5_prefix(self):
        # "claude-opus-5-5".startswith("claude-opus-5"), so without its own row
        # the longest-prefix fallback would price it at opus-5's 5/25.
        for prov, mid in (("anthropic", "claude-opus-5-5"),
                          ("google-vertex-anthropic", "claude-opus-5-5@default")):
            e = oc_cost.rate_for(prov, mid)
            self.assertIsNotNone(e, prov)
            self.assertEqual(e["input"], 4, prov)
            self.assertEqual(e["output"], 20, prov)
            self.assertEqual(e["cache_read"], 0.20, prov)
            self.assertEqual(e["cache_write"], 5, prov)

    def test_haiku_5_5_base_tier_below_100k(self):
        # 99,999 tokens of context is the last base-tier request.
        for prov, mid in (("anthropic", "claude-haiku-5-5"),
                          ("google-vertex-anthropic", "claude-haiku-5-5@default")):
            toks = {"input": 59_999, "output": 1_000, "reasoning": 0,
                    "cache": {"read": 30_000, "write": 10_000}}
            cost, tier = oc_cost.cost_for_message(prov, mid, toks)
            expected = (59_999 * 0.10 + 1_000 * 0.50
                        + 30_000 * 0.01 + 10_000 * 0.125) / 1e6
            self.assertAlmostEqual(cost, expected, places=9, msg=prov)
            self.assertEqual(tier, "base", prov)

    def test_haiku_5_5_from_100k_is_5x_for_whole_request(self):
        # Vertex bills "longer than or equal to 100k" at the long rates.
        for prov, mid in (("anthropic", "claude-haiku-5-5"),
                          ("google-vertex-anthropic", "claude-haiku-5-5@default")):
            toks = {"input": 60_000, "output": 1_000, "reasoning": 0,
                    "cache": {"read": 30_000, "write": 10_000}}
            cost, tier = oc_cost.cost_for_message(prov, mid, toks)
            expected = (60_000 * 0.50 + 1_000 * 2.50
                        + 30_000 * 0.05 + 10_000 * 0.625) / 1e6
            self.assertAlmostEqual(cost, expected, places=9, msg=prov)
            self.assertEqual(tier, "long_context", prov)

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

    def test_gemini_flash_uses_introductory_rate_before_2027(self):
        # Google's intro pricing for 3.6/3.7/3.8 Flash runs through 2026-12-31:
        # 0.75 / 3.75 / cache_read 0.075 per 1M. Both routes are priced: Vertex
        # (cloudbox/macOS) and the direct Developer API (devbox vision-qa).
        for provider in ("google-vertex", "google"):
            for model in ("gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"):
                e = oc_cost.rate_for(provider, model, "2026-08-13")
                self.assertEqual(e["input"], 0.75, (provider, model))
                self.assertEqual(e["output"], 3.75, (provider, model))
                self.assertEqual(e["cache_read"], 0.075, (provider, model))

    def test_gemini_flash_doubles_from_2027(self):
        # Standard pricing applies starting 2027-01-01 (boundary inclusive).
        for provider in ("google-vertex", "google"):
            for model in ("gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash"):
                e = oc_cost.rate_for(provider, model, "2027-01-01")
                self.assertEqual(e["input"], 1.5, (provider, model))
                self.assertEqual(e["output"], 7.5, (provider, model))
                self.assertEqual(e["cache_read"], 0.15, (provider, model))

    def test_direct_gemini_api_is_priced_not_unpriced(self):
        # Regression: devbox records Gemini traffic under providerID "google"
        # (no ADC, both Vertex providers disabled). Before these rows existed
        # every such row fell through rate_for and reported tier "unpriced".
        toks = {"input": 1_000_000, "output": 1_000_000, "reasoning": 0,
                "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message(
            "google", "gemini-3.8-flash", toks, "2026-09-02")
        self.assertAlmostEqual(cost, 0.75 + 3.75, places=6)
        self.assertEqual(tier, "base")

    def test_direct_gemini_api_matches_vertex_rates(self):
        # The two routes share one definition; if they ever diverge, this is
        # the test that should force the split to be deliberate.
        for model in ("gemini-3.5-flash", "gemini-3.6-flash",
                      "gemini-3.7-flash", "gemini-3.8-flash"):
            for day in ("2026-09-02", "2027-06-01"):
                self.assertEqual(
                    oc_cost.rate_for("google", model, day),
                    oc_cost.rate_for("google-vertex", model, day),
                    (model, day))

    def test_gemini_4_argon_phases_on_both_routes(self):
        # Intro 2 / 10 / cache 0.10 through 2026-11-30; standard 4 / 20 / 0.20
        # from 2026-12-01. Same per-1M price on Vertex global and the
        # Developer API, so both routes share one definition.
        for provider in ("google-vertex", "google"):
            intro = oc_cost.rate_for(provider, "gemini-4-argon", "2026-11-30")
            self.assertEqual(
                (intro["input"], intro["output"], intro["cache_read"]),
                (2, 10, 0.10), provider)
            std = oc_cost.rate_for(provider, "gemini-4-argon", "2026-12-01")
            self.assertEqual(
                (std["input"], std["output"], std["cache_read"]),
                (4, 20, 0.20), provider)

    def test_gemini_4_argon_is_priced_not_unpriced(self):
        toks = {"input": 1_000_000, "output": 1_000_000, "reasoning": 0,
                "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message(
            "google-vertex", "gemini-4-argon", toks, "2026-10-13")
        self.assertAlmostEqual(cost, 2 + 10, places=6)
        self.assertEqual(tier, "base")

    def test_gemini_4_hydrogen_rates_on_both_routes(self):
        # Flat 1.5 / 7.5 / cache 0.075 (no promo). Same per-1M price on Vertex
        # global and Developer API, so both routes share one definition.
        for provider in ("google-vertex", "google"):
            rate = oc_cost.rate_for(provider, "gemini-4-hydrogen", "2026-11-12")
            self.assertEqual(
                (rate["input"], rate["output"], rate["cache_read"]),
                (1.5, 7.5, 0.075), provider)

    def test_gemini_4_hydrogen_is_priced_not_unpriced(self):
        toks = {"input": 1_000_000, "output": 1_000_000, "reasoning": 0,
                "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message(
            "google-vertex", "gemini-4-hydrogen", toks, "2026-11-12")
        self.assertAlmostEqual(cost, 1.5 + 7.5, places=6)
        self.assertEqual(tier, "base")

    def test_gemini_flash_last_intro_day_is_still_intro(self):
        e = oc_cost.rate_for("google-vertex", "gemini-3.8-flash", "2026-12-31")
        self.assertEqual(e["input"], 0.75)

    def test_gemini_flash_cost_for_message_uses_row_day(self):
        toks = {"input": 1_000_000, "output": 1_000_000, "reasoning": 0,
                "cache": {"read": 0, "write": 0}}
        intro, tier = oc_cost.cost_for_message(
            "google-vertex", "gemini-3.8-flash", toks, "2026-08-13")
        self.assertAlmostEqual(intro, 0.75 + 3.75, places=6)
        self.assertEqual(tier, "base")
        standard, _ = oc_cost.cost_for_message(
            "google-vertex", "gemini-3.8-flash", toks, "2027-06-01")
        self.assertAlmostEqual(standard, 1.5 + 7.5, places=6)

    def test_undated_model_ignores_day(self):
        # Only phased entries care about the date; everything else is
        # time-invariant and must not shift across the Gemini cutoff.
        before = oc_cost.rate_for("google-vertex-anthropic", "claude-opus-5", "2026-08-13")
        after = oc_cost.rate_for("google-vertex-anthropic", "claude-opus-5", "2027-06-01")
        self.assertEqual(before, after)

    def test_estimate_prices_gemini_rows_by_their_own_day(self):
        # A window spanning the cutoff must price each row at the rate in
        # force on ITS day, not today's rate for all of them.
        rows = [
            {"provider": "google-vertex", "model": "gemini-3.8-flash",
             "day": "2026-12-31", "input": 1_000_000, "output": 0,
             "reasoning": 0, "cache_read": 0, "cache_write": 0,
             "recorded_cost": 0.0, "session_id": "s1"},
            {"provider": "google-vertex", "model": "gemini-3.8-flash",
             "day": "2027-01-01", "input": 1_000_000, "output": 0,
             "reasoning": 0, "cache_read": 0, "cache_write": 0,
             "recorded_cost": 0.0, "session_id": "s1"},
        ]
        agg = oc_cost.estimate(rows)
        model_row = agg["by_model"][0]
        self.assertAlmostEqual(model_row["est_cost"], 0.75 + 1.5, places=6)

    def test_longest_prefix_wins_regardless_of_dict_order_rates(self):
        original = getattr(oc_cost, "RATES", None)
        try:
            oc_cost.RATES = {
                ("openai", "gpt-5"): {
                    "input": 15, "output": 75, "cache_read": 1.5, "cache_write": 18.75
                },
                ("openai", "gpt-5.5"): {
                    "input": 5, "output": 30, "cache_read": 0.5, "cache_write": 0
                },
            }
            e = oc_cost.rate_for("openai", "gpt-5.5-snapshot")
            self.assertIsNotNone(e)
            self.assertEqual(e["input"], 5)
            self.assertEqual(e["output"], 30)
        finally:
            if original is not None:
                oc_cost.RATES = original


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

    def test_recorded_cost_summed(self):
        d0 = 1800000000000
        msgs = [
            assistant_msg("m1", "s1", d0+1, model="gpt-5.5", provider="openai",
                          inp=100, cost=0.15),
            assistant_msg("m2", "s1", d0+2, model="gpt-5.5", provider="openai",
                          inp=200, cost=0.25),
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_message_rows(conn, d0, d0 + DAY_MS)
        est = oc_cost.estimate(rows)
        by = {(r["provider"], r["model"]): r for r in est["by_model"]}
        self.assertAlmostEqual(by[("openai", "gpt-5.5")]["recorded_cost"], 0.40, places=6)

    def test_tier_counts(self):
        d0 = 1800000000000
        msgs = [
            # gpt-5.5 base context: threshold is 272000
            assistant_msg("m1", "s1", d0+1, model="gpt-5.5", provider="openai",
                          inp=100000),  # base
            assistant_msg("m2", "s1", d0+2, model="gpt-5.5", provider="openai",
                          inp=300000),  # long_context
            # and let's add one unpriced
            assistant_msg("m3", "s1", d0+3, model="unknown", provider="weird"),  # unpriced
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_message_rows(conn, d0, d0 + DAY_MS)
        est = oc_cost.estimate(rows)
        by = {(r["provider"], r["model"]): r for r in est["by_model"]}
        gpt_row = by[("openai", "gpt-5.5")]
        self.assertEqual(gpt_row["tiers"]["base"], 1)
        self.assertEqual(gpt_row["tiers"]["long_context"], 1)
        self.assertEqual(gpt_row["tiers"]["unpriced"], 0)

        weird_row = by[("weird", "unknown")]
        self.assertEqual(weird_row["tiers"]["base"], 0)
        self.assertEqual(weird_row["tiers"]["long_context"], 0)
        self.assertEqual(weird_row["tiers"]["unpriced"], 1)

    def test_query_message_rows_filtering(self):
        d0 = 1800000000000
        msgs = [
            # Inside window, role='assistant', cache_read is present (non-null) -> should be included
            assistant_msg("m1", "s1", d0 + 1000, cache_read=100),
            # Outside window -> should be excluded
            assistant_msg("m2", "s1", d0 - 1000, cache_read=200),
            # role='user' -> should be excluded
            {
                "id": "u1", "session_id": "s1", "time_created": d0 + 1500,
                "role": "user", "tokens": {"input": 0, "output": 0, "cache": {"read": 0}},
            },
            # cache_read is null -> should be excluded
            {
                "id": "m3", "session_id": "s1", "time_created": d0 + 2000,
                "role": "assistant", "modelID": "gpt-5", "providerID": "openai",
                "tokens": {"input": 100, "output": 50},
            }
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_message_rows(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["provider"], "anthropic")
        self.assertEqual(rows[0]["model"], "claude-opus-4-6")
        self.assertEqual(rows[0]["day"], "2027-01-15") # d0 is 1800000000000 ms, which is 2027-01-15
        self.assertEqual(rows[0]["input"], 0)
        self.assertEqual(rows[0]["output"], 0)
        self.assertEqual(rows[0]["reasoning"], 0)
        self.assertEqual(rows[0]["cache_read"], 100)
        self.assertEqual(rows[0]["cache_write"], 0)
        self.assertEqual(rows[0]["recorded_cost"], 0.0)


class TestReconcile(unittest.TestCase):
    def test_flags_material_delta(self):
        # estimated $5.00, recorded $7.43 -> delta +$2.43, ~48% -> flagged
        # (OR rule: 48% > 5%, even though $2.43 < $5).
        by_model = [{"provider": "google-vertex-anthropic", "model": "claude-opus-4-7@default",
                     "msgs": 10, "est_cost": 5.00, "recorded_cost": 7.43}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        row = rec["rows"][0]
        self.assertAlmostEqual(row["delta"], 2.43, places=2)
        self.assertTrue(row["flagged"])  # 48% > 5%

    def test_small_delta_not_flagged(self):
        by_model = [{"provider": "openai", "model": "gpt-5.5", "msgs": 5,
                     "est_cost": 100.0, "recorded_cost": 101.0}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        self.assertFalse(rec["rows"][0]["flagged"])  # 1% and $1 both under thresholds

    def test_high_pct_small_dollar_is_flagged(self):
        # est $1.00, recorded $1.50 -> delta $0.50 (50%). OR rule flags it
        # (50% > 5%) even though $0.50 < $5. The bogus AND rule would suppress it.
        by_model = [{"provider": "p", "model": "m", "est_cost": 1.00, "recorded_cost": 1.50}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        self.assertTrue(rec["rows"][0]["flagged"])

    def test_large_dollar_small_pct_is_flagged(self):
        # est $1000, recorded $1040 -> delta $40 (4%). $40 > $5 flags it
        # even though 4% < 5%.
        by_model = [{"provider": "p", "model": "m", "est_cost": 1000.0, "recorded_cost": 1040.0}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        self.assertTrue(rec["rows"][0]["flagged"])

    def test_zero_estimate_does_not_crash(self):
        # est $0.00, recorded $6.00 -> must not raise ZeroDivisionError.
        by_model = [{"provider": "p", "model": "m", "est_cost": 0.0, "recorded_cost": 6.0}]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        row = rec["rows"][0]
        self.assertAlmostEqual(row["delta"], 6.0, places=6)
        self.assertTrue(row["flagged"])  # $6 > $5

    def test_totals(self):
        by_model = [
            {"provider": "p", "model": "a", "est_cost": 5.0, "recorded_cost": 7.43},
            {"provider": "p", "model": "b", "est_cost": 100.0, "recorded_cost": 101.0},
        ]
        rec = oc_cost.reconcile(by_model, pct_threshold=5.0, usd_threshold=5.0)
        self.assertAlmostEqual(rec["total_est"], 105.0, places=6)
        self.assertAlmostEqual(rec["total_recorded"], 108.43, places=6)
        self.assertAlmostEqual(rec["total_delta"], 3.43, places=6)
        # order preserved
        self.assertEqual([r["model"] for r in rec["rows"]], ["a", "b"])

    def test_reconcile_uses_est_cost_recorded_when_present(self):
        by_model = [
            {
                "provider": "goose:gcp_vertex_ai",
                "model": "claude-opus-5-5",
                "est_cost": 0.40,
                "est_cost_recorded": 0.20,
                "recorded_cost": 0.20,
            }
        ]
        rec = oc_cost.reconcile(by_model)
        self.assertEqual(len(rec["rows"]), 1)
        row = rec["rows"][0]
        self.assertAlmostEqual(row["delta"], 0.0, places=6)
        self.assertAlmostEqual(row["delta_pct"], 0.0, places=6)
        self.assertFalse(row["flagged"])
        self.assertAlmostEqual(rec["total_est"], 0.40, places=6)
        self.assertAlmostEqual(rec["total_recorded"], 0.20, places=6)
        self.assertAlmostEqual(rec["total_delta"], 0.0, places=6)


class TestParseArgsReconcile(unittest.TestCase):
    def test_reconcile_default_false(self):
        self.assertFalse(oc_cost.parse_args([]).reconcile)

    def test_reconcile_flag(self):
        self.assertTrue(oc_cost.parse_args(["--reconcile"]).reconcile)


class TestParseArgsVertex(unittest.TestCase):
    def _clear_env(self):
        for k in ("OC_COST_VERTEX_AUDIT_TABLE", "OC_COST_VERTEX_PROJECT",
                  "OC_COST_VERTEX_PRINCIPAL"):
            os.environ.pop(k, None)

    def test_vertex_reconcile_default_false(self):
        self._clear_env()
        args = oc_cost.parse_args([])
        self.assertFalse(args.vertex_reconcile)
        self.assertIsNone(args.vertex_audit_table)
        self.assertIsNone(args.vertex_project)
        self.assertIsNone(args.vertex_principal)

    def test_vertex_reconcile_flag(self):
        self.assertTrue(oc_cost.parse_args(["--vertex-reconcile"]).vertex_reconcile)

    def test_vertex_flags_explicit(self):
        args = oc_cost.parse_args([
            "--vertex-reconcile",
            "--vertex-audit-table", "proj:ds.tbl",
            "--vertex-project", "billing-proj",
            "--vertex-principal", "me@example.com",
        ])
        self.assertEqual(args.vertex_audit_table, "proj:ds.tbl")
        self.assertEqual(args.vertex_project, "billing-proj")
        self.assertEqual(args.vertex_principal, "me@example.com")

    def test_vertex_flags_env_fallback(self):
        self._clear_env()
        os.environ["OC_COST_VERTEX_AUDIT_TABLE"] = "envproj:envds.envtbl"
        os.environ["OC_COST_VERTEX_PROJECT"] = "env-billing"
        os.environ["OC_COST_VERTEX_PRINCIPAL"] = "env@example.com"
        try:
            args = oc_cost.parse_args([])
            self.assertEqual(args.vertex_audit_table, "envproj:envds.envtbl")
            self.assertEqual(args.vertex_project, "env-billing")
            self.assertEqual(args.vertex_principal, "env@example.com")
        finally:
            self._clear_env()

    def test_explicit_flag_overrides_env(self):
        self._clear_env()
        os.environ["OC_COST_VERTEX_AUDIT_TABLE"] = "envproj:envds.envtbl"
        try:
            args = oc_cost.parse_args(["--vertex-audit-table", "cli:cli.cli"])
            self.assertEqual(args.vertex_audit_table, "cli:cli.cli")
        finally:
            self._clear_env()


class TestBuildVertexQuery(unittest.TestCase):
    START = 1775001600000  # 2026-04-01T00:00:00Z
    END = 1776297600000    # 2026-04-16T00:00:00Z

    def test_normalizes_colon_table_to_backticked_dotted(self):
        sql = oc_cost.build_vertex_query("proj:ds.tbl", self.START, self.END, None)
        self.assertIn("`proj.ds.tbl`", sql)
        # The bq-style colon must not survive into standard SQL.
        self.assertNotIn("proj:ds.tbl", sql)

    def test_accepts_already_dotted_table(self):
        sql = oc_cost.build_vertex_query("proj.ds.tbl", self.START, self.END, None)
        self.assertIn("`proj.ds.tbl`", sql)

    def test_includes_dedupe_and_model_regex(self):
        sql = oc_cost.build_vertex_query("p:d.t", self.START, self.END, None)
        self.assertIn("COUNT(DISTINCT IFNULL(operation.id, insertId))", sql)
        self.assertIn("/publishers/[^/]+/models/([^/]+)", sql)
        self.assertIn("REGEXP_EXTRACT", sql)

    def test_includes_time_window(self):
        sql = oc_cost.build_vertex_query("p:d.t", self.START, self.END, None)
        self.assertIn(f"TIMESTAMP_MILLIS({self.START})", sql)
        self.assertIn(f"TIMESTAMP_MILLIS({self.END})", sql)

    def test_principal_filter_present_when_given(self):
        sql = oc_cost.build_vertex_query("p:d.t", self.START, self.END, "me@example.com")
        self.assertIn("principalEmail", sql)
        self.assertIn("'me@example.com'", sql)

    def test_principal_filter_absent_when_none(self):
        sql = oc_cost.build_vertex_query("p:d.t", self.START, self.END, None)
        self.assertNotIn("principalEmail", sql)

    def test_principal_single_quote_escaped(self):
        # A single quote in the principal must be escaped (doubled) so it can't
        # break out of the string literal / inject SQL.
        sql = oc_cost.build_vertex_query("p:d.t", self.START, self.END, "a'b@x.com")
        self.assertIn("'a''b@x.com'", sql)


class TestDbCallCountsByVertexModel(unittest.TestCase):
    def test_sums_vertex_providers_and_strips_at_suffix(self):
        by_model = [
            {"provider": "google-vertex-anthropic", "model": "claude-opus-4-7@default", "msgs": 10},
            {"provider": "google-vertex-anthropic", "model": "claude-opus-4-7@us", "msgs": 5},
            {"provider": "google-vertex", "model": "gemini-3.5-flash", "msgs": 7},
        ]
        counts = oc_cost.db_call_counts_by_vertex_model(by_model)
        # Two opus rows with different @suffix collapse to one normalized key.
        self.assertEqual(counts["claude-opus-4-7"], 15)
        self.assertEqual(counts["gemini-3.5-flash"], 7)

    def test_excludes_non_vertex_providers(self):
        by_model = [
            {"provider": "anthropic", "model": "claude-opus-4-7", "msgs": 100},
            {"provider": "openai", "model": "gpt-5.5", "msgs": 50},
            {"provider": "github-copilot", "model": "claude-opus-4.6", "msgs": 9},
            {"provider": "google-vertex", "model": "gemini-3.5-flash", "msgs": 3},
        ]
        counts = oc_cost.db_call_counts_by_vertex_model(by_model)
        self.assertEqual(counts, {"gemini-3.5-flash": 3})

    def test_sums_goose_vertex_calls_with_opencode(self):
        by_model = [
            {"provider": "google-vertex-anthropic", "rate_provider": "google-vertex-anthropic", "model": "claude-opus-5-5@default", "msgs": 10},
            {"provider": "goose:gcp_vertex_ai", "rate_provider": "google-vertex-anthropic", "model": "claude-opus-5-5", "msgs": 5},
            {"provider": "goose:mock-rolling", "rate_provider": None, "model": "claude-opus-5-5", "msgs": 3},
        ]
        counts = oc_cost.db_call_counts_by_vertex_model(by_model)
        self.assertEqual(counts["claude-opus-5-5"], 15)

    def test_empty_input(self):
        self.assertEqual(oc_cost.db_call_counts_by_vertex_model([]), {})


class TestReconcileVertex(unittest.TestCase):
    def _row(self, rec, model):
        return next(r for r in rec["rows"] if r["model"] == model)

    def test_undercount_flagged_with_positive_delta(self):
        # gemini DB sees 19646 calls, Vertex actually 31002 -> +11356 (57.8%).
        rec = oc_cost.reconcile_vertex(
            {"gemini-3.5-flash": 19646}, {"gemini-3.5-flash": 31002}
        )
        row = self._row(rec, "gemini-3.5-flash")
        self.assertEqual(row["db_calls"], 19646)
        self.assertEqual(row["vertex_calls"], 31002)
        self.assertEqual(row["delta"], 11356)  # vertex - db
        self.assertAlmostEqual(row["delta_pct"], 11356 / 19646 * 100, places=4)
        self.assertTrue(row["flagged"])

    def test_model_only_in_vertex_zero_db(self):
        # claude-haiku-4-5: titles run on it, no message row -> db_calls 0.
        rec = oc_cost.reconcile_vertex({}, {"claude-haiku-4-5": 4123})
        row = self._row(rec, "claude-haiku-4-5")
        self.assertEqual(row["db_calls"], 0)
        self.assertEqual(row["vertex_calls"], 4123)
        self.assertEqual(row["delta"], 4123)
        self.assertEqual(row["delta_pct"], float("inf"))  # zero baseline
        self.assertTrue(row["flagged"])

    def test_model_only_in_db_zero_vertex(self):
        rec = oc_cost.reconcile_vertex({"gemini-3.5-flash": 100}, {})
        row = self._row(rec, "gemini-3.5-flash")
        self.assertEqual(row["db_calls"], 100)
        self.assertEqual(row["vertex_calls"], 0)
        self.assertEqual(row["delta"], -100)
        self.assertTrue(row["flagged"])  # -100% trips pct rule

    def test_near_one_to_one_not_flagged(self):
        # opus reconciles ~1:1: tiny gap, neither threshold tripped.
        rec = oc_cost.reconcile_vertex(
            {"claude-opus-4-7": 35280}, {"claude-opus-4-7": 35291},
            pct_threshold=5.0, count_threshold=50,
        )
        row = self._row(rec, "claude-opus-4-7")
        self.assertEqual(row["delta"], 11)
        self.assertFalse(row["flagged"])

    def test_zero_delta_zero_db_not_flagged(self):
        rec = oc_cost.reconcile_vertex({"m": 0}, {"m": 0})
        row = self._row(rec, "m")
        self.assertEqual(row["delta_pct"], 0.0)
        self.assertFalse(row["flagged"])

    def test_or_rule_big_count_small_pct_flagged(self):
        # db 100000, vertex 100060 -> delta 60 (0.06%). count rule (60>50) flags.
        rec = oc_cost.reconcile_vertex(
            {"m": 100000}, {"m": 100060}, pct_threshold=5.0, count_threshold=50,
        )
        self.assertTrue(self._row(rec, "m")["flagged"])

    def test_or_rule_small_count_big_pct_flagged(self):
        # db 10, vertex 40 -> delta 30 (300%). pct rule flags even though 30<50.
        rec = oc_cost.reconcile_vertex(
            {"m": 10}, {"m": 40}, pct_threshold=5.0, count_threshold=50,
        )
        self.assertTrue(self._row(rec, "m")["flagged"])

    def test_totals_and_sort(self):
        rec = oc_cost.reconcile_vertex(
            {"a": 100, "b": 5}, {"a": 110, "b": 50, "c": 7},
        )
        self.assertEqual(rec["total_db"], 105)
        self.assertEqual(rec["total_vertex"], 167)
        self.assertEqual(rec["total_delta"], 62)
        # Sorted by descending vertex_calls: a(110), b(50), c(7).
        self.assertEqual([r["model"] for r in rec["rows"]], ["a", "b", "c"])


class _FakeProc:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class TestRunBqQuery(unittest.TestCase):
    def test_success_parses_json_rows(self):
        captured = {}

        def fake_run(argv, **kwargs):
            captured["argv"] = argv
            return _FakeProc(0, '[{"model":"x","vertex_calls":"5"}]', "")

        rows = oc_cost.run_bq_query("SELECT 1", project="bill", _run=fake_run)
        self.assertEqual(rows, [{"model": "x", "vertex_calls": "5"}])
        # SQL passed as the final positional arg; project threaded through.
        self.assertEqual(captured["argv"][0], "bq")
        self.assertIn("SELECT 1", captured["argv"])
        self.assertTrue(any("--project_id=bill" == a for a in captured["argv"]))
        self.assertTrue(any("--format=json" == a for a in captured["argv"]))

    def test_no_project_omits_project_flag(self):
        captured = {}

        def fake_run(argv, **kwargs):
            captured["argv"] = argv
            return _FakeProc(0, "[]", "")

        oc_cost.run_bq_query("SELECT 1", project=None, _run=fake_run)
        self.assertFalse(any(a.startswith("--project_id") for a in captured["argv"]))

    def test_empty_stdout_returns_empty_list(self):
        rows = oc_cost.run_bq_query("Q", _run=lambda *a, **k: _FakeProc(0, "", ""))
        self.assertEqual(rows, [])

    def test_bq_missing_raises_vertex_query_error(self):
        def fake_run(argv, **kwargs):
            raise FileNotFoundError("no bq")

        with self.assertRaises(oc_cost.VertexQueryError):
            oc_cost.run_bq_query("Q", _run=fake_run)

    def test_nonzero_exit_raises_with_stderr(self):
        def fake_run(argv, **kwargs):
            return _FakeProc(1, "", "permission denied on table")

        with self.assertRaises(oc_cost.VertexQueryError) as cm:
            oc_cost.run_bq_query("Q", _run=fake_run)
        self.assertIn("permission denied", str(cm.exception))

    def test_bad_json_raises(self):
        def fake_run(argv, **kwargs):
            return _FakeProc(0, "this is not json", "")

        with self.assertRaises(oc_cost.VertexQueryError):
            oc_cost.run_bq_query("Q", _run=fake_run)


class TestFetchVertexCounts(unittest.TestCase):
    def test_reduces_rows_to_int_counts(self):
        def runner(sql, project):
            return [
                {"model": "claude-opus-4-7", "vertex_calls": "35291"},
                {"model": "gemini-3.5-flash", "vertex_calls": "31002"},
            ]

        counts = oc_cost.fetch_vertex_counts(
            "p:d.t", "bill", 1, 2, None, runner=runner
        )
        self.assertEqual(counts, {"claude-opus-4-7": 35291, "gemini-3.5-flash": 31002})

    def test_null_model_bucketed_as_unknown(self):
        def runner(sql, project):
            return [
                {"model": None, "vertex_calls": "9"},
                {"model": "", "vertex_calls": "1"},
                {"model": "x", "vertex_calls": "3"},
            ]

        counts = oc_cost.fetch_vertex_counts("p:d.t", None, 1, 2, None, runner=runner)
        self.assertEqual(counts["x"], 3)
        self.assertEqual(counts["(unknown)"], 10)  # 9 + 1 summed

    def test_runner_receives_built_sql_and_project(self):
        captured = {}

        def runner(sql, project):
            captured["sql"] = sql
            captured["project"] = project
            return []

        oc_cost.fetch_vertex_counts("proj:ds.tbl", "bill", 100, 200,
                                    "me@x.com", runner=runner)
        self.assertIn("`proj.ds.tbl`", captured["sql"])
        self.assertIn("TIMESTAMP_MILLIS(100)", captured["sql"])
        self.assertIn("'me@x.com'", captured["sql"])
        self.assertEqual(captured["project"], "bill")

    def test_default_runner_is_module_run_bq_query(self):
        # When no runner is injected, fetch_vertex_counts must late-bind to the
        # module-level run_bq_query (so it is monkeypatchable, e.g. by main()).
        called = {}
        orig = oc_cost.run_bq_query

        def fake(sql, project):
            called["hit"] = True
            return []

        oc_cost.run_bq_query = fake
        try:
            oc_cost.fetch_vertex_counts("p:d.t", None, 1, 2, None)
            self.assertTrue(called.get("hit"))
        finally:
            oc_cost.run_bq_query = orig


class TestVertexReconciliationReport(unittest.TestCase):
    BY_MODEL = [
        {"provider": "google-vertex-anthropic", "model": "claude-opus-4-7@default", "msgs": 35280},
        {"provider": "google-vertex", "model": "gemini-3.5-flash", "msgs": 19646},
        {"provider": "openai", "model": "gpt-5.5", "msgs": 18869},  # non-vertex, ignored
    ]

    def test_skipped_when_no_audit_table(self):
        args = oc_cost.parse_args(["--vertex-reconcile"])
        args.vertex_audit_table = None
        rep = oc_cost.vertex_reconciliation_report(args, self.BY_MODEL, 1, 2)
        self.assertEqual(rep["status"], "skipped")
        self.assertIn("audit", rep["reason"].lower())

    def test_error_status_on_query_failure(self):
        args = oc_cost.parse_args(["--vertex-reconcile", "--vertex-audit-table", "p:d.t"])

        def runner(sql, project):
            raise oc_cost.VertexQueryError("boom: permission denied")

        rep = oc_cost.vertex_reconciliation_report(args, self.BY_MODEL, 1, 2, runner=runner)
        self.assertEqual(rep["status"], "error")
        self.assertIn("boom", rep["reason"])

    def test_ok_status_reconciles_and_flags(self):
        args = oc_cost.parse_args([
            "--vertex-reconcile", "--vertex-audit-table", "p:d.t",
            "--vertex-principal", "me@x.com",
        ])

        def runner(sql, project):
            return [
                {"model": "claude-opus-4-7", "vertex_calls": "35291"},  # ~1:1
                {"model": "gemini-3.5-flash", "vertex_calls": "31002"},  # undercount
                {"model": "claude-haiku-4-5", "vertex_calls": "4123"},   # invisible
            ]

        rep = oc_cost.vertex_reconciliation_report(args, self.BY_MODEL, 1, 2, runner=runner)
        self.assertEqual(rep["status"], "ok")
        self.assertEqual(rep["principal"], "me@x.com")
        self.assertEqual(rep["audit_table"], "p:d.t")
        by = {r["model"]: r for r in rep["rows"]}
        self.assertFalse(by["claude-opus-4-7"]["flagged"])
        self.assertTrue(by["gemini-3.5-flash"]["flagged"])
        self.assertEqual(by["claude-haiku-4-5"]["db_calls"], 0)
        self.assertTrue(by["claude-haiku-4-5"]["flagged"])
        # delta_pct for the zero-db haiku row must be JSON-safe (no raw inf).
        self.assertIsNone(by["claude-haiku-4-5"]["delta_pct"])
        # Whole report must be RFC-8259 JSON-serializable.
        json.dumps(rep, allow_nan=False)

    def test_project_derived_from_table_when_unset(self):
        args = oc_cost.parse_args(["--vertex-reconcile", "--vertex-audit-table", "myproj:ds.t"])
        captured = {}

        def runner(sql, project):
            captured["project"] = project
            return []

        rep = oc_cost.vertex_reconciliation_report(args, self.BY_MODEL, 1, 2, runner=runner)
        self.assertEqual(captured["project"], "myproj")  # parsed from table
        self.assertEqual(rep["project"], "myproj")


class TestRateForGuard(unittest.TestCase):
    def test_none_model_returns_none(self):
        self.assertIsNone(oc_cost.rate_for("openai", None))

    def test_none_provider_returns_none(self):
        self.assertIsNone(oc_cost.rate_for(None, "gpt-5.5"))

    def test_cost_for_message_handles_none_ids(self):
        toks = {"input": 100, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}}
        cost, tier = oc_cost.cost_for_message(None, None, toks)
        self.assertIsNone(cost)
        self.assertEqual(tier, "unpriced")


def _write_db_file(messages: list[dict], sessions: list[dict] | None = None) -> str:
    """Write messages to a temp on-disk sqlite DB (connect() needs a file path
    for its mode=ro URI) and return the path. Caller is responsible for unlink."""
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    conn = sqlite3.connect(path)
    conn.execute(
        """
        CREATE TABLE message (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            time_created integer NOT NULL,
            time_updated integer NOT NULL,
            data text NOT NULL
        )
        """
    )
    if sessions is not None:
        conn.execute(
            """
            CREATE TABLE session (
                id text PRIMARY KEY,
                parent_id text
            )
            """
        )
        for s in sessions:
            conn.execute(
                "INSERT INTO session (id, parent_id) VALUES (?, ?)",
                (s["id"], s.get("parent_id")),
            )
    for m in messages:
        data = {k: v for k, v in m.items() if k not in ("id", "session_id", "time_created")}
        conn.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) "
            "VALUES (?, ?, ?, ?, ?)",
            (m["id"], m["session_id"], m["time_created"], m["time_created"], json.dumps(data)),
        )
    conn.commit()
    conn.close()
    return path


def make_goose_db(
    ledger_rows: list[dict], sessions: list[dict] | None = None
) -> str:
    """Write goose sessions and usage_ledger tables to a temp file, return path.
    Caller unlinks."""
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    conn = sqlite3.connect(path)
    conn.execute(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            parent_session_id TEXT,
            provider_name TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE usage_ledger (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            created_timestamp INTEGER NOT NULL,
            model TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER,
            total_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,
            cost REAL,
            cost_source TEXT,
            is_compaction INTEGER DEFAULT 0
        )
        """
    )
    if sessions is not None:
        for s in sessions:
            conn.execute(
                "INSERT INTO sessions (id, parent_session_id, provider_name) VALUES (?, ?, ?)",
                (s["id"], s.get("parent_session_id"), s.get("provider_name")),
            )
    for row in ledger_rows:
        conn.execute(
            """
            INSERT INTO usage_ledger (
                session_id, created_timestamp, model, input_tokens, output_tokens,
                total_tokens, cache_read_tokens, cache_write_tokens, cost, cost_source, is_compaction
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                row["session_id"],
                row["created_timestamp"],
                row.get("model"),
                row.get("input_tokens", 0),
                row.get("output_tokens", 0),
                row.get("total_tokens", (row.get("input_tokens", 0) or 0) + (row.get("output_tokens", 0) or 0)),
                row.get("cache_read_tokens", 0),
                row.get("cache_write_tokens", 0),
                row.get("cost"),
                row.get("cost_source", "estimated"),
                row.get("is_compaction", 0),
            ),
        )
    conn.commit()
    conn.close()
    return path


def goose_ledger_row(
    session_id: str,
    created_timestamp: int,
    model: str = "claude-opus-5-5",
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
    cost: float | None = None,
    cost_source: str = "estimated",
    is_compaction: int = 0,
) -> dict:
    return {
        "session_id": session_id,
        "created_timestamp": created_timestamp,
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_tokens": cache_read_tokens,
        "cache_write_tokens": cache_write_tokens,
        "cost": cost,
        "cost_source": cost_source,
        "is_compaction": is_compaction,
    }


class TestMainIntegration(unittest.TestCase):
    """End-to-end: main() over a real on-disk DB, JSON output."""

    def setUp(self):
        self._orig_goose_db = getattr(oc_cost, "_DEFAULT_GOOSE_DB", None)
        oc_cost._DEFAULT_GOOSE_DB = "/nonexistent/path/to/goose.db"

    def tearDown(self):
        if self._orig_goose_db is not None:
            oc_cost._DEFAULT_GOOSE_DB = self._orig_goose_db
        elif hasattr(oc_cost, "_DEFAULT_GOOSE_DB"):
            delattr(oc_cost, "_DEFAULT_GOOSE_DB")

    def test_end_to_end_json_reconcile(self):
        import io
        import contextlib
        d0 = 1800000000000  # 2027-01-15 UTC
        msgs = [
            # priced: est $0.50, but recorded inflated to $2.93 -> flagged
            assistant_msg("m1", "s1", d0 + 1, model="claude-opus-4-7@default",
                          provider="google-vertex-anthropic", cache_read=1_000_000, cost=2.93),
            # unpriced: recorded $1.00, no rate-book entry
            assistant_msg("m2", "s1", d0 + 2, model="mystery", provider="weird",
                          cache_read=1_000_000, cost=1.00),
        ]
        path = _write_db_file(msgs)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main(["--db", path, "--json",
                                   "--since", "2027-01-01", "--until", "2027-01-31",
                                   "--reconcile"])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            # No non-standard JSON tokens.
            self.assertNotIn("Infinity", out)
            self.assertNotIn("NaN", out)
            parsed = json.loads(out)
            self.assertEqual(set(parsed.keys()),
                             {"meta", "daily", "estimate", "reconciliation", "size_buckets"})
            self.assertTrue(parsed["meta"]["reconcile"])
            # estimate: only the priced opus contributes ($0.50); mystery unpriced.
            self.assertAlmostEqual(parsed["estimate"]["total_est"], 0.50, places=6)
            self.assertIn(["weird", "mystery"], parsed["estimate"]["unpriced"])
            # reconciliation: only priced rows; opus flagged (recorded 2.93 >> est 0.50).
            recrows = parsed["reconciliation"]["rows"]
            self.assertEqual(len(recrows), 1)
            opus = recrows[0]
            self.assertEqual(opus["model"], "claude-opus-4-7@default")
            self.assertTrue(opus["flagged"])
            self.assertAlmostEqual(parsed["reconciliation"]["total_recorded"], 2.93, places=6)
            self.assertAlmostEqual(parsed["reconciliation"]["total_est"], 0.50, places=6)
            self.assertAlmostEqual(parsed["reconciliation"]["total_delta"], 2.43, places=6)
        finally:
            os.unlink(path)

    def _clear_vertex_env(self):
        for k in ("OC_COST_VERTEX_AUDIT_TABLE", "OC_COST_VERTEX_PROJECT",
                  "OC_COST_VERTEX_PRINCIPAL"):
            os.environ.pop(k, None)

    def test_end_to_end_json_vertex_reconcile(self):
        import io
        import contextlib
        self._clear_vertex_env()
        d0 = 1800000000000  # 2027-01-15 UTC
        msgs = [
            assistant_msg("m1", "s1", d0 + 1, model="claude-opus-4-7@default",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
            assistant_msg("m2", "s1", d0 + 2, model="gemini-3.5-flash",
                          provider="google-vertex", inp=1000),
        ]
        path = _write_db_file(msgs)

        def fake_bq(sql, project):
            return [
                {"model": "claude-opus-4-7", "vertex_calls": "1"},     # ~1:1
                {"model": "gemini-3.5-flash", "vertex_calls": "50"},   # undercount
                {"model": "claude-haiku-4-5", "vertex_calls": "30"},   # invisible titles
            ]

        orig = oc_cost.run_bq_query
        oc_cost.run_bq_query = fake_bq
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main(["--db", path, "--json",
                                   "--since", "2027-01-01", "--until", "2027-01-31",
                                   "--vertex-reconcile",
                                   "--vertex-audit-table", "proj:ds.tbl"])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertNotIn("Infinity", out)
            self.assertNotIn("NaN", out)
            parsed = json.loads(out)
            self.assertIn("vertex_reconciliation", parsed)
            vr = parsed["vertex_reconciliation"]
            self.assertEqual(vr["status"], "ok")
            by = {r["model"]: r for r in vr["rows"]}
            self.assertFalse(by["claude-opus-4-7"]["flagged"])
            self.assertTrue(by["gemini-3.5-flash"]["flagged"])
            self.assertTrue(by["claude-haiku-4-5"]["flagged"])
            self.assertEqual(by["claude-haiku-4-5"]["db_calls"], 0)
        finally:
            oc_cost.run_bq_query = orig
            os.unlink(path)

    def test_vertex_reconcile_skips_without_table(self):
        import io
        import contextlib
        self._clear_vertex_env()
        d0 = 1800000000000
        msgs = [assistant_msg("m1", "s1", d0 + 1, model="claude-opus-4-7@default",
                              provider="google-vertex-anthropic", cache_read=1_000_000)]
        path = _write_db_file(msgs)
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                rc = oc_cost.main(["--db", path, "--json",
                                   "--since", "2027-01-01", "--until", "2027-01-31",
                                   "--vertex-reconcile"])
            self.assertEqual(rc, 0)  # non-fatal
            parsed = json.loads(buf.getvalue())
            self.assertEqual(parsed["vertex_reconciliation"]["status"], "skipped")
            # A clear note went to stderr.
            self.assertIn("vertex", err.getvalue().lower())
        finally:
            os.unlink(path)

    def test_vertex_reconcile_text_section(self):
        import io
        import contextlib
        self._clear_vertex_env()
        d0 = 1800000000000
        msgs = [assistant_msg("m1", "s1", d0 + 1, model="gemini-3.5-flash",
                              provider="google-vertex", inp=1000)]
        path = _write_db_file(msgs)

        def fake_bq(sql, project):
            return [{"model": "gemini-3.5-flash", "vertex_calls": "50"},
                    {"model": "claude-haiku-4-5", "vertex_calls": "30"}]

        orig = oc_cost.run_bq_query
        oc_cost.run_bq_query = fake_bq
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main(["--db", path,
                                   "--since", "2027-01-01", "--until", "2027-01-31",
                                   "--vertex-reconcile",
                                   "--vertex-audit-table", "proj:ds.tbl"])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("Vertex Call Reconciliation", out)
            self.assertIn("claude-haiku-4-5", out)
            self.assertIn("FLAG", out)
        finally:
            oc_cost.run_bq_query = orig
            os.unlink(path)

    def test_end_to_end_text_runs(self):
        import io
        import contextlib
        import os as _os
        d0 = 1800000000000
        msgs = [
            assistant_msg("m1", "s1", d0 + 1, model="gpt-5.5", provider="openai",
                          inp=1000, out=500, cost=0.02),
        ]
        path = _write_db_file(msgs)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main(["--db", path, "--since", "2027-01-01", "--until", "2027-01-31"])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("Per-Model Estimated Cost", out)
            self.assertIn("Reconciliation", out)
        finally:
            _os.unlink(path)


class TestGooseRateProvider(unittest.TestCase):
    def test_gcp_vertex_ai_claude_models(self):
        self.assertEqual(
            oc_cost.goose_rate_provider("gcp_vertex_ai", "claude-opus-5-5"),
            "google-vertex-anthropic",
        )
        self.assertEqual(
            oc_cost.goose_rate_provider("gcp_vertex_ai", "claude-sonnet-4-6"),
            "google-vertex-anthropic",
        )
        self.assertEqual(
            oc_cost.goose_rate_provider("gcp_vertex_ai", "claude-haiku-5-5"),
            "google-vertex-anthropic",
        )

    def test_gcp_vertex_ai_non_claude_models(self):
        self.assertEqual(
            oc_cost.goose_rate_provider("gcp_vertex_ai", "gemini-3.5-flash"),
            "google-vertex",
        )
        self.assertEqual(
            oc_cost.goose_rate_provider("gcp_vertex_ai", None),
            "google-vertex",
        )

    def test_known_self_mapping_providers(self):
        self.assertEqual(
            oc_cost.goose_rate_provider("anthropic", "claude-opus-5-5"),
            "anthropic",
        )
        self.assertEqual(
            oc_cost.goose_rate_provider("google", "gemini-3.5-flash"),
            "google",
        )
        self.assertEqual(
            oc_cost.goose_rate_provider("openai", "gpt-5.5"),
            "openai",
        )

    def test_unknown_providers_return_none(self):
        self.assertIsNone(oc_cost.goose_rate_provider("mock-rolling", "model"))
        self.assertIsNone(oc_cost.goose_rate_provider("unknown", "model"))
        self.assertIsNone(oc_cost.goose_rate_provider(None, "model"))


class TestQueryGooseRows(unittest.TestCase):
    def test_cache_inclusive_input_conversion(self):
        rows = [
            goose_ledger_row("s1", 1775001600, input_tokens=1000, cache_read_tokens=200, cache_write_tokens=300),
            goose_ledger_row("s1", 1775001601, input_tokens=100, cache_read_tokens=200, cache_write_tokens=300),
        ]
        sessions = [{"id": "s1", "provider_name": "gcp_vertex_ai"}]
        path = make_goose_db(rows, sessions)
        try:
            q_rows, _ = oc_cost.query_goose_rows(path, 1775001600000, 1775001700000)
            self.assertEqual(len(q_rows), 2)
            self.assertEqual(q_rows[0]["input"], 500)
            self.assertEqual(q_rows[0]["cache_read"], 200)
            self.assertEqual(q_rows[0]["cache_write"], 300)
            self.assertEqual(q_rows[1]["input"], 0)
        finally:
            os.unlink(path)

    def test_seconds_to_day(self):
        rows = [goose_ledger_row("s1", 1775001600)]
        path = make_goose_db(rows, [{"id": "s1", "provider_name": "gcp_vertex_ai"}])
        try:
            q_rows, _ = oc_cost.query_goose_rows(path, 1775000000000, 1775005000000)
            self.assertEqual(q_rows[0]["day"], "2026-04-01")
        finally:
            os.unlink(path)

    def test_window_bounds(self):
        rows = [
            goose_ledger_row("s1", 1775000),
            goose_ledger_row("s1", 1775001),
            goose_ledger_row("s1", 1775002),
            goose_ledger_row("s1", 1775003),
        ]
        path = make_goose_db(rows, [{"id": "s1", "provider_name": "gcp_vertex_ai"}])
        try:
            q_rows, _ = oc_cost.query_goose_rows(path, 1775001000, 1775002000)
            self.assertEqual(len(q_rows), 2)
        finally:
            os.unlink(path)

    def test_goose_prefixes_and_backend(self):
        rows = [
            goose_ledger_row("s1", 1775001600, model="claude-opus-5-5"),
            goose_ledger_row("s2", 1775001601, model="claude-opus-5-5"),
        ]
        sessions = [
            {"id": "s1", "provider_name": "gcp_vertex_ai"},
            {"id": "s2", "provider_name": None},
        ]
        path = make_goose_db(rows, sessions)
        try:
            q_rows, _ = oc_cost.query_goose_rows(path, 1775000000000, 1775005000000)
            self.assertEqual(q_rows[0]["session_id"], "goose:s1")
            self.assertEqual(q_rows[0]["provider"], "goose:gcp_vertex_ai")
            self.assertEqual(q_rows[0]["rate_provider"], "google-vertex-anthropic")
            self.assertEqual(q_rows[0]["backend"], "goose")
            self.assertEqual(q_rows[0]["reasoning"], 0)

            self.assertEqual(q_rows[1]["session_id"], "goose:s2")
            self.assertEqual(q_rows[1]["provider"], "goose:unknown")
            self.assertIsNone(q_rows[1]["rate_provider"])
            self.assertEqual(q_rows[1]["backend"], "goose")
        finally:
            os.unlink(path)

    def test_null_cost_vs_recorded_cost(self):
        rows = [
            goose_ledger_row("s1", 1775001600, cost=None),
            goose_ledger_row("s1", 1775001601, cost=1.25),
            goose_ledger_row("s1", 1775001602, cost=0.0),
        ]
        path = make_goose_db(rows, [{"id": "s1", "provider_name": "gcp_vertex_ai"}])
        try:
            q_rows, _ = oc_cost.query_goose_rows(path, 1775000000000, 1775005000000)
            self.assertEqual(q_rows[0]["recorded_cost"], 0.0)
            self.assertTrue(q_rows[0]["recorded_missing"])

            self.assertEqual(q_rows[1]["recorded_cost"], 1.25)
            self.assertFalse(q_rows[1]["recorded_missing"])

            self.assertEqual(q_rows[2]["recorded_cost"], 0.0)
            self.assertFalse(q_rows[2]["recorded_missing"])
        finally:
            os.unlink(path)

    def test_kind_map(self):
        rows = [
            goose_ledger_row("s1", 1775001600),
            goose_ledger_row("s2", 1775001601),
        ]
        sessions = [
            {"id": "s1", "parent_session_id": "root_sess", "provider_name": "gcp_vertex_ai"},
            {"id": "s2", "parent_session_id": None, "provider_name": "gcp_vertex_ai"},
        ]
        path = make_goose_db(rows, sessions)
        try:
            _, kind_map = oc_cost.query_goose_rows(path, 1775000000000, 1775005000000)
            self.assertEqual(kind_map.get("goose:s1"), "subagent")
            self.assertEqual(kind_map.get("goose:s2"), "primary")
        finally:
            os.unlink(path)


class TestEstimateGoose(unittest.TestCase):
    def test_goose_vertex_claude_priced_and_fields(self):
        row = {
            "session_id": "goose:s1",
            "provider": "goose:gcp_vertex_ai",
            "rate_provider": "google-vertex-anthropic",
            "model": "claude-opus-5-5",
            "day": "2026-10-01",
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache_read": 1_000_000,
            "cache_write": 0,
            "recorded_cost": 0.20,
            "recorded_missing": False,
            "backend": "goose",
        }
        est = oc_cost.estimate([row])
        self.assertEqual(len(est["by_model"]), 1)
        m = est["by_model"][0]
        self.assertEqual(m["provider"], "goose:gcp_vertex_ai")
        self.assertEqual(m["rate_provider"], "google-vertex-anthropic")
        self.assertEqual(m["model"], "claude-opus-5-5")
        self.assertEqual(m["backend"], "goose")
        self.assertTrue(m["priced"])
        self.assertAlmostEqual(m["est_cost"], 0.20, places=6)
        self.assertEqual(m["unrecorded_msgs"], 0)

    def test_unrecorded_msgs_counted(self):
        row = {
            "session_id": "goose:s1",
            "provider": "goose:gcp_vertex_ai",
            "rate_provider": "google-vertex-anthropic",
            "model": "claude-opus-5-5",
            "day": "2026-10-01",
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache_read": 1_000_000,
            "cache_write": 0,
            "recorded_cost": 0.0,
            "recorded_missing": True,
            "backend": "goose",
        }
        est = oc_cost.estimate([row])
        m = est["by_model"][0]
        self.assertEqual(m["unrecorded_msgs"], 1)

    def test_opencode_rows_backend_and_unrecorded_msgs(self):
        row = {
            "session_id": "s1",
            "provider": "anthropic",
            "model": "claude-opus-5-5",
            "day": "2026-10-01",
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache_read": 1_000_000,
            "cache_write": 0,
            "recorded_cost": 0.20,
        }
        est = oc_cost.estimate([row])
        m = est["by_model"][0]
        self.assertEqual(m["backend"], "opencode")
        self.assertEqual(m["rate_provider"], "anthropic")
        self.assertEqual(m["unrecorded_msgs"], 0)
        self.assertEqual(m["est_cost_recorded"], m["est_cost"])

    def test_estimate_computes_est_cost_recorded(self):
        row_rec = {
            "session_id": "goose:s1",
            "provider": "goose:gcp_vertex_ai",
            "rate_provider": "google-vertex-anthropic",
            "model": "claude-opus-5-5",
            "day": "2026-10-01",
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache_read": 1_000_000,
            "cache_write": 0,
            "recorded_cost": 0.20,
            "recorded_missing": False,
            "backend": "goose",
        }
        row_null = {
            "session_id": "goose:s2",
            "provider": "goose:gcp_vertex_ai",
            "rate_provider": "google-vertex-anthropic",
            "model": "claude-opus-5-5",
            "day": "2026-10-01",
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache_read": 1_000_000,
            "cache_write": 0,
            "recorded_cost": 0.0,
            "recorded_missing": True,
            "backend": "goose",
        }
        est = oc_cost.estimate([row_rec, row_null])
        m = est["by_model"][0]
        self.assertAlmostEqual(m["est_cost"], 0.40, places=6)
        self.assertAlmostEqual(m["est_cost_recorded"], 0.20, places=6)
        self.assertAlmostEqual(m["recorded_cost"], 0.20, places=6)
        self.assertEqual(m["unrecorded_msgs"], 1)

    def test_goose_unpriced_model(self):
        row = {
            "session_id": "goose:s1",
            "provider": "goose:mock-rolling",
            "rate_provider": None,
            "model": "unknown-model",
            "day": "2026-10-01",
            "input": 100,
            "output": 50,
            "reasoning": 0,
            "cache_read": 0,
            "cache_write": 0,
            "recorded_cost": 0.0,
            "recorded_missing": True,
            "backend": "goose",
        }
        est = oc_cost.estimate([row])
        self.assertEqual(est["total_est"], 0.0)
        self.assertIn(("goose:mock-rolling", "unknown-model"), est["unpriced"])
        m = est["by_model"][0]
        self.assertEqual(m["backend"], "goose")
        self.assertIsNone(m["rate_provider"])
        self.assertEqual(m["unrecorded_msgs"], 1)


class TestMerges(unittest.TestCase):
    def test_merge_daily(self):
        opencode_daily = [
            {"day": "2026-04-01", "msgs": 2, "cache_read": 100, "cache_write": 10, "uncached": 50, "output": 20},
        ]
        goose_rows = [
            {"day": "2026-04-01", "input": 20, "output": 10, "cache_read": 40, "cache_write": 5},
            {"day": "2026-04-02", "input": 30, "output": 15, "cache_read": 60, "cache_write": 0},
        ]
        merged = oc_cost.merge_daily(opencode_daily, goose_rows)
        self.assertEqual(len(merged), 2)
        d1 = merged[0]
        self.assertEqual(d1["day"], "2026-04-01")
        self.assertEqual(d1["msgs"], 3)
        self.assertEqual(d1["cache_read"], 140)
        self.assertEqual(d1["cache_write"], 15)
        self.assertEqual(d1["uncached"], 70)
        self.assertEqual(d1["output"], 30)

        d2 = merged[1]
        self.assertEqual(d2["day"], "2026-04-02")
        self.assertEqual(d2["msgs"], 1)
        self.assertEqual(d2["uncached"], 30)

    def test_merge_size_buckets(self):
        opencode_buckets = [
            {"bucket": "0-50k", "msgs": 1, "min_size": 1000, "max_size": 2000},
        ]
        goose_rows = [
            {"input": 100, "cache_read": 100, "cache_write": 100},
            {"input": 350000, "cache_read": 0, "cache_write": 0},
        ]
        merged = oc_cost.merge_size_buckets(opencode_buckets, goose_rows)
        self.assertEqual(len(merged), 2)
        b0 = merged[0]
        self.assertEqual(b0["bucket"], "0-50k")
        self.assertEqual(b0["msgs"], 2)
        self.assertEqual(b0["min_size"], 300)
        self.assertEqual(b0["max_size"], 2000)

        b1 = merged[1]
        self.assertEqual(b1["bucket"], "300k+")
        self.assertEqual(b1["msgs"], 1)
        self.assertEqual(b1["min_size"], 350000)


class TestMainGooseIntegration(unittest.TestCase):
    def setUp(self):
        self._orig_goose_db = getattr(oc_cost, "_DEFAULT_GOOSE_DB", None)
        oc_cost._DEFAULT_GOOSE_DB = "/nonexistent/path/to/goose.db"

    def tearDown(self):
        if self._orig_goose_db is not None:
            oc_cost._DEFAULT_GOOSE_DB = self._orig_goose_db
        elif hasattr(oc_cost, "_DEFAULT_GOOSE_DB"):
            delattr(oc_cost, "_DEFAULT_GOOSE_DB")

    def test_json_end_to_end_both_dbs(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        g_sessions = [{"id": "g1", "provider_name": "gcp_vertex_ai"}]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, g_sessions)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path, "--json",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            data = json.loads(buf.getvalue())
            self.assertEqual(data["meta"]["db_path"], oc_path)
            self.assertEqual(data["meta"]["goose_db_path"], g_path)
            self.assertAlmostEqual(data["estimate"]["total_est"], 0.40, places=6)
            backends = {r["backend"] for r in data["estimate"]["by_model"]}
            self.assertEqual(backends, {"opencode", "goose"})
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_no_goose_flag(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, [{"id": "g1", "provider_name": "gcp_vertex_ai"}])
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path, "--no-goose", "--json",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
            self.assertAlmostEqual(data["estimate"]["total_est"], 0.20, places=6)
            self.assertEqual(len(data["estimate"]["by_model"]), 1)
            self.assertEqual(data["estimate"]["by_model"][0]["backend"], "opencode")
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_explicit_missing_goose_db_warns(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_path = _write_db_file(oc_msgs)
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", "/nonexistent/goose.db", "--json",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            self.assertIn("Warning: goose DB not found: /nonexistent/goose.db", err.getvalue())
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
        finally:
            os.unlink(oc_path)

    def test_default_missing_goose_db_silent(self):
        import io
        import contextlib
        import warnings
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_path = _write_db_file(oc_msgs)
        orig_default_db = oc_cost._DEFAULT_DB
        oc_cost._DEFAULT_DB = oc_path
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                    rc = oc_cost.main([
                        "--json",
                        "--since", "2027-01-01", "--until", "2027-01-31",
                    ])
            self.assertEqual(rc, 0)
            self.assertEqual(err.getvalue(), "")
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
        finally:
            oc_cost._DEFAULT_DB = orig_default_db
            os.unlink(oc_path)

    def test_db_without_goose_db_skips_goose(self):
        import io
        import contextlib
        import warnings
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, [{"id": "g1", "provider_name": "gcp_vertex_ai"}])
        oc_cost._DEFAULT_GOOSE_DB = g_path
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                    rc = oc_cost.main([
                        "--db", oc_path, "--json",
                        "--since", "2027-01-01", "--until", "2027-01-31",
                    ])
            self.assertEqual(rc, 0)
            self.assertEqual(err.getvalue(), "")
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
            self.assertAlmostEqual(data["estimate"]["total_est"], 0.20, places=6)
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_neither_db_nor_goose_db_uses_default_goose(self):
        import io
        import contextlib
        import warnings
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, [{"id": "g1", "provider_name": "gcp_vertex_ai"}])
        orig_default_db = oc_cost._DEFAULT_DB
        oc_cost._DEFAULT_DB = oc_path
        oc_cost._DEFAULT_GOOSE_DB = g_path
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                    rc = oc_cost.main([
                        "--json",
                        "--since", "2027-01-01", "--until", "2027-01-31",
                    ])
            self.assertEqual(rc, 0)
            self.assertEqual(err.getvalue(), "")
            data = json.loads(buf.getvalue())
            self.assertEqual(data["meta"]["goose_db_path"], g_path)
            self.assertAlmostEqual(data["estimate"]["total_est"], 0.40, places=6)
        finally:
            oc_cost._DEFAULT_DB = orig_default_db
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_no_goose_wins_over_missing_goose_db(self):
        import io
        import contextlib
        import warnings
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_path = _write_db_file(oc_msgs)
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                    rc = oc_cost.main([
                        "--db", oc_path, "--goose-db", "/nonexistent/goose.db", "--no-goose", "--json",
                        "--since", "2027-01-01", "--until", "2027-01-31",
                    ])
            self.assertEqual(rc, 0)
            self.assertEqual(err.getvalue(), "")
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
        finally:
            os.unlink(oc_path)

    def test_corrupt_goose_db_warns_and_exits_zero(self):
        import io
        import contextlib
        import tempfile
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_path = _write_db_file(oc_msgs)
        fd, bad_path = tempfile.mkstemp(suffix=".db")
        os.write(fd, b"corrupt junk not a database")
        os.close(fd)
        try:
            buf = io.StringIO()
            err = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", bad_path, "--json",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            self.assertIn("Warning: goose usage not counted:", err.getvalue())
            data = json.loads(buf.getvalue())
            self.assertIsNone(data["meta"]["goose_db_path"])
        finally:
            os.unlink(oc_path)
            os.unlink(bad_path)

    def test_text_output_with_goose(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, [{"id": "g1", "provider_name": "gcp_vertex_ai"}])
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path,
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("Usage Report (opencode + goose)", out)
            self.assertIn("goose:gcp_vertex_ai/claude-opus-5-5", out)
            self.assertIn(f"Database: {oc_path}", out)
            self.assertIn(f"Goose database: {g_path}", out)
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_text_output_unrecorded_note(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=None),
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, [{"id": "g1", "provider_name": "gcp_vertex_ai"}])
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path,
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn(
                "  Note: 1 goose messages have no recorded cost (goose had no price then); they are in Estimated but not in Δ.",
                out,
            )
            self.assertIn("Δ (recorded−estimated, rows with a recorded cost):", out)
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_text_output_unrecorded_note_excludes_unpriced_mocks(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=None),
            goose_ledger_row("g2", (d0 + 3000) // 1000, model="unknown-mock-model",
                             input_tokens=100, cost=None),
        ]
        g_sessions = [
            {"id": "g1", "provider_name": "gcp_vertex_ai"},
            {"id": "g2", "provider_name": "mock-rolling"},
        ]
        oc_path = _write_db_file(oc_msgs)
        g_path = make_goose_db(g_rows, g_sessions)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path,
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            # Only the 1 priced message is counted, not the mock one.
            self.assertIn(
                "  Note: 1 goose messages have no recorded cost (goose had no price then); they are in Estimated but not in Δ.",
                out,
            )
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)

    def test_text_output_opencode_only(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_path = _write_db_file(oc_msgs)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--no-goose",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("OpenCode Usage Report", out)
            self.assertNotIn("Usage Report (opencode + goose)", out)
            self.assertNotIn("Goose database:", out)
        finally:
            os.unlink(oc_path)

    def test_by_kind_merges_goose_and_opencode(self):
        import io
        import contextlib
        d0 = 1800000000000
        oc_msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-5-5",
                          provider="google-vertex-anthropic", cache_read=1_000_000),
        ]
        oc_sessions = [{"id": "s1", "parent_id": None}]
        g_rows = [
            goose_ledger_row("g1", (d0 + 2000) // 1000, model="claude-opus-5-5",
                             cache_read_tokens=1_000_000, cost=0.20),
        ]
        g_sessions = [{"id": "g1", "parent_session_id": "root", "provider_name": "gcp_vertex_ai"}]
        oc_path = _write_db_file(oc_msgs, sessions=oc_sessions)
        g_path = make_goose_db(g_rows, g_sessions)
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = oc_cost.main([
                    "--db", oc_path, "--goose-db", g_path, "--json", "--by-kind",
                    "--since", "2027-01-01", "--until", "2027-01-31",
                ])
            self.assertEqual(rc, 0)
            data = json.loads(buf.getvalue())
            self.assertIn("by_kind", data)
            by_kind = {k["kind"]: k for k in data["by_kind"]}
            self.assertEqual(by_kind["primary"]["sessions"], 1)
            self.assertEqual(by_kind["primary"]["msgs"], 1)
            self.assertEqual(by_kind["subagent"]["sessions"], 1)
            self.assertEqual(by_kind["subagent"]["msgs"], 1)
        finally:
            os.unlink(oc_path)
            os.unlink(g_path)


# Without this, `python3 test_oc_cost.py` imports the module, defines all 101
# test methods, runs NONE of them, prints nothing, and exits 0 -- measured.
# That is the oc-session-list artifact (a checkPhase that ran `--help`) in
# python form, and it is what this file would have contributed to CI had the
# check been written the obvious way. The suite was reachable only via
# `python3 -m unittest <file>`, which the reachability guard's runner regex
# cannot match (`-m` does not end in `.py`), so the honest fix is to make the
# file directly runnable rather than to teach the guard a new shape.
if __name__ == "__main__":
    unittest.main()

