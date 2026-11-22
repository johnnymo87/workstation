#!/usr/bin/env python3
"""Tests for update-goose-pin.py.

The pin must move only onto a complete release, never touch a held platform entry, and
give every entry its OWN asset's hash. The real pkgs/goose/default.nix is a fixture too,
so a reformat of that file that breaks the rewrite fails here, not in a bump.

Run: python3 .github/scripts/test_update_goose_pin.py
"""
from __future__ import annotations

import base64
import importlib.util
import re
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("update-goose-pin.py")
spec = importlib.util.spec_from_file_location("update_goose_pin", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# The live file may hold darwin back (its own version/tag) or not; the tests derive both
# states from it so they pass either way.
REAL = re.sub(
    r'(\n    "aarch64-darwin" = \{\n)(      version = "[^"]*";\n)?(      tag = "[^"]*";\n)?',
    r"\1",
    mod.NIX.read_text(),
)
HELD = REAL.replace(
    '    "aarch64-darwin" = {\n      asset',
    '    "aarch64-darwin" = {\n      tag = "patched-1.54.0.18";\n      asset',
)
LINUX = ["goose-aarch64-unknown-linux-gnu.tar.gz", "goose-x86_64-unknown-linux-gnu.tar.gz"]
DARWIN = "goose-aarch64-apple-darwin.tar.gz"


def release(tag, assets, draft=False):
    return {"tag_name": tag, "draft": draft, "prerelease": False, "assets": [{"name": a} for a in assets]}


def sums(assets):
    return "".join(f"{(('%02x' % i) * 32)}  {a}\n" for i, a in enumerate(assets, 1))


def sri(i):
    return "sha256-" + base64.b64encode(bytes.fromhex(("%02x" % i) * 32)).decode()


class PlanTest(unittest.TestCase):
    ALL = LINUX + [DARWIN, "SHA256SUMS"]

    def test_real_file_has_a_tag_and_three_entries(self):
        self.assertTrue(mod.parse_tag(mod.current_tag(REAL)))
        self.assertEqual(len(mod.entries(REAL)), 3)

    def test_newer_complete_release_is_picked(self):
        rels = [release("patched-99.0.0.0", self.ALL[:1]), release("patched-9.60.2.1", self.ALL),
                release("patched-9.60.2.0", self.ALL)]
        p = mod.plan(REAL, rels)
        self.assertEqual((p["tag"], p["version"], p["major"]), ("patched-9.60.2.1", "9.60.2-patched.1", "true"))

    def test_nothing_newer_or_only_drafts(self):
        cur = mod.current_tag(REAL)
        self.assertEqual(mod.plan(REAL, [release(cur, self.ALL)]), {})
        self.assertEqual(mod.plan(REAL, [release("patched-9.0.0.0", self.ALL, draft=True)]), {})

    def test_held_entry_asset_is_not_required(self):
        rels = [release("patched-9.60.2.0", LINUX + ["SHA256SUMS"])]
        self.assertEqual(mod.plan(REAL, rels), {})
        self.assertEqual(mod.plan(HELD, rels)["tag"], "patched-9.60.2.0")

    def test_minor_is_not_major(self):
        a = mod.parse_tag(mod.current_tag(REAL))[0]
        p = mod.plan(REAL, [release(f"patched-{a}.99.0.0", self.ALL)])
        self.assertEqual(p["major"], "false")


class RewriteTest(unittest.TestCase):
    def test_every_entry_gets_its_own_hash(self):
        out = mod.rewrite(REAL, "patched-9.60.2.0", sums(LINUX + [DARWIN]))
        self.assertIn('  version = "9.60.2-patched.0";', out)
        self.assertIn('  tag = "patched-9.60.2.0";', out)
        e = {m.group("system"): m.group("body") for m in mod.ENTRY_RE.finditer(out)}
        self.assertIn(sri(1), e["aarch64-linux"])
        self.assertIn(sri(2), e["x86_64-linux"])
        self.assertIn(sri(3), e["aarch64-darwin"])

    def test_held_entry_is_untouched(self):
        out = mod.rewrite(HELD, "patched-9.60.2.0", sums(LINUX))
        held = lambda t: [m.group(0) for m in mod.ENTRY_RE.finditer(t) if m.group("system") == "aarch64-darwin"]
        self.assertEqual(held(out), held(HELD))
        self.assertEqual(out.count('tag = "patched-1.54.0.18";'), 1)

    def test_missing_asset_in_sums_fails(self):
        with self.assertRaises(ValueError):
            mod.rewrite(REAL, "patched-9.60.2.0", sums(LINUX))


if __name__ == "__main__":
    unittest.main()
