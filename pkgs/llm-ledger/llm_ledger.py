#!/usr/bin/env python3
"""llm-ledger: maintains /var/lib/llm-ledger/ledger.db and raw archives."""

from __future__ import annotations

import argparse
import datetime
import gzip
import json
import os
import socket
import sqlite3
import sys
import time
import zlib
from collections.abc import Sequence
from pathlib import Path
from typing import Any

# Import oc_tags (sibling directory in repo checkout or beside this file in store)
try:
    import oc_tags
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "oc-tags"))
    import oc_tags

DEFAULT_DB = "/var/lib/llm-ledger/ledger.db"
DEFAULT_EVENTS = "/var/lib/claude-failover-proxy/events.jsonl"
DEFAULT_SAMPLES = "/var/lib/teamclaude-pool-canary/quota-samples.jsonl"
DEFAULT_SAMPLES_ARCHIVE = "/var/lib/teamclaude-pool-canary/archive"

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS route (
  request_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, session_id TEXT,
  model TEXT, desired TEXT, chosen TEXT);

CREATE TABLE IF NOT EXISTS requests (
  request_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, host TEXT NOT NULL,
  session_id TEXT,
  attr_key TEXT NOT NULL,
  backend TEXT, model TEXT,
  input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
  cost_usd REAL, status INTEGER, duration_ms INTEGER);

CREATE INDEX IF NOT EXISTS requests_ts ON requests(ts, attr_key, backend, model, cost_usd);
CREATE INDEX IF NOT EXISTS requests_attr_ts ON requests(attr_key, ts);

CREATE TABLE IF NOT EXISTS session_program (
  attr_key TEXT PRIMARY KEY, tag TEXT NOT NULL,
  source TEXT NOT NULL,
  root TEXT, title TEXT, updated_at INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS session_program_tag ON session_program(tag, attr_key);

CREATE TABLE IF NOT EXISTS hourly (
  hour INTEGER NOT NULL,
  attr_key TEXT NOT NULL, backend TEXT NOT NULL, model TEXT NOT NULL,
  n INTEGER, input INTEGER, output INTEGER, cache_read INTEGER,
  cache_write INTEGER, cost_usd REAL,
  PRIMARY KEY (hour, attr_key, backend, model));

CREATE TABLE IF NOT EXISTS quota_pool (
  ts INTEGER PRIMARY KEY, healthy INTEGER, canary_healthy INTEGER,
  canary_serving INTEGER, roster INTEGER, current TEXT, fwh REAL);

CREATE TABLE IF NOT EXISTS quota_samples (
  ts INTEGER NOT NULL, account TEXT NOT NULL, s TEXT, u5h REAL, u7d REAL,
  u7d_fable REAL, fw INTEGER, r7d INTEGER, r5h INTEGER,
  PRIMARY KEY (ts, account));

CREATE TABLE IF NOT EXISTS ingest_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def to_int(val: Any) -> int | None:
    if val is None or isinstance(val, bool):
        return None
    try:
        return int(val)
    except (ValueError, TypeError):
        return None


def to_float(val: Any) -> float | None:
    if val is None or isinstance(val, bool):
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def to_fw_int(val: Any) -> int | None:
    if val is True:
        return 1
    if val is False:
        return 0
    if val == 1 and not isinstance(val, bool):
        return 1
    if val == 0 and not isinstance(val, bool):
        return 0
    return None


def parse_iso_ts(val: Any) -> int | None:
    if not isinstance(val, str) or not val:
        return None
    try:
        dt = datetime.datetime.fromisoformat(val)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return round(dt.timestamp() * 1000)
    except Exception:
        return None


def parse_quota_sample_line(
    line_str: str,
) -> tuple[tuple[Any, ...] | None, list[tuple[Any, ...]], bool]:
    """Parse one quota sample line.

    Returns:
        (pool_row | None, sample_rows, is_malformed)
        pool_row: (ts, healthy, canary_healthy, canary_serving, roster, current, fwh)
        sample_rows: list of (ts, account, s, u5h, u7d, u7d_fable, fw, r7d, r5h)
    """
    stripped = line_str.strip()
    if not stripped:
        return None, [], False

    try:
        obj = json.loads(stripped)
    except Exception:
        return None, [], True

    if not isinstance(obj, dict):
        return None, [], True

    ts_ms = parse_iso_ts(obj.get("ts"))
    if ts_ms is None:
        return None, [], True

    pool_row = (
        ts_ms,
        to_int(obj.get("healthy")),
        to_int(obj.get("canary_healthy")),
        to_int(obj.get("canary_serving")),
        to_int(obj.get("roster")),
        str(obj["current"]) if obj.get("current") is not None else None,
        to_float(obj.get("fwh")),
    )

    accounts = obj.get("accounts")
    if accounts is None:
        accounts = []
    elif not isinstance(accounts, list):
        return None, [], True

    sample_rows: list[tuple[Any, ...]] = []
    for acc in accounts:
        if not isinstance(acc, dict):
            continue
        acc_name = acc.get("n")
        if not acc_name or not isinstance(acc_name, str):
            continue
        s = str(acc["s"]) if acc.get("s") is not None else None
        u5h = to_float(acc.get("u5h"))
        u7d = to_float(acc.get("u7d"))
        u7d_fable = to_float(acc.get("u7dF"))
        fw = to_fw_int(acc.get("fw"))
        r7d = to_int(acc.get("r7d"))
        r5h = to_int(acc.get("r5h"))
        sample_rows.append((ts_ms, acc_name, s, u5h, u7d, u7d_fable, fw, r7d, r5h))

    return pool_row, sample_rows, False


def open_ledger_db(db_path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path)
    res = conn.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
    if res.upper() != "DELETE":
        raise RuntimeError(f"Failed to set journal_mode=DELETE (got {res})")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA_SQL)
    conn.commit()
    return conn


