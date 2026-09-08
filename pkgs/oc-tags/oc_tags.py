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
import json
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


CFP_DIR = "/var/lib/claude-failover-proxy"


def cfp_metered_by_day(cfp_dir: str = CFP_DIR) -> dict[str, float]:
    """Actual billed dollars per ET day. Returns {} if cfp is absent.

    This is a REFERENCE LINE, never a band: it is pinned near $210/day by two
    $100 ceilings, so per-tag metered dollars would measure which work reached
    the cap first, i.e. time of day. See the design doc.
    """
    if not os.path.isdir(cfp_dir):
        return {}

    by_day: dict[str, float] = {}

    history_path = os.path.join(cfp_dir, "history.jsonl")
    if os.path.isfile(history_path):
        try:
            with open(history_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except Exception:
                        continue
                    day = record.get("day")
                    if not day:
                        continue
                    spend = float(record.get("spend") or 0.0)
                    ent = float(record.get("enterpriseSpend") or 0.0)
                    by_day[day] = spend + ent
        except Exception:
            pass

    today_spend: dict[str, float] = collections.defaultdict(float)
    for fname in ("spend.json", "spend-enterprise.json"):
        fpath = os.path.join(cfp_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    data = json.load(f)
                day = data.get("day")
                total = float(data.get("total") or 0.0)
                if day:
                    today_spend[day] += total
            except Exception:
                pass

    for day, total in today_spend.items():
        by_day[day] = total

    return by_day


def build_parser() -> argparse.ArgumentParser:
    desc = __doc__.splitlines()[0] if __doc__ else ""
    p = argparse.ArgumentParser(prog="oc-tags", description=desc)
    p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    sub = p.add_subparsers(dest="command", required=True)

    # set
    set_p = sub.add_parser("set", help="tag a session or directory pattern")
    set_p.add_argument("--dir", metavar="PATH", help="directory pattern to tag")
    set_p.add_argument("target", nargs="?", help="tag (or tag when --dir is used)")
    set_p.add_argument("session_id", nargs="?", help="optional session id")
    set_p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    set_p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    # ls
    ls_p = sub.add_parser("ls", help="list tags")
    ls_p.add_argument("--counts", action="store_true", help="show session and directory counts")
    ls_p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    ls_p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    # rm
    rm_p = sub.add_parser("rm", help="remove a tag")
    rm_p.add_argument("--dir", metavar="PATH", help="directory pattern to remove")
    rm_p.add_argument("target", nargs="?", help="session id to remove")
    rm_p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    rm_p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    # report
    rep = sub.add_parser("report", help="text table of dollars by tag by day")
    rep.add_argument("--days", type=int, default=14, help="number of days to report")
    rep.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    rep.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    # top
    top_p = sub.add_parser("top", help="rank untagged root sessions by dollars")
    top_p.add_argument("--days", type=int, default=14, help="number of days to look back")
    top_p.add_argument("--min", type=float, default=0.0, help="minimum dollar threshold")
    top_p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    top_p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

    return p


def cmd_set(args: argparse.Namespace) -> int:
    if args.dir:
        tag = args.target
        if not tag:
            sys.stderr.write("Error: tag is required\n")
            return 1
        try:
            with open_store(args.tags_db) as st:
                set_dir_tag(st, args.dir, tag)
        except ValueError as e:
            sys.stderr.write(f"Error: {e}\n")
            return 1
        print(f"Tagged dir pattern '{args.dir.strip()}' as '{normalise_tag(tag)}'")
        return 0

    tag = args.target
    if not tag:
        sys.stderr.write("Error: tag is required\n")
        return 1

    target_sid = args.session_id or os.environ.get("OPENCODE_SESSION_ID")
    if not target_sid:
        sys.stderr.write("Error: no session ID provided and OPENCODE_SESSION_ID is not set\n")
        return 1

    root_sid = target_sid
    if os.path.exists(args.db):
        try:
            conn = connect_ro(args.db)
            try:
                s_rows = conn.execute("SELECT id, parent_id FROM session").fetchall()
                parents = {r[0]: r[1] for r in s_rows}
                root_sid = root_of(target_sid, parents)
            finally:
                conn.close()
        except Exception:
            pass

    try:
        with open_store(args.tags_db) as st:
            set_session_tag(st, root_sid, tag)
    except ValueError as e:
        sys.stderr.write(f"Error: {e}\n")
        return 1

    norm = normalise_tag(tag)
    if root_sid != target_sid:
        print(f"Tagged root session '{root_sid}' (resolved from '{target_sid}') as '{norm}'")
    else:
        print(f"Tagged session '{root_sid}' as '{norm}'")
    return 0


def cmd_ls(args: argparse.Namespace) -> int:
    with open_store(args.tags_db) as conn:
        s_tags = session_tags(conn)
        d_tags = dir_tags(conn)

    if args.counts:
        all_tags = sorted(set(s_tags.values()) | set(d_tags.values()))
        if not all_tags:
            print("No tags defined.")
            return 0
        s_counts = collections.Counter(s_tags.values())
        d_counts = collections.Counter(d_tags.values())
        print(f"{'tag':<36} {'sessions':>10} {'dirs':>8}")
        print("-" * 56)
        for t in all_tags:
            print(f"{t:<36} {s_counts[t]:>10} {d_counts[t]:>8}")
    else:
        if not d_tags and not s_tags:
            print("No tags defined.")
            return 0
        if d_tags:
            print("Directory patterns:")
            for p, t in d_tags.items():
                print(f"  {p} -> {t}")
        if s_tags:
            print("Sessions:")
            for s, t in s_tags.items():
                print(f"  {s} -> {t}")
    return 0


def cmd_rm(args: argparse.Namespace) -> int:
    if args.dir:
        with open_store(args.tags_db) as st:
            deleted = rm_dir_tag(st, args.dir)
        if deleted:
            print(f"Removed dir tag for '{args.dir.strip()}'")
            return 0
        sys.stderr.write(f"Error: no dir tag found for '{args.dir.strip()}'\n")
        return 1

    if args.target:
        with open_store(args.tags_db) as st:
            deleted = rm_session_tag(st, args.target)
        if deleted:
            print(f"Removed session tag for '{args.target}'")
            return 0
        sys.stderr.write(f"Error: no session tag found for '{args.target}'\n")
        return 1

    sys.stderr.write("Error: specify session-id or --dir <path>\n")
    return 1


def cmd_report(args: argparse.Namespace) -> int:
    raw_now = os.environ.get("OC_TAGS_NOW_MS")
    now_ms = int(raw_now) if raw_now else int(time.time() * 1000)
    now_dt = datetime.datetime.fromtimestamp(now_ms / 1000, ET)
    today_start = datetime.datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=ET)
    since_dt = today_start - datetime.timedelta(days=args.days)
    until_dt = today_start + datetime.timedelta(days=1)

    since_ms = int(since_dt.timestamp() * 1000)
    until_ms = int(until_dt.timestamp() * 1000)
    since_str = since_dt.strftime("%Y-%m-%d")
    until_str = today_start.strftime("%Y-%m-%d")

    if os.path.exists(args.tags_db):
        with open_store(args.tags_db) as st:
            s_tags = session_tags(st)
            d_tags = dir_tags(st)
    else:
        s_tags = {}
        d_tags = {}

    bucket = choose_bucket(args.days)
    if not os.path.exists(args.db):
        print(f"Consumed at list price (USD) -- not billed.  Window: {since_str}..{until_str} (ET)\n")
        print("No assistant messages found in this window.")
        return 0

    agg = aggregate(
        args.db,
        since_ms=since_ms,
        until_ms=until_ms,
        bucket=bucket,
        session_tags=s_tags,
        dir_tags=d_tags,
        now_ms=now_ms,
    )

    print(f"Consumed at list price (USD) -- not billed.  Window: {since_str}..{until_str} (ET)\n")

    if not agg.totals:
        print("No assistant messages found in this window.")
        return 0

    total_dollars = sum(agg.totals.values())
    print(f"{'tag':<36} {'total':>10} {'share':>7}")
    print("-" * 55)
    for tag, dollars in agg.totals.items():
        share = (dollars / total_dollars * 100.0) if total_dollars > 0 else 0.0
        print(f"{tag:<36} {dollars:>10.2f} {share:>6.1f}%")
    print("-" * 55)
    print(f"{'total':<36} {total_dollars:>10.2f}\n")

    if agg.unpriced:
        unpriced_parts = []
        for model in sorted(agg.unpriced):
            info = agg.unpriced[model]
            msgs = info["messages"]
            toks = info["tokens"]
            if toks >= 1_000_000:
                tok_str = f"{toks / 1_000_000:.1f}M"
            elif toks >= 1_000:
                tok_str = f"{toks / 1_000:.1f}K"
            else:
                tok_str = str(toks)
            msg_str = "msg" if msgs == 1 else "msgs"
            unpriced_parts.append(f"{model} ({msgs} {msg_str}, {tok_str} tok)")
        print(f"Unpriced models: {', '.join(unpriced_parts)}")

    if agg.partial_bucket:
        print("Newest bucket is PARTIAL (in-flight turns carry no cost until they complete).")

    return 0


def cmd_top(args: argparse.Namespace) -> int:
    raw_now = os.environ.get("OC_TAGS_NOW_MS")
    now_ms = int(raw_now) if raw_now else int(time.time() * 1000)
    now_dt = datetime.datetime.fromtimestamp(now_ms / 1000, ET)
    today_start = datetime.datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=ET)
    since_dt = today_start - datetime.timedelta(days=args.days)
    until_dt = today_start + datetime.timedelta(days=1)

    since_ms = int(since_dt.timestamp() * 1000)
    until_ms = int(until_dt.timestamp() * 1000)

    if os.path.exists(args.tags_db):
        with open_store(args.tags_db) as st:
            s_tags = session_tags(st)
            d_tags = dir_tags(st)
    else:
        s_tags = {}
        d_tags = {}

    bucket = choose_bucket(args.days)
    if not os.path.exists(args.db):
        print("No untagged root sessions found.")
        return 0

    agg = aggregate(
        args.db,
        since_ms=since_ms,
        until_ms=until_ms,
        bucket=bucket,
        session_tags=s_tags,
        dir_tags=d_tags,
        now_ms=now_ms,
    )

    untagged = []
    for root_id, dollars in agg.root_totals.items():
        meta = agg.root_meta.get(root_id, {})
        if meta.get("source") == "auto" and dollars >= args.min and dollars > 0:
            untagged.append((dollars, root_id, meta.get("title") or "", meta.get("directory") or ""))

    untagged.sort(key=lambda item: (-item[0], item[1]))

    if not untagged:
        print("No untagged root sessions found.")
        return 0

    print(f"{'dollars':>10}  {'session_id':<32}  {'title':<40}  directory")
    print("-" * 110)
    for dollars, root_id, title, directory in untagged:
        d_str = f"${dollars:,.2f}"
        t_disp = title if len(title) <= 40 else title[:37] + "..."
        print(f"{d_str:>10}  {root_id:<32}  {t_disp:<40}  {directory}")

    # Detect shared directory prefixes among untagged roots (>= 3 roots)
    prefix_counts: dict[str, list[str]] = collections.defaultdict(list)
    for _, root_id, _, directory in untagged:
        if not directory:
            continue
        d_norm = directory.rstrip("/")
        if _WORKTREE_MARKER in d_norm:
            head, _, _ = d_norm.partition(_WORKTREE_MARKER)
            pat = f"{head}{_WORKTREE_MARKER}*"
            prefix_counts[pat].append(root_id)
        parent = posixpath.dirname(d_norm)
        if parent and parent not in ("/", "/tmp"):
            pat = f"{parent}/*"
            prefix_counts[pat].append(root_id)
        prefix_counts[d_norm].append(root_id)

    hints = []
    seen_roots: set[str] = set()
    for pat, roots in sorted(prefix_counts.items(), key=lambda item: (-len(item[1]), -len(item[0]))):
        unique_roots = set(roots)
        if len(unique_roots) >= 3 and not unique_roots.issubset(seen_roots):
            hints.append((pat, len(unique_roots)))
            seen_roots.update(unique_roots)

    if hints:
        print()
        for pat, count in hints:
            print(f"Hint: {count} untagged roots share directory prefix '{pat}'. Cover them with:")
            print(f"  oc-tags set --dir '{pat}' <tag>")

    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    return build_parser().parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else 2

    if args.command == "set":
        return cmd_set(args)
    elif args.command == "ls":
        return cmd_ls(args)
    elif args.command == "rm":
        return cmd_rm(args)
    elif args.command == "report":
        return cmd_report(args)
    elif args.command == "top":
        return cmd_top(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
