#!/usr/bin/env python3
"""llm-ledger: maintains /var/lib/llm-ledger/ledger.db and raw archives."""

from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import gzip
import hashlib
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


ADVISORY_WARNING_SUBSTRINGS: tuple[str, ...] = ()


def is_advisory_warning(warning: str) -> bool:
    """Determine whether a warning is advisory (non-fatal) vs fatal.

    Fatal warnings cause exit code 1 so systemd's OnFailure alert fires.
    Advisory warnings are printed but keep exit 0.

    ADVISORY_WARNING_SUBSTRINGS is deliberately empty. On 2026-11-23 the live
    resolver inputs produced no warnings at all, and the obvious candidate
    ("lgtm goose ledger: N row(s) not counted") is exactly the signal of an
    lgtm schema change that would silently misattribute goose traffic for
    good once the 72 h recheck window passes. Add a substring here only for a
    condition known to be benign AND persistent, with the evidence beside it.
    """
    return any(s in warning for s in ADVISORY_WARNING_SUBSTRINGS)


def add_warning(warnings: list[str] | None, msg: str) -> None:
    """Add a warning to the list if not already present, or print to stderr if no list."""
    if warnings is not None:
        if msg not in warnings:
            warnings.append(msg)
    else:
        sys.stderr.write(f"warning: {msg}\n")


def load_session_tags(
    conn: sqlite3.Connection,
    tags_db: str | None,
    warnings: list[str] | None = None,
) -> tuple[dict[str, str], bool]:
    """Load session tags map from tags_db.

    Rule:
    - If tags_db does not exist AND session_program has no rows with source='manual',
      proceed with an empty tag map and no warning (fresh host).
    - If tags_db does not exist but manual rows exist (tags were there before and
      vanished), record a fatal warning and signal skip (return {}, False).
    - If tags_db exists but cannot be read, record a fatal warning and signal
      skip (return {}, False).

    Returns:
        (tag_map, ok) where ok=False means snapshot should be skipped.
    """
    actual_tags_db = tags_db or oc_tags.DEFAULT_TAGS_DB
    if not actual_tags_db or not os.path.exists(actual_tags_db):
        has_manual = False
        try:
            row = conn.execute("SELECT 1 FROM session_program WHERE source = 'manual' LIMIT 1").fetchone()
            has_manual = row is not None
        except sqlite3.OperationalError:
            has_manual = False

        if not has_manual:
            return {}, True

        add_warning(warnings, f"tags db not found: {actual_tags_db}")
        return {}, False

    try:
        with oc_tags.open_store(actual_tags_db, readonly=True) as store:
            tag_map = oc_tags.session_tags(store)
        return tag_map, True
    except Exception as e:
        add_warning(warnings, f"failed to read tags db {actual_tags_db}: {e}")
        return {}, False


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