def get_ingest_state(conn: sqlite3.Connection) -> dict[str, str]:
    return dict(conn.execute("SELECT key, value FROM ingest_state").fetchall())


def compute_attr_key(
    sid: str | None,
    ts: int,
    resolver: oc_tags.CfpSessionResolver | None,
) -> str:
    if sid is None or not isinstance(sid, str):
        return oc_tags.CFP_UNROUTED_TAG
    if sid.startswith("ses_"):
        return sid
    if oc_tags._GOOSE_SESSION_ID.match(sid):
        claim = resolver.goose_claim(sid, ts) if resolver else None
        if claim is not None:
            return claim[0]
        if resolver and resolver.in_goose_serve(sid):
            return f"goose:{sid}"
        return oc_tags.CFP_GOOSE_UNKNOWN_TAG
    return oc_tags.CFP_UNROUTED_TAG


def parse_raw_lines(
    lines: Sequence[bytes],
) -> list[tuple[bytes, dict[str, Any] | None, int | None, bool]]:
    """Parse raw byte lines once.

    Returns:
        list of (raw_bytes, json_dict | None, ts | None, is_malformed)
    """
    parsed: list[tuple[bytes, dict[str, Any] | None, int | None, bool]] = []
    for raw in lines:
        try:
            line_str = raw.decode("utf-8")
        except UnicodeDecodeError:
            parsed.append((raw, None, None, True))
            continue

        stripped = line_str.strip()
        if not stripped:
            continue

        try:
            obj = json.loads(stripped)
            if isinstance(obj, dict):
                ts = to_int(obj.get("ts"))
                parsed.append((raw, obj, ts, False))
            else:
                parsed.append((raw, None, None, True))
        except Exception:
            parsed.append((raw, None, None, True))

    return parsed


