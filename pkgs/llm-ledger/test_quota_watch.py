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
from unittest import mock
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
    ACCT_PAGE_MAX_H,
    FORECAST_ZERO_H,
    BLIND_MS,
    HORIZON_MS,
    STEP_MS,
    K_MIN_BURN,
    STALE_INPUT_MS,
    Accumulator,
    PoolTracker,
    compute_burn_events,
    pool_at,
    estimate_k,
    burn_rate,
    forecast,
    step_alerts,
    sum_buckets,
    parse_et_datetime,
    load_inputs,
    run_live,
    replay,
)

E = ZoneInfo("America/New_York")


def _python_stub(alert_log: str) -> str:
    """A stand-in for opencode-drift-alert: logs its argv as one JSON line
    (alert texts contain newlines, so shell quoting is not safe) and touches
    the state file, as the real helper does after a successful send."""
    return (
        f"#!{sys.executable}\n"
        "import json, pathlib, sys\n"
        f"with open({alert_log!r}, 'a') as f:\n"
        "    f.write(json.dumps({'argv': sys.argv[1:]}) + '\\n')\n"
        "pathlib.Path(sys.argv[1]).touch()\n"
    )


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

    def test_excluded_account_not_in_accumulator(self):
        """Accounts in explicit excluded set must not be fed into Accumulator / count burn."""
        acc = Accumulator(excluded={"ignored_acct"})
        t0 = 1000000
        acc.feed(t0, "ignored_acct", 0.50, t0 + 50000)
        acc.feed(t0 + 300000, "ignored_acct", 0.90, t0 + 50000)
        self.assertEqual(acc.burn_events, [])


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

    def test_pool_tracker_r7d_eff_independent_of_null_u7d(self):
        """r7d_eff must be latest non-null r7d at any tick <= T, independent of null u7d."""
        tracker = PoolTracker()
        t0 = 1000000
        # Tick t0: u7d = 0.50, r7d = 5000
        tracker.feed_tick(t0, [("acct1", 0.50, 5000)])
        # Tick t0 + 5m: u7d = None, r7d = 9000 (updated reset time on null-u tick)
        tracker.feed_tick(t0 + 300000, [("acct1", None, 9000)])
        # Tick t0 + 10m: u7d = None, r7d = None
        tracker.feed_tick(t0 + 600000, [("acct1", None, None)])

        pool = tracker.pool()
        self.assertIn("acct1", pool)
        u_eff, r_eff = pool["acct1"]
        self.assertEqual(u_eff, 0.50)
        self.assertEqual(r_eff, 9000, "r7d_eff must be 9000 from null-u tick, not 5000")

    def test_pool_tracker_shared_behavior(self):
        """PoolTracker produces identical result to pool_at."""
        t0 = 1000000
        samples = [
            (t0, "acct1", 0.50, 5000),
            (t0 + 300000, "acct1", 0.60, 5000),
            (t0 + 300000, "acct2", 0.40, 6000),
        ]
        p1 = pool_at(samples, t0 + 300000)
        tracker = PoolTracker()
        tracker.feed_tick(t0, [("acct1", 0.50, 5000)])
        tracker.feed_tick(t0 + 300000, [("acct1", 0.60, 5000), ("acct2", 0.40, 6000)])
        p2 = tracker.pool()
        self.assertEqual(p1, p2)


