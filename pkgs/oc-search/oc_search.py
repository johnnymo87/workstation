#!/usr/bin/env python3
"""oc-search -- search OpenCode session history for a substring.

Prints one row per session whose transcript contains QUERY, newest match
first, with the session id you feed to `opencode -s`.

WHY THIS IS NOT A `SELECT ... WHERE instr(data, ?)` ANY MORE
------------------------------------------------------------
The previous implementation (a bash + sqlite3 heredoc in home.base.nix) ran
exactly that: an unindexed full scan of `part`. Measured on cloudbox,
2026-08-05:

    part rows                   1,572,057
    sum(length(part.data))      4,105,562,053  (4.1 GB of JSON text)
    opencode.db                 13.0 GB  (47% of its pages are freelist)
    full scan, cold page cache  ~5m49s   (user CPU 6s -- pure I/O wait)
    `oc-search FbmEmployee...`  4m13s end to end

So the cost was never JSON parsing and never `--all` "pulling in giant tool
outputs": EVERY mode already read every byte of every part, because the
`--types` filter is a predicate applied *after* the row is read, not a way to
read fewer rows. `--all` is if anything cheaper than the default, since it
skips the json_extract.

That scan does not fit in any reasonable caller's patience. In particular the
lgtm PR-review daemon shells out with a 30s `execFile` timeout, so it had been
silently SIGTERM-ing oc-search and building review packets without the session
history section. Reproduced exactly (see README).

THE THREE THINGS THIS DOES ABOUT IT
-----------------------------------
1. A sidecar FTS5 **trigram** index (`--index`), stored outside opencode.db in
   the user cache. Trigram + `detail=full` makes a quoted phrase match an
   EXACT substring match, so index results are byte-identical to `instr()` --
   verified against `instr` on a 49k-row sample: 230/230 and 8573/8573, no
   false positives, no false negatives. Queries drop to milliseconds.

2. Correctness does not depend on the index being fresh. The index carries a
   watermark rowid; everything above it is always resolved by a bounded scan
   of the tail. A stale index makes oc-search slower, never wrong.

3. When there is no usable index, the fallback scan is run in parallel across
   rowid ranges (the scan is I/O-latency bound, not bandwidth bound: the same
   disk does 441 MB/s sequential while SQLite's serial scan achieved ~15-40
   MB/s), and it is LOUD -- a stderr warning up front plus a self-enforced
   deadline for non-interactive callers, so a caller like lgtm gets a
   diagnosable error instead of an unexplained SIGTERM.

`part.rowid` is monotonic in `time_created` (spot-checked every 100,000 rows
across five months), which is what makes both the watermark and the parallel
range split legitimate.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import shutil
import sqlite3
import sys
import threading
import time
import urllib.parse
from typing import Any, Iterable

DEFAULT_DB = "~/.local/share/opencode/opencode.db"
DEFAULT_TYPES = "tool"

# Bump when the sidecar layout changes; a mismatch forces a rebuild.
INDEX_SCHEMA_VERSION = 2
TMAX_SHIFT = 14

# Trigram FTS5 cannot represent a pattern shorter than one trigram.
MIN_TRIGRAM_LEN = 3

# Fallback-scan parallelism. The scan is I/O-latency bound and sqlite3 releases
# the GIL for the duration of each step(), so threads give real overlap.
DEFAULT_JOBS = 16

# Non-interactive callers (lgtm) get a deadline they can see in a log line.
# Interactive humans get none by default -- a first-ever full scan is slow but
# it is theirs to wait for.
DEFAULT_NONINTERACTIVE_TIMEOUT_S = 25.0

# Per --index run, how many tail rows to fold into the index.
# Default is None (unlimited: a full rebuild completes in one run).
DEFAULT_INDEX_BATCH: int | None = None

# Fallback bytes per row when an existing index is absent or too small to measure.
INDEX_BYTES_PER_ROW = 7_200

# Hard floor: never let an index build take the machine's last few GB.
MIN_FREE_BYTES = 5_000_000_000

# Rows per index-build transaction. Bounds WAL growth and bounds the work lost
# if the build is interrupted. Measured: at 50,000 the WAL still reached 2.2 GB
# mid-build, because FTS5 segment merges amplify a transaction far past the
# bytes inserted into it. 10,000 keeps the checkpoint interval short enough for
# journal_size_limit to actually claw the file back.
COMMIT_EVERY = 10_000

# Rows read from the SOURCE database per statement (bead workstation-o5s1.3).
# This is not a buffer size, it is the unit of work over which the source's WAL
# read mark is held: each chunk is a statement that runs to completion, so the
# mark is released between chunks and checkpointing can advance. It was
# previously the fetchmany() size of one long-lived cursor, which held the mark
# for the entire batch instead. Keep it small enough that the pause between
# releases stays short, and large enough that per-statement overhead stays
# irrelevant against reading a ~4KB blob per row.
READ_CHUNK = 2_000

# `--limit` fast path (bead workstation-gqt3.1): rowids in the first window
# scanned down from the top of the table, and the factor each further window
# grows by. 4,096 rows is a few hours of parts on cloudbox, so a needle seen
# several times a day stops in the first window. A needle that never reaches N
# sessions reads exactly the rows the unlimited search reads, in more passes:
# measured warm on cloudbox 2026-10-09, 2.9s vs 2.2s at x4 (4.1s at x2).
RECENT_FIRST_WINDOW = 4_096
RECENT_WINDOW_GROWTH = 4

# Reconcile bounds and sweep parameters (bead workstation-gqt3.3).
# RECONCILE_MAX bounds changed-identity rows (renumber detector, e.g. VACUUM INTO renumber).
# DELETE_MAX bounds deleted rows. Exceeding either forces a full rebuild from scratch.
RECONCILE_MAX = 50_000
DELETE_MAX = 1_000_000
RECHECK_ROWS = 100_000

IDENTITY_SWEEP_SQL = (
    "SELECT p.rowid FROM part p INDEXED BY sqlite_autoindex_part_1 "
    "LEFT JOIN idx.part_meta pm ON pm.rowid_ = p.rowid "
    "WHERE p.rowid <= ? AND pm.part_id IS NOT p.id LIMIT ?"
)

DELETES_SWEEP_SQL = (
    "SELECT rowid_ FROM idx.part_meta "
    "WHERE rowid_ NOT IN (SELECT +rowid FROM part INDEXED BY sqlite_autoindex_part_1) "
    "LIMIT ?"
)

RECHECK_SWEEP_SQL = (
    "SELECT p.rowid FROM part p "
    "JOIN idx.part_meta pm ON pm.rowid_ = p.rowid "
    "WHERE p.rowid <= ? AND p.rowid > ? AND pm.time_updated IS NOT p.time_updated"
)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def positive_int(raw: str) -> int:
    value = int(raw)
    if value < 1:
        raise argparse.ArgumentTypeError(f"must be 1 or greater, got {value}")
    return value


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="oc-search",
        description="Search OpenCode session history for QUERY.",
        epilog=(
            "Substring semantics, byte-exact and case-sensitive, identical "
            "with or without the index."
        ),
    )
    p.add_argument("query", nargs="?", help="Substring to search for.")
    p.add_argument(
        "--types",
        default=DEFAULT_TYPES,
        metavar="TYPES",
        help=f"Comma-separated part types to search (default: {DEFAULT_TYPES}).",
    )
    p.add_argument(
        "--all", dest="search_all", action="store_true", help="Search all part types."
    )
    p.add_argument("--json", action="store_true", help="Machine-readable output.")
    p.add_argument(
        "--limit",
        type=int,
        default=0,
        metavar="N",
        help=(
            "Show at most N sessions, with exact counts. Searches newest-first "
            "(by insertion) and stops, so it stays fast for common needles even "
            "without a usable index. Equal to the first N rows of the unlimited "
            "search except near bulk-imported history (see search_recent)."
        ),
    )
    p.add_argument("--db", help=f"Path to opencode.db (default: {DEFAULT_DB}).")
    p.add_argument("--index-path", help="Path to the sidecar index db.")
    p.add_argument(
        "--index",
        action="store_true",
        help="Build or incrementally refresh the sidecar index, then exit.",
    )
    p.add_argument(
        "--if-exists",
        action="store_true",
        help=(
            "With --index: refresh an existing index, but do not create one. "
            "What the hourly timer uses -- the first build is ~11 GB and stays "
            "a deliberate act."
        ),
    )
    p.add_argument(
        "--rebuild",
        action="store_true",
        help="With --index: discard and rebuild from scratch.",
    )
    p.add_argument(
        "--index-info", action="store_true", help="Report index state, then exit."
    )
    p.add_argument(
        "--no-index", action="store_true", help="Ignore the index; force a full scan."
    )
    p.add_argument(
        "--index-batch",
        type=positive_int,
        default=DEFAULT_INDEX_BATCH,
        metavar="N",
        help="Max tail rows folded in per --index run (default: unlimited).",
    )
    p.add_argument(
        "--jobs",
        type=int,
        default=DEFAULT_JOBS,
        metavar="N",
        help=f"Parallel workers for a fallback scan (default: {DEFAULT_JOBS}).",
    )
    p.add_argument(
        "--timeout",
        type=float,
        metavar="SECS",
        help=(
            "Abort with a diagnosable error after SECS. 0 disables. Default: "
            f"{DEFAULT_NONINTERACTIVE_TIMEOUT_S:g}s when stdout is not a TTY "
            "(so pipeline callers get an error, not a SIGTERM), none when it is."
        ),
    )
    args = p.parse_args(argv)
    if not (args.index or args.index_info) and not args.query:
        p.error("a search query is required")
    return args


def warn(msg: str) -> None:
    print(f"oc-search: {msg}", file=sys.stderr, flush=True)


class TimedOut(Exception):
    pass


class Deadline:
    """A wall-clock budget enforced from inside SQLite's progress handler.

    The point is loudness. Without it the only way a slow oc-search ends is
    the caller's own kill, which produces `Command failed: oc-search ...` and
    no explanation whatsoever -- exactly the log line lgtm emitted.
    """

    def __init__(self, seconds: float | None):
        self.deadline = None if not seconds else time.monotonic() + seconds
        self.seconds = seconds
        self.tripped = threading.Event()

    def expired(self) -> bool:
        if self.deadline is None:
            return False
        if time.monotonic() > self.deadline:
            self.tripped.set()
        return self.tripped.is_set()

    def arm(self, conn: sqlite3.Connection) -> None:
        if self.deadline is None:
            return
        # ~20k VM steps between checks: fine-grained enough to abort promptly,
        # coarse enough not to matter against a disk read.
        conn.set_progress_handler(lambda: 1 if self.expired() else 0, 2_000)

    def check(self) -> None:
        """Trip outside of SQLite too, so time burned in Python still counts."""
        if self.expired():
            raise TimedOut()


# --------------------------------------------------------------------------
# Paths / databases
# --------------------------------------------------------------------------


def default_index_path(db_path: str) -> str:
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(cache, "oc-search", "index.db")


def file_ro_uri(path: str) -> str:
    return "file:" + urllib.parse.quote(os.path.abspath(os.path.expanduser(path))) + "?mode=ro"


def open_source(path: str, deadline: Deadline | None = None) -> sqlite3.Connection:
    conn = sqlite3.connect(file_ro_uri(path), uri=True, timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA query_only=ON")
    conn.execute("PRAGMA busy_timeout=2000")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.execute("PRAGMA cache_size=-65536")
    if deadline is not None:
        deadline.arm(conn)
    return conn


def part_rowid_bounds(conn: sqlite3.Connection) -> tuple[int, int]:
    row = conn.execute("SELECT MIN(rowid), MAX(rowid) FROM part").fetchone()
    lo, hi = row[0], row[1]
    return (0 if lo is None else int(lo), 0 if hi is None else int(hi))


# --------------------------------------------------------------------------
# The sidecar index
# --------------------------------------------------------------------------

_INDEX_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS ft
  USING fts5(data, tokenize="trigram case_sensitive 1", content='', contentless_delete=1);
CREATE TABLE IF NOT EXISTS part_meta (
  rowid_ INTEGER PRIMARY KEY,
  part_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  type TEXT
);
CREATE TABLE IF NOT EXISTS tmax (
  bucket INTEGER PRIMARY KEY,
  max_tc INTEGER NOT NULL
);
"""


