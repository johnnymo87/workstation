#!/usr/bin/env python3
"""oc-context -- how full is each OpenCode session's context window?

Answers "which of my ~10 concurrent sessions should compact?" by printing, per
session, the estimated live context size in tokens, the model's context window,
and the percentage used, sorted fullest-first.

WHAT THE NUMBER IS (read this before trusting it)
-------------------------------------------------
For each session we take the LAST assistant message that is not a compaction
summary and that has non-zero token accounting, and report its `tokens.total`:

    total = input + output + reasoning + cache.read + cache.write

`input + cache.read + cache.write` is the prompt the provider actually billed
for that request -- i.e. the context size AT that request. Adding `output +
reasoning` accounts for the model's own reply, which becomes part of the next
request's prompt. So `total` is a forward estimate of the prompt size of the
NEXT request in that session.

This is the same quantity OpenCode's own TUI footer displays, with one
deliberate difference: we SKIP messages with `summary: true`. Those are
compaction calls, made by a different (cheap) model against the pre-compaction
transcript; the TUI's `findLast` picks them up and shows their usage -- against
the wrong model's context window -- for one message after every compaction.

Measured accuracy (cloudbox, 8,291 consecutive same-model message pairs over
24h): next request's actual prompt minus previous message's `total` had a
median of +292 tokens, p05 +13, p95 +5,244, and was within 2,000 tokens 86% of
the time. The estimate runs slightly LOW because tokens added since the last
completed request (a user message, a tool result not yet sent) are not in it.

See README.md for the full list of what this does NOT capture.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable

DEFAULT_DB = "~/.local/share/opencode/opencode.db"
DEFAULT_STATE_DIR = "~/.local/share/opencode/session-state.d"
DEFAULT_MODELS_JSON = "~/.cache/opencode/models.json"
# The front door. Never address an individual serve (127.0.0.1:4096-4099) --
# see the front-door opacity guard in users/dev/test-frontdoor-opacity.sh.
DEFAULT_SERVER = "http://127.0.0.1:4700"

# A session-state overlay whose heartbeat is older than this is treated as a
# dead TUI, not a live session. Observed live heartbeats are 1-13s old.
DEFAULT_LIVE_WINDOW_S = 120


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="oc-context",
        description="Report OpenCode session context usage (tokens, window, %% used).",
    )
    p.add_argument(
        "sessions",
        nargs="*",
        help="Session ids to report. Default: every session with a live TUI heartbeat.",
    )
    p.add_argument(
        "--recent",
        type=float,
        metavar="HOURS",
        help="Instead of live sessions, report sessions updated within HOURS.",
    )
    p.add_argument(
        "--children",
        action="store_true",
        help="Include child (subagent) sessions. Default: root sessions only.",
    )
    p.add_argument(
        "--min-percent",
        type=float,
        default=0.0,
        metavar="P",
        help="Only show sessions at or above P%% of their context window.",
    )
    p.add_argument("--json", action="store_true", help="Machine-readable output.")
    p.add_argument("--db", help=f"Path to opencode.db (default: {DEFAULT_DB})")
    p.add_argument(
        "--state-dir", help=f"Session-state overlay dir (default: {DEFAULT_STATE_DIR})"
    )
    p.add_argument(
        "--models-json", help=f"models.dev catalog cache (default: {DEFAULT_MODELS_JSON})"
    )
    p.add_argument(
        "--server",
        default=DEFAULT_SERVER,
        help=f"OpenCode front door, for the authoritative model catalog (default: {DEFAULT_SERVER})",
    )
    p.add_argument(
        "--no-server",
        action="store_true",
        help="Do not query the server; use the models.json cache only.",
    )
    p.add_argument(
        "--live-window",
        type=float,
        default=DEFAULT_LIVE_WINDOW_S,
        metavar="SECONDS",
        help=f"Max session-state heartbeat age to count as live (default: {DEFAULT_LIVE_WINDOW_S})",
    )
    args = p.parse_args(argv)

    if args.recent is not None and args.recent <= 0:
        p.error("--recent must be > 0")
    if args.live_window <= 0:
        p.error("--live-window must be > 0")
    if args.sessions and args.recent is not None:
        p.error("pass either explicit session ids or --recent, not both")

    return args


# --------------------------------------------------------------------------
# Model catalog: (providerID, modelID) -> context window
# --------------------------------------------------------------------------


def catalog_from_server_payload(payload: Any) -> dict[tuple[str, str], int]:
    """Parse GET /config/providers into {(provider, model): context_limit}."""
    out: dict[tuple[str, str], int] = {}
    providers = (payload or {}).get("providers") or []
    for prov in providers:
        pid = prov.get("id")
        if not pid:
            continue
        for mid, model in (prov.get("models") or {}).items():
            limit = ((model or {}).get("limit") or {}).get("context")
            if isinstance(limit, int) and limit > 0:
                out[(pid, mid)] = limit
    return out


def catalog_from_models_json(payload: Any) -> dict[tuple[str, str], int]:
    """Parse the models.dev cache into {(provider, model): context_limit}."""
    out: dict[tuple[str, str], int] = {}
    for pid, prov in (payload or {}).items():
        if not isinstance(prov, dict):
            continue
        for mid, model in (prov.get("models") or {}).items():
            limit = ((model or {}).get("limit") or {}).get("context")
            if isinstance(limit, int) and limit > 0:
                out[(pid, mid)] = limit
    return out


def fetch_server_catalog(server: str, timeout: float = 5.0) -> dict[tuple[str, str], int]:
    url = server.rstrip("/") + "/config/providers"
    with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310
        return catalog_from_server_payload(json.loads(resp.read().decode("utf-8")))


def load_catalog(args: argparse.Namespace) -> tuple[dict[tuple[str, str], int], str]:
    """Return (catalog, source-label).

    The server is preferred: it reflects opencode.json overrides (models the
    local config declares outright, or whose limits it rewrites), which the
    models.dev cache does not know about. The cache is the offline fallback.
    """
    if not args.no_server:
        try:
            cat = fetch_server_catalog(args.server)
            if cat:
                return cat, args.server
        except (urllib.error.URLError, OSError, ValueError, TimeoutError):
            pass

    path = Path(os.path.expanduser(args.models_json or DEFAULT_MODELS_JSON))
    try:
        return catalog_from_models_json(json.loads(path.read_text())), str(path)
    except (OSError, ValueError):
        return {}, "none"


def lookup_window(
    catalog: dict[tuple[str, str], int], provider: str | None, model: str | None
) -> int | None:
    """Context window for a (provider, model), with a longest-prefix fallback.

    The fallback mirrors oc-cost: a model id may carry a suffix the catalog
    does not have (`@default`, a date pin), so try the exact key, then the
    longest catalog key in the same provider that the model id starts with.
    """
    if not provider or not model:
        return None
    exact = catalog.get((provider, model))
    if exact:
        return exact
    best_key = ""
    best_val: int | None = None
    for (pid, mid), limit in catalog.items():
        if pid != provider:
            continue
        if model.startswith(mid) and len(mid) > len(best_key):
            best_key, best_val = mid, limit
    return best_val


# --------------------------------------------------------------------------
# Live-session discovery (session-state.d overlays)
# --------------------------------------------------------------------------


def read_live_sessions(
    state_dir: str, now_ms: float, window_s: float
) -> dict[str, dict[str, Any]]:
    """Sessions with a fresh serve heartbeat, i.e. an attached/running TUI.

    Each overlay file is one serve instance: {pid, serveId, directory,
    heartbeat, sessions: {<id>: {activity, error, ...}}}. A stale heartbeat
    means the serve (or the whole box) went away and the entry is a leftover.
    """
    out: dict[str, dict[str, Any]] = {}
    cutoff = now_ms - window_s * 1000
    for path in sorted(glob.glob(os.path.join(os.path.expanduser(state_dir), "*.json"))):
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict):
            continue
        heartbeat = doc.get("heartbeat")
        if not isinstance(heartbeat, (int, float)) or heartbeat < cutoff:
            continue
        for sid, state in (doc.get("sessions") or {}).items():
            state = state if isinstance(state, dict) else {}
            out[sid] = {
                "activity": state.get("activity"),
                "error": bool(state.get("error")),
                "serve_directory": doc.get("directory"),
                "heartbeat": heartbeat,
            }
    return out


# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    conn.execute("PRAGMA busy_timeout=2000")
    return conn


def select_sessions(
    conn: sqlite3.Connection,
    *,
    ids: Iterable[str] | None,
    recent_hours: float | None,
    include_children: bool,
    now_ms: float,
) -> list[dict[str, Any]]:
    where = []
    params: list[Any] = []
    ids = list(ids or [])
    if ids:
        where.append(f"id IN ({','.join('?' * len(ids))})")
        params.extend(ids)
    if recent_hours is not None:
        where.append("time_updated >= ?")
        params.append(now_ms - recent_hours * 3600 * 1000)
    if not include_children:
        where.append("parent_id IS NULL")
    sql = (
        "SELECT id, parent_id, title, directory, agent, time_updated "
        "FROM session"
        + (" WHERE " + " AND ".join(where) if where else "")
        + " ORDER BY time_updated DESC"
    )
    return [dict(r) for r in conn.execute(sql, params)]


# The tail scan is bounded by the (session_id, time_created, id) index, so this
# is a short backward walk, not a table scan.
_LAST_MSG_SQL = """
SELECT data FROM message
WHERE session_id = ?
  AND json_extract(data, '$.role') = 'assistant'
  AND IFNULL(json_extract(data, '$.summary'), 0) = 0