class TestMetricsAndForecast(unittest.TestCase):
    def test_estimate_k(self):
        self.assertIsNone(estimate_k(0.4, 100.0), "burn < K_MIN_BURN (0.5) must return None")
        k_val = estimate_k(1.0, 500.0)
        self.assertIsNotNone(k_val)
        assert k_val is not None
        self.assertAlmostEqual(k_val, 500.0)

    def test_burn_rate(self):
        # 6h burn = 0.6, 24h burn = 1.2, no spillover
        # rate(6) = 0.6/6 = 0.10, rate(24) = 1.2/24 = 0.05 -> max is 0.10
        B = burn_rate(0.6, 1.2, 0.0, 0.0, None)
        self.assertAlmostEqual(B, 0.10)

        # With spillover: spill_6h = $100, k = 1000 -> spill burn = 0.10
        # rate(6) = (0.6 + 0.1)/6 = 0.7/6 ≈ 0.1167
        B_spill = burn_rate(0.6, 1.2, 100.0, 0.0, 1000.0)
        self.assertAlmostEqual(B_spill, 0.7 / 6.0)

    def test_sum_buckets_exact_bounds(self):
        """15-min window = exactly 3 buckets; excludes bucket T starting at T (future leak)."""
        # Buckets at 0, 300_000, 600_000, 900_000, 1_200_000
        buckets = {
            0: 1.0,
            300_000: 2.0,
            600_000: 4.0,
            900_000: 8.0,  # bucket T (starts at 900_000)
            1_200_000: 16.0,
        }
        # Window (900_000 - 900_000, 900_000] -> [0, 900_000) -> buckets 0, 300_000, 600_000
        val = sum_buckets(buckets, T=900_000, W=900_000)
        self.assertEqual(val, 1.0 + 2.0 + 4.0)

    def test_forecast_path_length_and_monotone(self):
        """forecast appends 289 points starting at (T, H0), monotone non-increasing absent refills."""
        T = 1700000000000
        H0 = 2.5
        B = 0.1
        path: list[tuple[int, float]] = []
        zero_h, vertex_usd, next_refill = forecast(H0, B, refills=[], k=None, T=T, path=path)
        self.assertEqual(len(path), 289)
        self.assertEqual(path[0], (T, H0))
        # Monotone non-increasing absent refills
        for i in range(1, len(path)):
            self.assertLessEqual(path[i][1], path[i - 1][1])
            self.assertEqual(path[i][0], T + i * STEP_MS)
        self.assertEqual(path[-1][0], T + HORIZON_MS)

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
        assert vertex_usd is not None
        self.assertAlmostEqual(vertex_usd, zero_h * B * k, places=1)
        self.assertEqual(next_refill, (r_time, 0.50))

    def test_next_refill_beyond_24h_horizon(self):
        """next_refill must be earliest refill of any pool account even if beyond 24h horizon."""
        t0 = 100000000
        H0 = 0.50
        B = 0.01
        r_time = t0 + 30 * 3600 * 1000  # 30 hours out (> 24h horizon)
        refills = [(r_time, 0.40)]
        zero_h, vertex_usd, next_refill = forecast(H0, B, refills, k=1000.0, T=t0)
        self.assertEqual(next_refill, (r_time, 0.40))
        # Since refill is at 30h, it does not refill within the 24h simulation
        # h(24h) = 0.50 - 24 * 0.01 = 0.26 > 0.02 -> zero_h is 0.0
        self.assertEqual(zero_h, 0.0)

    def test_forecast_unsorted_refills(self):
        """Refills passed unsorted are sorted so stepping order is correct."""
        t0 = 100000000
        H0 = 0.05
        B = 0.05
        # Refills passed in reverse order: 4h before 2h
        refills_unsorted = [
            (t0 + 4 * 3600 * 1000, 0.50),
            (t0 + 2 * 3600 * 1000, 0.50),
        ]
        zero_h, _, next_r = forecast(H0, B, refills_unsorted, k=1000.0, T=t0)
        self.assertEqual(next_r, (t0 + 2 * 3600 * 1000, 0.50))
        # Verify it matches sorted forecast
        refills_sorted = [
            (t0 + 2 * 3600 * 1000, 0.50),
            (t0 + 4 * 3600 * 1000, 0.50),
        ]
        zero_h_sorted, _, _ = forecast(H0, B, refills_sorted, k=1000.0, T=t0)
        self.assertEqual(zero_h, zero_h_sorted)


