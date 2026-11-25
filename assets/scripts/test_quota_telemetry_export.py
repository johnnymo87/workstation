#!/usr/bin/env python3
"""Unit tests for assets/scripts/quota-telemetry-export.py."""

import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT_PATH = REPO_ROOT / "assets" / "scripts" / "quota-telemetry-export.py"

loader = importlib.machinery.SourceFileLoader("quota_telemetry_export", str(SCRIPT_PATH))
spec = importlib.util.spec_from_loader("quota_telemetry_export", loader)
assert spec is not None
qte = importlib.util.module_from_spec(spec)
loader.exec_module(qte)

for p in (REPO_ROOT / "pkgs" / "llm-ledger", REPO_ROOT / "pkgs" / "oc-tags"):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))
import llm_ledger  # noqa: E402


def _ms(iso_str: str) -> int:
    return int(dt.datetime.fromisoformat(iso_str.replace("Z", "+00:00")).timestamp() * 1000)


class TestAggregateCfpEvents(unittest.TestCase):
    def setUp(self):
        self.now = dt.datetime(2026, 11, 24, 15, 30, tzinfo=dt.timezone.utc)
        self.since = dt.datetime(2026, 11, 23, 0, 0, tzinfo=dt.timezone.utc)

    def test_joins_route_usage_filters_max_and_aggregates_cash(self):
        lines = [
            # In-order vertex request
            json.dumps({"type": "route", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "model": "claude-opus-5-5"}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "backend": "vertex",
                        "cost": 1.25, "usage": {"input": 100, "output": 50, "cacheRead": 1000, "cacheWrite": 200}}),
            # Usage-before-route (out of order) in same hour/backend/model
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:45:00Z"), "requestId": "r2", "backend": "vertex",
                        "cost": 0.75, "usage": {"input": 200, "output": 25, "cacheRead": 500, "cacheWrite": 300}}),
            json.dumps({"type": "route", "ts": _ms("2026-11-24T13:45:00Z"), "requestId": "r2", "model": "claude-opus-5-5"}),
            # Max request must be excluded (already exported from teamclaude usage.jsonl)
            json.dumps({"type": "route", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "r3", "model": "claude-opus-5-5"}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "r3", "backend": "max",
                        "cost": 5.0, "usage": {"input": 999, "output": 999, "cacheRead": 0, "cacheWrite": 0}}),
            # agy cash backend in another hour
            json.dumps({"type": "route", "ts": _ms("2026-11-24T14:05:00Z"), "requestId": "r4", "model": "claude-sonnet-5-5"}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T14:05:00Z"), "requestId": "r4", "backend": "agy",
                        "cost": 0.42, "usage": {"input": 10, "output": 20, "cacheRead": 30, "cacheWrite": 40}}),
            # Current incomplete hour (15:00Z) must be excluded
            json.dumps({"type": "route", "ts": _ms("2026-11-24T15:05:00Z"), "requestId": "r5", "model": "claude-opus-5-5"}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T15:05:00Z"), "requestId": "r5", "backend": "vertex",
                        "cost": 9.99, "usage": {"input": 1, "output": 1, "cacheRead": 1, "cacheWrite": 1}}),
            # keepwarm / boot / unrouted usage ignored
            json.dumps({"type": "keepwarm", "ts": _ms("2026-11-24T13:00:00Z")}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:50:00Z"), "requestId": "missing-route", "backend": "vertex",
                        "cost": 3.0, "usage": {"input": 1, "output": 1}}),
        ]
        weeks, first_h = qte.aggregate_cfp_events(lines, "mac", self.now, self.since)
        self.assertEqual(first_h, dt.datetime(2026, 11, 24, 13, 0, tzinfo=dt.timezone.utc))
        self.assertEqual(list(weeks.keys()), ["2026-W48"])
        rows = weeks["2026-W48"]
        self.assertEqual(len(rows), 2)

        r13 = rows[0]
        self.assertEqual(r13["host"], "mac")
        self.assertEqual(r13["hour_utc"], "2026-11-24T13:00Z")
        self.assertEqual(r13["account"], "")
        self.assertEqual(r13["backend"], "vertex")
        self.assertEqual(r13["model"], "claude-opus-5-5")
        self.assertEqual(r13["requests"], 2)
        self.assertEqual(r13["input"], 300)
        self.assertEqual(r13["output"], 75)
        self.assertEqual(r13["cache_read"], 1500)
        self.assertEqual(r13["cache_write_5m"], 500)
        self.assertEqual(r13["cache_write_1h"], 0)
        self.assertAlmostEqual(r13["cost_usd"], 2.0, places=6)

        r14 = rows[1]
        self.assertEqual(r14["hour_utc"], "2026-11-24T14:00Z")
        self.assertEqual(r14["backend"], "agy")
        self.assertEqual(r14["model"], "claude-sonnet-5-5")
        self.assertAlmostEqual(r14["cost_usd"], 0.42, places=6)

    def test_unpriced_cash_row_emits_none_cost(self):
        lines = [
            json.dumps({"type": "route", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "model": "claude-opus-5-5"}),
            json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "backend": "vertex",
                        "cost": None, "usage": {"input": 10, "output": 5}}),
        ]
        weeks, _ = qte.aggregate_cfp_events(lines, "mac", self.now, self.since)
        self.assertIsNone(weeks["2026-W48"][0]["cost_usd"])