def fts5_trigram_available() -> tuple[bool, str]:
    """Can this SQLite build do what the index needs?

    Checked rather than assumed: the whole exactness argument rests on the
    trigram tokenizer with detail=full and contentless_delete=1, and a SQLite
    compiled without FTS5 or without contentless_delete=1 would otherwise surface
    as a confusing error deep inside a build.
    """
    probe = None
    try:
        probe = sqlite3.connect(":memory:")
        probe.execute(
            'CREATE VIRTUAL TABLE t USING fts5('
            'x, tokenize="trigram case_sensitive 1", content="", contentless_delete=1'
            ')'
        )
        probe.execute("INSERT OR REPLACE INTO t(rowid, x) VALUES (1, 'FbmEmployeeCutoff')")
        probe.execute("INSERT OR REPLACE INTO t(rowid, x) VALUES (1, 'FbmEmployeeModified')")
        n1 = probe.execute("SELECT count(*) FROM t WHERE t MATCH '\"Employee\"'").fetchone()[0]
        n_old = probe.execute("SELECT count(*) FROM t WHERE t MATCH '\"Cutoff\"'").fetchone()[0]
        probe.execute("DELETE FROM t WHERE rowid=1")
        n2 = probe.execute("SELECT count(*) FROM t WHERE t MATCH '\"Employee\"'").fetchone()[0]
    except sqlite3.Error as exc:
        return (False, str(exc))
    finally:
        if probe is not None:
            try:
                probe.close()
            except Exception:
                pass
    if n1 != 1:
        return (False, "trigram phrase match returned the wrong row count")
    if n_old != 0:
        return (False, "contentless_delete=1 failed to remove old trigram postings on replace")
    if n2 != 0:
        return (False, "delete failed to remove trigram postings")
    return (True, "")


