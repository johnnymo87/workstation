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


def process_batch(
    conn: sqlite3.Connection,
    lines: Sequence[str | bytes],
    host: str,
    opencode_db: str | None,
    goose_db: str | None,
    tags_db: str | None,
    lgtm_ledger: str | None,
    tag_map: dict[str, str],
    recent_routes: dict[str, tuple[str | None, str | None]],
) -> tuple[int, int, int, int]:
    """Process a batch of lines, inserting routes and requests into conn.

    Returns:
        (new_routes, new_requests, malformed, max_ts)
    """
    batch_routes: list[tuple[str, int, str | None, str | None, str | None, str | None]] = []
    batch_usages: list[dict[str, Any]] = []
    malformed = 0
    max_ts = 0

    for raw in lines:
        if isinstance(raw, bytes):
            try:
                line_str = raw.decode("utf-8")
            except UnicodeDecodeError:
                malformed += 1
                continue
        else:
            line_str = raw

        line_str = line_str.strip()
        if not line_str:
            continue

        try:
            obj = json.loads(line_str)
        except Exception:
            malformed += 1
            continue

        if not isinstance(obj, dict):
            malformed += 1
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

        ts = to_int(obj.get("ts"))
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
            recent_routes[req_id] = (sid, model)
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

    # Associate routes with usages
    missing_route_ids = []
    for u in batch_usages:
        rid = u["req_id"]
        if rid in recent_routes:
            u["sid"], u["model"] = recent_routes[rid]
        else:
            missing_route_ids.append(rid)

    if missing_route_ids:
        # Check DB route table in chunks of 500
        for i in range(0, len(missing_route_ids), 500):
            chunk = missing_route_ids[i:i + 500]
            placeholders = ",".join("?" for _ in chunk)
            for row in conn.execute(
                f"SELECT request_id, session_id, model FROM route WHERE request_id IN ({placeholders})",
                chunk,
            ):
                recent_routes[row[0]] = (row[1], row[2])

        for u in batch_usages:
            if "sid" not in u:
                if u["req_id"] in recent_routes:
                    u["sid"], u["model"] = recent_routes[u["req_id"]]
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

    # Insert into route
    new_routes = 0
    if batch_routes:
        cur = conn.cursor()
        cur.executemany(
            "INSERT OR IGNORE INTO route (request_id, ts, session_id, model, desired, chosen) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            batch_routes,
        )
        new_routes = cur.rowcount

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

    # Check if any route fills in an existing request with session_id IS NULL
    if batch_routes:
        null_rows = conn.execute(
            "SELECT request_id, ts FROM requests WHERE session_id IS NULL"
        ).fetchall()
        if null_rows:
            null_dict = {r[0]: r[1] for r in null_rows}
            updates = []
            for r in batch_routes:
                rid = r[0]
                if rid in null_dict:
                    req_ts = null_dict[rid]
                    sid = r[2]
                    model = r[3]
                    if sid is not None and oc_tags._GOOSE_SESSION_ID.match(sid):
                        if resolver and sid in goose_sids:
                            attr_k = compute_attr_key(sid, req_ts, resolver)
                        else:
                            single_res = oc_tags.CfpSessionResolver(
                                session_ids=[sid],
                                db_path=opencode_db or oc_tags.DEFAULT_OPENCODE_DB,
                                goose_db=goose_db or oc_tags.DEFAULT_GOOSE_DB,
                                session_tags=tag_map,
                                lgtm_ledger=lgtm_ledger,
                                since_ms=req_ts - 1000,
                                until_ms=req_ts + 1000,
                            )
                            attr_k = compute_attr_key(sid, req_ts, single_res)
                    else:
                        attr_k = compute_attr_key(sid, req_ts, None)
                    updates.append((sid, model, attr_k, rid))

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

    if not os.path.exists(events_path):
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

    st = os.stat(events_path)
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

    if cur_size == read_offset:
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

    with open(events_path, "rb") as f:
        f.seek(read_offset)
        data = f.read()

    last_nl = data.rfind(b"\n")
    if last_nl == -1:
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

    consumed_data = data[:last_nl + 1]
    raw_lines = consumed_data.splitlines(keepends=True)
    if not raw_lines:
        return {"new_routes": 0, "new_requests": 0, "malformed": 0}

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

    recent_routes: dict[str, tuple[str | None, str | None]] = {}
    current_offset = read_offset

    for i in range(0, len(raw_lines), batch_size):
        batch = raw_lines[i : i + batch_size]
        batch_len = sum(len(l) for l in batch)
        batch_end_offset = current_offset + batch_len

        # Step 2: raw archive BEFORE DB commit
        if is_restart:
            # Re-archive only lines with ts > cutoff.
            # Lines without numeric ts are NOT archived on restart.
            to_archive = []
            for bline in batch:
                try:
                    obj = json.loads(bline)
                    ts = to_int(obj.get("ts"))
                    if ts is not None and (cutoff is None or ts > cutoff):
                        to_archive.append(bline)
                except Exception:
                    pass
            archive_bytes = b"".join(to_archive)
        else:
            # Non-restart: archive all lines (including boot/keepwarm)
            archive_bytes = b"".join(batch)

        if archive_bytes:
            os.makedirs(raw_dir, exist_ok=True)
            utc_date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
            archive_file = os.path.join(raw_dir, f"cfp-events-{utc_date}.jsonl.gz")
            with open(archive_file, "ab") as af:
                af.write(gzip.compress(archive_bytes))

        # Step 1: parse and insert into DB
        routes_n, reqs_n, malformed_n, batch_max_ts = process_batch(
            conn=conn,
            lines=batch,
            host=host,
            opencode_db=opencode_db,
            goose_db=goose_db,
            tags_db=tags_db,
            lgtm_ledger=lgtm_ledger,
            tag_map=tag_map,
            recent_routes=recent_routes,
        )

        total_new_routes += routes_n
        total_new_requests += reqs_n
        total_malformed += malformed_n
        if batch_max_ts > current_archived_through_ts:
            current_archived_through_ts = batch_max_ts

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

    return {
        "new_routes": total_new_routes,
        "new_requests": total_new_requests,
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
) -> dict[str, Any]:
    """Execute run steps 1-2."""
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
        recent_routes: dict[str, tuple[str | None, str | None]] = {}

        for filepath in files:
            if not os.path.exists(filepath):
                continue

            open_fn = gzip.open if filepath.endswith(".gz") else open
            with open_fn(filepath, "rt", encoding="utf-8", errors="replace") as f:
                batch: list[str] = []
                for line in f:
                    batch.append(line)
                    if len(batch) >= batch_size:
                        r_n, req_n, mal_n, _ = process_batch(
                            conn=conn,
                            lines=batch,
                            host=host,
                            opencode_db=opencode_db,
                            goose_db=goose_db,
                            tags_db=tags_db,
                            lgtm_ledger=lgtm_ledger,
                            tag_map=tag_map,
                            recent_routes=recent_routes,
                        )
                        conn.commit()
                        total_new_routes += r_n
                        total_new_requests += req_n
                        total_malformed += mal_n
                        batch = []

                if batch:
                    r_n, req_n, mal_n, _ = process_batch(
                        conn=conn,
                        lines=batch,
                        host=host,
                        opencode_db=opencode_db,
                        goose_db=goose_db,
                        tags_db=tags_db,
                        lgtm_ledger=lgtm_ledger,
                        tag_map=tag_map,
                        recent_routes=recent_routes,
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