class LedgerLock:
    """Exclusive fcntl flock on <db dir>/.lock."""

    def __init__(self, db_path: str, blocking: bool = True):
        self.lock_path = os.path.join(os.path.dirname(os.path.abspath(db_path)), ".lock")
        self.blocking = blocking
        self.fd: Any = None
        self.acquired = False

    def __enter__(self) -> LedgerLock:
        os.makedirs(os.path.dirname(self.lock_path), exist_ok=True)
        self.fd = open(self.lock_path, "a")
        if self.blocking:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX)
                self.acquired = True
                return self
            except Exception:
                self.fd.close()
                self.fd = None
                raise
        else:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.acquired = True
            except (BlockingIOError, OSError):
                self.fd.close()
                self.fd = None
                self.acquired = False
            return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        if self.fd is not None:
            if self.acquired:
                try:
                    fcntl.flock(self.fd, fcntl.LOCK_UN)
                except OSError:
                    pass
            self.fd.close()
            self.fd = None
            self.acquired = False


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
    warnings: list[str] | None = None,
) -> tuple[int, int, int, int, set[int]]:
    """Process pre-parsed lines, inserting routes and requests into conn.

    Returns:
        (new_routes, new_requests, malformed, max_ts, touched_hours)
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
            warnings=warnings,
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

    batch_touched_hours: set[int] = set()

    # Insert into requests
    new_requests = 0
    if requests_rows:
        existing_req_ids: set[str] = set()
        for i in range(0, len(requests_rows), 500):
            chunk = [r[0] for r in requests_rows[i : i + 500]]
            placeholders = ",".join("?" for _ in chunk)
            for row in conn.execute(
                f"SELECT request_id FROM requests WHERE request_id IN ({placeholders})",
                chunk,
            ):
                existing_req_ids.add(row[0])

        seen_req_ids = set(existing_req_ids)
        for r in requests_rows:
            req_id = r[0]
            if req_id not in seen_req_ids:
                seen_req_ids.add(req_id)
                batch_touched_hours.add((r[1] // 3_600_000) * 3_600_000)

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
                    warnings=warnings,
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
                for req_id, req_ts in needs_fill:
                    batch_touched_hours.add((req_ts // 3_600_000) * 3_600_000)

    return new_routes, new_requests, malformed, max_ts, batch_touched_hours


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
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    """Step 1 & 2: cfp tail ingest and raw gzip archive."""
    state = get_ingest_state(conn)
    stored_inode = int(state["cfp_inode"]) if "cfp_inode" in state else None
    stored_offset = int(state["cfp_offset"]) if "cfp_offset" in state else 0
    stored_archived_ts = (
        int(state["cfp_archived_through_ts"])
        if "cfp_archived_through_ts" in state
        else None
    )
    stored_head_sha = state.get("cfp_head_sha")
    stored_head_len = int(state["cfp_head_len"]) if "cfp_head_len" in state else None

    if not os.path.exists(events_path):
        add_warning(warnings, f"events file not found: {events_path}")
        return {"new_routes": 0, "new_requests": 0, "malformed": 0, "touched_hours": set()}

    try:
        f = open(events_path, "rb")
    except OSError as e:
        add_warning(warnings, f"failed to read events file {events_path}: {e}")
        return {"new_routes": 0, "new_requests": 0, "malformed": 0, "touched_hours": set()}

    with f:
        st = os.fstat(f.fileno())
        cur_inode = st.st_ino
        cur_size = st.st_size

        is_restart = False
        if stored_inode is not None:
            if cur_inode != stored_inode or cur_size < stored_offset:
                is_restart = True
            else:
                # Inode matches and cur_size >= stored_offset
                if stored_head_sha is not None and stored_head_len is not None:
                    f.seek(0)
                    head_data = f.read(stored_head_len)
                    if len(head_data) != stored_head_len or hashlib.sha256(head_data).hexdigest() != stored_head_sha:
                        is_restart = True
                if not is_restart and stored_offset > 0:
                    f.seek(stored_offset - 1)
                    if f.read(1) != b"\n":
                        is_restart = True

        read_offset = 0 if (is_restart or stored_inode is None) else stored_offset
        cutoff = (
            (stored_archived_ts - 600_000)
            if (is_restart and stored_archived_ts is not None)
            else None
        )

        if cur_size <= read_offset:
            return {"new_routes": 0, "new_requests": 0, "malformed": 0, "touched_hours": set()}

        f.seek(read_offset)

        # Load session tags
        tag_map, _tags_ok = load_session_tags(conn, tags_db, warnings)

        total_new_routes = 0
        total_new_requests = 0
        total_malformed = 0
        touched_hours: set[int] = set()
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
            routes_n, reqs_n, malformed_n, batch_max_ts, batch_hours = process_batch(
                conn=conn,
                parsed_lines=parsed,
                host=host,
                opencode_db=opencode_db,
                goose_db=goose_db,
                tags_db=tags_db,
                lgtm_ledger=lgtm_ledger,
                tag_map=tag_map,
                warnings=warnings,
            )

            total_new_routes += routes_n
            total_new_requests += reqs_n
            total_malformed += malformed_n
            touched_hours.update(batch_hours)
            if batch_max_ts > current_archived_through_ts:
                current_archived_through_ts = batch_max_ts

            batch_end_offset = current_offset + byte_len

            # Read head bytes from the same fd at commit time
            saved_pos = f.tell()
            f.seek(0)
            cur_head_bytes = f.read(4096)
            f.seek(saved_pos)
            cur_head_len = len(cur_head_bytes)
            cur_head_sha = hashlib.sha256(cur_head_bytes).hexdigest()

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
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_head_sha', ?)",
                (cur_head_sha,),
            )
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_head_len', ?)",
                (str(cur_head_len),),
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
        "touched_hours": touched_hours,
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


def step_goose_recheck(
    conn: sqlite3.Connection,
    opencode_db: str | None = None,
    goose_db: str | None = None,
    tags_db: str | None = None,
    lgtm_ledger: str | None = None,
    goose_recheck_hours: int = 72,
    now: float | None = None,
    warnings: list[str] | None = None,
) -> tuple[int, set[int]]:
    """Step 4: recheck goose-shaped requests within goose_recheck_hours window.

    Returns:
        (rechecked_count, touched_hours)
    """
    if now is None:
        now_ms = int(time.time() * 1000)
    elif now > 1e11:
        now_ms = int(now)
    else:
        now_ms = int(now * 1000)

    cutoff_ts = now_ms - goose_recheck_hours * 3600 * 1000

    rows = conn.execute(
        "SELECT request_id, ts, session_id, attr_key FROM requests "
        "WHERE ts >= ? AND session_id GLOB '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9]*'",
        (cutoff_ts,),
    ).fetchall()
    goose_rows = [r for r in rows if r[2] and oc_tags._GOOSE_SESSION_ID.match(r[2])]
    if not goose_rows:
        return 0, set()

    goose_sids = {r[2] for r in goose_rows}
    min_ts = min(r[1] for r in goose_rows)
    max_ts = max(r[1] for r in goose_rows)

    tag_map, _tags_ok = load_session_tags(conn, tags_db, warnings)

    resolver = oc_tags.CfpSessionResolver(
        session_ids=goose_sids,
        db_path=opencode_db or oc_tags.DEFAULT_OPENCODE_DB,
        goose_db=goose_db or oc_tags.DEFAULT_GOOSE_DB,
        session_tags=tag_map,
        lgtm_ledger=lgtm_ledger,
        since_ms=min_ts,
        until_ms=max_ts + 1,
        warnings=warnings,
    )

    to_update: list[tuple[str, str]] = []
    recheck_touched_hours: set[int] = set()

    for req_id, req_ts, sid, current_attr_key in goose_rows:
        new_attr = compute_attr_key(sid, req_ts, resolver)
        if new_attr != current_attr_key:
            to_update.append((new_attr, req_id))
            recheck_touched_hours.add((req_ts // 3_600_000) * 3_600_000)

    if to_update:
        conn.executemany(
            "UPDATE requests SET attr_key = ? WHERE request_id = ?",
            to_update,
        )
        conn.commit()

    return len(to_update), recheck_touched_hours


def coalesce_hour_ranges(hours: set[int]) -> list[tuple[int, int]]:
    """Merge sorted hour starts into contiguous [start_ms, end_ms) intervals."""
    if not hours:
        return []
    sorted_h = sorted(hours)
    ranges: list[tuple[int, int]] = []
    cur_start = sorted_h[0]
    cur_end = cur_start + 3_600_000
    for h in sorted_h[1:]:
        if h == cur_end:
            cur_end = h + 3_600_000
        else:
            ranges.append((cur_start, cur_end))
            cur_start = h
            cur_end = h + 3_600_000
    ranges.append((cur_start, cur_end))
    return ranges


def step_hourly_rollup(
    conn: sqlite3.Connection,
    touched_hours: set[int] | None = None,
) -> int:
    """Step 5: rebuild hourly rollup for touched hours (or all hours if fresh/None).

    Uses index-friendly range predicates (ts >= start_ms AND ts < end_ms) over
    requests_ts index to avoid full-table scans.

    Returns:
        number of hours rebuilt
    """
    hourly_empty = conn.execute("SELECT 1 FROM hourly LIMIT 1").fetchone() is None
    requests_exist = conn.execute("SELECT 1 FROM requests LIMIT 1").fetchone() is not None
    is_fresh = hourly_empty and requests_exist

    if is_fresh or touched_hours is None:
        conn.execute("DELETE FROM hourly")
        conn.execute("""
            INSERT INTO hourly (hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd)
            SELECT
              (ts / 3600000) * 3600000 AS hour,
              attr_key,
              COALESCE(backend, '') AS backend,
              COALESCE(model, '') AS model,
              COUNT(*) AS n,
              COALESCE(SUM(input), 0) AS input,
              COALESCE(SUM(output), 0) AS output,
              COALESCE(SUM(cache_read), 0) AS cache_read,
              COALESCE(SUM(cache_write), 0) AS cache_write,
              COALESCE(SUM(cost_usd), 0.0) AS cost_usd
            FROM requests
            GROUP BY (ts / 3600000) * 3600000, attr_key, COALESCE(backend, ''), COALESCE(model, '')
        """)
        conn.commit()
        count_row = conn.execute("SELECT count(DISTINCT hour) FROM hourly").fetchone()
        return count_row[0] if count_row else 0

    if not touched_hours:
        return 0

    # Coalesce contiguous hours into [start_ms, end_ms) ranges so the queries
    # use the requests_ts B-tree index (ts >= ? AND ts < ?) instead of table scans.
    ranges = coalesce_hour_ranges(touched_hours)
    for start_ms, end_ms in ranges:
        conn.execute("DELETE FROM hourly WHERE hour >= ? AND hour < ?", (start_ms, end_ms))
        conn.execute("""
            INSERT INTO hourly (hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd)
            SELECT
              (ts / 3600000) * 3600000 AS hour,
              attr_key,
              COALESCE(backend, '') AS backend,
              COALESCE(model, '') AS model,
              COUNT(*) AS n,
              COALESCE(SUM(input), 0) AS input,
              COALESCE(SUM(output), 0) AS output,
              COALESCE(SUM(cache_read), 0) AS cache_read,
              COALESCE(SUM(cache_write), 0) AS cache_write,
              COALESCE(SUM(cost_usd), 0.0) AS cost_usd
            FROM requests
            WHERE ts >= ? AND ts < ?
            GROUP BY (ts / 3600000) * 3600000, attr_key, COALESCE(backend, ''), COALESCE(model, '')
        """, (start_ms, end_ms))
    conn.commit()
    return len(touched_hours)


def step_session_program_snapshot(
    conn: sqlite3.Connection,
    opencode_db: str | None = None,
    goose_db: str | None = None,
    tags_db: str | None = None,
    now: float | None = None,
    warnings: list[str] | None = None,
) -> int:
    """Step 6: update session_program snapshot.

    Returns:
        number of snapshot rows written (upserted)
    """
    if now is None:
        now_ms = int(time.time() * 1000)
    elif now > 1e11:
        now_ms = int(now)
    else:
        now_ms = int(now * 1000)

    existing_sp: dict[str, tuple[str, str, str | None, str | None]] = {}
    for r in conn.execute("SELECT attr_key, tag, source, root, title FROM session_program"):
        existing_sp[r[0]] = (r[1], r[2], r[3], r[4])

    opencode_parents: dict[str, str | None] = {}
    opencode_dirs: dict[str, str | None] = {}
    opencode_titles: dict[str, str | None] = {}
    opencode_loaded = False
    actual_opencode_db = opencode_db or oc_tags.DEFAULT_OPENCODE_DB
    if actual_opencode_db and os.path.exists(actual_opencode_db):
        try:
            oc_conn = oc_tags.connect_ro(actual_opencode_db)
            try:
                for sid, parent_id, directory, title in oc_conn.execute(
                    "SELECT id, parent_id, directory, title FROM session"
                ):
                    opencode_parents[sid] = parent_id
                    opencode_dirs[sid] = directory
                    opencode_titles[sid] = title
                opencode_loaded = True
            finally:
                oc_conn.close()
        except Exception as e:
            add_warning(warnings, f"failed to read opencode db {actual_opencode_db}: {e}")

    goose_parents: dict[str, str | None] = {}
    goose_meta: dict[str, tuple[str | None, str | None, str | None, str | None]] = {}
    goose_loaded = False
    actual_goose_db = goose_db or oc_tags.DEFAULT_GOOSE_DB
    if actual_goose_db and os.path.exists(actual_goose_db):
        try:
            g_conn = oc_tags.connect_ro(actual_goose_db)
            try:
                for sid, parent_session_id, working_dir, name, session_type, rtitle in g_conn.execute(
                    "SELECT id, parent_session_id, working_dir, name, session_type, "
                    "CASE WHEN json_valid(recipe_json) THEN json_extract(recipe_json, '$.title') END FROM sessions"
                ):
                    goose_parents[sid] = parent_session_id
                    goose_meta[sid] = (working_dir, name, session_type, rtitle)
                goose_loaded = True
            finally:
                g_conn.close()
        except Exception as e:
            add_warning(warnings, f"failed to read goose db {actual_goose_db}: {e}")

    tag_map, tags_ok = load_session_tags(conn, tags_db, warnings)
    if not tags_ok:
        return 0

    attr_keys = [r[0] for r in conn.execute("SELECT DISTINCT attr_key FROM requests")]
    to_upsert: list[tuple[str, str, str, str | None, str | None, int]] = []

    for attr_key in attr_keys:
        resolved: tuple[str, str, str | None, str | None] | None = None
        if attr_key.startswith("ses_"):
            if not opencode_loaded:
                continue
            if attr_key not in opencode_parents:
                if attr_key in existing_sp:
                    cur_tag, cur_source, cur_root, cur_title = existing_sp[attr_key]
                    target_tag = (tag_map.get(cur_root) if cur_root else None) or tag_map.get(attr_key)
                    if target_tag is not None and target_tag != cur_tag:
                        resolved = (target_tag, "manual", cur_root, cur_title)
                    else:
                        continue
                else:
                    root = attr_key
                    tag, source = oc_tags.effective_tag(attr_key, None, tag_map)
                    title = None
                    resolved = (tag, source, root, title)
            else:
                root = oc_tags.root_of(attr_key, opencode_parents)
                tag, source = oc_tags.effective_tag(root, opencode_dirs.get(root), tag_map)
                title = opencode_titles.get(root)
                resolved = (tag, source, root, title)
        elif attr_key.startswith("goose:"):
            if not goose_loaded:
                continue
            sid = attr_key[len("goose:"):]
            if sid not in goose_meta:
                continue
            root_sid = oc_tags.root_of(sid, goose_parents)
            wdir, name, stype, rtitle = goose_meta.get(root_sid, (None, None, None, None))
            root = f"goose:{root_sid}"
            if root in tag_map:
                tag = tag_map[root]
                source = "manual"
            else:
                tag = oc_tags.goose_auto_key(recipe_title=rtitle, name=name, session_type=stype)
                source = "auto"
            title = rtitle or name or stype or None
            resolved = (tag, source, root, title)
        elif attr_key.startswith("lgtm-goose:"):
            tag = tag_map.get(attr_key) or oc_tags.LGTM_LEDGER_TAG
            source = "manual"
            root = attr_key
            title = None
            resolved = (tag, source, root, title)
        elif attr_key.startswith("cfp:"):
            tag = attr_key
            source = "manual"
            root = attr_key
            title = None
            resolved = (tag, source, root, title)

        if resolved is None:
            continue

        tag, source, root, title = resolved
        if attr_key in existing_sp:
            cur_tag, cur_source, cur_root, cur_title = existing_sp[attr_key]
            if (cur_tag, cur_source, cur_root, cur_title) == (tag, source, root, title):
                continue

        to_upsert.append((attr_key, tag, source, root, title, now_ms))

    if to_upsert:
        conn.executemany(
            "INSERT OR REPLACE INTO session_program (attr_key, tag, source, root, title, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            to_upsert,
        )
        conn.commit()

    return len(to_upsert)


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
    goose_recheck_hours: int = 72,
    now: float | None = None,
    take_lock: bool = True,
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    """Execute run steps 1-6 under lock."""
    warnings_list = warnings if warnings is not None else []
    lock_ctx: Any = LedgerLock(db_path, blocking=False) if take_lock else contextlib.nullcontext()
    with lock_ctx as lock:
        if take_lock and not lock.acquired:
            print(f"llm-ledger: lock {lock.lock_path} is held; exiting")
            return {"locked": True, "warnings": warnings_list}

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
                warnings=warnings_list,
            )
            touched_hours: set[int] = counts.pop("touched_hours", set())

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

            rechecked_count, recheck_hours = step_goose_recheck(
                conn=conn,
                opencode_db=opencode_db,
                goose_db=goose_db,
                tags_db=tags_db,
                lgtm_ledger=lgtm_ledger,
                goose_recheck_hours=goose_recheck_hours,
                now=now,
                warnings=warnings_list,
            )
            counts["rechecked"] = rechecked_count
            touched_hours.update(recheck_hours)

            hours_rebuilt = step_hourly_rollup(conn=conn, touched_hours=touched_hours)
            counts["hours_rebuilt"] = hours_rebuilt

            snapshot_rows = step_session_program_snapshot(
                conn=conn,
                opencode_db=opencode_db,
                goose_db=goose_db,
                tags_db=tags_db,
                now=now,
                warnings=warnings_list,
            )
            counts["snapshot_rows"] = snapshot_rows
            counts["warnings"] = warnings_list

            return counts
        finally:
            conn.close()


def rebuild_hourly(
    db_path: str = DEFAULT_DB,
    take_lock: bool = True,
) -> dict[str, Any]:
    """Rebuild all hourly rollup rows under blocking lock."""
    lock_ctx: Any = LedgerLock(db_path, blocking=True) if take_lock else contextlib.nullcontext()
    with lock_ctx:
        conn = open_ledger_db(db_path)
        try:
            hours_rebuilt = step_hourly_rollup(conn, touched_hours=None)
            return {
                "new_routes": 0,
                "new_requests": 0,
                "malformed": 0,
                "quota_rows": 0,
                "rechecked": 0,
                "hours_rebuilt": hours_rebuilt,
                "snapshot_rows": 0,
            }
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
    take_lock: bool = True,
    now: float | None = None,
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    """Import events from files (plain or .gz) without touching tail state or raw archive."""
    warnings_list = warnings if warnings is not None else []
    if not files:
        return {
            "new_routes": 0,
            "new_requests": 0,
            "malformed": 0,
            "quota_rows": 0,
            "rechecked": 0,
            "hours_rebuilt": 0,
            "snapshot_rows": 0,
            "warnings": warnings_list,
        }

    lock_ctx: Any = LedgerLock(db_path, blocking=True) if take_lock else contextlib.nullcontext()
    with lock_ctx:
        host = host or socket.gethostname()
        conn = open_ledger_db(db_path)
        try:
            tag_map, tags_ok = load_session_tags(conn, tags_db, warnings_list)

            total_new_routes = 0
            total_new_requests = 0
            total_malformed = 0
            touched_hours: set[int] = set()

            for filepath in files:
                if not os.path.exists(filepath):
                    add_warning(warnings_list, f"events file not found: {filepath}")
                    continue

                open_fn = gzip.open if filepath.endswith(".gz") else open
                try:
                    f = open_fn(filepath, "rb")
                except (OSError, gzip.BadGzipFile) as e:
                    add_warning(warnings_list, f"failed to read events file {filepath}: {e}")
                    continue

                with f:
                    batch: list[bytes] = []
                    while True:
                        try:
                            line = f.readline()
                        except (EOFError, zlib.error, gzip.BadGzipFile) as e:
                            add_warning(warnings_list, f"truncated gzip file {filepath}: {e}")
                            break
                        if not line:
                            break
                        batch.append(line)
                        if len(batch) >= batch_size:
                            parsed = parse_raw_lines(batch)
                            r_n, req_n, mal_n, _, b_hours = process_batch(
                                conn=conn,
                                parsed_lines=parsed,
                                host=host,
                                opencode_db=opencode_db,
                                goose_db=goose_db,
                                tags_db=tags_db,
                                lgtm_ledger=lgtm_ledger,
                                tag_map=tag_map,
                                warnings=warnings_list,
                            )
                            conn.commit()
                            total_new_routes += r_n
                            total_new_requests += req_n
                            total_malformed += mal_n
                            touched_hours.update(b_hours)
                            batch = []

                    if batch:
                        parsed = parse_raw_lines(batch)
                        r_n, req_n, mal_n, _, b_hours = process_batch(
                            conn=conn,
                            parsed_lines=parsed,
                            host=host,
                            opencode_db=opencode_db,
                            goose_db=goose_db,
                            tags_db=tags_db,
                            lgtm_ledger=lgtm_ledger,
                            tag_map=tag_map,
                            warnings=warnings_list,
                        )
                        conn.commit()
                        total_new_routes += r_n
                        total_new_requests += req_n
                        total_malformed += mal_n
                        touched_hours.update(b_hours)

            # Step 5: rollup for touched hours
            hours_rebuilt = step_hourly_rollup(conn=conn, touched_hours=touched_hours)

            # Step 6: snapshot
            snapshot_rows = 0
            if tags_ok:
                snapshot_rows = step_session_program_snapshot(
                    conn=conn,
                    opencode_db=opencode_db,
                    goose_db=goose_db,
                    tags_db=tags_db,
                    now=now,
                    warnings=warnings_list,
                )

            return {
                "new_routes": total_new_routes,
                "new_requests": total_new_requests,
                "malformed": total_malformed,
                "quota_rows": 0,
                "rechecked": 0,
                "hours_rebuilt": hours_rebuilt,
                "snapshot_rows": snapshot_rows,
                "warnings": warnings_list,
            }
        finally:
            conn.close()


def parse_et_datetime(val: str | None, end_of_day_for_date: bool = False) -> int:
    """Parse ISO date or datetime string, interpreting naive datetimes in America/New_York."""
    import quota_watch
    return quota_watch.parse_et_datetime(val, end_of_day_for_date=end_of_day_for_date)


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

    # rebuild-hourly subcommand
    rebuild_parser = subparsers.add_parser("rebuild-hourly")
    rebuild_parser.add_argument("--db", default=DEFAULT_DB)

    # quota-watch subcommand
    qw_parser = subparsers.add_parser("quota-watch")
    qw_parser.add_argument("--db", default=DEFAULT_DB)
    qw_parser.add_argument("--state-dir", default="/var/lib/llm-quota-watch")
    qw_parser.add_argument("--alert-cmd", default=None)
    qw_parser.add_argument("--exclude-account", action="append", default=None)

    # quota-replay subcommand
    qr_parser = subparsers.add_parser("quota-replay")
    qr_parser.add_argument("--db", default=DEFAULT_DB)
    qr_parser.add_argument("--since", required=True)
    qr_parser.add_argument("--until", default="now")
    qr_parser.add_argument("--exclude-account", action="append", default=None)

    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    if args.command == "quota-watch":
        import quota_watch
        excluded = set(args.exclude_account or [])
        return quota_watch.run_live(
            db=args.db,
            state_dir=args.state_dir,
            alert_cmd=args.alert_cmd,
            excluded=excluded,
        )

    if args.command == "quota-replay":
        import quota_watch
        since_ms = quota_watch.parse_et_datetime(args.since, end_of_day_for_date=False)
        until_ms = quota_watch.parse_et_datetime(args.until, end_of_day_for_date=True)
        excluded = set(args.exclude_account or [])
        events = quota_watch.replay(
            db=args.db,
            since_ms=since_ms,
            until_ms=until_ms,
            excluded=excluded,
        )
        for e in events:
            print(e)
        import collections
        counts = collections.Counter(e.kind for e in events)
        summary_parts = [f"{k}={counts[k]}" for k in sorted(counts)]
        print(f"events: {' '.join(summary_parts) if summary_parts else 'none'} total={len(events)}")
        return 0

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
            goose_recheck_hours=args.goose_recheck_hours,
        )
        if counts.get("locked"):
            return 0
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
    elif args.command == "rebuild-hourly":
        counts = rebuild_hourly(db_path=args.db)
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

    warnings: list[str] = counts.get("warnings", [])
    seen: set[str] = set()
    deduped_warnings: list[str] = []
    for w in warnings:
        if w not in seen:
            seen.add(w)
            deduped_warnings.append(w)

    for w in deduped_warnings:
        sys.stderr.write(f"warning: {w}\n")

    has_fatal = any(not is_advisory_warning(w) for w in deduped_warnings)
    return 1 if has_fatal else 0


if __name__ == "__main__":
    sys.exit(main())
