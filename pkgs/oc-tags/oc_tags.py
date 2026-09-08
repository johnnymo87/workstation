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
import html
import http.server
import json
import os
import posixpath
import sqlite3
import sys
import time
import urllib.parse
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
def open_store(path: str = DEFAULT_TAGS_DB, readonly: bool = False):
    """Open (creating if needed when writable) the sidecar tag DB.

    Deliberately NOT beside opencode.db: `rm ~/.local/share/opencode/*.db*`
    is a documented remedy and must not take hand-made tags with it.
    """
    if readonly:
        if not os.path.exists(path):
            conn = sqlite3.connect(":memory:")
            conn.executescript(_SCHEMA)
            try:
                yield conn
            finally:
                conn.close()
            return
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.execute("PRAGMA busy_timeout=5000")
        try:
            yield conn
        finally:
            conn.close()
        return

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
class Window:
    since_ms: int
    until_ms: int
    since_dt: datetime.datetime
    until_dt: datetime.datetime
    today_start: datetime.datetime
    since_str: str
    until_str: str
    now_ms: int


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
    window: Window | None = None
    cap_hits: dict[str, str] = field(default_factory=dict)  # day -> "HH:MM"


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
             ORDER BY time_created ASC
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
    day_accum: dict[str, float] = collections.defaultdict(float)
    buckets = set()

    for sid, ts, cost, model, total_tok, tin, tout, cread, cwrite in rows:
        cost = cost or 0.0
        dt = datetime.datetime.fromtimestamp(ts / 1000, ET)
        day_str = dt.strftime("%Y-%m-%d")
        day_accum[day_str] += cost
        if day_accum[day_str] >= 195.0 and day_str not in agg.cap_hits:
            agg.cap_hits[day_str] = dt.strftime("%H:%M")
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


def calculate_window(days: int, now_ms: int | None = None) -> Window:
    if now_ms is None:
        raw_now = os.environ.get("OC_TAGS_NOW_MS")
        now_ms = int(raw_now) if raw_now else int(time.time() * 1000)
    now_dt = datetime.datetime.fromtimestamp(now_ms / 1000, ET)
    today_start = datetime.datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=ET)
    since_dt = today_start - datetime.timedelta(days=days)
    until_dt = today_start + datetime.timedelta(days=1)
    return Window(
        since_ms=int(since_dt.timestamp() * 1000),
        until_ms=int(until_dt.timestamp() * 1000),
        since_dt=since_dt,
        until_dt=until_dt,
        today_start=today_start,
        since_str=since_dt.strftime("%Y-%m-%d"),
        until_str=today_start.strftime("%Y-%m-%d"),
        now_ms=now_ms,
    )


def load_aggregate(
    db_path: str = DEFAULT_OPENCODE_DB,
    tags_db: str = DEFAULT_TAGS_DB,
    days: int = 14,
    bucket: str | None = None,
    now_ms: int | None = None,
) -> Aggregate:
    win = calculate_window(days, now_ms=now_ms)
    s_tags = {}
    d_tags = {}
    if os.path.exists(tags_db):
        with open_store(tags_db, readonly=True) as st:
            s_tags = session_tags(st)
            d_tags = dir_tags(st)

    b = bucket if bucket is not None else choose_bucket(days)
    if not os.path.exists(db_path):
        agg = Aggregate()
        agg.window = win
        return agg

    agg = aggregate(
        db_path,
        since_ms=win.since_ms,
        until_ms=win.until_ms,
        bucket=b,
        session_tags=s_tags,
        dir_tags=d_tags,
        now_ms=win.now_ms,
    )
    agg.window = win
    return agg


CFP_DIR = "/var/lib/claude-failover-proxy"


@dataclass(frozen=True)
class CfpSpend:
    metered: dict[str, float] = field(default_factory=dict)
    notional: dict[str, float] = field(default_factory=dict)