class TestMainExportAndImportRoundTrip(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.repo = os.path.join(self.tmpdir.name, "repo")
        os.makedirs(self.repo)
        subprocess.run(["git", "-C", self.repo, "init", "-q"], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", self.repo, "config", "user.name", "Test User"], check=True)
        self.ledger = os.path.join(self.tmpdir.name, "usage.jsonl")
        self.events = os.path.join(self.tmpdir.name, "events.jsonl")

    def tearDown(self):
        self.tmpdir.cleanup()

    def _run_main(self, now_dt: dt.datetime, ledger=None, cfp_events=None):
        argv = [
            "--host", "mac",
            "--repo", self.repo,
            "--ledger", ledger if ledger is not None else self.ledger,
            "--no-push",
        ]
        if cfp_events is not None:
            argv += ["--cfp-events", cfp_events]

        class _FixedDateTime(dt.datetime):
            @classmethod
            def now(cls, tz=None):
                return now_dt if tz is None else now_dt.astimezone(tz)

        with mock.patch.object(qte.dt, "datetime", _FixedDateTime):
            return qte.main(argv)

    def test_cash_only_without_teamclaude_ledger(self):
        # usage.jsonl does NOT exist, only events.jsonl exists
        with open(self.events, "w") as f:
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "r1", "backend": "vertex",
                                "cost": 3.5, "usage": {"input": 100, "output": 50, "cacheRead": 0, "cacheWrite": 0}}) + "\n")
        rc = self._run_main(dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc), cfp_events=self.events)
        self.assertEqual(rc, 0)
        week_file = os.path.join(self.repo, "mac", "2026-W48.jsonl")
        self.assertTrue(os.path.exists(week_file))
        with open(week_file, encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["backend"], "vertex")
        self.assertEqual(rows[0]["account"], "")
        self.assertAlmostEqual(rows[0]["cost_usd"], 3.5, places=6)

    def test_per_source_truncation_cutoff_preserves_older_rows(self):
        # Initial run with Max at 10:00Z and 12:00Z, Cash at 10:00Z and 12:00Z
        with open(self.ledger, "w") as f:
            f.write(json.dumps({"ts": "2026-11-24T10:15:00Z", "account": "a@example.com", "model": "claude-opus-5-5", "input": 100, "output": 10}) + "\n")
            f.write(json.dumps({"ts": "2026-11-24T12:15:00Z", "account": "a@example.com", "model": "claude-opus-5-5", "input": 200, "output": 20}) + "\n")
        with open(self.events, "w") as f:
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T10:20:00Z"), "requestId": "c1", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T10:20:00Z"), "requestId": "c1", "backend": "vertex", "cost": 1.1, "usage": {"input": 10}}) + "\n")
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T12:20:00Z"), "requestId": "c2", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T12:20:00Z"), "requestId": "c2", "backend": "vertex", "cost": 2.2, "usage": {"input": 20}}) + "\n")
        rc = self._run_main(dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc), cfp_events=self.events)
        self.assertEqual(rc, 0)

        # Now truncate events.jsonl so it only starts at 12:00Z (and adds 13:00Z),
        # while usage.jsonl still has 10:00Z and 12:00Z.
        with open(self.events, "w") as f:
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T12:20:00Z"), "requestId": "c2", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T12:20:00Z"), "requestId": "c2", "backend": "vertex", "cost": 2.2, "usage": {"input": 20}}) + "\n")
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "c3", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "c3", "backend": "vertex", "cost": 3.3, "usage": {"input": 30}}) + "\n")
        rc2 = self._run_main(dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc), cfp_events=self.events)
        self.assertEqual(rc2, 0)

        with open(os.path.join(self.repo, "mac", "2026-W48.jsonl"), encoding="utf-8") as f:
            rows = [json.loads(l) for l in f if l.strip()]
        keys = [(r["hour_utc"], r.get("backend") or "max", r.get("account") or "") for r in rows]
        self.assertEqual(keys, [
            ("2026-11-24T10:00Z", "vertex", ""),
            ("2026-11-24T10:00Z", "max", "a@example.com"),
            ("2026-11-24T12:00Z", "vertex", ""),
            ("2026-11-24T12:00Z", "max", "a@example.com"),
            ("2026-11-24T13:00Z", "vertex", ""),
        ])

    def test_roundtrip_into_llm_ledger_fleet_views(self):
        with open(self.ledger, "w") as f:
            f.write(json.dumps({"ts": "2026-11-24T13:10:00Z", "account": "acct-m@example.com", "model": "claude-opus-5-5", "input": 1_000_000, "output": 0}) + "\n")
        with open(self.events, "w") as f:
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "v1", "model": "claude-opus-5-5"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:20:00Z"), "requestId": "v1", "backend": "vertex", "cost": 7.25, "usage": {"input": 500, "output": 100}}) + "\n")
        rc = self._run_main(dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc), cfp_events=self.events)
        self.assertEqual(rc, 0)

        db_path = os.path.join(self.tmpdir.name, "ledger.db")
        res = llm_ledger.import_remote(db_path=db_path, repo_dir=self.repo, local_host="cloudbox")
        self.assertEqual(res["files"], 1)
        self.assertEqual(res["rows"], 2)
        self.assertEqual(res["malformed"], 0)
        self.assertEqual(res["unpriced"], 0)

        conn = sqlite3.connect(db_path)
        fh = conn.execute("SELECT host, backend, cost_usd FROM fleet_hourly ORDER BY backend").fetchall()
        self.assertEqual(len(fh), 2)
        self.assertEqual(fh[0][0:2], ("mac", "max"))
        self.assertAlmostEqual(fh[0][2], 4.0, places=6)
        self.assertEqual(fh[1][0:2], ("mac", "vertex"))
        self.assertAlmostEqual(fh[1][2], 7.25, places=6)

        # Cash row must NOT appear in fleet_account_hourly (Max only)
        fah = conn.execute("SELECT host, account, cost_usd FROM fleet_account_hourly").fetchall()
        self.assertEqual(len(fah), 1)
        self.assertEqual(fah[0][0:2], ("mac", "acct-m"))
        conn.close()

    def test_goose_db_exports_vertex_gemini_delta_without_double_counting_agy(self):
        # Hour 13: cfp agy recorded $10.00 of Neon; goose usage_ledger recorded $14.50 total
        # (so $4.50 fell back to Vertex). Hour 12: cfp agy recorded $8.00; goose recorded $8.00 (no delta).
        with open(self.events, "w") as f:
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T12:10:00Z"), "requestId": "a1", "model": "gemini-4-neon"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T12:10:00Z"), "requestId": "a1", "backend": "agy", "cost": 8.0, "usage": {"input": 1000, "output": 200}}) + "\n")
            f.write(json.dumps({"type": "route", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "a2", "model": "gemini-4-neon"}) + "\n")
            f.write(json.dumps({"type": "usage", "ts": _ms("2026-11-24T13:10:00Z"), "requestId": "a2", "backend": "agy", "cost": 10.0, "usage": {"input": 2000, "output": 400}}) + "\n")

        goose_db = os.path.join(self.tmpdir.name, "sessions.db")
        gcon = sqlite3.connect(goose_db)
        gcon.execute(
            "CREATE TABLE usage_ledger ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, created_timestamp INTEGER, "
            "model TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, "
            "cache_write_tokens INTEGER, cost REAL)"
        )
        t12 = int(dt.datetime(2026, 11, 24, 12, 10, tzinfo=dt.timezone.utc).timestamp())
        t13 = int(dt.datetime(2026, 11, 24, 13, 10, tzinfo=dt.timezone.utc).timestamp())
        gcon.executemany(
            "INSERT INTO usage_ledger (session_id, created_timestamp, model, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost) "
            "VALUES (?, ?, ?, ?, ?, 0, 0, ?)",
            [
                ("s1", t12, "gemini-4-neon", 1000, 200, 8.0),
                ("s1", t13, "gemini-4-neon", 2000, 400, 10.0),
                ("s1", t13 + 60, "gemini-4-neon", 900, 100, 4.5),
                ("s1", t13 + 90, "claude-opus-5-5", 500, 100, 3.0),
            ],
        )
        gcon.commit()
        gcon.close()

        now = dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc)
        since = dt.datetime(2026, 11, 23, 0, 0, tzinfo=dt.timezone.utc)
        with open(self.events) as f:
            cfp_weeks, _ = qte.aggregate_cfp_events(f, "mac", now, since)
        vg_weeks, _ = qte.aggregate_goose_vertex_gemini(goose_db, "mac", now, since, cfp_weeks)
        all_vg = [r for rows in vg_weeks.values() for r in rows]
        self.assertEqual(len(all_vg), 1)
        self.assertEqual(all_vg[0]["hour_utc"], "2026-11-24T13:00Z")
        self.assertEqual(all_vg[0]["backend"], "vertex-gemini")
        self.assertEqual(all_vg[0]["model"], "gemini-4-neon")
        self.assertAlmostEqual(all_vg[0]["cost_usd"], 4.5, places=6)
        self.assertEqual(all_vg[0]["requests"], 1)


if __name__ == "__main__":
    unittest.main()
