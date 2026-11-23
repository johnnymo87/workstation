"""quota-watch: monitors Claude Max pool quota, predicts shortfall, and manages alerts."""

from __future__ import annotations

import bisect
import collections
import dataclasses
import datetime
import json
import os
import re
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time
from collections.abc import Sequence
from typing import Any
from zoneinfo import ZoneInfo

CAP: float = 0.98
RESET_DROP: float = 0.05
CARRY_MS: int = 15 * 60 * 1000  # 15 min
RESYNC_GAP_MS: int = 60 * 60 * 1000  # 1 h
STALE_HOLD_MS: int = 15 * 60 * 1000  # 15 min
DRY_H: float = 0.10
DRY_CLEAR_H: float = 0.15
SHORT_FIRE_H: float = 2.0
SHORT_CLEAR_H: float = 0.5
ACCT_HI: float = 0.90
ACCT_REARM: float = 0.85
ACCT_PAGE_MAX_H: float = 1.0
FORECAST_ZERO_H: float = 0.02
BLIND_MS: int = 60 * 60 * 1000  # 60 min
HORIZON_MS: int = 24 * 60 * 60 * 1000  # 24 h
STEP_MS: int = 5 * 60 * 1000  # 5 min
K_MIN_BURN: float = 0.5
STALE_INPUT_MS: int = 20 * 60 * 1000  # 20 min

NY_TZ = ZoneInfo("America/New_York")
RECORD_TIMEOUT_S: float = 30.0


class QuotaRecordError(RuntimeError):
    """Raised when recording runs into the ledger fails."""


@dataclasses.dataclass
class ReplayEvent:
    ts: int
    kind: str  # "pool-dry" | "shortfall" | "account-high"
    action: str  # "fire" | "clear"
    metrics: dict[str, Any] = dataclasses.field(default_factory=dict)

    def __str__(self) -> str:
        et = datetime.datetime.fromtimestamp(self.ts / 1000, tz=NY_TZ).strftime("%Y-%m-%d %H:%M")
        if self.kind == "pool-dry":
            symbol = "DRY+" if self.action == "fire" else "DRY-"
            if self.action == "fire":
                return f"{et} {symbol} H0={self.metrics.get('H0', 0.0):.3f} spill15=${self.metrics.get('spill_15m', 0.0):.1f}"
            return f"{et} {symbol} H0={self.metrics.get('H0', 0.0):.3f}"
        elif self.kind == "shortfall":
            symbol = "SHORT+" if self.action == "fire" else "SHORT-"
            if self.action == "fire":
                k_val = round(self.metrics["k"]) if self.metrics.get("k") is not None else "None"
                return (
                    f"{et} {symbol} zero_h={self.metrics.get('zero_h', 0.0):.1f} "
                    f"H0={self.metrics.get('H0', 0.0):.2f} "
                    f"burn={self.metrics.get('B', 0.0):.3f} "
                    f"k={k_val}"
                )
            return f"{et} {symbol} zero_h={self.metrics.get('zero_h', 0.0):.1f}"
        elif self.kind == "account-high":
            symbol = "ACCT_HI+" if self.action == "fire" else "ACCT_HI-"
            page_str = f" page={'yes' if self.metrics.get('page') else 'no'}" if self.action == "fire" else ""
            return f"{et} {symbol} {self.metrics.get('account')} u7d={self.metrics.get('u7d', 0.0):.2f}{page_str}"
        return f"{et} {self.kind} {self.action}"


class Accumulator:
    """High-water mark burn accumulator per account."""

    def __init__(self, excluded: set[str] | None = None) -> None:
        self.excluded: set[str] = set(excluded or [])
        self.st: dict[str, dict[str, Any]] = {}
        self.burn_events: list[tuple[int, float]] = []

    def feed(self, ts: int, account: str, u7d: float | None, r7d: int | None) -> None:
        if account in self.excluded:
            return
        if u7d is None:
            return

        if account not in self.st:
            self.st[account] = {"hw": u7d, "last_ts": ts, "r": r7d}
            return

        s = self.st[account]
        gap = ts - s["last_ts"]
        crossed = s["r"] is not None and ts >= s["r"]

        if gap > RESYNC_GAP_MS:
            s["hw"] = u7d
        elif (s["hw"] - u7d > RESET_DROP) or (crossed and u7d < s["hw"]):
            # Reset detected
            self.burn_events.append((ts, u7d))
            s["hw"] = u7d
        elif crossed and (ts - s["r"] <= STALE_HOLD_MS):
            # Stale tick after r7d: hold
            s["last_ts"] = ts
            return
        elif u7d > s["hw"]:
            self.burn_events.append((ts, u7d - s["hw"]))
            s["hw"] = u7d
        # else: jitter

        s["last_ts"] = ts
        if r7d is not None:
            s["r"] = r7d

    def burn(self, T: int, W: int) -> float:
        """Sum burn events over (T - W, T]."""
        idx_start = bisect.bisect_left(self.burn_events, (T - W + 1, 0.0))
        idx_end = bisect.bisect_right(self.burn_events, (T, float("inf")))
        return sum(amt for _, amt in self.burn_events[idx_start:idx_end])


