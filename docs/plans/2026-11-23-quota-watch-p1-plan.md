# quota-watch (phase 1 of the LLM spend program): plan

Bead: `workstation-4si2.2`. Design: `docs/plans/2026-11-23-llm-spend-metrics-design.md`
("Facts" 5–9, "Alerts", Phase 1). Phase 0 (`llm-ledger`) is deployed, and its
ledger is this phase's only input.

## Goal

Warn **before** the Claude Max pool runs dry, and say so **while** it is dry,
using only `/var/lib/llm-ledger/ledger.db` (read-only). Alerts go through
`opencode-drift-alert` to pigeon.

## What the archive says (measured 2026-11-23, and what each fact forces)

| Fact | Consequence |
|---|---|
| Every small `u7d` dip is exactly 0.01 (1,026 of them); the smallest real reset is 0.10. | Burn is a **high-water mark**: count only rises above the mark; a drop > 0.05 is a reset. |
| `u7d` is null at some reset ticks. | Carry the last value for up to 15 min (headroom); skip it for burn. |
| 2026-11-13 18:00: `r7d` had passed but the sample still read the old 0.85 (reset showed at 18:05). | Crossing `r7d` without a drop is a **stale tick**: hold (count nothing, keep the old `r7d`) for up to 15 min after `r7d`. A crossing **with** any drop (`u < hw`) is a reset. |
| Pool-wide off-schedule resets on 2026-09-01 14:00 and 09-04 16:10. | Resets are detected from drops, never from the schedule alone. |
| Membership gaps (one account absent 2026-08-21 → 10-16), DST hole 2026-11-01 (65 min). | A gap > 1 h resyncs the mark without counting burn. An account absent from the latest tick is out of the pool. |
| One roster member never reports `u7d` (spend-capped seat). | Accounts with no non-null `u7d` in the loaded window are excluded automatically; `--exclude-account` can add more. No account names in code. |
| The pool ran dry 2026-11-22 12:10–18:05 EST while Σ(1−u7d) read 0.09–0.12; teamclaude refuses at about 0.98. | Headroom = Σ max(0, 0.98 − u7d). |
| Spillover is visible in the ledger as `route.desired='max' AND requests.backend='vertex'` ($340 in 30 days, $333 of it on 11-22). `desired='vertex'` is the deliberate ~$100/day Vertex budget, not spillover. | Spillover uses exactly that predicate. |
| cloudbox Max notional $ per unit of pool burn varies 60–1,700 per day (devbox and the Mac burn the same accounts). | `k` (local) = 7-day Max $ ÷ 7-day burn. It *underestimates* true $/quota, so spillover ÷ k *overestimates* the missing burn: conservative. Reported as `k(local)`. |

Prototype replay (`2026-10-25` → now, the rules below): resets detected 81
(the bead's count); shortfall episodes **3** (11-18 14:20, 11-19 15:25, and
11-21 22:20 — 14 h before the 11-22 dry spell, active through it); pool-dry
**1** episode (11-22 12:10 → 18:05). The two earlier shortfall episodes were
near misses ($5 and $8 of spillover those days), not pure noise.

## Algorithm

All times are integer epoch ms. Constants live at module top:

```
CAP = 0.98            RESET_DROP = 0.05      CARRY_MS = 15 min
RESYNC_GAP_MS = 1 h   STALE_HOLD_MS = 15 min DRY_H = 0.02    DRY_CLEAR_H = 0.05
SHORT_FIRE_H = 2.0    SHORT_CLEAR_H = 0.5    ACCT_HI = 0.90  ACCT_REARM = 0.85
HORIZON_MS = 24 h     STEP_MS = 5 min        K_MIN_BURN = 0.5  STALE_INPUT_MS = 20 min
```

**Accumulator** (per account, fed samples in ts order; null `u7d` skipped):

- First sample: `hw = u`, `last_ts`, `r = r7d`; no burn.
- `gap = ts − last_ts > RESYNC_GAP_MS` → `hw = u` (no burn).
- else `crossed = r is not None and ts >= r`:
  - `hw − u > RESET_DROP` or (`crossed` and `u < hw`) → **reset**: burn += `u`; `hw = u`.
  - `crossed` and `ts − r <= STALE_HOLD_MS` → **hold**: update `last_ts` only; do not update `r`.
  - `u > hw` → burn += `u − hw`; `hw = u`.
  - otherwise (jitter) → nothing.
- Then `last_ts = ts`; `r = r7d` if r7d not null.

Burn events are `(ts, amount)`; `burn(W)` = sum over `(T−W, T]`.

**Pool at tick T** (T = latest sample ts): accounts present in tick T, minus
excluded. `u_eff` = this tick's `u7d`, or the last non-null within `CARRY_MS`;
an account with neither is dropped from the pool (unknown ≠ free).
`r7d_eff` = latest non-null r7d for the account. `H0 = Σ max(0, CAP − u_eff)`.

