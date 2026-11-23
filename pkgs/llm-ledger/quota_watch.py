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
import subprocess
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
DRY_H: float = 0.02
DRY_CLEAR_H: float = 0.05
SHORT_FIRE_H: float = 2.0
SHORT_CLEAR_H: float = 0.5
ACCT_HI: float = 0.90
ACCT_REARM: float = 0.85
HORIZON_MS: int = 24 * 60 * 60 * 1000  # 24 h
STEP_MS: int = 5 * 60 * 1000  # 5 min
K_MIN_BURN: float = 0.5
STALE_INPUT_MS: int = 20 * 60 * 1000  # 20 min

NY_TZ = ZoneInfo("America/New_York")


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
            return f"{et} {symbol} {self.metrics.get('account')} u7d={self.metrics.get('u7d', 0.0):.2f}"
        return f"{et} {self.kind} {self.action}"


class Accumulator:
    """High-water mark burn accumulator per account."""

    def __init__(self) -> None:
        self.st: dict[str, dict[str, Any]] = {}
        self.burn_events: list[tuple[int, float]] = []

    def feed(self, ts: int, account: str, u7d: float | None, r7d: int | None) -> None:
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
) -> list[tuple[int, float]]:
    acc = Accumulator()
    for ts, account, u7d, r7d in sorted(samples, key=lambda r: r[0]):
        acc.feed(ts, account, u7d, r7d)
    return acc.burn_events


