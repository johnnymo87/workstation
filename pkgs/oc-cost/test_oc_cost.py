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


if __name__ == "__main__":
    unittest.main()