def compute_burn_events(
    samples: Sequence[tuple[int, str, float | None, int | None]],
    excluded: set[str] | None = None,
) -> list[tuple[int, float]]:
    acc = Accumulator(excluded=excluded)
    for ts, account, u7d, r7d in sorted(samples, key=lambda r: r[0]):
        acc.feed(ts, account, u7d, r7d)
    return acc.burn_events


class PoolTracker:
    """Incremental pool tracker across ticks.

    Tracks present accounts, carries u7d <= CARRY_MS, records latest non-null r7d,
    and excludes both explicitly excluded accounts and accounts with no non-null
    u7d in the loaded window.
    """

    def __init__(self, excluded: set[str] | None = None) -> None:
        self.excluded: set[str] = set(excluded or [])
        self.seen: collections.Counter[str] = collections.Counter()
        self.all_null: collections.Counter[str] = collections.Counter()
        self.last_u: dict[str, tuple[float, int]] = {}  # account -> (u7d, tick_ts)
        self.latest_r7d: dict[str, int] = {}  # account -> latest non-null r7d
        self.present_accounts: set[str] = set()
        self.current_tick: int = 0

    def feed_tick(
        self,
        T: int,
        rows: Sequence[tuple[str, float | None, int | None]],
    ) -> None:
        self.current_tick = T
        self.present_accounts = set()
        for account, u7d, r7d in rows:
            self.present_accounts.add(account)
            self.seen[account] += 1
            if u7d is None:
                self.all_null[account] += 1
            else:
                self.last_u[account] = (u7d, T)

            if r7d is not None:
                self.latest_r7d[account] = r7d

    def pool(self) -> dict[str, tuple[float, int | None]]:
        auto_excluded = {a for a in self.seen if self.seen[a] == self.all_null[a]}
        full_excluded = auto_excluded | self.excluded
        res: dict[str, tuple[float, int | None]] = {}
        for account in self.present_accounts:
            if account in full_excluded:
                continue
            if account in self.last_u:
                u_val, u_ts = self.last_u[account]
                if self.current_tick - u_ts <= CARRY_MS:
                    r_eff = self.latest_r7d.get(account)
                    res[account] = (u_val, r_eff)
        return res


def pool_at(
    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] | Sequence[tuple[int, str, float | None, int | None]],
    T: int,
    excluded: set[str] | None = None,
) -> dict[str, tuple[float, int | None]]:
    """Determine pool membership and effective (u7d, r7d) at tick T."""
    tracker = PoolTracker(excluded=excluded)
    ticks_map: dict[int, list[tuple[str, float | None, int | None]]]
    if isinstance(samples_by_tick, dict):
        ticks_map = samples_by_tick
    else:
        ticks_map = collections.defaultdict(list)
        for ts, account, u7d, r7d in samples_by_tick:
            ticks_map[ts].append((account, u7d, r7d))

    for tick in sorted(t for t in ticks_map if t <= T):
        tracker.feed_tick(tick, ticks_map[tick])
    return tracker.pool()


def estimate_k(burn_7d: float, max_usd_7d: float) -> float | None:
    """k (local) = 7-day Max $ / 7-day burn; None if burn_7d < K_MIN_BURN."""
    if burn_7d < K_MIN_BURN:
        return None
    return max_usd_7d / burn_7d


def burn_rate(
    burn_6h: float,
    burn_24h: float,
    spill_6h: float,
    spill_24h: float,
    k: float | None,
) -> float:
    """Burn rate B = max(rate(6), rate(24)) in units/h."""
    rate_6h = (burn_6h + ((spill_6h / k) if k else 0.0)) / 6.0
    rate_24h = (burn_24h + ((spill_24h / k) if k else 0.0)) / 24.0
    return max(rate_6h, rate_24h)