def pool_at(
    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] | list[tuple[int, str, float | None, int | None]],
    T: int,
    excluded: set[str] | None = None,
) -> dict[str, tuple[float, int | None]]:
    """Determine pool membership and effective (u7d, r7d) at tick T.

    Accounts with no non-null u7d in the loaded window are auto-excluded.
    Accounts in excluded are excluded.
    Accounts absent from tick T are excluded.
    Null u7d at tick T is carried for up to CARRY_MS; otherwise dropped.
    """
    ticks_map: dict[int, list[tuple[str, float | None, int | None]]]
    if isinstance(samples_by_tick, list):
        ticks_map = collections.defaultdict(list)
        for ts, account, u7d, r7d in samples_by_tick:
            ticks_map[ts].append((account, u7d, r7d))
    else:
        ticks_map = samples_by_tick

    # Detect accounts with no non-null u7d in the entire loaded window
    seen: collections.Counter[str] = collections.Counter()
    all_null: collections.Counter[str] = collections.Counter()
    for ts, rows in ticks_map.items():
        for account, u7d, _ in rows:
            seen[account] += 1
            if u7d is None:
                all_null[account] += 1

    auto_excluded = {a for a in seen if seen[a] == all_null[a]}
    full_excluded = auto_excluded | (excluded or set())

    current_rows = ticks_map.get(T, [])
    current_accounts = {r[0]: (r[1], r[2]) for r in current_rows}

    pool: dict[str, tuple[float, int | None]] = {}
    for account, (u_curr, r_curr) in current_accounts.items():
        if account in full_excluded:
            continue

        if u_curr is not None:
            r_eff = r_curr
            if r_eff is None:
                # Find latest non-null r7d up to T
                for ts in sorted((t for t in ticks_map if t <= T), reverse=True):
                    for a, _, r in ticks_map[ts]:
                        if a == account and r is not None:
                            r_eff = r
                            break
                    if r_eff is not None:
                        break
            pool[account] = (u_curr, r_eff)
        else:
            # Carry forward last non-null u7d within CARRY_MS
            prev_u: float | None = None
            prev_r: int | None = None
            for ts in sorted((t for t in ticks_map if t < T), reverse=True):
                if T - ts > CARRY_MS:
                    break
                for a, u, r in ticks_map[ts]:
                    if a == account and u is not None:
                        prev_u = u
                        prev_r = r
                        break
                if prev_u is not None:
                    break

            if prev_u is not None:
                # If prev_r is None, look back further for r7d
                if prev_r is None:
                    for ts in sorted((t for t in ticks_map if t <= T), reverse=True):
                        for a, _, r in ticks_map[ts]:
                            if a == account and r is not None:
                                prev_r = r
                                break
                        if prev_r is not None:
                            break
                pool[account] = (prev_u, prev_r)

    return pool


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
) -> tuple[float, float | None, tuple[int, float] | None]:
    """Forecast zero headroom hours over 24h horizon in 5-min steps.

    Returns (zero_h, vertex_usd, next_refill).
    """
    sorted_refills = sorted(refills, key=lambda r: r[0])
    next_refill = sorted_refills[0] if sorted_refills else None

    h = H0
    zero_h = 0.0
    t = T
    i = 0
    step_h = STEP_MS / 3600_000.0

    while t < T + HORIZON_MS:
        t += STEP_MS
        h = max(0.0, h - B * step_h)
        while i < len(sorted_refills) and sorted_refills[i][0] <= t:
            h += sorted_refills[i][1]
            i += 1
        if h < DRY_H:
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

    k_str = str(round(k)) if k is not None else "None"
    refill_str = f"Next refill: {format_dt_et(next_refill[0])} (+{next_refill[1]:.2f}). " if next_refill else ""

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
            f"Claude Max pool is dry (headroom={H0:.3f}, 15m spillover=${spill_15m:.2f}). "
            f"Burn rate: {B:.3f}/h. k(local): {k_str}. "
            f"Projected dry: {zero_h:.1f}h"
            + (f" (Vertex ≈ ${round(vertex_usd)})" if vertex_usd is not None else "")
            + f". {refill_str}"
            + "Note: Max $ are notional, Vertex $ are cash."
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
            f"Claude Max pool shortfall projected: {zero_h:.1f}h dry over next 24h"
            + (f" (Vertex ≈ ${round(vertex_usd)})" if vertex_usd is not None else "")
            + f". Headroom: {H0:.3f}. Burn rate: {B:.3f}/h. k(local): {k_str}. "
            + f"{refill_str}"
            + "Note: Max $ are notional, Vertex $ are cash."
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
                reset_text = f"Reset time: {format_dt_et(r7d_eff)}. " if r7d_eff else ""
                text = (
                    f"Claude Max account '{account}' high usage: u7d={u_eff:.3f} (>= {ACCT_HI:.2f}). "
                    f"Headroom: {H0:.3f}. Burn rate: {B:.3f}/h. "
                    + reset_text
                    + "Note: Max $ are notional, Vertex $ are cash."
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
    """Sum bucket values over window (T - W, T]."""
    start_b = ((T - W) // STEP_MS) * STEP_MS
    end_b = (T // STEP_MS) * STEP_MS
    return sum(buckets.get(b, 0.0) for b in range(start_b, end_b + STEP_MS, STEP_MS))


def load_inputs(
    conn: sqlite3.Connection,
    since_ms: int,
) -> tuple[list[tuple[int, str, float | None, int | None]], dict[int, float], dict[int, float]]:
    """Load samples and 5-minute buckets of spillover $ and Max $ since since_ms."""
    cur = conn.execute(
        "SELECT ts, account, u7d, r7d FROM quota_samples WHERE ts >= ? ORDER BY ts ASC, account ASC",
        (since_ms,),
    )
    samples = cur.fetchall()

    spill_cur = conn.execute(
        "SELECT (q.ts / 300000) * 300000 AS b, SUM(q.cost_usd) "
        "FROM requests q JOIN route r USING(request_id) "
        "WHERE q.ts >= ? AND r.desired = 'max' AND q.backend = 'vertex' "
        "GROUP BY b",
        (since_ms,),
    )
    spill_buckets = {
        row[0]: float(row[1]) for row in spill_cur if row[0] is not None and row[1] is not None
    }

    max_cur = conn.execute(
        "SELECT (ts / 300000) * 300000 AS b, SUM(cost_usd) "
        "FROM requests "
        "WHERE ts >= ? AND backend = 'max' "
        "GROUP BY b",
        (since_ms,),
    )
    max_buckets = {
        row[0]: float(row[1]) for row in max_cur if row[0] is not None and row[1] is not None
    }

    return samples, spill_buckets, max_buckets


def run_live(
    db: str,
    state_dir: str,
    alert_cmd: str | None = None,
    now: float | None = None,
    excluded: set[str] | None = None,
) -> int:
    """Run live quota watch check."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = conn.execute("SELECT max(ts) FROM quota_samples").fetchone()
        if not row or row[0] is None:
            print("quota-watch: no quota samples found; skipping")
            return 0
        T: int = row[0]

        if now is None:
            now_ms = int(time.time() * 1000)
        elif now < 1e11:
            now_ms = int(now * 1000)
        else:
            now_ms = int(now)

        if now_ms - T > STALE_INPUT_MS:
            stale_min = (now_ms - T) / 60000.0
            print(f"quota-watch: stale input (last sample T was {stale_min:.1f} min ago); skipping")
            return 0

        since_ms = T - 8 * 24 * 3600 * 1000
        samples, spill_buckets, max_buckets = load_inputs(conn, since_ms)
    finally:
        conn.close()

    acc = Accumulator()
    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] = collections.defaultdict(list)
    for ts, a, u, r in samples:
        samples_by_tick[ts].append((a, u, r))

    for ts in sorted(samples_by_tick):
        for a, u, r in samples_by_tick[ts]:
            acc.feed(ts, a, u, r)

    pool = pool_at(samples_by_tick, T, excluded)
    H0 = sum(max(0.0, CAP - u) for u, _ in pool.values())
    burn_7d = acc.burn(T, 7 * 24 * 3600 * 1000)
    max_7d = sum_buckets(max_buckets, T, 7 * 24 * 3600 * 1000)
    k = estimate_k(burn_7d, max_7d)

    burn_6h = acc.burn(T, 6 * 3600 * 1000)
    burn_24h = acc.burn(T, 24 * 3600 * 1000)
    spill_6h = sum_buckets(spill_buckets, T, 6 * 3600 * 1000)
    spill_24h = sum_buckets(spill_buckets, T, 24 * 3600 * 1000)
    B = burn_rate(burn_6h, burn_24h, spill_6h, spill_24h, k)

    refills = [
        (max(r, T + STEP_MS), min(u, CAP))
        for _, (u, r) in pool.items()
        if r is not None and r <= T + HORIZON_MS
    ]
    zero_h, vertex_usd, next_refill = forecast(H0, B, refills, k, T)

    spill_15m = sum_buckets(spill_buckets, T, 15 * 60 * 1000)
    spill_30m = sum_buckets(spill_buckets, T, 30 * 60 * 1000)

    state_path = os.path.join(state_dir, "state.json")
    state: dict[str, Any] = {}
    if os.path.exists(state_path):
        try:
            with open(state_path, "r", encoding="utf-8") as f:
                state = json.load(f)
        except Exception:
            state = {}

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
                subprocess.run(argv, check=True)
            else:
                print(f"would-alert: {action['signature']} ttl={action['ttl']} max={action['max']} text={action['text']}")

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
) -> list[ReplayEvent]:
    """Replay quota watch evaluation tick-by-tick."""
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        warmup_since = since_ms - 8 * 24 * 3600 * 1000
        samples, spill_buckets, max_buckets = load_inputs(conn, warmup_since)
    finally:
        conn.close()

    samples_by_tick: dict[int, list[tuple[str, float | None, int | None]]] = collections.defaultdict(list)
    seen: collections.Counter[str] = collections.Counter()
    all_null: collections.Counter[str] = collections.Counter()
    for ts, a, u, r in samples:
        samples_by_tick[ts].append((a, u, r))
        seen[a] += 1
        if u is None:
            all_null[a] += 1

    auto_excluded = {a for a in seen if seen[a] == all_null[a]}
    full_excluded = auto_excluded | (excluded or set())

    acc = Accumulator()
    cur_pool: dict[str, tuple[float, int | None, int]] = {}  # account -> (u_eff, r7d_eff, last_nonnull_ts)
    alert_state: dict[str, Any] = {}
    events: list[ReplayEvent] = []

    for T in sorted(samples_by_tick):
        rows = samples_by_tick[T]
        present = set()
        for a, u, r in rows:
            present.add(a)
            acc.feed(T, a, u, r)
            if u is not None:
                r_eff = r if r is not None else (cur_pool.get(a, (0.0, None, 0))[1])
                cur_pool[a] = (u, r_eff, T)
            elif a in cur_pool and T - cur_pool[a][2] <= CARRY_MS:
                pass
            else:
                cur_pool.pop(a, None)

        for a in list(cur_pool):
            if a not in present:
                cur_pool.pop(a)

        if T < since_ms:
            continue
        if T > until_ms:
            break

        pool = {a: (v[0], v[1]) for a, v in cur_pool.items() if a not in full_excluded}
        H0 = sum(max(0.0, CAP - u) for u, _ in pool.values())
        burn_7d = acc.burn(T, 7 * 24 * 3600 * 1000)
        max_7d = sum_buckets(max_buckets, T, 7 * 24 * 3600 * 1000)
        k = estimate_k(burn_7d, max_7d)

        burn_6h = acc.burn(T, 6 * 3600 * 1000)
        burn_24h = acc.burn(T, 24 * 3600 * 1000)
        spill_6h = sum_buckets(spill_buckets, T, 6 * 3600 * 1000)
        spill_24h = sum_buckets(spill_buckets, T, 24 * 3600 * 1000)
        B = burn_rate(burn_6h, burn_24h, spill_6h, spill_24h, k)

        refills = [
            (max(r, T + STEP_MS), min(u, CAP))
            for _, (u, r) in pool.items()
            if r is not None and r <= T + HORIZON_MS
        ]
        zero_h, vertex_usd, next_refill = forecast(H0, B, refills, k, T)

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
                events.append(ReplayEvent(ts=T, kind="account-high", action="fire", metrics={"account": a, "u7d": pool.get(a, (0.0, None))[0]}))
            elif was_latched and not latched:
                events.append(ReplayEvent(ts=T, kind="account-high", action="clear", metrics={"account": a, "u7d": pool.get(a, (0.0, None))[0]}))

        alert_state = new_alert_state

    return events
