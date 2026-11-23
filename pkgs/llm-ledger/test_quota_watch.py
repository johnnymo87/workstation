"""Tests for quota-watch. Run: python3 pkgs/llm-ledger/test_quota_watch.py"""

from __future__ import annotations

import datetime
import gzip
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

# Redirect HOME to a throwaway dir BEFORE importing oc_tags or llm_ledger.
_HOME_SANDBOX = tempfile.TemporaryDirectory(prefix="quota-watch-test-home-")
os.environ["HOME"] = _HOME_SANDBOX.name

# Add oc-tags and llm-ledger to sys.path
_PKG_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_PKG_DIR))
sys.path.insert(0, str(_PKG_DIR.parent / "oc-tags"))

import llm_ledger
import quota_watch
from quota_watch import (
    CAP,
    RESET_DROP,
    CARRY_MS,
    RESYNC_GAP_MS,
    STALE_HOLD_MS,
    DRY_H,
    DRY_CLEAR_H,
    SHORT_FIRE_H,
    SHORT_CLEAR_H,
    ACCT_HI,
    ACCT_REARM,
    HORIZON_MS,
    STEP_MS,
    K_MIN_BURN,
    STALE_INPUT_MS,
    Accumulator,
    compute_burn_events,
    pool_at,
    estimate_k,
    burn_rate,
    forecast,
    step_alerts,
    load_inputs,
    run_live,
    replay,
)

E = ZoneInfo("America/New_York")


class TestQuotaWatchMathAndAccumulator(unittest.TestCase):
    def test_accumulator_jitter_counts_zero(self):
        """Jitter: a -> a - 0.01 -> a counts zero burn."""
        t0 = 1000000
        # Account starts at 0.50
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.50, t0 + 7 * 86400 * 1000)
        # Drops by 0.01 (jitter)
        acc.feed(t0 + 300000, "acct1", 0.49, t0 + 7 * 86400 * 1000)
        # Rises back to 0.50 (no rise above high-water mark)
        acc.feed(t0 + 600000, "acct1", 0.50, t0 + 7 * 86400 * 1000)

        self.assertEqual(acc.burn_events, [])
        self.assertEqual(acc.burn(t0 + 600000, 3600000), 0.0)

    def test_accumulator_rise_above_highwater(self):
        """Burn increases when u > hw."""
        t0 = 1000000
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.50, t0 + 7 * 86400 * 1000)
        acc.feed(t0 + 300000, "acct1", 0.55, t0 + 7 * 86400 * 1000)

        self.assertEqual(len(acc.burn_events), 1)
        self.assertEqual(acc.burn_events[0][0], t0 + 300000)
        self.assertAlmostEqual(acc.burn_events[0][1], 0.05)
        self.assertAlmostEqual(acc.burn(t0 + 300000, 3600000), 0.05)

    def test_accumulator_scheduled_reset(self):
        """Crossing r7d with drop u < hw counts post-reset value as burn."""
        t0 = 1000000
        r7d = t0 + 600000
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.85, r7d)
        # Crossed r7d at t0 + 600000, with drop to 0.10
        acc.feed(t0 + 600000, "acct1", 0.10, r7d + 7 * 86400 * 1000)

        self.assertEqual(len(acc.burn_events), 1)
        self.assertEqual(acc.burn_events[0], (t0 + 600000, 0.10))
        self.assertAlmostEqual(acc.burn(t0 + 600000, 3600000), 0.10)

    def test_accumulator_stale_tick_then_drop(self):
        """11-13 shape: Crossing r7d without drop holds for <=15 min, then drop counts once."""
        t0 = 1000000
        r7d = t0 + 300000
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.85, r7d)

        # At t0 + 300000 (ts == r7d): sample still reads 0.85 (stale tick)
        acc.feed(t0 + 300000, "acct1", 0.85, r7d)
        self.assertEqual(acc.burn_events, [], "Stale tick must not count burn")

        # At t0 + 600000 (5 min later, within 15 min): sample reads 0.05 (reset arrived)
        new_r7d = r7d + 7 * 86400 * 1000
        acc.feed(t0 + 600000, "acct1", 0.05, new_r7d)

        self.assertEqual(len(acc.burn_events), 1)
        self.assertEqual(acc.burn_events[0], (t0 + 600000, 0.05))

    def test_accumulator_off_schedule_reset(self):
        """Drop > 0.05 even when not crossing r7d counts as reset."""
        t0 = 1000000
        r7d = t0 + 7 * 86400 * 1000
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.80, r7d)

        # Drop by 0.15 without crossing r7d (e.g. pool-wide off-schedule reset)
        acc.feed(t0 + 300000, "acct1", 0.65, r7d)
        self.assertEqual(len(acc.burn_events), 1)
        self.assertEqual(acc.burn_events[0], (t0 + 300000, 0.65))

    def test_accumulator_gap_resync(self):
        """Gap > 1 hour resyncs high-water mark without counting burn."""
        t0 = 1000000
        acc = Accumulator()
        acc.feed(t0, "acct1", 0.80, t0 + 7 * 86400 * 1000)

        # Gap of 2 hours
        acc.feed(t0 + 7200000, "acct1", 0.20, t0 + 7 * 86400 * 1000)
        self.assertEqual(acc.burn_events, [], "Gap > 1h must resync without burn")

        # Further rise after resync counts burn from new mark 0.20
        acc.feed(t0 + 7500000, "acct1", 0.25, t0 + 7 * 86400 * 1000)
        self.assertEqual(len(acc.burn_events), 1)
        self.assertEqual(acc.burn_events[0][0], t0 + 7500000)
        self.assertAlmostEqual(acc.burn_events[0][1], 0.05)