def cfp_spend_by_day(cfp_dir: str = CFP_DIR) -> CfpSpend:
    """Actual billed dollars and notional vertex cost per ET day.

    Returns empty mappings if cfp is absent.
    """
    if not os.path.isdir(cfp_dir):
        return CfpSpend()

    metered_by_day: dict[str, float] = {}
    notional_by_day: dict[str, float] = {}

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
                    if not isinstance(record, dict):
                        continue
                    day = record.get("day")
                    if not day or not isinstance(day, str):
                        continue
                    try:
                        spend = float(record.get("spend") or 0.0)
                        ent = float(record.get("enterpriseSpend") or 0.0)
                        notional = float(record.get("notionalVertexCost") or 0.0)
                    except (ValueError, TypeError):
                        continue
                    metered_by_day[day] = spend + ent
                    if notional:
                        notional_by_day[day] = notional
        except FileNotFoundError:
            pass
        except OSError as e:
            sys.stderr.write(f"Warning: could not read {history_path}: {e}\n")

    today_spend: dict[str, float] = collections.defaultdict(float)
    today_notional: dict[str, float] = collections.defaultdict(float)
    for fname in ("spend.json", "spend-enterprise.json"):
        fpath = os.path.join(cfp_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if not isinstance(data, dict):
                    continue
                day = data.get("day")
                if not day or not isinstance(day, str):
                    continue
                try:
                    total = float(data.get("total") or 0.0)
                    notional = float(data.get("notionalVertexCost") or 0.0)
                except (ValueError, TypeError):
                    continue
                today_spend[day] += total
                if notional:
                    today_notional[day] += notional
            except FileNotFoundError:
                pass
            except OSError as e:
                sys.stderr.write(f"Warning: could not read {fpath}: {e}\n")

    for day, total in today_spend.items():
        metered_by_day[day] = total
    for day, notional in today_notional.items():
        notional_by_day[day] = notional

    return CfpSpend(metered=metered_by_day, notional=notional_by_day)


def cfp_metered_by_day(cfp_dir: str = CFP_DIR) -> dict[str, float]:
    """Actual billed dollars per ET day. Returns {} if cfp is absent.

    This is a REFERENCE LINE, never a band: it is pinned near $210/day by two
    $100 ceilings, so per-tag metered dollars would measure which work reached
    the cap first, i.e. time of day. See the design doc.
    """
    return cfp_spend_by_day(cfp_dir).metered


def render_svg(
    agg: Aggregate,
    metered_by_day: dict[str, float] | CfpSpend,
    hide: frozenset[str] = frozenset(),
    top_n: int = 12,
    notional_by_day: dict[str, float] | None = None,
) -> str:
    """Render a stacked-area chart of list-price LLM consumption per tag as SVG.

    Pure function: no socket, no DB access, testable in a sandbox.
    """
    import math

    if isinstance(metered_by_day, CfpSpend):
        metered = metered_by_day.metered
        notional = metered_by_day.notional if notional_by_day is None else notional_by_day
    else:
        metered = metered_by_day or {}
        notional = notional_by_day or {}

    visible_tags = [t for t in agg.totals if t not in hide]
    if not visible_tags or not agg.buckets:
        return (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 400" width="100%" height="400">\n'
            '  <style>\n'
            '    text { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }\n'
            '  </style>\n'
            '  <rect width="1100" height="400" fill="#ffffff"/>\n'
            '  <text x="550" y="200" text-anchor="middle" font-size="18" fill="#64748b">No data in window</text>\n'
            '</svg>\n'
        )

    # Top-N partitioning
    if len(visible_tags) > top_n:
        head_tags = visible_tags[:top_n]
        tail_tags = visible_tags[top_n:]
        bands = list(head_tags)
        other_series: dict[str, float] = collections.defaultdict(float)
        other_total = 0.0
        for t in tail_tags:
            other_total += agg.totals[t]
            for b in agg.buckets:
                other_series[b] += agg.series[t].get(b, 0.0)
        if "other" not in hide and other_total > 0:
            bands.append("other")
    else:
        head_tags = visible_tags
        tail_tags = []
        bands = list(head_tags)
        other_series = collections.defaultdict(float)
        other_total = 0.0

    def band_val(tag: str, b: str) -> float:
        if tag == "other":
            return other_series.get(b, 0.0)
        return agg.series[tag].get(b, 0.0)

    def band_tot(tag: str) -> float:
        if tag == "other":
            return other_total
        return agg.totals[tag]

    # Assign colors: saturated for manual, desaturated for auto, neutral for other
    PALETTE_HUES = [215, 145, 28, 280, 345, 185, 45, 95, 315, 165, 10, 250]
    colors: dict[str, str] = {}
    for i, t in enumerate(bands):
        if t == "other":
            colors[t] = "#94a3b8"
        else:
            source = agg.sources.get(t, "auto" if t.startswith("auto:") else "manual")
            hue = PALETTE_HUES[i % len(PALETTE_HUES)]
            if source == "manual":
                colors[t] = f"hsl({hue}, 75%, 48%)"
            else:
                colors[t] = f"hsl({hue}, 25%, 68%)"

    # SVG layout dimensions
    width = 1100
    height = 640
    plot_x = 90
    plot_y = 65
    plot_w = 710
    plot_h = 460
    x_left = plot_x
    x_right = plot_x + plot_w
    y_top = plot_y
    y_bottom = plot_y + plot_h

    M = len(agg.buckets)
    x_coords = []
    for i in range(M):
        if M == 1:
            x_coords.append(plot_x + plot_w / 2)
        else:
            x_coords.append(plot_x + i * (plot_w / (M - 1)))

    totals_by_bucket = []
    for i, b in enumerate(agg.buckets):
        tot_b = sum(band_val(t, b) for t in bands)
        totals_by_bucket.append(tot_b)

    metered_vals = [metered.get(b, 0.0) for b in agg.buckets]
    max_val = max(totals_by_bucket + metered_vals + [1.0])

    target_ticks = 5
    raw_step = max_val / target_ticks
    mag = 10 ** math.floor(math.log10(raw_step or 1.0))
    norm_step = raw_step / mag
    if norm_step <= 1.2:
        step = 1.0 * mag
    elif norm_step <= 2.5:
        step = 2.0 * mag
    elif norm_step <= 6.0:
        step = 5.0 * mag
    else:
        step = 10.0 * mag
    y_max = math.ceil(max_val / step) * step
    if y_max <= 0:
        y_max = 1.0

    def y_scale(val: float) -> float:
        return y_bottom - (val / y_max) * plot_h

    svg_parts = []
    svg_parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="100%" height="{height}">\n'
        f'  <style>\n'
        f'    text {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}\n'
        f'  </style>\n'
        f'  <defs>\n'
        f'    <pattern id="hatch" width="8" height="8" patternTransform="rotate(45 0 0)" patternUnits="userSpaceOnUse">\n'
        f'      <line x1="0" y1="0" x2="0" y2="8" stroke="#64748b" stroke-width="2" opacity="0.4"/>\n'
        f'    </pattern>\n'
        f'  </defs>\n'
        f'  <rect width="{width}" height="{height}" fill="#ffffff"/>'
    )

    # Gridlines and Y-axis labels
    y_val = 0.0
    while y_val <= y_max + 1e-9:
        y_pos = y_scale(y_val)
        svg_parts.append(
            f'  <line x1="{x_left}" y1="{y_pos:.1f}" x2="{x_right}" y2="{y_pos:.1f}" stroke="#e2e8f0" stroke-width="1"/>'
        )
        val_str = f"${y_val:,.0f}" if y_val >= 10 else f"${y_val:,.2f}"
        svg_parts.append(
            f'  <text x="{x_left - 10}" y="{y_pos + 4:.1f}" text-anchor="end" font-size="11" fill="#64748b">{val_str}</text>'
        )
        y_val += step

    # X-axis bucket labels
    label_step = max(1, math.ceil(M / 12))
    for i, b in enumerate(agg.buckets):
        if i % label_step == 0 or i == M - 1:
            x_pos = x_coords[i]
            label = b[5:] if len(b) > 5 else b
            svg_parts.append(
                f'  <text x="{x_pos:.1f}" y="{y_bottom + 18}" text-anchor="middle" font-size="10" fill="#64748b">{html.escape(label)}</text>'
            )

    # Partial bucket hatching
    if agg.partial_bucket and agg.partial_bucket in agg.buckets:
        p_idx = agg.buckets.index(agg.partial_bucket)
        p_x = x_coords[p_idx]
        if M == 1:
            h_start = x_left
            h_w = plot_w
        else:
            dx = plot_w / (M - 1)
            h_start = max(x_left, p_x - dx / 2)
            h_end = min(x_right, p_x + dx / 2)
            h_w = h_end - h_start
        svg_parts.append(
            f'  <rect x="{h_start:.1f}" y="{y_top}" width="{h_w:.1f}" height="{plot_h}" fill="url(#hatch)"/>'
        )
        svg_parts.append(
            f'  <text x="{p_x:.1f}" y="{y_top + 16}" text-anchor="middle" font-size="11" font-style="italic" fill="#475569">partial</text>'
        )

    # Stacked Area Bands
    y_cum = [0.0] * M
    for t in bands:
        bot_pts = []
        top_pts = []
        for i, b in enumerate(agg.buckets):
            v = band_val(t, b)
            bot_y = y_scale(y_cum[i])
            top_y = y_scale(y_cum[i] + v)
            bot_pts.append((x_coords[i], bot_y))
            top_pts.append((x_coords[i], top_y))
            y_cum[i] += v

        if M == 1:
            x_m = x_coords[0]
            bw = 40
            top_y = top_pts[0][1]
            bot_y = bot_pts[0][1]
            bh = bot_y - top_y
            svg_parts.append(
                f'  <rect x="{x_m - bw/2:.1f}" y="{top_y:.1f}" width="{bw}" height="{bh:.1f}" fill="{colors[t]}" stroke="{colors[t]}" stroke-width="0.5"/>'
            )
        else:
            path_d = [f"M {bot_pts[0][0]:.1f} {bot_pts[0][1]:.1f}"]
            for pt in bot_pts[1:]:
                path_d.append(f"L {pt[0]:.1f} {pt[1]:.1f}")
            for pt in reversed(top_pts):
                path_d.append(f"L {pt[0]:.1f} {pt[1]:.1f}")
            path_d.append("Z")
            d_str = " ".join(path_d)
            svg_parts.append(
                f'  <path d="{d_str}" fill="{colors[t]}" stroke="{colors[t]}" stroke-width="0.5"/>'
            )

    # Metered Reference Line
    if any(m > 0 for m in metered_vals):
        line_pts = []
        for i, b in enumerate(agg.buckets):
            m_val = metered.get(b, 0.0)
            line_pts.append(f"{x_coords[i]:.1f},{y_scale(m_val):.1f}")
        pts_str = " ".join(line_pts)
        svg_parts.append(
            f'  <polyline points="{pts_str}" fill="none" stroke="#e11d48" stroke-width="2" stroke-dasharray="4,2"/>'
        )

    # Axis Title
    svg_parts.append(
        f'  <text transform="rotate(-90)" x="{- (y_top + plot_h / 2):.1f}" y="25" text-anchor="middle" font-size="12" fill="#475569">Consumed at list price (USD) — not billed</text>'
    )

    # Headline above chart: cap hit at HH:MM for most recent day where metered >= $195
    qualifying_days = [d for d, m in metered.items() if m >= 195.0]
    if qualifying_days:
        recent_day = max(qualifying_days)
        hit_time = agg.cap_hits.get(recent_day)
        if hit_time:
            svg_parts.append(
                f'  <text x="{plot_x}" y="38" font-size="15" font-weight="600" fill="#dc2626">cap hit at {html.escape(hit_time)}</text>'
            )

    # Legend
    leg_x = 825
    leg_y = 65
    row_h = 18
    for i, t in enumerate(bands):
        curr_y = leg_y + i * row_h
        tot_str = f"${band_tot(t):,.2f}"
        esc_tag = html.escape(t)
        svg_parts.append(
            f'  <rect x="{leg_x}" y="{curr_y}" width="11" height="11" rx="2" fill="{colors[t]}"/>'
        )
        svg_parts.append(
            f'  <text x="{leg_x + 18}" y="{curr_y + 9}" font-size="11" fill="#1e293b">{esc_tag}: {tot_str}</text>'
        )

    # Unpriced entry (pinned regardless of Top-N, labelled in tokens, not dollars)
    u_curr_y = leg_y + len(bands) * row_h
    unpriced_toks = sum(info.get("tokens", 0) for info in agg.unpriced.values()) if agg.unpriced else 0
    if unpriced_toks >= 1_000_000:
        tok_str = f"{unpriced_toks / 1_000_000:.1f}M"
    elif unpriced_toks >= 1_000:
        tok_str = f"{unpriced_toks / 1_000:.1f}K"
    else:
        tok_str = str(unpriced_toks)
    svg_parts.append(
        f'  <rect x="{leg_x}" y="{u_curr_y}" width="11" height="11" rx="2" fill="#e2e8f0" stroke="#94a3b8" stroke-width="1"/>'
    )
    svg_parts.append(
        f'  <text x="{leg_x + 18}" y="{u_curr_y + 9}" font-size="11" fill="#64748b">unpriced: {tok_str} tok</text>'
    )

    # Metered line in legend
    if any(m > 0 for m in metered_vals):
        m_curr_y = u_curr_y + row_h
        svg_parts.append(
            f'  <line x1="{leg_x}" y1="{m_curr_y + 5}" x2="{leg_x + 12}" y2="{m_curr_y + 5}" stroke="#e11d48" stroke-width="2" stroke-dasharray="3,1"/>'
        )
        svg_parts.append(
            f'  <text x="{leg_x + 18}" y="{m_curr_y + 9}" font-size="11" fill="#e11d48">billed (capped)</text>'
        )

    # Footer: coverage vs cfp notional, unpriced summary, and drift warning
    total_list = sum(agg.totals.values())
    matching_days = [b for b in agg.buckets if b in notional]
    matching_list = sum(agg.series[t].get(d, 0.0) for t in agg.totals for d in matching_days)
    total_notional = sum(notional[b] for b in matching_days)

    if total_notional > 0:
        cov_pct = (matching_list / total_notional) * 100.0
        day_note = f", {len(matching_days)} of {len(agg.buckets)} days" if len(matching_days) < len(agg.buckets) else ""
        cov_str = f"Coverage: {cov_pct:.1f}% vs CFP notional (${matching_list:,.2f} / ${total_notional:,.2f}{day_note})"
    else:
        cov_str = f"Total list price: ${total_list:,.2f}"

    if agg.unpriced:
        u_items = [f"{m} ({info.get('tokens', 0)} tok)" for m, info in sorted(agg.unpriced.items())]
        unp_str = f"Unpriced: {', '.join(u_items)}"
    else:
        unp_str = "Unpriced: none"

    # Drift warning: per-day ratio outside 0.90-1.05
    drift_alerts = []
    for d in matching_days:
        n_val = notional[d]
        if n_val > 0:
            d_list = sum(agg.series[t].get(d, 0.0) for t in agg.totals)
            ratio = d_list / n_val
            if ratio < 0.90 or ratio > 1.05:
                drift_alerts.append(f"{d} ({ratio:.2f})")

    footer_y = y_bottom + 42
    svg_parts.append(
        f'  <text x="{plot_x}" y="{footer_y}" font-size="11" fill="#64748b">{html.escape(cov_str)} | {html.escape(unp_str)}</text>'
    )
    if drift_alerts:
        drift_msg = f"⚠️ Drift warning: per-day coverage ratio outside 0.90–1.05: {', '.join(drift_alerts)}"
        svg_parts.append(
            f'  <text x="{plot_x}" y="{footer_y + 16}" font-size="11" font-weight="600" fill="#b91c1c">{html.escape(drift_msg)}</text>'
        )

    svg_parts.append("</svg>\n")
    return "\n".join(svg_parts)