class TestAlertsHysteresisAndLatch(unittest.TestCase):
    def test_pool_dry_hysteresis(self):
        """pool-dry fires at H0 < 0.10 & spill15 > 0; clears at H0 >= 0.15 or spill30 == 0."""
        state = {}
        # H0 = 0.08 (< 0.10), spill15 = 10.0 -> fires
        metrics_fire = {
            "H0": 0.08,
            "zero_h": 3.0,
            "spill_15m": 10.0,
            "spill_30m": 10.0,
            "pool": {"acct1": (0.90, 2000000)},
            "B": 0.05,
            "k": 1000.0,
            "vertex_usd": 150.0,
            "next_refill": (2000000, 0.5),
            "T": 1000000,
        }
        st1, acts1 = step_alerts(state, metrics_fire)
        self.assertTrue(st1["pool_dry"])
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "send" for a in acts1))

        # H0 rises to 0.12 (above 0.10, but below 0.15) with ongoing spillover -> still active
        metrics_mid = dict(metrics_fire, H0=0.12)
        st2, acts2 = step_alerts(st1, metrics_mid)
        self.assertTrue(st2["pool_dry"])
        # pool-dry is sent on every run while active
        self.assertTrue(any(a["kind"] == "pool-dry" and a["type"] == "send" for a in acts2))

        # H0 rises to 0.16 (>= 0.15) -> clears
        metrics_clear = dict(metrics_fire, H0=0.16)
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

    def test_account_high_page_condition(self):
        """Account-high only sends alert at latch if H0 < ACCT_PAGE_MAX_H (1.0); still latches silently."""
        state = {}
        # Case 1: H0 = 1.20 (>= 1.0) -> latches silently, NO send action
        metrics_wide = {
            "H0": 1.20,
            "zero_h": 0.0,
            "spill_15m": 0.0,
            "spill_30m": 0.0,
            "pool": {"acct_wide": (0.91, 2000000)},
            "B": 0.05,
            "k": None,
            "vertex_usd": None,
            "next_refill": None,
            "T": 1000000,
        }
        st1, acts1 = step_alerts(state, metrics_wide)
        self.assertTrue(st1["acct_high"]["acct_wide"])
        self.assertEqual(len(acts1), 0, "Must not send account-high alert when H0 >= 1.0")

        # Case 2: H0 = 0.80 (< 1.0) -> latches and sends alert
        metrics_tight = dict(metrics_wide, H0=0.80, pool={"acct_tight": (0.92, 2000000)})
        st2, acts2 = step_alerts(state, metrics_tight)
        self.assertTrue(st2["acct_high"]["acct_tight"])
        self.assertTrue(any(a["kind"] == "account-high" and a["type"] == "send" for a in acts2))

    def test_hot_accounts_in_pool_dry_and_shortfall_texts(self):
        """pool-dry and shortfall texts list accounts currently >= 0.90 with u7d."""
        state = {}
        metrics = {
            "H0": 0.05,  # < DRY_H (0.10)
            "zero_h": 3.0,  # >= SHORT_FIRE_H (2.0)
            "spill_15m": 10.0,
            "spill_30m": 10.0,
            "pool": {
                "acct_hot1": (0.95, 2000000),
                "acct_hot2": (0.91, 2000000),
                "acct_ok": (0.50, 2000000),
            },
            "B": 0.05,
            "k": 1000.0,
            "vertex_usd": 150.0,
            "next_refill": (2000000, 0.5),
            "T": 1000000,
        }
        # Test pool-dry text
        _, acts_dry = step_alerts(state, metrics)
        dry_act = [a for a in acts_dry if a["kind"] == "pool-dry"][0]
        self.assertIn("Accounts at or above 0.90:", dry_act["text"])
        self.assertIn("acct_hot1 0.95", dry_act["text"])
        self.assertIn("acct_hot2 0.91", dry_act["text"])
        self.assertNotIn("acct_ok", dry_act["text"])

        # Test shortfall text (when pool-dry not active)
        metrics_short = dict(metrics, spill_15m=0.0, spill_30m=0.0, H0=0.20)
        _, acts_short = step_alerts(state, metrics_short)
        short_act = [a for a in acts_short if a["kind"] == "shortfall"][0]
        self.assertIn("Accounts at or above 0.90:", short_act["text"])
        self.assertIn("acct_hot1 0.95", short_act["text"])
        self.assertIn("acct_hot2 0.91", short_act["text"])


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
            f.write(_python_stub(alert_log))
        os.chmod(stub_script, os.stat(stub_script).st_mode | stat.S_IEXEC)

        conn = sqlite3.connect(self.db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
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

        # Write existing state so acct1 was not latched (was_latched=False)
        with open(os.path.join(self.state_dir, "state.json"), "w") as f:
            json.dump({"pool_dry": False, "shortfall": False, "acct_high": {"acct1": False}}, f)

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

    def test_state_robustness_and_first_run_seeding(self):
        """State missing/corrupt starts fresh, warns on stderr, and seeds acct_high silently."""
        cases = [
            ("missing", None),
            ("empty", ""),
            ("array", "[]"),
            ("null", "null"),
            ("string", '"x"'),
            ("malformed_field", '{"acct_high": "foo"}'),
            ("invalid_json", "{bad json"),
        ]
        for name, content in cases:
            with self.subTest(case=name):
                state_dir = os.path.join(self.tmp_dir.name, f"state_{name}")
                os.makedirs(state_dir, exist_ok=True)
                state_file = os.path.join(state_dir, "state.json")
                if content is not None:
                    with open(state_file, "w") as f:
                        f.write(content)

                # DB with hot account (u7d = 0.95)
                db_path = os.path.join(self.tmp_dir.name, f"db_{name}.db")
                conn = sqlite3.connect(db_path)
                conn.executescript(llm_ledger.SCHEMA_SQL)
                t0 = 1700000000000
                conn.execute(
                    "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
                    (t0, "acct1", 0.95, t0 + 86400 * 1000),
                )
                conn.commit()
                conn.close()

                alert_cmd = os.path.join(self.tmp_dir.name, f"stub_{name}.sh")
                with open(alert_cmd, "w") as f:
                    f.write("#!/bin/sh\nexit 0\n")
                os.chmod(alert_cmd, 0o755)

                import io
                from unittest.mock import patch
                stderr_buf = io.StringIO()
                with patch("sys.stderr", stderr_buf):
                    rc = run_live(db_path, state_dir, alert_cmd=alert_cmd, now=t0)
                self.assertEqual(rc, 0)
                self.assertIn("state missing or corrupt", stderr_buf.getvalue())

                # Assert state.json was written and acct1 was seeded
                with open(state_file) as f:
                    saved_state = json.load(f)
                self.assertTrue(saved_state["acct_high"]["acct1"])
                # Assert .alert file was NOT created (no alert sent on first-run seeding)
                self.assertFalse(os.path.exists(os.path.join(state_dir, "acct-acct1.alert")))

    def test_alert_command_timeout_and_error(self):
        """Alert command failure/timeout warns to stderr and continues without crashing; state saved."""
        state_dir = os.path.join(self.tmp_dir.name, "state_err")
        os.makedirs(state_dir, exist_ok=True)
        stub_err = os.path.join(self.tmp_dir.name, "stub_err.sh")
        with open(stub_err, "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        os.chmod(stub_err, 0o755)

        db_path = os.path.join(self.tmp_dir.name, "db_err.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000000000
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.95, t0 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        # Write pre-existing state with acct1=False so it transitions and triggers send
        with open(os.path.join(state_dir, "state.json"), "w") as f:
            json.dump({"pool_dry": False, "shortfall": False, "acct_high": {"acct1": False}}, f)

        import io
        from unittest.mock import patch
        stderr_buf = io.StringIO()
        with patch("sys.stderr", stderr_buf):
            rc = run_live(db_path, state_dir, alert_cmd=stub_err, now=t0)
        self.assertEqual(rc, 0, "run_live must continue with exit 0 despite alert cmd failure")
        self.assertIn("warning: alert command exited with code 1", stderr_buf.getvalue())
        # State must still be saved
        with open(os.path.join(state_dir, "state.json")) as f:
            saved_state = json.load(f)
        self.assertTrue(saved_state["acct_high"]["acct1"])

    def test_run_live_pool_dry_and_shortfall_argv(self):
        """run_live calls alert_cmd with exact argv for pool-dry and shortfall, and suppresses shortfall when dry."""
        alert_log = os.path.join(self.tmp_dir.name, "alert_log_dry.jsonl")
        stub_script = os.path.join(self.tmp_dir.name, "stub_dry.sh")
        with open(stub_script, "w") as f:
            f.write(_python_stub(alert_log))
        os.chmod(stub_script, 0o755)

        state_dir = os.path.join(self.tmp_dir.name, "state_dry_test")
        os.makedirs(state_dir, exist_ok=True)
        # Pre-seed state so it's not treated as fresh
        with open(os.path.join(state_dir, "state.json"), "w") as f:
            json.dump({"pool_dry": False, "shortfall": False, "acct_high": {}}, f)

        db_path = os.path.join(self.tmp_dir.name, "db_dry.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
        # acct1 has u7d=0.98 -> H0 = 0.00 (< 0.02)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.98, t0 + 86400 * 1000),
        )
        # Add spillover in the last 15 min: route.desired='max' AND requests.backend='vertex'
        conn.execute(
            "INSERT INTO route (request_id, ts, desired) VALUES ('r1', ?, 'max')",
            (t0 - 60000,),
        )
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('r1', ?, 'host', 'key', 'vertex', 5.0)",
            (t0 - 60000,),
        )
        conn.commit()
        conn.close()

        rc = run_live(db_path, state_dir, alert_cmd=stub_script, now=t0, host="host")
        self.assertEqual(rc, 0)

        with open(alert_log) as f:
            lines = [json.loads(line) for line in f]

        # pool-dry should fire: argv [alert_file, "quota-pool-dry", text, "900", "14400"]
        dry_inv = [inv for inv in lines if inv["argv"][1] == "quota-pool-dry"]
        self.assertEqual(len(dry_inv), 1)
        self.assertEqual(dry_inv[0]["argv"][3], "900")
        self.assertEqual(dry_inv[0]["argv"][4], "14400")

        # shortfall should NOT be sent while pool-dry is active
        short_inv = [inv for inv in lines if inv["argv"][1] == "quota-shortfall"]
        self.assertEqual(len(short_inv), 0)

    def test_run_live_blind_spot_stale_samples(self):
        """If samples are > 60 min stale, blind alert is sent and run_live skips quota evaluation."""
        alert_log = os.path.join(self.tmp_dir.name, "alert_blind_samples.jsonl")
        stub_script = os.path.join(self.tmp_dir.name, "stub_blind_s.sh")
        with open(stub_script, "w") as f:
            f.write(_python_stub(alert_log))
        os.chmod(stub_script, 0o755)

        state_dir = os.path.join(self.tmp_dir.name, "state_blind_s")
        os.makedirs(state_dir, exist_ok=True)

        db_path = os.path.join(self.tmp_dir.name, "db_blind_s.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000000000
        # Samples are 70 min old (> 60 min)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0 - 70 * 60 * 1000, "acct1", 0.50, t0 + 86400 * 1000),
        )
        # Fresh requests for host
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('r1', ?, 'myhost', 'k', 'max', 1.0)",
            (t0 - 5 * 60 * 1000,),
        )
        conn.commit()
        conn.close()

        rc = run_live(db_path, state_dir, alert_cmd=stub_script, now=t0, host="myhost")
        self.assertEqual(rc, 0)

        with open(alert_log) as f:
            lines = [json.loads(line) for line in f]
        blind_inv = [inv for inv in lines if inv["argv"][1] == "quota-watch-blind"]
        self.assertEqual(len(blind_inv), 1)
        self.assertEqual(blind_inv[0]["argv"][0], os.path.join(state_dir, "blind.alert"))
        self.assertEqual(blind_inv[0]["argv"][3], "3600")
        self.assertEqual(blind_inv[0]["argv"][4], "14400")
        self.assertIn("quota_samples is", blind_inv[0]["argv"][2])

    def test_run_live_blind_spot_stale_requests_fresh_samples(self):
        """If requests are > 60 min stale with fresh samples, blind alert is sent and quota evaluation runs."""
        alert_log = os.path.join(self.tmp_dir.name, "alert_blind_req.jsonl")
        stub_script = os.path.join(self.tmp_dir.name, "stub_blind_r.sh")
        with open(stub_script, "w") as f:
            f.write(_python_stub(alert_log))
        os.chmod(stub_script, 0o755)

        state_dir = os.path.join(self.tmp_dir.name, "state_blind_r")
        os.makedirs(state_dir, exist_ok=True)
        with open(os.path.join(state_dir, "state.json"), "w") as f:
            json.dump({"pool_dry": False, "shortfall": False, "acct_high": {}}, f)

        db_path = os.path.join(self.tmp_dir.name, "db_blind_r.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
        # Fresh samples (5 min old)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0 - 5 * 60 * 1000, "acct1", 0.50, t0 + 86400 * 1000),
        )
        # Stale requests for host (70 min old)
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('r1', ?, 'myhost', 'k', 'max', 1.0)",
            (t0 - 70 * 60 * 1000,),
        )
        conn.commit()
        conn.close()

        import io
        from unittest.mock import patch
        stdout_buf = io.StringIO()
        with patch("sys.stdout", stdout_buf):
            rc = run_live(db_path, state_dir, alert_cmd=stub_script, now=t0, host="myhost")
        self.assertEqual(rc, 0)

        # Blind alert must be sent
        with open(alert_log) as f:
            lines = [json.loads(line) for line in f]
        blind_inv = [inv for inv in lines if inv["argv"][1] == "quota-watch-blind"]
        self.assertEqual(len(blind_inv), 1)
        self.assertIn("requests for host 'myhost'", blind_inv[0]["argv"][2])

        # Quota evaluation must still have run (summary line printed)
        self.assertIn("quota-watch T=", stdout_buf.getvalue())

    def test_run_live_blind_spot_fresh_clears_alert(self):
        """When inputs are fresh again, blind.alert is deleted."""
        state_dir = os.path.join(self.tmp_dir.name, "state_blind_fresh")
        os.makedirs(state_dir, exist_ok=True)
        blind_alert_file = os.path.join(state_dir, "blind.alert")
        with open(blind_alert_file, "w") as f:
            f.write("old alert")

        db_path = os.path.join(self.tmp_dir.name, "db_blind_fresh.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
        # Fresh samples (5 min old)
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0 - 5 * 60 * 1000, "acct1", 0.50, t0 + 86400 * 1000),
        )
        # Fresh requests (5 min old)
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('r1', ?, 'myhost', 'k', 'max', 1.0)",
            (t0 - 5 * 60 * 1000,),
        )
        conn.commit()
        conn.close()

        rc = run_live(db_path, state_dir, alert_cmd=None, now=t0, host="myhost")
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(blind_alert_file), "blind.alert must be removed when inputs are fresh")

    def test_load_inputs_and_run_live_host_filter(self):
        """load_inputs and newest-request query filter requests by host."""
        db_path = os.path.join(self.tmp_dir.name, "db_host.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.50, t0 + 86400 * 1000),
        )
        # host A (cloudbox) has backend=max cost=10.0
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('rA', ?, 'cloudbox', 'k', 'max', 10.0)",
            (t0 - 60000,),
        )
        # host B (devbox) has backend=max cost=50.0
        conn.execute(
            "INSERT INTO requests (request_id, ts, host, attr_key, backend, cost_usd) VALUES ('rB', ?, 'devbox', 'k', 'max', 50.0)",
            (t0 - 60000,),
        )
        conn.commit()

        # Query with host='cloudbox'
        _, _, max_b_cb = load_inputs(conn, t0 - 3600000, host="cloudbox")
        b_key = ((t0 - 60000) // 300000) * 300000
        self.assertEqual(max_b_cb.get(b_key), 10.0)

        # Query with host='devbox'
        _, _, max_b_db = load_inputs(conn, t0 - 3600000, host="devbox")
        self.assertEqual(max_b_db.get(b_key), 50.0)
        conn.close()

    def test_replay_account_high_page_flag(self):
        """Replay account-high events carry page=yes/no depending on H0 < 1.0."""
        db_path = os.path.join(self.tmp_dir.name, "db_acct_page.db")
        conn = sqlite3.connect(db_path)
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000000000
        # Tick t0: acct1 is 0.95, H0 = max(0, 0.98 - 0.95) = 0.03 (< 1.0) -> page=yes
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.95, t0 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        events = replay(db_path, since_ms=t0, until_ms=t0)
        acct_events = [e for e in events if e.kind == "account-high"]
        self.assertEqual(len(acct_events), 1)
        self.assertTrue(acct_events[0].metrics["page"])
        self.assertIn("page=yes", str(acct_events[0]))

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
        host_name = "cloudbox"
        # spill_buckets: route.desired='max' AND requests.backend='vertex'
        for i, (b_ms, cost) in enumerate(fixture["spill_buckets"]):
            rid = f"spill_{i}"
            route_rows.append((rid, b_ms, None, None, "max", "vertex"))
            req_rows.append((rid, b_ms, host_name, None, "tag", "vertex", "model", 0, 0, 0, 0, cost, 200, 100))

        # max_buckets: requests.backend='max'
        for i, (b_ms, cost) in enumerate(fixture["max_buckets"]):
            rid = f"max_{i}"
            route_rows.append((rid, b_ms, None, None, "max", "max"))
            req_rows.append((rid, b_ms, host_name, None, "tag", "max", "model", 0, 0, 0, 0, cost, 200, 100))

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

        events = replay(self.db_path, since_ms=since_ms, until_ms=until_ms, host=host_name)

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

    def test_record_run_creates_tables_and_replaces_path(self):
        """record_run creates tables, inserts run row, and replaces forecast path."""
        db_path = os.path.join(self.tmp_dir.name, "record_run_test.db")
        T1 = 1700000000000
        path1: list[tuple[int, float]] = []
        forecast(2.0, 0.1, [], None, T1, path=path1)
        row1 = {
            "ts": T1,
            "h0": 2.0,
            "burn_h": 0.1,
            "burn_6h": 0.05,
            "burn_24h": 0.2,
            "spill_6h": 0.0,
            "spill_24h": 0.0,
            "k": 100.0,
            "zero_h": 0.0,
            "vertex_usd": 0.0,
            "next_refill_ts": None,
            "next_refill_amt": None,
            "pool_n": 5,
            "source": "live",
        }
        quota_watch.record_run(db_path, row1, path1)

        conn = sqlite3.connect(db_path)
        runs = conn.execute("SELECT * FROM quota_watch_runs").fetchall()
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0][0], T1)
        self.assertEqual(runs[0][1], 2.0)
        self.assertEqual(runs[0][-1], "live")

        fc = conn.execute("SELECT ts, headroom, run_ts FROM quota_forecast").fetchall()
        self.assertEqual(len(fc), 289)
        self.assertTrue(all(r[2] == T1 for r in fc))
        conn.close()

        # Second call with T2 replaces the path
        T2 = T1 + 300000
        path2: list[tuple[int, float]] = []
        forecast(1.9, 0.1, [], None, T2, path=path2)
        row2 = dict(row1, ts=T2, h0=1.9)
        quota_watch.record_run(db_path, row2, path2)

        conn = sqlite3.connect(db_path)
        runs = conn.execute("SELECT * FROM quota_watch_runs ORDER BY ts").fetchall()
        self.assertEqual(len(runs), 2)

        fc = conn.execute("SELECT ts, headroom, run_ts FROM quota_forecast").fetchall()
        self.assertEqual(len(fc), 289)
        self.assertTrue(all(r[2] == T2 for r in fc))
        conn.close()

    def test_record_run_readonly_db_warns_and_does_not_raise(self):
        """record_run on an unwritable DB path (directory) warns on stderr and does not raise."""
        bad_db = self.tmp_dir.name

        row = {
            "ts": 1700000000000,
            "h0": 1.0,
            "burn_h": 0.1,
            "burn_6h": 0.0,
            "burn_24h": 0.0,
            "spill_6h": 0.0,
            "spill_24h": 0.0,
            "k": None,
            "zero_h": 0.0,
            "vertex_usd": None,
            "next_refill_ts": None,
            "next_refill_amt": None,
            "pool_n": 3,
            "source": "live",
        }
        import io
        stderr_cap = io.StringIO()
        orig_stderr = sys.stderr
        try:
            sys.stderr = stderr_cap
            quota_watch.record_run(bad_db, row, [(1700000000000, 1.0)])
        finally:
            sys.stderr = orig_stderr

        err = stderr_cap.getvalue()
        self.assertIn("quota-watch: could not record run:", err)

    def test_record_run_path_none_leaves_existing_forecast_intact(self):
        """record_run with path=None or empty path leaves existing forecast intact."""
        db_path = os.path.join(self.tmp_dir.name, "forecast_intact.db")
        T1 = 1700000000000
        path1 = [(T1, 2.0), (T1 + 300000, 1.9)]
        row1 = {
            "ts": T1,
            "h0": 2.0,
            "burn_h": 0.1,
            "burn_6h": 0.0,
            "burn_24h": 0.0,
            "spill_6h": 0.0,
            "spill_24h": 0.0,
            "k": None,
            "zero_h": 0.0,
            "vertex_usd": None,
            "next_refill_ts": None,
            "next_refill_amt": None,
            "pool_n": 1,
            "source": "live",
        }
        quota_watch.record_run(db_path, row1, path=path1)

        conn = sqlite3.connect(db_path)
        fc_before = conn.execute("SELECT ts, headroom, run_ts FROM quota_forecast").fetchall()
        self.assertEqual(len(fc_before), 2)
        conn.close()

        # Second run with path=None leaves quota_forecast intact
        T2 = T1 + 300000
        row2 = dict(row1, ts=T2, h0=1.9)
        quota_watch.record_run(db_path, row2, path=None)

        conn = sqlite3.connect(db_path)
        fc_after = conn.execute("SELECT ts, headroom, run_ts FROM quota_forecast").fetchall()
        conn.close()
        self.assertEqual(fc_after, fc_before)

        # Third run with path=[] leaves quota_forecast intact
        T3 = T2 + 300000
        row3 = dict(row1, ts=T3, h0=1.8)
        quota_watch.record_run(db_path, row3, path=[])

        conn = sqlite3.connect(db_path)
        fc_after_empty = conn.execute("SELECT ts, headroom, run_ts FROM quota_forecast").fetchall()
        conn.close()
        self.assertEqual(fc_after_empty, fc_before)

    def test_run_live_recording_failure_still_succeeds(self):
        """run_live against a DB where record_run fails still returns 0 and prints summary."""
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.executescript(llm_ledger.SCHEMA_SQL)
        t0 = 1700000100000
        for d in range(7):
            ts = t0 - (7 - d) * 86400 * 1000
            conn.execute(
                "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
                (ts, "acct1", 0.50, ts + 86400 * 1000),
            )
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.50, t0 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        # Hold a RESERVED lock via BEGIN IMMEDIATE: readers proceed, writers fail with busy.
        lock_conn = sqlite3.connect(self.db_path)
        lock_conn.execute("BEGIN IMMEDIATE")

        import io
        stdout_cap = io.StringIO()
        stderr_cap = io.StringIO()
        orig_stdout = sys.stdout
        orig_stderr = sys.stderr
        try:
            sys.stdout = stdout_cap
            sys.stderr = stderr_cap
            with mock.patch.object(quota_watch, "RECORD_TIMEOUT_S", 0.05):
                rc = quota_watch.run_live(self.db_path, self.state_dir, now=t0 + 60000)
        finally:
            sys.stdout = orig_stdout
            sys.stderr = orig_stderr
            lock_conn.close()

        self.assertEqual(rc, 0)
        self.assertIn("quota-watch: could not record run:", stderr_cap.getvalue())
        self.assertIn("quota-watch T=", stdout_cap.getvalue())


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

    def test_cli_subcommands_host_arg(self):
        """llm-ledger quota-watch and quota-replay accept --host."""
        ret_qw = llm_ledger.main([
            "quota-watch",
            "--db", self.db_path,
            "--state-dir", self.state_dir,
            "--host", "customhost",
        ])
        self.assertEqual(ret_qw, 0)

        ret_qr = llm_ledger.main([
            "quota-replay",
            "--db", self.db_path,
            "--since", "2026-11-20",
            "--host", "customhost",
        ])
        self.assertEqual(ret_qr, 0)

    def test_replay_record_does_not_overwrite_live(self):
        """quota-replay --record does not overwrite an existing 'live' row for the same ts."""
        conn = sqlite3.connect(self.db_path)
        t0 = 1700000100000
        for d in range(7):
            ts = t0 - (7 - d) * 86400 * 1000
            conn.execute(
                "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
                (ts, "acct1", 0.50, ts + 86400 * 1000),
            )
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.50, t0 + 86400 * 1000),
        )
        # Pre-populate a 'live' row for t0
        conn.execute(
            """INSERT INTO quota_watch_runs (
                ts, h0, burn_h, burn_6h, burn_24h, spill_6h, spill_24h,
                k, zero_h, vertex_usd, next_refill_ts, next_refill_amt,
                pool_n, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (t0, 99.0, 0.0, 0.0, 0.0, 0.0, 0.0, None, 0.0, None, None, None, 1, "live"),
        )
        conn.commit()
        conn.close()

        since_str = datetime.datetime.fromtimestamp((t0 - 3600000) / 1000, tz=E).strftime("%Y-%m-%d %H:%M")
        until_str = datetime.datetime.fromtimestamp((t0 + 3600000) / 1000, tz=E).strftime("%Y-%m-%d %H:%M")
        import io
        stdout_cap = io.StringIO()
        orig_stdout = sys.stdout
        try:
            sys.stdout = stdout_cap
            ret = llm_ledger.main([
                "quota-replay",
                "--db", self.db_path,
                "--since", since_str,
                "--until", until_str,
                "--record",
            ])
        finally:
            sys.stdout = orig_stdout

        self.assertEqual(ret, 0)
        self.assertIn("recorded", stdout_cap.getvalue())

        conn = sqlite3.connect(self.db_path)
        row = conn.execute("SELECT ts, h0, source FROM quota_watch_runs WHERE ts = ?", (t0,)).fetchone()
        conn.close()
        self.assertIsNotNone(row)
        self.assertEqual(row[1], 99.0)
        self.assertEqual(row[2], "live")

    def test_replay_record_unwritable_db_returns_nonzero(self):
        """quota-replay --record returns 1 and warns on stderr when DB cannot be written."""
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA journal_mode=DELETE")
        t0 = 1700000100000
        for d in range(7):
            ts = t0 - (7 - d) * 86400 * 1000
            conn.execute(
                "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
                (ts, "acct1", 0.50, ts + 86400 * 1000),
            )
        conn.execute(
            "INSERT INTO quota_samples (ts, account, u7d, r7d) VALUES (?, ?, ?, ?)",
            (t0, "acct1", 0.50, t0 + 86400 * 1000),
        )
        conn.commit()
        conn.close()

        # Hold BEGIN IMMEDIATE to block record_replay_runs
        lock_conn = sqlite3.connect(self.db_path)
        lock_conn.execute("BEGIN IMMEDIATE")

        since_str = datetime.datetime.fromtimestamp((t0 - 3600000) / 1000, tz=E).strftime("%Y-%m-%d %H:%M")
        until_str = datetime.datetime.fromtimestamp((t0 + 3600000) / 1000, tz=E).strftime("%Y-%m-%d %H:%M")
        import io
        stderr_cap = io.StringIO()
        orig_stderr = sys.stderr
        try:
            sys.stderr = stderr_cap
            with mock.patch.object(quota_watch, "RECORD_TIMEOUT_S", 0.05):
                ret = llm_ledger.main([
                    "quota-replay",
                    "--db", self.db_path,
                    "--since", since_str,
                    "--until", until_str,
                    "--record",
                ])
        finally:
            sys.stderr = orig_stderr
            lock_conn.close()

        self.assertEqual(ret, 1)
        self.assertIn("quota-replay: could not record:", stderr_cap.getvalue())

    def test_parse_et_datetime(self):
        """parse_et_datetime handles naive dates, end_of_day, naive datetimes, DST, and offsets."""
        # Naive date (start of day)
        ts_start = parse_et_datetime("2026-11-20")
        dt_start = datetime.datetime.fromtimestamp(ts_start / 1000, tz=E)
        self.assertEqual(dt_start.strftime("%Y-%m-%d %H:%M:%S"), "2026-11-20 00:00:00")

        # Naive date with end_of_day_for_date=True (exclusive next midnight)
        ts_end = parse_et_datetime("2026-11-20", end_of_day_for_date=True)
        dt_end = datetime.datetime.fromtimestamp(ts_end / 1000, tz=E)
        self.assertEqual(dt_end.strftime("%Y-%m-%d %H:%M:%S"), "2026-11-21 00:00:00")

        # Naive datetime
        ts_dt = parse_et_datetime("2026-11-20 14:30")
        dt_val = datetime.datetime.fromtimestamp(ts_dt / 1000, tz=E)
        self.assertEqual(dt_val.strftime("%Y-%m-%d %H:%M"), "2026-11-20 14:30")

        # DST-period date (July is EDT -04:00)
        ts_dst = parse_et_datetime("2026-07-04")
        dt_dst = datetime.datetime.fromtimestamp(ts_dst / 1000, tz=E)
        self.assertEqual(dt_dst.strftime("%z"), "-0400")

        # Non-DST date (December is EST -05:00)
        ts_nodst = parse_et_datetime("2026-12-25")
        dt_nodst = datetime.datetime.fromtimestamp(ts_nodst / 1000, tz=E)
        self.assertEqual(dt_nodst.strftime("%z"), "-0500")

        # Explicit offset honoured
        ts_utc = parse_et_datetime("2026-11-20T19:00:00Z")
        dt_utc = datetime.datetime.fromtimestamp(ts_utc / 1000, tz=E)
        self.assertEqual(dt_utc.strftime("%Y-%m-%d %H:%M"), "2026-11-20 14:00")


if __name__ == "__main__":
    unittest.main()
