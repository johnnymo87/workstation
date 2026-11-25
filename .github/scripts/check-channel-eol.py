#!/usr/bin/env python3
"""Check whether workstation's NixOS release channel is nearing EOL or has a successor ready.

Reads `flake.nix` for `nixpkgs` (`nixos-YY.MM`), `home-manager` (`release-YY.MM`), and
`nix-darwin` (`nix-darwin-YY.MM`), computes the current channel's EOL date (Jun 30 for
YY.11, Dec 31 for YY.05) and next release (`YY.05` -> `YY.11`, `YY.11` -> `(YY+1).05`),
and checks GitHub for whether the next release branches exist upstream.

Opens (or updates at most once per 7 days, or immediately when upstream readiness flips
from partial to ready) one GitHub issue assigned to `johnnymo87` when either:
  - all three upstream repos have branched the next release, or
  - today is within `--warn-days` (default 45) of the current channel's EOL date.

Auto-closes obsolete `NixOS channel upgrade:` issues once the flake has moved past them.
"""

from __future__ import annotations

import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Callable

DEFAULT_LABELS = "dependencies,automated"
DEFAULT_ASSIGNEE = "johnnymo87"
DEFAULT_WARN_DAYS = 45
ISSUE_PREFIX = "NixOS channel upgrade:"

CHANNEL_PATTERNS = {
    "nixpkgs": re.compile(r'github:NixOS/nixpkgs/nixos-(\d{2}\.(?:05|11))'),
    "home-manager": re.compile(r'github:nix-community/home-manager/release-(\d{2}\.(?:05|11))'),
    "nix-darwin": re.compile(r'github:nix-darwin/nix-darwin/nix-darwin-(\d{2}\.(?:05|11))'),
}


