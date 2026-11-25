#!/usr/bin/env python3
"""Unit tests for .github/scripts/report-workflow-failure.py."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parent / "report-workflow-failure.py"
SPEC = importlib.util.spec_from_file_location("report_workflow_failure", SCRIPT)
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FakeGh:
    def __init__(self, open_issues: list[dict] | None = None) -> None:
        self.open_issues = open_issues or []
        self.calls: list[tuple[list[str], str | None]] = []

    def __call__(self, args: list[str], stdin: str | None = None) -> str:
        self.calls.append((args, stdin))
        if args[:2] == ["issue", "list"]:
            return json.dumps(self.open_issues)
        return ""


class ReportWorkflowFailureTest(unittest.TestCase):
    RUN_URL = "https://github.com/johnnymo87/workstation/actions/runs/12345"

    def test_creates_issue_on_first_failure(self) -> None:
        gh = FakeGh([])
        action = MOD.handle_status(
            workflow="Update packages (beads)",
            status="failure",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "created")
        self.assertEqual(len(gh.calls), 2)
        create_args, body = gh.calls[1]
        self.assertEqual(create_args[:2], ["issue", "create"])
        self.assertIn("Automated workflow failing: Update packages (beads)", create_args)
        self.assertIn("johnnymo87", create_args)
        assert body is not None
        self.assertIn(self.RUN_URL, body)

    def test_dedupes_same_day_created_issue(self) -> None:
        gh = FakeGh([
            {
                "number": 42,
                "title": "Automated workflow failing: Update goose",
                "createdAt": "2026-11-25T06:00:00Z",
                "comments": [],
            }
        ])
        action = MOD.handle_status(
            workflow="Update goose",
            status="failure",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "deduped:42")
        self.assertEqual(len(gh.calls), 1)

    def test_dedupes_same_day_comment(self) -> None:
        gh = FakeGh([
            {
                "number": 42,
                "title": "Automated workflow failing: Update goose",
                "createdAt": "2026-11-24T06:00:00Z",
                "comments": [{"createdAt": "2026-11-25T00:41:00Z"}],
            }
        ])
        action = MOD.handle_status(
            workflow="Update goose",
            status="failure",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "deduped:42")
        self.assertEqual(len(gh.calls), 1)

    def test_comments_on_next_day_failure(self) -> None:
        gh = FakeGh([
            {
                "number": 42,
                "title": "Automated workflow failing: Update packages (beads)",
                "createdAt": "2026-11-24T06:00:00Z",
                "comments": [{"createdAt": "2026-11-24T12:00:00Z"}],
            }
        ])
        action = MOD.handle_status(
            workflow="Update packages (beads)",
            status="failure",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "commented:42")
        self.assertEqual(gh.calls[1][0][:3], ["issue", "comment", "42"])

    def test_closes_issue_on_recovery(self) -> None:
        gh = FakeGh([
            {
                "number": 42,
                "title": "Automated workflow failing: Update packages (beads)",
                "createdAt": "2026-11-24T06:00:00Z",
                "comments": [],
            }
        ])
        action = MOD.handle_status(
            workflow="Update packages (beads)",
            status="success",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "closed:42")
        self.assertEqual(gh.calls[1][0][:3], ["issue", "close", "42"])

    def test_success_with_no_open_issue_is_noop(self) -> None:
        gh = FakeGh([])
        action = MOD.handle_status(
            workflow="Update flake.lock",
            status="success",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "noop-clean")
        self.assertEqual(len(gh.calls), 1)

    def test_cancelled_does_nothing(self) -> None:
        gh = FakeGh([])
        action = MOD.handle_status(
            workflow="Update flake.lock",
            status="cancelled",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "noop-status")
        self.assertEqual(len(gh.calls), 0)

    def test_ignores_other_workflow_issues(self) -> None:
        gh = FakeGh([
            {
                "number": 99,
                "title": "Automated workflow failing: Update bb",
                "createdAt": "2026-11-25T06:00:00Z",
                "comments": [],
            }
        ])
        action = MOD.handle_status(
            workflow="Update gws",
            status="failure",
            run_url=self.RUN_URL,
            today_utc="2026-11-25",
            run_gh=gh,
        )
        self.assertEqual(action, "created")


if __name__ == "__main__":
    unittest.main()
