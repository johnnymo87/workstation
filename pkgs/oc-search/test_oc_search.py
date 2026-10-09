#!/usr/bin/env python3
"""Tests for oc-search. Run: python3 pkgs/oc-search/test_oc_search.py

Wired into CI as the `oc-search` flake check (see flake.nix), which invokes
this file directly.

The load-bearing claim under test is EQUIVALENCE: for every query shape, the
indexed path and the scanning path must produce the same rows that a plain
`instr()` over the same fixture produces. That is the whole safety argument
for putting an index in front of a substring search, so it is tested
exhaustively (`test_index_matches_scan_for_every_substring`) rather than
spot-checked.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import random
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import oc_search  # noqa: E402


BASE_MS = 1_780_000_000_000


def make_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE session (
          id text PRIMARY KEY,
          title text NOT NULL,
          directory text NOT NULL,
          time_updated integer NOT NULL
        );
        CREATE TABLE part (
          id text PRIMARY KEY,
          message_id text NOT NULL,
          session_id text NOT NULL,
          time_created integer NOT NULL,
          time_updated integer NOT NULL,
          data text NOT NULL
        );
        CREATE INDEX part_session_idx ON part(session_id);
        CREATE INDEX part_message_id_id_idx ON part(message_id, id);
        """
    )
    return conn


def add_session(conn, sid, *, title="a title", directory="/tmp/proj"):
    conn.execute(
        "INSERT INTO session (id, title, directory, time_updated) VALUES (?,?,?,?)",
        (sid, title, directory, BASE_MS),
    )


_SEQ = [0]


def add_part(conn, sid, *, type="tool", text="", t=None, time_updated=None):
    _SEQ[0] += 1
    n = _SEQ[0]
    data = json.dumps({"type": type, "text": text, "id": f"prt_{n}"})
    tc = BASE_MS + (t if t is not None else n)
    tu = BASE_MS if time_updated is None else time_updated
    conn.execute(
        "INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)"
        " VALUES (?,?,?,?,?,?)",
        (f"prt_{n}", f"msg_{n}", sid, tc, tu, data),
    )
    return f"prt_{n}"


def update_part(
    conn: sqlite3.Connection,
    rowid: int,
    *,
    text: str | None = None,
    type: str | None = None,
    bump: int = 1_000,
) -> None:
    row = conn.execute(
        "SELECT id, time_created, time_updated, data FROM part WHERE rowid=?", (rowid,)
    ).fetchone()
    if row is None:
        raise ValueError(f"part rowid {rowid} not found")
    _pid, _tc, tu, raw_data = row[0], row[1], row[2], row[3]
    d = json.loads(raw_data)
    if text is not None:
        d["text"] = text
    if type is not None:
        d["type"] = type
    new_data = json.dumps(d)
    new_tu = tu + bump
    conn.execute(
        "UPDATE part SET data=?, time_updated=? WHERE rowid=?",
        (new_data, new_tu, rowid),
    )


def delete_part(conn: sqlite3.Connection, rowid: int) -> None:
    conn.execute("DELETE FROM part WHERE rowid=?", (rowid,))


class Fixture:
    """A temp opencode.db plus a temp sidecar index path."""

    def __init__(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "opencode.db")
        self.index = os.path.join(self.dir.name, "cache", "index.db")
        self.conn = make_db(self.db)

    def commit(self):
        self.conn.commit()

    def close(self):
        self.conn.close()
        self.dir.cleanup()

    def build_index(self, **kw):
        src = oc_search.open_source(self.db)
        try:
            return oc_search.build_index(
                src,
                self.index,
                self.db,
                rebuild=kw.get("rebuild", False),
                batch=kw.get("batch", 1_000_000),
                progress=False,
            )
        finally:
            src.close()

    def search(self, *argv) -> tuple[int, str, str]:
        """Run oc-search against this fixture. Last argument is the query.

        The query goes after `--` so that a needle beginning with a dash is
        still a needle -- the same escape hatch the shipped CLI gives humans.
        """
        flags = list(argv[:-1])
        query = argv[-1]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = oc_search.run(
                flags
                + ["--db", self.db, "--index-path", self.index, "--timeout", "0", "--", query]
            )
        return rc, out.getvalue(), err.getvalue()

    def sessions(self, *argv) -> list[dict]:
        rc, out, _ = self.search("--json", *argv)
        assert rc == 0, rc
        return json.loads(out)


