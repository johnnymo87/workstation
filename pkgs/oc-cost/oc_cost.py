#!/usr/bin/env python3
"""oc-cost: report OpenCode usage and cost from the local SQLite database."""

from __future__ import annotations

import argparse
import math
import sys
import os
import json
import sqlite3
from datetime import datetime, timezone
from typing import Optional

# Per-million-token rates in USD, keyed by (providerID, model base id).
# Source of truth = official provider pricing pages (NOT models.dev, which
# wrongly tiers current-gen Vertex Claude). "tier" is optional; when present
# it is a WHOLE-REQUEST long-context tier applied to all token categories once
# context (input + cache.read + cache.write) >= threshold.
RATES: dict[tuple[str, str], dict] = {
    # --- Anthropic Claude: FLAT across full context (Anthropic + Vertex + Bedrock,
    #     current gen). models.dev's >200K Vertex tier is a parsing artifact. ---
    ("anthropic", "claude-opus-4-7"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-opus-4-8"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-opus-4-6"):              {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("anthropic", "claude-sonnet-4-6"):            {"input": 3, "output": 15, "cache_read": 0.30, "cache_write": 3.75},
    ("google-vertex-anthropic", "claude-opus-4-7"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-opus-4-8"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-opus-4-6"):   {"input": 5, "output": 25, "cache_read": 0.50, "cache_write": 6.25},
    ("google-vertex-anthropic", "claude-sonnet-4-6"): {"input": 3, "output": 15, "cache_read": 0.30, "cache_write": 3.75},
    # --- Google Gemini (Vertex) ---
    ("google-vertex", "gemini-3.5-flash"):  {"input": 1.5, "output": 9, "cache_read": 0.15, "cache_write": 1.5},
    # gemini-3.1-pro-preview: 200K tier VERIFIED REAL via official Google Vertex
    # pricing (whole-request selection above 200K input tokens).
    ("google-vertex", "gemini-3.1-pro-preview"): {
        "input": 2, "output": 12, "cache_read": 0.20, "cache_write": 2,
        "tier": {"threshold": 200000, "input": 4, "output": 18, "cache_read": 0.40, "cache_write": 4},
    },
    # --- OpenAI ---
    ("openai", "gpt-5.5"): {
        "input": 5, "output": 30, "cache_read": 0.50, "cache_write": 0,
        "tier": {"threshold": 272000, "input": 10, "output": 45, "cache_read": 1, "cache_write": 0},
    },
}


def rate_for(provider: Optional[str], model_id: Optional[str]) -> Optional[dict]:
    """Look up a rate-book entry for (provider, model). Strips @suffix, tries
    exact match, then longest-prefix match on the model component within the
    same provider. Returns None if unknown or if either id is missing (a real
    DB can contain assistant rows with a null providerID/modelID)."""
    if not provider or not model_id:
        return None
    base = model_id.split("@", 1)[0]
    if (provider, base) in RATES:
        return RATES[(provider, base)]
    best: Optional[tuple[str, str]] = None
    for (prov, key) in RATES:
        if prov == provider and base.startswith(key):
            if best is None or len(key) > len(best[1]):
                best = (prov, key)
    return RATES[best] if best else None


def cost_for_message(
    provider: Optional[str], model_id: Optional[str], tokens: dict
) -> tuple[Optional[float], str]:
    """Return (cost_usd, tier_label) for one request. tier_label is one of
    'base' | 'long_context' | 'unpriced'. cost is None when unpriced.
    Whole-request tier selection: context = input + cache.read + cache.write."""
    entry = rate_for(provider, model_id)
    if entry is None:
        return None, "unpriced"
    inp = tokens.get("input", 0) or 0
    out = tokens.get("output", 0) or 0
    reasoning = tokens.get("reasoning", 0) or 0
    cache = tokens.get("cache", {}) or {}
    cr = cache.get("read", 0) or 0
    cw = cache.get("write", 0) or 0
    context = inp + cr + cw
    tier = entry.get("tier")
    if tier and context >= tier["threshold"]:
        r, label = tier, "long_context"
    else:
        r, label = entry, "base"
    cost = (inp * r["input"] + out * r["output"] + reasoning * r["output"]
            + cr * r["cache_read"] + cw * r["cache_write"]) / 1_000_000
    return cost, label



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
    parser.add_argument(
        "--by-kind", action="store_true", dest="by_kind",
        help=(
            "Add a primary-vs-subagent breakdown section. Subagent sessions "
            "are those whose row in the session table has a non-null parent_id."
        ),
    )
    parser.add_argument(
        "--reconcile", action="store_true",
        help=(
            "Expand the full per-(provider,model) reconciliation table comparing "
            "our estimate against OpenCode's recorded $.cost, plus the unpriced list. "
            "A one-line reconciliation summary is always shown regardless of this flag."
        ),
    )

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


def session_kind_map(conn: sqlite3.Connection) -> dict[str, str]:
    """Map session id -> 'primary' | 'subagent'.

    A session is 'subagent' if its `session` table row has a non-null
    `parent_id` (it was spawned by another session, e.g. via the Task tool);
    otherwise 'primary'. Used by main() to classify per-message rows for the
    --by-kind breakdown. Requires the `session` table (real opencode.db has
    it; raises sqlite3.OperationalError if absent, which main() handles).
    """
    cur = conn.execute("SELECT id, parent_id FROM session")
    return {
        row["id"]: ("subagent" if row["parent_id"] is not None else "primary")
        for row in cur.fetchall()
    }


def query_message_rows(conn: sqlite3.Connection, start_ms: int, end_ms: int) -> list[dict]:
    """Query all assistant message rows with token counts and recorded cost."""
    cur = conn.execute(
        f"""
        SELECT session_id AS session_id,
               json_extract(data, '$.providerID') AS provider,
               json_extract(data, '$.modelID') AS model,
               date(time_created/1000, 'unixepoch') AS day,
               COALESCE(json_extract(data, '$.tokens.input'), 0) AS input,
               COALESCE(json_extract(data, '$.tokens.output'), 0) AS output,
               COALESCE(json_extract(data, '$.tokens.reasoning'), 0) AS reasoning,
               COALESCE(json_extract(data, '$.tokens.cache.read'), 0) AS cache_read,
               COALESCE(json_extract(data, '$.tokens.cache.write'), 0) AS cache_write,
               COALESCE(json_extract(data, '$.cost'), 0.0) AS recorded_cost
        FROM message
        WHERE {_BASE_WHERE}
        """,
        {"start_ms": start_ms, "end_ms": end_ms},
    )
    return [dict(r) for r in cur.fetchall()]


def estimate(rows: list[dict]) -> dict:
    """Aggregate per-message estimation data per provider and model."""
    by_model_map = {}
    unpriced_list = []
    unpriced_seen = set()

    for row in rows:
        provider = row["provider"]
        model = row["model"]
        key = (provider, model)

        tokens = {
            "input": row["input"],
            "output": row["output"],
            "reasoning": row["reasoning"],
            "cache": {
                "read": row["cache_read"],
                "write": row["cache_write"],
            }
        }

        cost_usd, tier_label = cost_for_message(provider, model, tokens)

        if key not in by_model_map:
            rate_entry = rate_for(provider, model)
            priced = rate_entry is not None

            by_model_map[key] = {
                "provider": provider,
                "model": model,
                "msgs": 0,
                "input": 0,
                "output": 0,
                "reasoning": 0,
                "cache_read": 0,
                "cache_write": 0,
                "est_cost": 0.0,
                "recorded_cost": 0.0,
                "tiers": {"base": 0, "long_context": 0, "unpriced": 0},
                "priced": priced,
            }

        agg = by_model_map[key]
        agg["msgs"] += 1
        agg["input"] += row["input"]
        agg["output"] += row["output"]
        agg["reasoning"] += row["reasoning"]
        agg["cache_read"] += row["cache_read"]
        agg["cache_write"] += row["cache_write"]
        agg["recorded_cost"] += row["recorded_cost"]

        if cost_usd is not None:
            agg["est_cost"] += cost_usd

        if tier_label in agg["tiers"]:
            agg["tiers"][tier_label] += 1

        if tier_label == "unpriced":
            if key not in unpriced_seen:
                unpriced_seen.add(key)
                unpriced_list.append(key)

    by_model_list = list(by_model_map.values())

    # Sort by_model deterministically:
    # 1. est_cost descending
    # 2. recorded_cost descending
    # 3. provider ascending
    # 4. model ascending
    by_model_list.sort(key=lambda x: (-x["est_cost"], -x["recorded_cost"], x["provider"], x["model"]))

    total_est = sum(item["est_cost"] for item in by_model_list if item["priced"])

    return {
        "by_model": by_model_list,
        "total_est": total_est,
        "unpriced": unpriced_list,
    }


def reconcile(
    by_model: list[dict],
    pct_threshold: float = 5.0,
    usd_threshold: float = 5.0,
) -> dict:
    """Compare estimated vs recorded cost per row and flag material gaps.

    Does NOT mutate the input rows; returns new row dicts that copy the
    input fields and add: `delta` (= recorded_cost - est_cost), `delta_pct`
    (delta as a percentage of est_cost), and `flagged`.

    Flag rule is OR, per the design doc (§3.4): a row is flagged when
    abs(delta) > usd_threshold OR abs(delta_pct) > pct_threshold. The OR
    (not AND) ensures both a high-dollar drift and a high-percentage drift
    are caught -- this is what surfaces OpenCode's models.dev-driven recorded
    over-count on Vertex opus.

    delta_pct is guarded against a zero estimate: when est_cost == 0 it is
    0.0 if delta is also 0, else +/-inf (which always trips the pct test).
    """
    rows: list[dict] = []
    total_est = 0.0
    total_recorded = 0.0
    for row in by_model:
        est = row.get("est_cost", 0.0) or 0.0
        recorded = row.get("recorded_cost", 0.0) or 0.0
        delta = recorded - est
        if est != 0:
            delta_pct = delta / est * 100.0
        elif delta == 0:
            delta_pct = 0.0
        else:
            delta_pct = float("inf") if delta > 0 else float("-inf")
        flagged = abs(delta) > usd_threshold or abs(delta_pct) > pct_threshold
        new_row = dict(row)
        new_row["delta"] = delta
        new_row["delta_pct"] = delta_pct
        new_row["flagged"] = flagged
        rows.append(new_row)
        total_est += est
        total_recorded += recorded
    return {
        "rows": rows,
        "total_est": total_est,
        "total_recorded": total_recorded,
        "total_delta": total_recorded - total_est,
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


def _short_label(label: str, width: int = 40) -> str:
    """Truncate a provider/model label to `width`, keeping the TAIL (model id
    + version + @suffix) rather than the common provider prefix, so otherwise
    near-identical rows (e.g. .../claude-opus-4-7 vs -4-6) stay distinguishable."""
    if len(label) <= width:
        return label
    return ".." + label[-(width - 2):]


def _pct(part: float, total: float) -> str:
    return f"{(part / total * 100):.1f}" if total > 0 else "0.0"


def _ms_to_iso(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _json_safe_recrow(row: dict) -> dict:
    """Copy a reconciliation row, coercing a non-finite delta_pct (the
    zero-estimate +/-inf sentinel) to None so render_json emits valid,
    RFC 8259-compliant JSON (no bare Infinity/NaN literals)."""
    out = dict(row)
    dpct = out.get("delta_pct")
    if not (isinstance(dpct, (int, float)) and math.isfinite(dpct)):
        out["delta_pct"] = None
    return out


def render_json(report: dict) -> str:
    # allow_nan=False guarantees we never emit non-standard Infinity/NaN tokens;
    # report values are pre-sanitized in main() so this should never trip.
    return json.dumps(report, indent=2, sort_keys=True, allow_nan=False)


def render_text(report: dict) -> str:
    lines: list[str] = []
    daily = report["daily"]
    meta = report["meta"]

    if not daily:
        lines.append(
            f"\n  No usage data in window {meta['window']['start']} → "
            f"{meta['window']['end']}.\n"
        )
        lines.append(f"Database: {meta['db_path']}\n")
        return "\n".join(lines)

    est = report["estimate"]
    rec = report["reconciliation"]
    buckets = report["size_buckets"]
    reconcile_full = meta.get("reconcile", False)

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

    # Per-model estimated cost section (own rate book, per-request tiers).
    lines.append("\n\n  Per-Model Estimated Cost (own rate book, per-request tiers)\n")
    lines.append("PROVIDER/MODEL                           MSGS   CACHE_RD(M)  CACHE_WR(M)  OUTPUT(M)       EST$")
    lines.append("-" * 100)
    for m in est["by_model"]:
        cr_M = m["cache_read"]  / 1e6
        cw_M = m["cache_write"] / 1e6
        ou_M = m["output"]      / 1e6
        if m["priced"]:
            cost_tag = _fmt_usd(m["est_cost"]).rjust(10)
        else:
            cost_tag = " (unpriced)"
        name = _short_label(f"{m['provider']}/{m['model']}", 40)
        lines.append(
            f"{name:<40} {str(m['msgs']):>5}  "
            f"{cr_M:>10.1f}  {cw_M:>10.1f}  {ou_M:>8.1f}  {cost_tag}"
        )
    lines.append("-" * 100)
    lines.append(
        f"{'TOTAL (estimated, priced only)':<40} {'':>5}  "
        f"{'':>10}  {'':>10}  {'':>8}  "
        f"{_fmt_usd(est['total_est']):>10}"
    )

    # Reconciliation summary line (always shown).
    lines.append("\n\n  Reconciliation (estimated vs recorded $.cost)\n")
    lines.append(
        f"  Estimated: {_fmt_usd(rec['total_est'])}   |   "
        f"Recorded: {_fmt_usd(rec['total_recorded'])}   |   "
        f"Δ (recorded−estimated): {_fmt_usd(rec['total_delta'])}"
    )

    if reconcile_full:
        # Full per-(provider,model) reconciliation table (priced rows only).
        lines.append("")
        lines.append("PROVIDER/MODEL                           MSGS        EST$   RECORDED$        Δ$      Δ%   FLAG")
        lines.append("-" * 100)
        for r in rec["rows"]:
            name = _short_label(f"{r['provider']}/{r['model']}", 40)
            dpct = r.get("delta_pct")
            pct_tag = f"{dpct:>6.1f}" if isinstance(dpct, (int, float)) else "   n/a"
            flag_tag = "  FLAG" if r.get("flagged") else ""
            lines.append(
                f"{name:<40} {str(r.get('msgs', '')):>5}  "
                f"{_fmt_usd(r['est_cost']):>10}  "
                f"{_fmt_usd(r['recorded_cost']):>10}  "
                f"{_fmt_usd(r['delta']):>8}  {pct_tag}{flag_tag}"
            )

        # Unpriced models: recorded cost known, estimate is n/a. Excluded from
        # the estimated total; never silently folded into $0.
        unpriced_rows = [m for m in est["by_model"] if not m["priced"]]
        if unpriced_rows:
            lines.append("")
            lines.append("  Unpriced (excluded from estimate; recorded shown for reference):")
            for m in unpriced_rows:
                label = f"{m['provider']}/{m['model']}"
                lines.append(
                    f"    {label:<44} msgs {str(m['msgs']):>6}   "
                    f"recorded {_fmt_usd(m['recorded_cost'])}   estimated n/a"
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

    # Optional: primary-vs-subagent breakdown (only when --by-kind was set)
    by_kind = report.get("by_kind")
    if by_kind:
        lines.append("\n\n  Primary vs Subagent (estimated, per-request tiers)\n")
        lines.append("KIND       SESSIONS  MSGS    CACHE_RD(M)  CACHE_WR(M)  OUTPUT(M)       EST$")
        lines.append("-" * 80)
        kind_total = 0.0
        for k in by_kind:
            cost_tag = (
                _fmt_usd(k["cost_usd"]).rjust(11)
                if k.get("cost_usd") is not None
                else "  (no rate)"
            )
            if k.get("cost_usd") is not None:
                kind_total += k["cost_usd"]
            lines.append(
                f"{k['kind']:<10} {str(k['sessions']):>8}  {str(k['msgs']):>5}  "
                f"{k['cache_read'] / 1e6:>10.1f}  "
                f"{k['cache_write'] / 1e6:>10.1f}  "
                f"{k['output'] / 1e6:>8.1f}  {cost_tag}"
            )
        lines.append("-" * 80)
        # The kind subtotal can differ from the overall estimated total because
        # unpriced models are excluded from both (so they cancel out).
        lines.append(f"  {'(kind subtotal)':<43}{_fmt_usd(kind_total):>33}")

    lines.append(
        f"\nPeriod: {daily[0]['day']} to {daily[-1]['day']} "
        f"({len(daily)} active days)"
    )
    lines.append(f"Database: {meta['db_path']}\n")
    return "\n".join(lines)


def summarize_by_kind(rows: list[dict], kind_map: dict[str, str]) -> list[dict]:
    """Build a primary-vs-subagent summary from per-message rows.

    Classifies each message row by its session's kind (defaulting to
    'primary' when a session id is absent from the map), then runs the
    same per-request tier-aware `estimate()` over each kind's rows. Returns
    rows shaped for the render/JSON by-kind section: kind, sessions (distinct
    session ids in that kind), msgs, token sums, recorded_cost, and est-derived
    cost_usd (None when nothing priced). Primary is listed before subagent.
    """
    buckets: dict[str, list[dict]] = {"primary": [], "subagent": []}
    sessions: dict[str, set] = {"primary": set(), "subagent": set()}
    for r in rows:
        kind = kind_map.get(r.get("session_id"), "primary")
        buckets[kind].append(r)
        sessions[kind].add(r.get("session_id"))

    summary: list[dict] = []
    for kind in ("primary", "subagent"):
        krows = buckets[kind]
        if not krows:
            continue
        kest = estimate(krows)
        summary.append({
            "kind":          kind,
            "sessions":      len(sessions[kind]),
            "msgs":          len(krows),
            "cache_read":    sum(r["cache_read"]  for r in krows),
            "cache_write":   sum(r["cache_write"] for r in krows),
            "uncached":      sum(r["input"]       for r in krows),
            "output":        sum(r["output"]      for r in krows),
            "recorded_cost": sum(r["recorded_cost"] for r in krows),
            "cost_usd":      kest["total_est"] if kest["total_est"] > 0 else None,
        })
    return summary


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    db_path = args.db or _DEFAULT_DB
    now_ms = int(datetime.now(tz=timezone.utc).timestamp() * 1000)
    start_ms, end_ms = resolve_window(args, now_ms)

    conn = connect(db_path)

    try:
        try:
            daily   = query_daily(conn, start_ms, end_ms)
            rows    = query_message_rows(conn, start_ms, end_ms)
            buckets = query_size_buckets(conn, start_ms, end_ms)
        except sqlite3.OperationalError as e:
            if "locked" in str(e).lower():
                print("Database busy. Retry in a moment.", file=sys.stderr)
                return 2
            raise

        # Headline cost is our own per-request tier-aware estimate; recorded
        # $.cost is shown alongside via reconciliation. Only priced rows are
        # reconciled; unpriced models are surfaced separately (never $0).
        est = estimate(rows)
        priced_rows = [r for r in est["by_model"] if r["priced"]]
        rec = reconcile(priced_rows)

        report = {
            "meta": {
                "db_path": db_path,
                "window": {"start": _ms_to_iso(start_ms), "end": _ms_to_iso(end_ms)},
                "active_days": len(daily),
                "reconcile": args.reconcile,
            },
            "daily": daily,
            "estimate": {
                "total_est": est["total_est"],
                "by_model": est["by_model"],
                "unpriced": [list(t) for t in est["unpriced"]],
            },
            "reconciliation": {
                "rows": [_json_safe_recrow(r) for r in rec["rows"]],
                "total_est": rec["total_est"],
                "total_recorded": rec["total_recorded"],
                "total_delta": rec["total_delta"],
            },
            "size_buckets": buckets,
        }

        if args.by_kind:
            try:
                kind_map = session_kind_map(conn)
            except sqlite3.OperationalError as e:
                # Defensive: if the session table is missing, skip the
                # breakdown rather than failing the whole report.
                print(
                    f"Warning: --by-kind unavailable ({e}); skipping breakdown.",
                    file=sys.stderr,
                )
                kind_map = None
            if kind_map is not None:
                report["by_kind"] = summarize_by_kind(rows, kind_map)
    finally:
        conn.close()

    if args.json:
        print(render_json(report))
    else:
        print(render_text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
