#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import argparse
import sys
from typing import Optional

# Anthropic per-model rates in USD per million tokens.
# Source: https://docs.anthropic.com/en/docs/about-claude/pricing
# Update manually when rates change or new models land.
PRICES: dict[str, dict[str, float]] = {
    "claude-opus-4-7": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-6": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-5": {
        "input": 5, "output": 25, "cache_write": 6.25, "cache_read": 0.50,
    },
    "claude-opus-4-1": {
        "input": 15, "output": 75, "cache_write": 18.75, "cache_read": 1.50,
    },
    "claude-opus-4": {
        "input": 15, "output": 75, "cache_write": 18.75, "cache_read": 1.50,
    },
    "claude-sonnet-4-6": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-sonnet-4-5": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-sonnet-4": {
        "input": 3, "output": 15, "cache_write": 3.75, "cache_read": 0.30,
    },
    "claude-haiku-4-5": {
        "input": 1, "output": 5, "cache_write": 1.25, "cache_read": 0.10,
    },
    "claude-haiku-3-5": {
        "input": 0.80, "output": 4, "cache_write": 1.0, "cache_read": 0.08,
    },
}


def price_for(model_id: str) -> Optional[dict[str, float]]:
    """Look up per-million-token rates for a model id.

    Strips an @suffix (e.g. "@default", "@vertex"), tries an exact match,
    then falls back to the longest prefix match in PRICES.
    Returns None if no match is found.
    """
    base = model_id.split("@", 1)[0]
    if base in PRICES:
        return PRICES[base]
    # Longest-prefix match so claude-opus-4-6-foo prefers 4-6 over 4.
    best_key: Optional[str] = None
    for key in PRICES:
        if base.startswith(key):
            if best_key is None or len(key) > len(best_key):
                best_key = key
    return PRICES[best_key] if best_key else None


def _positive_int(value: str) -> int:
    n = int(value)
    if n <= 0:
        raise argparse.ArgumentTypeError(f"must be a positive integer, got {value}")
    return n


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments.

    --days and --since/--until are mutually exclusive. We enforce this with
    a custom check rather than argparse's add_mutually_exclusive_group
    because we want --days to coexist with neither --since nor --until being
    given (the default), but reject --days alongside *either* of them.
    """
    parser = argparse.ArgumentParser(
        prog="oc-cost",
        description=(
            "Report OpenCode token usage and API cost "
            "from ~/.local/share/opencode/opencode.db."
        ),
    )
    parser.add_argument(
        "--days", type=_positive_int, default=14,
        help="Look back N days (default: 14). Mutually exclusive with --since/--until.",
    )
    parser.add_argument("--since", help="ISO date YYYY-MM-DD (UTC midnight).")
    parser.add_argument("--until", help="ISO date YYYY-MM-DD (exclusive UTC midnight).")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of formatted text.")
    parser.add_argument("--db", help="Override path to opencode.db.")

    args = parser.parse_args(argv)

    days_explicit = "--days" in (argv or [])
    if days_explicit and (args.since or args.until):
        parser.error("--days cannot be combined with --since/--until")

    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    print(f"args = {args!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