def process_batch(
    conn: sqlite3.Connection,
    parsed_lines: Sequence[tuple[bytes, dict[str, Any] | None, int | None, bool]],
    host: str,
    opencode_db: str | None,
    goose_db: str | None,
    tags_db: str | None,
    lgtm_ledger: str | None,
    tag_map: dict[str, str],
) -> tuple[int, int, int, int]:
    """Process pre-parsed lines, inserting routes and requests into conn.

    Returns:
        (new_routes, new_requests, malformed, max_ts)
    """
    batch_routes: list[tuple[str, int, str | None, str | None, str | None, str | None]] = []
    batch_usages: list[dict[str, Any]] = []
    malformed = sum(1 for _, _, _, is_mal in parsed_lines if is_mal)
    max_ts = 0

    for _raw, obj, ts, is_mal in parsed_lines:
        if is_mal or obj is None:
            continue

        ltype = obj.get("type")
        if ltype in ("keepwarm", "boot"):
            continue
        if ltype not in ("route", "usage"):
            malformed += 1
            continue

        req_id = obj.get("requestId")
        if not req_id or not isinstance(req_id, str):
            malformed += 1
            continue

        if ts is None:
            malformed += 1
            continue
        if ts > max_ts:
            max_ts = ts

        if ltype == "route":
            sid = str(obj["sessionId"]) if obj.get("sessionId") is not None else None
            model = str(obj["model"]) if obj.get("model") is not None else None
            desired = str(obj["desired"]) if obj.get("desired") is not None else None
            chosen = str(obj["chosen"]) if obj.get("chosen") is not None else None
            batch_routes.append((req_id, ts, sid, model, desired, chosen))
        elif ltype == "usage":
            dur = to_int(obj.get("durationMs"))
            cost = to_float(obj.get("cost"))
            status = to_int(obj.get("status"))
            backend = str(obj.get("backend")) if obj.get("backend") is not None else None
            usage_field = obj.get("usage")
            u_dict = usage_field if isinstance(usage_field, dict) else {}
            inp = to_int(u_dict.get("input"))
            outp = to_int(u_dict.get("output"))
            cread = to_int(u_dict.get("cacheRead"))
            cwrite = to_int(u_dict.get("cacheWrite"))
            batch_usages.append({
                "req_id": req_id,
                "ts": ts,
                "duration_ms": dur,
                "cost_usd": cost,
                "status": status,
                "backend": backend,
                "input": inp,
                "output": outp,
                "cache_read": cread,
                "cache_write": cwrite,
            })

    # Insert batch routes into route table
    new_routes = 0
    if batch_routes:
        cur = conn.cursor()
        cur.executemany(
            "INSERT OR IGNORE INTO route (request_id, ts, session_id, model, desired, chosen) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            batch_routes,
        )
        new_routes = cur.rowcount

    # Match routes for batch usages:
    # First from batch_routes in memory, then from DB route table in chunks of <= 500
    batch_routes_map = {r[0]: (r[2], r[3]) for r in batch_routes}
    missing_route_ids = []
    for u in batch_usages:
        rid = u["req_id"]
        if rid in batch_routes_map:
            u["sid"], u["model"] = batch_routes_map[rid]
        else:
            missing_route_ids.append(rid)

    if missing_route_ids:
        db_route_map: dict[str, tuple[str | None, str | None]] = {}
        for i in range(0, len(missing_route_ids), 500):
            chunk = missing_route_ids[i : i + 500]
            placeholders = ",".join("?" for _ in chunk)
            for row in conn.execute(
                f"SELECT request_id, session_id, model FROM route WHERE request_id IN ({placeholders})",
                chunk,
            ):
                db_route_map[row[0]] = (row[1], row[2])

        for u in batch_usages:
            if "sid" not in u:
                rid = u["req_id"]
                if rid in db_route_map:
                    u["sid"], u["model"] = db_route_map[rid]
                else:
                    u["sid"], u["model"] = None, None

    # Resolve attr_keys for batch usages
    goose_sids = {
        u["sid"]
        for u in batch_usages
        if u["sid"] and oc_tags._GOOSE_SESSION_ID.match(u["sid"])
    }
    resolver = None
    if goose_sids:
        min_ts = min(u["ts"] for u in batch_usages if u["sid"] in goose_sids)
        max_ts_g = max(u["ts"] for u in batch_usages if u["sid"] in goose_sids)
        resolver = oc_tags.CfpSessionResolver(
            session_ids=goose_sids,
            db_path=opencode_db or oc_tags.DEFAULT_OPENCODE_DB,
            goose_db=goose_db or oc_tags.DEFAULT_GOOSE_DB,
            session_tags=tag_map,
            lgtm_ledger=lgtm_ledger,
            since_ms=min_ts,
            until_ms=max_ts_g + 1,
        )

    requests_rows = []
    for u in batch_usages:
        attr_key = compute_attr_key(u["sid"], u["ts"], resolver)
        requests_rows.append((
            u["req_id"],
            u["ts"],
            host,
            u["sid"],
            attr_key,
            u["backend"],
            u["model"],
            u["input"],
            u["output"],
            u["cache_read"],
            u["cache_write"],
            u["cost_usd"],
            u["status"],
            u["duration_ms"],
        ))

    # Insert into requests
    new_requests = 0
    if requests_rows:
        cur = conn.cursor()
        cur.executemany(
            "INSERT OR IGNORE INTO requests (request_id, ts, host, session_id, attr_key, backend, model, "
            "input, output, cache_read, cache_write, cost_usd, status, duration_ms) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            requests_rows,
        )
        new_requests = cur.rowcount

    # Route-after-usage fill-in: check this batch's route request_ids via PK in chunks of <= 500
    if batch_routes:
        route_ids = list({r[0] for r in batch_routes})
        needs_fill: list[tuple[str, int]] = []
        for i in range(0, len(route_ids), 500):
            chunk = route_ids[i : i + 500]
            placeholders = ",".join("?" for _ in chunk)
            for row in conn.execute(
                f"SELECT request_id, ts FROM requests WHERE request_id IN ({placeholders}) AND session_id IS NULL",
                chunk,
            ):
                needs_fill.append((row[0], row[1]))

        if needs_fill:
            route_by_id = {r[0]: r for r in batch_routes}
            fill_goose_sids = {
                route_by_id[req_id][2]
                for req_id, _ in needs_fill
                if route_by_id[req_id][2] and oc_tags._GOOSE_SESSION_ID.match(route_by_id[req_id][2])
            }
            fill_resolver = None
            if fill_goose_sids:
                goose_fill_ts = [
                    ts for req_id, ts in needs_fill
                    if route_by_id[req_id][2] in fill_goose_sids
                ]
                fill_resolver = oc_tags.CfpSessionResolver(
                    session_ids=fill_goose_sids,
                    db_path=opencode_db or oc_tags.DEFAULT_OPENCODE_DB,
                    goose_db=goose_db or oc_tags.DEFAULT_GOOSE_DB,
                    session_tags=tag_map,
                    lgtm_ledger=lgtm_ledger,
                    since_ms=min(goose_fill_ts),
                    until_ms=max(goose_fill_ts) + 1,
                )

            updates = []
            for req_id, req_ts in needs_fill:
                r = route_by_id[req_id]
                sid = r[2]
                model = r[3]
                attr_k = compute_attr_key(sid, req_ts, fill_resolver)
                updates.append((sid, model, attr_k, req_id))

            if updates:
                conn.executemany(
                    "UPDATE requests SET session_id = ?, model = ?, attr_key = ? "
                    "WHERE request_id = ? AND session_id IS NULL",
                    updates,
                )

    return new_routes, new_requests, malformed, max_ts


