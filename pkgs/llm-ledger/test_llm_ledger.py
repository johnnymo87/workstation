"""Tests for llm-ledger. Run: python3 pkgs/llm-ledger/test_llm_ledger.py"""

from __future__ import annotations

import datetime
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import time
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
        self.tags_db = os.path.join(self.tmpdir.name, "tags.db")
        with oc_tags.open_store(self.tags_db) as _:
            pass
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
            reqs = {r[0] for r in conn.execute("SELECT request_id FROM requests").fetchall()}
            self.assertEqual(reqs, {"r1", "r2", "r3"})
        finally:
            conn.close()

    def test_inode_reuse_head_sha_mismatch_restarts(self):
        # File 1 has 2 lines
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        line2 = json.dumps({"type": "usage", "ts": 200, "requestId": "r2", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line1)
            f.write(line2)

        orig_ino = os.stat(self.events_path).st_ino
        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret1["new_requests"], 2)

        # Check ingest_state has cfp_head_sha and cfp_head_len
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            state = llm_ledger.get_ingest_state(conn)
            self.assertIn("cfp_head_sha", state)
            self.assertIn("cfp_head_len", state)
            stored_offset = int(state["cfp_offset"])
        finally:
            conn.close()

        # Overwrite file in-place (same inode, size >= stored_offset, but head content different)
        line_diff_1 = json.dumps({"type": "usage", "ts": 300, "requestId": "r_diff_1", "cost": 0.02, "backend": "b"}) + "\n"
        line_diff_2 = json.dumps({"type": "usage", "ts": 400, "requestId": "r_diff_2", "cost": 0.02, "backend": "b"}) + "\n"
        content = (line_diff_1 + line_diff_2).encode("utf-8")
        # Ensure new content is at least as large as stored_offset
        if len(content) < stored_offset:
            content += b" " * (stored_offset - len(content)) + b"\n"

        with open(self.events_path, "r+b") as f:
            f.seek(0)
            f.write(content)
            f.truncate()

        cur_ino = os.stat(self.events_path).st_ino
        self.assertEqual(cur_ino, orig_ino)
        self.assertGreaterEqual(os.stat(self.events_path).st_size, stored_offset)

        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        # Restarted from offset 0, so r_diff_1 and r_diff_2 are ingested without rows lost
        self.assertGreaterEqual(ret2["new_requests"], 2)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            reqs = {r[0] for r in conn.execute("SELECT request_id FROM requests").fetchall()}
            self.assertTrue({"r1", "r2", "r_diff_1", "r_diff_2"}.issubset(reqs))
        finally:
            conn.close()

    def test_inode_reuse_non_newline_at_offset_minus_one_restarts(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        line2 = json.dumps({"type": "usage", "ts": 200, "requestId": "r2", "cost": 0.01, "backend": "b"}) + "\n\n"
        with open(self.events_path, "w") as f:
            f.write(line1)
            f.write(line2)

        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        self.assertEqual(ret1["new_requests"], 2)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            state = llm_ledger.get_ingest_state(conn)
            stored_offset = int(state["cfp_offset"])
        finally:
            conn.close()

        # Mutate the byte at stored_offset - 1 so it is not b"\n", but keep head intact
        with open(self.events_path, "r+b") as f:
            f.seek(stored_offset - 1)
            f.write(b"X\n")
            # Append a new line after offset
            new_line = json.dumps({"type": "usage", "ts": 300, "requestId": "r3", "cost": 0.01, "backend": "b"}) + "\n"
            f.write(new_line.encode("utf-8"))

        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path,
            events_path=self.events_path,
            raw_dir=self.raw_dir,
        )
        # Because byte at offset-1 wasn't \n, it restarts from 0
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            reqs = {r[0] for r in conn.execute("SELECT request_id FROM requests").fetchall()}
            self.assertIn("r1", reqs)
            self.assertIn("r2", reqs)
            self.assertIn("r3", reqs)
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
                "--tags-db", self.tags_db,
            ])
        self.assertEqual(exit_code, 0)
        self.assertIn("routes=1 requests=1", out.getvalue())

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
        finally:
            conn.close()

    def test_run_missing_tags_db_fresh_host_proceeds_with_exit_0(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line1)

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "run",
                "--db", self.db_path,
                "--events", self.events_path,
                "--raw-dir", self.raw_dir,
                "--tags-db", "/nonexistent/tags.db",
            ])
        self.assertEqual(exit_code, 0)
        self.assertEqual(err.getvalue(), "")

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
        finally:
            conn.close()

    def test_run_missing_tags_db_with_manual_rows_warns_skips_snapshot_and_exits_1(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # Seed a manual row in session_program indicating tags were present before
            conn.execute(
                "INSERT INTO session_program VALUES ('ses_prior', 'old-tag', 'manual', 'ses_prior', 'Prior', 100)"
            )
            conn.commit()
        finally:
            conn.close()

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "run",
                "--db", self.db_path,
                "--events", self.events_path,
                "--raw-dir", self.raw_dir,
                "--tags-db", "/nonexistent/tags.db",
            ])
        self.assertEqual(exit_code, 1)
        self.assertIn("tags db not found", err.getvalue())

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # Request was still ingested
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
            # But snapshot was skipped: only the seeded row exists
            self.assertEqual(conn.execute("SELECT count(*) FROM session_program").fetchone()[0], 1)
        finally:
            conn.close()

    def test_run_corrupt_tags_db_warns_skips_snapshot_and_exits_1(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"}) + "\n"
        with open(self.events_path, "w") as f:
            f.write(line1)

        corrupt_tags = os.path.join(self.tmpdir.name, "corrupt_tags.db")
        with open(corrupt_tags, "wb") as f:
            f.write(b"NOT A SQLITE FILE")

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "run",
                "--db", self.db_path,
                "--events", self.events_path,
                "--raw-dir", self.raw_dir,
                "--tags-db", corrupt_tags,
            ])
        self.assertEqual(exit_code, 1)
        self.assertIn("failed to read tags db", err.getvalue())

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM requests").fetchone()[0], 1)
            self.assertEqual(conn.execute("SELECT count(*) FROM session_program").fetchone()[0], 0)
        finally:
            conn.close()

    def test_run_missing_events_file_warns_and_exits_1(self):
        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "run",
                "--db", self.db_path,
                "--events", "/nonexistent/events.jsonl",
                "--raw-dir", self.raw_dir,
            ])
        self.assertEqual(exit_code, 1)
        self.assertIn("events file not found", err.getvalue())

    def test_advisory_warning_keeps_exit_0(self):
        # Create a valid tags.db so tags loading doesn't trigger a fatal warning
        tags_db = os.path.join(self.tmpdir.name, "tags.db")
        with oc_tags.open_store(tags_db) as _:
            pass

        # Goose-shaped sessionId so CfpSessionResolver is constructed
        route_line = json.dumps({"type": "route", "ts": 100, "requestId": "r1", "sessionId": "20261123_1", "model": "m"})
        usage_line = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"})
        with open(self.events_path, "w") as f:
            f.write(route_line + "\n" + usage_line + "\n")

        # Mock CfpSessionResolver to inject a warning. A substring listed in
        # ADVISORY_WARNING_SUBSTRINGS keeps exit 0; the lgtm "rows not counted"
        # warning is NOT advisory (it signals an lgtm schema change).
        injected = ["benign-test-warning: something"]
        orig_resolver = oc_tags.CfpSessionResolver
        def mock_resolver(*args, **kwargs):
            warns = kwargs.get("warnings")
            if warns is not None:
                warns.append(injected[0])
            return orig_resolver(*args, **kwargs)

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with mock.patch("oc_tags.CfpSessionResolver", side_effect=mock_resolver), \
                mock.patch.object(llm_ledger, "ADVISORY_WARNING_SUBSTRINGS", ("benign-test-warning",)):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                exit_code = llm_ledger.main([
                    "run",
                    "--db", self.db_path,
                    "--events", self.events_path,
                    "--raw-dir", self.raw_dir,
                    "--tags-db", tags_db,
                ])
        self.assertEqual(exit_code, 0)
        self.assertIn("benign-test-warning", err.getvalue())
        self.assertFalse(llm_ledger.is_advisory_warning(
            "lgtm goose ledger: 3 row(s) not counted (unknown schema, kind, or timestamp) in /path"))

    def test_fatal_resolver_warning_causes_exit_1(self):
        tags_db = os.path.join(self.tmpdir.name, "tags.db")
        with oc_tags.open_store(tags_db) as _:
            pass

        route_line = json.dumps({"type": "route", "ts": 100, "requestId": "r1", "sessionId": "20261123_1", "model": "m"})
        usage_line = json.dumps({"type": "usage", "ts": 100, "requestId": "r1", "cost": 0.01, "backend": "b"})
        with open(self.events_path, "w") as f:
            f.write(route_line + "\n" + usage_line + "\n")

        orig_resolver = oc_tags.CfpSessionResolver
        def mock_resolver(*args, **kwargs):
            warns = kwargs.get("warnings")
            if warns is not None:
                warns.append("goose sessions not read for cfp join: database disk image is malformed")
            return orig_resolver(*args, **kwargs)

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with mock.patch("oc_tags.CfpSessionResolver", side_effect=mock_resolver):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                exit_code = llm_ledger.main([
                    "run",
                    "--db", self.db_path,
                    "--events", self.events_path,
                    "--raw-dir", self.raw_dir,
                    "--tags-db", tags_db,
                ])
        self.assertEqual(exit_code, 1)
        self.assertIn("goose sessions not read for cfp join", err.getvalue())

    def test_import_events_truncated_gzip_keeps_prior_rows_warns_and_exits_1(self):
        # Create a valid gz stream followed by truncated member
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r-gz-1", "cost": 0.01, "backend": "b"}) + "\n"
        line2 = json.dumps({"type": "usage", "ts": 200, "requestId": "r-gz-2", "cost": 0.01, "backend": "b"}) + "\n"
        valid_gz = gzip.compress((line1 + line2).encode("utf-8"))

        # Append truncated gzip header (first 5 bytes of a new gzip member)
        truncated_gz_path = os.path.join(self.tmpdir.name, "truncated.jsonl.gz")
        with open(truncated_gz_path, "wb") as f:
            f.write(valid_gz)
            f.write(b"\x1f\x8b\x08\x00\x00")  # Incomplete gzip member header

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "import-events",
                truncated_gz_path,
                "--db", self.db_path,
            ])
        self.assertEqual(exit_code, 1)
        self.assertIn("truncated gzip file", err.getvalue())

        # Verify prior rows were kept and committed into DB
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            reqs = {r[0] for r in conn.execute("SELECT request_id FROM requests").fetchall()}
            self.assertEqual(reqs, {"r-gz-1", "r-gz-2"})
        finally:
            conn.close()

    def test_import_events_bad_gzip_file_keeps_prior_rows_warns_and_exits_1(self):
        line1 = json.dumps({"type": "usage", "ts": 100, "requestId": "r-badgz-1", "cost": 0.01, "backend": "b"}) + "\n"
        valid_gz = gzip.compress(line1.encode("utf-8"))

        bad_gz_path = os.path.join(self.tmpdir.name, "bad.jsonl.gz")
        with open(bad_gz_path, "wb") as f:
            f.write(valid_gz)
            f.write(b"NOT_GZIP_BYTES_CORRUPT")

        import io
        import contextlib
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            exit_code = llm_ledger.main([
                "import-events",
                bad_gz_path,
                "--db", self.db_path,
            ])
        self.assertEqual(exit_code, 1)
        self.assertIn("truncated gzip file", err.getvalue())

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            reqs = {r[0] for r in conn.execute("SELECT request_id FROM requests").fetchall()}
            self.assertIn("r-badgz-1", reqs)
        finally:
            conn.close()

    def test_warnings_deduplicated_order_preserving(self):
        # Test that duplicate warnings are deduplicated preserving first-seen order
        import io
        import contextlib

        mock_counts = {
            "new_routes": 0,
            "new_requests": 0,
            "malformed": 0,
            "quota_rows": 0,
            "rechecked": 0,
            "hours_rebuilt": 0,
            "snapshot_rows": 0,
            "warnings": [
                "warning first",
                "warning second",
                "warning first",
                "warning third",
                "warning second",
            ],
        }

        err = io.StringIO()
        out = io.StringIO()
        with mock.patch("llm_ledger.run_ingest", return_value=mock_counts):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                exit_code = llm_ledger.main(["run", "--db", self.db_path])

        self.assertEqual(exit_code, 1)
        expected = "warning: warning first\nwarning: warning second\nwarning: warning third\n"
        self.assertEqual(err.getvalue(), expected)

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
        os.utime(archive_file, (time.time() - 200, time.time() - 200))

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
            os.utime(archive_path, (time.time() - 200, time.time() - 200))

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

    def test_quota_archive_zero_byte_skipped_and_imported_next_run(self):
        os.makedirs(self.samples_archive, exist_ok=True)
        archive_file = os.path.join(self.samples_archive, "quota-samples-until-20260828T222004.jsonl.gz")
        # Write 0-byte file
        with open(archive_file, "wb"):
            pass
        os.utime(archive_file, (time.time() - 200, time.time() - 200))

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            # Not recorded in ingest_state, retried next run
            self.assertEqual(ret1.get("quota_archive_retry", 0), 1)
            self.assertEqual(ret1["quota_rows"], 0)
            val = conn.execute("SELECT count(*) FROM ingest_state").fetchone()[0]
            self.assertEqual(val, 0)

            # Next run: archive is populated with real data
            line = {"ts": "2026-08-28T22:20:00-04:00", "healthy": 3, "accounts": [{"n": "acc1", "u7d": 0.2}]}
            with gzip.open(archive_file, "wt") as f:
                f.write(json.dumps(line) + "\n")
            os.utime(archive_file, (time.time() - 200, time.time() - 200))

            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret2["quota_rows"], 1)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 1)
            ingest_val = conn.execute(
                "SELECT value FROM ingest_state WHERE key = 'quota_archive:quota-samples-until-20260828T222004.jsonl.gz'"
            ).fetchone()
            self.assertIsNotNone(ingest_val)
        finally:
            conn.close()

    def test_quota_archive_truncated_gzip_skipped_and_imported_next_run(self):
        os.makedirs(self.samples_archive, exist_ok=True)
        archive_file = os.path.join(self.samples_archive, "quota-samples-until-20260828T222004.jsonl.gz")
        line1 = {"ts": "2026-08-28T22:15:00-04:00", "healthy": 3, "accounts": [{"n": "acc1", "u7d": 0.1}]}
        line2 = {"ts": "2026-08-28T22:20:00-04:00", "healthy": 3, "accounts": [{"n": "acc1", "u7d": 0.2}]}
        full_bytes = gzip.compress((json.dumps(line1) + "\n" + json.dumps(line2) + "\n").encode("utf-8"))
        # Truncate gzip bytes mid-file
        truncated_bytes = full_bytes[: len(full_bytes) // 2]
        with open(archive_file, "wb") as f:
            f.write(truncated_bytes)
        os.utime(archive_file, (time.time() - 200, time.time() - 200))

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret1.get("quota_archive_retry", 0), 1)
            self.assertEqual(ret1["quota_rows"], 0)
            self.assertEqual(ret1["malformed"], 0)  # NOT counted as malformed lines
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 0)  # transaction rolled back
            self.assertEqual(conn.execute("SELECT count(*) FROM ingest_state").fetchone()[0], 0)

            # Next run: full file appears
            with open(archive_file, "wb") as f:
                f.write(full_bytes)
            os.utime(archive_file, (time.time() - 200, time.time() - 200))

            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            self.assertEqual(ret2["quota_rows"], 2)
            self.assertEqual(ret2["quota_pool_rows"], 2)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 2)
            ingest_val = conn.execute(
                "SELECT value FROM ingest_state WHERE key = 'quota_archive:quota-samples-until-20260828T222004.jsonl.gz'"
            ).fetchone()
            self.assertIsNotNone(ingest_val)
        finally:
            conn.close()

    def test_quota_archive_fresh_mtime_skipped_then_imported(self):
        os.makedirs(self.samples_archive, exist_ok=True)
        archive_file = os.path.join(self.samples_archive, "quota-samples-until-20260828T222004.jsonl.gz")
        line = {"ts": "2026-08-28T22:20:00-04:00", "healthy": 3, "accounts": [{"n": "acc1", "u7d": 0.2}]}
        with gzip.open(archive_file, "wt") as f:
            f.write(json.dumps(line) + "\n")
        # mtime is now (fresh)
        file_mtime = os.stat(archive_file).st_mtime

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # Run at file_mtime + 30s (< 120s old)
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
                now=file_mtime + 30.0,
            )
            self.assertEqual(ret1.get("quota_archive_retry", 0), 1)
            self.assertEqual(ret1["quota_rows"], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM ingest_state").fetchone()[0], 0)

            # Next run at file_mtime + 150s (>= 120s old)
            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
                now=file_mtime + 150.0,
            )
            self.assertEqual(ret2["quota_rows"], 1)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 1)
            ingest_val = conn.execute(
                "SELECT value FROM ingest_state WHERE key = 'quota_archive:quota-samples-until-20260828T222004.jsonl.gz'"
            ).fetchone()
            self.assertIsNotNone(ingest_val)
        finally:
            conn.close()

    def test_quota_live_file_partial_trailing_line_not_lost(self):
        line1 = json.dumps({"ts": "2026-11-20T10:00:00-05:00", "healthy": 5, "accounts": [{"n": "a1", "u7d": 0.1}]})
        line2_part = '{"ts": "2026-11-20T10:05:00-05:00", "healthy": 5'
        with open(self.samples_path, "w") as f:
            f.write(line1 + "\n")
            f.write(line2_part)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            ret1 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            # Line 1 imported, partial line 2 skipped without counting as malformed
            self.assertEqual(ret1["quota_rows"], 1)
            self.assertEqual(ret1["quota_pool_rows"], 1)
            self.assertEqual(ret1["malformed"], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 1)

            # Next run: line 2 completed
            with open(self.samples_path, "a") as f:
                f.write(', "accounts": [{"n": "a1", "u7d": 0.2}]}\n')

            ret2 = llm_ledger.step_quota_samples(
                conn,
                samples_path=self.samples_path,
                samples_archive=self.samples_archive,
            )
            # Line 2 imported
            self.assertEqual(ret2["quota_rows"], 1)
            self.assertEqual(ret2["quota_pool_rows"], 1)
            self.assertEqual(ret2["malformed"], 0)
            self.assertEqual(conn.execute("SELECT count(*) FROM quota_pool").fetchone()[0], 2)
        finally:
            conn.close()

    def test_quota_live_file_oserror_warns_stderr(self):
        import io
        import contextlib
        with open(self.samples_path, "w") as f:
            f.write("dummy\n")
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            err_buf = io.StringIO()
            with contextlib.redirect_stderr(err_buf):
                with mock.patch("builtins.open", side_effect=OSError("disk error")):
                    ret = llm_ledger.step_quota_samples(
                        conn,
                        samples_path=self.samples_path,
                        samples_archive=self.samples_archive,
                    )
            self.assertEqual(ret["quota_rows"], 0)
            self.assertIn("warning: failed to read live quota samples", err_buf.getvalue())
        finally:
            conn.close()


