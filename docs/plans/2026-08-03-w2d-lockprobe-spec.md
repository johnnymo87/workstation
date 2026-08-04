# W2d — production write-lock instrumentation for `opencode.db`

Bead: `workstation-yvxh.12`. Feeds the W2 (`workstation-yvxh.3`) Go/No-Go on
2026-08-09. Spine: `workstation-yvxh`.

## 1. What this measures, and what it does NOT

The bead is titled "hold-duration distribution". That title survives, but the
instrument measures **two distinct quantities**, and conflating them is the
single most likely way to produce a confidently wrong number. Stated plainly:

| # | Quantity | Symbol | Instrument | Notes |
|---|----------|--------|-----------|-------|
| 1 | **Write-lock hold duration** | `H` | `/proc/locks`, exclusive POSIX `WRITE` on byte 120 of `opencode.db-shm` | Direct. Holder PID is visible. |
| 2 | **Observed main-thread freeze** | `F` | `/proc/<pid>/wchan` of each serve's main thread | `hrtimer_nanosleep` = inside SQLite busy-wait. |

**`F` is not `H`.** A contender arrives at an arbitrary point *inside* a hold,
so `F` is the **residual** hold remaining at arrival, under length-biased
sampling. A 60s hold entered at t=58s yields F=2s. Any reasoning that reads a
short `F` as evidence of a short `H` is wrong.

That is not a defect, because **residual is the quantity the W2 decision
actually turns on**. W2 asks: *if we cut `busy_timeout` from 5000ms to ~100ms,
how many writes that succeed today would instead be lost?* That is exactly
`P(residual < 5s)` — measured directly by `F`, with no inversion needed.

So: **report `F` as residual, report `H` as hold, never substitute one for the
other.** W2c's model `freeze ≈ min(A*T, H)` names `H`; this document
deliberately does not reuse that symbol for `F`.

`P(residual < 5s)` is the decision quantity, but it is **not** simply
`P(F < 5s)` — raw freeze runs are truncated at `T` and split across retries, so
the naive read is biased. The estimator is pre-registered in §5 before any data
exists, precisely so the tempting-but-wrong version cannot be reached for on
2026-08-09.

### Why not infer `H` from `F` by censoring

Tempting and unnecessary. Three ways it breaks:

- **Length bias** (above) — `F` samples residuals, not holds.
- **Run merging** — two distinct short waits back-to-back appear as one run.
- **Run splitting** — a hold longer than `busy_timeout` produces a *failed*
  attempt, the loop briefly resumes, and the app retries. One 15s hold can
  appear as ~three 5s runs, not one 15s run. This breaks any attempt to count
  `A` from wchan alone.

`H` is measured directly from `/proc/locks` instead, which sidesteps all three.

## 2. Empirical basis (measured 2026-08-03, before writing this)

A 30s throwaway probe at 191Hz against the live pool:

```
byte 120 (WAL write):  32 episodes/30s = 64/min   p50 5.2ms  max 10.5ms  duty 0.61%
byte 121 (checkpoint):  1 episode                                        duty 0.03%
byte 123 (read-mark):   1 episode
```

Two consequences that drive the whole design:

1. **Ordinary holds are sub-sample.** Every duration came back as a multiple of
   the 5.2ms sample period, i.e. every hold was caught in 1–2 samples. The true
   central tendency is *below* the resolution floor. The p50 is an artifact and
   must not be quoted as a measurement.
2. **Per-episode logging is not viable.** 64/min is ~92k episodes/day. Logging
   one line each would recreate, in miniature, the 13GB-file problem this whole
   spine exists to fix.

The decision-relevant signal is therefore **the tail** — the rare long hold
(checkpoint stall, VACUUM, a wedged peer) — plus **aggregate counts** for the
short bulk, which give the arrival rate needed to reason about contention.

## 3. Design

One sampler, one loop, two instruments, three record types.

### Sampling
- Target ~100Hz. Per sample: one read of `/proc/locks`, plus one read of
  `/proc/<pid>/wchan` per discovered serve.
- **Durations are computed from wall-clock timestamps, never from sample
  counts.** Under load the loop jitters; sample-counting would silently
  understate.
- Every emitted duration carries the `res_ms` (sample period) that bounds its
  error, so no consumer can over-read the precision.

### Discovery
- Serves are found via `systemctl show 'opencode-serve@*.service'` — a
  **glob**, so no serve port is ever named. This keeps the sampler outside the
  front-door opacity guard's `SITE_RE` by construction rather than by
  exemption.
