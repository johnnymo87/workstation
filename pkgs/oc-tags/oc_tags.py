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
import sys

VERSION = "0.1.0"


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