def step_cfp_tail_and_archive(
    conn: sqlite3.Connection,
    events_path: str,
    raw_dir: str,
    host: str,
    opencode_db: str | None = None,
    goose_db: str | None = None,
    tags_db: str | None = None,
    lgtm_ledger: str | None = None,
    batch_size: int = 50000,
) -> dict[str, int]:
    """Step 1 & 2: cfp tail ingest and raw gzip archive."""
    state = get_ingest_state(conn)
    stored_inode = int(state["cfp_inode"]) if "cfp_inode" in state else None
    stored_offset = int(state["cfp_offset"]) if "cfp_offset" in state else 0
    stored_archived_ts = (
        int(state["cfp_archived_through_ts"])
        if "cfp_archived_through_ts" in state
        else None
    )

    try:
        f = open(events_path, "rb")
    except OSError:
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

    with f:
        st = os.fstat(f.fileno())
        cur_inode = st.st_ino
        cur_size = st.st_size

        is_restart = (stored_inode is not None) and (
            cur_inode != stored_inode or cur_size < stored_offset
        )
        read_offset = 0 if (is_restart or stored_inode is None) else stored_offset
        cutoff = (
            (stored_archived_ts - 600_000)
            if (is_restart and stored_archived_ts is not None)
            else None
        )

        if cur_size <= read_offset:
            return {"new_routes": 0, "new_requests": 0, "malformed": 0}

        f.seek(read_offset)

        # Load session tags if tags.db exists
        tag_map: dict[str, str] = {}
        actual_tags_db = tags_db or oc_tags.DEFAULT_TAGS_DB
        if actual_tags_db and os.path.exists(actual_tags_db):
            try:
                store = oc_tags.open_store(actual_tags_db, readonly=True)
                try:
                    tag_map = oc_tags.session_tags(store)
                finally:
                    store.close()
            except Exception:
                tag_map = {}

        total_new_routes = 0
        total_new_requests = 0
        total_malformed = 0
        current_archived_through_ts = stored_archived_ts or 0
        current_offset = read_offset

        batch_lines: list[bytes] = []
        batch_bytes_len = 0

        def process_and_commit_batch(lines: list[bytes], byte_len: int) -> None:
            nonlocal current_offset, total_new_routes, total_new_requests, total_malformed, current_archived_through_ts
            if not lines:
                return

            parsed = parse_raw_lines(lines)

            # Step 2: raw archive BEFORE DB commit
            if is_restart:
                archive_bytes = b"".join(
                    raw for raw, obj, ts, is_mal in parsed
                    if not is_mal and ts is not None and (cutoff is None or ts > cutoff)
                )
            else:
                archive_bytes = b"".join(lines)

            if archive_bytes:
                os.makedirs(raw_dir, exist_ok=True)
                utc_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
                archive_file = os.path.join(raw_dir, f"cfp-events-{utc_date}.jsonl.gz")
                with open(archive_file, "ab") as af:
                    af.write(gzip.compress(archive_bytes))

            # Step 1: parse and insert into DB
            routes_n, reqs_n, malformed_n, batch_max_ts = process_batch(
                conn=conn,
                parsed_lines=parsed,
                host=host,
                opencode_db=opencode_db,
                goose_db=goose_db,
                tags_db=tags_db,
                lgtm_ledger=lgtm_ledger,
                tag_map=tag_map,
            )

            total_new_routes += routes_n
            total_new_requests += reqs_n
            total_malformed += malformed_n
            if batch_max_ts > current_archived_through_ts:
                current_archived_through_ts = batch_max_ts

            batch_end_offset = current_offset + byte_len

            # Commit DB transaction including offset and inode
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_inode', ?)",
                (str(cur_inode),),
            )
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_offset', ?)",
                (str(batch_end_offset),),
            )
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_archived_through_ts', ?)",
                (str(current_archived_through_ts),),
            )
            conn.commit()
            current_offset = batch_end_offset

        while True:
            line = f.readline()
            if not line:
                break
            if not line.endswith(b"\n"):
                # Partial line at EOF - stop without consuming it
                break
            batch_lines.append(line)
            batch_bytes_len += len(line)
            if len(batch_lines) >= batch_size:
                process_and_commit_batch(batch_lines, batch_bytes_len)
                batch_lines = []
                batch_bytes_len = 0

        if batch_lines:
            process_and_commit_batch(batch_lines, batch_bytes_len)

    return {
        "new_routes": total_new_routes,
        "new_requests": total_new_requests,
        "malformed": total_malformed,
    }