def open_index_rw(path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA cache_size=-262144")
    # Truncate the WAL back down after each checkpoint. SQLite's default
    # (journal_size_limit = -1) leaves the file at its high-water mark, and an
    # FTS5 bulk load pushes that mark to gigabytes -- observed at 3.0 GB during
    # the first full build, on a host that was concurrently 94% full.
    conn.execute("PRAGMA journal_size_limit=67108864")
    conn.executescript(_INDEX_SCHEMA)
    return conn


def open_index_ro(path: str, deadline: Deadline | None = None) -> sqlite3.Connection | None:
    if not os.path.exists(path):
        return None
    try:
        conn = sqlite3.connect(file_ro_uri(path), uri=True, timeout=5.0)
    except sqlite3.Error:
        return None
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=2000")
    conn.execute("PRAGMA cache_size=-65536")
    if deadline is not None:
        deadline.arm(conn)
    return conn


def get_meta(conn: sqlite3.Connection, key: str) -> str | None:
    try:
        row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    except sqlite3.Error:
        return None
    return None if row is None else row[0]


def set_meta(conn: sqlite3.Connection, key: str, value: Any) -> None:
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?,?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )


def write_rows(idx: sqlite3.Connection, rows: Iterable[Any]) -> None:
    """Write parts to `ft`, `part_meta`, and `tmax`.

    Every ft write is `INSERT OR REPLACE` so that re-indexed or updated rows do
    not leave ghost postings on the contentless table. `tmax` tracks the
    per-bucket max(time_created) (TMAX_SHIFT=14) and is upserted as
    max(existing, new), never lowered.

    Accepts exactly one row shape: the sqlite3.Row from the build's SELECT
    (rowid, id, session_id, time_created, time_updated, type, data), or a
    7-tuple in that exact order:
        (rowid, id, session_id, time_created, time_updated, type, data)
    Raises ValueError on anything else.
    """
    payload = []
    metas = []
    tmax_map: dict[int, int] = {}
    for r in rows:
        if isinstance(r, tuple):
            if len(r) != 7:
                raise ValueError(f"expected 7-tuple, got length {len(r)}: {r!r}")
            rid, pid, sid, tc, tu, ptype, data = r
        elif isinstance(r, sqlite3.Row):
            try:
                rid = r["rowid"]
                pid = r["id"]
                sid = r["session_id"]
                tc = r["time_created"]
                tu = r["time_updated"]
                ptype = r["type"]
                data = r["data"]
            except (IndexError, KeyError) as exc:
                raise ValueError(f"sqlite3.Row missing expected columns: {exc}") from exc
        else:
            raise ValueError(f"expected 7-tuple or sqlite3.Row, got {type(r).__name__}: {r!r}")

        rid = int(rid)
        tc = int(tc)
        tu = int(tu)
        payload.append((rid, data))
        metas.append((rid, pid, sid, tc, tu, ptype))
        bucket = rid >> TMAX_SHIFT
        if bucket not in tmax_map or tc > tmax_map[bucket]:
            tmax_map[bucket] = tc

    if payload:
        idx.executemany("INSERT OR REPLACE INTO ft(rowid, data) VALUES (?,?)", payload)
        idx.executemany(
            "INSERT OR REPLACE INTO part_meta "
            "(rowid_, part_id, session_id, time_created, time_updated, type) "
            "VALUES (?,?,?,?,?,?)",
            metas,
        )
    if tmax_map:
        idx.executemany(
            "INSERT INTO tmax(bucket, max_tc) VALUES (?, ?) "
            "ON CONFLICT(bucket) DO UPDATE SET max_tc = max(tmax.max_tc, excluded.max_tc)",
            list(tmax_map.items()),
        )


def index_validity(
    src: sqlite3.Connection, idx: sqlite3.Connection, db_path: str
) -> tuple[bool, int, str]:
    """Is this index usable, and up to which source rowid?

    Returns (usable, watermark, reason-if-not).

    The watermark row's identity is re-checked against the live database on
    every run. That is what makes rowid reuse safe: SQLite only ever hands out
    a recycled rowid at the TOP of the table, so if anything was deleted and
    re-inserted under our watermark, the watermark row itself changed and we
    notice here instead of silently missing matches.
    """
    if get_meta(idx, "schema_version") != str(INDEX_SCHEMA_VERSION):
        return (False, 0, "index schema version mismatch")
    if get_meta(idx, "source_db") != os.path.realpath(db_path):
        return (False, 0, "index was built against a different opencode.db")
    raw = get_meta(idx, "watermark_rowid")
    if raw is None:
        return (False, 0, "index has no watermark")
    watermark = int(raw)
    if watermark == 0:
        return (True, 0, "")
    want_id = get_meta(idx, "watermark_part_id")
    row = src.execute("SELECT id FROM part WHERE rowid=?", (watermark,)).fetchone()
    if row is None or row[0] != want_id:
        return (
            False,
            0,
            "watermark row no longer matches the live database "
            "(sessions were deleted); index must be rebuilt",
        )
    return (True, watermark, "")


def inspect_index_schema_version(path: str) -> int | None:
    if not os.path.exists(path):
        return None
    try:
        conn = sqlite3.connect(file_ro_uri(path), uri=True, timeout=5.0)
        try:
            row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
            return int(row[0]) if row and row[0] is not None else None
        finally:
            conn.close()
    except Exception:
        return None


def estimate_disk_need(
    src: sqlite3.Connection,
    index_path: str,
    *,
    watermark: int = 0,
    src_max: int = 0,
    batch: int | None = None,
    rebuild: bool = False,
) -> int:
    """Estimated disk bytes needed for an index build or catch-up.

    For a rebuild, estimated from the live row count of `part` (using its
    covering primary-key autoindex where present) times the measured bytes per
    row of the existing index, falling back to INDEX_BYTES_PER_ROW (7.2 KB/row)
    when the index is absent or too small to measure. Catch-up uses the pending
    rows up to batch. Multiplied by 1.2 safety factor.
    """
    if rebuild:
        try:
            row_count = src.execute(
                "SELECT count(*) FROM part INDEXED BY sqlite_autoindex_part_1"
            ).fetchone()[0]
        except sqlite3.OperationalError:
            row_count = src.execute("SELECT count(*) FROM part").fetchone()[0]
        rows = int(row_count)
    else:
        pending = max(0, src_max - watermark)
        rows = pending if (batch is None or batch == 0) else min(batch, pending)

    bytes_per_row = float(INDEX_BYTES_PER_ROW)
    if os.path.exists(index_path):
        try:
            conn = sqlite3.connect(file_ro_uri(index_path), uri=True, timeout=5.0)
            try:
                cnt_row = conn.execute("SELECT count(*) FROM part_meta").fetchone()
                meta_count = int(cnt_row[0]) if cnt_row and cnt_row[0] is not None else 0
                if meta_count >= 10_000:
                    bytes_per_row = os.path.getsize(index_path) / meta_count
            finally:
                conn.close()
        except Exception:
            pass

    return int(rows * bytes_per_row * 1.2)