class TestPoolAt(unittest.TestCase):
    def test_pool_at_null_carry_and_drop(self):
        """Null u7d carried for <= 15 min, dropped after > 15 min."""
        t0 = 1000000
        # Tick t0: acct1 has 0.50
        # Tick t0 + 5m (300_000): acct1 has None (5 min <= 15 min -> carried)
        # Tick t0 + 20m (1_200_000): acct1 has None (20 min > 15 min -> dropped)
        samples = [
            (t0, "acct1", 0.50, t0 + 10000000),
            (t0 + 300000, "acct1", None, t0 + 10000000),
            (t0 + 1200000, "acct1", None, t0 + 10000000),
        ]

        pool_5m = pool_at(samples, t0 + 300000)
        self.assertIn("acct1", pool_5m)
        self.assertEqual(pool_5m["acct1"][0], 0.50)

        pool_20m = pool_at(samples, t0 + 1200000)
        self.assertNotIn("acct1", pool_20m, "Account with null > 15 min must be dropped from pool")

    def test_pool_at_absent_account_dropped(self):
        """An account absent from the latest tick is out of the pool."""
        t0 = 1000000
        samples = [
            (t0, "acct1", 0.50, t0 + 10000000),
            (t0, "acct2", 0.40, t0 + 10000000),
            (t0 + 300000, "acct1", 0.52, t0 + 10000000),
            # acct2 not present at t0 + 300000
        ]
        pool = pool_at(samples, t0 + 300000)
        self.assertIn("acct1", pool)
        self.assertNotIn("acct2", pool)

    def test_pool_at_spend_capped_all_null_excluded(self):
        """Accounts with no non-null u7d in loaded window are auto-excluded."""
        t0 = 1000000
        samples = [
            (t0, "acct1", 0.50, t0 + 10000000),
            (t0, "spend_capped", None, None),
            (t0 + 300000, "acct1", 0.52, t0 + 10000000),
            (t0 + 300000, "spend_capped", None, None),
        ]
        pool = pool_at(samples, t0 + 300000)
        self.assertIn("acct1", pool)
        self.assertNotIn("spend_capped", pool)

    def test_pool_at_explicit_exclude(self):
        """Explicit excluded account set removes account."""
        t0 = 1000000
        samples = [
            (t0, "acct1", 0.50, t0 + 10000000),
            (t0, "acct2", 0.60, t0 + 10000000),
        ]
        pool = pool_at(samples, t0, excluded={"acct2"})
        self.assertIn("acct1", pool)
        self.assertNotIn("acct2", pool)