ORDER BY time_created DESC, id DESC
LIMIT 40
"""

_LAST_COMPACTION_SQL = """
SELECT MAX(time_created) FROM message
WHERE session_id = ?
  AND json_extract(data, '$.summary') = 1
"""


def message_total_tokens(data: dict[str, Any] | None) -> int:
    """`tokens.total`, recomputed from parts when the field is absent.

    Verified against 45,713 assistant messages: `total` equals
    input + output + reasoning + cache.read + cache.write, and is present on
    all but 77 of them (in-flight or errored messages, which are all zero).
    """
    tokens = (data or {}).get("tokens") or {}
    total = tokens.get("total")
    if isinstance(total, (int, float)) and total > 0:
        return int(total)
    cache = tokens.get("cache") or {}
    return int(
        (tokens.get("input") or 0)
        + (tokens.get("output") or 0)
        + (tokens.get("reasoning") or 0)
        + (cache.get("read") or 0)
        + (cache.get("write") or 0)
    )


def last_context_message(conn: sqlite3.Connection, session_id: str) -> dict[str, Any] | None:
    """Newest non-compaction assistant message carrying real token accounting."""
    for row in conn.execute(_LAST_MSG_SQL, (session_id,)):
        try:
            data = json.loads(row["data"])
        except ValueError:
            continue
        if message_total_tokens(data) > 0:
            return data
    return None


def last_compaction_ms(conn: sqlite3.Connection, session_id: str) -> int | None:
    row = conn.execute(_LAST_COMPACTION_SQL, (session_id,)).fetchone()
    value = row[0] if row else None
    return int(value) if value else None


# --------------------------------------------------------------------------
# Row assembly
# --------------------------------------------------------------------------


def build_rows(
    conn: sqlite3.Connection,
    sessions: list[dict[str, Any]],
    catalog: dict[tuple[str, str], int],
    live: dict[str, dict[str, Any]],
    now_ms: float,
) -> list[dict[str, Any]]:
    rows = []
    for sess in sessions:
        sid = sess["id"]
        msg = last_context_message(conn, sid)
        tokens = message_total_tokens(msg) if msg else None
        provider = (msg or {}).get("providerID")
        model = (msg or {}).get("modelID")
        window = lookup_window(catalog, provider, model)
        percent = (
            round(100.0 * tokens / window, 1) if tokens and window else None
        )
        compacted = last_compaction_ms(conn, sid)
        state = live.get(sid) or {}
        rows.append(
            {
                "session_id": sid,
                "parent_id": sess.get("parent_id"),
                "title": sess.get("title") or "",
                "directory": sess.get("directory") or "",
                "agent": (msg or {}).get("agent") or sess.get("agent") or "",
                "provider_id": provider,
                "model_id": model,
                "tokens": tokens,
                "context_window": window,
                "percent": percent,
                "headroom": (window - tokens) if (tokens and window) else None,
                "measured_at_ms": ((msg or {}).get("time") or {}).get("completed")
                or ((msg or {}).get("time") or {}).get("created"),
                "session_updated_ms": sess.get("time_updated"),
                "last_compaction_ms": compacted,
                "live": sid in live,
                "activity": state.get("activity"),
                "error": state.get("error", False),
            }
        )
    # Fullest first; sessions we could not measure sink to the bottom.
    rows.sort(key=lambda r: (r["percent"] is None, -(r["percent"] or 0.0)))
    return rows


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------


def human_tokens(n: int | None) -> str:
    if n is None:
        return "-"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.2f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)


def human_age(ms: float | None, now_ms: float) -> str:
    if not ms:
        return "-"
    secs = max(0, (now_ms - ms) / 1000)
    if secs < 90:
        return f"{int(secs)}s"
    if secs < 5400:
        return f"{int(secs / 60)}m"
    if secs < 86400 * 2:
        return f"{int(secs / 3600)}h"
    return f"{int(secs / 86400)}d"


def short_model(model: str | None) -> str:
    if not model:
        return "-"
    return model.split("@")[0]


def render_table(rows: list[dict[str, Any]], now_ms: float) -> str:
    header = f"{'%CTX':>6}  {'TOKENS':>8}  {'WINDOW':>7}  {'MODEL':<22} {'STATE':<8} {'MEAS':>5}  {'CMPCT':>5}  {'SESSION':<30} DIRECTORY"
    lines = [header, "-" * len(header)]
    for r in rows:
        pct = f"{r['percent']:.1f}" if r["percent"] is not None else "n/a"
        state = r["activity"] or ("live" if r["live"] else "-")
        if r["error"]:
            state += "!"
        lines.append(
            f"{pct:>6}  {human_tokens(r['tokens']):>8}  {human_tokens(r['context_window']):>7}  "
            f"{short_model(r['model_id']):<22} {state:<8} "
            f"{human_age(r['measured_at_ms'], now_ms):>5}  "
            f"{human_age(r['last_compaction_ms'], now_ms):>5}  "
            f"{r['session_id']:<30} {r['directory']}"
        )
    return "\n".join(lines)


LEGEND = """
%CTX    percent of the model's context window used
TOKENS  estimated tokens in the session's live context (see below)
MEAS    age of the measurement -- the last completed assistant turn
CMPCT   time since this session last compacted ("-" = never)