def check_disk_precheck(
    src: sqlite3.Connection,
    index_path: str,
    *,
    watermark: int = 0,
    src_max: int = 0,
    batch: int | None = None,
    rebuild: bool = False,
) -> int:
    need = estimate_disk_need(
        src,
        index_path,
        watermark=watermark,
        src_max=src_max,
        batch=batch,
        rebuild=rebuild,
    )
    index_dir = os.path.dirname(index_path) or "."
    os.makedirs(index_dir, exist_ok=True)
    free = shutil.disk_usage(index_dir).free
    current_index_size = os.path.getsize(index_path) if os.path.exists(index_path) else 0
    available = (free + current_index_size) if rebuild else free
    if need > available:
        if rebuild:
            raise SystemExit(
                f"oc-search: refusing to index: estimated ~{need/1e9:.1f} GB needed, "
                f"{available/1e9:.1f} GB available ({free/1e9:.1f} GB free + "
                f"{current_index_size/1e9:.1f} GB reclaimed index) on {index_dir}"
            )
        else:
            raise SystemExit(
                f"oc-search: refusing to index: estimated ~{need/1e9:.1f} GB needed, "
                f"{free/1e9:.1f} GB free on {index_dir}"
            )
    return need


def build_index(
    src: sqlite3.Connection,
    index_path: str,
    db_path: str,
    *,
    rebuild: bool = False,
    batch: int | None = None,
    progress: bool = False,
    reconcile_max: int = RECONCILE_MAX,
    delete_max: int = DELETE_MAX,
    recheck_rows: int = RECHECK_ROWS,
) -> dict[str, Any]:
    _, src_max = part_rowid_bounds(src)

    is_fresh = not os.path.exists(index_path)
    file_schema_ver = inspect_index_schema_version(index_path) if not is_fresh else None
    schema_mismatch = (not is_fresh) and (file_schema_ver != INDEX_SCHEMA_VERSION)

    is_rebuild = rebuild or is_fresh or schema_mismatch

    watermark = 0
    if not is_rebuild:
        quick_idx = open_index_ro(index_path)
        if quick_idx is not None:
            try:
                sdb = get_meta(quick_idx, "source_db")
                wm = get_meta(quick_idx, "watermark_rowid")
                if sdb != os.path.realpath(db_path) or wm is None:
                    is_rebuild = True
                else:
                    watermark = int(wm)
            finally:
                quick_idx.close()
        else:
            is_rebuild = True

    if is_rebuild:
        check_disk_precheck(
            src,
            index_path,
            watermark=0,
            src_max=src_max,
            batch=batch,
            rebuild=True,
        )
        if not is_fresh:
            for suffix in ("", "-wal", "-shm"):
                try:
                    os.remove(index_path + suffix)
                except FileNotFoundError:
                    pass

    idx = open_index_rw(index_path)
    try:
        if is_rebuild:
            set_meta(idx, "schema_version", INDEX_SCHEMA_VERSION)
            set_meta(idx, "source_db", os.path.realpath(db_path))
            set_meta(idx, "watermark_rowid", 0)
            set_meta(idx, "watermark_part_id", "")
            idx.commit()
            watermark = 0
            reconciled_changed = 0
            reconciled_deleted = 0
            rechecked = 0
        else:
            orig_w = int(get_meta(idx, "watermark_rowid") or 0)
            watermark = orig_w
            orig_w_id = get_meta(idx, "watermark_part_id") or ""
            watermark_part_id = orig_w_id
            reconciled_changed = 0
            reconciled_deleted = 0
            rechecked = 0

            if watermark > 0:
                # Reconcile sweep on the SOURCE connection with the index ATTACHed read-only
                try:
                    src.execute("DETACH idx")
                except sqlite3.OperationalError:
                    pass
                clean_index_path = urllib.parse.quote(os.path.abspath(index_path))
                uri = f"file:{clean_index_path}?mode=ro"
                src.execute("ATTACH ? AS idx", (uri,))
                try:
                    changed_rows = src.execute(
                        IDENTITY_SWEEP_SQL, (watermark, reconcile_max + 1)
                    ).fetchall()
                    deleted_rows = src.execute(
                        DELETES_SWEEP_SQL, (delete_max + 1,)
                    ).fetchall()
                    lo = max(0, watermark - recheck_rows)
                    recheck_rows_res = src.execute(
                        RECHECK_SWEEP_SQL, (watermark, lo)
                    ).fetchall()
                finally:
                    try:
                        src.execute("DETACH idx")
                    except sqlite3.Error:
                        pass

                changed_rowids = [int(r[0]) for r in changed_rows]
                deleted_rowids = [int(r[0]) for r in deleted_rows]
                recheck_rowids = [int(r[0]) for r in recheck_rows_res]

                if len(changed_rowids) > reconcile_max:
                    warn(
                        f"changed identity rows ({len(changed_rowids)}) exceeds "
                        f"RECONCILE_MAX ({reconcile_max}); rebuilding from scratch"
                    )
                    idx.close()
                    return build_index(
                        src,
                        index_path,
                        db_path,
                        rebuild=True,
                        batch=batch,
                        progress=progress,
                        reconcile_max=reconcile_max,
                        delete_max=delete_max,
                        recheck_rows=recheck_rows,
                    )

                if len(deleted_rowids) > delete_max:
                    warn(
                        f"deleted rows ({len(deleted_rowids)}) exceeds "
                        f"DELETE_MAX ({delete_max}); rebuilding from scratch"
                    )
                    idx.close()
                    return build_index(
                        src,
                        index_path,
                        db_path,
                        rebuild=True,
                        batch=batch,
                        progress=progress,
                        reconcile_max=reconcile_max,
                        delete_max=delete_max,
                        recheck_rows=recheck_rows,
                    )

                changed_set = set(changed_rowids)
                deleted_set = set(deleted_rowids)
                unique_rechecked = [
                    rid for rid in recheck_rowids
                    if rid not in changed_set and rid not in deleted_set
                ]

                reconciled_changed = len(changed_rowids)
                reconciled_deleted = len(deleted_rowids)
                rechecked = len(unique_rechecked)

                # Apply deletes (build tuples once)
                if deleted_rowids:
                    del_tuples = [(rid,) for rid in deleted_rowids]
                    idx.executemany("DELETE FROM ft WHERE rowid=?", del_tuples)
                    idx.executemany("DELETE FROM part_meta WHERE rowid_=?", del_tuples)

                # Apply changed and rechecked rows
                rewrite_rowids = changed_rowids + unique_rechecked
                if rewrite_rowids:
                    for i in range(0, len(rewrite_rowids), 500):
                        chunk_rids = rewrite_rowids[i : i + 500]
                        placeholders = ",".join("?" * len(chunk_rids))
                        sql = (
                            "SELECT rowid, id, session_id, time_created, time_updated, "
                            "json_extract(data,'$.type') AS type, data FROM part "
                            f"WHERE rowid IN ({placeholders})"
                        )
                        fetched_rows = src.execute(sql, chunk_rids).fetchall()
                        if fetched_rows:
                            write_rows(idx, fetched_rows)
                        if len(fetched_rows) < len(chunk_rids):
                            fetched_rids = {int(r["rowid"]) for r in fetched_rows}
                            missing_rids = [rid for rid in chunk_rids if rid not in fetched_rids]
                            if missing_rids:
                                missing_tuples = [(rid,) for rid in missing_rids]
                                idx.executemany("DELETE FROM ft WHERE rowid=?", missing_tuples)
                                idx.executemany("DELETE FROM part_meta WHERE rowid_=?", missing_tuples)
                                deleted_set.update(missing_rids)
                                reconciled_deleted += len(missing_rids)

                # Watermark re-point (Point 5):
                # if the W row was deleted or changed, set watermark_rowid/watermark_part_id to the highest
                # remaining part_meta row (rowid_ and part_id) - or 0 if empty.
                if orig_w in deleted_set or orig_w in changed_set:
                    highest = idx.execute(
                        "SELECT rowid_, part_id FROM part_meta ORDER BY rowid_ DESC LIMIT 1"
                    ).fetchone()
                    if highest is not None:
                        watermark = int(highest[0])
                        watermark_part_id = str(highest[1])
                    else:
                        watermark = 0
                        watermark_part_id = ""
                    set_meta(idx, "watermark_rowid", watermark)
                    set_meta(idx, "watermark_part_id", watermark_part_id)

                if reconciled_changed > 0 or reconciled_deleted > 0 or rechecked > 0:
                    idx.commit()

            if (
                watermark >= src_max
                and (reconciled_changed == 0 and reconciled_deleted == 0 and rechecked == 0)
            ):
                return {
                    "mode": "noop",
                    "indexed": 0,
                    "watermark": watermark,
                    "up_to_date": True,
                    "reconciled_changed": 0,
                    "reconciled_deleted": 0,
                    "rechecked": 0,
                }

            check_disk_precheck(
                src,
                index_path,
                watermark=watermark,
                src_max=src_max,
                batch=batch,
                rebuild=False,
            )
        # `type` is resolved by json_extract in SQL, exactly as the old
        # implementation filtered it: the field's position inside the blob
        # varies, so no cheaper string probe is safe.
        #
        # ONE STATEMENT PER CHUNK, NOT ONE CURSOR FETCHED IN CHUNKS.
        # (bead workstation-o5s1.3; incident 2026-09-15, epic workstation-o5s1)
        #
        # This used to be a single `src.execute(... LIMIT batch)` whose cursor
        # was drained with `fetchmany(READ_CHUNK)` inside the loop below. An
        # un-exhausted SQLite statement keeps its READ TRANSACTION open, which
        # pins the WAL read mark on the SOURCE database for as long as the
        # cursor lives — and since the index writes happen inside that loop, the
        # mark was held for the whole batch. No checkpoint can advance past a
        # held read mark, so opencode.db's WAL grew ~9 MB/min, unbounded, for
        # the duration of every index run.
        #
        # MEASURED: normally 217-246s per 200,000-row batch, which is already
        # four minutes of blocked checkpointing every hour. On 2026-09-15, with
        # the index writes starved of I/O by concurrent bazel builds, ONE run
        # held it for 87 minutes (6m49s of CPU) and drove the WAL past 1 GB. The
        # holder was visible as byte 127 of the opencode.db-shm inode in
        # /proc/locks — byte 128 is the DMS lock every connection holds and is
        # noise.
        #
        # Re-issuing the query per chunk and calling fetchall() lets each
        # statement RUN TO COMPLETION, so the read transaction ends and the read
        # mark is released between chunks. Checkpointing gets the gaps.
        #
        # THE DESTINATION CONNECTION ALREADY DID THIS, with the comment below
        # explaining why one long transaction was wrong. The fix had been
        # applied to the database being WRITTEN (this process's private index)
        # and not to the one being READ — which is the one with ~15 concurrent
        # writers and the only one where a held mark hurts anybody else.
        #
        # SNAPSHOT ISOLATION IS DELIBERATELY GIVEN UP. Chunks no longer see one
        # consistent view of `part`, and that is sound here rather than merely
        # tolerable: rows are append-mostly with increasing rowid and the
        # watermark is monotonic, so a row inserted mid-run is picked up by the
        # next run — which is already the normal case, since a batch that fills
        # reports MORE REMAINS. A row deleted between chunks is skipped, which is
        # correct, it is gone. A row updated between chunks is indexed in its
        # newer form, which is what a search index wants. Anything not yet
        # indexed is covered by the tail scan, the same mechanism that already
        # covers an interrupted build. The sweep at the start of --index reconciles
        # watermark deletion and rowid reuse, re-pointing the watermark instead
        # of forcing a whole-index rebuild.
        n = 0
        last: tuple[int, str] | None = None
        cursor_rowid = watermark
        since_commit = 0
        since_disk_check = 0
        t0 = time.monotonic()
        index_dir = os.path.dirname(index_path) or "."
        while batch is None or batch == 0 or n < batch:
            chunk_limit = (
                READ_CHUNK
                if (batch is None or batch == 0)
                else min(READ_CHUNK, batch - n)
            )
            rows = src.execute(
                "SELECT rowid, id, session_id, time_created, time_updated, "
                "json_extract(data,'$.type') AS type, data FROM part "
                "WHERE rowid > ? ORDER BY rowid LIMIT ?",
                (cursor_rowid, chunk_limit),
            ).fetchall()
            if not rows:
                break

            # ROWID REUSE AT A CHUNK BOUNDARY (bead workstation-o5s1.3).
            #
            # This is the one hazard chunking introduces that the old
            # single-snapshot scan could not have, and it is checked here rather
            # than argued away. `part` has a TEXT primary key, so its rowid is
            # implicit and SQLite REUSES rowids below the maximum after deletes.
            # On cloudbox that is not hypothetical: max(rowid) exceeds count by
            # ~466,000, and session deletion cascades to parts routinely.
            #
            # The index normally sits at the head of the table, so the boundary
            # between two chunks is the live max rowid. If a session is deleted
            # in the gap between two chunk statements and new parts reuse those
            # rowids, chunk k has already indexed the OLD contents of rows that
            # now belong to somebody else, and chunk k+1 reads only past the
            # boundary.
            #
            # Checked AFTER the fetch, not before, so that a delete landing in
            # EITHER gap (before or after the new statement) is caught.
            # When a boundary row changed under the scan, stop catchup without rebuilding.
            # Commit what is indexed; the next run's sweep reconciles the boundary row.
            if last is not None:
                still = src.execute(
                    "SELECT id FROM part WHERE rowid=?", (last[0],)
                ).fetchone()
                if still is None or still[0] != last[1]:
                    warn(
                        "chunk boundary row changed under the scan "
                        "(rowid reuse after a delete); stopping catchup for next run's sweep to repair"
                    )
                    set_meta(idx, "watermark_rowid", last[0])
                    set_meta(idx, "watermark_part_id", last[1])
                    set_meta(idx, "built_at", int(time.time()))
                    idx.commit()
                    if is_rebuild:
                        chunk_mode = "rebuild"
                    elif (reconciled_changed > 0 or reconciled_deleted > 0 or rechecked > 0):
                        chunk_mode = "reconcile"
                    else:
                        chunk_mode = "catchup"
                    return {
                        "mode": chunk_mode,
                        "indexed": n,
                        "watermark": last[0],
                        "up_to_date": False,
                        "reconciled_changed": reconciled_changed,
                        "reconciled_deleted": reconciled_deleted,
                        "rechecked": rechecked,
                    }

            write_rows(idx, rows)
            last = (int(rows[-1]["rowid"]), rows[-1]["id"])
            cursor_rowid = int(rows[-1]["rowid"])
            n += len(rows)
            since_commit += len(rows)
            since_disk_check += len(rows)
            # THRESHOLD CROSSING, NOT `n % COMMIT_EVERY == 0` (bead
            # workstation-o5s1.3). The modulo form was safe only because
            # fetchmany() on one snapshot returned a short batch exactly once, at
            # the true end. Chunks can now be short mid-run — the scan catches
            # the head of the table and rows land between two statements — after
            # which `n` is permanently off-multiple and the periodic commit, the
            # 5 GB disk guard and the progress line all go silent for the rest of
            # the run. Silently losing the disk guard is the part that matters.
            if last is not None and since_commit >= COMMIT_EVERY:
                since_commit = 0
                # Commit the watermark WITH the rows it describes, periodically.
                # One transaction around the whole build would grow a WAL the
                # size of the finished index (observed passing 900 MB inside two
                # minutes), and would throw away every row on an interruption.
                # Committing in step means an interrupted build is simply a
                # smaller index, which the tail scan already covers.
                set_meta(idx, "watermark_rowid", last[0])
                set_meta(idx, "watermark_part_id", last[1])
                idx.commit()
            if since_disk_check >= 20_000:
                since_disk_check = 0
                # The estimate above is an estimate. Bail out with a readable
                # message rather than wedging the machine on a full disk.
                if shutil.disk_usage(index_dir).free < MIN_FREE_BYTES:
                    idx.commit()
                    raise SystemExit(
                        f"oc-search: stopping index build at {n:,} rows: less "
                        f"than {MIN_FREE_BYTES/1e9:.0f} GB free on {index_dir}. "
                        "Partial index kept; searches stay correct via the tail scan."
                    )
                if progress:
                    rate = n / max(time.monotonic() - t0, 1e-6)
                    warn(f"indexed {n:,} rows ({rate:,.0f}/s)")

        if last is not None:
            set_meta(idx, "watermark_rowid", last[0])
            set_meta(idx, "watermark_part_id", last[1])
        set_meta(idx, "built_at", int(time.time()))
        idx.commit()
        final_watermark = last[0] if last else watermark
        if is_rebuild:
            mode = "rebuild"
        elif reconciled_changed > 0 or reconciled_deleted > 0 or rechecked > 0:
            mode = "reconcile"
        elif n > 0:
            mode = "catchup"
        else:
            mode = "noop"

        return {
            "mode": mode,
            "indexed": n,
            "watermark": final_watermark,
            "up_to_date": final_watermark >= src_max,
            "reconciled_changed": reconciled_changed,
            "reconciled_deleted": reconciled_deleted,
            "rechecked": rechecked,
        }
    finally:
        try:
            idx.close()
        except sqlite3.Error:
            pass