class TestMetricsAndForecast(unittest.TestCase):
    def test_estimate_k(self):
        self.assertIsNone(estimate_k(0.4, 100.0), "burn < K_MIN_BURN (0.5) must return None")
        self.assertAlmostEqual(estimate_k(1.0, 500.0), 500.0)

    def test_burn_rate(self):
        # 6h burn = 0.6, 24h burn = 1.2, no spillover
        # rate(6) = 0.6/6 = 0.10, rate(24) = 1.2/24 = 0.05 -> max is 0.10
        B = burn_rate(0.6, 1.2, 0.0, 0.0, None)
        self.assertAlmostEqual(B, 0.10)

        # With spillover: spill_6h = $100, k = 1000 -> spill burn = 0.10
        # rate(6) = (0.6 + 0.1)/6 = 0.7/6 ≈ 0.1167
        B_spill = burn_rate(0.6, 1.2, 100.0, 0.0, 1000.0)
        self.assertAlmostEqual(B_spill, 0.7 / 6.0)

    def test_forecast_and_refills(self):
        """Forecast simulates 24h forward in 5-min steps and applies refills in order."""
        t0 = 100000000
        H0 = 0.10
        B = 0.05  # burns 0.05 / h -> reaches zero in 2h
        # Refill at t0 + 3h (+0.50)
        r_time = t0 + 3 * 3600 * 1000
        refills = [(r_time, 0.50)]
        k = 1000.0

        zero_h, vertex_usd, next_refill = forecast(H0, B, refills, k, t0)
        # h starts 0.10. At B=0.05/h, h drops below DRY_H (0.02) at (0.10 - 0.02)/0.05 = 1.6h.
        # From 1.6h to 3h (1.4h), h < 0.02 (dry).
        # At 3h, refill +0.50 arrives -> h rises to 0.50.
        # h drops below 0.02 at (0.50 - 0.02)/0.05 = 9.6h later (at t0 + 12.6h).
        # From 12.6h to 24h (11.4h), h < 0.02 (dry).
        # Total dry hours = 1.4h + 11.4h = 12.8h (in 5-min discrete steps, 12.75h).
        self.assertAlmostEqual(zero_h, 12.75, places=1)
        self.assertIsNotNone(vertex_usd)
        self.assertAlmostEqual(vertex_usd, zero_h * B * k, places=1)
        self.assertEqual(next_refill, (r_time, 0.50))


