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
import json
import os
import shutil
import sqlite3
import sys
import threading
import time
from typing import Any, Iterable

DEFAULT_DB = "~/.local/share/opencode/opencode.db"
DEFAULT_TYPES = "tool"

# Bump when the sidecar layout changes; a mismatch forces a rebuild.
INDEX_SCHEMA_VERSION = 1

# Trigram FTS5 cannot represent a pattern shorter than one trigram.
MIN_TRIGRAM_LEN = 3

# Fallback-scan parallelism. The scan is I/O-latency bound and sqlite3 releases
# the GIL for the duration of each step(), so threads give real overlap.
DEFAULT_JOBS = 16

# Non-interactive callers (lgtm) get a deadline they can see in a log line.
# Interactive humans get none by default -- a first-ever full scan is slow but
# it is theirs to wait for.
DEFAULT_NONINTERACTIVE_TIMEOUT_S = 25.0

# Per --index run, how many tail rows to fold into the index. Bounds the cost
# of the implicit catch-up so a search never turns into a rebuild.
DEFAULT_INDEX_BATCH = 200_000

# Measured index size ratio (trigram, detail=full, contentless), used only to
# refuse a build that would fill the disk.
INDEX_SIZE_RATIO = 2.8

# Hard floor: never let an index build take the machine's last few GB.
MIN_FREE_BYTES = 5_000_000_000

# Rows per index-build transaction. Bounds WAL growth and bounds the work lost
# if the build is interrupted. Measured: at 50,000 the WAL still reached 2.2 GB
# mid-build, because FTS5 segment merges amplify a transaction far past the
# bytes inserted into it. 10,000 keeps the checkpoint interval short enough for
# journal_size_limit to actually claw the file back.
COMMIT_EVERY = 10_000


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


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
        "--limit", type=int, default=0, metavar="N", help="Show at most N sessions."
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
        type=int,
        default=DEFAULT_INDEX_BATCH,
        metavar="N",
        help=f"Max tail rows folded in per --index run (default: {DEFAULT_INDEX_BATCH}).",
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


def open_source(path: str, deadline: Deadline | None = None) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5.0)
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
  USING fts5(data, tokenize="trigram case_sensitive 1", content='');