def ingest_quota_lines(
    lines: Any,
    conn: sqlite3.Connection,
    newest_ts: int | None = None,
    batch_size: int = 50000,
    check_trailing_newline: bool = False,
) -> tuple[int, int, int, int]:
    """Process an iterable of quota lines and stage inserts into quota_pool and quota_samples.

    Returns:
        (pool_rows_added, sample_rows_added, malformed_count, lines_read)
    """
    pool_rows_added = 0
    sample_rows_added = 0
    malformed_count = 0
    lines_read = 0
    cur = conn.cursor()
    pool_batch: list[tuple[Any, ...]] = []
    sample_batch: list[tuple[Any, ...]] = []

    for line in lines:
        if check_trailing_newline and not line.endswith("\n"):
            # Partial trailing line at EOF - stop without consuming or counting as malformed
            break
        lines_read += 1
        p_row, s_rows, is_mal = parse_quota_sample_line(line)
        if is_mal:
            malformed_count += 1
            continue
        if p_row is None:
            continue

        ts = p_row[0]
        if newest_ts is not None and ts <= newest_ts:
            continue

        pool_batch.append(p_row)
        sample_batch.extend(s_rows)

        if len(pool_batch) >= batch_size:
            cur.executemany(
                "INSERT OR IGNORE INTO quota_pool (ts, healthy, canary_healthy, canary_serving, roster, current, fwh) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                pool_batch,
            )
            pool_rows_added += cur.rowcount
            pool_batch = []

        if len(sample_batch) >= batch_size:
            cur.executemany(
                "INSERT OR IGNORE INTO quota_samples (ts, account, s, u5h, u7d, u7d_fable, fw, r7d, r5h) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                sample_batch,
            )
            sample_rows_added += cur.rowcount
            sample_batch = []

    if pool_batch:
        cur.executemany(
            "INSERT OR IGNORE INTO quota_pool (ts, healthy, canary_healthy, canary_serving, roster, current, fwh) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            pool_batch,
        )
        pool_rows_added += cur.rowcount

    if sample_batch:
        cur.executemany(
            "INSERT OR IGNORE INTO quota_samples (ts, account, s, u5h, u7d, u7d_fable, fw, r7d, r5h) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            sample_batch,
        )
        sample_rows_added += cur.rowcount

    return pool_rows_added, sample_rows_added, malformed_count, lines_read


