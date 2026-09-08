#!/usr/bin/env python3
"""oc-tags: tag opencode sessions and chart list-price consumption per tag.

The dollar figure is opencode's own recorded per-message cost. It is LIST
PRICE CONSUMED, not money billed: two $100/day ceilings in
claude-failover-proxy cap real spend near $210/day and everything past them
runs on a flat-rate Max subscription. See
docs/plans/2026-09-08-oc-tags-design.md.
"""

from __future__ import annotations

import argparse
import os
import posixpath
import sys

VERSION = "0.1.0"

_WORKTREE_MARKER = "/.worktrees/"


def auto_key(directory: str | None) -> str:
    """Fallback tag for an untagged root session, derived from its directory.

    Worktrees KEEP their slug: `mono/.worktrees/w3-pr2` -> `auto:mono/w3-pr2`.
    The slug is the epic/ticket signal and is the only free attribution this
    tool gets. Collapsing it merges ~$15k of distinct work into one band.
    """
    if not directory:
        return "auto:no-dir"
    d = directory.rstrip("/") or "/"
    if d == "/tmp" or d.startswith("/tmp/"):
        return "auto:tmp"
    if _WORKTREE_MARKER in d:
        head, _, tail = d.partition(_WORKTREE_MARKER)
        project = posixpath.basename(head) or head
        slug = tail.split("/", 1)[0]
        return f"auto:{project}/{slug}"
    return f"auto:{posixpath.basename(d) or d}"


def root_of(session_id: str, parents: dict[str, str | None]) -> str:
    """Topmost EXISTING ancestor of `session_id`.

    `parents` maps session id -> parent id (or None). A parent that is absent
    from the map is a deleted session; we stop at the last id that exists
    rather than dropping the row. Visited-set guards a cycle.
    """
    cur = session_id
    seen: set[str] = set()
    while True:
        if cur in seen:
            return cur
        seen.add(cur)
        parent = parents.get(cur)
        if not parent or parent not in parents:
            return cur
        cur = parent




def parse_args(argv: list[str]) -> argparse.Namespace:
    desc = __doc__.splitlines()[0] if __doc__ else ""
    p = argparse.ArgumentParser(prog="oc-tags", description=desc)
    sub = p.add_subparsers(dest="command", required=True)

    rep = sub.add_parser("report", help="text table of dollars by tag by day")
    rep.add_argument("--days", type=int, default=14)

    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    parse_args(sys.argv[1:] if argv is None else argv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