CREATE TABLE IF NOT EXISTS part_meta (
  rowid_ INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  type TEXT
);
"""


def fts5_trigram_available() -> tuple[bool, str]:
    """Can this SQLite build do what the index needs?

    Checked rather than assumed: the whole exactness argument rests on the
    trigram tokenizer with detail=full, and a SQLite compiled without FTS5
    would otherwise surface as a confusing error deep inside a build.
    """
    try:
        probe = sqlite3.connect(":memory:")
        probe.execute(
            "CREATE VIRTUAL TABLE t USING fts5(x, tokenize=\"trigram case_sensitive 1\")"
        )
        probe.execute("INSERT INTO t(x) VALUES ('FbmEmployeeCutoff')")
        n = probe.execute("SELECT count(*) FROM t WHERE t MATCH '\"Employee\"'").fetchone()[0]
        probe.close()
    except sqlite3.Error as exc:
        return (False, str(exc))
    if n != 1:
        return (False, "trigram phrase match returned the wrong row count")
    return (True, "")


def open_index_rw(path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5.0)
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


def build_index(
    src: sqlite3.Connection,
    index_path: str,
    db_path: str,
    *,
    rebuild: bool,
    batch: int,
    progress: bool,
) -> dict[str, Any]:
    if rebuild:
        for suffix in ("", "-wal", "-shm"):
            try:
                os.remove(index_path + suffix)
            except FileNotFoundError:
                pass

    _, src_max = part_rowid_bounds(src)
    idx = open_index_rw(index_path)
    try:
        usable, watermark, reason = index_validity(src, idx, db_path)
        if not usable and get_meta(idx, "watermark_rowid") is not None:
            warn(f"{reason}; rebuilding from scratch")
            idx.close()
            return build_index(
                src, index_path, db_path, rebuild=True, batch=batch, progress=progress
            )

        if watermark >= src_max:
            return {"indexed": 0, "watermark": watermark, "up_to_date": True}

        # Refuse to fill the disk. Estimated from a bounded sample rather than
        # SUM(length(data)) over the pending range -- that sum is itself the
        # multi-minute full scan this whole change exists to avoid, and running
        # it as a "cheap precheck" is how the first version of --index timed
        # itself out.
        sample = src.execute(
            "SELECT AVG(len) FROM (SELECT length(data) AS len FROM part "
            "WHERE rowid > ? ORDER BY rowid LIMIT 2000)",
            (watermark,),
        ).fetchone()[0]
        pending_rows = min(batch, max(0, src_max - watermark))
        need = int((sample or 0) * pending_rows * INDEX_SIZE_RATIO * 1.5)
        index_dir = os.path.dirname(index_path)
        free = shutil.disk_usage(index_dir).free
        if need > free:
            raise SystemExit(
                f"oc-search: refusing to index: estimated ~{need/1e9:.1f} GB "
                f"needed, {free/1e9:.1f} GB free on {index_dir}"
            )

        set_meta(idx, "schema_version", INDEX_SCHEMA_VERSION)
        set_meta(idx, "source_db", os.path.realpath(db_path))

        # `type` is resolved by json_extract in SQL, exactly as the old
        # implementation filtered it: the field's position inside the blob
        # varies, so no cheaper string probe is safe.
        cur = src.execute(
            "SELECT rowid, id, session_id, time_created, "
            "json_extract(data,'$.type') AS type, data FROM part "
            "WHERE rowid > ? ORDER BY rowid LIMIT ?",
            (watermark, batch),
        )
        n = 0
        last: tuple[int, str] | None = None
        t0 = time.monotonic()
        while True:
            rows = cur.fetchmany(2000)
            if not rows:
                break
            payload = []
            metas = []
            for r in rows:
                payload.append((r["rowid"], r["data"]))
                metas.append(
                    (r["rowid"], r["session_id"], r["time_created"], r["type"])
                )
                last = (int(r["rowid"]), r["id"])
            idx.executemany("INSERT INTO ft(rowid, data) VALUES (?,?)", payload)
            idx.executemany(
                "INSERT OR REPLACE INTO part_meta "
                "(rowid_, session_id, time_created, type) VALUES (?,?,?,?)",
                metas,
            )
            n += len(rows)
            if last is not None and n % COMMIT_EVERY == 0:
                # Commit the watermark WITH the rows it describes, periodically.
                # One transaction around the whole build would grow a WAL the
                # size of the finished index (observed passing 900 MB inside two
                # minutes), and would throw away every row on an interruption.
                # Committing in step means an interrupted build is simply a
                # smaller index, which the tail scan already covers.
                set_meta(idx, "watermark_rowid", last[0])
                set_meta(idx, "watermark_part_id", last[1])
                idx.commit()
            if n % 20_000 == 0:
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
        return {
            "indexed": n,
            "watermark": last[0] if last else watermark,
            "up_to_date": (last[0] if last else watermark) >= src_max,
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
        print(json.dumps(info, indent=2))
        return 0

    if args.index:
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
        if idx is not None:
            usable, watermark, reason = index_validity(src, idx, db_path)
            if not usable:
                warn(f"index unusable: {reason}. Falling back to a full scan.")
                idx.close()
                idx = None
                watermark = 0
            elif len(query) < MIN_TRIGRAM_LEN:
                warn(
                    f"query shorter than {MIN_TRIGRAM_LEN} characters cannot use the "
                    "trigram index. Falling back to a full scan."
                )
                idx.close()
                idx = None
                watermark = 0
            else:
                used_index = True

        if not used_index:
            warn(
                f"no usable index at {index_path}: scanning every part row "
                f"({args.jobs}-way). This reads gigabytes and takes minutes on a "
                "cold cache. Build the index once with `oc-search --index`."
            )

        src_min, src_max = part_rowid_bounds(src)
        deadline.check()
        if used_index and idx is not None:
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