class BatchCapTest(unittest.TestCase):
    def test_default_batch_is_unlimited(self):
        args = oc_search.parse_args(["hello"])
        self.assertIsNone(args.index_batch)

    def test_explicit_batch_must_be_positive_int(self):
        args = oc_search.parse_args(["--index-batch", "42", "hello"])
        self.assertEqual(args.index_batch, 42)

        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args(["--index-batch", "0", "hello"])

        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args(["--index-batch", "-5", "hello"])

    def test_unlimited_batch_completes_in_one_run(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(15):
                add_part(f.conn, "ses_1", text=f"text_{i}")
            f.commit()
            saved = oc_search.READ_CHUNK
            oc_search.READ_CHUNK = 2
            try:
                # With batch=None (default unlimited), all 15 rows are indexed
                res = f.build_index(batch=None)
                self.assertEqual(res["indexed"], 15)
                self.assertTrue(res["up_to_date"])
            finally:
                oc_search.READ_CHUNK = saved
        finally:
            f.close()


class DiskPrecheckTest(unittest.TestCase):
    def test_estimate_rebuild_without_existing_index(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(10):
                add_part(f.conn, "ses_1", text=f"item_{i}")
            f.commit()

            # 10 rows * 7200 bytes * 1.2 = 86400
            need = oc_search.estimate_disk_need(
                f.conn, f.index, rebuild=True, watermark=0, src_max=10
            )
            self.assertEqual(need, int(10 * oc_search.INDEX_BYTES_PER_ROW * 1.2))
        finally:
            f.close()

    def test_estimate_rebuild_with_small_existing_index_uses_constant(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(10):
                add_part(f.conn, "ses_1", text=f"item_{i}")
            f.commit()
            f.build_index()

            # Existing index has 10 rows (< 10_000), so constant 7200 is used
            need = oc_search.estimate_disk_need(
                f.conn, f.index, rebuild=True, watermark=0, src_max=10
            )
            self.assertEqual(need, int(10 * oc_search.INDEX_BYTES_PER_ROW * 1.2))
        finally:
            f.close()

    def test_estimate_rebuild_with_large_existing_index_uses_measured_ratio(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(50):
                add_part(f.conn, "ses_1", text=f"item_{i}")
            f.commit()

            # Create mock index with >= 10,000 rows in part_meta
            os.makedirs(os.path.dirname(f.index), exist_ok=True)
            conn = oc_search.open_index_rw(f.index)
            # Insert 10,000 dummy rows into part_meta
            metas = [(i, f"p_{i}", "s_1", 1000, 1000, "tool") for i in range(1, 10001)]
            conn.executemany(
                "INSERT INTO part_meta (rowid_, part_id, session_id, time_created, time_updated, type) "
                "VALUES (?,?,?,?,?,?)",
                metas,
            )
            conn.commit()
            conn.close()

            file_size = os.path.getsize(f.index)
            expected_bytes_per_row = file_size / 10_000
            expected_need = int(50 * expected_bytes_per_row * 1.2)

            need = oc_search.estimate_disk_need(
                f.conn, f.index, rebuild=True, watermark=0, src_max=50
            )
            self.assertEqual(need, expected_need)
        finally:
            f.close()

    def test_estimate_catchup_uses_pending_rows(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(25):
                add_part(f.conn, "ses_1", text=f"item_{i}")
            f.commit()

            # Catch up from watermark 5 to src_max 25 with batch 10 -> 10 rows
            need = oc_search.estimate_disk_need(
                f.conn, f.index, rebuild=False, watermark=5, src_max=25, batch=10
            )
            self.assertEqual(need, int(10 * oc_search.INDEX_BYTES_PER_ROW * 1.2))

            # Catch up from watermark 5 to src_max 25 with batch None -> 20 rows
            need_unlimited = oc_search.estimate_disk_need(
                f.conn, f.index, rebuild=False, watermark=5, src_max=25, batch=None
            )
            self.assertEqual(need_unlimited, int(20 * oc_search.INDEX_BYTES_PER_ROW * 1.2))
        finally:
            f.close()

    def test_disk_precheck_refusal_and_replacement_credit(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            for i in range(10):
                add_part(f.conn, "ses_1", text=f"item_{i}")
            f.commit()

            need = oc_search.estimate_disk_need(f.conn, f.index, rebuild=True, src_max=10)

            # Case 1: Rebuild where need > free + current_index_size -> refuse
            real_usage = oc_search.shutil.disk_usage
            from collections import namedtuple
            Usage = namedtuple("Usage", ["total", "used", "free"])

            # Mock free space to be 1000 bytes (far less than need ~86400)
            oc_search.shutil.disk_usage = lambda d: Usage(10**12, 10**12 - 1000, 1000)
            try:
                with self.assertRaises(SystemExit) as ctx:
                    oc_search.check_disk_precheck(f.conn, f.index, rebuild=True, src_max=10)
                self.assertIn("refusing to index", str(ctx.exception))
            finally:
                oc_search.shutil.disk_usage = real_usage

            # Case 2: Rebuild where free < need, BUT free + current_index_size >= need -> succeeds!
            # Create a file of size 100_000 at f.index
            os.makedirs(os.path.dirname(f.index), exist_ok=True)
            with open(f.index, "wb") as idx_file:
                idx_file.write(b"x" * 100_000)

            # Free is only 1,000, but with current_index_size 100,000, available is 101,000 > need (86400)
            oc_search.shutil.disk_usage = lambda d: Usage(10**12, 10**12 - 1000, 1000)
            try:
                # Should not raise SystemExit
                checked_need = oc_search.check_disk_precheck(
                    f.conn, f.index, rebuild=True, src_max=10
                )
                self.assertEqual(checked_need, need)
            finally:
                oc_search.shutil.disk_usage = real_usage
        finally:
            f.close()


class IndexLockTest(unittest.TestCase):
    def test_held_lock_prints_message_and_exits_zero(self):
        import fcntl
        f = Fixture()
        try:
            lock_path = f.index + ".lock"
            os.makedirs(os.path.dirname(lock_path), exist_ok=True)
            with open(lock_path, "w") as lock_file:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    rc = oc_search.run(["--index", "--db", f.db, "--index-path", f.index])
                self.assertEqual(rc, 0)
                self.assertIn("already in progress", out.getvalue())
        finally:
            f.close()


class BuildModeTest(unittest.TestCase):
    def test_build_returns_mode(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            add_part(f.conn, "ses_1", text="item 1")
            f.commit()

            # Fresh build is a rebuild
            res1 = f.build_index()
            self.assertEqual(res1["mode"], "rebuild")
            self.assertEqual(res1["indexed"], 1)

            # Nothing to do is noop
            res2 = f.build_index()
            self.assertEqual(res2["mode"], "noop")
            self.assertEqual(res2["indexed"], 0)

            # New part added is catchup
            add_part(f.conn, "ses_1", text="item 2")
            f.commit()
            res3 = f.build_index()
            self.assertEqual(res3["mode"], "catchup")
            self.assertEqual(res3["indexed"], 1)

            # Explicit rebuild is rebuild
            res4 = f.build_index(rebuild=True)
            self.assertEqual(res4["mode"], "rebuild")
            self.assertEqual(res4["indexed"], 2)
        finally:
            f.close()


class V1MigrationTest(unittest.TestCase):
    def test_v1_index_recreated_as_v2_exactly_once(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            add_part(f.conn, "ses_1", type="tool", text="hello world", t=10)
            f.commit()

            # Create a v1-shaped index manually
            os.makedirs(os.path.dirname(f.index), exist_ok=True)
            v1_conn = sqlite3.connect(f.index)
            v1_conn.executescript(
                """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                CREATE VIRTUAL TABLE ft USING fts5(data, tokenize="trigram case_sensitive 1", content='');
                CREATE TABLE part_meta (
                  rowid_ INTEGER PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  time_created INTEGER NOT NULL,
                  type TEXT
                );
                """
            )
            v1_conn.execute("INSERT INTO meta (key, value) VALUES ('schema_version', '1')")
            v1_conn.execute(
                "INSERT INTO meta (key, value) VALUES ('source_db', ?)",
                (os.path.realpath(f.db),),
            )
            v1_conn.execute("INSERT INTO meta (key, value) VALUES ('watermark_rowid', '0')")
            v1_conn.commit()
            v1_conn.close()

            # Run build_index
            res1 = f.build_index()
            self.assertEqual(res1.get("mode"), "rebuild")

            # Check that index is now v2
            idx = oc_search.open_index_ro(f.index)
            self.assertIsNotNone(idx)
            try:
                self.assertEqual(oc_search.get_meta(idx, "schema_version"), "2")
                cols = {r[1] for r in idx.execute("PRAGMA table_info(part_meta)").fetchall()}
                self.assertIn("part_id", cols)
                self.assertIn("time_updated", cols)
                tmax_exists = idx.execute(
                    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='tmax'"
                ).fetchone()[0]
                self.assertEqual(tmax_exists, 1)
                sql = idx.execute(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='ft'"
                ).fetchone()[0]
                self.assertIn("contentless_delete=1", sql)
            finally:
                idx.close()

            # Second build does NOT rebuild again
            res2 = f.build_index()
            self.assertEqual(res2.get("mode"), "noop")
            self.assertEqual(res2["indexed"], 0)
            self.assertTrue(res2["up_to_date"])
        finally:
            f.close()


class SchemaV2Test(unittest.TestCase):
    def test_index_schema_version_is_two(self):
        self.assertEqual(oc_search.INDEX_SCHEMA_VERSION, 2)
        self.assertEqual(oc_search.TMAX_SHIFT, 14)

    def test_v2_schema_tables_and_columns(self):
        with tempfile.TemporaryDirectory() as td:
            idx_path = os.path.join(td, "index.db")
            conn = oc_search.open_index_rw(idx_path)
            try:
                # ft sql has contentless_delete=1
                sql = conn.execute(
                    "SELECT sql FROM sqlite_master WHERE type='table' AND name='ft'"
                ).fetchone()[0]
                self.assertIn("contentless_delete=1", sql)

                # part_meta columns
                cols = {
                    r[1] for r in conn.execute("PRAGMA table_info(part_meta)").fetchall()
                }
                self.assertEqual(
                    cols,
                    {"rowid_", "part_id", "session_id", "time_created", "time_updated", "type"},
                )

                # tmax table
                tmax_cols = {
                    r[1] for r in conn.execute("PRAGMA table_info(tmax)").fetchall()
                }
                self.assertEqual(tmax_cols, {"bucket", "max_tc"})
            finally:
                conn.close()

    def test_build_populates_part_meta_and_tmax(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            pid1 = add_part(f.conn, "ses_1", type="tool", text="one", t=100, time_updated=BASE_MS + 150)
            pid2 = add_part(f.conn, "ses_1", type="text", text="two", t=200, time_updated=BASE_MS + 250)
            f.commit()
            f.build_index()

            idx = oc_search.open_index_ro(f.index)
            self.assertIsNotNone(idx)
            try:
                pm_rows = idx.execute(
                    "SELECT rowid_, part_id, session_id, time_created, time_updated, type "
                    "FROM part_meta ORDER BY rowid_"
                ).fetchall()
                self.assertEqual(len(pm_rows), 2)
                self.assertEqual(pm_rows[0]["part_id"], pid1)
                self.assertEqual(pm_rows[0]["time_created"], BASE_MS + 100)
                self.assertEqual(pm_rows[0]["time_updated"], BASE_MS + 150)
                self.assertEqual(pm_rows[1]["part_id"], pid2)
                self.assertEqual(pm_rows[1]["time_created"], BASE_MS + 200)
                self.assertEqual(pm_rows[1]["time_updated"], BASE_MS + 250)

                # Check tmax
                tmax_rows = idx.execute("SELECT bucket, max_tc FROM tmax").fetchall()
                self.assertTrue(len(tmax_rows) >= 1)
                for tr in tmax_rows:
                    self.assertEqual(tr["max_tc"], BASE_MS + 200)
            finally:
                idx.close()
        finally:
            f.close()

    def test_tmax_never_lowered(self):
        with tempfile.TemporaryDirectory() as td:
            idx_path = os.path.join(td, "index.db")
            conn = oc_search.open_index_rw(idx_path)
            try:
                # Row in bucket 0 with time_created 500
                r1 = {
                    "rowid": 1,
                    "id": "prt_1",
                    "session_id": "ses_1",
                    "time_created": 500,
                    "time_updated": 500,
                    "type": "tool",
                    "data": json.dumps({"text": "hi"}),
                }
                oc_search.write_rows(conn, [r1])
                val = conn.execute("SELECT max_tc FROM tmax WHERE bucket=0").fetchone()[0]
                self.assertEqual(val, 500)

                # Row in bucket 0 with LOWER time_created 300
                r2 = {
                    "rowid": 2,
                    "id": "prt_2",
                    "session_id": "ses_1",
                    "time_created": 300,
                    "time_updated": 300,
                    "type": "tool",
                    "data": json.dumps({"text": "lo"}),
                }
                oc_search.write_rows(conn, [r2])
                val2 = conn.execute("SELECT max_tc FROM tmax WHERE bucket=0").fetchone()[0]
                self.assertEqual(val2, 500, "tmax must never be lowered")

                # Row in bucket 0 with HIGHER time_created 800
                r3 = {
                    "rowid": 3,
                    "id": "prt_3",
                    "session_id": "ses_1",
                    "time_created": 800,
                    "time_updated": 800,
                    "type": "tool",
                    "data": json.dumps({"text": "up"}),
                }
                oc_search.write_rows(conn, [r3])
                val3 = conn.execute("SELECT max_tc FROM tmax WHERE bucket=0").fetchone()[0]
                self.assertEqual(val3, 800)
            finally:
                conn.close()

    def test_behaviour_replace_leaves_no_ghost_posting(self):
        """Index a row, mutate source row's data at same rowid, rewrite via
        write_rows, and assert the OLD text no longer matches via FTS."""
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            pid = add_part(f.conn, "ses_1", type="tool", text="AlphaOldTextUnique")
            f.commit()
            f.build_index()

            # Verify original matches
            idx = oc_search.open_index_rw(f.index)
            try:
                cnt_old = idx.execute(
                    "SELECT count(*) FROM ft WHERE ft MATCH '\"AlphaOldTextUnique\"'"
                ).fetchone()[0]
                self.assertEqual(cnt_old, 1)

                # Mutate source row
                rid = f.conn.execute("SELECT rowid FROM part WHERE id=?", (pid,)).fetchone()[0]
                update_part(f.conn, rid, text="BetaNewTextUnique")
                f.commit()

                # Re-read row and write through write_rows
                updated = f.conn.execute(
                    "SELECT rowid, id, session_id, time_created, time_updated, "
                    "json_extract(data,'$.type') AS type, data FROM part WHERE rowid=?",
                    (rid,),
                ).fetchall()
                oc_search.write_rows(idx, updated)
                idx.commit()

                # Assert NEW text matches and OLD text does not match
                cnt_new = idx.execute(
                    "SELECT count(*) FROM ft WHERE ft MATCH '\"BetaNewTextUnique\"'"
                ).fetchone()[0]
                self.assertEqual(cnt_new, 1)
                cnt_old_after = idx.execute(
                    "SELECT count(*) FROM ft WHERE ft MATCH '\"AlphaOldTextUnique\"'"
                ).fetchone()[0]
                self.assertEqual(cnt_old_after, 0, "old text must not leave ghost postings")
            finally:
                idx.close()
        finally:
            f.close()

    def test_source_grep_no_plain_insert_into_ft(self):
        """Assert oc_search.py contains no INSERT INTO ft that is not INSERT OR REPLACE,
        and no INSERT INTO ft(ft."""
        source_path = Path(oc_search.__file__).resolve()
        content = source_path.read_text(encoding="utf-8")

        import re
        # Find all occurrences of INSERT INTO ft (ignoring leading 'OR REPLACE' if any)
        pattern = re.compile(r"INSERT\s+(?:OR\s+\w+\s+)?INTO\s+ft\b", re.IGNORECASE)
        matches = [m.group(0) for m in pattern.finditer(content)]
        self.assertTrue(len(matches) > 0, "must find at least one ft write in oc_search.py")
        for m in matches:
            normalized = " ".join(m.upper().split())
            self.assertEqual(
                normalized,
                "INSERT OR REPLACE INTO FT",
                f"Forbidden ft insert form: {m!r} in {source_path}",
            )

        # Control command form INSERT INTO ft(ft is also forbidden
        control_pattern = re.compile(r"INSERT\s+INTO\s+ft\s*\(\s*ft\b", re.IGNORECASE)
        self.assertFalse(
            control_pattern.search(content),
            "FTS control-command INSERT INTO ft(ft is forbidden",
        )


class FixtureHelpersTest(unittest.TestCase):
    def test_make_db_has_production_indexes(self):
        f = Fixture()
        try:
            indexes = {
                r[0]
                for r in f.conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='index'"
                ).fetchall()
            }
            self.assertIn("part_session_idx", indexes)
            self.assertIn("part_message_id_id_idx", indexes)
        finally:
            f.close()

    def test_add_part_supports_time_updated(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            pid = add_part(f.conn, "ses_1", time_updated=BASE_MS + 9999)
            row = f.conn.execute(
                "SELECT time_created, time_updated FROM part WHERE id=?", (pid,)
            ).fetchone()
            self.assertEqual(row[1], BASE_MS + 9999)
        finally:
            f.close()

    def test_update_part_helper(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            pid = add_part(f.conn, "ses_1", type="tool", text="original")
            row = f.conn.execute(
                "SELECT rowid, time_created, time_updated, data FROM part WHERE id=?", (pid,)
            ).fetchone()
            rid, tc, tu, data = row[0], row[1], row[2], json.loads(row[3])
            self.assertEqual(data["text"], "original")
            self.assertEqual(data["type"], "tool")

            update_part(f.conn, rid, text="updated text", type="text", bump=5000)
            updated_row = f.conn.execute(
                "SELECT time_created, time_updated, data FROM part WHERE id=?", (pid,)
            ).fetchone()
            up_tc, up_tu, up_data = updated_row[0], updated_row[1], json.loads(updated_row[2])
            self.assertEqual(up_tc, tc, "time_created must not change")
            self.assertEqual(up_tu, tu + 5000, "time_updated must bump")
            self.assertEqual(up_data["text"], "updated text")
            self.assertEqual(up_data["type"], "text")
            self.assertEqual(up_data["id"], pid, "part id must be preserved")
        finally:
            f.close()

    def test_delete_part_helper(self):
        f = Fixture()
        try:
            add_session(f.conn, "ses_1")
            pid = add_part(f.conn, "ses_1", text="to delete")
            rid = f.conn.execute("SELECT rowid FROM part WHERE id=?", (pid,)).fetchone()[0]
            delete_part(f.conn, rid)
            count = f.conn.execute("SELECT count(*) FROM part WHERE rowid=?", (rid,)).fetchone()[0]
            self.assertEqual(count, 0)
        finally:
            f.close()


class ParseArgsTest(unittest.TestCase):
    """The old bash CLI's contract. lgtm and humans both depend on it."""

    def test_defaults_to_tool_parts(self):
        args = oc_search.parse_args(["hello"])
        self.assertEqual(args.query, "hello")
        self.assertEqual(oc_search.resolve_types(args), ["tool"])

    def test_types_space_separated(self):
        args = oc_search.parse_args(["--types", "tool,text", "mono"])
        self.assertEqual(oc_search.resolve_types(args), ["tool", "text"])
        self.assertEqual(args.query, "mono")

    def test_types_equals_form(self):
        args = oc_search.parse_args(["--types=tool,text", "mono"])
        self.assertEqual(oc_search.resolve_types(args), ["tool", "text"])

    def test_all_beats_types(self):
        args = oc_search.parse_args(["--all", "--types", "tool", "q"])
        self.assertIsNone(oc_search.resolve_types(args))

    def test_double_dash_protects_a_dash_leading_query(self):
        args = oc_search.parse_args(["--", "--weird-query"])
        self.assertEqual(args.query, "--weird-query")

    def test_missing_query_is_an_error(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args([])

    def test_two_queries_are_an_error(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                oc_search.parse_args(["one", "two"])


class FtsPhraseTest(unittest.TestCase):
    def test_quotes_are_doubled(self):
        self.assertEqual(oc_search.fts_phrase('a"b'), '"a""b"')

    def test_plain(self):
        self.assertEqual(oc_search.fts_phrase("gh pr create"), '"gh pr create"')


class SearchBehaviourTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a", title="alpha", directory="/tmp/a")
        add_session(self.f.conn, "ses_b", title="beta", directory="/tmp/b")
        add_part(self.f.conn, "ses_a", type="tool", text="gh pr create --fill", t=10)
        add_part(self.f.conn, "ses_a", type="tool", text="gh pr create again", t=20)
        add_part(self.f.conn, "ses_a", type="text", text="talking about kubectl", t=30)
        add_part(self.f.conn, "ses_b", type="text", text="gh pr create in text", t=40)
        add_part(self.f.conn, "ses_b", type="reasoning", text="thinking kubectl", t=50)
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_default_scope_is_tool_only(self):
        rows = self.f.sessions("gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_a"])
        self.assertEqual(rows[0]["matches"], 2)

    def test_types_widens_scope(self):
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_all_includes_reasoning(self):
        rows = self.f.sessions("--all", "kubectl")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})
        rows = self.f.sessions("--types", "text", "kubectl")
        self.assertEqual({r["id"] for r in rows}, {"ses_a"})

    def test_sorted_by_most_recent_match(self):
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_b", "ses_a"])

    def test_no_match_exits_zero_and_says_so(self):
        # lgtm keys off empty stdout; an exit code change here would turn a
        # miss into a logged failure.
        rc, out, err = self.f.search("nothing-here-at-all")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertIn("no sessions matched", err)

    def test_table_columns(self):
        rc, out, _ = self.f.search("gh pr create")
        self.assertEqual(rc, 0)
        header = out.splitlines()[0].split()
        self.assertEqual(header, ["id", "title", "directory", "last_match", "matches"])
        self.assertIn("ses_a", out)

    def test_limit(self):
        rows = self.f.sessions("--types", "tool,text", "--limit", "1", "gh pr create")
        self.assertEqual(len(rows), 1)

    def test_session_deleted_but_parts_left_behind_is_dropped(self):
        self.f.conn.execute("DELETE FROM session WHERE id='ses_b'")
        self.f.commit()
        rows = self.f.sessions("--types", "tool,text", "gh pr create")
        self.assertEqual([r["id"] for r in rows], ["ses_a"])

    def test_scan_warns_loudly_when_there_is_no_index(self):
        _, _, err = self.f.search("gh pr create")
        self.assertIn("no usable index", err)
        self.assertIn("--index", err)


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        add_session(self.f.conn, "ses_b")
        add_part(self.f.conn, "ses_a", type="tool", text="FbmEmployeeCutoffRepublish")
        add_part(self.f.conn, "ses_a", type="text", text="unrelated chatter")
        add_part(self.f.conn, "ses_b", type="tool", text="also FbmEmployeeCutoffRepublish")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_build_then_query_uses_index_and_says_nothing(self):
        res = self.f.build_index()
        self.assertEqual(res["indexed"], 3)
        self.assertTrue(res["up_to_date"])
        rc, out, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertEqual(rc, 0)
        self.assertNotIn("no usable index", err)
        self.assertIn("ses_a", out)
        self.assertIn("ses_b", out)

    def test_index_is_incremental(self):
        self.f.build_index()
        add_part(self.f.conn, "ses_a", type="tool", text="brand new FbmEmployeeCutoffRepublish")
        self.f.commit()
        res = self.f.build_index()
        self.assertEqual(res["indexed"], 1)

    def test_stale_index_still_returns_the_tail(self):
        """The correctness guarantee: a stale index costs time, never truth."""
        self.f.build_index()
        add_part(self.f.conn, "ses_b", type="tool", text="late FbmEmployeeCutoffRepublish")
        add_part(self.f.conn, "ses_b", type="tool", text="later FbmEmployeeCutoffRepublish")
        self.f.commit()
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        by_id = {r["id"]: r["matches"] for r in rows}
        self.assertEqual(by_id, {"ses_a": 1, "ses_b": 3})

    def test_interrupted_build_leaves_a_usable_smaller_index(self):
        """A partial index must be usable, not poisonous.

        The build commits its watermark alongside the rows it describes, so a
        killed build degrades to "indexed less", which the tail scan covers.
        Simulated here by the batch limit, which is the same code path.
        """
        self.f.build_index(rebuild=True, batch=1)
        src = oc_search.open_source(self.f.db)
        idx = oc_search.open_index_ro(self.f.index)
        usable, watermark, reason = oc_search.index_validity(src, idx, self.f.db)
        idx.close()
        src.close()
        self.assertTrue(usable, reason)
        self.assertGreater(watermark, 0)
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_index_batch_bounds_the_work(self):
        res = self.f.build_index(rebuild=True, batch=2)
        self.assertEqual(res["indexed"], 2)
        self.assertFalse(res["up_to_date"])
        # ...and the un-indexed remainder is still found.
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        self.assertEqual({r["id"] for r in rows}, {"ses_a", "ses_b"})

    def test_index_for_another_db_is_rejected_loudly(self):
        self.f.build_index()
        src = oc_search.open_source(self.f.db)
        idx = oc_search.open_index_rw(self.f.index)
        oc_search.set_meta(idx, "source_db", "/somewhere/else/opencode.db")
        idx.commit()
        idx.close()
        src.close()
        rc, out, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertEqual(rc, 0)
        self.assertIn("different opencode.db", err)
        self.assertIn("ses_a", out)  # still correct, via the fallback scan

    def test_watermark_row_replaced_invalidates_the_index(self):
        """Guards the one way rowid reuse could hide a match.

        SQLite only recycles a rowid at the top of the table, so a deletion
        that could shadow indexed content necessarily changes the watermark
        row. Rewriting it here stands in for "the newest sessions were deleted
        and new parts took their rowids".
        """
        self.f.build_index()
        self.f.conn.execute(
            "UPDATE part SET id='prt_impostor' WHERE rowid=(SELECT MAX(rowid) FROM part)"
        )
        self.f.commit()
        _, _, err = self.f.search("FbmEmployeeCutoffRepublish")
        self.assertIn("must be rebuilt", err)

    def test_short_query_falls_back_and_says_why(self):
        self.f.build_index()
        _, _, err = self.f.search("Fb")
        self.assertIn("trigram index", err)

    def test_no_index_flag_forces_a_scan(self):
        self.f.build_index()
        _, out, err = self.f.search("--no-index", "FbmEmployeeCutoffRepublish")
        self.assertIn("no usable index", err)
        self.assertIn("ses_a", out)


class EquivalenceTest(unittest.TestCase):
    """Indexed results == scanned results == raw instr(), for every substring.

    Trigram FTS5 is only a legitimate substitute for `instr` if it is exact in
    both directions. This walks every substring of length >= 3 of a corpus
    chosen to include the awkward shapes: repeated trigrams, overlapping
    matches, punctuation, unicode, JSON metacharacters and quotes.
    """

    CORPUS = [
        "FbmEmployeeCutoffRepublishService",
        "aaaa aaab aaaa",
        "gh pr create --fill --base main",
        "kubectl -n prod exec -it pod/foo -- bash",
        'a "quoted" thing with \\ backslash',
        "DATA-4297 and DATA-42970",
        "rules_oci // bazel:target",
        "unicode: naïve — 日本語 test",
        "mono mono mono",
        "abcabcabc",
    ]

    @classmethod
    def setUpClass(cls):
        cls.f = Fixture()
        for i, text in enumerate(cls.CORPUS):
            sid = f"ses_{i}"
            add_session(cls.f.conn, sid)
            add_part(cls.f.conn, sid, type="tool", text=text)
        cls.f.commit()
        cls.f.build_index()

    @classmethod
    def tearDownClass(cls):
        cls.f.close()

    def truth(self, needle: str) -> set[str]:
        conn = sqlite3.connect(self.f.db)
        try:
            rows = conn.execute(
                "SELECT DISTINCT session_id FROM part WHERE instr(data, ?) > 0", (needle,)
            ).fetchall()
        finally:
            conn.close()
        return {r[0] for r in rows}

    def test_index_matches_scan_for_every_substring(self):
        checked = 0
        for text in self.CORPUS:
            for start in range(len(text)):
                for length in range(oc_search.MIN_TRIGRAM_LEN, len(text) - start + 1):
                    needle = text[start : start + length]
                    if "\x00" in needle:
                        continue
                    expected = self.truth(needle)
                    indexed = {r["id"] for r in self.f.sessions(needle)}
                    scanned = {r["id"] for r in self.f.sessions("--no-index", needle)}
                    self.assertEqual(
                        indexed, expected, f"indexed path disagrees on {needle!r}"
                    )
                    self.assertEqual(
                        scanned, expected, f"scan path disagrees on {needle!r}"
                    )
                    checked += 1
        self.assertGreater(checked, 1000)

    def test_case_sensitivity_matches_instr(self):
        # instr() is byte-exact; the index is built `case_sensitive 1` so it
        # must be too. A case-folding index would silently over-report.
        self.assertEqual(self.truth("fbmemployee"), set())
        self.assertEqual({r["id"] for r in self.f.sessions("fbmemployee")}, set())
        self.assertEqual({r["id"] for r in self.f.sessions("FbmEmployee")}, {"ses_0"})


class ParallelScanTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        for i in range(200):
            add_part(self.f.conn, "ses_a", type="tool", text=f"needle-{i % 7} filler")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_split_ranges_cover_every_row_exactly_once(self):
        for jobs in (1, 2, 3, 8, 64):
            rows = self.f.sessions("--no-index", "--jobs", str(jobs), "needle-3")
            self.assertEqual(len(rows), 1, jobs)
            self.assertEqual(rows[0]["matches"], 200 // 7 + (1 if 200 % 7 > 3 else 0), jobs)

    def test_parallel_and_serial_agree(self):
        serial = self.f.sessions("--no-index", "--jobs", "1", "needle-")
        parallel = self.f.sessions("--no-index", "--jobs", "16", "needle-")
        self.assertEqual(serial, parallel)


class DeadlineTest(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        for i in range(400):
            add_part(self.f.conn, "ses_a", type="tool", text="x" * 200)
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_expired_deadline_reports_instead_of_dying_silently(self):
        """The lgtm failure mode, inverted.

        Tonight's log line was `Command failed: oc-search ...` with an empty
        stderr, because the only thing that ended the run was the caller's
        SIGTERM. A tripped deadline must instead exit non-zero WITH an
        explanation on stderr, which is what lands in the caller's log.
        """
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = oc_search.run(
                [
                    "x",
                    "--db",
                    self.f.db,
                    "--index-path",
                    self.f.index,
                    "--timeout",
                    "0.000001",
                    "--jobs",
                    "1",
                ]
            )
        self.assertEqual(rc, 2)
        self.assertIn("aborted after", err.getvalue())
        self.assertIn("--index", err.getvalue())

    def test_zero_timeout_means_no_deadline(self):
        d = oc_search.Deadline(0)
        self.assertIsNone(d.deadline)
        self.assertFalse(d.expired())


class IndexInfoTest(unittest.TestCase):
    def test_reports_missing_index(self):
        f = Fixture()
        add_session(f.conn, "ses_a")
        add_part(f.conn, "ses_a")
        f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(["--index-info", "--db", f.db, "--index-path", f.index])
        self.assertEqual(rc, 0)
        self.assertFalse(json.loads(out.getvalue())["exists"])
        f.close()

    def test_reports_unindexed_tail(self):
        f = Fixture()
        add_session(f.conn, "ses_a")
        add_part(f.conn, "ses_a")
        f.commit()
        f.build_index()
        add_part(f.conn, "ses_a")
        f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            oc_search.run(["--index-info", "--db", f.db, "--index-path", f.index])
        info = json.loads(out.getvalue())
        self.assertTrue(info["usable"])
        self.assertGreaterEqual(info["unindexed_rows_estimate"], 1)
        f.close()


class IfExistsTest(unittest.TestCase):
    """The timer must never create an 11 GB index nobody asked for."""

    def setUp(self):
        self.f = Fixture()
        add_session(self.f.conn, "ses_a")
        add_part(self.f.conn, "ses_a", type="tool", text="FbmEmployeeCutoffRepublish")
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def test_refuses_to_create_one(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(
                ["--index", "--if-exists", "--db", self.f.db, "--index-path", self.f.index]
            )
        self.assertEqual(rc, 0)
        self.assertIn("nothing to refresh", out.getvalue())
        self.assertFalse(os.path.exists(self.f.index))

    def test_refreshes_an_existing_one(self):
        self.f.build_index()
        add_part(self.f.conn, "ses_a", type="tool", text="more FbmEmployeeCutoffRepublish")
        self.f.commit()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = oc_search.run(
                ["--index", "--if-exists", "--db", self.f.db, "--index-path", self.f.index]
            )
        self.assertEqual(rc, 0)
        self.assertIn("indexed 1 rows", out.getvalue())


class Fts5CapabilityTest(unittest.TestCase):
    def test_this_sqlite_can_do_trigram_fts(self):
        """If this ever fails, the index is not buildable on this platform.

        Asserted rather than assumed because every exactness claim in this
        package depends on it, and macOS/nix python builds are not all alike.
        """
        ok, why = oc_search.fts5_trigram_available()
        self.assertTrue(ok, why)

    def test_fails_loudly_when_contentless_delete_fails(self):
        """Simulate an SQLite where contentless_delete=1 is ignored or unsupported."""
        real_connect = sqlite3.connect

        class FakeConn:
            def __init__(self, *a, **kw):
                self._c = real_connect(":memory:")

            def execute(self, sql, *args):
                # Strip contentless_delete=1 to simulate older SQLite
                if "contentless_delete=1" in sql:
                    raise sqlite3.OperationalError("unknown option: contentless_delete")
                return self._c.execute(sql, *args)

            def close(self):
                self._c.close()

        oc_search.sqlite3.connect = FakeConn
        try:
            ok, why = oc_search.fts5_trigram_available()
            self.assertFalse(ok)
            self.assertIn("contentless_delete", why)
        finally:
            oc_search.sqlite3.connect = real_connect


class MissingDatabaseTest(unittest.TestCase):
    def test_reports_and_exits_one(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = oc_search.run(["q", "--db", "/nonexistent/opencode.db"])
        self.assertEqual(rc, 1)
        self.assertIn("database not found", err.getvalue())


class _ProbeCursor:
    """Cursor wrapper that asks "could a checkpoint run right now?" after each
    bulk fetch. fetchone() is deliberately NOT probed: the small metadata
    queries complete on their own and say nothing about the scan loop."""

    def __init__(self, cur, owner):
        self._cur = cur
        self._owner = owner

    def __getattr__(self, name):
        return getattr(self._cur, name)

    def fetchall(self):
        rows = self._cur.fetchall()
        self._owner.probe()
        return rows

    def fetchmany(self, size=None):
        rows = self._cur.fetchmany() if size is None else self._cur.fetchmany(size)
        self._owner.probe()
        return rows


class _CheckpointProbe:
    """Wraps the SOURCE connection handed to build_index.

    Counts how many times the part-scan query is issued (one statement per
    chunk is the property under test) and, after each bulk fetch, tries a real
    wal_checkpoint(TRUNCATE) from a separate connection. A checkpoint cannot
    pass a held WAL read mark, so `busy` is a direct measurement of whether the
    source read transaction is still open.
    """

    # NB this also matches the AVG(len) disk-estimate sample, which uses the
    # same WHERE. So the counts are one higher than the number of chunks: 8 for
    # 12 rows at READ_CHUNK=2, and 2 (not 1) for a single long-lived cursor.
    SCAN_SQL_FRAGMENT = "FROM part WHERE rowid > ?"

    def __init__(self, conn, db_path):
        self._conn = conn
        self._db = db_path
        self.scan_statements = 0
        self.busy_results = []

    def __getattr__(self, name):
        return getattr(self._conn, name)

    def execute(self, sql, *args, **kw):
        if self.SCAN_SQL_FRAGMENT in sql:
            self.scan_statements += 1
        return _ProbeCursor(self._conn.execute(sql, *args, **kw), self)

    def probe(self):
        other = sqlite3.connect(self._db, timeout=0.25)
        try:
            busy, _, _ = other.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            self.busy_results.append(busy)
        finally:
            other.close()


class SourceReadTransactionTest(unittest.TestCase):
    """bead workstation-o5s1.3 -- the source WAL read mark must be released
    between chunks.

    THE INCIDENT (2026-09-15, epic workstation-o5s1): the scan was one
    `src.execute(... LIMIT batch)` drained with fetchmany() inside the loop that
    also did the index writes. An un-exhausted SQLite statement keeps its read
    transaction open, so the read mark on opencode.db was pinned for the whole
    batch -- 217-246s per run normally, and 87 minutes on the night the index
    writes were starved of I/O by concurrent bazel builds. No checkpoint can
    advance past a held read mark, so the WAL grew ~9 MB/min past 1 GB.

    WHY THIS ASSERTS THE STATEMENT COUNT AND NOT ONLY THE CHECKPOINT. A revert
    to the single long cursor would not reliably fail a checkpoint-only
    assertion on a small fixture: fetchmany() returning fewer rows than asked
    exhausts the statement, which releases the mark, so the probe would come
    back clean for the wrong reason and the test would pass vacuously. The
    number of scan statements is the structural fact -- one per chunk, or one
    for the whole batch -- and it cannot be faked by fixture size.
    """

    def setUp(self):
        self.f = Fixture()
        # A read mark only exists in WAL mode; the default fixture is rollback.
        # ASSERTED, not assumed: in rollback mode wal_checkpoint returns 0 for
        # everything, so the checkpoint test below would pass vacuously and say
        # nothing at all about read marks.
        mode = self.f.conn.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        self.assertEqual(mode, "wal", "fixture is not in WAL mode")
        add_session(self.f.conn, "ses_a")
        for i in range(12):
            add_part(
                self.f.conn, "ses_a", type="tool",
                text=f"chunk{i} FbmEmployeeCutoffRepublish",
            )
        self.f.commit()

    def tearDown(self):
        self.f.close()

    def _run_probed(self, read_chunk):
        probe = _CheckpointProbe(oc_search.open_source(self.f.db), self.f.db)
        saved = oc_search.READ_CHUNK
        oc_search.READ_CHUNK = read_chunk
        try:
            res = oc_search.build_index(
                probe, self.f.index, self.f.db,
                rebuild=True, batch=1_000_000, progress=False,
            )
        finally:
            oc_search.READ_CHUNK = saved
            probe.close()
        return probe, res

    def test_one_scan_statement_per_chunk(self):
        probe, res = self._run_probed(read_chunk=2)
        self.assertEqual(res["indexed"], 12)
        # 12 rows / 2 per chunk = 6 statements, plus one returning empty to end
        # the loop, plus the AVG(len) sample = 8. A single long-lived cursor
        # issues 2 (the scan and that same sample).
        self.assertGreaterEqual(
            probe.scan_statements, 6,
            f"scan issued {probe.scan_statements} statement(s) for 12 rows at "
            "READ_CHUNK=2 -- the loop is holding one cursor across the batch "
            "again, which pins the source WAL read mark",
        )

    def test_a_checkpoint_can_run_between_chunks(self):
        probe, _ = self._run_probed(read_chunk=2)
        self.assertGreaterEqual(
            len(probe.busy_results), 6, "probe never fired; the loop did not chunk"
        )
        self.assertEqual(
            [b for b in probe.busy_results if b != 0], [],
            "wal_checkpoint(TRUNCATE) reported busy between chunks -- the source "
            "read transaction is still open, so the WAL cannot be reclaimed",
        )

    def test_the_rows_still_come_out_right(self):
        """Chunking gives up snapshot isolation; it must not give up rows."""
        self._run_probed(read_chunk=2)
        rows = self.f.sessions("FbmEmployeeCutoffRepublish")
        self.assertEqual({r["id"]: r["matches"] for r in rows}, {"ses_a": 12})

    def test_rowid_reuse_between_chunks_forces_a_rebuild(self):
        """The hazard chunking introduces, and the reason it is checked rather
        than argued away.

        `part` has a TEXT primary key, so its rowid is implicit and SQLite
        reuses rowids below the maximum after deletes. On cloudbox max(rowid)
        exceeds count(*) by ~466,000 and session deletes cascade routinely, so
        this is a live condition, not a thought experiment.

        The index normally sits at the head of the table, so a chunk boundary IS
        the live max rowid. Delete the head rows between two chunk statements and
        let new parts reuse those rowids, and chunk k has already indexed the OLD
        contents of rows that now belong to somebody else while chunk k+1 reads
        only past the boundary. index_validity() cannot see it: it checks the
        FINAL watermark row, which is past the damage and perfectly consistent.

        The old single-snapshot scan was immune, so this is a regression this
        change had to pay for. The interleaving is injected through the probe, at
        the one instant it matters -- between a chunk's fetch and the next.
        """
        # 12 rows at READ_CHUNK=2 = 6 chunks. Fire after the LAST of them, so
        # the victim rows are already in the index when they are recycled. An
        # earlier version of this test fired at chunk 3, before those rows had
        # been read at all -- the next chunk then simply picked up the new
        # contents, no damage occurred, and the test passed with or without the
        # boundary check. A regression test that cannot fail is worse than none,
        # because it certifies the thing it never examined.
        victim_rowids = [
            r[0] for r in self.f.conn.execute(
                "SELECT rowid FROM part ORDER BY rowid DESC LIMIT 4"
            ).fetchall()
        ]

        state = {"fired": False, "calls": 0}
        outer = self

        class ReuseProbe(_CheckpointProbe):
            def probe(self):
                state["calls"] += 1
                if state["fired"] or state["calls"] < 6:
                    return
                state["fired"] = True
                c = outer.f.conn
                # Recycle the rowids the scan has just finished indexing...
                for rid in victim_rowids:
                    c.execute("DELETE FROM part WHERE rowid=?", (rid,))
                for rid in victim_rowids:
                    c.execute(
                        "INSERT INTO part (rowid, id, message_id, session_id, "
                        "time_created, time_updated, data) VALUES (?,?,?,?,?,?,?)",
                        (rid, f"prt_reused_{rid}", f"msg_reused_{rid}", "ses_a",
                         BASE_MS, BASE_MS,
                         json.dumps({"type": "tool", "text": "NEWCONTENT",
                                     "id": f"prt_reused_{rid}"})),
                    )
                # ...and append past the boundary, so the scan keeps going and
                # finishes on a watermark row that is perfectly consistent. That
                # is what makes the corruption invisible to index_validity().
                for k in (1, 2):
                    add_part(c, "ses_a", type="tool", text=f"tail{k} NEWCONTENT")
                c.commit()

        probe = ReuseProbe(oc_search.open_source(self.f.db), self.f.db)
        saved = oc_search.READ_CHUNK
        oc_search.READ_CHUNK = 2
        try:
            oc_search.build_index(
                probe, self.f.index, self.f.db,
                rebuild=True, batch=1_000_000, progress=False,
            )
        finally:
            oc_search.READ_CHUNK = saved
            probe.close()

        self.assertTrue(state["fired"], "the interleaving never happened")
        # The index must agree with the database, not with what the database
        # used to say. Without the boundary check the recycled rowids keep their
        # pre-delete contents forever, and the tail scan cannot help because the
        # watermark has already advanced past them.
        truth = self.f.conn.execute(
            "SELECT count(*) FROM part WHERE data LIKE '%NEWCONTENT%'"
        ).fetchone()[0]
        self.assertEqual(truth, 6)
        rows = self.f.sessions("NEWCONTENT")
        got = rows[0]["matches"] if rows else 0
        self.assertEqual(got, truth, "index disagrees with the live database")

    def test_batch_limit_still_bounds_the_work_when_chunked(self):
        """The batch cap is enforced across chunks, not per chunk -- otherwise
        --index-batch would silently mean something 'READ_CHUNK times bigger'."""
        saved = oc_search.READ_CHUNK
        oc_search.READ_CHUNK = 2
        try:
            res = self.f.build_index(rebuild=True, batch=5)
        finally:
            oc_search.READ_CHUNK = saved
        self.assertEqual(res["indexed"], 5)
        self.assertFalse(res["up_to_date"])


class LimitFastPathTest(unittest.TestCase):
    """bead workstation-gqt3.1 -- `--limit N` walks newest-first and stops.

    The contract: `--limit N` returns exactly the first N rows the unlimited
    search would, with exact `matches` and `last_match`, while reading only as
    much of the table as it takes to find N sessions. lgtm keeps ~10 rows and
    was paying for the whole aggregation (and timing out) to get them.
    """

    NEEDLES = ["needle", "needle-common", "needle-rare", "nothing-matches-this"]

    def setUp(self):
        self.f = Fixture()
        self.saved_window = oc_search.RECENT_FIRST_WINDOW
        # Tiny windows so a small fixture exercises many window steps.
        oc_search.RECENT_FIRST_WINDOW = 3
        c = self.f.conn
        for s in range(30):
            add_session(c, f"ses_{s:02d}", title=f"t{s}")
        # Interleave parts across sessions; times strictly increase with rowid.
        # Production is like this at the head of the table but NOT everywhere
        # -- see test_bulk_inserted_block_picks_by_insertion_order.
        t = 0
        for rnd in range(12):
            for s in range(30):
                if (s + rnd) % 3:
                    continue
                t += 1
                kind = "tool" if (s + rnd) % 2 else "text"
                text = "needle-common filler"
                if s % 10 == 0:
                    text += " needle-rare"
                add_part(c, f"ses_{s:02d}", type=kind, text=text, t=t)
                t += 1
                add_part(c, f"ses_{s:02d}", type="reasoning", text="no match here", t=t)
        self.f.commit()

    def tearDown(self):
        oc_search.RECENT_FIRST_WINDOW = self.saved_window
        self.f.close()

    def assert_limit_is_a_prefix(self, *flags):
        for needle in self.NEEDLES:
            for types in (["--types", "tool"], ["--types", "tool,text"], ["--all"]):
                full = self.f.sessions(*flags, *types, needle)
                for n in (1, 2, 5, 13, 1000):
                    got = self.f.sessions(*flags, *types, "--limit", str(n), needle)
                    self.assertEqual(
                        got, full[:n], f"flags={flags} types={types} n={n} {needle!r}"
                    )

    def test_prefix_without_index(self):
        self.assert_limit_is_a_prefix("--no-index")

    def test_prefix_with_full_index(self):
        self.f.build_index()
        self.assert_limit_is_a_prefix()

    def test_prefix_with_partial_index(self):
        # Half the table indexed: the walk must cover the tail, then the index.
        total = self.f.conn.execute("SELECT count(*) FROM part").fetchone()[0]
        self.f.build_index(rebuild=True, batch=total // 2)
        self.assert_limit_is_a_prefix()

    def test_prefix_with_invalid_index(self):
        self.f.build_index()
        self.f.conn.execute(
            "UPDATE part SET id='prt_impostor' WHERE rowid=(SELECT MAX(rowid) FROM part)"
        )
        self.f.commit()
        self.assert_limit_is_a_prefix()

    def test_counts_include_matches_far_below_the_stopping_point(self):
        """Exact counts, not window-local ones."""
        c = self.f.conn
        add_session(c, "ses_old_and_new")
        for i in range(40):
            add_part(c, "ses_x_filler", type="tool", text="filler")
        first = add_part(c, "ses_old_and_new", type="tool", text="ZZTOP ancient", t=0)
        for i in range(40):
            add_part(c, "ses_x_filler", type="tool", text="filler")
        add_part(c, "ses_old_and_new", type="tool", text="ZZTOP recent", t=100_000)
        self.f.commit()
        self.assertTrue(first)
        rows = self.f.sessions("--no-index", "--limit", "1", "ZZTOP")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "ses_old_and_new")
        self.assertEqual(rows[0]["matches"], 2)
        self.assertEqual(rows[0]["last_match_ms"], BASE_MS + 100_000)

    def test_deleted_session_does_not_use_up_a_slot(self):
        newest = self.f.sessions("--no-index", "--types", "tool,text", "needle-common")
        self.f.conn.execute("DELETE FROM session WHERE id=?", (newest[0]["id"],))
        self.f.commit()
        for flags in (["--no-index"], []):
            got = self.f.sessions(*flags, "--types", "tool,text", "--limit", "3", "needle-common")
            self.assertEqual(got, newest[1:4], flags)

    def _scanned_rows(self, *argv):
        """Run a search, returning (rows, total rowid span read by scan_range)."""
        spans = []
        real = oc_search.scan_range

        def spy(db_path, lo, hi, *a, **kw):
            spans.append(hi - lo)
            return real(db_path, lo, hi, *a, **kw)

        oc_search.scan_range = spy
        try:
            rows = self.f.sessions(*argv)
        finally:
            oc_search.scan_range = real
        return rows, sum(spans)

    def test_common_needle_reads_only_the_top_of_the_table(self):
        """The point of the change: an invalid/absent index must not turn
        `--limit 2` on a common needle into a full scan."""
        total = self.f.conn.execute("SELECT max(rowid) FROM part").fetchone()[0]
        rows, scanned = self._scanned_rows(
            "--no-index", "--jobs", "1", "--types", "tool,text", "--limit", "2", "needle-common"
        )
        self.assertEqual(len(rows), 2)
        self.assertLess(scanned, total // 4, f"read {scanned} of {total} rows")
        # ...whereas without --limit it reads everything, which is the baseline.
        _, full = self._scanned_rows("--no-index", "--jobs", "1", "--types", "tool,text", "needle-common")
        self.assertGreaterEqual(full, total)

    def test_full_index_is_not_rescanned(self):
        self.f.build_index()
        rows, scanned = self._scanned_rows("--types", "tool,text", "--limit", "5", "needle-rare")
        self.assertEqual(len(rows), 3)  # ses_00, ses_10, ses_20
        self.assertEqual(scanned, 0)

    def test_part_deleted_after_indexing_is_not_reported(self):
        """Recounting against the live table means a stale index posting for a
        part that no longer exists cannot surface a session with 0 matches."""
        add_session(self.f.conn, "ses_gone_part")
        add_part(self.f.conn, "ses_gone_part", type="tool", text="QQUNIQUE")
        add_part(self.f.conn, "ses_gone_part", type="tool", text="keeps the watermark row alive")
        self.f.commit()
        self.f.build_index()
        self.f.conn.execute("DELETE FROM part WHERE data LIKE '%QQUNIQUE%'")
        self.f.commit()
        self.assertEqual(self.f.sessions("--limit", "5", "QQUNIQUE"), [])

    def test_match_on_the_watermark_row_is_found_by_the_index_phase(self):
        """Boundary: the index phase reads `ft.rowid <= floor`, inclusive."""
        f = Fixture()
        try:
            add_session(f.conn, "ses_w")
            add_part(f.conn, "ses_w", type="tool", text="WMARK on the watermark row")
            f.commit()
            f.build_index()
            add_session(f.conn, "ses_later")
            add_part(f.conn, "ses_later", type="tool", text="unrelated tail row")
            f.commit()
            rows = f.sessions("--limit", "5", "WMARK")
            self.assertEqual([(r["id"], r["matches"]) for r in rows], [("ses_w", 1)])
        finally:
            f.close()

    def test_match_on_the_lowest_row_is_found_without_an_index(self):
        """Boundary: the no-index floor is min(rowid)-1, not min(rowid)."""
        f = Fixture()
        try:
            add_session(f.conn, "ses_first")
            add_part(f.conn, "ses_first", type="tool", text="LOWEST in row one")
            for _ in range(10):
                add_part(f.conn, "ses_first", type="text", text="filler")
            f.commit()
            rows = f.sessions("--no-index", "--limit", "5", "LOWEST")
            self.assertEqual([(r["id"], r["matches"]) for r in rows], [("ses_first", 1)])
        finally:
            f.close()

    def test_bulk_inserted_block_picks_by_insertion_order(self):
        """The documented limit of the early stop, pinned so it cannot drift.

        cloudbox has a ~100k-row block bulk-inserted in reverse chronological
        order (rowids ~852k-955k, 2026-06-07). Walking by rowid meets the
        OLDER session first there, so `--limit 1` picks it rather than the
        session with the newest match. What must still hold: every returned
        row is a real match with exactly the unlimited path's count and
        last_match. When gqt3.3 adds a time-bounded stop rule, flip the first
        assertion to `== full[:1]`.
        """
        f = Fixture()
        try:
            add_session(f.conn, "ses_newer")
            add_session(f.conn, "ses_older")
            add_part(f.conn, "ses_newer", type="tool", text="BLOCK newer", t=500)
            # Far enough apart to land in different scan windows (the walk
            # sorts by time WITHIN a window), as the real block's rows do.
            for i in range(20):
                add_part(f.conn, "ses_newer", type="text", text="filler", t=500 + i)
            add_part(f.conn, "ses_older", type="tool", text="BLOCK older", t=100)
            f.commit()
            full = f.sessions("--no-index", "BLOCK")
            self.assertEqual([r["id"] for r in full], ["ses_newer", "ses_older"])
            for flags in (["--no-index"], []):
                if not flags:
                    f.build_index()
                got = f.sessions(*flags, "--limit", "1", "BLOCK")
                self.assertEqual([r["id"] for r in got], ["ses_older"], flags)
                by_id = {r["id"]: r for r in full}
                for r in got:
                    self.assertEqual(r, by_id[r["id"]], flags)
        finally:
            f.close()

    def test_table_output_respects_limit(self):
        rc, out, _ = self.f.search("--types", "tool,text", "--limit", "4", "needle-common")
        self.assertEqual(rc, 0)
        self.assertEqual(len(out.splitlines()), 2 + 4)


class DifferentialRunner:
    """Seeded generator executing random DB and index operations.

    Structured so later tasks can add ops (update, interior delete,
    session delete, top reuse, interrupted build) by adding entries to
    OP_WEIGHTS and implementing the corresponding op_ method.
    """

    OP_WEIGHTS = {
        "insert_new": 4,
        "insert_existing": 4,
        "build": 2,
    }

    NEEDLES = [
        "cat",
        "dog",
        "common",
        "xyz_absent",
    ]

    VOCAB = [
        "cat",
        "dog",
        "common",
        "alpha",
        "beta",
        "gamma",
        "quick",
        "brown",
        "fox",
    ]

    TYPES = ["tool", "text", "reasoning"]

    def __init__(self, seed: int, test_case: unittest.TestCase):
        self.rng = random.Random(seed)
        self.test_case = test_case
        self.fixture = Fixture()
        self.sessions: list[str] = []
        # IMPORTANT: Task 1 assigns strictly distinct time_created values
        # to avoid ties flaking --limit equality. Task 4 will add ties.
        self.time_counter = 0

    def close(self):
        self.fixture.close()

    def next_time(self) -> int:
        self.time_counter += 1
        return self.time_counter

    def random_text(self) -> str:
        k = self.rng.randint(1, 3)
        words = self.rng.sample(self.VOCAB, k)
        return " ".join(words)

    def op_insert_new(self):
        sid = f"ses_{len(self.sessions):03d}"
        add_session(self.fixture.conn, sid, title=f"title_{sid}")
        self.sessions.append(sid)
        for _ in range(self.rng.randint(1, 2)):
            t = self.next_time()
            add_part(
                self.fixture.conn,
                sid,
                type=self.rng.choice(self.TYPES),
                text=self.random_text(),
                t=t,
            )
        self.fixture.commit()

    def op_insert_existing(self):
        if not self.sessions:
            self.op_insert_new()
            return
        sid = self.rng.choice(self.sessions)
        for _ in range(self.rng.randint(1, 2)):
            t = self.next_time()
            add_part(
                self.fixture.conn,
                sid,
                type=self.rng.choice(self.TYPES),
                text=self.random_text(),
                t=t,
            )
        self.fixture.commit()

    def op_build(self):
        self.fixture.build_index()
        self.assert_differential()

    def assert_differential(self):
        """Assert indexed unlimited == --no-index, and --limit N == first N."""
        for needle in self.NEEDLES:
            for type_flags in ([], ["--all"]):
                unlimited_indexed = self.fixture.sessions(*type_flags, needle)
                unlimited_scanned = self.fixture.sessions("--no-index", *type_flags, needle)
                self.test_case.assertEqual(
                    unlimited_indexed,
                    unlimited_scanned,
                    f"Unlimited indexed vs scanned mismatch for needle={needle!r}, flags={type_flags}",
                )
                for n in (1, 2, 3, 4):
                    limit_indexed = self.fixture.sessions(*type_flags, "--limit", str(n), needle)
                    self.test_case.assertEqual(
                        limit_indexed,
                        unlimited_scanned[:n],
                        f"--limit {n} mismatch for needle={needle!r}, flags={type_flags}",
                    )

    def run_steps(self, n_steps: int):
        ops = list(self.OP_WEIGHTS.keys())
        weights = list(self.OP_WEIGHTS.values())
        for _ in range(n_steps):
            chosen = self.rng.choices(ops, weights=weights, k=1)[0]
            handler = getattr(self, f"op_{chosen}")
            handler()
        # Always end with a build and assert
        self.op_build()


class DifferentialTest(unittest.TestCase):
    """Differential test harness comparing indexed results to --no-index.

    Seeded pseudo-random operations generate realistic data mutations. After
    each build, assertions verify that:
    1. Indexed unlimited results == --no-index results (exact equivalence)
    2. --limit N (N in 1..4) results == first N of --no-index unlimited results
    """

    SEEDS = [42, 1337, 2026]

    def test_seeded_differential_runs(self):
        for seed in self.SEEDS:
            with self.subTest(seed=seed):
                runner = DifferentialRunner(seed, self)
                try:
                    runner.run_steps(10)
                finally:
                    runner.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
