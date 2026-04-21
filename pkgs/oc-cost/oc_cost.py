#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import argparse
import sys
import os
import json
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
    # Gemini 3.1 Pro Preview (Vertex AI / AI Studio).
    # Rates are for the <=200k context tier as published 2026-04. The >200k
    # tier doubles input ($4.00) and bumps output to $18.00 / cache_read to
    # $0.40 -- not modelled here because oc-cost has no per-request context
    # window data.
    #
    # IMPORTANT: Google bills cache CREATION at the standard input rate
    # ($2.00/MTok) AND charges a separate token-hour STORAGE fee
    # (~$4.50/MTok-hour) for as long as the cache lives. oc-cost's schema
    # only captures per-token rates, so we set cache_write to the creation
    # rate ($2.00). This UNDERCOUNTS Gemini cache cost for long-lived
    # caches; the storage component is invisible to this tool. See README.
    "gemini-3.1-pro-preview": {
        "input": 2.00, "output": 12.00, "cache_write": 2.00, "cache_read": 0.20,
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


def compute_cost_components(by_model: list[dict], active_days: int) -> dict:
    """Compute cost components, applying each model's own rates.

    Mutates each `by_model` row in place to add `cost_usd` (None for
    unknown models). Returns a dict with per-component totals plus
    daily_avg, monthly_proj, and a list of unpriced model names.
    """
    cache_reads = cache_writes = uncached_input = output = 0.0
    unpriced: list[str] = []

    for row in by_model:
        rates = price_for(row["model"])
        if rates is None:
            row["cost_usd"] = None
            unpriced.append(row["model"])
            continue
        # USD = tokens * rate / 1e6
        cr = row["cache_read"]  * rates["cache_read"]  / 1e6
        cw = row["cache_write"] * rates["cache_write"] / 1e6
        un = row["uncached"]    * rates["input"]       / 1e6
        ou = row["output"]      * rates["output"]      / 1e6
        row["cost_usd"] = cr + cw + un + ou
        cache_reads    += cr
        cache_writes   += cw
        uncached_input += un
        output         += ou

    total = cache_reads + cache_writes + uncached_input + output
    daily_avg = total / active_days if active_days > 0 else 0.0

    return {
        "cache_reads":     cache_reads,
        "cache_writes":    cache_writes,
        "uncached_input":  uncached_input,
        "output":          output,
        "total":           total,
        "daily_avg":       daily_avg,
        "monthly_proj":    daily_avg * 30,
        "unpriced_models": unpriced,
    }


_DEFAULT_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")


def connect(db_path: str) -> sqlite3.Connection:
    """Open opencode.db in read-only mode. Exits 1 on missing or wrong-schema DB."""
    if not os.path.exists(db_path):
        print(
            f"Database not found: {db_path}. "
            f"Set --db or check OPENCODE_DATA_DIR.",
            file=sys.stderr,
        )
        sys.exit(1)
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    # Confirm it's an OpenCode DB.
    cur = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='message'"
    )
    if cur.fetchone() is None:
        print(
            f"Not an OpenCode database (missing 'message' table): {db_path}",
            file=sys.stderr,
        )
        sys.exit(1)
    return conn


def _fmt_usd(n: float) -> str:
    return f"${n:.2f}"


def _pct(part: float, total: float) -> str:
    return f"{(part / total * 100):.1f}" if total > 0 else "0.0"


def _ms_to_iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def render_json(report: dict) -> str:
    return json.dumps(report, indent=2, sort_keys=True)


