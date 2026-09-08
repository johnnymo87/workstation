"""Tests for oc-tags. Run: python3 pkgs/oc-tags/test_oc_tags.py"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Allow `import oc_tags` when running from repo root or anywhere else.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_tags  # noqa: E402


class TestParseArgs(unittest.TestCase):
    def test_report_defaults(self):
        args = oc_tags.parse_args(["report"])
        self.assertEqual(args.command, "report")
        self.assertEqual(args.days, 14)


# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