def handle_request(
    path: str,
    query: str | dict[str, list[str]],
    db_path: str = DEFAULT_OPENCODE_DB,
    tags_db: str = DEFAULT_TAGS_DB,
    cfp_dir: str = CFP_DIR,
    now_ms: int | None = None,
) -> tuple[int, str, str]:
    if path == "/healthz":
        return (200, "text/plain; charset=utf-8", "ok\n")

    if path != "/":
        return (404, "text/plain; charset=utf-8", "Not Found\n")

    if isinstance(query, str):
        params = urllib.parse.parse_qs(query)
    elif isinstance(query, dict):
        params = query
    else:
        params = {}

    days = 7
    if "days" in params:
        raw_days = params["days"][0] if params["days"] else ""
        try:
            days = int(raw_days)
            if days <= 0:
                return (400, "text/plain; charset=utf-8", "Error: days must be a positive integer\n")
        except ValueError:
            return (400, "text/plain; charset=utf-8", "Error: days must be an integer\n")

    bucket = None
    if "bucket" in params:
        raw_bucket = params["bucket"][0] if params["bucket"] else ""
        if raw_bucket not in ("hour", "day"):
            return (400, "text/plain; charset=utf-8", "Error: bucket must be 'hour' or 'day'\n")
        bucket = raw_bucket

    hide_set = set()
    if "hide" in params:
        for val in params["hide"]:
            for item in val.split(","):
                item = item.strip()
                if item:
                    hide_set.add(item)
    hide = frozenset(hide_set)

    top_n = 12
    if "top_n" in params:
        try:
            top_n = int(params["top_n"][0])
        except (ValueError, IndexError):
            pass

    try:
        agg = load_aggregate(
            db_path=db_path,
            tags_db=tags_db,
            days=days,
            bucket=bucket,
            now_ms=now_ms,
        )
        spend = cfp_spend_by_day(cfp_dir)
        svg = render_svg(agg, spend, hide=hide, top_n=top_n)
        return (200, "image/svg+xml; charset=utf-8", svg)
    except sqlite3.OperationalError as e:
        return (503, "text/plain; charset=utf-8", f"Database error: {e}\n")