# --------------------------------------------------------------------------
# Search
# --------------------------------------------------------------------------


def fts_phrase(query: str) -> str:
    """The query as a single FTS5 phrase.

    With the trigram tokenizer and detail=full this matches exactly the rows
    whose text contains `query` as a substring -- the phrase is the sequence of
    the query's overlapping trigrams, which can only be reconstructed by the
    literal string. Verified against instr() on real data (README).
    """
    return '"' + query.replace('"', '""') + '"'


def type_predicate(types: list[str] | None, column: str) -> tuple[str, list[Any]]:
    if types is None:
        return ("", [])
    placeholders = ",".join("?" * len(types))
    return (f" AND {column} IN ({placeholders})", list(types))


def search_indexed(
    idx: sqlite3.Connection, query: str, types: list[str] | None
) -> dict[str, tuple[int, int]]:
    pred, params = type_predicate(types, "pm.type")
    sql = (
        "SELECT pm.session_id AS sid, COUNT(*) AS n, MAX(pm.time_created) AS t "
        "FROM ft JOIN part_meta pm ON pm.rowid_ = ft.rowid "
        "WHERE ft MATCH ?" + pred + " GROUP BY pm.session_id"
    )
    out: dict[str, tuple[int, int]] = {}
    for r in idx.execute(sql, [fts_phrase(query)] + params):
        out[r["sid"]] = (int(r["n"]), int(r["t"]))
    return out


