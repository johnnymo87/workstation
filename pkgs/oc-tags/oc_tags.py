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
import collections
import contextlib
import datetime
from dataclasses import dataclass, field
import fnmatch
import os
import posixpath
import sqlite3
import sys
import time
import zoneinfo

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
        project = posixpath.basename(head) or (head.strip("/") or "root")
        slug = tail.strip("/").split("/", 1)[0]
        return f"auto:{project}/{slug}".lower() if slug else f"auto:{project}".lower()
    if d.endswith("/.worktrees"):
        head = d[: -len("/.worktrees")]
        return f"auto:{posixpath.basename(head) or (head.strip('/') or 'root')}".lower()
    base = posixpath.basename(d) or (d.strip("/") or "root")
    return f"auto:{base}".lower()


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


DEFAULT_TAGS_DB = os.path.expanduser("~/.local/share/oc-tags/tags.db")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS session_tag (
    session_id TEXT PRIMARY KEY,
    tag        TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS dir_tag (
    pattern    TEXT PRIMARY KEY,
    tag        TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
"""


def normalise_tag(tag: str) -> str:
    t = (tag or "").strip().lower()
    if not t:
        raise ValueError("tag must not be empty")
    if t.startswith("auto:"):
        raise ValueError("tag must not start with 'auto:'")
    return t


@contextlib.contextmanager
def open_store(path: str = DEFAULT_TAGS_DB):
    """Open (creating if needed) the sidecar tag DB.

    Deliberately NOT beside opencode.db: `rm ~/.local/share/opencode/*.db*`
    is a documented remedy and must not take hand-made tags with it.
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    try:
        conn.executescript(_SCHEMA)
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def set_session_tag(conn, session_id: str, tag: str) -> None:
    conn.execute(
        "INSERT INTO session_tag(session_id, tag, created_at) VALUES (?,?,?) "
        "ON CONFLICT(session_id) DO UPDATE SET tag=excluded.tag, created_at=excluded.created_at",
        (session_id, normalise_tag(tag), int(time.time() * 1000)),
    )


def set_dir_tag(conn, pattern: str, tag: str) -> None:
    p = (pattern or "").strip()
    if not p:
        raise ValueError("pattern must not be empty")
    conn.execute(
        "INSERT INTO dir_tag(pattern, tag, created_at) VALUES (?,?,?) "
        "ON CONFLICT(pattern) DO UPDATE SET tag=excluded.tag, created_at=excluded.created_at",
        (p, normalise_tag(tag), int(time.time() * 1000)),
    )


def session_tags(conn) -> dict[str, str]:
    return dict(conn.execute("SELECT session_id, tag FROM session_tag"))


def dir_tags(conn) -> dict[str, str]:
    return dict(conn.execute("SELECT pattern, tag FROM dir_tag ORDER BY pattern"))


def rm_session_tag(conn, session_id: str) -> bool:
    return conn.execute("DELETE FROM session_tag WHERE session_id=?", (session_id,)).rowcount > 0


def rm_dir_tag(conn, pattern: str) -> bool:
    p = (pattern or "").strip()
    return conn.execute("DELETE FROM dir_tag WHERE pattern=?", (p,)).rowcount > 0


def effective_tag(
    session_id: str,
    directory: str | None,
    session_tag_map: dict[str, str],
    dir_tag_map: dict[str, str],
) -> tuple[str, str]:
    """Resolve a ROOT session's tag. Returns (tag, source) where source is
    'manual' or 'auto'. `oc-tags top` treats 'auto' as untagged so the
    backlog stays visible rather than hidden behind a plausible label.
    """
    tag = session_tag_map.get(session_id)
    if tag:
        return tag, "manual"
    if directory:
        d_norm = directory.rstrip("/") or "/"
        matches = [
            p for p in dir_tag_map
            if fnmatch.fnmatch(d_norm, p.rstrip("/") or "/")
        ]
        if matches:
            # Longest pattern wins: specific beats general. Tie-break lexicographically.
            best = max(matches, key=lambda p: (len(p), p))
            return dir_tag_map[best], "manual"
    return auto_key(directory), "auto"


ET = zoneinfo.ZoneInfo("America/New_York")


def bucket_key(epoch_ms: int, size: str) -> str:
    # Note on November fall-back (DST transition):
    # Wall-clock hour 01 occurs twice, so both map to the same "...T01" key
    # and that bucket absorbs two hours. Harmless for a <=3-day hourly view.
    dt = datetime.datetime.fromtimestamp(epoch_ms / 1000, ET)
    return dt.strftime("%Y-%m-%dT%H") if size == "hour" else dt.strftime("%Y-%m-%d")


def choose_bucket(days: int) -> str:
    """Hourly only for short windows. 720 hourly bars x 15 series is noise."""
    return "hour" if days <= 3 else "day"


DEFAULT_OPENCODE_DB = os.path.expanduser("~/.local/share/opencode/opencode.db")


@dataclass
class Aggregate:
    series: dict = field(default_factory=lambda: collections.defaultdict(dict))
    totals: dict = field(default_factory=dict)
    buckets: list = field(default_factory=list)
    sources: dict = field(default_factory=dict)   # tag -> 'manual' | 'auto'
    unpriced: dict = field(default_factory=dict)  # model -> {messages, tokens}
    partial_bucket: str | None = None
    root_totals: dict = field(default_factory=dict)   # root_id -> float
    root_meta: dict = field(default_factory=dict)     # root_id -> {title, directory, tag, source}


def connect_ro(db_path: str) -> sqlite3.Connection:
    """Read-only connection to opencode.db.

    NEVER immutable=1: WAL needs a writable -shm, which exists while any serve
    runs. busy_timeout because ~15 serves write concurrently.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def aggregate(
    db_path: str,
    since_ms: int,
    until_ms: int,
    bucket: str,
    session_tags: dict[str, str],
    dir_tags: dict[str, str],
    now_ms: int | None = None,
) -> Aggregate:
    conn = connect_ro(db_path)
    conn.execute("BEGIN")
    try:
        s_rows = conn.execute("SELECT id, parent_id, directory, title FROM session").fetchall()
        parents = {r[0]: r[1] for r in s_rows}
        dirs = {r[0]: r[2] for r in s_rows}
        titles = {r[0]: r[3] for r in s_rows}

        rows = conn.execute(
            """
            SELECT session_id,
                   time_created,
                   json_extract(data, '$.cost'),
                   json_extract(data, '$.modelID'),
                   json_extract(data, '$.tokens.total'),
                   json_extract(data, '$.tokens.input'),
                   json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.cache.read'),
                   json_extract(data, '$.tokens.cache.write')
              FROM message
             WHERE time_created >= ? AND time_created < ?
               AND json_extract(data, '$.role') = 'assistant'
            """,
            (since_ms, until_ms),
        ).fetchall()
    finally:
        try:
            conn.rollback()
        finally:
            conn.close()

    agg = Aggregate()
    tag_cache: dict[str, tuple[str, str]] = {}
    per_bucket = collections.defaultdict(lambda: collections.defaultdict(float))
    buckets = set()

    for sid, ts, cost, model, total_tok, tin, tout, cread, cwrite in rows:
        cost = cost or 0.0
        root = root_of(sid, parents)
        if root not in tag_cache:
            tag, source = effective_tag(
                root, dirs.get(root), session_tag_map=session_tags, dir_tag_map=dir_tags
            )
            tag_cache[root] = (tag, source)
            agg.root_meta[root] = {
                "title": titles.get(root),
                "directory": dirs.get(root),
                "tag": tag,
                "source": source,
            }
        tag, source = tag_cache[root]
        agg.sources[tag] = source

        key = bucket_key(ts, bucket)
        buckets.add(key)
        per_bucket[tag][key] += cost
        agg.root_totals[root] = agg.root_totals.get(root, 0.0) + cost

        if total_tok is not None:
            toks = int(total_tok)
        else:
            toks = int((tin or 0) + (tout or 0) + (cread or 0) + (cwrite or 0))

        # A model with no recorded price must be LOUD. Rendering it as $0
        # would silently under-report on exactly the day a new model ships.
        if cost == 0 and toks > 0:
            model_key = model or "unknown"
            u = agg.unpriced.setdefault(model_key, {"messages": 0, "tokens": 0})
            u["messages"] += 1
            u["tokens"] += toks

    agg.buckets = sorted(buckets)
    agg.series = {t: dict(b) for t, b in per_bucket.items()}
    # Deterministically ordered, descending by dollars; tie-break alphabetically by tag
    agg.totals = dict(
        sorted(
            ((t, sum(b.values())) for t, b in agg.series.items()),
            key=lambda item: (-item[1], item[0]),
        )
    )
    # In-flight turns carry no cost until they complete, so the newest bucket
    # always under-reads and must be labelled if it is currently in flight.
    now_epoch_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    current_bucket = bucket_key(now_epoch_ms, bucket)
    agg.partial_bucket = (
        agg.buckets[-1] if (agg.buckets and agg.buckets[-1] == current_bucket) else None
    )
    return agg




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