def step_quota_samples(
    conn: sqlite3.Connection,
    samples_path: str = DEFAULT_SAMPLES,
    samples_archive: str = DEFAULT_SAMPLES_ARCHIVE,
    batch_size: int = 50000,
    now: float | None = None,
    archive_min_age: float = 120.0,
) -> dict[str, int]:
    """Step 3: quota samples import from archives and live file."""
    state = get_ingest_state(conn)
    total_pool_rows = 0
    total_sample_rows = 0
    total_malformed = 0
    quota_archive_retry = 0
    current_time = time.time() if now is None else now

    # 1. Archives: import each archive not yet recorded in ingest_state
    if os.path.isdir(samples_archive):
        archive_files = sorted(Path(samples_archive).glob("*.jsonl.gz"))
        for archive_path in archive_files:
            basename = archive_path.name
            state_key = f"quota_archive:{basename}"
            if state_key in state:
                continue

            try:
                st = archive_path.stat()
            except OSError as e:
                quota_archive_retry += 1
                sys.stderr.write(f"warning: stat failed for archive {basename}: {e}\n")
                continue

            if st.st_size == 0:
                quota_archive_retry += 1
                sys.stderr.write(f"warning: skipping 0-byte archive {basename}\n")
                continue

            if current_time - st.st_mtime < archive_min_age:
                quota_archive_retry += 1
                continue

            try:
                with gzip.open(archive_path, "rt", encoding="utf-8", errors="replace") as f:
                    p_add, s_add, mal_cnt, lines_read = ingest_quota_lines(
                        lines=f,
                        conn=conn,
                        newest_ts=None,
                        batch_size=batch_size,
                        check_trailing_newline=False,
                    )

                if lines_read == 0:
                    conn.rollback()
                    quota_archive_retry += 1
                    sys.stderr.write(f"warning: archive {basename} yielded 0 lines\n")
                    continue

                # Record archive in ingest_state in the SAME transaction as its rows
                conn.execute(
                    "INSERT OR REPLACE INTO ingest_state (key, value) VALUES (?, ?)",
                    (state_key, "1"),
                )
                conn.commit()
                state[state_key] = "1"
                total_pool_rows += p_add
                total_sample_rows += s_add
                total_malformed += mal_cnt
            except (OSError, EOFError, zlib.error) as e:
                conn.rollback()
                quota_archive_retry += 1
                sys.stderr.write(f"warning: error reading archive {basename}: {e}\n")
                continue

    # 2. Live file: skipping lines whose ts <= newest quota_pool.ts
    if os.path.isfile(samples_path):
        row = conn.execute("SELECT max(ts) FROM quota_pool").fetchone()
        newest_ts = row[0] if (row and row[0] is not None) else None

        try:
            with open(samples_path, "r", encoding="utf-8", errors="replace") as f:
                p_add, s_add, mal_cnt, _ = ingest_quota_lines(
                    lines=f,
                    conn=conn,
                    newest_ts=newest_ts,
                    batch_size=batch_size,
                    check_trailing_newline=True,
                )
            conn.commit()
            total_pool_rows += p_add
            total_sample_rows += s_add
            total_malformed += mal_cnt
        except OSError as e:
            sys.stderr.write(f"warning: failed to read live quota samples from {samples_path}: {e}\n")

    return {
        "quota_rows": total_sample_rows,
        "quota_pool_rows": total_pool_rows,
        "quota_sample_rows": total_sample_rows,
        "quota_archive_retry": quota_archive_retry,
        "malformed": total_malformed,
    }