def forecast(
    H0: float,
    B: float,
    refills: list[tuple[int, float]],
    k: float | None,
    T: int,
    path: list[tuple[int, float]] | None = None,
) -> tuple[float, float | None, tuple[int, float] | None]:
    """Forecast zero headroom hours over 24h horizon in 5-min steps.

    next_refill is the earliest upcoming refill of any pool account even if beyond the horizon.
    The simulation only includes refills within the 24h horizon.
    If path is provided, appends (t, h) for T and each 5-min step through the 24h horizon.
    Returns (zero_h, vertex_usd, next_refill).
    """
    sorted_all = sorted(refills, key=lambda r: r[0])
    next_refill = sorted_all[0] if sorted_all else None
    sim_refills = [ref for ref in sorted_all if ref[0] <= T + HORIZON_MS]

    h = H0
    zero_h = 0.0
    t = T
    i = 0
    step_h = STEP_MS / 3600_000.0

    if path is not None:
        path.append((t, h))

    while t < T + HORIZON_MS:
        t += STEP_MS
        h = max(0.0, h - B * step_h)
        while i < len(sim_refills) and sim_refills[i][0] <= t:
            h += sim_refills[i][1]
            i += 1
        if path is not None:
            path.append((t, h))
        if h < FORECAST_ZERO_H:
            zero_h += step_h

    vertex_usd = (zero_h * B * k) if k is not None else None
    return zero_h, vertex_usd, next_refill


def format_dt_et(ts: int) -> str:
    return datetime.datetime.fromtimestamp(ts / 1000, tz=NY_TZ).strftime("%m-%d %H:%M ET")