def scan_range(
    db_path: str,
    lo: int,
    hi: int,
    query: str,
    types: list[str] | None,
    deadline: Deadline,
) -> dict[str, tuple[int, int]]:
    """One rowid slice of the fallback scan.

    Both predicates stay in SQL and `data` is never selected: the blobs run to
    megabytes and there is nothing Python can do with them that instr() and
    json_extract() cannot do in C, without the copy.
    """
    pred, params = type_predicate(types, "json_extract(data,'$.type')")
    sql = (
        "SELECT session_id, COUNT(*), MAX(time_created) FROM part "
        "WHERE rowid > ? AND rowid <= ? AND instr(data, ?) > 0" + pred
        + " GROUP BY session_id"
    )
    conn = open_source(db_path, deadline)
    out: dict[str, tuple[int, int]] = {}
    try:
        for sid, n, t in conn.execute(sql, [lo, hi, query] + params):
            out[sid] = (int(n), int(t))
    finally:
        conn.close()
    return out


def merge(
    into: dict[str, tuple[int, int]], other: dict[str, tuple[int, int]]
) -> dict[str, tuple[int, int]]:
    for sid, (n, t) in other.items():
        pn, pt = into.get(sid, (0, 0))
        into[sid] = (pn + n, t if t > pt else pt)
    return into


