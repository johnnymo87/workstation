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


class TestParseArgsReconcile(unittest.TestCase):
    def test_reconcile_default_false(self):
        self.assertFalse(oc_cost.parse_args([]).reconcile)

    def test_reconcile_flag(self):
        self.assertTrue(oc_cost.parse_args(["--reconcile"]).reconcile)


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


def _write_db_file(messages: list[dict]) -> str:
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


class TestMainIntegration(unittest.TestCase):
    """End-to-end: main() over a real on-disk DB, JSON output."""

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

