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


class TestAutoKey(unittest.TestCase):
    def test_worktree_keeps_slug(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/fbm-transform-evidence"),
            "auto:mono/fbm-transform-evidence",
        )

    def test_primary_root(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono"), "auto:mono")

    def test_tmp_collapses(self):
        self.assertEqual(oc_tags.auto_key("/tmp/yt0p-verify"), "auto:tmp")
        self.assertEqual(oc_tags.auto_key("/tmp"), "auto:tmp")

    def test_nested_worktree_path(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees/w3-pr2/sub/dir"),
            "auto:mono/w3-pr2",
        )

    def test_missing_directory(self):
        self.assertEqual(oc_tags.auto_key(None), "auto:no-dir")
        self.assertEqual(oc_tags.auto_key(""), "auto:no-dir")

    def test_trailing_slash(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/"), "auto:mono")

    def test_worktree_container_without_slug(self):
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/.worktrees"), "auto:mono")
        self.assertEqual(oc_tags.auto_key("/home/dev/projects/mono/.worktrees/"), "auto:mono")

    def test_doubled_slash_in_worktrees(self):
        self.assertEqual(
            oc_tags.auto_key("/home/dev/projects/mono/.worktrees//w3-pr2"),
            "auto:mono/w3-pr2",
        )

    def test_root_worktrees_slug(self):
        self.assertEqual(oc_tags.auto_key("/.worktrees/slug"), "auto:root/slug")


class TestRootOf(unittest.TestCase):
    def test_root_is_itself(self):
        self.assertEqual(oc_tags.root_of("a", {"a": None}), "a")

    def test_child_resolves_to_parent(self):
        self.assertEqual(oc_tags.root_of("b", {"a": None, "b": "a"}), "a")

    def test_dangling_parent_stops_at_self(self):
        # 983 live sessions point at a deleted parent. Attribute to the
        # topmost EXISTING ancestor -- here, the child itself.
        self.assertEqual(oc_tags.root_of("b", {"b": "gone"}), "b")

    def test_dangling_grandparent_stops_at_existing(self):
        self.assertEqual(oc_tags.root_of("c", {"b": "gone", "c": "b"}), "b")

    def test_cycle_guard(self):
        self.assertEqual(oc_tags.root_of("a", {"a": "b", "b": "a"}), "a")

    def test_unknown_session(self):
        self.assertEqual(oc_tags.root_of("zzz", {"a": None}), "zzz")

    def test_lasso_cycle(self):
        self.assertEqual(oc_tags.root_of("c", {"c": "b", "b": "a", "a": "b"}), "b")

    def test_empty_parents_map(self):
        self.assertEqual(oc_tags.root_of("a", {}), "a")




# Without this guard, `python3 test_oc_tags.py` imports the module, defines
# every test, runs NONE, prints nothing and exits 0 -- the exact failure mode
# documented at the bottom of pkgs/oc-cost/test_oc_cost.py. The flake check
# runs this file directly, so the guard is what makes the check able to fail.
if __name__ == "__main__":
    unittest.main()