def run_ingest(
    db_path: str = DEFAULT_DB,
    events_path: str = DEFAULT_EVENTS,
    raw_dir: str | None = None,
    host: str | None = None,
    opencode_db: str | None = None,
    goose_db: str | None = None,
    tags_db: str | None = None,
    lgtm_ledger: str | None = None,
    samples_path: str = DEFAULT_SAMPLES,
    samples_archive: str = DEFAULT_SAMPLES_ARCHIVE,
    now: float | None = None,
) -> dict[str, Any]:
    """Execute run steps 1-3."""
    host = host or socket.gethostname()
    actual_raw_dir = raw_dir or os.path.join(os.path.dirname(os.path.abspath(db_path)), "raw")

    conn = open_ledger_db(db_path)
    try:
        counts = step_cfp_tail_and_archive(
            conn=conn,
            events_path=events_path,
            raw_dir=actual_raw_dir,
            host=host,
            opencode_db=opencode_db,
            goose_db=goose_db,
            tags_db=tags_db,
            lgtm_ledger=lgtm_ledger,
        )
        quota_counts = step_quota_samples(
            conn=conn,
            samples_path=samples_path,
            samples_archive=samples_archive,
            now=now,
        )
        counts["malformed"] = counts.get("malformed", 0) + quota_counts.get("malformed", 0)
        counts["quota_rows"] = quota_counts.get("quota_rows", 0)
        counts["quota_pool_rows"] = quota_counts.get("quota_pool_rows", 0)
        counts["quota_sample_rows"] = quota_counts.get("quota_sample_rows", 0)
        counts["quota_archive_retry"] = quota_counts.get("quota_archive_retry", 0)
        return counts
    finally:
        conn.close()


