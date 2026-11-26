#!/usr/bin/env python3
"""Open, deduplicate, and auto-close GitHub issues for failing scheduled workflows.

Called from the final `if: always()` step of `.github/workflows/update-*.yml`:
  - On `failure`: opens one issue per workflow (assigned to johnnymo87, labeled
    `automated`). If an open issue already exists, posts at most one follow-up
    comment per UTC day so 6h/8h cron workflows do not spam.
  - On `success`: closes any open failure issue for that workflow with a
    recovery comment.
  - On `cancelled` (or skipped): does nothing.
"""

from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
from typing import Any, Callable

DEFAULT_LABEL = "automated"
DEFAULT_ASSIGNEE = "johnnymo87"


def issue_title(workflow: str) -> str:
    return f"Automated workflow failing: {workflow}"


def _default_run_gh(args: list[str], stdin: str | None = None) -> str:
    proc = subprocess.run(
        ["gh", *args],
        input=stdin,
        text=True,
        capture_output=True,
        check=True,
    )
    return proc.stdout


def find_open_issue(
    title: str,
    label: str,
    run_gh: Callable[..., str],
) -> dict[str, Any] | None:
    raw = run_gh([
        "issue",
        "list",
        "--state",
        "open",
        "--label",
        label,
        "--limit",
        "100",
        "--json",
        "number,title,createdAt,comments",
    ])
    issues = json.loads(raw or "[]")
    for issue in issues:
        if issue.get("title") == title:
            return issue
    return None


def _has_activity_today(issue: dict[str, Any], today_utc: str) -> bool:
    created = str(issue.get("createdAt") or "")
    if created.startswith(today_utc):
        return True
    for comment in issue.get("comments") or []:
        c_date = str(comment.get("createdAt") or "")
        if c_date.startswith(today_utc):
            return True
    return False


def handle_status(
    *,
    workflow: str,
    status: str,
    run_url: str,
    today_utc: str | None = None,
    label: str = DEFAULT_LABEL,
    assignee: str = DEFAULT_ASSIGNEE,
    run_gh: Callable[..., str] = _default_run_gh,
) -> str:
    """Apply the failure/recovery issue state transition. Returns a short action tag."""
    if today_utc is None:
        today_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

    title = issue_title(workflow)
    norm_status = status.strip().lower()

    if norm_status not in ("failure", "success"):
        return "noop-status"

    existing = find_open_issue(title, label, run_gh)

    if norm_status == "success":
        if existing is None:
            return "noop-clean"
        number = str(existing["number"])
        run_gh([
            "issue",
            "close",
            number,
            "--comment",
            f"Workflow recovered on {today_utc}: {run_url}",
        ])
        return f"closed:{number}"

    # norm_status == "failure"
    if existing is None:
        body = (
            f"The `{workflow}` workflow failed on {today_utc}.\n\n"
            f"- Run: {run_url}\n\n"
            "This issue will receive at most one follow-up comment per UTC day while "
            "the workflow keeps failing, and will close automatically once a run succeeds."
        )
        args = [
            "issue",
            "create",
            "--title",
            title,
            "--label",
            label,
            "--body-file",
            "-",
        ]
        if assignee:
            args.extend(["--assignee", assignee])
        run_gh(args, stdin=body)
        return "created"

    number = str(existing["number"])
    if _has_activity_today(existing, today_utc):
        return f"deduped:{number}"

    run_gh([
        "issue",
        "comment",
        number,
        "--body",
        f"Still failing on {today_utc}: {run_url}",
    ])
    return f"commented:{number}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", required=True, help="Workflow (or workflow + matrix leg) name")
    parser.add_argument("--status", required=True, help="GitHub Actions job.status value")
    parser.add_argument("--run-url", required=True, help="URL of the workflow run")
    parser.add_argument("--label", default=DEFAULT_LABEL)
    parser.add_argument("--assignee", default=DEFAULT_ASSIGNEE)
    args = parser.parse_args(argv)

    action = handle_status(
        workflow=args.workflow,
        status=args.status,
        run_url=args.run_url,
        label=args.label,
        assignee=args.assignee,
    )
    print(f"report-workflow-failure: {action}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