**k** = Max $ over (T−7d, T] ÷ burn(7d); `None` if burn(7d) < `K_MIN_BURN`.

**Burn rate** (units/h): `rate(h) = (burn(h) + (spill$(h) / k if k else 0)) / h`;
`B = max(rate(6), rate(24))`.

**Forecast**: refills = `(max(r7d_eff, T+STEP), min(u_eff, CAP))` for pool
accounts with `r7d_eff <= T + HORIZON`. Step `t` from T to T+HORIZON by
`STEP_MS`: `h = max(0, h − B·STEP/1h)`; add refills with time ≤ t; if
`h < DRY_H`, `zero_h += STEP/1h`. Output `zero_h`, `vertex_usd = zero_h·B·k`
(None without k), and the next refill (time, amount).

**Alerts** (state persisted between runs as JSON):

- **pool-dry**: fires when `H0 < DRY_H` and spill$ over the last 15 min > 0;
  clears when `H0 >= DRY_CLEAR_H` or spill$ over the last 30 min is 0.
- **shortfall**: fires when `zero_h >= SHORT_FIRE_H`; clears when
  `zero_h < SHORT_CLEAR_H`. Not *sent* while pool-dry is active (the dry text
  carries the forecast), but its state keeps evolving.
- **account high**: per account, latch when `u_eff >= ACCT_HI` (send once at
  the latch), re-arm when `u_eff < ACCT_REARM`.

Sending: on every run while pool-dry / shortfall is active, call
`drift-alert <state-dir>/<name>.alert <signature> <text> <ttl> <max>` (it owns
backoff and escalation): pool-dry `quota-pool-dry` 900/14400; shortfall
`quota-shortfall` 3600/14400. Account-high is sent once per latch with
signature `quota-acct:<account>` and ttl 0. On clear, delete the `.alert` file
so the next episode pages fresh. Texts state: headroom, burn rate, k(local),
projected hours dry and Vertex $, next refill (time ET, amount), and for
account-high the account, u7d, and its reset time.

**Stale input**: if `now − T > STALE_INPUT_MS`, print a skip line and exit 0
(stale-input *alerting* is phase 4, `workstation-4si2.5`).

## Interfaces

New file `pkgs/llm-ledger/quota_watch.py` (pure functions + a thin DB layer):

- `Accumulator` / `compute_burn_events(samples)`
- `pool_at(samples_by_tick, T, excluded)` → `{account: (u_eff, r7d_eff)}`
- `estimate_k(...)`, `burn_rate(...)`, `forecast(H0, B, refills, k, T)`
- `step_alerts(state, metrics)` → `(new_state, actions)` (pure; actions are
  send/clear instructions)
- `load_inputs(conn, since_ms)` → samples + 5-min spill and max-$ buckets
  (`route.desired='max' AND backend='vertex'`; `backend='max'`)
- `run_live(db, state_dir, alert_cmd, now, excluded)` and
  `replay(db, since, until, excluded)` → list of events

`llm_ledger.py` gains subcommands `quota-watch` (`--db`, `--state-dir`,
`--alert-cmd`, `--exclude-account` repeatable) and `quota-replay` (`--db`,
`--since`, `--until`, ISO dates, ET). Without `--alert-cmd`, quota-watch prints
what it would send. The ledger is opened `mode=ro` URI.

## Tests (`pkgs/llm-ledger/test_quota_watch.py`)

Synthetic, each modelled on an archive case: jitter a→a−0.01→a counts zero;
scheduled reset counts post-reset value; null at reset carried for headroom
≤ 15 min then dropped; stale tick after `r7d` (11-13 shape) counts nothing,
then the real drop counts once; off-schedule pool-wide reset; > 1 h gap
resyncs; spend-capped (all-null) account excluded; refills stepped in order;
hysteresis for both latching alerts; account-high latch/re-arm; stale-input
skip; drift-alert invoked with the right argv (stub script) and `.alert` files
removed on clear.

Real-data fixture `testdata/dry-spell-2026-11-22.json.gz` (anonymised
accounts, 2026-11-20 19:00 → 11-22 19:00 ET): replay must fire shortfall
before 11-22 12:00, fire pool-dry between 12:00 and 12:30, and clear pool-dry
between 18:00 and 18:30.

Acceptance on the live ledger (manual, recorded in the PR): `quota-replay
--since 2026-10-25` reproduces the prototype's episodes above.

## Deployment

`hosts/cloudbox/llm-ledger.nix`: a second `ExecStart` (oneshot runs them in
order, after the writer) `llm-ledger quota-watch --state-dir
/var/lib/llm-quota-watch --alert-cmd ${driftAlert}`; `StateDirectory =
"llm-quota-watch"`. The failure alert's text names both steps. The flake
check runs both suites with pinned counts.