class TestAlertsHysteresisAndLatch(unittest.TestCase):
    def test_pool_dry_hysteresis(self):
        """pool-dry fires at H0 < 0.02 & spill15 > 0; clears at H0 >= 0.05 or spill30 == 0."""
        state = {}
        # H0 = 0.01, spill15 = 10.0 -> fires
        metrics_fire = {
            "H0": 0.01,
            "zero_h": 3.0,
            "spill_15m": 10.0,
            "spill_30m": 10.0,
            "pool": {"acct1": (0.97, 2000000)},
            "B": 0.05,
            "k": 1000.0,
            "vertex_usd": 150.0,
            "next_refill": (2000000, 0.5),
            "T": 1000000,
        }
        st1, acts1 = step_alerts(state, metrics_fire)
        self.assertTrue(st1["pool_dry"])
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "send" for a in acts1))

        # H0 rises to 0.03 (above 0.02, but below 0.05) with ongoing spillover -> still active
        metrics_mid = dict(metrics_fire, H0=0.03)
        st2, acts2 = step_alerts(st1, metrics_mid)
        self.assertTrue(st2["pool_dry"])
        # pool-dry is sent on every run while active
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "send" for a in acts2))

        # H0 rises to 0.06 -> clears
        metrics_clear = dict(metrics_fire, H0=0.06)
        st3, acts3 = step_alerts(st2, metrics_clear)
        self.assertFalse(st3["pool_dry"])
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "clear" for a in acts3))

    def test_shortfall_suppressed_by_pool_dry(self):
        """Shortfall active state evolves but send is suppressed while pool-dry is active."""
        state = {}
        metrics = {
            "H0": 0.01,  # triggers pool-dry
            "zero_h": 4.0,  # triggers shortfall
            "spill_15m": 10.0,
            "spill_30m": 10.0,
            "pool": {"acct1": (0.97, 2000000)},
            "B": 0.05,
            "k": 1000.0,
            "vertex_usd": 200.0,
            "next_refill": (2000000, 0.5),
            "T": 1000000,
        }
        new_st, acts = step_alerts(state, metrics)
        self.assertTrue(new_st["pool_dry"])
        self.assertTrue(new_st["shortfall"])
        # pool-dry send action must be present
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "send" for a in acts))
        # shortfall send action must NOT be present
        self.assertFalse(any(a["kind"] == "shortfall" and a["type"] == "send" for a in acts))

    def test_shortfall_hysteresis(self):
        """Shortfall fires at zero_h >= 2.0; clears at zero_h < 0.5."""
        state = {}
        metrics_fire = {
            "H0": 0.20,
            "zero_h": 2.5,
            "spill_15m": 0.0,
            "spill_30m": 0.0,
            "pool": {"acct1": (0.78, 2000000)},
            "B": 0.05,
            "k": 1000.0,
            "vertex_usd": 125.0,
            "next_refill": (2000000, 0.5),
            "T": 1000000,
        }
        st1, acts1 = step_alerts(state, metrics_fire)
        self.assertTrue(st1["shortfall"])
        self.assertTrue(any(a["kind"] == "shortfall" and a["type"] == "send" for a in acts1))

        # Drops to 1.0 (between 0.5 and 2.0) -> stays active
        metrics_mid = dict(metrics_fire, zero_h=1.0)
        st2, acts2 = step_alerts(st1, metrics_mid)
        self.assertTrue(st2["shortfall"])

        # Drops to 0.4 (< 0.5) -> clears
        metrics_clear = dict(metrics_fire, zero_h=0.4)
        st3, acts3 = step_alerts(st2, metrics_clear)
        self.assertFalse(st3["shortfall"])
        self.assertTrue(any(a["kind"] == "shortfall" and a["type"] == "clear" for a in acts3))

    def test_account_high_latch_and_rearm(self):
        """Account-high latches at u7d >= 0.90 (sent once), re-arms below 0.85 (clear action)."""
        state = {}
        metrics_hi = {
            "H0": 0.50,
            "zero_h": 0.0,
            "spill_15m": 0.0,
            "spill_30m": 0.0,
            "pool": {"acct_special": (0.91, 2000000)},
            "B": 0.05,
            "k": None,
            "vertex_usd": None,
            "next_refill": None,
            "T": 1000000,
        }
        # First time >= 0.90 -> latches and sends
        st1, acts1 = step_alerts(state, metrics_hi)
        self.assertTrue(st1["acct_high"]["acct_special"])
        self.assertTrue(any(a["kind"] == "account-high" and a["type"] == "send" for a in acts1))

        # Next run still at 0.91 -> latched, so NOT sent again
        st2, acts2 = step_alerts(st1, metrics_hi)
        self.assertTrue(st2["acct_high"]["acct_special"])
        self.assertFalse(any(a["kind"] == "account-high" and a["type"] == "send" for a in acts2))

        # Drops to 0.88 (>= 0.85) -> stays latched, no action
        metrics_mid = dict(metrics_hi, pool={"acct_special": (0.88, 2000000)})
        st3, acts3 = step_alerts(st2, metrics_mid)
        self.assertTrue(st3["acct_high"]["acct_special"])
        self.assertEqual(len(acts3), 0)

        # Drops to 0.10 (< 0.85) -> re-arms, generates clear action to delete .alert file
        metrics_rearm = dict(metrics_hi, pool={"acct_special": (0.10, 2000000)})
        st4, acts4 = step_alerts(st3, metrics_rearm)
        self.assertFalse(st4["acct_high"]["acct_special"])
        self.assertTrue(any(a["kind"] == "account-high" and a["type"] == "clear" for a in acts4))


