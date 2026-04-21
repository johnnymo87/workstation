"""Tests for oc-cost. Run: python3 -m unittest pkgs/oc-cost/test_oc_cost.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