def step_alerts(
    state: dict[str, Any],
    metrics: dict[str, Any],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Pure alert state transition step.

    Returns (new_state, actions).
    Actions have keys: type ("send" | "clear"), kind, name, signature, text, ttl, max.
    """
    new_state: dict[str, Any] = {}
    actions: list[dict[str, Any]] = []

    H0: float = metrics.get("H0", 0.0)
    zero_h: float = metrics.get("zero_h", 0.0)
    spill_15m: float = metrics.get("spill_15m", 0.0)
    spill_30m: float = metrics.get("spill_30m", 0.0)
    pool: dict[str, tuple[float, int | None]] = metrics.get("pool", {})
    B: float = metrics.get("B", 0.0)
    k: float | None = metrics.get("k")
    vertex_usd: float | None = metrics.get("vertex_usd")
    next_refill: tuple[int, float] | None = metrics.get("next_refill")

    refill_str = (
        f"Next refill: {format_dt_et(next_refill[0])}, +{next_refill[1]:.2f}.\n"
        if next_refill else "Next refill: none known.\n"
    )
    burn_str = f"burn {B:.3f}/h" + (f" (one account every ~{1 / B:.0f} h)" if B > 0 else "")
    vertex_str = (
        f", about ${round(vertex_usd)} of Vertex cash at the current rate" if vertex_usd is not None else ""
    )
    hot_accts = sorted(
        [f"{a} {u:.2f}" for a, (u, _) in pool.items() if u >= ACCT_HI]
    )
    hot_str = (
        f"Accounts at or above {ACCT_HI:.2f}: " + ", ".join(hot_accts) + ".\n"
        if hot_accts else ""
    )
    units_note = (
        "Headroom is in account-weeks: the sum over accounts of max(0, "
        f"{CAP:.2f} - u7d); teamclaude stops using an account at about {CAP:.2f}. "
        + (
            f"The Vertex $ are cloudbox's alone (devbox and the Mac spill on their own), "
            f"estimated with k(local)={round(k)}: cloudbox's notional Max $ per account-week "
            "of pool burn over the last 7 days."
            if k is not None
            else "No Vertex $ estimate: too little burn in the last 7 days to fit k."
        )
    )

    # 1. pool-dry alert
    was_dry: bool = bool(state.get("pool_dry", False))
    is_dry: bool
    if not was_dry:
        is_dry = (H0 < DRY_H) and (spill_15m > 0)
    else:
        if (H0 >= DRY_CLEAR_H) or (spill_30m == 0):
            is_dry = False
        else:
            is_dry = True

    new_state["pool_dry"] = is_dry
    if was_dry and not is_dry:
        actions.append({"type": "clear", "kind": "pool-dry", "name": "pool-dry"})
    elif is_dry:
        text = (
            "Claude Max pool is DRY: Max traffic is spilling to Vertex, which is cash.\n"
            f"${spill_15m:.2f} spilled in the last 15 min. Headroom {H0:.3f}, {burn_str}.\n"
            + hot_str
            + refill_str
            + f"Forecast: {zero_h:.1f} h dry in the next 24 h{vertex_str}.\n"
            + units_note
        )
        actions.append({
            "type": "send",
            "kind": "pool-dry",
            "name": "pool-dry",
            "signature": "quota-pool-dry",
            "text": text,
            "ttl": 900,
            "max": 14400,
        })

    # 2. shortfall alert
    was_short: bool = bool(state.get("shortfall", False))
    is_short: bool
    if not was_short:
        is_short = zero_h >= SHORT_FIRE_H
    else:
        if zero_h < SHORT_CLEAR_H:
            is_short = False
        else:
            is_short = True

    new_state["shortfall"] = is_short
    if was_short and not is_short:
        actions.append({"type": "clear", "kind": "shortfall", "name": "shortfall"})
    elif is_short and not is_dry:
        # Not sent while pool-dry is active
        text = (
            f"Claude Max pool is projected to run dry: {zero_h:.1f} h at zero headroom "
            f"in the next 24 h{vertex_str}.\n"
            f"Now: headroom {H0:.3f}, {burn_str}.\n"
            + hot_str
            + refill_str
            + units_note
        )
        actions.append({
            "type": "send",
            "kind": "shortfall",
            "name": "shortfall",
            "signature": "quota-shortfall",
            "text": text,
            "ttl": 3600,
            "max": 14400,
        })

    # 3. account-high alerts
    old_acct_high = dict(state.get("acct_high", {}))
    new_acct_high = dict(old_acct_high)

    for account, (u_eff, r7d_eff) in pool.items():
        sanitized = re.sub(r"[^A-Za-z0-9._-]", "_", account)
        name = f"acct-{sanitized}"
        sig = f"quota-acct:{account}"
        was_latched = bool(old_acct_high.get(account, False))

        if u_eff >= ACCT_HI:
            if not was_latched:
                new_acct_high[account] = True
                should_page = H0 < ACCT_PAGE_MAX_H
                if should_page:
                    reset_text = f"It resets {format_dt_et(r7d_eff)}.\n" if r7d_eff else ""
                    text = (
                        f"Claude Max account '{account}' is at u7d={u_eff:.2f} "
                        f"(warning at {ACCT_HI:.2f}; teamclaude stops using it at about {CAP:.2f}).\n"
                        + reset_text
                        + f"Pool headroom {H0:.3f} account-weeks, {burn_str}."
                    )
                    actions.append({
                        "type": "send",
                        "kind": "account-high",
                        "name": name,
                        "signature": sig,
                        "text": text,
                        "ttl": 0,
                        "max": 14400,
                    })
        elif u_eff < ACCT_REARM:
            if was_latched:
                new_acct_high[account] = False
                actions.append({
                    "type": "clear",
                    "kind": "account-high",
                    "name": name,
                })

    new_state["acct_high"] = new_acct_high
    return new_state, actions


def sum_buckets(buckets: dict[int, float], T: int, W: int) -> float:
    """Sum bucket values over window (T - W, T] with T - W <= b < T."""
    end_b = (T // STEP_MS) * STEP_MS
    start_b = end_b - W
    return sum(buckets.get(b, 0.0) for b in range(start_b, end_b, STEP_MS))


def parse_et_datetime(val: str | None, end_of_day_for_date: bool = False) -> int:
    """Parse ISO date or datetime string, interpreting naive datetimes in America/New_York.

    If given as date only (YYYY-MM-DD) and end_of_day_for_date=True, returns the next midnight ET.
    """
    if val is None or val == "now":
        return int(time.time() * 1000)
    val = val.strip()
    is_date_only = len(val) == 10 and val.count("-") == 2 and "T" not in val and " " not in val
    try:
        dt = datetime.datetime.fromisoformat(val)
    except Exception as e:
        raise ValueError(f"Invalid ISO datetime string: {val}") from e

    if is_date_only and end_of_day_for_date:
        dt = dt + datetime.timedelta(days=1)

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=NY_TZ)
    else:
        dt = dt.astimezone(NY_TZ)
    return int(dt.timestamp() * 1000)


def load_inputs(
    conn: sqlite3.Connection,
    since_ms: int,
    host: str | None = None,
) -> tuple[list[tuple[int, str, float | None, int | None]], dict[int, float], dict[int, float]]:
    """Load samples and 5-minute buckets of spillover $ and Max $ since since_ms."""
    cur = conn.execute(
        "SELECT ts, account, u7d, r7d FROM quota_samples WHERE ts >= ? ORDER BY ts ASC, account ASC",
        (since_ms,),
    )
    samples = cur.fetchall()

    if host is not None:
        spill_cur = conn.execute(
            "SELECT (q.ts / 300000) * 300000 AS b, SUM(q.cost_usd) "
            "FROM requests q JOIN route r USING(request_id) "
            "WHERE q.ts >= ? AND r.desired = 'max' AND q.backend = 'vertex' AND q.host = ? "
            "GROUP BY b",
            (since_ms, host),
        )
        max_cur = conn.execute(
            "SELECT (ts / 300000) * 300000 AS b, SUM(cost_usd) "
            "FROM requests "
            "WHERE ts >= ? AND backend = 'max' AND host = ? "
            "GROUP BY b",
            (since_ms, host),
        )
    else:
        spill_cur = conn.execute(
            "SELECT (q.ts / 300000) * 300000 AS b, SUM(q.cost_usd) "
            "FROM requests q JOIN route r USING(request_id) "
            "WHERE q.ts >= ? AND r.desired = 'max' AND q.backend = 'vertex' "
            "GROUP BY b",
            (since_ms,),
        )
        max_cur = conn.execute(
            "SELECT (ts / 300000) * 300000 AS b, SUM(cost_usd) "
            "FROM requests "
            "WHERE ts >= ? AND backend = 'max' "
            "GROUP BY b",
            (since_ms,),
        )

    spill_buckets = {
        row[0]: float(row[1]) for row in spill_cur if row[0] is not None and row[1] is not None
    }
    max_buckets = {
        row[0]: float(row[1]) for row in max_cur if row[0] is not None and row[1] is not None
    }

    return samples, spill_buckets, max_buckets


def load_or_seed_state(
    state_path: str,
    pool: dict[str, tuple[float, int | None]],
) -> tuple[dict[str, Any], bool]:
    """Load state.json; if missing or corrupt, warn on stderr, start fresh, and seed acct_high silently."""
    is_fresh = False
    state: dict[str, Any] = {}
    if not os.path.exists(state_path):
        is_fresh = True
        sys.stderr.write("quota-watch: state missing or corrupt (file not found); starting fresh\n")
    else:
        try:
            with open(state_path, "r", encoding="utf-8") as f:
                raw = json.load(f)
            if not isinstance(raw, dict):
                is_fresh = True
                sys.stderr.write("quota-watch: state missing or corrupt (not a dict); starting fresh\n")
            elif not isinstance(raw.get("acct_high"), dict):
                is_fresh = True
                sys.stderr.write("quota-watch: state missing or corrupt (acct_high not a dict); starting fresh\n")
            else:
                state = raw
        except Exception as e:
            is_fresh = True
            sys.stderr.write(f"quota-watch: state missing or corrupt ({e}); starting fresh\n")

    if is_fresh:
        state = {
            "pool_dry": False,
            "shortfall": False,
            "acct_high": {},
        }
        for account, (u_eff, _) in pool.items():
            if u_eff >= ACCT_HI:
                state["acct_high"][account] = True

    return state, is_fresh


def record_run(
    db: str,
    row: dict[str, Any] | Sequence[Any],
    path: list[tuple[int, float]] | None = None,
    timeout: float | None = None,
) -> None:
    """Record quota watch run and forecast path in the ledger.

    Best-effort: catches sqlite3.Error, OSError, and ImportError, writes warning to stderr, returns.
    """
    t = RECORD_TIMEOUT_S if timeout is None else timeout
    try:
        from llm_ledger import QUOTA_WATCH_SCHEMA_SQL

        if isinstance(row, dict):
            row_tuple = (
                row["ts"],
                row["h0"],
                row["burn_h"],
                row.get("burn_6h"),
                row.get("burn_24h"),
                row.get("spill_6h"),
                row.get("spill_24h"),
                row.get("k"),
                row["zero_h"],
                row.get("vertex_usd"),
                row.get("next_refill_ts"),
                row.get("next_refill_amt"),
                row["pool_n"],
                row.get("source", "live"),
            )
            run_ts = row["ts"]
        else:
            row_tuple = tuple(row)
            run_ts = row_tuple[0]

        conn = sqlite3.connect(db, timeout=t)
        try:
            with conn:
                for stmt in QUOTA_WATCH_SCHEMA_SQL.strip().split(";"):
                    stmt = stmt.strip()
                    if stmt:
                        conn.execute(stmt)
                conn.execute(
                    """INSERT OR REPLACE INTO quota_watch_runs (
  ts, h0, burn_h, burn_6h, burn_24h, spill_6h, spill_24h,
  k, zero_h, vertex_usd, next_refill_ts, next_refill_amt,
  pool_n, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    row_tuple,
                )
                if path:
                    conn.execute("DELETE FROM quota_forecast")
                    forecast_rows = [(t, h, run_ts) for t, h in path]
                    conn.executemany(
                        "INSERT INTO quota_forecast (ts, headroom, run_ts) VALUES (?, ?, ?)",
                        forecast_rows,
                    )
        finally:
            conn.close()
    except (sqlite3.Error, OSError, ImportError) as e:
        sys.stderr.write(f"quota-watch: could not record run: {e}\n")
        return


def record_replay_runs(
    db: str,
    rows: list[tuple[Any, ...]],
    timeout: float | None = None,
) -> int:
    """Record replay runs into quota_watch_runs using INSERT OR IGNORE in one transaction.

    Returns the number of rows inserted and prints how many rows inserted.
    """
    if not rows:
        print("quota-replay: recorded 0 rows")
        return 0
    from llm_ledger import QUOTA_WATCH_SCHEMA_SQL

    t = RECORD_TIMEOUT_S if timeout is None else timeout
    try:
        conn = sqlite3.connect(db, timeout=t)
        try:
            with conn:
                for stmt in QUOTA_WATCH_SCHEMA_SQL.strip().split(";"):
                    stmt = stmt.strip()
                    if stmt:
                        conn.execute(stmt)
                changes_before = conn.total_changes
                conn.executemany(
                    """INSERT OR IGNORE INTO quota_watch_runs (
  ts, h0, burn_h, burn_6h, burn_24h, spill_6h, spill_24h,
  k, zero_h, vertex_usd, next_refill_ts, next_refill_amt,
  pool_n, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    rows,
                )
                inserted = conn.total_changes - changes_before
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as e:
        sys.stderr.write(f"quota-replay: could not record: {e}\n")
        raise QuotaRecordError(str(e)) from e
    print(f"quota-replay: recorded {inserted} rows")
    return inserted


def run_live(
    db: str,
    state_dir: str,
    alert_cmd: str | None = None,
    now: float | None = None,
    excluded: set[str] | None = None,
    host: str | None = None,
) -> int:
    """Run live quota watch check."""
    host = host or socket.gethostname()
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30.0)
    try:
        row = conn.execute("SELECT max(ts) FROM quota_samples").fetchone()
        T: int | None = row[0] if (row and row[0] is not None) else None

        req_row = conn.execute("SELECT max(ts) FROM requests WHERE host = ?", (host,)).fetchone()
        req_T: int | None = req_row[0] if (req_row and req_row[0] is not None) else None

        if now is None:
            now_ms = int(time.time() * 1000)
        elif now < 1e11:
            now_ms = int(now * 1000)
        else:
            now_ms = int(now)

        # Blind-spot alert check:
        # if now - T > BLIND_MS = 60 min, OR newest requests.ts for host is older than now - 60 min
        blind_reasons: list[str] = []
        if T is None:
            blind_reasons.append("quota_samples has no rows")
        elif now_ms - T > BLIND_MS:
            stale_s_min = (now_ms - T) / 60000.0
            blind_reasons.append(f"quota_samples is {stale_s_min:.1f} min old")

        if req_T is None:
            blind_reasons.append(f"requests for host '{host}' has no rows")
        elif now_ms - req_T > BLIND_MS:
            stale_r_min = (now_ms - req_T) / 60000.0
            blind_reasons.append(f"requests for host '{host}' is {stale_r_min:.1f} min old")

        blind_file = os.path.join(state_dir, "blind.alert")
        if blind_reasons:
            stale_desc = " and ".join(blind_reasons)
            blind_text = (
                f"Claude Max quota watch blind spot: {stale_desc} (threshold {BLIND_MS // 60000} min). "
                "Quota alerts are not trustworthy until it recovers."
            )
            if alert_cmd:
                argv = [
                    alert_cmd,
                    blind_file,
                    "quota-watch-blind",
                    blind_text,
                    "3600",
                    "14400",
                ]
                try:
                    res = subprocess.run(argv, timeout=60)
                    if res.returncode != 0:
                        sys.stderr.write(f"warning: alert command exited with code {res.returncode}: {argv}\n")
                except subprocess.TimeoutExpired:
                    sys.stderr.write(f"warning: alert command timed out after 60s: {argv}\n")
            else:
                print(f"would-alert: quota-watch-blind ttl=3600 max=14400 text={blind_text}")
        else:
            if os.path.exists(blind_file):
                try:
                    os.remove(blind_file)
                except OSError:
                    pass

        # 20-min stale skip
        if T is None:
            print("quota-watch: no quota samples found; skipping")
            return 0

        if now_ms - T > STALE_INPUT_MS:
            stale_min = (now_ms - T) / 60000.0
            print(f"quota-watch: stale input (last sample T was {stale_min:.1f} min ago); skipping")
            return 0

        since_ms = T - 8 * 24 * 3600 * 1000
        samples, spill_buckets, max_buckets = load_inputs(conn, since_ms, host=host)
    finally:
        conn.close()

    acc = Accumulator(excluded=excluded)
    tracker = PoolTracker(excluded=excluded)

    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] = collections.defaultdict(list)
    for ts, a, u, r in samples:
        samples_by_tick[ts].append((a, u, r))

    for ts in sorted(samples_by_tick):
        rows = samples_by_tick[ts]
        tracker.feed_tick(ts, rows)
        for a, u, r in rows:
            acc.feed(ts, a, u, r)

    pool = tracker.pool()
    H0 = sum(max(0.0, CAP - u) for u, _ in pool.values())
    burn_7d = acc.burn(T, 7 * 24 * 3600 * 1000)
    max_7d = sum_buckets(max_buckets, T, 7 * 24 * 3600 * 1000)
    k = estimate_k(burn_7d, max_7d)

    burn_6h = acc.burn(T, 6 * 3600 * 1000)
    burn_24h = acc.burn(T, 24 * 3600 * 1000)
    spill_6h = sum_buckets(spill_buckets, T, 6 * 3600 * 1000)
    spill_24h = sum_buckets(spill_buckets, T, 24 * 3600 * 1000)
    B = burn_rate(burn_6h, burn_24h, spill_6h, spill_24h, k)

    all_refills = [
        (max(r, T + STEP_MS), min(u, CAP))
        for _, (u, r) in pool.items()
        if r is not None
    ]
    forecast_path: list[tuple[int, float]] = []
    zero_h, vertex_usd, next_refill = forecast(H0, B, all_refills, k, T, path=forecast_path)

    spill_15m = sum_buckets(spill_buckets, T, 15 * 60 * 1000)
    spill_30m = sum_buckets(spill_buckets, T, 30 * 60 * 1000)

    state_path = os.path.join(state_dir, "state.json")
    state, is_fresh = load_or_seed_state(state_path, pool)

    metrics = {
        "H0": H0,
        "zero_h": zero_h,
        "spill_15m": spill_15m,
        "spill_30m": spill_30m,
        "pool": pool,
        "B": B,
        "k": k,
        "vertex_usd": vertex_usd,
        "next_refill": next_refill,
        "T": T,
    }

    new_state, actions = step_alerts(state, metrics)

    # Persist state atomically
    os.makedirs(state_dir, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(prefix="state-", suffix=".tmp", dir=state_dir)
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
        json.dump(new_state, f)
    os.replace(tmp_path, state_path)

    # Process actions
    for action in actions:
        alert_file = os.path.join(state_dir, f"{action['name']}.alert")
        if action["type"] == "clear":
            if os.path.exists(alert_file):
                try:
                    os.remove(alert_file)
                except OSError:
                    pass
        elif action["type"] == "send":
            if alert_cmd:
                argv = [
                    alert_cmd,
                    alert_file,
                    action["signature"],
                    action["text"],
                    str(action["ttl"]),
                    str(action["max"]),
                ]
                try:
                    res = subprocess.run(argv, timeout=60)
                    if res.returncode != 0:
                        sys.stderr.write(f"warning: alert command exited with code {res.returncode}: {argv}\n")
                except subprocess.TimeoutExpired:
                    sys.stderr.write(f"warning: alert command timed out after 60s: {argv}\n")
            else:
                print(f"would-alert: {action['signature']} ttl={action['ttl']} max={action['max']} text={action['text']}")

    # Record run and forecast path in the ledger (best-effort)
    run_row = {
        "ts": T,
        "h0": H0,
        "burn_h": B,
        "burn_6h": burn_6h,
        "burn_24h": burn_24h,
        "spill_6h": spill_6h,
        "spill_24h": spill_24h,
        "k": k,
        "zero_h": zero_h,
        "vertex_usd": vertex_usd,
        "next_refill_ts": next_refill[0] if next_refill else None,
        "next_refill_amt": next_refill[1] if next_refill else None,
        "pool_n": len(pool),
        "source": "live",
    }
    record_run(db, run_row, forecast_path)

    # Print summary line
    t_et = datetime.datetime.fromtimestamp(T / 1000, tz=NY_TZ).strftime("%Y-%m-%d %H:%M")
    k_str = str(round(k)) if k is not None else "none"
    v_str = f"${round(vertex_usd)}" if vertex_usd is not None else "none"
    pool_dry_str = "yes" if new_state.get("pool_dry") else "no"
    short_str = "yes" if new_state.get("shortfall") else "no"
    acct_hi_cnt = sum(1 for v in new_state.get("acct_high", {}).values() if v)

    print(
        f"quota-watch T={t_et} headroom={H0:.2f} burn={B:.3f}/h k(local)={k_str} "
        f"dry_h={zero_h:.1f} vertex≈{v_str} pool_dry={pool_dry_str} short={short_str} acct_hi={acct_hi_cnt}"
    )
    return 0


def replay(
    db: str,
    since_ms: int,
    until_ms: int,
    excluded: set[str] | None = None,
    host: str | None = None,
    record: bool = False,
) -> list[ReplayEvent]:
    """Replay quota watch evaluation tick-by-tick."""
    host = host or socket.gethostname()
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30.0)
    try:
        warmup_since = since_ms - 8 * 24 * 3600 * 1000
        samples, spill_buckets, max_buckets = load_inputs(conn, warmup_since, host=host)
    finally:
        conn.close()

    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] = collections.defaultdict(list)
    for ts, a, u, r in samples:
        samples_by_tick[ts].append((a, u, r))

    acc = Accumulator(excluded=excluded)
    tracker = PoolTracker(excluded=excluded)
    alert_state: dict[str, Any] = {}
    events: list[ReplayEvent] = []
    replay_rows: list[tuple[Any, ...]] = []

    for T in sorted(samples_by_tick):
        rows = samples_by_tick[T]
        tracker.feed_tick(T, rows)
        for a, u, r in rows:
            acc.feed(T, a, u, r)

        if T < since_ms:
            continue
        if T > until_ms:
            break

        pool = tracker.pool()
        H0 = sum(max(0.0, CAP - u) for u, _ in pool.values())
        burn_7d = acc.burn(T, 7 * 24 * 3600 * 1000)
        max_7d = sum_buckets(max_buckets, T, 7 * 24 * 3600 * 1000)
        k = estimate_k(burn_7d, max_7d)

        burn_6h = acc.burn(T, 6 * 3600 * 1000)
        burn_24h = acc.burn(T, 24 * 3600 * 1000)
        spill_6h = sum_buckets(spill_buckets, T, 6 * 3600 * 1000)
        spill_24h = sum_buckets(spill_buckets, T, 24 * 3600 * 1000)
        B = burn_rate(burn_6h, burn_24h, spill_6h, spill_24h, k)

        all_refills = [
            (max(r, T + STEP_MS), min(u, CAP))
            for _, (u, r) in pool.items()
            if r is not None
        ]
        zero_h, vertex_usd, next_refill = forecast(H0, B, all_refills, k, T)

        replay_rows.append(
            (
                T,
                H0,
                B,
                burn_6h,
                burn_24h,
                spill_6h,
                spill_24h,
                k,
                zero_h,
                vertex_usd,
                next_refill[0] if next_refill else None,
                next_refill[1] if next_refill else None,
                len(pool),
                "replay",
            )
        )

        spill_15m = sum_buckets(spill_buckets, T, 15 * 60 * 1000)
        spill_30m = sum_buckets(spill_buckets, T, 30 * 60 * 1000)

        metrics = {
            "H0": H0,
            "zero_h": zero_h,
            "spill_15m": spill_15m,
            "spill_30m": spill_30m,
            "pool": pool,
            "B": B,
            "k": k,
            "vertex_usd": vertex_usd,
            "next_refill": next_refill,
            "T": T,
        }

        new_alert_state, _ = step_alerts(alert_state, metrics)

        # Detect transitions
        was_dry = bool(alert_state.get("pool_dry", False))
        is_dry = bool(new_alert_state.get("pool_dry", False))
        if not was_dry and is_dry:
            events.append(ReplayEvent(ts=T, kind="pool-dry", action="fire", metrics={"H0": H0, "spill_15m": spill_15m}))
        elif was_dry and not is_dry:
            events.append(ReplayEvent(ts=T, kind="pool-dry", action="clear", metrics={"H0": H0}))

        was_short = bool(alert_state.get("shortfall", False))
        is_short = bool(new_alert_state.get("shortfall", False))
        if not was_short and is_short:
            events.append(ReplayEvent(ts=T, kind="shortfall", action="fire", metrics={"zero_h": zero_h, "H0": H0, "B": B, "k": k}))
        elif was_short and not is_short:
            events.append(ReplayEvent(ts=T, kind="shortfall", action="clear", metrics={"zero_h": zero_h}))

        old_acct = alert_state.get("acct_high", {})
        new_acct = new_alert_state.get("acct_high", {})
        for a, latched in new_acct.items():
            was_latched = bool(old_acct.get(a, False))
            if not was_latched and latched:
                u_val = pool.get(a, (0.0, None))[0]
                should_page = H0 < ACCT_PAGE_MAX_H
                events.append(
                    ReplayEvent(
                        ts=T,
                        kind="account-high",
                        action="fire",
                        metrics={"account": a, "u7d": u_val, "page": should_page},
                    )
                )
            elif was_latched and not latched:
                u_val = pool.get(a, (0.0, None))[0]
                events.append(
                    ReplayEvent(
                        ts=T,
                        kind="account-high",
                        action="clear",
                        metrics={"account": a, "u7d": u_val},
                    )
                )

        alert_state = new_alert_state

    if record:
        record_replay_runs(db, replay_rows)

    return events