def parse_channels(flake_text: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for name, pattern in CHANNEL_PATTERNS.items():
        match = pattern.search(flake_text)
        if not match:
            raise ValueError(f"Could not find release channel for {name} in flake.nix")
        found[name] = match.group(1)
    return found


def next_channel(channel: str) -> str:
    yy_s, mm_s = channel.split(".")
    yy = int(yy_s)
    if mm_s == "05":
        return f"{yy:02d}.11"
    if mm_s == "11":
        return f"{(yy + 1) % 100:02d}.05"
    raise ValueError(f"Unsupported NixOS channel: {channel}")


def channel_eol(channel: str) -> datetime.date:
    yy_s, mm_s = channel.split(".")
    year = 2000 + int(yy_s)
    if mm_s == "05":
        return datetime.date(year, 12, 31)
    if mm_s == "11":
        return datetime.date(year + 1, 6, 30)
    raise ValueError(f"Unsupported NixOS channel: {channel}")


def issue_title(current: str, target: str, eol: datetime.date) -> str:
    return f"{ISSUE_PREFIX} {current} -> {target} (EOL {eol.isoformat()})"


def _default_run_gh(args: list[str], stdin: str | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        ["gh", *args],
        input=stdin,
        text=True,
        capture_output=True,
        check=False,
    )
    return proc.returncode, proc.stdout, proc.stderr


def branch_exists(repo: str, branch: str, run_gh: Callable[..., tuple[int, str, str]]) -> bool:
    rc, _, stderr = run_gh(["api", f"repos/{repo}/branches/{branch}", "--silent"])
    if rc == 0:
        return True
    if "HTTP 404" in stderr or "404" in stderr:
        return False
    raise RuntimeError(f"gh api failed for {repo}@{branch} (exit {rc}): {stderr.strip()}")


def check_upstream_readiness(
    target: str,
    run_gh: Callable[..., tuple[int, str, str]],
) -> dict[str, bool]:
    # nixpkgs creates release-YY.MM first, then nixos-YY.MM once Hydra builds it.
    nixpkgs_ready = branch_exists("NixOS/nixpkgs", f"nixos-{target}", run_gh)
    nixpkgs_branched = nixpkgs_ready or branch_exists("NixOS/nixpkgs", f"release-{target}", run_gh)
    hm_ready = branch_exists("nix-community/home-manager", f"release-{target}", run_gh)
    darwin_ready = branch_exists("nix-darwin/nix-darwin", f"nix-darwin-{target}", run_gh)
    return {
        "nixpkgs_channel": nixpkgs_ready,
        "nixpkgs_release_branch": nixpkgs_branched,
        "home_manager": hm_ready,
        "nix_darwin": darwin_ready,
    }


def _last_activity_date(issue: dict[str, Any]) -> datetime.date | None:
    timestamps = [str(issue.get("createdAt") or "")]
    for c in issue.get("comments") or []:
        timestamps.append(str(c.get("createdAt") or ""))
    dates = []
    for ts in timestamps:
        if len(ts) >= 10:
            try:
                dates.append(datetime.date.fromisoformat(ts[:10]))
            except ValueError:
                pass
    return max(dates) if dates else None


def _issue_already_marked_ready(issue: dict[str, Any]) -> bool:
    texts = [str(issue.get("body") or "")]
    for c in issue.get("comments") or []:
        texts.append(str(c.get("body") or ""))
    return any("Status: **all upstream channels ready**" in t for t in texts)


def run_check(
    *,
    flake_text: str,
    today: datetime.date | None = None,
    warn_days: int = DEFAULT_WARN_DAYS,
    labels: str = DEFAULT_LABELS,
    assignee: str = DEFAULT_ASSIGNEE,
    run_gh: Callable[..., tuple[int, str, str]] = _default_run_gh,
) -> str:
    if today is None:
        today = datetime.datetime.now(datetime.timezone.utc).date()

    channels = parse_channels(flake_text)
    if len(set(channels.values())) != 1:
        raise ValueError(f"Mismatched release channels in flake.nix: {channels}")
    current = channels["nixpkgs"]
    target = next_channel(current)
    eol = channel_eol(current)
    days_left = (eol - today).days

    readiness = check_upstream_readiness(target, run_gh)
    all_ready = (
        readiness["nixpkgs_channel"]
        and readiness["home_manager"]
        and readiness["nix_darwin"]
    )
    should_alert = all_ready or (days_left <= warn_days)

    rc, raw_issues, stderr = run_gh([
        "issue",
        "list",
        "--state",
        "open",
        "--label",
        "automated",
        "--limit",
        "100",
        "--json",
        "number,title,body,createdAt,comments",
    ])
    if rc != 0:
        raise RuntimeError(f"gh issue list failed: {stderr.strip()}")
    open_issues = json.loads(raw_issues or "[]")

    expected_title = issue_title(current, target, eol)
    matching: dict[str, Any] | None = None
    for issue in open_issues:
        title = str(issue.get("title") or "")
        if not title.startswith(ISSUE_PREFIX):
            continue
        if title == expected_title:
            matching = issue
        else:
            # Obsolete channel-upgrade issue from a prior release.
            num = str(issue["number"])
            run_gh([
                "issue",
                "close",
                num,
                "--comment",
                f"Flake is now on `nixos-{current}`; closing obsolete channel upgrade reminder.",
            ])

    if not should_alert:
        return f"ok:{current}:days_left={days_left}"

    status_line = (
        "Status: **all upstream channels ready**"
        if all_ready
        else "Status: **EOL approaching — waiting on upstream branches**"
    )
    eol_note = (
        f"**{abs(days_left)} days PAST EOL** ({eol.isoformat()})"
        if days_left < 0
        else f"**{days_left} days until EOL** ({eol.isoformat()})"
    )
    body = (
        f"Workstation is currently on `nixos-{current}` ({eol_note}).\n\n"
        f"{status_line}\n\n"
        f"Upstream readiness for `{target}`:\n\n"
        f"- `NixOS/nixpkgs` (`nixos-{target}`): {'ready' if readiness['nixpkgs_channel'] else ('branched (`release-' + target + '`), awaiting `nixos-' + target + '`' if readiness['nixpkgs_release_branch'] else 'not branched')}\n"
        f"- `nix-community/home-manager` (`release-{target}`): {'ready' if readiness['home_manager'] else 'not branched'}\n"
        f"- `nix-darwin/nix-darwin` (`nix-darwin-{target}`): {'ready' if readiness['nix_darwin'] else 'not branched'}\n\n"
        "Target cadence: upgrade within ~1 month of release, before the previous channel's "
        "Jun 30 / Dec 31 EOL. Stage devbox first, then cloudbox in a quiet window, then Mac/gamebox."
    )

    if matching is None:
        args = [
            "issue",
            "create",
            "--title",
            expected_title,
            "--label",
            labels,
            "--body-file",
            "-",
        ]
        if assignee:
            args.extend(["--assignee", assignee])
        rc, _, stderr = run_gh(args, stdin=body)
        if rc != 0:
            raise RuntimeError(f"gh issue create failed: {stderr.strip()}")
        return f"created:{current}->{target}"

    num = str(matching["number"])
    flipped_ready = all_ready and not _issue_already_marked_ready(matching)
    last_date = _last_activity_date(matching)
    due_weekly = last_date is None or (today - last_date).days >= 7

    if not flipped_ready and not due_weekly:
        return f"deduped:{num}"

    rc, _, stderr = run_gh(["issue", "comment", num, "--body-file", "-"], stdin=body)
    if rc != 0:
        raise RuntimeError(f"gh issue comment failed: {stderr.strip()}")
    return f"commented:{num}:{'ready' if flipped_ready else 'weekly'}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flake", default="flake.nix")
    parser.add_argument("--warn-days", type=int, default=DEFAULT_WARN_DAYS)
    parser.add_argument("--labels", default=DEFAULT_LABELS)
    parser.add_argument("--assignee", default=DEFAULT_ASSIGNEE)
    args = parser.parse_args(argv)

    flake_text = Path(args.flake).read_text(encoding="utf-8")
    result = run_check(
        flake_text=flake_text,
        warn_days=args.warn_days,
        labels=args.labels,
        assignee=args.assignee,
    )
    print(f"check-channel-eol: {result}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