The number is the last non-compaction assistant message's `tokens.total`
(input + output + reasoning + cache.read + cache.write): the prompt the
provider billed for that request, plus the reply that joins the next one.
It is a forward estimate of the NEXT request's prompt size and runs slightly
LOW -- it excludes anything added since that request completed (a user
message, a tool result not yet sent). Measured error over 8,291 consecutive
same-model pairs: median +292 tokens, p95 +5,244, within 2k 86% of the time.
"""


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    now_ms = time.time() * 1000

    db_path = os.path.expanduser(args.db or DEFAULT_DB)
    if not os.path.exists(db_path):
        print(f"oc-context: database not found at {db_path}", file=sys.stderr)
        return 1

    live = read_live_sessions(
        args.state_dir or DEFAULT_STATE_DIR, now_ms, args.live_window
    )

    ids: list[str] | None = args.sessions or None
    recent = args.recent
    if ids is None and recent is None:
        ids = sorted(live)
        if not ids:
            print(
                "oc-context: no sessions with a live heartbeat. "
                "Use --recent HOURS to report recently-updated sessions instead.",
                file=sys.stderr,
            )
            return 0 if args.json else 1

    catalog, catalog_source = load_catalog(args)

    conn = open_db(db_path)
    try:
        sessions = select_sessions(
            conn,
            ids=ids,
            recent_hours=recent,
            # An explicitly-named session is always reported, even if it is a
            # subagent child: the caller asked for that id by name.
            include_children=args.children or bool(args.sessions),
            now_ms=now_ms,
        )
        rows = build_rows(conn, sessions, catalog, live, now_ms)
    finally:
        conn.close()

    if args.min_percent > 0:
        rows = [r for r in rows if (r["percent"] or 0.0) >= args.min_percent]

    if args.json:
        print(
            json.dumps(
                {
                    "generated_at_ms": int(now_ms),
                    "catalog_source": catalog_source,
                    "sessions": rows,
                },
                indent=2,
            )
        )
        return 0

    if not rows:
        print("oc-context: no matching sessions.")
        return 0

    print(render_table(rows, now_ms))
    print(LEGEND.rstrip())
    print(f"\nmodel catalog: {catalog_source}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
