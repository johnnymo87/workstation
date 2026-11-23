"""Tests for llm-ledger. Run: python3 pkgs/llm-ledger/test_llm_ledger.py"""

from __future__ import annotations

import datetime
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Redirect HOME to a throwaway dir BEFORE importing oc_tags or llm_ledger.
_HOME_SANDBOX = tempfile.TemporaryDirectory(prefix="llm-ledger-test-home-")
os.environ["HOME"] = _HOME_SANDBOX.name

# Add oc-tags and llm-ledger to sys.path
_PKG_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_PKG_DIR))
sys.path.insert(0, str(_PKG_DIR.parent / "oc-tags"))

import llm_ledger  # noqa: E402
import oc_tags     # noqa: E402


class TestLlmLedger(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory(prefix="llm-ledger-unit-")
        self.db_path = os.path.join(self.tmpdir.name, "ledger.db")
        self.events_path = os.path.join(self.tmpdir.name, "events.jsonl")
        self.raw_dir = os.path.join(self.tmpdir.name, "raw")
        self.samples_path = os.path.join(self.tmpdir.name, "quota-samples.jsonl")
        self.samples_archive = os.path.join(self.tmpdir.name, "archive")
        self.orig_default_samples = llm_ledger.DEFAULT_SAMPLES
        self.orig_default_samples_archive = llm_ledger.DEFAULT_SAMPLES_ARCHIVE
        llm_ledger.DEFAULT_SAMPLES = self.samples_path
        llm_ledger.DEFAULT_SAMPLES_ARCHIVE = self.samples_archive

    def tearDown(self):
        llm_ledger.DEFAULT_SAMPLES = self.orig_default_samples
        llm_ledger.DEFAULT_SAMPLES_ARCHIVE = self.orig_default_samples_archive
        self.tmpdir.cleanup()

    def test_schema_creation_and_pragmas(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # Check journal_mode and busy_timeout
            jm = conn.execute("PRAGMA journal_mode").fetchone()[0]
            self.assertEqual(jm.upper(), "DELETE")
            bt = conn.execute("PRAGMA busy_timeout").fetchone()[0]
            self.assertGreaterEqual(bt, 30000)

            # Check all tables exist
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
            expected_tables = {
                "route",
                "requests",
                "session_program",
                "hourly",
                "quota_pool",
                "quota_samples",
                "ingest_state",
            }
            self.assertTrue(expected_tables.issubset(tables))

            # Check expected indexes exist
            indexes = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='index'"
                ).fetchall()
            }
            self.assertIn("requests_ts", indexes)
            self.assertIn("requests_attr_ts", indexes)
            self.assertIn("session_program_tag", indexes)
        finally:
            conn.close()

    def test_route_and_usage_join(self):
        route_line = {
            "type": "route",
            "ts": 1700000000000,
            "requestId": "req-1",
            "sessionId": "ses_test123",
            "model": "claude-opus-5-5",
            "desired": "vertex",
            "chosen": "vertex",
        }
        usage_line = {
            "type": "usage",
            "ts": 1700000000000,
            "durationMs": 1500,
            "requestId": "req-1",
            "cost": 0.05,
            "usage": {
                "input": 10,
                "output": 20,
                "cacheRead": 30,
                "cacheWrite": 40,
            },
            "status": 200,
            "backend": "vertex",
        }
        with open(self.events_path, "w") as f:
            f.write(json.dumps(route_line) + "\n")
            f.write(json.dumps(usage_line) + "\n")

        ret = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            host="test-host",
        )
        self.assertEqual(ret["new_routes"], 1)
        self.assertEqual(ret["new_requests"], 1)
        self.assertEqual(ret["malformed"], 0)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT request_id, ts, host, session_id, attr_key, backend, model, "
                "input, output, cache_read, cache_write, cost_usd, status, duration_ms "
                "FROM requests WHERE request_id = 'req-1'"
            ).fetchone()
            self.assertIsNotNone(row)
            (
                req_id, ts, host, sid, attr_key, backend, model,
                inp, outp, cread, cwrite, cost, status, dur
            ) = row
            self.assertEqual(req_id, "req-1")
            self.assertEqual(ts, 1700000000000)
            self.assertEqual(host, "test-host")
            self.assertEqual(sid, "ses_test123")
            self.assertEqual(attr_key, "ses_test123")
            self.assertEqual(backend, "vertex")
            self.assertEqual(model, "claude-opus-5-5")
            self.assertEqual(inp, 10)
            self.assertEqual(outp, 20)
            self.assertEqual(cread, 30)
            self.assertEqual(cwrite, 40)
            self.assertAlmostEqual(cost, 0.05)
            self.assertEqual(status, 200)
            self.assertEqual(dur, 1500)
        finally:
            conn.close()

    def test_backend_from_usage_when_route_chosen_differs(self):
        route_line = {
            "type": "route",
            "ts": 1700000000000,
            "requestId": "req-backend",
            "sessionId": "ses_backend",
            "model": "claude-sonnet-4",
            "desired": "vertex",
            "chosen": "vertex",
        }
        usage_line = {
            "type": "usage",
            "ts": 1700000000000,
            "requestId": "req-backend",
            "backend": "anthropic",
            "cost": 0.01,
            "usage": {"input": 1, "output": 2},
        }
        with open(self.events_path, "w") as f:
            f.write(json.dumps(route_line) + "\n")
            f.write(json.dumps(usage_line) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            host="test-host",
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT backend, model FROM requests WHERE request_id = 'req-backend'"
            ).fetchone()
            self.assertIsNotNone(row)
            self.assertEqual(row[0], "anthropic")  # from usage, not vertex
            self.assertEqual(row[1], "claude-sonnet-4")  # from route
        finally:
            conn.close()

    def test_usage_without_route_then_later_route_fills_it(self):
        usage_line = {
            "type": "usage",
            "ts": 1700000000000,
            "requestId": "req-late",
            "backend": "vertex",
            "cost": 0.02,
            "usage": {"input": 5, "output": 5},
        }
        with open(self.events_path, "w") as f:
            f.write(json.dumps(usage_line) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            host="test-host",
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT session_id, model, attr_key FROM requests WHERE request_id = 'req-late'"
            ).fetchone()
            self.assertIsNone(row[0])
            self.assertIsNone(row[1])
            self.assertEqual(row[2], oc_tags.CFP_UNROUTED_TAG)
        finally:
            conn.close()

        # Run 2: route line arrives
        route_line = {
            "type": "route",
            "ts": 1700000000000,
            "requestId": "req-late",
            "sessionId": "ses_later",
            "model": "claude-opus-5-5",
            "desired": "vertex",
            "chosen": "vertex",
        }
        with open(self.events_path, "a") as f:
            f.write(json.dumps(route_line) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            host="test-host",
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT session_id, model, attr_key FROM requests WHERE request_id = 'req-late'"
            ).fetchone()
            self.assertEqual(row[0], "ses_later")
            self.assertEqual(row[1], "claude-opus-5-5")
            self.assertEqual(row[2], "ses_later")
        finally:
            conn.close()

    def test_partial_last_line_not_consumed_then_consumed_next_run(self):
        line1 = json.dumps({
            "type": "usage",
            "ts": 1700000000000,
            "requestId": "req-part-1",
            "backend": "vertex",
            "cost": 0.01,
        })
        line2_partial = '{"type":"usage","ts":1700000001000,"requestId":"req-part-2","cost":0.02'

        with open(self.events_path, "w") as f:
            f.write(line1 + "\n")
            f.write(line2_partial)

        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret1["new_requests"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
            offset = int(conn.execute("SELECT value FROM ingest_state WHERE key = 'cfp_offset'").fetchone()[0])
            self.assertEqual(offset, len(line1.encode("utf-8")) + 1)
        finally:
            conn.close()

        # Run 2: finish the line
        with open(self.events_path, "a") as f:
            f.write(',"backend":"vertex"}\n')

        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret2["new_requests"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 2)
            row = conn.execute("SELECT request_id, cost_usd FROM requests WHERE request_id = 'req-part-2'").fetchone()
            self.assertIsNotNone(row)
            self.assertAlmostEqual(row[1], 0.02)
        finally:
            conn.close()

    def test_inode_change_restart_without_duplicate_rows_and_without_rearchiving_old_lines(self):
        # Setup file 1 with 2 lines (ts = 1_000_000_000)
        file1 = self.events_path
        line1 = json.dumps({"type": "usage", "ts": 1000000000, "requestId": "req-old-1", "cost": 0.01, "backend": "b"}) + "\n"
        line2 = json.dumps({"type": "usage", "ts": 1000000000, "requestId": "req-old-2", "cost": 0.02, "backend": "b"}) + "\n"
        with open(file1, "w") as f:
            f.write(line1)
            f.write(line2)

        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=file1,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret1["new_requests"], 2)

        # Inspect raw archive from run 1
        raw_files = list(Path(self.raw_dir).glob("*.gz"))
        self.assertEqual(len(raw_files), 1)
        with gzip.open(raw_files[0], "rt") as gz:
            archived_lines_run1 = gz.readlines()
        self.assertEqual(len(archived_lines_run1), 2)

        # Create a new file (simulating daily rename/trim, new inode)
        # It contains old lines (ts=1_000_000_000) which is <= 1_000_000_000 - 600_000 + delta
        # Let's say ts=1_000_000_000 is older than cutoff (archived_through_ts was 2_000_000_000)
        # Let's update archived_through_ts or set timestamps:
        # If archived_through_ts was 2_000_000_000, cutoff is 2_000_000_000 - 600_000 = 1_999_400_000.
        # Lines with ts=1_000_000_000 are < cutoff, so they should NOT be re-archived.
        # A new line with ts=2_000_100_000 should be archived.
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            conn.execute(
                "INSERT OR REPLACE INTO ingest_state (key, value) VALUES ('cfp_archived_through_ts', '2000000000')"
            )
            conn.commit()
        finally:
            conn.close()

        file2 = os.path.join(self.tmpdir.name, "events_new.jsonl")
        new_line = json.dumps({"type": "usage", "ts": 2000100000, "requestId": "req-new-3", "cost": 0.03, "backend": "b"}) + "\n"
        with open(file2, "w") as f:
            f.write(line1)
            f.write(line2)
            f.write(new_line)

        # Run with file2 (new inode)
        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=file2,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret2["new_requests"], 1)  # Only req-new-3 added

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 3)
            # Check inode updated
            cur_st = os.stat(file2)
            stored_ino = int(conn.execute("SELECT value FROM ingest_state WHERE key = 'cfp_inode'").fetchone()[0])
            self.assertEqual(stored_ino, cur_st.st_ino)
        finally:
            conn.close()

        # Check archive has only 1 new line added (total 3 lines, not 5!)
        with gzip.open(raw_files[0], "rt") as gz:
            archived_lines_all = gz.readlines()
        self.assertEqual(len(archived_lines_all), 3)

    def test_truncation_size_less_than_offset_restarts(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        line2 = json.dumps({"type": "usage", "ts": 200, "requestId": "r2", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line1)
            f.write(line2)

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )

        # Truncate file in place to just 1 line (same inode, smaller size)
        line3 = json.dumps({"type": "usage", "ts": 300, "requestId": "r3", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line3)

        ret = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret["new_requests"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 3)
        finally:
            conn.close()

    def test_idempotent_reimport(self):
        line = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line)

        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret1["new_requests"], 1)

        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret2["new_requests"], 0)
        self.assertEqual(ret2["new_routes"], 0)

    def test_malformed_lines_counted(self):
        lines = [
            json.dumps({"type": "route", "ts": 100, "requestId": "r1"}),
            json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "backend": "b", "cost": 0.01}),
            "not a json at all",
            json.dumps("just a string"),
            json.dumps({"type": "usage", "ts": 100}),  # missing requestId
            json.dumps({"type": "usage", "requestId": "r2"}),  # missing ts
            json.dumps({"type": "keepwarm", "ts": 100}),  # keepwarm ignored, not malformed
            json.dumps({"type": "boot", "ts": 100}),  # boot ignored, not malformed
        ]
        with open(self.events_path, "w") as f:
            for l in lines:
                f.write(l + "\n")

        ret = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret["new_routes"], 1)
        self.assertEqual(ret["new_requests"], 1)
        self.assertEqual(ret["malformed"], 4)

    def test_attr_key_resolution(self):
        # 1. ses_*
        # 2. goose-shaped in goose-serve
        # 3. goose-shaped claimed by lgtm
        # 4. goose-shaped unknown
        # 5. unrouted / other
        goose_db = os.path.join(self.tmpdir.name, "goose.db")
        gconn = sqlite3.connect(goose_db)
        gconn.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, working_dir TEXT, name TEXT, session_type TEXT, recipe_json TEXT)")
        gconn.execute("CREATE TABLE usage_ledger (session_id TEXT, created_timestamp INTEGER)")
        gconn.execute("INSERT INTO sessions VALUES ('20261120_1', NULL, '/tmp', 'test-session', 'chat', NULL)")
        gconn.execute("INSERT INTO usage_ledger VALUES ('20261120_1', 1700000000)")  # 1700000000 s = 1700000000000 ms
        gconn.commit()
        gconn.close()

        lgtm_path = os.path.join(self.tmpdir.name, "lgtm.jsonl")
        # lgtm row format: {"root": "lgtm-goose:pr-123", "tag": "lgtm", "source": "manual", "title": "PR 123", "ts": 1700000000000}
        with open(lgtm_path, "w") as f:
            f.write(json.dumps({
                "v": 1,
                "key": "k1",
                "kind": "review",
                "session": "pr-123",
                "repo": "workstation",
                "pr": 123,
                "at": "2023-11-14T22:13:20+00:00",
                "costUsd": 0.05,
            }) + "\n")

        routes = [
            {"type": "route", "ts": 1700000000000, "requestId": "r-ses", "sessionId": "ses_abc123"},
            {"type": "route", "ts": 1700000000000, "requestId": "r-goose-serve", "sessionId": "20261120_1"},
            {"type": "route", "ts": 1700000000000, "requestId": "r-lgtm", "sessionId": "20261120_2"},
            {"type": "route", "ts": 1700500000000, "requestId": "r-goose-unk", "sessionId": "20261120_3"},
            {"type": "route", "ts": 1700000000000, "requestId": "r-other", "sessionId": "other-sid"},
        ]
        usages = [
            {"type": "usage", "ts": 1700000000000, "requestId": "r-ses", "backend": "b", "cost": 0.01},
            {"type": "usage", "ts": 1700000000000, "requestId": "r-goose-serve", "backend": "b", "cost": 0.01},
            {"type": "usage", "ts": 1700000000000, "requestId": "r-lgtm", "backend": "b", "cost": 0.01},
            {"type": "usage", "ts": 1700500000000, "requestId": "r-goose-unk", "backend": "b", "cost": 0.01},
            {"type": "usage", "ts": 1700000000000, "requestId": "r-other", "backend": "b", "cost": 0.01},
            {"type": "usage", "ts": 1700000000000, "requestId": "r-noroute", "backend": "b", "cost": 0.01},
        ]
        with open(self.events_path, "w") as f:
            for r in routes:
                f.write(json.dumps(r) + "\n")
            for u in usages:
                f.write(json.dumps(u) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            goose_db=goose_db,
            lgtm_ledger=lgtm_path,
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            rows = dict(conn.execute("SELECT request_id, attr_key FROM requests").fetchall())
            self.assertEqual(rows["r-ses"], "ses_abc123")
            self.assertEqual(rows["r-goose-serve"], "goose:20261120_1")
            self.assertEqual(rows["r-lgtm"], "lgtm-goose:pr-123")
            self.assertEqual(rows["r-goose-unk"], oc_tags.CFP_GOOSE_UNKNOWN_TAG)
            self.assertEqual(rows["r-other"], oc_tags.CFP_UNROUTED_TAG)
            self.assertEqual(rows["r-noroute"], oc_tags.CFP_UNROUTED_TAG)
        finally:
            conn.close()

    def test_numbers_missing_or_boolean(self):
        usage_line = {
            "type": "usage",
            "ts": 1700000000000,
            "requestId": "req-bools",
            "backend": "vertex",
            "status": True,         # bool -> NULL
            "cost": "non-numeric",  # str -> NULL
            "durationMs": False,    # bool -> NULL
            "usage": {
                "input": True,      # bool -> NULL
                "output": "bad",    # str -> NULL
                "cacheRead": None,  # None -> NULL
                "cacheWrite": 100,
            },
        }
        with open(self.events_path, "w") as f:
            f.write(json.dumps(usage_line) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT status, cost_usd, duration_ms, input, output, cache_read, cache_write "
                "FROM requests WHERE request_id = 'req-bools'"
            ).fetchone()
            self.assertIsNotNone(row)
            self.assertIsNone(row[0])  # status
            self.assertIsNone(row[1])  # cost_usd
            self.assertIsNone(row[2])  # duration_ms
            self.assertIsNone(row[3])  # input
            self.assertIsNone(row[4])  # output
            self.assertIsNone(row[5])  # cache_read
            self.assertEqual(row[6], 100)  # cache_write
        finally:
            conn.close()

    def test_import_events_gz_and_plain(self):
        plain_file = os.path.join(self.tmpdir.name, "import1.jsonl")
        gz_file = os.path.join(self.tmpdir.name, "import2.jsonl.gz")

        r1 = json.dumps({"type": "route", "ts": 100, "requestId": "r-plain", "sessionId": "ses_plain", "model": "m1"})
        u1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r-plain", "backend": "v1", "cost": 0.05})
        with open(plain_file, "w") as f:
            f.write(r1 + "\n" + u1 + "\n")

        r2 = json.dumps({"type": "route", "ts": 200, "requestId": "r-gz", "sessionId": "ses_gz", "model": "m2"})
        u2 = json.dumps({"type": "usage", "ts": 200, "requestId": "r-gz", "backend": "v2", "cost": 0.10})
        with gzip.open(gz_file, "wt") as f:
            f.write(r2 + "\n" + u2 + "\n")

        # import-events command
        ret = llm_ledger.import_events(
            db_path=self.db_path,
            files=[plain_file, gz_file],
            host="import-host",
        )
        self.assertEqual(ret["new_routes"], 2)
        self.assertEqual(ret["new_requests"], 2)

        # Check DB rows
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 2)
            # ingest_state should have NO tail state!
            tail_state = conn.execute("SELECT count(*) FROM ingest_state").fetchone()[0]
            self.assertEqual(tail_state, 0)
        finally:
            conn.close()

        # Check raw dir was NOT written to
        self.assertFalse(os.path.exists(self.raw_dir))

    def test_import_events_cross_file_route_fill(self):
        # File 1 has usage without route
        f1 = os.path.join(self.tmpdir.name, "file1.jsonl")
        u = json.dumps({"type": "usage", "ts": 100, "requestId": "r-cross", "backend": "vertex", "cost": 0.05})
        with open(f1, "w") as f:
            f.write(u + "\n")

        # File 2 has route
        f2 = os.path.join(self.tmpdir.name, "file2.jsonl")
        r = json.dumps({"type": "route", "ts": 100, "requestId": "r-cross", "sessionId": "ses_cross", "model": "claude-3-7-sonnet"})
        with open(f2, "w") as f:
            f.write(r + "\n")

        llm_ledger.import_events(db_path=self.db_path, files=[f1, f2])

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            row = conn.execute(
                "SELECT session_id, model, attr_key FROM requests WHERE request_id = 'r-cross'"
            ).fetchone()
            self.assertEqual(row[0], "ses_cross")
            self.assertEqual(row[1], "claude-3-7-sonnet")
            self.assertEqual(row[2], "ses_cross")
        finally:
            conn.close()

    def test_archive_gzip_member_concatenation_and_non_numeric_ts(self):
        # Run 1: Normal run with keepwarm and boot lines (non-numeric ts lines)
        l1 = json.dumps({"type": "keepwarm"}) + "\n"
        l2 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "backend": "v", "cost": 0.01}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(l1 + l2)

        llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        # Run 2: Appends another line to the events file
        l3 = json.dumps({"type": "usage", "ts": 200, "requestId": "r2", "backend": "v", "cost": 0.02}) + "\n"
        with open(self.events_path, "a") as f:
            f.write(l3)

        llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        # Check raw archive contains all 3 lines concatenated properly across multiple gzip members
        raw_files = list(Path(self.raw_dir).glob("*.gz"))
        self.assertEqual(len(raw_files), 1)
        with gzip.open(raw_files[0], "rt") as gz:
            lines = gz.readlines()
        self.assertEqual(len(lines), 3)
        self.assertIn('"keepwarm"', lines[0])

    def test_fstat_on_opened_fd_records_opened_file_inode(self):
        # Create initial events file
        with open(self.events_path, "w") as f:
            f.write(json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "backend": "v", "cost": 0.01}) + "\n")

        real_open = open
        def open_and_rename(*args, **kwargs):
            fh = real_open(*args, **kwargs)
            # When opening self.events_path in binary read mode, rename it immediately
            if args and args[0] == self.events_path and len(args) > 1 and "b" in args[1]:
                os.rename(self.events_path, self.events_path + ".old")
                with real_open(self.events_path, "w") as f_new:
                    f_new.write(json.dumps({"type": "usage", "ts": 200, "requestId": "r2", "backend": "v", "cost": 0.02}) + "\n")
            return fh

        with mock.patch("builtins.open", side_effect=open_and_rename):
            llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        # The recorded inode in ingest_state should be the inode of the OPENED file (which is now .old)
        st_old = os.stat(self.events_path + ".old")
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            stored_ino = int(conn.execute("SELECT value FROM ingest_state WHERE key = 'cfp_inode'").fetchone()[0])
            self.assertEqual(stored_ino, st_old.st_ino)
        finally:
            conn.close()

    def test_route_fill_in_goose_batch_resolver(self):
        # Insert 2 usage rows with goose-shaped session ids that have no route
        u1 = json.dumps({"type": "usage", "ts": 1700000000000, "requestId": "g-fill-1", "backend": "v", "cost": 0.01})
        u2 = json.dumps({"type": "usage", "ts": 1700000000000, "requestId": "g-fill-2", "backend": "v", "cost": 0.02})
        with open(self.events_path, "w") as f:
            f.write(u1 + "\n" + u2 + "\n")
        llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        # Next run: routes arrive for both
        r1 = json.dumps({"type": "route", "ts": 1700000000000, "requestId": "g-fill-1", "sessionId": "20261120_1", "model": "m1"})
        r2 = json.dumps({"type": "route", "ts": 1700000000000, "requestId": "g-fill-2", "sessionId": "20261120_2", "model": "m2"})
        with open(self.events_path, "a") as f:
            f.write(r1 + "\n" + r2 + "\n")

        with mock.patch("oc_tags.CfpSessionResolver", wraps=oc_tags.CfpSessionResolver) as mock_resolver:
            llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)
            # Should have called CfpSessionResolver AT MOST ONCE for the batch of goose fill-ins
            self.assertLessEqual(mock_resolver.call_count, 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            rows = dict(conn.execute("SELECT request_id, session_id FROM requests").fetchall())
            self.assertEqual(rows["g-fill-1"], "20261120_1")
            self.assertEqual(rows["g-fill-2"], "20261120_2")
        finally:
            conn.close()

    def test_cli_main(self):
        route_line = json.dumps({"type": "route", "ts": 100, "requestId": "r-cli", "sessionId": "ses_cli", "model": "m"})
        usage_line = json.dumps({"type": "usage", "ts": 100, "requestId": "r-cli", "backend": "v", "cost": 0.01})
        with open(self.events_path, "w") as f:
            f.write(route_line + "\n" + usage_line + "\n")

        import io
        import contextlib
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exit_code = llm_ledger.main([
                "run",
                "--db", self.db_path,
                "--events", self.events_path,
                "--raw-dir", self.raw_dir,
            ])
        self.assertEqual(exit_code, 0)
        self.assertIn("routes=1 requests=1", out.getvalue())

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
        finally:
            conn.close()

    def test_quota_dst_offsets(self):
        # Line 1: EDT offset (-04:00) -> 2026-07-26T22:00:00-04:00 is 2026-07-27T02:00:00Z (1785117600000 ms)
        line1 = {
            "ts": "2026-07-26T22:00:00-04:00",
            "healthy": 3,
            "roster": 3,
            "current": "johnnymo872@gmail.com",
            "accounts": [
                {
                    "n": "jonathan.mohrbacher",
                    "s": "active",
                    "u5h": 0.1,
                    "u7d": 0.5,
                    "u7dF": 0.1,
                    "fw": False,
                }
            ],
        }
        # Line 2: EST offset (-05:00) -> 2026-11-22T22:00:00-05:00 is 2026-11-23T03:00:00Z (1795402800000 ms)
        line2 = {
            "ts": "2026-11-22T22:00:00-05:00",
            "healthy": 6,
            "canary_healthy": 5,
            "canary_serving": 5,
            "roster": 6,
            "current": "johnnymo873@gmail.com",
            "fwh": 24,
            "accounts": [
                {
                    "n": "jonathan.mohrbacher",
                    "s": "active",
                    "u5h": 0.2,
                    "u7d": 0.9,
                    "u7dF": 0.2,
                    "fw": True,
                }
            ],
        }
        with open(self.samples_path, "w") as f:
            f.write(json.dumps(line1) + "\n")
            f.write(json.dumps(line2) + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            counts = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(counts["quota_rows"], 2)
            self.assertEqual(counts["quota_pool_rows"], 2)

            pool_rows = conn.execute("SELECT ts, healthy, roster FROM quota_pool ORDER BY ts ASC").fetchall()
            self.assertEqual(len(pool_rows), 2)
            self.assertEqual(pool_rows[0][0], 1785117600000)
            self.assertEqual(pool_rows[1][0], 1795402800000)

            sample_rows = conn.execute(
                "SELECT ts, account, s, u5h, u7d, u7d_fable, fw FROM quota_samples ORDER BY ts ASC"
            ).fetchall()
            self.assertEqual(len(sample_rows), 2)
            # Row 1 (-04:00)
            self.assertEqual(sample_rows[0][0], 1785117600000)
            self.assertEqual(sample_rows[0][1], "jonathan.mohrbacher")
            self.assertEqual(sample_rows[0][2], "active")
            self.assertAlmostEqual(sample_rows[0][3], 0.1)
            self.assertAlmostEqual(sample_rows[0][4], 0.5)
            self.assertAlmostEqual(sample_rows[0][5], 0.1)
            self.assertEqual(sample_rows[0][6], 0)  # fw False -> 0

            # Row 2 (-05:00)
            self.assertEqual(sample_rows[1][0], 1795402800000)
            self.assertEqual(sample_rows[1][1], "jonathan.mohrbacher")
            self.assertEqual(sample_rows[1][2], "active")
            self.assertAlmostEqual(sample_rows[1][3], 0.2)
            self.assertAlmostEqual(sample_rows[1][4], 0.9)
            self.assertAlmostEqual(sample_rows[1][5], 0.2)
            self.assertEqual(sample_rows[1][6], 1)  # fw True -> 1
        finally:
            conn.close()

    def test_quota_archives_imported_once(self):
        os.makedirs(self.samples_archive, exist_ok=True)
        archive_file = os.path.join(self.samples_archive, "quota-samples-until-20260828T222004.jsonl.gz")
        line1 = {
            "ts": "2026-08-28T22:15:00-04:00",
            "healthy": 3,
            "roster": 3,
            "accounts": [{"n": "acc1", "u7d": 0.1}],
        }
        line2 = {
            "ts": "2026-08-28T22:20:00-04:00",
            "healthy": 3,
            "roster": 3,
            "accounts": [{"n": "acc1", "u7d": 0.2}],
        }
        with gzip.open(archive_file, "wt") as f:
            f.write(json.dumps(line1) + "\n" + json.dumps(line2) + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # First import
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret1["quota_rows"], 2)
            self.assertEqual(ret1["quota_pool_rows"], 2)

            # Ingest state recorded
            val = conn.execute(
                "SELECT value FROM ingest_state WHERE key = 'quota_archive:quota-samples-until-20260828T222004.jsonl.gz'"
            ).fetchone()
            self.assertIsNotNone(val)

            # Second import: should be skipped because it's recorded in ingest_state
            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret2["quota_rows"], 0)
            self.assertEqual(ret2["quota_pool_rows"], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 2)
        finally:
            conn.close()

    def test_quota_live_file_skip_by_newest_ts(self):
        line1 = {"ts": "2026-11-20T10:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.1}]}
        line2 = {"ts": "2026-11-20T11:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.2}]}
        with open(self.samples_path, "w") as f:
            f.write(json.dumps(line1) + "\n" + json.dumps(line2) + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret1["quota_rows"], 2)

            # Append an old line (ts1), a duplicate (ts2), and a newer line (ts3)
            line3 = {"ts": "2026-11-20T12:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.3}]}
            with open(self.samples_path, "a") as f:
                f.write(json.dumps(line1) + "\n")
                f.write(json.dumps(line2) + "\n")
                f.write(json.dumps(line3) + "\n")

            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            # Only line3 is newer than ts2, line1 and line2 skipped by newest ts check
            self.assertEqual(ret2["quota_rows"], 1)
            self.assertEqual(ret2["quota_pool_rows"], 1)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 3)
        finally:
            conn.close()

    def test_quota_old_lines_missing_fields(self):
        # Old lines lack canary_*, fwh, u7dF, fw, r7d, r5h
        old_line = {
            "ts": "2026-07-26T22:45:00-04:00",
            "healthy": 3,
            "roster": 3,
            "current": "johnnymo872@gmail.com",
            "accounts": [
                {
                    "n": "jonathan.mohrbacher",
                    "s": "active",
                    "u5h": 0.05,
                    "u7d": 0.44,
                }
            ],
        }
        with open(self.samples_path, "w") as f:
            f.write(json.dumps(old_line) + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            pool_row = conn.execute(
                "SELECT canary_healthy, canary_serving, fwh FROM quota_pool"
            ).fetchone()
            self.assertIsNotNone(pool_row)
            self.assertIsNone(pool_row[0])  # canary_healthy
            self.assertIsNone(pool_row[1])  # canary_serving
            self.assertIsNone(pool_row[2])  # fwh

            sample_row = conn.execute(
                "SELECT u7d_fable, fw, r7d, r5h FROM quota_samples"
            ).fetchone()
            self.assertIsNotNone(sample_row)
            self.assertIsNone(sample_row[0])  # u7d_fable (u7dF was missing)
            self.assertIsNone(sample_row[1])  # fw
            self.assertIsNone(sample_row[2])  # r7d
            self.assertIsNone(sample_row[3])  # r5h
        finally:
            conn.close()

    def test_quota_null_u7d_kept_null(self):
        line = {
            "ts": "2026-11-22T22:00:00-05:00",
            "healthy": 5,
            "accounts": [
                {"n": "acc_null", "u7d": None},
                {"n": "acc_zero", "u7d": 0},
                {"n": "acc_val", "u7d": 0.75},
                {"n": "acc_missing"},
            ],
        }
        with open(self.samples_path, "w") as f:
            f.write(json.dumps(line) + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            rows = dict(conn.execute("SELECT account, u7d FROM quota_samples").fetchall())
            self.assertIsNone(rows["acc_null"])
            self.assertEqual(rows["acc_zero"], 0.0)
            self.assertAlmostEqual(rows["acc_val"], 0.75)
            self.assertIsNone(rows["acc_missing"])
        finally:
            conn.close()

    def test_quota_rewritten_live_file_neither_loses_nor_duplicates(self):
        # 1. Setup initial live file with 4 lines
        lines = [
            {"ts": f"2026-11-20T10:0{i}:00-05:00", "healthy": 5, "accounts": [{"n": "acc1", "u7d": i * 0.1}]}
            for i in range(4)
        ]
        with open(self.samples_path, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")

        # Run 1: imports all 4 lines
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret1["quota_rows"], 4)
            self.assertEqual(ret1["quota_pool_rows"], 4)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 4)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_samples").fetchone()[0], 4)

            # 2. Canary archives lines 0 and 1 into a new archive
            os.makedirs(self.samples_archive, exist_ok=True)
            archive_path = os.path.join(self.samples_archive, "quota-samples-until-20261120T100100.jsonl.gz")
            with gzip.open(archive_path, "wt") as gz:
                gz.write(json.dumps(lines[0]) + "\n" + json.dumps(lines[1]) + "\n")

            # Canary rewrites live file to keep only lines 2, 3, and appends a new line 4
            line4 = {"ts": "2026-11-20T10:04:00-05:00", "healthy": 5, "accounts": [{"n": "acc1", "u7d": 0.4}]}
            with open(self.samples_path, "w") as f:
                f.write(json.dumps(lines[2]) + "\n")
                f.write(json.dumps(lines[3]) + "\n")
                f.write(json.dumps(line4) + "\n")

            # Run 2:
            # - Archive lines 0, 1 are ignored by INSERT OR IGNORE because they already exist in DB
            # - Archive is recorded in ingest_state
            # - Live lines 2, 3 are skipped because ts <= newest_ts
            # - Live line 4 is inserted
            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret2["quota_rows"], 1)  # Only line 4 added
            self.assertEqual(ret2["quota_pool_rows"], 1)

            # Total rows in DB is exactly 5
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 5)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_samples").fetchone()[0], 5)

            # Ingest state has the archive recorded
            val = conn.execute(
                "SELECT value FROM ingest_state WHERE key = 'quota_archive:quota-samples-until-20261120T100100.jsonl.gz'"
            ).fetchone()
            self.assertIsNotNone(val)
        finally:
            conn.close()

    def test_quota_missing_live_file_and_archive_dir(self):
        nonexistent_samples = os.path.join(self.tmpdir.name, "does-not-exist.jsonl")
        nonexistent_archive = os.path.join(self.tmpdir.name, "does-not-exist-dir")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            counts = llm_ledger.step_quota_samples(
                conn,
                samples_path=nonexistent_samples,
                samples_archive=nonexistent_archive,
            )
            self.assertEqual(counts["quota_rows"], 0)
            self.assertEqual(counts["quota_pool_rows"], 0)
            self.assertEqual(counts["malformed"], 0)
        finally:
            conn.close()

    def test_quota_malformed_lines_skipped_and_counted(self):
        lines = [
            json.dumps({"ts": "2026-11-20T10:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.1}]}),
            "not a json",
            json.dumps([1, 2, 3]),
            json.dumps({"healthy": 5}),  # missing ts
            json.dumps({"ts": "invalid-iso-date", "healthy": 5}),  # invalid ts
        ]
        with open(self.samples_path, "w") as f:
            for l in lines:
                f.write(l + "\n")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            counts = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(counts["quota_rows"], 1)
            self.assertEqual(counts["quota_pool_rows"], 1)
            self.assertEqual(counts["malformed"], 4)
        finally:
            conn.close()

    def test_run_ingest_integrates_quota_step(self):
        # Test that run_ingest calls quota step and returns merged counts
        line = {"ts": "2026-11-20T10:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.1}]}
        with open(self.samples_path, "w") as f:
            f.write(json.dumps(line) + "\n")

        ret = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
            samples_path=self.samples_path,
            samples_archive=self.samples_archive,
        )
        self.assertEqual(ret["quota_rows"], 1)
        self.assertEqual(ret["new_routes"], 0)
        self.assertEqual(ret["new_requests"], 0)


if __name__ == "__main__":
    unittest.main()
