#!/usr/bin/env python3
"""Unit tests for .github/scripts/check-channel-eol.py."""

from __future__ import annotations

import datetime
import importlib.util
import json
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parent / "check-channel-eol.py"
SPEC = importlib.util.spec_from_file_location("check_channel_eol", SCRIPT)
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

SAMPLE_FLAKE_2605 = """
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
  };
}
"""


class FakeGh:
    def __init__(
        self,
        existing_branches: set[str] | None = None,
        open_issues: list[dict] | None = None,
    ) -> None:
        self.existing_branches = existing_branches or set()
        self.open_issues = open_issues or []
        self.calls: list[tuple[list[str], str | None]] = []

    def __call__(self, args: list[str], stdin: str | None = None) -> tuple[int, str, str]:
        self.calls.append((args, stdin))
        if args[0] == "api" and "/branches/" in args[1]:
            key = args[1].removeprefix("repos/")
            return (0, "", "") if key in self.existing_branches else (1, "", "404")
        if args[:2] == ["issue", "list"]:
            return (0, json.dumps(self.open_issues), "")
        return (0, "", "")


class CheckChannelEolTest(unittest.TestCase):
    def test_parses_real_flake_nix(self) -> None:
        flake_path = Path(__file__).resolve().parents[2] / "flake.nix"
        channels = MOD.parse_channels(flake_path.read_text(encoding="utf-8"))
        self.assertEqual(channels["nixpkgs"], channels["home-manager"])
        self.assertEqual(channels["nixpkgs"], channels["nix-darwin"])

    def test_channel_math_05_and_11(self) -> None:
        self.assertEqual(MOD.next_channel("26.05"), "26.11")
        self.assertEqual(MOD.channel_eol("26.05"), datetime.date(2026, 12, 31))
        self.assertEqual(MOD.next_channel("26.11"), "27.05")
        self.assertEqual(MOD.channel_eol("26.11"), datetime.date(2027, 6, 30))

    def test_no_alert_when_far_from_eol_and_not_ready(self) -> None:
        gh = FakeGh(existing_branches=set(), open_issues=[])
        res = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 8, 1),
            run_gh=gh,
        )
        self.assertTrue(res.startswith("ok:26.05:"))
        self.assertFalse(any(c[0][:2] == ["issue", "create"] for c in gh.calls))

    def test_creates_issue_when_within_warn_window(self) -> None:
        gh = FakeGh(
            existing_branches={"NixOS/nixpkgs/branches/release-26.11"},
            open_issues=[],
        )
        res = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 11, 25),
            run_gh=gh,
        )
        self.assertEqual(res, "created:26.05->26.11")
        create_calls = [c for c in gh.calls if c[0][:2] == ["issue", "create"]]
        self.assertEqual(len(create_calls), 1)
        args, body = create_calls[0]
        self.assertIn("NixOS channel upgrade: 26.05 -> 26.11 (EOL 2026-12-31)", args)
        assert body is not None
        self.assertIn("waiting on upstream branches", body)
        self.assertIn("branched (`release-26.11`)", body)

    def test_creates_issue_when_all_upstream_ready_even_before_warn_window(self) -> None:
        gh = FakeGh(
            existing_branches={
                "NixOS/nixpkgs/branches/nixos-26.11",
                "nix-community/home-manager/branches/release-26.11",
                "nix-darwin/nix-darwin/branches/nix-darwin-26.11",
            },
            open_issues=[],
        )
        res = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 11, 1),
            run_gh=gh,
        )
        self.assertEqual(res, "created:26.05->26.11")
        _, body = [c for c in gh.calls if c[0][:2] == ["issue", "create"]][0]
        assert body is not None
        self.assertIn("all upstream channels ready", body)

    def test_dedupes_within_7_days_and_comments_immediately_on_ready_flip(self) -> None:
        existing = {
            "number": 77,
            "title": "NixOS channel upgrade: 26.05 -> 26.11 (EOL 2026-12-31)",
            "body": "Status: **EOL approaching — waiting on upstream branches**",
            "createdAt": "2026-11-25T07:00:00Z",
            "comments": [],
        }
        gh_wait = FakeGh(existing_branches=set(), open_issues=[existing])
        res1 = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 11, 27),
            run_gh=gh_wait,
        )
        self.assertEqual(res1, "deduped:77")

        gh_ready = FakeGh(
            existing_branches={
                "NixOS/nixpkgs/branches/nixos-26.11",
                "nix-community/home-manager/branches/release-26.11",
                "nix-darwin/nix-darwin/branches/nix-darwin-26.11",
            },
            open_issues=[existing],
        )
        res2 = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 11, 27),
            run_gh=gh_ready,
        )
        self.assertEqual(res2, "commented:77:ready")

    def test_closes_obsolete_channel_issue(self) -> None:
        old_issue = {
            "number": 55,
            "title": "NixOS channel upgrade: 25.11 -> 26.05 (EOL 2026-06-30)",
            "body": "old",
            "createdAt": "2026-06-01T07:00:00Z",
            "comments": [],
        }
        gh = FakeGh(existing_branches=set(), open_issues=[old_issue])
        res = MOD.run_check(
            flake_text=SAMPLE_FLAKE_2605,
            today=datetime.date(2026, 8, 1),
            run_gh=gh,
        )
        self.assertTrue(res.startswith("ok:26.05:"))
        close_calls = [c for c in gh.calls if c[0][:3] == ["issue", "close", "55"]]
        self.assertEqual(len(close_calls), 1)

    def test_raises_on_non_404_api_error(self) -> None:
        def failing_gh(args: list[str], stdin: str | None = None) -> tuple[int, str, str]:
            return (1, "", "gh: HTTP 403 API rate limit exceeded")

        with self.assertRaises(RuntimeError):
            MOD.branch_exists("NixOS/nixpkgs", "nixos-26.11", failing_gh)

    def test_raises_on_mismatched_channels(self) -> None:
        mismatched = SAMPLE_FLAKE_2605.replace("release-26.05", "release-25.11")
        with self.assertRaises(ValueError):
            MOD.run_check(
                flake_text=mismatched,
                today=datetime.date(2026, 8, 1),
                run_gh=FakeGh(),
            )


if __name__ == "__main__":
    unittest.main()