def render_text(report: dict) -> str:
    lines: list[str] = []
    daily = report["daily"]
    by_model = report["by_model"]
    components = report["cost_components"]
    buckets = report["size_buckets"]
    meta = report["meta"]

    if not daily:
        lines.append(
            f"\n  No usage data in window {meta['window']['start']} → "
            f"{meta['window']['end']}.\n"
        )
        lines.append(f"Database: {meta['db_path']}\n")
        return "\n".join(lines)

    # Daily section
    lines.append(f"\n  OpenCode Usage Report ({meta['active_days']} active days)\n")
    lines.append("DATE        MSGS   READ%  WRITE%  UNCACHED%")
    lines.append("-" * 52)
    for d in daily:
        total = d["cache_read"] + d["cache_write"] + d["uncached"]
        lines.append(
            f"{d['day']}  {str(d['msgs']):>5}  "
            f"{_pct(d['cache_read'], total):>5}%  "
            f"{_pct(d['cache_write'], total):>5}%    "
            f"{_pct(d['uncached'], total):>5}%"
        )

    # Per-model section
    lines.append("\n\n  Per-Model Cost Breakdown\n")
    lines.append("MODEL                          MSGS   CACHE_RD(M)  CACHE_WR(M)  OUTPUT(M)   COST")
    lines.append("-" * 90)
    grand_cache_read = grand_cache_write = grand_output = 0
    grand_total = 0.0
    for m in by_model:
        cr_M = m["cache_read"]  / 1e6
        cw_M = m["cache_write"] / 1e6
        ou_M = m["output"]      / 1e6
        grand_cache_read  += m["cache_read"]
        grand_cache_write += m["cache_write"]
        grand_output      += m["output"]
        if m["cost_usd"] is not None:
            grand_total += m["cost_usd"]
            cost_tag = _fmt_usd(m["cost_usd"]).rjust(10)
        else:
            cost_tag = "  (no rate)"
        name = m["model"][:28] + ".." if len(m["model"]) > 28 else m["model"]
        lines.append(
            f"{name:<30} {str(m['msgs']):>5}  "
            f"{cr_M:>10.1f}  {cw_M:>10.1f}  {ou_M:>8.1f}  {cost_tag}"
        )
    lines.append("-" * 90)
    lines.append(
        f"{'TOTAL':<30} {'':>5}  "
        f"{grand_cache_read / 1e6:>10.1f}  "
        f"{grand_cache_write / 1e6:>10.1f}  "
        f"{grand_output / 1e6:>8.1f}  "
        f"{_fmt_usd(grand_total):>10}"
    )

    # Cost components section
    total = components["total"]
    lines.append("\n\n  Cost Components (per-model rates applied separately)\n")
    lines.append(
        f"  Cache reads:   {_fmt_usd(components['cache_reads']):>10}  "
        f"({_pct(components['cache_reads'], total)}%)"
    )
    lines.append(
        f"  Cache writes:  {_fmt_usd(components['cache_writes']):>10}  "
        f"({_pct(components['cache_writes'], total)}%)"
    )
    lines.append(
        f"  Uncached in:   {_fmt_usd(components['uncached_input']):>10}  "
        f"({_pct(components['uncached_input'], total)}%)"
    )
    lines.append(
        f"  Output:        {_fmt_usd(components['output']):>10}  "
        f"({_pct(components['output'], total)}%)"
    )
    lines.append(f"  {'─' * 30}")
    lines.append(f"  Total:         {_fmt_usd(total):>10}")
    lines.append(f"  Daily avg:     {_fmt_usd(components['daily_avg']):>10}")
    lines.append(f"  Monthly proj:  {_fmt_usd(components['monthly_proj']):>10}")
    if components["unpriced_models"]:
        lines.append(
            f"\n  Unpriced models (excluded from total): "
            f"{', '.join(components['unpriced_models'])}"
        )

    # Size buckets section
    total_msgs = sum(b["msgs"] for b in buckets)
    lines.append("\n\n  Prompt Size Distribution\n")
    lines.append("BUCKET       MSGS    %     MIN(k)   MAX(k)")
    lines.append("-" * 50)
    for b in buckets:
        lines.append(
            f"{b['bucket']:<12} {str(b['msgs']):>5}  "
            f"{_pct(b['msgs'], total_msgs):>5}%  "
            f"{b['min_size'] / 1000:>7.1f}  "
            f"{b['max_size'] / 1000:>7.1f}"
        )

    lines.append(
        f"\nPeriod: {daily[0]['day']} to {daily[-1]['day']} "
        f"({len(daily)} active days)"
    )
    lines.append(f"Database: {meta['db_path']}\n")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    db_path = args.db or _DEFAULT_DB
    now_ms = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
    start_ms, end_ms = resolve_window(args, now_ms)

    conn = connect(db_path)

    try:
        daily   = query_daily(conn, start_ms, end_ms)
        by_model = query_by_model(conn, start_ms, end_ms)
        buckets = query_size_buckets(conn, start_ms, end_ms)
    except sqlite3.OperationalError as e:
        if "locked" in str(e).lower():
            print("Database busy. Retry in a moment.", file=sys.stderr)
            return 2
        raise

    components = compute_cost_components(by_model, active_days=max(len(daily), 1))

    report = {
        "meta": {
            "db_path": db_path,
            "window": {"start": _ms_to_iso(start_ms), "end": _ms_to_iso(end_ms)},
            "active_days": len(daily),
        },
        "daily": daily,
        "by_model": by_model,
        "cost_components": components,
        "size_buckets": buckets,
    }

    if args.json:
        print(render_json(report))
    else:
        print(render_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