- Re-discovery every 30s. The nightly 03:00 reset restarts the pool and every
  PID changes; a sampler pinned to boot-time PIDs would report a confident
  empty distribution forever. PID-set changes are logged.

### Record types
1. `hold` — a byte-120..127 exclusive lock episode: `{pid, byte, start,
   dur_ms}`. Emitted **only** when `dur_ms >= hold_detail_ms` (default 100).
2. `freeze` — a contiguous `hrtimer_nanosleep` run on a serve main thread:
   `{pid, port, start, dur_ms, overlapped_hold_pid}`. Emitted for every run
   above `freeze_detail_ms` (default 100); these are rare enough to keep.
3. `rollup` — every 300s: sample count, achieved Hz, per-byte episode counts,
   duration histograms, freeze histograms, current PID set.

### `rollup` is the heartbeat — the anti-silent-failure device
A sampler reading a dead PID logs "no contention" forever and looks perfectly
healthy. The `rollup` record makes the two cases distinguishable:

- rollups present + zero episodes → genuinely quiet. A real null result.
- rollups absent, or `serves_found: 0` → **the instrument is broken.**

Any analysis MUST check rollup continuity before quoting a distribution.

### Coincidence flag (validates the wchan reading)
`hrtimer_nanosleep` is *characteristic* of SQLite's busy-wait in a Bun process
but is not proof — `Bun.sleepSync` or a native addon could also sleep. When a
freeze run on serve X overlaps an observed byte-120 hold by a **different**
PID, that is near-conclusive: X is blocked on that holder. Freeze runs carry
`overlapped_hold_pid` so validated and unvalidated runs can be separated at
analysis time rather than assumed equivalent.

### Output bounding
JSONL to `/var/lib/opencode-lockprobe/episodes.jsonl`, with a hard byte cap
(default 64MB). On reaching the cap the sampler logs loudly and stops writing
detail records but **keeps emitting rollups**, so a capped run degrades to
"counts only" rather than dying silently.

## 4. Non-goals
- **No perturbation of production.** Read-only procfs. No lock is ever taken on
  the real ~13GB DB, and the serve pool is not restarted to install this.
- **Not a fix, and not a gate.** W2 already carries a conservative default
  (retry span >= 5s) that is safe without this data. This buys tuning
  precision, nothing more.
- **No `A` reconstruction** from wchan (see run-splitting above).

## 5. The estimator, pre-registered

Written **before** the data exists. Choosing an estimator after seeing results
is how a wrong number gets rationalised into a decision.

### 5.1 The trap: do NOT compute `P(F < 5s)` from `freeze_hist`

The rollup histogram is for *monitoring*, not for the decision. Two effects
make a naive `P(F < 5s)` read from it wrong **in the dangerous direction**:

- Each attempt is truncated at `T=5000ms`, so a *failing* 12s wait appears as
  several sub-5s runs.
- Runs split across retries (§6 observed 2769ms + 7082ms for one 10s wait).

A 2769ms fragment of a **failed** wait is indistinguishable, in the histogram,
from a genuine 2769ms residual where the write then **succeeded**. Counting
fragments as successes **overstates** today's success rate, which biases toward
approving the aggressive `busy_timeout` cut — the exact error this instrument
exists to prevent.

### 5.2 The estimator to actually use

From **`freeze` detail records only** (they carry `start`, `dur_ms`, pid, and
`overlapped_hold_pid`; the rollup histogram does not):

1. **Stitch** consecutive freeze runs on the same pid separated by a gap
   `<= 500ms` into a single *wait episode*. (Observed inter-attempt gap was
   ~111ms; 500ms is a deliberately generous margin.)
2. **Classify** each episode by its **final** run:
   - final run ends well below `T` (say `< 0.9*T = 4500ms`) → the lock was
     **acquired**; the episode **succeeded**. Episode residual = total stitched
     duration.
   - final run ends at `~T` (`>= 4500ms`) → the attempt **timed out**; the
     episode is **right-censored** at its total duration.
3. **Report** `P(residual < 5s) = successes / episodes`, with a
   Clopper–Pearson interval, and state N explicitly.
4. **Segment** by `overlapped_hold_pid`: episodes with a confirmed overlapping
   holder are validated busy-waits. Report validated and unvalidated
   separately; do not pool them without saying so.

### 5.3 What the hold side reports independently
`H` distribution above the resolution floor, the arrival rate (~64/min
baseline), and the long tail by lock byte (120 write vs 121 checkpoint). This
is the richer dataset — every hold is observed, contended or not — and it does
not depend on contention actually occurring during the window.