def scan_parallel(
    db_path: str,
    lo: int,
    hi: int,
    query: str,
    types: list[str] | None,
    deadline: Deadline,
    jobs: int,
) -> dict[str, tuple[int, int]]:
    """Split [lo, hi] by rowid across `jobs` connections.

    Legitimate because rowid is monotonic in time and every row falls in
    exactly one half-open range. Threads rather than processes: sqlite3
    releases the GIL around each step(), and the work is I/O wait.
    """
    span = hi - lo
    if span <= 0:
        return {}
    jobs = max(1, min(jobs, span))
    if jobs == 1:
        return scan_range(db_path, lo, hi, query, types, deadline)
    chunk = span // jobs + 1
    results: list[dict[str, tuple[int, int]]] = [dict() for _ in range(jobs)]
    errors: list[BaseException] = []

    def work(i: int) -> None:
        a = lo + i * chunk
        b = min(lo + (i + 1) * chunk, hi)
        if a >= b:
            return
        try:
            results[i] = scan_range(db_path, a, b, query, types, deadline)
        except BaseException as exc:  # noqa: BLE001 - re-raised on the main thread
            errors.append(exc)

    threads = [threading.Thread(target=work, args=(i,)) for i in range(jobs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise errors[0]
    out: dict[str, tuple[int, int]] = {}
    for part in results:
        merge(out, part)
    return out


def search_recent(
    src: sqlite3.Connection,
    db_path: str,
    idx: sqlite3.Connection | None,
    floor: int,
    src_max: int,
    query: str,
    types: list[str] | None,
    limit: int,
    deadline: Deadline,
    jobs: int,
) -> dict[str, tuple[int, int]]:
    """The newest `limit` matching sessions, without aggregating every match.

    bead workstation-gqt3.1. The unlimited search aggregates every matching
    part in the database and only then sorts and truncates. lgtm keeps about
    ten rows of that, and was timing out at 25s even with a complete index,
    because a common needle such as a repo name matches millions of postings.

    WHEN STOPPING EARLY IS EXACT, AND WHEN IT IS NOT. Results are ordered by
    each session's newest match. Walking matching rows from the highest rowid
    down meets sessions in INSERTION order. That equals result order wherever
    `part.rowid` is monotonic in `time_created`: once `limit` live sessions
    have been met above rowid L, every unmet session has all of its matches at
    or below L, i.e. is older than all of them. Then the output is exactly the
    unlimited output's first `limit` rows.

    It is NOT monotonic everywhere. Rowids ~852,410-955,037 on cloudbox are a
    block of ~100k parts from 668 sessions (05-31..06-07), bulk-inserted
    2026-06-07 22:28 in roughly reverse chronological order, so times there run
    backwards by up to 168h. A needle whose N-th newest session falls in that
    era can get the wrong N sessions. Measured: `--types tool,text
    cops-6234-proto --limit 20` gets 5 of 20 wrong. Elsewhere inversions are
    under a minute: 248 in the last 1.5M rows, the largest 41s. So:
      - the sessions returned are always real matches, with exact counts and
        last_match from the live table, sorted by last_match;
      - which sessions are returned follows insertion order. That is the
        exact top N except around that block (or any future bulk insert).
    The exact fix is a stop rule bounded by a per-bucket running max of
    time_created kept by the indexer; it is deferred to the schema-v2 work
    (bead workstation-gqt3.3).

    THE WALK, top down:
      1. (floor, src_max] -- the rows the index has not seen, or the whole
         table when there is no usable index -- in rowid windows that start at
         RECENT_FIRST_WINDOW and double, each scanned with the same parallel
         instr() as the fallback. A common needle stops in the first window,
         so an absent or invalid index no longer means a full scan.
      2. Then, with a usable index, its postings at or below `floor` in
         descending rowid order, which FTS5 streams without sorting.

    WHY THE COUNTS ARE STILL EXACT. The walk only decides WHICH sessions are
    returned. Each one is then recounted against the live table through
    part_session_idx, so `matches` covers matches far below where the walk
    stopped, and a stale index posting for a part deleted since indexing
    cannot make a session appear (a recount of 0 drops it and the walk goes
    on). Deleted sessions are skipped the same way, so they do not use up one
    of the `limit` slots.
    """
    picked: dict[str, tuple[int, int]] = {}
    seen: set[str] = set()
    pred, params = type_predicate(types, "json_extract(data,'$.type')")
    recount_sql = (
        "SELECT COUNT(*), MAX(time_created) FROM part "
        "WHERE session_id = ? AND instr(data, ?) > 0" + pred
    )

    def consider(sid: str) -> bool:
        """Account for one session; True once `limit` sessions are picked."""
        if sid in seen:
            return False
        seen.add(sid)
        if src.execute("SELECT 1 FROM session WHERE id=?", (sid,)).fetchone() is None:
            return False
        n, t = src.execute(recount_sql, [sid, query] + params).fetchone()
        if n:
            picked[sid] = (int(n), int(t))
        deadline.check()
        return len(picked) >= limit

    hi = src_max
    window = RECENT_FIRST_WINDOW
    while hi > floor:
        lo = max(floor, hi - window)
        found = scan_parallel(db_path, lo, hi, query, types, deadline, jobs)
        deadline.check()
        # Newest match first. A session's newest match in this window is its
        # newest overall unless it was already met higher up, in which case
        # consider() skips it.
        for sid in sorted(found, key=lambda s: found[s][1], reverse=True):
            if consider(sid):
                return picked
        hi = lo
        window *= RECENT_WINDOW_GROWTH

    if idx is not None and floor > 0:
        ipred, iparams = type_predicate(types, "pm.type")
        cur = idx.execute(
            "SELECT pm.session_id FROM ft JOIN part_meta pm ON pm.rowid_ = ft.rowid "
            "WHERE ft MATCH ? AND ft.rowid <= ?" + ipred + " ORDER BY ft.rowid DESC",
            [fts_phrase(query), floor] + iparams,
        )
        try:
            for (sid,) in cur:
                if consider(sid):
                    break
        finally:
            cur.close()
    return picked


def decorate(
    src: sqlite3.Connection, hits: dict[str, tuple[int, int]]
) -> list[dict[str, Any]]:
    """Attach session title/directory, dropping sessions that no longer exist.

    Deleted sessions are how opencode reclaims space, and dropping them here is
    also what keeps a stale index from reporting rows for sessions that are
    gone.
    """
    rows: list[dict[str, Any]] = []
    ids = list(hits)
    for i in range(0, len(ids), 400):
        chunk = ids[i : i + 400]
        q = (
            "SELECT id, title, directory FROM session WHERE id IN ("
            + ",".join("?" * len(chunk))
            + ")"
        )
        for r in src.execute(q, chunk):
            n, t = hits[r["id"]]
            rows.append(
                {
                    "id": r["id"],
                    "title": r["title"] or "",
                    "directory": r["directory"] or "",
                    "last_match_ms": t,
                    "matches": n,
                }
            )
    rows.sort(key=lambda r: r["last_match_ms"], reverse=True)
    return rows


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def render_table(rows: list[dict[str, Any]]) -> str:
    """The column layout the old sqlite3 `.mode column` output had.

    Kept byte-shaped rather than improved on purpose: lgtm slices the first
    2000 characters of this into a review packet, and humans read the id out
    of column one.
    """
    header = ["id", "title", "directory", "last_match", "matches"]
    body = [
        [
            r["id"],
            r["title"][:40],
            r["directory"][:45],
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["last_match_ms"] / 1000)),
            str(r["matches"]),
        ]
        for r in rows
    ]
    widths = [len(h) for h in header]
    for line in body:
        for i, cell in enumerate(line):
            widths[i] = max(widths[i], len(cell))
    out = [
        "  ".join(h.ljust(widths[i]) for i, h in enumerate(header)),
        "  ".join("-" * widths[i] for i in range(len(header))),
    ]
    out += ["  ".join(c.ljust(widths[i]) for i, c in enumerate(line)) for line in body]
    return "\n".join(out)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def resolve_types(args: argparse.Namespace) -> list[str] | None:
    if args.search_all:
        return None
    types = [t.strip() for t in args.types.split(",") if t.strip()]
    return types or None


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    db_path = os.path.expanduser(args.db or DEFAULT_DB)
    if not os.path.exists(db_path):
        warn(f"database not found at {db_path}")
        return 1
    index_path = os.path.expanduser(args.index_path or default_index_path(db_path))

    if args.timeout is not None:
        budget: float | None = args.timeout
    elif args.index or args.index_info:
        # Indexing is a deliberately long operation; a search is not.
        budget = None
    else:
        budget = None if sys.stdout.isatty() else DEFAULT_NONINTERACTIVE_TIMEOUT_S
    deadline = Deadline(budget)

    src = open_source(db_path, deadline)

    if args.index_info:
        idx = open_index_ro(index_path)
        info: dict[str, Any] = {"index_path": index_path, "exists": idx is not None}
        if idx is not None:
            usable, watermark, reason = index_validity(src, idx, db_path)
            _, src_max = part_rowid_bounds(src)
            info.update(
                usable=usable,
                reason=reason,
                watermark=watermark,
                source_max_rowid=src_max,
                unindexed_rows_estimate=max(0, src_max - watermark),
                bytes=os.path.getsize(index_path),
                built_at=get_meta(idx, "built_at"),
            )
            idx.close()
        src.close()
        print(json.dumps(info, indent=2))
        return 0

    if args.index:
        lock_path = index_path + ".lock"
        os.makedirs(os.path.dirname(os.path.abspath(lock_path)), exist_ok=True)
        lock_file = open(lock_path, "a")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as exc:
            if isinstance(exc, BlockingIOError) or exc.errno in (
                errno.EAGAIN,
                errno.EWOULDBLOCK,
                errno.EACCES,
            ):
                lock_file.close()
                src.close()
                print(f"oc-search: index build already in progress on {index_path}")
                return 0
            lock_file.close()
            src.close()
            raise
        try:
            if args.if_exists and not os.path.exists(index_path):
                # Not an error: this is the timer finding nothing to do on a host
                # where nobody has opted into the index yet.
                print(f"no index at {index_path}; nothing to refresh")
                return 0
            ok, why = fts5_trigram_available()
            if not ok:
                warn(f"this SQLite cannot build the index (FTS5 trigram: {why})")
                return 1
            t0 = time.monotonic()
            res = build_index(
                src,
                index_path,
                db_path,
                rebuild=args.rebuild,
                batch=args.index_batch,
                progress=sys.stderr.isatty(),
            )
            dt = time.monotonic() - t0
            print(
                f"indexed {res['indexed']:,} rows in {dt:.1f}s; watermark "
                f"{res['watermark']}; {'up to date' if res['up_to_date'] else 'MORE REMAINS -- run again'}"
            )
            return 0 if res["up_to_date"] else 3
        finally:
            src.close()
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                lock_file.close()
            except Exception:
                pass

    query = args.query or ""
    types = resolve_types(args)

    idx = None
    watermark = 0
    used_index = False
    hits: dict[str, tuple[int, int]] = {}
    rows: list[dict[str, Any]] = []
    try:
        idx = None if args.no_index else open_index_ro(index_path, deadline)
        if idx is not None:
            ok, why = fts5_trigram_available()
            if not ok:
                warn(f"ignoring index: FTS5 trigram unavailable ({why})")
                idx.close()
                idx = None
        # With --limit an unusable index costs a newest-first walk that stops
        # at N sessions, not a full scan, so the warnings say so.
        fallback = "a newest-first scan" if args.limit > 0 else "a full scan"
        if idx is not None:
            usable, watermark, reason = index_validity(src, idx, db_path)
            if not usable:
                warn(f"index unusable: {reason}. Falling back to {fallback}.")
                idx.close()
                idx = None
                watermark = 0
            elif len(query) < MIN_TRIGRAM_LEN:
                warn(
                    f"query shorter than {MIN_TRIGRAM_LEN} characters cannot use the "
                    f"trigram index. Falling back to {fallback}."
                )
                idx.close()
                idx = None
                watermark = 0
            else:
                used_index = True

        if not used_index and args.limit > 0:
            warn(
                f"no usable index at {index_path}: scanning newest-first until "
                f"{args.limit} sessions match. A rare needle can still read every "
                "part row. Build the index once with `oc-search --index`."
            )
        elif not used_index:
            warn(
                f"no usable index at {index_path}: scanning every part row "
                f"({args.jobs}-way). This reads gigabytes and takes minutes on a "
                "cold cache. Build the index once with `oc-search --index`."
            )

        src_min, src_max = part_rowid_bounds(src)
        deadline.check()
        if args.limit > 0:
            hits = search_recent(
                src,
                db_path,
                idx if used_index else None,
                watermark if used_index else max(src_min - 1, 0),
                src_max,
                query,
                types,
                args.limit,
                deadline,
                args.jobs,
            )
        elif used_index and idx is not None:
            hits = search_indexed(idx, query, types)
            # Everything the index has not seen yet, always, so that a stale
            # index costs time and never truth.
            if src_max > watermark:
                merge(
                    hits,
                    scan_parallel(
                        db_path, watermark, src_max, query, types, deadline, args.jobs
                    ),
                )
            deadline.check()
        else:
            lo = max(src_min - 1, 0)
            hits = scan_parallel(
                db_path, lo, src_max, query, types, deadline, args.jobs
            )
            deadline.check()
    except (sqlite3.OperationalError, TimedOut) as exc:
        if deadline.tripped.is_set() or isinstance(exc, TimedOut):
            warn(
                f"aborted after {budget:g}s: {'index query' if used_index else 'full scan'} "
                f"of {db_path} did not finish. "
                + (
                    "The index is stale -- run `oc-search --index`."
                    if used_index
                    else "Run `oc-search --index` once to make this fast."
                )
            )
            return 2
        raise
    finally:
        if idx is not None:
            idx.close()

    rows = decorate(src, hits)
    if args.limit > 0:
        rows = rows[: args.limit]
    src.close()

    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        warn(f"no sessions matched {query!r}")
        return 0
    print(render_table(rows))
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except BrokenPipeError:
        return 0
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
