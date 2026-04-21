"""Tests for oc-cost. Run: python3 -m unittest pkgs/oc-cost/test_oc_cost.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
import json
import sqlite3

# Allow `import oc_cost` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_cost  # noqa: E402


class TestPriceFor(unittest.TestCase):
    def test_exact_match(self):
        rates = oc_cost.price_for("claude-opus-4-6")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 5)
        self.assertEqual(rates["output"], 25)
        self.assertEqual(rates["cache_write"], 6.25)
        self.assertEqual(rates["cache_read"], 0.50)

    def test_strips_at_suffix(self):
        # Real-world model IDs from opencode.db look like
        # "claude-opus-4-6@default" or "...@vertex".
        rates = oc_cost.price_for("claude-opus-4-6@default")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 5)

    def test_prefix_fallback(self):
        # Variants like "claude-sonnet-4-5-20251022" should match
        # claude-sonnet-4-5 by prefix.
        rates = oc_cost.price_for("claude-sonnet-4-5-20251022")
        self.assertIsNotNone(rates)
        self.assertEqual(rates["input"], 3)  # sonnet-4-5 input rate

    def test_unknown_returns_none(self):
        self.assertIsNone(oc_cost.price_for("totally-unknown-model"))

    def test_unknown_with_at_suffix_returns_none(self):
        self.assertIsNone(oc_cost.price_for("totally-unknown@default"))

    def test_longest_prefix_wins_regardless_of_dict_order(self):
        # Regression test for the analyze.mjs bug: when multiple keys
        # match by prefix, the LONGEST one must win, not the first
        # iterated. We monkeypatch PRICES with a deliberately
        # adversarial insertion order (short key first) to prove the
        # invariant doesn't depend on how PRICES happens to be ordered.
        original = oc_cost.PRICES
        try:
            oc_cost.PRICES = {
                "claude-opus-4": {  # SHORT key first -- adversarial
                    "input": 15, "output": 75, "cache_write": 18.75, "cache_read": 1.50,
                },
                "claude-opus-4-7": {
                    "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
                },
            }
            rates = oc_cost.price_for("claude-opus-4-7-snapshot-20260101")
            self.assertIsNotNone(rates)
            # Must pick claude-opus-4-7 (longer) over claude-opus-4 (shorter).
            # A first-match-wins implementation would return $15/$75 here.
            self.assertEqual(rates["input"], 5)
            self.assertEqual(rates["output"], 25)
        finally:
            oc_cost.PRICES = original


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



def make_test_db(messages: list[dict]) -> sqlite3.Connection:
    """Build an in-memory SQLite DB matching opencode.db's schema.

    Each `messages` dict needs keys: id, session_id, time_created (ms),
    and message-data fields (role, modelID, providerID, tokens). We wrap
    the message-data fields into a JSON string for the `data` column.
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
) -> dict:
    return {
        "id": msg_id,
        "session_id": session_id,
        "time_created": time_ms,
        "role": "assistant",
        "modelID": model,
        "providerID": provider,
        "tokens": {
            "input": inp,
            "output": out,
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


class TestQueryByModel(unittest.TestCase):
    def test_groups_by_model_orders_by_cache_read_desc(self):
        d0 = 1800000000000
        msgs = [
            assistant_msg("m1", "s1", d0 + 1000, model="claude-opus-4-6", cache_read=500, out=100),
            assistant_msg("m2", "s1", d0 + 2000, model="claude-sonnet-4-6", cache_read=1000, out=50),
            assistant_msg("m3", "s1", d0 + 3000, model="claude-opus-4-6", cache_read=200, out=30),
        ]
        conn = make_test_db(msgs)
        rows = oc_cost.query_by_model(conn, d0, d0 + DAY_MS)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["model"], "claude-sonnet-4-6")
        self.assertEqual(rows[0]["cache_read"], 1000)
        self.assertEqual(rows[1]["model"], "claude-opus-4-6")
        self.assertEqual(rows[1]["cache_read"], 700)
        self.assertEqual(rows[1]["output"], 130)


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


if __name__ == "__main__":
    unittest.main()