class TestLiveAndReplay(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory(prefix="qw-test-")
        self.db_path = os.path.join(self.tmp_dir.name, "test_ledger.db")
        self.state_dir = os.path.join(self.tmp_dir.name, "state")
        os.makedirs(self.state_dir, exist_ok=True)

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_run_live_stale_input_skip(self):
        """If now - T > 20 min, run_live prints skip message and returns 0 without alerting."""
        conn = sqlite3.connect(self.db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        # Insert sample at T = 1000000
        t0 = 1000000
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.50, t0 + 10000000),
        )
        conn.commit()
        conn.close()

        # now is 25 minutes later (> 20 min)
        now_ms = t0 + 25 * 60 * 1000
        rc = run_live(self.db_path, self.state_dir, alert_cmd=None, now=now_ms)
        self.assertEqual(rc, 0)
        # state.json should not even be created
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "state.json")))

    def test_run_live_alerts_argv_and_clear(self):
        """run_live calls alert_cmd with exact argv and deletes .alert file on clear."""
        # Create stub alert script
        alert_log = os.path.join(self.tmp_dir.name, "alert_invocations.jsonl")
        stub_script = os.path.join(self.tmp_dir.name, "stub_alert.sh")
        with open(stub_script, "w") as f:
            f.write(f"""#!/bin/sh
cat <<EOF >> "{alert_log}"
{{"argv": ["$1", "$2", "$3", "$4", "$5", "$6"]}}
EOF
# Touch the alert file as real drift-alert would
touch "$1"
""")
        os.chmod(stub_script, os.stat(stub_script).st_mode | stat.S_IEXEC)

        conn = sqlite3.connect(self.db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000000000
        # Seed 7 earlier days of quota samples
        for d in range(7):
            ts = t0 - (7 - d) * 86400 * 1000
            conn.execute(
                "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
                (ts, "acct1", 0.50 + 0.05 * d, ts + 86400 * 1000),
            )
        # Make the latest tick have acct1 at 0.95 (triggers account-high)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.95, t0 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        # Run live
        rc = run_live(self.db_path, self.state_dir, alert_cmd=stub_script, now=t0)
        self.assertEqual(rc, 0)

        # Verify state.json written atomically
        self.assertTrue(os.path.exists(os.path.join(self.state_dir, "state.json")))

        # Check alert log
        self.assertTrue(os.path.exists(alert_log))
        with open(alert_log) as f:
            lines = [json.loads(line) for line in f]
        self.assertTrue(len(lines) >= 1)
        # Check argv: [alert_file, signature, text, str(ttl), str(max)]
        acct_inv = [inv for inv in lines if inv["argv"][1] == "quota-acct:acct1"][0]
        alert_file = os.path.join(self.state_dir, "acct-acct1.alert")
        self.assertEqual(acct_inv["argv"][0], alert_file)
        self.assertEqual(acct_inv["argv"][1], "quota-acct:acct1")
        self.assertEqual(acct_inv["argv"][3], "0")  # ttl 0
        self.assertEqual(acct_inv["argv"][4], "14400")  # max 14400

        # Now simulate next run where acct1 reset to 0.10 (drops below 0.85 -> clear)
        t1 = t0 + 300000
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t1, "acct1", 0.10, t1 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        # Verify .alert file exists before run
        self.assertTrue(os.path.exists(alert_file))
        rc2 = run_live(self.db_path, self.state_dir, alert_cmd=stub_script, now=t1)
        self.assertEqual(rc2, 0)
        # Verify .alert file deleted on clear
        self.assertFalse(os.path.exists(alert_file))

    def test_fixture_replay_dry_spell_2026_11_22(self):
        """Fixture replay: shortfall fires before 12:00 ET, pool-dry 12:00-12:30, clears 18:00-18:30."""
        fixture_path = _PKG_DIR / "testdata" / "dry-spell-2026-11-22.json.gz"
        self.assertTrue(fixture_path.exists(), f"Fixture not found: {fixture_path}")

        with gzip.open(fixture_path, "rt") as f:
            fixture = json.load(f)

        conn = sqlite3.connect(self.db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)

        # Insert samples
        sample_rows = [
            (ts, acc, None, None, u, None, None, r, None)
            for ts, acc, u, r in fixture["samples"]
        ]
        conn.executemany(
            "INSERT INTO quota_samples (ts, account, s, u5h, u7d, u7d_fable, fw, r7d, r5h) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            sample_rows,
        )

        # Synthesize requests and routes from spill_buckets and max_buckets
        req_rows = []
        route_rows = []
        # spill_buckets: route.desired='max' AND requests.backend='vertex'
        for i, (b_ms, cost) in enumerate(fixture["spill_buckets"]):
            rid = f"spill_{i}"
            route_rows.append((rid, b_ms, None, None, "max", "vertex"))
            req_rows.append((rid, b_ms, "host", None, "tag", "vertex", "model", 0, 0, 0, 0, cost, 200, 100))

        # max_buckets: requests.backend='max'
        for i, (b_ms, cost) in enumerate(fixture["max_buckets"]):
            rid = f"max_{i}"
            route_rows.append((rid, b_ms, None, None, "max", "max"))
            req_rows.append((rid, b_ms, "host", None, "tag", "max", "model", 0, 0, 0, 0, cost, 200, 100))

        conn.executemany(
            "INSERT INTO route (request_id, ts, session_id, model, desired, chosen) VALUES (?, ?, ?, ?, ?, ?)",
            route_rows,
        )
        conn.executemany(
            "INSERT INTO requests (request_id, ts, host, session_id, attr_key, backend, model, input, output, cache_read, cache_write, cost_usd, status, duration_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            req_rows,
        )
        conn.commit()
        conn.close()

        # Replay window: 2026-11-20 19:00 ET to 2026-11-22 19:00 ET
        since_dt = datetime.datetime(2026, 11, 20, 19, 0, tzinfo=E)
        until_dt = datetime.datetime(2026, 11, 22, 19, 0, tzinfo=E)
        since_ms = int(since_dt.timestamp() * 1000)
        until_ms = int(until_dt.timestamp() * 1000)

        events = replay(self.db_path, since_ms=since_ms, until_ms=until_ms)

        # Assert: shortfall fires before 2026-11-22 12:00 ET
        short_fires = [
            e for e in events
            if e.kind == "shortfall" and e.action == "fire"
        ]
        self.assertTrue(len(short_fires) > 0, "Shortfall must fire during replay")
        nov22_1200_ms = int(datetime.datetime(2026, 11, 22, 12, 0, tzinfo=E).timestamp() * 1000)
        self.assertTrue(
            any(e.ts < nov22_1200_ms for e in short_fires),
            f"Shortfall must fire before 2026-11-22 12:00 ET, got: {[datetime.datetime.fromtimestamp(e.ts/1000, E).strftime('%Y-%m-%d %H:%M') for e in short_fires]}",
        )

        # Assert: pool-dry fires between 12:00 and 12:30 ET
        dry_fires = [
            e for e in events
            if e.kind == "pool-dry" and e.action == "fire"
        ]
        self.assertTrue(len(dry_fires) > 0, "Pool-dry must fire during replay")
        nov22_1230_ms = int(datetime.datetime(2026, 11, 22, 12, 30, tzinfo=E).timestamp() * 1000)
        self.assertTrue(
            any(nov22_1200_ms <= e.ts <= nov22_1230_ms for e in dry_fires),
            f"Pool-dry must fire between 12:00 and 12:30 ET, got: {[datetime.datetime.fromtimestamp(e.ts/1000, E).strftime('%Y-%m-%d %H:%M') for e in dry_fires]}",
        )

        # Assert: pool-dry clears between 18:00 and 18:30 ET
        dry_clears = [
            e for e in events
            if e.kind == "pool-dry" and e.action == "clear"
        ]
        self.assertTrue(len(dry_clears) > 0, "Pool-dry must clear during replay")
        nov22_1800_ms = int(datetime.datetime(2026, 11, 22, 18, 0, tzinfo=E).timestamp() * 1000)
        nov22_1830_ms = int(datetime.datetime(2026, 11, 22, 18, 30, tzinfo=E).timestamp() * 1000)
        self.assertTrue(
            any(nov22_1800_ms <= e.ts <= nov22_1830_ms for e in dry_clears),
            f"Pool-dry must clear between 18:00 and 18:30 ET, got: {[datetime.datetime.fromtimestamp(e.ts/1000, E).strftime('%Y-%m-%d %H:%M') for e in dry_clears]}",
        )


class TestCliSubcommands(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory(prefix="qw-cli-")
        self.db_path = os.path.join(self.tmp_dir.name, "test.db")
        self.state_dir = os.path.join(self.tmp_dir.name, "state")
        os.makedirs(self.state_dir, exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        conn.close()

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_cli_quota_watch_subcommand(self):
        """llm-ledger quota-watch executes without taking writer lock."""
        # Lock file should NOT be acquired
        ret = llm_ledger.main(["quota-watch", "--db", self.db_path, "--state-dir", self.state_dir])
        self.assertEqual(ret, 0)
        # Verify no .lock file created
        lock_file = os.path.join(os.path.dirname(os.path.abspath(self.db_path)), ".lock")
        self.assertFalse(os.path.exists(lock_file))

    def test_cli_quota_replay_subcommand(self):
        """llm-ledger quota-replay executes with --since and --until."""
        ret = llm_ledger.main([
            "quota-replay",
            "--db", self.db_path,
            "--since", "2026-11-20",
            "--until", "2026-11-22",
        ])
        self.assertEqual(ret, 0)


if __name__ == "__main__":
    unittest.main()