### 5.4 Null result
No freezes over D days **with rollup continuity intact**: by the rule of three
the episode rate is `< 3/D` per day at 95% confidence. With D=5, `<0.6/day` —
decision-useful, and it says the conservative retry span costs nothing.

**A null result is only reportable if the continuity checks in §5.5 all pass.**

### 5.5 Mandatory pre-analysis checks
Before quoting any number, verify:
- `rollup` records are continuous across the window (no unexplained gaps).
- `serves_found` is 4 throughout, apart from explained restarts.
- `shm_ino` is stable, or every change is paired with a `shm_changed` record.
- No `serves_lost` or `shm_unstattable` records, or they are accounted for.
- `max_gap_ms` stays near the nominal period; a large gap means durations in
  that window are bounded by the gap, not by `res_ms`.
- `capped` is false, or detail-record loss is accounted for.

Any of these failing means the window is **suspect**, not quiet.

## 6. End-to-end validation (run 2026-08-03, before deployment)

Fixtures prove the state machine; they cannot prove the instrument reads real
SQLite semantics. So it was checked against ground truth on a **throwaway**
serve (`:4711`, cwd `/tmp/w2a`, `OPENCODE_DB=/tmp/w2a/scratch.db`), with a
positive control asserting the lock really was held. The production pool and
the real DB were never touched.

Known 12s hold from an external `sqlite3 BEGIN IMMEDIATE`, two concurrent
writes against the warmed serve:

```
hold   pid=1051731 byte=120   dur=12000.3ms      (known hold: 12s)
freeze pid=1046015 port=4711  dur=2769.2ms  overlapped_hold_pid=1051731
freeze pid=1046015 port=4711  dur=7081.6ms  overlapped_hold_pid=1051731
writes: http=500 t=5.014s      http=500 t=10.026s
```

Four things this establishes:

1. **Hold duration is accurate**: 12000.3ms against a known 12s hold, and the
   holder PID matches the real `sqlite3` process.
2. **Freeze detection works on a real Bun serve**, and the coincidence flag
   correctly attributed both runs to the actual holder.
3. **The writes reproduce W2c's staircase** (5.014s, 10.026s) — each burning a
   full `T=5000` — on an independent implementation. W2c replicates.
4. **Run-splitting is real and was directly observed.** The freeze arrived as
   two runs (2769ms + 7082ms) separated by a ~111ms gap, not one 10s run: the
   loop briefly resumes between attempts. Summed, 9.85s vs the writes' 10.03s
   of waiting. This is the empirical reason this design does **not** try to
   reconstruct `A` from wchan.

A separate check against a real WAL DB caught a hold of 2496ms where the true
hold was 3000ms — the sampler having started 500ms late. That is
**left-censoring**, quantified below.

## 7. Known limits (stated, not hidden)

- **Left-censoring**: a hold already in progress when the sampler starts is
  measured from the sampler's first sample, so it is under-reported (observed:
  2496ms for a true 3000ms hold started 500ms earlier). Affects only the first
  episode after a start/restart; negligible against ~92k episodes/day, but a
  restart-heavy window should not be read closely.
- Holds shorter than the sample period are undercounted; detection probability
  is roughly `min(1, dur/period)`. Short-residual mass is therefore a **lower**
  bound and must be reported as such. The direction is *conservative*: it
  removes mass from the short bins, so it under-states how often the current 5s
  attempt succeeds, and thus argues against the aggressive cut rather than for
  it. (The bias that argues *for* the cut is the estimator trap in §5.1, which
  is why §5.2 is pre-registered.)
- The `0-5` and `5-10` histogram buckets are at or below the resolution floor
  at 100Hz. Their emptiness is an artifact, not a finding.
- Episodes still open when the probe is stopped are never counted — one lost
  long hold per restart, biased against the tail.
- `/var/lib/opencode-lockprobe/episodes.jsonl` must **not** be rotated or
  deleted while the probe runs: writes would continue to the unlinked inode and
  the data would vanish silently at close. Nothing rotates it today.
- Waiters are invisible in `/proc/locks`: SQLite polls with non-blocking
  `F_SETLK` rather than blocking, so there are no `->` blocked entries. The
  wait side is covered by wchan instead. (This is itself corroboration that the
  busy-wait is a sleep loop.)
- Sub-period holds cannot be resolved at all. Exact hold timestamps would need
  `bpftrace` on `fcntl` — root-only, and rejected here as disproportionate.
