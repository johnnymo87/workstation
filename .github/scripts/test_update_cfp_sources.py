#!/usr/bin/env python3
"""Tests for update-cfp-sources.py.

The bug under test is a SILENT one -- a crossed asset id/hash pair still
verifies in Nix and only fails on the affected machine at exec time -- so the
regression oracle here is "each block kept its OWN id and hash", not merely
"the script ran".

Run: python3 .github/scripts/test_update_cfp_sources.py
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("update-cfp-sources.py")
REAL_NIX = Path(__file__).resolve().parents[2] / "pkgs/claude-failover-proxy/default.nix"

spec = importlib.util.spec_from_file_location("update_cfp_sources", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


FIXTURE = '''{
  lib,
}:

let
  version = "0.9.4";

  sources = {
    "aarch64-linux" = fetchurl {
      name = "claude-failover-proxy-${version}-linux-arm64";
      url = "https://api.github.com/repos/o/r/releases/assets/111";
      hash = "sha256-LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLQ=";
      curlOptsList = [ "-H" "Accept: application/octet-stream" ];
    };

    "aarch64-darwin" = fetchurl {
      name = "claude-failover-proxy-${version}-darwin-arm64";
      url = "https://api.github.com/repos/o/r/releases/assets/222";
      hash = "sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDQ=";
      curlOptsList = [ "-H" "Accept: application/octet-stream" ];
    };
  };
in
{ }
'''

NEW = {
    "aarch64-linux": ("333", "sha256-NEWLINUXNEWLINUXNEWLINUXNEWLINUXNEWLINUXXQ="),
    "aarch64-darwin": ("444", "sha256-NEWDARWINNEWDARWINNEWDARWINNEWDARWINNEWDQ="),
}


class RewriteTest(unittest.TestCase):
    def test_each_block_keeps_its_own_id_and_hash(self) -> None:
        out = mod.rewrite(FIXTURE, "0.9.4", "0.9.5", NEW)

        linux_block = out.split('"aarch64-darwin"')[0]
        darwin_block = out.split('"aarch64-darwin"')[1]

        self.assertIn("releases/assets/333", linux_block)
        self.assertIn(NEW["aarch64-linux"][1], linux_block)
        self.assertIn("releases/assets/444", darwin_block)
        self.assertIn(NEW["aarch64-darwin"][1], darwin_block)

        # The precise historical corruption: darwin carrying linux's values.
        self.assertNotIn("releases/assets/333", darwin_block)
        self.assertNotIn(NEW["aarch64-linux"][1], darwin_block)

    def test_version_bumped_once(self) -> None:
        out = mod.rewrite(FIXTURE, "0.9.4", "0.9.5", NEW)
        self.assertIn('version = "0.9.5"', out)
        self.assertNotIn('version = "0.9.4"', out)

    def test_identical_hashes_across_targets_are_rejected(self) -> None:
        """A shared hash is the corruption signature, so refuse to write it."""
        same = "sha256-SAMESAMESAMESAMESAMESAMESAMESAMESAMESAMEBQ="
        with self.assertRaises(SystemExit):
            mod.rewrite(
                FIXTURE,
                "0.9.4",
                "0.9.5",
                {"aarch64-linux": ("333", same), "aarch64-darwin": ("444", same)},
            )

    def test_missing_block_is_fatal(self) -> None:
        with self.assertRaises(SystemExit):
            mod.rewrite_source(FIXTURE, "x86_64-linux", "999", "sha256-x")

    def test_wrong_current_version_is_fatal(self) -> None:
        with self.assertRaises(SystemExit):
            mod.rewrite(FIXTURE, "0.0.0", "0.9.5", NEW)

    def test_runs_against_the_real_default_nix(self) -> None:
        """Guards the block-delimiter assumption against real formatting."""
        text = REAL_NIX.read_text()
        current = text.split('version = "')[1].split('"')[0]
        out = mod.rewrite(text, current, "9.9.9", NEW)
        self.assertIn('version = "9.9.9"', out)
        self.assertIn("releases/assets/333", out)
        self.assertIn("releases/assets/444", out)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
