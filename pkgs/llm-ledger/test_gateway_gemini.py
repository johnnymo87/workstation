"""Tests for the aigateway Gemini ingest and the GCP-commitment spend feed
(bead eng-agent-platform-ul4.28.4)."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import llm_ledger

# 2026-11-24 17:37:40Z = 12:37:40 ET
T0 = 1795541860000


def gw_line(rid, started, model="gemini-4-neon", region="global", status=200, sid="ses_a",
            inp=1_000_000, out=100_000, cread=2_000_000, cwrite=0, dollars=None, completed=None):
    def s(v):
        return "" if v is None else str(v)
    return "\t".join([rid, str(started), str(completed if completed is not None else started + 5000), model,
                      region, str(status), sid or "", s(inp), s(out), s(cread), s(cwrite), s(dollars)])


class FakePsql:
    def __init__(self, lines=(), rc=0, exc=None):
        self.lines = list(lines)
        self.rc = rc
        self.exc = exc
        self.calls = []

    def __call__(self, args, **kw):
        self.calls.append(args)
        if self.exc:
            raise self.exc
        return SimpleNamespace(returncode=self.rc, stdout="\n".join(self.lines) + "\n", stderr="boom")


class GatewayBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.db_path = os.path.join(d, "ledger.db")
        self.flag = os.path.join(d, "enabled")
        open(self.flag, "w").close()
        self.conn = llm_ledger.open_ledger_db(self.db_path)
        self.missing = os.path.join(d, "missing.db")

    def tearDown(self):
        self.conn.close()
        self.tmp.cleanup()

    def step(self, fake, now_ms=T0 + 60_000, warnings=None):
        return llm_ledger.step_gateway_gemini(
            conn=self.conn, host="cloudbox", psql="docker exec -i pg psql", flag_path=self.flag,
            opencode_db=self.missing, goose_db=self.missing, tags_db=self.missing,
            lgtm_ledger=self.missing, now_ms=now_ms, warnings=warnings if warnings is not None else [], run=fake)


class TestPriceGemini(unittest.TestCase):
    def test_neon_global(self):
        usd = llm_ledger.price_gemini("gemini-4-neon", "global", 1_000_000, 100_000, 2_000_000, 0, T0)
        self.assertAlmostEqual(usd, 3.0 + 1.5 + 0.3)

    def test_neon_non_global_plus_ten_percent(self):
        usd = llm_ledger.price_gemini("gemini-4-neon", "us-east5", 1_000_000, 0, 0, 0, T0)
        self.assertAlmostEqual(usd, 3.3)

    def test_neon_cache_write_priced_from_2027_01_12(self):
        jan12 = 1799730000000  # 2027-01-12T05:00:00Z
        self.assertAlmostEqual(llm_ledger.price_gemini("gemini-4-neon", "global", 0, 0, 0, 1_000_000, T0), 0.0)
        self.assertAlmostEqual(llm_ledger.price_gemini("gemini-4-neon", "global", 0, 0, 0, 1_000_000, jan12), 3.75)

    def test_no_tokens_or_unknown_model(self):
        self.assertIsNone(llm_ledger.price_gemini("gemini-4-neon", "global", None, None, None, None, T0))
        self.assertIsNone(llm_ledger.price_gemini("unknown", "global", 1, 1, 0, 0, T0))


class TestStepGatewayGemini(GatewayBase):
    def rows(self):
        return self.conn.execute(
            "SELECT request_id, ts, host, session_id, attr_key, backend, model, input, output, "
            "cache_read, cache_write, cost_usd, status, duration_ms FROM requests ORDER BY request_id").fetchall()

    def test_ingests_prices_and_attributes(self):
        fake = FakePsql([
            gw_line("u1", T0),
            gw_line("u2", T0 + 1000, model="gemini-3.8-flash", dollars="0.012500"),
            gw_line("u3", T0 + 2000, status=429, inp=None, out=None, cread=None, cwrite=None),
        ])
        res = self.step(fake)
        self.assertEqual(res["gateway_rows"], 3)
        self.assertEqual(res["touched_hours"], {(T0 // 3_600_000) * 3_600_000})
        r = {row[0]: row for row in self.rows()}
        self.assertEqual(r["gw:u1"][:7], ("gw:u1", T0, "cloudbox", "ses_a", "ses_a", "vertex-gemini", "gemini-4-neon"))
        self.assertAlmostEqual(r["gw:u1"][11], 4.8)
        self.assertEqual(r["gw:u1"][13], 5000)
        # The gateway's own dollars win where it priced the row.
        self.assertAlmostEqual(r["gw:u2"][11], 0.0125)
        # An errored call with no usage is kept (it is a request) at NULL cost.
        self.assertIsNone(r["gw:u3"][11])
        self.assertEqual(r["gw:u3"][12], 429)
        sql = fake.calls[0][-1]
        self.assertIn("model NOT LIKE 'claude%'", sql)
        # The first run backfills a bounded window, not the whole history.
        since_s = (T0 + 60_000 - llm_ledger.GATEWAY_BACKFILL_MS) / 1000.0
        self.assertIn(f"request_completed_at >= to_timestamp({since_s:.3f})", sql)
        self.assertIn("translate(coalesce(client_session_id", sql)
        self.assertEqual(llm_ledger.get_ingest_state(self.conn)["gateway_status"], "ok")

    def test_idempotent_and_overlapping_cursor(self):
        self.step(FakePsql([gw_line("u1", T0)]))
        fake = FakePsql([gw_line("u1", T0), gw_line("u2", T0 + 10_000)])
        res = self.step(fake, now_ms=T0 + 120_000)
        self.assertEqual(res["gateway_rows"], 1)
        self.assertEqual(len(self.rows()), 2)
        sql = fake.calls[0][-1]
        since_s = (T0 + 5000 - llm_ledger.GATEWAY_OVERLAP_MS) / 1000.0
        self.assertIn(f"request_completed_at >= to_timestamp({since_s:.3f})", sql)

    def test_cursor_never_moves_backwards(self):
        self.step(FakePsql([gw_line("u1", T0 + 3_600_000)]))
        self.step(FakePsql([]))
        state = llm_ledger.get_ingest_state(self.conn)
        self.assertEqual(state["gateway_completed_through"], str(T0 + 3_605_000))

    def test_skipped_without_intent_flag(self):
        os.remove(self.flag)
        fake = FakePsql([gw_line("u1", T0)])
        res = self.step(fake)
        self.assertEqual(fake.calls, [])
        self.assertEqual(res["gateway_rows"], 0)
        self.assertEqual(res["gateway_status"], "disabled")
        feed = llm_ledger.commitment_spend(self.conn, now_ms=T0)
        self.assertFalse(feed["complete"])
        self.assertIn("disabled", feed["incomplete_reason"])

    def test_disabled_without_psql(self):
        res = llm_ledger.step_gateway_gemini(conn=self.conn, host="h", psql=None)
        self.assertEqual(res["gateway_rows"], 0)

    def test_failure_never_fails_the_writer_and_keeps_its_start_time(self):
        self.step(FakePsql([gw_line("u1", T0)]), now_ms=T0)
        w: list[str] = []
        res = self.step(FakePsql(rc=2), now_ms=T0 + 10 * 60_000, warnings=w)
        self.assertEqual(res["gateway_status"], "error")
        # Not a RuntimeError, and still contained.
        self.step(FakePsql(exc=ValueError("surprise")), now_ms=T0 + 31 * 60_000, warnings=w)
        self.assertEqual(w, [])
        st = llm_ledger.get_ingest_state(self.conn)
        self.assertEqual(st["gateway_status"], "error")
        self.assertEqual(st["gateway_error_since_ms"], str(T0 + 10 * 60_000))
        self.assertIn("surprise", st["gateway_error"])
        # A failure never advances the cursor; feed says incomplete.
        self.assertEqual(st["gateway_completed_through"], str(T0 + 5000))
        feed = llm_ledger.commitment_spend(self.conn, now_ms=T0 + 31 * 60_000)
        self.assertFalse(feed["complete"])
        self.assertEqual(feed["gateway_error_since"], "2026-11-24T17:47:40Z")
        # Recovery clears the error clock.
        self.step(FakePsql([]), now_ms=T0 + 40 * 60_000)
        st = llm_ledger.get_ingest_state(self.conn)
        self.assertEqual(st["gateway_status"], "ok")
        self.assertNotIn("gateway_error_since_ms", st)

    def test_first_poll_failing_is_still_an_error(self):
        self.step(FakePsql(rc=1), now_ms=T0)
        feed = llm_ledger.commitment_spend(self.conn, now_ms=T0)
        self.assertFalse(feed["complete"])
        self.assertEqual(feed["gateway_status"], "error")
        self.assertIsNone(feed["gateway_polled_at"])

    def test_wrong_field_count_is_a_failure_not_a_misparse(self):
        res = self.step(FakePsql(["a\tb"]))
        self.assertEqual(res["gateway_status"], "error")
        self.assertEqual(self.rows(), [])

    def test_pages_through_a_large_backfill(self):
        orig = llm_ledger.GATEWAY_PAGE_ROWS
        llm_ledger.GATEWAY_PAGE_ROWS = 2
        try:
            pages = [[gw_line("u1", T0), gw_line("u2", T0 + 1000)],
                     [gw_line("u2", T0 + 1000), gw_line("u3", T0 + 2000)],
                     [gw_line("u3", T0 + 2000)]]
            calls = []

            def run(args, **kw):
                calls.append(args[-1])
                return SimpleNamespace(returncode=0, stdout="\n".join(pages[len(calls) - 1]) + "\n", stderr="")
            res = self.step(run)
        finally:
            llm_ledger.GATEWAY_PAGE_ROWS = orig
        self.assertEqual(res["gateway_rows"], 3)
        self.assertEqual(len(calls), 3)
        self.assertIn("LIMIT 2", calls[0])
        self.assertIn(f"to_timestamp({(T0 + 6000) / 1000.0:.3f})", calls[1])

    def test_paging_that_cannot_advance_is_an_error(self):
        orig = llm_ledger.GATEWAY_PAGE_ROWS
        llm_ledger.GATEWAY_PAGE_ROWS = 2
        try:
            self.step(FakePsql([gw_line("u0", T0)]), now_ms=T0)
            same = [gw_line("a", T0 - 10_000_000, completed=T0 + 5000 - llm_ledger.GATEWAY_OVERLAP_MS),
                    gw_line("b", T0 - 10_000_000, completed=T0 + 5000 - llm_ledger.GATEWAY_OVERLAP_MS)]
            res = self.step(FakePsql(same), now_ms=T0 + 60_000)
        finally:
            llm_ledger.GATEWAY_PAGE_ROWS = orig
        self.assertEqual(res["gateway_status"], "error")

    def test_goose_session_without_claim_is_goose_unknown(self):
        self.step(FakePsql([gw_line("u1", T0, sid="20261124_7")]))
        attr = self.conn.execute("SELECT attr_key FROM requests").fetchone()[0]
        self.assertEqual(attr, llm_ledger.oc_tags.CFP_GOOSE_UNKNOWN_TAG)


class TestCommitmentSpend(GatewayBase):
    def add(self, rid, ts, backend, model, cost, attr="ses_a", inp=1):
        self.conn.execute(
            "INSERT INTO requests (request_id, ts, host, session_id, attr_key, backend, model, input, cost_usd) "
            "VALUES (?, ?, 'cloudbox', ?, ?, ?, ?, ?, ?)", (rid, ts, attr, attr, backend, model, inp, cost))

    def test_buckets_and_neon_by_program(self):
        self.conn.execute("INSERT INTO session_program VALUES ('ses_a', 'stall-watcher/coord', 'manual', NULL, NULL, 0)")
        self.conn.execute("INSERT INTO session_program VALUES ('ses_b', 'lgtm', 'manual', NULL, NULL, 0)")
        self.add("n1", T0, "vertex-gemini", "gemini-4-neon", 2.0)
        self.add("n2", T0 + 1, "vertex-gemini", "gemini-4-neon", 1.0, attr="ses_b")
        self.add("n3", T0 + 2, "vertex-gemini", "gemini-4-neon", None)  # unpriced
        self.add("n4", T0 + 3, "vertex-gemini", "gemini-4-neon", None, inp=None)  # errored, no usage
        self.add("f1", T0, "vertex-gemini", "gemini-3.8-flash", 0.5, attr="ses_c")
        self.add("a1", T0, "agy", "claude-opus-5-5", 4.0)
        self.add("g1", T0, "agy", "gemini-4-neon", 0.5, attr="ses_b")  # Neon on the seat via cfp
        self.add("v1", T0, "vertex", "claude-opus-5-5", 100.0)  # Claude bucket: excluded
        self.add("m1", T0, "max", "claude-opus-5-5", 100.0)  # Max: excluded
        self.add("y1", T0 - 13 * 3_600_000, "vertex-gemini", "gemini-4-neon", 50.0)  # yesterday ET
        res = llm_ledger.commitment_spend(self.conn, now_ms=T0 + 60_000)
        self.assertEqual(res["day"], "2026-11-24")
        self.assertEqual(res["day_start"], "2026-11-24T05:00:00Z")
        self.assertEqual(res["neon"], {"usd": 3.5, "requests": 5, "unpriced_requests": 1,
                                       "no_usage_ok_requests": 0,
                                       "by_backend": {"vertex-gemini": 3.0, "agy": 0.5},
                                       "by_program": {"stall-watcher": 2.0, "lgtm": 1.5}})
        self.assertFalse(res["complete"])  # never polled, and an unpriced Neon row
        g = res["gcp_commitment"]
        self.assertAlmostEqual(g["usd"], 8.0)
        self.assertEqual(g["by_backend"], {"vertex-gemini": 3.5, "agy": 4.5})
        self.assertEqual(g["by_program"]["unresolved"], 0.5)
        y = llm_ledger.commitment_spend(self.conn, day="2026-11-23", now_ms=T0)
        self.assertEqual(y["neon"]["usd"], 50.0)

    def test_write_json_atomic_and_cli(self):
        self.add("n1", T0, "vertex-gemini", "gemini-4-neon", 2.0)
        llm_ledger.ensure_fleet_objects(self.conn, "cloudbox")
        self.conn.commit()
        path = os.path.join(self.tmp.name, "feed.json")
        llm_ledger.write_commitment_json(self.conn, path, now_ms=T0 + 1)
        feed = json.loads(Path(path).read_text())
        self.assertEqual(feed["schema"], 1)
        self.assertEqual(feed["neon"]["usd"], 2.0)
        self.assertEqual([f for f in os.listdir(self.tmp.name) if ".tmp." in f], [])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = llm_ledger.main(["commitment-spend", "--db", self.db_path, "--day", "2026-11-24", "--json"])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out.getvalue())["neon"]["usd"], 2.0)

    def test_backend_bucket_table(self):
        llm_ledger.ensure_fleet_objects(self.conn, "cloudbox")
        got = dict(self.conn.execute("SELECT backend, bucket FROM backend_bucket").fetchall())
        self.assertEqual(got["vertex-gemini"], "gcp-commitment")
        self.assertEqual(got["agy"], "gcp-commitment")
        self.assertEqual(got["vertex"], "claude-vertex")
        self.assertEqual(got["max"], "max")


class TestFeedComplete(GatewayBase):
    def test_complete_only_when_recently_polled_ok(self):
        self.step(FakePsql([gw_line("u1", T0)]), now_ms=T0)
        self.assertTrue(llm_ledger.commitment_spend(self.conn, now_ms=T0 + 60_000)["complete"])
        late = llm_ledger.commitment_spend(self.conn, now_ms=T0 + 16 * 60_000)
        self.assertFalse(late["complete"])
        self.assertIn("older than 15 min", late["incomplete_reason"])

    def test_ok_status_but_no_usage_is_counted(self):
        self.step(FakePsql([gw_line("u1", T0, inp=None, out=None, cread=None, cwrite=None)]), now_ms=T0)
        self.assertEqual(llm_ledger.commitment_spend(self.conn, now_ms=T0)["neon"]["no_usage_ok_requests"], 1)


class TestQuotaWatchGeminiAlert(GatewayBase):
    def run_watch(self, now_ms):
        import quota_watch
        state_dir = os.path.join(self.tmp.name, "qw")
        os.makedirs(state_dir, exist_ok=True)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            quota_watch.run_live(self.db_path, state_dir, alert_cmd=None, now=now_ms, host="cloudbox",
                                 alert_stale_hosts="")
        return out.getvalue()

    def test_pages_after_30_min_of_errors_only(self):
        self.step(FakePsql(rc=1), now_ms=T0)
        self.conn.commit()
        self.assertNotIn("gemini-feed-stale", self.run_watch(T0 + 29 * 60_000))
        self.assertIn("would-alert: gemini-feed-stale", self.run_watch(T0 + 31 * 60_000))
        self.step(FakePsql([]), now_ms=T0 + 32 * 60_000)
        self.assertNotIn("gemini-feed-stale", self.run_watch(T0 + 33 * 60_000))


class TestRunIngestWiring(GatewayBase):
    def test_run_ingest_ingests_rolls_up_and_writes_feed(self):
        events = os.path.join(self.tmp.name, "events.jsonl")
        open(events, "w").close()
        feed = os.path.join(self.tmp.name, "feed.json")
        self.conn.close()
        res = llm_ledger.run_ingest(
            db_path=self.db_path, events_path=events, raw_dir=os.path.join(self.tmp.name, "raw"),
            host="cloudbox", opencode_db=self.missing, goose_db=self.missing, tags_db=self.missing,
            lgtm_ledger=self.missing, samples_path=self.missing, samples_archive=self.missing, now=(T0 + 60_000) / 1000,
            gateway_psql="psql", gateway_flag=self.flag, commitment_json=feed,
            gateway_run=FakePsql([gw_line("u1", T0)]))
        self.conn = llm_ledger.open_ledger_db(self.db_path)
        self.assertEqual(res["gateway_rows"], 1)
        hourly = self.conn.execute("SELECT backend, model, n, cost_usd FROM hourly").fetchall()
        self.assertEqual(len(hourly), 1)
        self.assertEqual(hourly[0][:3], ("vertex-gemini", "gemini-4-neon", 1))
        self.assertAlmostEqual(hourly[0][3], 4.8)
        self.assertAlmostEqual(json.loads(Path(feed).read_text())["neon"]["usd"], 4.8)

    def test_remote_hourly_mac_agy_neon_counted_in_commitment_spend(self):
        # Local cloudbox gateway Neon row ($4.80)
        self.step(FakePsql([gw_line("local1", T0)]), now_ms=T0 + 60_000)
        # Remote Mac agy Neon row ($12.50) + remote Mac max Claude row (must NOT be counted)
        hour_ms = (T0 // 3_600_000) * 3_600_000
        self.conn.execute(
            "INSERT INTO remote_hourly (host, hour, account, backend, model, requests, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd) "
            "VALUES (?, ?, '', 'agy', 'gemini-4-neon', 10, 100000, 5000, 0, 0, 0, 12.50)",
            ("mac", hour_ms),
        )
        self.conn.execute(
            "INSERT INTO remote_hourly (host, hour, account, backend, model, requests, input, output, cache_read, cache_write_5m, cache_write_1h, cost_usd) "
            "VALUES (?, ?, 'acct-a', 'max', 'claude-opus-5-5', 5, 50000, 2000, 0, 0, 0, 99.00)",
            ("mac", hour_ms),
        )
        self.conn.commit()
        feed = llm_ledger.commitment_spend(self.conn, now_ms=T0 + 120_000)
        self.assertTrue(feed["complete"])
        self.assertAlmostEqual(feed["neon"]["usd"], 17.30, places=2)
        self.assertEqual(feed["neon"]["requests"], 11)
        self.assertAlmostEqual(feed["neon"]["by_backend"]["vertex-gemini"], 4.80, places=2)
        self.assertAlmostEqual(feed["neon"]["by_backend"]["agy"], 12.50, places=2)
        self.assertAlmostEqual(feed["neon"]["by_program"]["fleet:mac"], 12.50, places=2)
        self.assertAlmostEqual(feed["gcp_commitment"]["usd"], 17.30, places=2)


if __name__ == "__main__":
    unittest.main()