def make_handler(db_path: str, tags_db: str, cfp_dir: str):
    class OcTagsHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            pr = urllib.parse.urlparse(self.path)
            status, ctype, body = handle_request(
                pr.path,
                pr.query,
                db_path=db_path,
                tags_db=tags_db,
                cfp_dir=cfp_dir,
            )
            body_bytes = body.encode("utf-8") if isinstance(body, str) else body
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            try:
                self.wfile.write(body_bytes)
            except BrokenPipeError:
                pass

        def log_message(self, format, *args):
            pass

    return OcTagsHandler


def cmd_serve(args: argparse.Namespace) -> int:
    host = args.host
    port = args.port
    server = http.server.HTTPServer((host, port), make_handler(args.db, args.tags_db, CFP_DIR))
    print(f"Serving oc-tags chart on http://{host}:{port}/ (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


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

    # serve
    serve_p = sub.add_parser("serve", help="serve stacked-area chart over HTTP")
    serve_p.add_argument("--host", default="127.0.0.1", help="host to bind (default: 127.0.0.1)")
    serve_p.add_argument("--port", type=int, default=4710, help="port to bind (default: 4710)")
    serve_p.add_argument("--db", default=DEFAULT_OPENCODE_DB, help="path to opencode.db")
    serve_p.add_argument("--tags-db", default=DEFAULT_TAGS_DB, help="path to tags.db")

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
    with open_store(args.tags_db, readonly=True) as conn:
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
    agg = load_aggregate(db_path=args.db, tags_db=args.tags_db, days=args.days)
    win = agg.window
    since_str = win.since_str if win else ""
    until_str = win.until_str if win else ""

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
    agg = load_aggregate(db_path=args.db, tags_db=args.tags_db, days=args.days)

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
    _home = os.path.expanduser("~").rstrip("/")
    _WORKSPACE_CONTAINERS = {"/", "/tmp", "/home/dev/projects", "/home/dev/Code"}
    if _home:
        _WORKSPACE_CONTAINERS.update({_home, f"{_home}/projects", f"{_home}/Code"})

    prefix_counts: dict[str, set[str]] = collections.defaultdict(set)
    for _, root_id, _, directory in untagged:
        if not directory:
            continue
        d_norm = directory.rstrip("/")
        if _WORKTREE_MARKER in d_norm:
            head, _, _ = d_norm.partition(_WORKTREE_MARKER)
            pat = f"{head}{_WORKTREE_MARKER}*"
            prefix_counts[pat].add(root_id)
        else:
            parent = posixpath.dirname(d_norm)
            if parent and parent not in _WORKSPACE_CONTAINERS:
                pat = f"{parent}/*"
                prefix_counts[pat].add(root_id)
        prefix_counts[d_norm].add(root_id)

    hints = []
    seen_roots: set[str] = set()
    for pat, roots in sorted(prefix_counts.items(), key=lambda item: (-len(item[1]), -len(item[0]))):
        if len(roots) >= 3 and not roots.issubset(seen_roots):
            hints.append((pat, len(roots)))
            seen_roots.update(roots)

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

    if args.command in ("report", "top", "ls"):
        try:
            if args.command == "report":
                return cmd_report(args)
            elif args.command == "top":
                return cmd_top(args)
            elif args.command == "ls":
                return cmd_ls(args)
        except BrokenPipeError:
            try:
                devnull = os.open(os.devnull, os.O_WRONLY)
                try:
                    os.dup2(devnull, sys.stdout.fileno())
                finally:
                    os.close(devnull)
            except Exception:
                pass
            return 0

    if args.command == "set":
        return cmd_set(args)
    elif args.command == "rm":
        return cmd_rm(args)
    elif args.command == "serve":
        return cmd_serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