def import_events(
    db_path: str = DEFAULT_DB,
    files: list[str] | None = None,
    host: str | None = None,
    opencode_db: str | None = None,
    goose_db: str | None = None,
    tags_db: str | None = None,
    lgtm_ledger: str | None = None,
    batch_size: int = 50000,
) -> dict[str, Any]:
    """Import events from files (plain or .gz) without touching tail state or raw archive."""
    if not files:
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

    host = host or socket.gethostname()
    conn = open_ledger_db(db_path)
    try:
        tag_map: dict[str, str] = {}
        actual_tags_db = tags_db or oc_tags.DEFAULT_TAGS_DB
        if actual_tags_db and os.path.exists(actual_tags_db):
            try:
                store = oc_tags.open_store(actual_tags_db, readonly=True)
                try:
                    tag_map = oc_tags.session_tags(store)
                finally:
                    store.close()
            except Exception:
                tag_map = {}

        total_new_routes = 0
        total_new_requests = 0
        total_malformed = 0

        for filepath in files:
            if not os.path.exists(filepath):
                continue

            open_fn = gzip.open if filepath.endswith(".gz") else open
            with open_fn(filepath, "rb") as f:
                batch: list[bytes] = []
                while True:
                    line = f.readline()
                    if not line:
                        break
                    batch.append(line)
                    if len(batch) >= batch_size:
                        parsed = parse_raw_lines(batch)
                        r_n, req_n, mal_n, _ = process_batch(
                            conn=conn,
                            parsed_lines=parsed,
                            host=host,
                            opencode_db=opencode_db,
                            goose_db=goose_db,
                            tags_db=tags_db,
                            lgtm_ledger=lgtm_ledger,
                            tag_map=tag_map,
                        )
                        conn.commit()
                        total_new_routes += r_n
                        total_new_requests += req_n
                        total_malformed += mal_n
                        batch = []

                if batch:
                    parsed = parse_raw_lines(batch)
                    r_n, req_n, mal_n, _ = process_batch(
                        conn=conn,
                        parsed_lines=parsed,
                        host=host,
                        opencode_db=opencode_db,
                        goose_db=goose_db,
                        tags_db=tags_db,
                        lgtm_ledger=lgtm_ledger,
                        tag_map=tag_map,
                    )
                    conn.commit()
                    total_new_routes += r_n
                    total_new_requests += req_n
                    total_malformed += mal_n

        return {
            "new_routes": total_new_routes,
            "new_requests": total_new_requests,
            "malformed": total_malformed,
        }
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="llm-ledger")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # run subcommand
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--db", default=DEFAULT_DB)
    run_parser.add_argument("--events", default=DEFAULT_EVENTS)
    run_parser.add_argument("--raw-dir", default=None)
    run_parser.add_argument("--host", default=socket.gethostname())
    run_parser.add_argument("--opencode-db", default=oc_tags.DEFAULT_OPENCODE_DB)
    run_parser.add_argument("--goose-db", default=oc_tags.DEFAULT_GOOSE_DB)
    run_parser.add_argument("--tags-db", default=oc_tags.DEFAULT_TAGS_DB)
    run_parser.add_argument("--lgtm-ledger", default=oc_tags.DEFAULT_LGTM_LEDGER)
    run_parser.add_argument("--samples", default=DEFAULT_SAMPLES)
    run_parser.add_argument("--samples-archive", default=DEFAULT_SAMPLES_ARCHIVE)
    run_parser.add_argument("--goose-recheck-hours", type=int, default=72)

    # import-events subcommand
    import_parser = subparsers.add_parser("import-events")
    import_parser.add_argument("files", nargs="+")
    import_parser.add_argument("--db", default=DEFAULT_DB)
    import_parser.add_argument("--host", default=socket.gethostname())
    import_parser.add_argument("--opencode-db", default=oc_tags.DEFAULT_OPENCODE_DB)
    import_parser.add_argument("--goose-db", default=oc_tags.DEFAULT_GOOSE_DB)
    import_parser.add_argument("--tags-db", default=oc_tags.DEFAULT_TAGS_DB)
    import_parser.add_argument("--lgtm-ledger", default=oc_tags.DEFAULT_LGTM_LEDGER)
    import_parser.add_argument("--goose-recheck-hours", type=int, default=72)

    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    t0 = time.time()

    if args.command == "run":
        counts = run_ingest(
            db_path=args.db,
            events_path=args.events,
            raw_dir=args.raw_dir,
            host=args.host,
            opencode_db=args.opencode_db,
            goose_db=args.goose_db,
            tags_db=args.tags_db,
            lgtm_ledger=args.lgtm_ledger,
            samples_path=args.samples,
            samples_archive=args.samples_archive,
        )
    elif args.command == "import-events":
        counts = import_events(
            db_path=args.db,
            files=args.files,
            host=args.host,
            opencode_db=args.opencode_db,
            goose_db=args.goose_db,
            tags_db=args.tags_db,
            lgtm_ledger=args.lgtm_ledger,
        )
    else:
        return 1

    elapsed = time.time() - t0
    summary = (
        f"routes={counts.get('new_routes', 0)} "
        f"requests={counts.get('new_requests', 0)} "
        f"malformed={counts.get('malformed', 0)} "
        f"quota={counts.get('quota_rows', 0)} "
        f"rechecked={counts.get('rechecked', 0)} "
        f"hours={counts.get('hours_rebuilt', 0)} "
        f"snapshot={counts.get('snapshot_rows', 0)} "
        f"elapsed={elapsed:.2f}s"
    )
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
