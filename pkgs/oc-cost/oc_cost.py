#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import argparse
import sys
import sqlite3
from datetime import datetime, timezone
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


def _parse_date_to_ms(s: str, end_of_day: bool = False) -> int:
    """Parse YYYY-MM-DD as UTC midnight, return unix milliseconds.

    If end_of_day, return the *next* day's UTC midnight (exclusive end).
    Raises ValueError on malformed input.
    """
    dt = datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    if end_of_day:
        # Add 1 day so --until 2026-04-15 includes all of April 15.
        dt = dt.replace(hour=0, minute=0, second=0)
        return int(dt.timestamp() * 1000) + 86_400_000
    return int(dt.timestamp() * 1000)


def resolve_window(args: argparse.Namespace, now_ms: int) -> tuple[int, int]:
    """Return (start_ms, end_ms) for the requested window."""
    if args.since or args.until:
        start = _parse_date_to_ms(args.since) if args.since else 0
        end = _parse_date_to_ms(args.until, end_of_day=True) if args.until else now_ms
        return start, end
    return now_ms - args.days * 86_400_000, now_ms



# Reused WHERE clause keeps the three queries in sync.
_BASE_WHERE = """
    json_extract(data, '$.role') = 'assistant'
    AND json_extract(data, '$.tokens.cache.read') IS NOT NULL
    AND time_created BETWEEN :start_ms AND :end_ms
"""


def query_daily(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        SELECT date(time_created/1000, 'unixepoch') AS day,
               COUNT(*) AS msgs,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'),  0)) AS cache_read,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cache_write,
               SUM(COALESCE(json_extract(data, '$.tokens.input'),       0)) AS uncached,
               SUM(COALESCE(json_extract(data, '$.tokens.output'),      0)) AS output
        FROM message
        WHERE {_BASE_WHERE}
        GROUP BY day ORDER BY day
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def query_by_model(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        SELECT json_extract(data, '$.modelID') AS model,
               COUNT(*) AS msgs,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'),  0)) AS cache_read,
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cache_write,
               SUM(COALESCE(json_extract(data, '$.tokens.input'),       0)) AS uncached,
               SUM(COALESCE(json_extract(data, '$.tokens.output'),      0)) AS output
        FROM message
        WHERE {_BASE_WHERE}
        GROUP BY model ORDER BY cache_read DESC
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def query_size_buckets(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    cur = conn.execute(
        f"""
        WITH per_msg AS (
            SELECT
                COALESCE(json_extract(data, '$.tokens.cache.read'),  0) +
                COALESCE(json_extract(data, '$.tokens.cache.write'), 0) +
                COALESCE(json_extract(data, '$.tokens.input'),       0) AS prompt_size
            FROM message
            WHERE {_BASE_WHERE}
        )
        SELECT
            CASE
                WHEN prompt_size <=  50000 THEN '0-50k'
                WHEN prompt_size <= 100000 THEN '50-100k'
                WHEN prompt_size <= 150000 THEN '100-150k'
                WHEN prompt_size <= 200000 THEN '150-200k'
                WHEN prompt_size <= 300000 THEN '200-300k'
                ELSE '300k+'
            END AS bucket,
            COUNT(*) AS msgs,
            MIN(prompt_size) AS min_size,
            MAX(prompt_size) AS max_size
        FROM per_msg
        GROUP BY bucket ORDER BY MIN(prompt_size)
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    print(f"args = {args!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