class TestLlmLedgerTask4(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory(prefix="llm-ledger-task4-")
        self.db_path = os.path.join(self.tmpdir.name, "ledger.db")
        self.events_path = os.path.join(self.tmpdir.name, "events.jsonl")
        self.raw_dir = os.path.join(self.tmpdir.name, "raw")
        self.opencode_db = os.path.join(self.tmpdir.name, "opencode.db")
        self.goose_db = os.path.join(self.tmpdir.name, "goose.db")
        self.tags_db = os.path.join(self.tmpdir.name, "tags.db")
        with oc_tags.open_store(self.tags_db) as _:
            pass
        self.lgtm_ledger = os.path.join(self.tmpdir.name, "lgtm.jsonl")
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

    def _create_opencode_db(self, sessions: list[tuple[str, str | None, str | None, str | None]]):
        conn = sqlite3.connect(self.opencode_db)
        conn.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT)")
        conn.executemany("INSERT INTO session VALUES (?, ?, ?, ?)", sessions)
        conn.commit()
        conn.close()

    def _create_goose_db(
        self,
        sessions: list[tuple[str, str | None, str | None, str | None, str | None, str | None]],
        ledger: list[tuple[str, int]] | None = None,
    ):
        conn = sqlite3.connect(self.goose_db)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, working_dir TEXT, "
            "name TEXT, session_type TEXT, recipe_json TEXT)"
        )
        conn.execute("CREATE TABLE IF NOT EXISTS usage_ledger (session_id TEXT, created_timestamp INTEGER)")
        conn.execute("DELETE FROM sessions")
        conn.execute("DELETE FROM usage_ledger")
        # recipe_json column needs to hold JSON if title is extracted via json_extract(recipe_json, '$.title')
        rows = []
        for s in sessions:
            sid, parent, wdir, name, stype, rtitle = s
            r_json = json.dumps({"title": rtitle}) if rtitle is not None else None
            rows.append((sid, parent, wdir, name, stype, r_json))
        conn.executemany("INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?)", rows)
        if ledger:
            conn.executemany("INSERT INTO usage_ledger VALUES (?, ?)", ledger)
        conn.commit()
        conn.close()

    def _write_lgtm_ledger(self, entries: list[dict]):
        with open(self.lgtm_ledger, "w") as f:
            for e in entries:
                f.write(json.dumps(e) + "\n")

    def test_held_lock_exit_zero_no_writes(self):
        import fcntl
        lock_file = os.path.join(os.path.dirname(os.path.abspath(self.db_path)), ".lock")
        os.makedirs(os.path.dirname(lock_file), exist_ok=True)
        fd = open(lock_file, "a")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            # 1. run_ingest should detect lock and not touch DB
            ret = llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path)
            self.assertTrue(ret.get("locked"))
            self.assertFalse(os.path.exists(self.db_path))

            # 2. main(["run", ...]) should return 0
            code = llm_ledger.main(["run", "--db", self.db_path, "--events", self.events_path])
            self.assertEqual(code, 0)
            self.assertFalse(os.path.exists(self.db_path))
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            fd.close()

    def test_rollup_matches_group_by_incremental(self):
        # Multiple runs across several hours
        h1 = 1700000000000 // 3600000 * 3600000
        h2 = h1 + 3600000
        h3 = h1 + 7200000

        events_run1 = [
            {"type": "route", "ts": h1 + 1000, "requestId": "r1", "sessionId": "ses_1", "model": "m1"},
            {"type": "usage", "ts": h1 + 1000, "requestId": "r1", "backend": "b1", "cost": 0.01,
             "usage": {"input": 10, "output": 20, "cacheRead": 5, "cacheWrite": 0}},
            {"type": "route", "ts": h2 + 2000, "requestId": "r2", "sessionId": "ses_2", "model": "m2"},
            {"type": "usage", "ts": h2 + 2000, "requestId": "r2", "backend": "b2", "cost": 0.02,
             "usage": {"input": 15, "output": 25, "cacheRead": 0, "cacheWrite": 5}},
        ]
        with open(self.events_path, "w") as f:
            for ev in events_run1:
                f.write(json.dumps(ev) + "\n")

        ret1 = llm_ledger.run_ingest(
            db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir
        )
        self.assertEqual(ret1["new_requests"], 2)

        # Run 2: more events in h2 and new in h3
        events_run2 = [
            {"type": "route", "ts": h2 + 5000, "requestId": "r3", "sessionId": "ses_2", "model": "m2"},
            {"type": "usage", "ts": h2 + 5000, "requestId": "r3", "backend": "b2", "cost": 0.03,
             "usage": {"input": 20, "output": 30, "cacheRead": 10, "cacheWrite": 0}},
            {"type": "route", "ts": h3 + 1000, "requestId": "r4", "sessionId": "ses_3", "model": "m3"},
            {"type": "usage", "ts": h3 + 1000, "requestId": "r4", "backend": "b1", "cost": 0.04,
             "usage": {"input": 40, "output": 50, "cacheRead": 0, "cacheWrite": 0}},
        ]
        with open(self.events_path, "a") as f:
            for ev in events_run2:
                f.write(json.dumps(ev) + "\n")

        ret2 = llm_ledger.run_ingest(
            db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir
        )
        self.assertEqual(ret2["new_requests"], 2)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            hourly_rows = conn.execute(
                "SELECT hour, attr_key, backend, model, n, input, output, cache_read, cache_write, round(cost_usd, 4) "
                "FROM hourly ORDER BY hour, attr_key, backend, model"
            ).fetchall()
            expected_rows = conn.execute(
                "SELECT (ts / 3600000) * 3600000 AS hr, attr_key, COALESCE(backend, ''), COALESCE(model, ''), "
                "count(*), coalesce(sum(input),0), coalesce(sum(output),0), "
                "coalesce(sum(cache_read),0), coalesce(sum(cache_write),0), round(coalesce(sum(cost_usd),0.0), 4) "
                "FROM requests GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4"
            ).fetchall()
            self.assertEqual(hourly_rows, expected_rows)
            self.assertEqual(len(hourly_rows), 3)  # h1(ses_1), h2(ses_2), h3(ses_3)
        finally:
            conn.close()

    def test_rollup_after_route_fill_in(self):
        h = 1700000000000 // 3600000 * 3600000
        # Usage without route
        usage1 = {"type": "usage", "ts": h + 1000, "requestId": "rf1", "backend": "b1", "cost": 0.05,
                  "usage": {"input": 10, "output": 20, "cacheRead": 0, "cacheWrite": 0}}
        with open(self.events_path, "w") as f:
            f.write(json.dumps(usage1) + "\n")

        llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            h_row = conn.execute("SELECT attr_key, model, n, cost_usd FROM hourly WHERE hour = ?", (h,)).fetchone()
            self.assertEqual(h_row[0], oc_tags.CFP_UNROUTED_TAG)
            self.assertEqual(h_row[1], "")
        finally:
            conn.close()

        # Later route arrives
        route1 = {"type": "route", "ts": h + 1000, "requestId": "rf1", "sessionId": "ses_filled", "model": "opus-model"}
        with open(self.events_path, "a") as f:
            f.write(json.dumps(route1) + "\n")

        llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            h_rows = conn.execute("SELECT attr_key, model, n, cost_usd FROM hourly WHERE hour = ?", (h,)).fetchall()
            self.assertEqual(len(h_rows), 1)
            self.assertEqual(h_rows[0][0], "ses_filled")
            self.assertEqual(h_rows[0][1], "opus-model")

            # Check matches GROUP BY
            expected = conn.execute(
                "SELECT (ts / 3600000) * 3600000, attr_key, COALESCE(backend, ''), COALESCE(model, ''), count(*), "
                "coalesce(sum(input),0), coalesce(sum(output),0), coalesce(sum(cache_read),0), coalesce(sum(cache_write),0), cost_usd "
                "FROM requests GROUP BY 1, 2, 3, 4"
            ).fetchall()
            actual = conn.execute(
                "SELECT hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd FROM hourly"
            ).fetchall()
            self.assertEqual(actual, expected)
        finally:
            conn.close()

    def test_rollup_after_goose_reattribution(self):
        now_ts = 1700000000000
        req_ts = now_ts - 5 * 3600 * 1000
        h = req_ts // 3600000 * 3600000
        sid = "20261120_1"

        self._create_goose_db(
            sessions=[(sid, None, "/tmp", "g-session", "chat", None)],
            ledger=[(sid, req_ts // 1000)],
        )

        # Ingest initially as goose:20261120_1
        route = {"type": "route", "ts": req_ts, "requestId": "rg1", "sessionId": sid, "model": "m"}
        usage = {"type": "usage", "ts": req_ts, "requestId": "rg1", "backend": "v", "cost": 0.05,
                 "usage": {"input": 1, "output": 2, "cacheRead": 0, "cacheWrite": 0}}
        with open(self.events_path, "w") as f:
            f.write(json.dumps(route) + "\n")
            f.write(json.dumps(usage) + "\n")

        llm_ledger.run_ingest(
            db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir,
            goose_db=self.goose_db, now=now_ts / 1000.0,
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            h_row = conn.execute("SELECT attr_key FROM hourly WHERE hour = ?", (h,)).fetchone()
            self.assertEqual(h_row[0], f"goose:{sid}")
        finally:
            conn.close()

        # Later lgtm row appears
        self._write_lgtm_ledger([{
            "v": 1, "key": "k1", "kind": "review", "session": "pr-42",
            "repo": "workstation", "pr": 42,
            "at": datetime.datetime.fromtimestamp(req_ts / 1000, datetime.timezone.utc).isoformat(),
            "costUsd": 0.05,
        }])
        # Note: goose_claim will claim if no usage_ledger in goose within GOOSE_LEDGER_JOIN_MS or lgtm claims it
        # Let's recreate goose_db without the usage_ledger timestamp so lgtm claims it
        self._create_goose_db(sessions=[(sid, None, "/tmp", "g-session", "chat", None)], ledger=[])

        ret = llm_ledger.run_ingest(
            db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir,
            goose_db=self.goose_db, lgtm_ledger=self.lgtm_ledger, now=now_ts / 1000.0,
        )
        self.assertEqual(ret.get("rechecked"), 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            h_row = conn.execute("SELECT attr_key FROM hourly WHERE hour = ?", (h,)).fetchone()
            self.assertEqual(h_row[0], "lgtm-goose:pr-42")

            # Check matches GROUP BY
            expected = conn.execute(
                "SELECT (ts / 3600000) * 3600000, attr_key, COALESCE(backend, ''), COALESCE(model, ''), count(*), "
                "coalesce(sum(input),0), coalesce(sum(output),0), coalesce(sum(cache_read),0), coalesce(sum(cache_write),0), cost_usd "
                "FROM requests GROUP BY 1, 2, 3, 4"
            ).fetchall()
            actual = conn.execute(
                "SELECT hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd FROM hourly"
            ).fetchall()
            self.assertEqual(actual, expected)
        finally:
            conn.close()

    def test_fresh_db_full_rebuild(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        h1 = 1700000000000 // 3600000 * 3600000
        h2 = h1 + 3600000
        conn.execute(
            "INSERT INTO requests VALUES ('r1', ?, 'host', 's1', 'k1', 'b1', 'm1', 1, 2, 0, 0, 0.01, 200, 100)",
            (h1 + 100,)
        )
        conn.execute(
            "INSERT INTO requests VALUES ('r2', ?, 'host', 's2', 'k2', 'b2', 'm2', 3, 4, 0, 0, 0.02, 200, 200)",
            (h2 + 200,)
        )
        conn.commit()
        conn.close()

        # hourly is currently empty
        # Call step_hourly_rollup directly or run_ingest with empty events
        with open(self.events_path, "w") as f:
            pass
        ret = llm_ledger.run_ingest(db_path=self.db_path, events_path=self.events_path, raw_dir=self.raw_dir)
        self.assertEqual(ret.get("hours_rebuilt"), 2)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM hourly").fetchone()[0], 2)
        finally:
            conn.close()

    def test_rebuild_hourly_subcommand(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        h1 = 1700000000000 // 3600000 * 3600000
        conn.execute(
            "INSERT INTO requests VALUES ('r1', ?, 'host', 's1', 'k1', 'b1', 'm1', 1, 2, 0, 0, 0.01, 200, 100)",
            (h1 + 100,)
        )
        conn.commit()
        conn.close()

        code = llm_ledger.main(["rebuild-hourly", "--db", self.db_path])
        self.assertEqual(code, 0)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            self.assertEqual(conn.execute("SELECT count(*) FROM hourly").fetchone()[0], 1)
        finally:
            conn.close()

    def test_snapshot_maps_child_to_root_tag(self):
        self._create_opencode_db([
            ("ses_root", None, "/home/dev/projects/proj", "Root Session Title"),
            ("ses_child", "ses_root", "/home/dev/projects/proj/sub", "Child Session Title"),
        ])
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "ses_root", "proj-alpha")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_child', 'ses_child', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        written = llm_ledger.step_session_program_snapshot(
            conn=conn,
            opencode_db=self.opencode_db,
            goose_db=self.goose_db,
            tags_db=self.tags_db,
            now=1700000000.0,
        )
        self.assertEqual(written, 1)

        row = conn.execute("SELECT attr_key, tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'ses_child'").fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "ses_child")
        self.assertEqual(row[1], "proj-alpha")
        self.assertEqual(row[2], "manual")
        self.assertEqual(row[3], "ses_root")
        self.assertEqual(row[4], "Root Session Title")
        self.assertEqual(row[5], 1700000000000)
        conn.close()

    def test_snapshot_picks_up_retag_next_run(self):
        self._create_opencode_db([
            ("ses_root", None, "/home/dev/projects/proj", "Root"),
        ])
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "ses_root", "tag-v1")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_root', 'ses_root', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        written1 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700000000.0
        )
        self.assertEqual(written1, 1)
        r1 = conn.execute("SELECT tag, updated_at FROM session_program WHERE attr_key = 'ses_root'").fetchone()
        self.assertEqual(r1[0], "tag-v1")
        self.assertEqual(r1[1], 1700000000000)

        # Retag in tags.db
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "ses_root", "tag-v2")

        written2 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700001000.0
        )
        self.assertEqual(written2, 1)
        r2 = conn.execute("SELECT tag, updated_at FROM session_program WHERE attr_key = 'ses_root'").fetchone()
        self.assertEqual(r2[0], "tag-v2")
        self.assertEqual(r2[1], 1700001000000)

        # Run 3: unchanged -> written is 0
        written3 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700002000.0
        )
        self.assertEqual(written3, 0)
        r3 = conn.execute("SELECT tag, updated_at FROM session_program WHERE attr_key = 'ses_root'").fetchone()
        self.assertEqual(r3[1], 1700001000000)
        conn.close()

    def test_snapshot_keeps_deleted_session_row(self):
        self._create_opencode_db([
            ("ses_del", None, "/home/dev/projects/proj", "To Delete"),
        ])
        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_del', 'ses_del', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700000000.0
        )
        r1 = conn.execute("SELECT tag, root, title FROM session_program WHERE attr_key = 'ses_del'").fetchone()
        self.assertIsNotNone(r1)

        # Delete from opencode.db
        oconn = sqlite3.connect(self.opencode_db)
        oconn.execute("DELETE FROM session WHERE id = 'ses_del'")
        oconn.commit()
        oconn.close()

        written = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700001000.0
        )
        self.assertEqual(written, 0)
        r2 = conn.execute("SELECT tag, root, title FROM session_program WHERE attr_key = 'ses_del'").fetchone()
        self.assertEqual(r1, r2)
        conn.close()

    def test_snapshot_absent_ses_without_existing_row_gets_attributed(self):
        # Session not in opencode.db, but tagged in tags.db (like short-lived lgtm sessions)
        self._create_opencode_db([])
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "ses_lgtm_absent", "lgtm-runs")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_lgtm_absent', 'ses_lgtm_absent', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.execute(
            "INSERT INTO requests VALUES ('r2', 1700000000000, 'h', 'ses_untagged_absent', 'ses_untagged_absent', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        written = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700000000.0
        )
        self.assertEqual(written, 2)

        r1 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'ses_lgtm_absent'").fetchone()
        self.assertEqual(r1, ("lgtm-runs", "manual", "ses_lgtm_absent", None))

        r2 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'ses_untagged_absent'").fetchone()
        self.assertEqual(r2, ("auto:no-dir", "auto", "ses_untagged_absent", None))
        conn.close()

    def test_snapshot_absent_ses_with_existing_row_remains_untouched(self):
        self._create_opencode_db([])
        # tags.db has NO entry for ses_prior or ses_prior_root
        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_prior', 'ses_prior', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        # Pre-existing row resolved previously while session existed
        conn.execute(
            "INSERT INTO session_program VALUES ('ses_prior', 'old-tag', 'manual', 'ses_prior_root', 'Prior Title', 1700000000000)"
        )
        conn.commit()

        written = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700001000.0
        )
        self.assertEqual(written, 0)

        r = conn.execute("SELECT tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'ses_prior'").fetchone()
        self.assertEqual(r, ("old-tag", "manual", "ses_prior_root", "Prior Title", 1700000000000))
        conn.close()

    def test_snapshot_absent_ses_with_existing_row_updates_if_retagged(self):
        self._create_opencode_db([])
        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_child', 'ses_child', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.execute(
            "INSERT INTO session_program VALUES ('ses_child', 'tag-v1', 'manual', 'ses_root', 'Prior Title', 1700000000000)"
        )
        conn.commit()

        # Case A: tag_map has entry for row's root ('ses_root')
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "ses_root", "tag-v2")

        written1 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700001000.0
        )
        self.assertEqual(written1, 1)
        r1 = conn.execute("SELECT tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'ses_child'").fetchone()
        self.assertEqual(r1, ("tag-v2", "manual", "ses_root", "Prior Title", 1700001000000))

        # Case B: tag_map has entry for attr_key itself ('ses_child')
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.rm_session_tag(st, "ses_root")
            oc_tags.set_session_tag(st, "ses_child", "tag-v3")

        written2 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700002000.0
        )
        self.assertEqual(written2, 1)
        r2 = conn.execute("SELECT tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'ses_child'").fetchone()
        self.assertEqual(r2, ("tag-v3", "manual", "ses_root", "Prior Title", 1700002000000))

        # Case C: tag_map has same tag -> no update
        written3 = llm_ledger.step_session_program_snapshot(
            conn=conn, opencode_db=self.opencode_db, tags_db=self.tags_db, now=1700003000.0
        )
        self.assertEqual(written3, 0)
        conn.close()

    def test_snapshot_goose_root_tag_and_auto(self):
        self._create_goose_db([
            ("g_root", None, "/home/dev/work", "goose-name", "chat", "Recipe Title"),
            ("g_child", "g_root", "/home/dev/work", "child-name", "chat", None),
        ])
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "goose:g_root", "manual-goose-tag")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'g_child', 'goose:g_child', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        # Subcase A: tags.db has override
        llm_ledger.step_session_program_snapshot(
            conn=conn, goose_db=self.goose_db, tags_db=self.tags_db, now=1700000000.0
        )
        r1 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'goose:g_child'").fetchone()
        self.assertEqual(r1[0], "manual-goose-tag")
        self.assertEqual(r1[1], "manual")
        self.assertEqual(r1[2], "goose:g_root")
        self.assertEqual(r1[3], "Recipe Title")

        # Subcase B: remove override -> auto fallback
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.rm_session_tag(st, "goose:g_root")

        llm_ledger.step_session_program_snapshot(
            conn=conn, goose_db=self.goose_db, tags_db=self.tags_db, now=1700001000.0
        )
        r2 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'goose:g_child'").fetchone()
        expected_auto = oc_tags.goose_auto_key(recipe_title="Recipe Title", name="goose-name", session_type="chat")
        self.assertEqual(r2[0], expected_auto)
        self.assertEqual(r2[1], "auto")
        self.assertEqual(r2[2], "goose:g_root")
        self.assertEqual(r2[3], "Recipe Title")
        conn.close()

    def test_snapshot_lgtm_default_and_override(self):
        with oc_tags.open_store(self.tags_db) as st:
            oc_tags.set_session_tag(st, "lgtm-goose:pr-override", "custom-lgtm-tag")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'sid', 'lgtm-goose:pr-default', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.execute(
            "INSERT INTO requests VALUES ('r2', 1700000000000, 'h', 'sid', 'lgtm-goose:pr-override', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        llm_ledger.step_session_program_snapshot(
            conn=conn, tags_db=self.tags_db, now=1700000000.0
        )

        r_def = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'lgtm-goose:pr-default'").fetchone()
        self.assertEqual(r_def[0], oc_tags.LGTM_LEDGER_TAG)
        self.assertEqual(r_def[1], "manual")
        self.assertEqual(r_def[2], "lgtm-goose:pr-default")
        self.assertIsNone(r_def[3])

        r_ov = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'lgtm-goose:pr-override'").fetchone()
        self.assertEqual(r_ov[0], "custom-lgtm-tag")
        self.assertEqual(r_ov[1], "manual")
        self.assertEqual(r_ov[2], "lgtm-goose:pr-override")
        self.assertIsNone(r_ov[3])
        conn.close()

    def test_snapshot_cfp_keys(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 's', 'cfp:unrouted', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.execute(
            "INSERT INTO requests VALUES ('r2', 1700000000000, 'h', 's', 'cfp:goose-unknown', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.commit()

        llm_ledger.step_session_program_snapshot(conn=conn, tags_db=self.tags_db, now=1700000000.0)

        r1 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'cfp:unrouted'").fetchone()
        self.assertEqual(r1, ("cfp:unrouted", "manual", "cfp:unrouted", None))

        r2 = conn.execute("SELECT tag, source, root, title FROM session_program WHERE attr_key = 'cfp:goose-unknown'").fetchone()
        self.assertEqual(r2, ("cfp:goose-unknown", "manual", "cfp:goose-unknown", None))
        conn.close()

    def test_goose_recheck_window(self):
        now_ts = 1700000000000
        # Request 1: 10h ago (within 72h)
        ts1 = now_ts - 10 * 3600 * 1000
        sid1 = "20261120_1"

        # Request 2: 100h ago (older than 72h)
        ts2 = now_ts - 100 * 3600 * 1000
        sid2 = "20261120_2"

        self._create_goose_db(sessions=[
            (sid1, None, "/tmp", "g1", "chat", None),
            (sid2, None, "/tmp", "g2", "chat", None),
        ])

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', ?, 'h', ?, ?, 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)",
            (ts1, sid1, f"goose:{sid1}")
        )
        conn.execute(
            "INSERT INTO requests VALUES ('r2', ?, 'h', ?, ?, 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)",
            (ts2, sid2, f"goose:{sid2}")
        )
        conn.commit()

        # Both have late lgtm rows
        self._write_lgtm_ledger([
            {
                "v": 1, "key": "k1", "kind": "review", "session": "pr-1",
                "repo": "workstation", "pr": 1,
                "at": datetime.datetime.fromtimestamp(ts1 / 1000, datetime.timezone.utc).isoformat(),
                "costUsd": 0.01,
            },
            {
                "v": 1, "key": "k2", "kind": "review", "session": "pr-2",
                "repo": "workstation", "pr": 2,
                "at": datetime.datetime.fromtimestamp(ts2 / 1000, datetime.timezone.utc).isoformat(),
                "costUsd": 0.01,
            },
        ])

        rechecked, touched_h = llm_ledger.step_goose_recheck(
            conn=conn,
            goose_db=self.goose_db,
            lgtm_ledger=self.lgtm_ledger,
            goose_recheck_hours=72,
            now=now_ts / 1000.0,
        )
        self.assertEqual(rechecked, 1)
        self.assertIn((ts1 // 3600000) * 3600000, touched_h)

        row1 = conn.execute("SELECT attr_key FROM requests WHERE request_id = 'r1'").fetchone()
        row2 = conn.execute("SELECT attr_key FROM requests WHERE request_id = 'r2'").fetchone()
        self.assertEqual(row1[0], "lgtm-goose:pr-1")
        self.assertEqual(row2[0], f"goose:{sid2}")  # Unchanged because > 72h
        conn.close()

    def test_snapshot_db_read_failure_skips_family(self):
        import io
        import contextlib

        # Create a corrupt opencode.db file
        with open(self.opencode_db, "wb") as f:
            f.write(b"this is not a valid sqlite database file!")

        conn = llm_ledger.open_ledger_db(self.db_path)
        conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'ses_existing', 'ses_existing', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        conn.execute(
            "INSERT INTO session_program VALUES ('ses_existing', 'my-tag', 'manual', 'ses_existing', 'Title', 1700000000000)"
        )
        conn.commit()

        err_buf = io.StringIO()
        with contextlib.redirect_stderr(err_buf):
            written = llm_ledger.step_session_program_snapshot(
                conn=conn,
                opencode_db=self.opencode_db,
                goose_db=self.goose_db,
                tags_db=self.tags_db,
                now=1700001000.0,
            )

        self.assertEqual(written, 0)
        self.assertIn("warning: failed to read opencode db", err_buf.getvalue())
        # The existing row is not deleted or modified
        row = conn.execute("SELECT tag, source FROM session_program WHERE attr_key = 'ses_existing'").fetchone()
        self.assertEqual(row, ("my-tag", "manual"))
        conn.close()

    def test_blocking_lock_raises_on_failure(self):
        with mock.patch("fcntl.flock", side_effect=OSError("flock failed")):
            with self.assertRaises(OSError):
                with llm_ledger.LedgerLock(self.db_path, blocking=True):
                    pass

    def test_rollup_explain_query_plan_uses_requests_ts_index(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            h = 1700000000000 // 3600000 * 3600000
            query = """
                EXPLAIN QUERY PLAN
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
            """
            plan = [r[3] for r in conn.execute(query, (h, h + 3600000)).fetchall()]
            # Confirm that requests_ts index is used by query planner
            self.assertTrue(
                any("USING INDEX requests_ts" in step for step in plan),
                f"Expected requests_ts index in plan: {plan}",
            )
        finally:
            conn.close()

    def test_goose_invalid_recipe_json_does_not_drop_family(self):
        # Create goose db with one valid and one corrupt recipe_json
        conn = sqlite3.connect(self.goose_db)
        conn.execute(
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, working_dir TEXT, "
            "name TEXT, session_type TEXT, recipe_json TEXT)"
        )
        conn.execute(
            "INSERT INTO sessions VALUES "
            "('g_good', NULL, '/tmp', 'good-name', 'chat', '{\"title\": \"Good Title\"}'), "
            "('g_bad', NULL, '/tmp', 'bad-name', 'chat', '{invalid json syntax')"
        )
        conn.commit()
        conn.close()

        ledger_conn = llm_ledger.open_ledger_db(self.db_path)
        ledger_conn.execute(
            "INSERT INTO requests VALUES ('r1', 1700000000000, 'h', 'g_good', 'goose:g_good', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        ledger_conn.execute(
            "INSERT INTO requests VALUES ('r2', 1700000000000, 'h', 'g_bad', 'goose:g_bad', 'b', 'm', 1, 1, 0, 0, 0.01, 200, 10)"
        )
        ledger_conn.commit()

        written = llm_ledger.step_session_program_snapshot(
            conn=ledger_conn, goose_db=self.goose_db, tags_db=self.tags_db, now=1700000000.0
        )
        self.assertEqual(written, 2)

        r_good = ledger_conn.execute("SELECT title FROM session_program WHERE attr_key = 'goose:g_good'").fetchone()
        r_bad = ledger_conn.execute("SELECT title FROM session_program WHERE attr_key = 'goose:g_bad'").fetchone()
        self.assertEqual(r_good[0], "Good Title")
        # In bad JSON, recipe_json title is NULL, but fallback to name is 'bad-name'
        self.assertEqual(r_bad[0], "bad-name")
        ledger_conn.close()

    def test_import_events_no_goose_recheck_hours_flag(self):
        # --goose-recheck-hours was removed from import-events
        with self.assertRaises(SystemExit):
            llm_ledger.main(["import-events", "dummy.jsonl", "--goose-recheck-hours", "48"])

    def test_quota_outlook_cli_success(self):
        """llm-ledger quota-outlook prints valid JSON contract, exits 0, acquires no lock."""
        conn = sqlite3.connect(self.db_path)
        conn.execute("""CREATE TABLE quota_watch_runs (
            ts INTEGER PRIMARY KEY,
            h0 REAL,
            burn_h REAL,
            burn_6h REAL,
            burn_24h REAL,
            spill_6h REAL,
            spill_24h REAL,
            k REAL,
            zero_h REAL,
            vertex_usd REAL,
            next_refill_ts INTEGER,
            next_refill_amt REAL,
            pool_n INTEGER,
            source TEXT DEFAULT 'live',
            verdict TEXT
        )""")
        ts = int(time.time() * 1000) - 60000  # 60s ago (fresh)
        conn.execute("""INSERT INTO quota_watch_runs (
            ts, h0, burn_h, zero_h, vertex_usd, next_refill_ts, next_refill_amt, pool_n, source, verdict
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", (
            ts, 1.5, 0.02, 0.0, 10.0, ts + 3600000, 0.95, 1, "live", "ample"
        ))
        conn.commit()
        conn.close()

        import io
        import contextlib
        import json
        out_buf = io.StringIO()
        with contextlib.redirect_stdout(out_buf):
            code = llm_ledger.main(["quota-outlook", "--db", self.db_path])

        self.assertEqual(code, 0)
        data = json.loads(out_buf.getvalue().strip())
        expected_keys = {
            "verdict", "ts", "age_s", "h0", "burn_h", "zero_h",
            "next_refill_ts", "next_refill_amt", "line"
        }
        self.assertEqual(set(data.keys()), expected_keys)
        self.assertEqual(data["verdict"], "ample")
        self.assertNotIn("error", data)
        self.assertNotIn("vertex_usd", data)
        self.assertFalse(os.path.exists(self.db_path + ".lock"))

    def test_quota_outlook_cli_nonexistent_db(self):
        """llm-ledger quota-outlook on nonexistent DB prints unknown JSON, exits 0, does not create file."""
        nonexistent_path = os.path.join(self.tmpdir.name, "nonexistent.db")
        import io
        import contextlib
        import json
        out_buf = io.StringIO()
        with contextlib.redirect_stdout(out_buf):
            code = llm_ledger.main(["quota-outlook", "--db", nonexistent_path])

        self.assertEqual(code, 0)
        data = json.loads(out_buf.getvalue().strip())
        expected_keys = {
            "verdict", "ts", "age_s", "h0", "burn_h", "zero_h",
            "next_refill_ts", "next_refill_amt", "line", "error"
        }
        self.assertEqual(set(data.keys()), expected_keys)
        self.assertEqual(data["verdict"], "unknown")
        self.assertIn("error", data)
        self.assertFalse(os.path.exists(nonexistent_path))

    def test_quota_outlook_cli_default_db(self):
        """llm-ledger quota-outlook with no --db uses DEFAULT_DB."""
        conn = sqlite3.connect(self.db_path)
        conn.execute("""CREATE TABLE quota_watch_runs (
            ts INTEGER PRIMARY KEY,
            h0 REAL,
            burn_h REAL,
            burn_6h REAL,
            burn_24h REAL,
            spill_6h REAL,
            spill_24h REAL,
            k REAL,
            zero_h REAL,
            vertex_usd REAL,
            next_refill_ts INTEGER,
            next_refill_amt REAL,
            pool_n INTEGER,
            source TEXT DEFAULT 'live',
            verdict TEXT
        )""")
        ts = int(time.time() * 1000) - 60000
        conn.execute("""INSERT INTO quota_watch_runs (
            ts, h0, burn_h, zero_h, vertex_usd, next_refill_ts, next_refill_amt, pool_n, source, verdict
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", (
            ts, 1.5, 0.02, 0.0, 10.0, ts + 3600000, 0.95, 1, "live", "ample"
        ))
        conn.commit()
        conn.close()

        import io
        import contextlib
        import json
        out_buf = io.StringIO()
        with mock.patch.object(llm_ledger, "DEFAULT_DB", self.db_path):
            with contextlib.redirect_stdout(out_buf):
                code = llm_ledger.main(["quota-outlook"])

        self.assertEqual(code, 0)
        data = json.loads(out_buf.getvalue().strip())
        self.assertEqual(data["verdict"], "ample")

    def test_quota_outlook_cli_broken_pipe(self):
        """llm-ledger quota-outlook catches BrokenPipeError on write/flush and returns 0."""
        with mock.patch.object(sys.stdout, "flush", side_effect=BrokenPipeError):
            code = llm_ledger.main(["quota-outlook", "--db", self.db_path])
            self.assertEqual(code, 0)

    def test_quota_outlook_cli_json_error_fallback(self):
        """llm-ledger quota-outlook falls back to inline unknown dict if json serialization fails."""
        import quota_watch
        import io
        import contextlib
        import json
        # Mock outlook to return a dict containing float('nan') which raises ValueError with allow_nan=False
        bad_dict = {
            "verdict": "ample",
            "ts": 1795455600000,
            "age_s": 100,
            "h0": float("nan"),
            "burn_h": None,
            "zero_h": None,
            "next_refill_ts": None,
            "next_refill_amt": None,
            "line": "some line",
        }
        out_buf = io.StringIO()
        with mock.patch.object(quota_watch, "outlook", return_value=bad_dict):
            with contextlib.redirect_stdout(out_buf):
                code = llm_ledger.main(["quota-outlook", "--db", self.db_path])

        self.assertEqual(code, 0)
        data = json.loads(out_buf.getvalue().strip())
        self.assertEqual(data["verdict"], "unknown")
        self.assertIn("error", data)
        self.assertIn("quota@", data["line"])

    def _remote_json(self, verdict="tight"):
        import json
        path = os.path.join(self.tmpdir.name, "remote.json")
        with open(path, "w") as f:
            json.dump({"verdict": verdict, "ts": int(time.time() * 1000) - 60000, "h0": 0.4,
                       "burn_h": 0.03, "zero_h": 3.0, "next_refill_ts": None,
                       "next_refill_amt": None, "line": "x"}, f)
        return path

    def _run_outlook(self, argv, env=None):
        import io
        import contextlib
        import json
        out_buf = io.StringIO()
        with mock.patch.dict(os.environ, env or {}, clear=False):
            if env is None or "LLM_LEDGER_OUTLOOK_JSON" not in env:
                os.environ.pop("LLM_LEDGER_OUTLOOK_JSON", None)
            with contextlib.redirect_stdout(out_buf):
                code = llm_ledger.main(argv)
        self.assertEqual(code, 0)
        return json.loads(out_buf.getvalue().strip())

    def test_quota_outlook_cli_from_json(self):
        """--from-json reads a published outlook instead of a ledger DB."""
        path = self._remote_json("tight")
        data = self._run_outlook(["quota-outlook", "--from-json", path])
        self.assertEqual(data["verdict"], "tight")
        self.assertIn("TIGHT", data["line"])

    def test_quota_outlook_cli_resolution_explicit_db_wins_over_env(self):
        """Explicit --db wins over LLM_LEDGER_OUTLOOK_JSON."""
        path = self._remote_json("dry")
        nonexistent = os.path.join(self.tmpdir.name, "nonexistent.db")
        data = self._run_outlook(["quota-outlook", "--db", nonexistent],
                                 env={"LLM_LEDGER_OUTLOOK_JSON": path})
        self.assertEqual(data["verdict"], "unknown")
        self.assertFalse(os.path.exists(nonexistent))

    def test_quota_outlook_cli_resolution_env_wins_over_default(self):
        """LLM_LEDGER_OUTLOOK_JSON wins over default DB and default file."""
        path = self._remote_json("dry")
        with mock.patch.object(llm_ledger, "DEFAULT_DB", self.db_path):
            data = self._run_outlook(["quota-outlook"], env={"LLM_LEDGER_OUTLOOK_JSON": path})
        self.assertEqual(data["verdict"], "dry")

    def test_quota_outlook_cli_resolution_db_present(self):
        """When DB is present, default resolution uses DB."""
        conn = sqlite3.connect(self.db_path)
        conn.execute("""CREATE TABLE IF NOT EXISTS quota_watch_runs (
            ts INTEGER PRIMARY KEY, h0 REAL, burn_h REAL, zero_h REAL,
            next_refill_ts INTEGER, next_refill_amt REAL, source TEXT DEFAULT 'live', verdict TEXT
        )""")
        ts = int(time.time() * 1000) - 10000
        conn.execute("INSERT OR REPLACE INTO quota_watch_runs (ts, h0, burn_h, zero_h, source, verdict) VALUES (?, 1.2, 0.01, 0.0, 'live', 'ample')", (ts,))
        conn.commit()
        conn.close()

        with mock.patch.object(llm_ledger, "DEFAULT_DB", self.db_path):
            data = self._run_outlook(["quota-outlook"])
        self.assertEqual(data["verdict"], "ample")

    def test_quota_outlook_cli_resolution_db_absent_uses_default_file(self):
        """When DEFAULT_DB is absent, default resolution uses DEFAULT_OUTLOOK_JSON."""
        absent_db = os.path.join(self.tmpdir.name, "absent.db")
        default_file = os.path.join(self.tmpdir.name, "default_outlook.json")
        with open(default_file, "w") as f:
            json.dump({"verdict": "ample", "ts": int(time.time() * 1000) - 60000, "h0": 1.5,
                       "burn_h": 0.02, "zero_h": 0.0, "next_refill_ts": None,
                       "next_refill_amt": None, "line": "quota line"}, f)

        with mock.patch.object(llm_ledger, "DEFAULT_DB", absent_db), \
             mock.patch.object(llm_ledger, "DEFAULT_OUTLOOK_JSON", default_file):
            data = self._run_outlook(["quota-outlook"])
        self.assertEqual(data["verdict"], "ample")
        self.assertIn("AMPLE", data["line"])

    def test_quota_outlook_cli_missing_file_error(self):
        """Missing published outlook file returns unknown with expected error message."""
        absent_json = os.path.join(self.tmpdir.name, "nonexistent_outlook.json")
        data = self._run_outlook(["quota-outlook", "--from-json", absent_json])
        self.assertEqual(data["verdict"], "unknown")
        self.assertEqual(data["error"], f"no published outlook at {absent_json}")
        self.assertIn("quota@", data["line"])

        absent_db = os.path.join(self.tmpdir.name, "absent.db")
        with mock.patch.object(llm_ledger, "DEFAULT_DB", absent_db), \
             mock.patch.object(llm_ledger, "DEFAULT_OUTLOOK_JSON", absent_json):
            data_def = self._run_outlook(["quota-outlook"])
        self.assertEqual(data_def["verdict"], "unknown")
        self.assertEqual(data_def["error"], f"no published outlook at {absent_json}")


class TestImportRemote(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory(prefix="llm-ledger-remote-")
        self.db_path = os.path.join(self.tmpdir.name, "ledger.db")
        self.repo_dir = os.path.join(self.tmpdir.name, "quota-telemetry")
        os.makedirs(self.repo_dir, exist_ok=True)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_schema_remote_tables(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            tables = {
                r[0]
                for r in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                ).fetchall()
            }
            self.assertIn("remote_hourly", tables)
            self.assertIn("remote_hosts", tables)
        finally:
            conn.close()

    def test_price_remote(self):
        # claude-opus-5-5: (4, 20, 0.2, 5.0) in $/MTok
        # input=46905, output=192940, cache_read=52539503, cw5m=3954596, cw1h=0
        # 46905*4 + 192940*20 + 52539503*0.2 + 3954596*5.0 = 34327300.6 / 1e6 = 34.3273006
        cost = llm_ledger.price_remote(
            "claude-opus-5-5",
            input_tokens=46905,
            output=192940,
            cache_read=52539503,
            cw5m=3954596,
            cw1h=0,
        )
        self.assertIsNotNone(cost)
        assert cost is not None
        self.assertAlmostEqual(cost, 34.3273006, places=6)

        # Suffix stripping: claude-opus-5-5@20250219
        cost_suffixed = llm_ledger.price_remote(
            "claude-opus-5-5@20250219",
            input_tokens=46905,
            output=192940,
            cache_read=52539503,
            cw5m=3954596,
            cw1h=0,
        )
        self.assertIsNotNone(cost_suffixed)
        assert cost_suffixed is not None
        self.assertAlmostEqual(cost_suffixed, 34.3273006, places=6)

        # 1h write rate is 2x input rate: claude-opus-5-5 input rate is 4 $/MTok -> 1h rate is 8 $/MTok
        cost_1h = llm_ledger.price_remote(
            "claude-opus-5-5",
            input_tokens=0,
            output=0,
            cache_read=0,
            cw5m=0,
            cw1h=1_000_000,
        )
        self.assertIsNotNone(cost_1h)
        assert cost_1h is not None
        self.assertAlmostEqual(cost_1h, 8.0, places=6)

        # Unknown model -> None
        self.assertIsNone(
            llm_ledger.price_remote(
                "claude-fable-5-2",
                input_tokens=100,
                output=100,
                cache_read=0,
                cw5m=0,
                cw1h=0,
            )
        )

    def test_ledger_lock_timeout(self):
        with llm_ledger.LedgerLock(self.db_path, blocking=True):
            t0 = time.monotonic()
            with self.assertRaises(TimeoutError):
                with llm_ledger.LedgerLock(self.db_path, timeout_s=0.2):
                    pass
            elapsed = time.monotonic() - t0
            self.assertGreaterEqual(elapsed, 0.2)

    def test_import_remote_first_import_and_prices_opus(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        # Week 48 of 2026 starts 2026-11-23T00:00Z
        row = {
            "account": "user@example.com",
            "cache_read": 52539503,
            "cache_write_1h": 0,
            "cache_write_5m": 3954596,
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "input": 46905,
            "model": "claude-opus-5-5",
            "output": 192940,
            "requests": 319,
            "split": True,
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["files"], 1)
        self.assertEqual(res["rows"], 1)
        self.assertEqual(res["malformed"], 0)
        self.assertEqual(res["unpriced"], 0)
        self.assertEqual(res["dupes"], 0)
        self.assertEqual(res["hosts"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            r = conn.execute(
                "SELECT host, hour, account, backend, model, requests, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd "
                "FROM remote_hourly"
            ).fetchone()
            self.assertEqual(r[0], "devbox")
            self.assertEqual(r[1], 1795392000000)  # 2026-11-23T00:00:00Z
            self.assertEqual(r[2], "user@example.com")
            self.assertEqual(r[3], "max")
            self.assertEqual(r[4], "claude-opus-5-5")
            self.assertEqual(r[5], 319)
            self.assertEqual(r[6], 46905)
            self.assertEqual(r[7], 192940)
            self.assertEqual(r[8], 52539503)
            self.assertEqual(r[9], 3954596)
            self.assertEqual(r[10], 0)
            self.assertAlmostEqual(r[11], 34.3273006, places=6)
        finally:
            conn.close()

    def test_import_remote_reimport_unchanged_file(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        row = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "model": "claude-opus-5-5",
            "requests": 1,
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        res1 = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res1["files"], 1)

        # Re-import unchanged file
        res2 = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res2["files"], 0)
        self.assertEqual(res2["rows"], 0)

    def test_import_remote_changed_file_replaces_week(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        # Week 48: 2026-11-23 to 2026-11-29
        # Week 49: 2026-11-30 to 2026-12-06
        w48_row1 = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "model": "claude-opus-5-5",
            "requests": 10,
        }
        w49_row = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-30T00:00Z",
            "model": "claude-opus-5-5",
            "requests": 20,
        }
        w48_path = os.path.join(devbox_dir, "2026-W48.jsonl")
        w49_path = os.path.join(devbox_dir, "2026-W49.jsonl")
        with open(w48_path, "w") as f:
            f.write(json.dumps(w48_row1) + "\n")
        with open(w49_path, "w") as f:
            f.write(json.dumps(w49_row) + "\n")

        llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )

        # Now change W48: replace with a different row in W48
        w48_row2 = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T01:00Z",
            "model": "claude-sonnet-5-5",
            "requests": 99,
        }
        with open(w48_path, "w") as f:
            f.write(json.dumps(w48_row2) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["files"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            w48_rows = conn.execute(
                "SELECT model, requests FROM remote_hourly WHERE hour >= 1795392000000 AND hour < 1795996800000"
            ).fetchall()
            self.assertEqual(w48_rows, [("claude-sonnet-5-5", 99)])

            # W49 is intact
            w49_rows = conn.execute(
                "SELECT model, requests FROM remote_hourly WHERE hour >= 1795996800000"
            ).fetchall()
            self.assertEqual(w49_rows, [("claude-opus-5-5", 20)])
        finally:
            conn.close()

    def test_import_remote_own_host_skipped(self):
        cloudbox_dir = os.path.join(self.repo_dir, "cloudbox")
        os.makedirs(cloudbox_dir, exist_ok=True)
        with open(os.path.join(cloudbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps({
                "account": "user@example.com",
                "host": "cloudbox",
                "hour_utc": "2026-11-23T00:00Z",
                "model": "claude-opus-5-5",
            }) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["files"], 0)
        self.assertEqual(res["hosts"], 0)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            count = conn.execute("SELECT count(*) FROM remote_hourly").fetchone()[0]
            self.assertEqual(count, 0)
        finally:
            conn.close()

    def test_import_remote_missing_backend_and_null_account(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        row = {
            "account": None,
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "model": "claude-opus-5-5",
            # backend missing
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            r = conn.execute("SELECT account, backend FROM remote_hourly").fetchone()
            self.assertEqual(r[0], "")
            self.assertEqual(r[1], "max")
        finally:
            conn.close()

    def test_import_remote_unknown_model_unpriced(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        row = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "model": "unknown-model-xyz",
            "input": 1000,
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["rows"], 1)
        self.assertEqual(res["unpriced"], 1)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            cost = conn.execute("SELECT cost_usd FROM remote_hourly").fetchone()[0]
            self.assertIsNone(cost)
        finally:
            conn.close()

    def test_import_remote_cost_usd_preserved(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        row = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T00:00Z",
            "model": "claude-opus-5-5",
            "cost_usd": 12.34,
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["unpriced"], 0)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            cost = conn.execute("SELECT cost_usd FROM remote_hourly").fetchone()[0]
            self.assertAlmostEqual(cost, 12.34, places=4)
        finally:
            conn.close()

    def test_import_remote_malformed_lines_and_dupes(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        lines = [
            "not a json line",
            json.dumps({"host": "otherhost", "hour_utc": "2026-11-23T00:00Z", "model": "m"}),  # host mismatch
            json.dumps({"host": "devbox", "hour_utc": "invalid-hour", "model": "m"}),            # bad hour
            json.dumps({"host": "devbox", "hour_utc": "2026-11-15T00:00Z", "model": "m"}),      # outside W48 week
            json.dumps({
                "account": "user@example.com",
                "host": "devbox",
                "hour_utc": "2026-11-23T00:00Z",
                "backend": "max",
                "model": "claude-opus-5-5",
                "requests": 1,
            }),
            # Duplicate PK (same host, hour, account, backend, model) with requests=2
            json.dumps({
                "account": "user@example.com",
                "host": "devbox",
                "hour_utc": "2026-11-23T00:00Z",
                "backend": "max",
                "model": "claude-opus-5-5",
                "requests": 2,
            }),
        ]
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write("\n".join(lines) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["malformed"], 4)
        self.assertEqual(res["dupes"], 1)
        self.assertEqual(res["rows"], 2)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            reqs = conn.execute("SELECT requests FROM remote_hourly").fetchall()
            self.assertEqual(reqs, [(2,)])
        finally:
            conn.close()

    def test_import_remote_watermark(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        row = {
            "account": "user@example.com",
            "host": "devbox",
            "hour_utc": "2026-11-23T10:00Z",
            "model": "claude-opus-5-5",
        }
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps(row) + "\n")

        watermark = {"host": "devbox", "hour_utc": "2026-11-23T21:00Z"}
        with open(os.path.join(devbox_dir, "_exported_through.json"), "w") as f:
            f.write(json.dumps(watermark) + "\n")

        llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
            now_ms=1795455600000,
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            r = conn.execute("SELECT host, first_hour, exported_through, imported_at FROM remote_hosts").fetchone()
            self.assertEqual(r[0], "devbox")
            # first_hour: 2026-11-23T10:00Z -> 1795428000000
            self.assertEqual(r[1], 1795428000000)
            # exported_through: 2026-11-23T21:00Z (1795467600000) + 3600000 -> 1795471200000
            self.assertEqual(r[2], 1795467600000 + 3600000)
            self.assertEqual(r[3], 1795455600000)
        finally:
            conn.close()

    def test_ensure_fleet_objects_view(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            # Seed hourly (local)
            conn.execute(
                "INSERT INTO hourly (hour, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd) "
                "VALUES (100, 'ses_loc', 'vertex', 'claude-opus-5-5', 1, 10, 20, 30, 40, 0.5)"
            )
            # Seed remote_hourly
            conn.execute(
                "INSERT INTO remote_hourly (host, hour, account, backend, model, requests, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd) "
                "VALUES ('devbox', 100, 'user@example.com', 'max', 'claude-opus-5-5', 2, 50, 60, 70, 80, 20, 1.5)"
            )
            conn.commit()

            llm_ledger.ensure_fleet_objects(conn, local_host="cloudbox")

            rows = conn.execute(
                "SELECT hour, host, attr_key, backend, model, n, input, output, cache_read, cache_write, cost_usd "
                "FROM fleet_hourly ORDER BY attr_key"
            ).fetchall()
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0], (100, "devbox", "fleet:devbox", "max", "claude-opus-5-5", 2, 50, 60, 70, 100, 1.5))
            self.assertEqual(rows[1], (100, "cloudbox", "ses_loc", "vertex", "claude-opus-5-5", 1, 10, 20, 30, 40, 0.5))

            # View not recreated when SQL unchanged
            initial_sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='view' AND name='fleet_hourly'").fetchone()[0]
            stmts: list[str] = []
            conn.set_trace_callback(stmts.append)
            try:
                llm_ledger.ensure_fleet_objects(conn, local_host="cloudbox")
                self.assertFalse(any("DROP VIEW" in s for s in stmts))
            finally:
                conn.set_trace_callback(None)
            final_sql = conn.execute("SELECT sql FROM sqlite_master WHERE type='view' AND name='fleet_hourly'").fetchone()[0]
            self.assertEqual(initial_sql, final_sql)
        finally:
            conn.close()

    def test_ensure_fleet_objects_session_program_survives_snapshot(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            conn.execute(
                "INSERT INTO remote_hosts (host, first_hour, exported_through, imported_at) "
                "VALUES ('devbox', 100, 200, 300)"
            )
            conn.commit()

            llm_ledger.ensure_fleet_objects(conn, local_host="cloudbox", now_ms=500)

            sp_row = conn.execute(
                "SELECT attr_key, tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'fleet:devbox'"
            ).fetchone()
            self.assertEqual(sp_row, ("fleet:devbox", "fleet:devbox", "fleet", None, "devbox (all usage)", 500))

            # Run step_session_program_snapshot: fleet:devbox must survive untouched
            llm_ledger.step_session_program_snapshot(conn, now=1000)

            sp_row_after = conn.execute(
                "SELECT attr_key, tag, source, root, title, updated_at FROM session_program WHERE attr_key = 'fleet:devbox'"
            ).fetchone()
            self.assertEqual(sp_row_after, ("fleet:devbox", "fleet:devbox", "fleet", None, "devbox (all usage)", 500))
        finally:
            conn.close()

    def test_import_remote_cli_missing_repo_and_success(self):
        # Missing repo dir -> exit 1 with message
        bad_dir = os.path.join(self.tmpdir.name, "does-not-exist")
        import io
        import contextlib
        err_buf = io.StringIO()
        with contextlib.redirect_stderr(err_buf):
            code = llm_ledger.main(["import-remote", "--repo", bad_dir, "--db", self.db_path])
        self.assertEqual(code, 1)
        self.assertIn("repo dir not found", err_buf.getvalue())

        # Success -> prints formatted counts
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps({
                "account": "user@example.com",
                "host": "devbox",
                "hour_utc": "2026-11-23T00:00Z",
                "model": "claude-opus-5-5",
            }) + "\n")

        out_buf = io.StringIO()
        with contextlib.redirect_stdout(out_buf):
            code = llm_ledger.main(["import-remote", "--repo", self.repo_dir, "--db", self.db_path, "--host", "cloudbox"])
        self.assertEqual(code, 0)
        self.assertIn("import-remote files=1 rows=1 malformed=0 unpriced=0", out_buf.getvalue())

    def test_import_remote_local_host_default(self):
        # When local_host is empty or None, it defaults to socket.gethostname()
        import socket
        my_host = socket.gethostname()
        my_host_dir = os.path.join(self.repo_dir, my_host)
        os.makedirs(my_host_dir, exist_ok=True)
        with open(os.path.join(my_host_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps({
                "account": "user@example.com",
                "host": my_host,
                "hour_utc": "2026-11-23T00:00Z",
                "model": "claude-opus-5-5",
            }) + "\n")

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="",
        )
        self.assertEqual(res["files"], 0)
        self.assertEqual(res["hosts"], 0)

    def test_import_remote_watermark_host_mismatch_ignored(self):
        devbox_dir = os.path.join(self.repo_dir, "devbox")
        os.makedirs(devbox_dir, exist_ok=True)
        with open(os.path.join(devbox_dir, "2026-W48.jsonl"), "w") as f:
            f.write(json.dumps({
                "account": "user@example.com",
                "host": "devbox",
                "hour_utc": "2026-11-23T00:00Z",
                "model": "claude-opus-5-5",
            }) + "\n")

        # Watermark has host "wrongbox" which differs from dir name "devbox"
        watermark = {"host": "wrongbox", "hour_utc": "2026-11-23T21:00Z"}
        with open(os.path.join(devbox_dir, "_exported_through.json"), "w") as f:
            f.write(json.dumps(watermark) + "\n")

        llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            r = conn.execute("SELECT exported_through FROM remote_hosts WHERE host='devbox'").fetchone()
            self.assertIsNotNone(r)
            self.assertIsNone(r[0])
        finally:
            conn.close()

    def test_import_remote_stray_dir_ignored(self):
        # docs/ dir with non-week file and empty/ dir
        docs_dir = os.path.join(self.repo_dir, "docs")
        os.makedirs(docs_dir, exist_ok=True)
        with open(os.path.join(docs_dir, "README.md"), "w") as f:
            f.write("Some documentation\n")

        empty_dir = os.path.join(self.repo_dir, "empty")
        os.makedirs(empty_dir, exist_ok=True)

        res = llm_ledger.import_remote(
            db_path=self.db_path,
            repo_dir=self.repo_dir,
            local_host="cloudbox",
        )
        self.assertEqual(res["hosts"], 0)

        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            hosts = conn.execute("SELECT host FROM remote_hosts").fetchall()
            self.assertEqual(hosts, [])
            sp_fleet = conn.execute("SELECT attr_key FROM session_program WHERE attr_key LIKE 'fleet:%'").fetchall()
            self.assertEqual(sp_fleet, [])
        finally:
            conn.close()

    def test_ensure_fleet_objects_session_program_updated_at_not_bumped_when_unchanged(self):
        conn = llm_ledger.open_ledger_db(self.db_path)
        try:
            conn.execute(
                "INSERT INTO remote_hosts (host, first_hour, exported_through, imported_at) "
                "VALUES ('devbox', 100, 200, 300)"
            )
            conn.commit()

            llm_ledger.ensure_fleet_objects(conn, local_host="cloudbox", now_ms=1000)
            row1 = conn.execute(
                "SELECT updated_at FROM session_program WHERE attr_key = 'fleet:devbox'"
            ).fetchone()
            self.assertEqual(row1[0], 1000)

            # Second call at later now_ms: updated_at must NOT be bumped because row is unchanged
            llm_ledger.ensure_fleet_objects(conn, local_host="cloudbox", now_ms=2000)
            row2 = conn.execute(
                "SELECT updated_at FROM session_program WHERE attr_key = 'fleet:devbox'"
            ).fetchone()
            self.assertEqual(row2[0], 1000)
        finally:
            conn.close()

    def test_ledger_lock_timeout_closes_fd_on_base_exception(self):
        with llm_ledger.LedgerLock(self.db_path, blocking=True):
            lock = llm_ledger.LedgerLock(self.db_path, timeout_s=5.0)
            with mock.patch("time.sleep", side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    with lock:
                        pass
            self.assertIsNone(lock.fd)


if __name__ == "__main__":
    unittest.main()
