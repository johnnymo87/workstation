# Cloudbox Serve Reliability Roadmap

**Spine bead:** `workstation-7za8` · **Started:** 2026-08-01 · **Host:** cloudbox only
**Status:** steps 0, 1, 3 done · next: step 2 (`workstation-h1y6`), with its risk model revised by step 3

`opencode-serve@4098` had **one** confirmed throttle-band wedge on 2026-08-01
(19:04–19:10), plus two earlier stall windows that self-recovered and are
probably a *different* failure. The band mechanism is understood and the fix is
precedented; the fix is also **not obviously sufficient on this host**, because
cloudbox has 31 GiB of unbounded zram swap that may prevent the OOM kill the fix
depends on. This roadmap sequences the work so it does not make things worse on
the way in, and is explicit about how much of the day's damage it actually
claims.

---

## Facts that must survive compaction

### How many wedges were there, actually — ONE, not three

The investigation this roadmap inherited said "three wedge episodes, all
recovered only by the canary". **That is false**, and the correction matters
more than anything else in this document, because it decides how much of the
problem step 2 can honestly claim.

```bash
sudo journalctl -u opencode-serve-canary --since "2026-08-01 10:00" \
     --until "2026-08-01 20:00" -o cat | grep -viE '^(Starting|Finished)'
```

| Window | Canary counter | Restart? | Forensics? |
|---|---|---|---|
| 10:49–10:56 | 1→4/7, **reset**, 1→3/7 | no | none |
| 15:29–15:43 | never above 3/7, **reset ×4** | no | none |
| 19:04–19:10 | clean 1/7 → 7/7 | **yes**, 19:10:23 | the one dump |

`/var/lib/opencode-serve-canary/` contains exactly **one** wedge directory, and
`journalctl -u opencode-serve@4098` shows no stop/start between 09:24:55 and a
manual one at 17:46:04.

**A counter reset means `/global/health` intermittently succeeded.** That is not
the throttle band's signature — the band degrades monotonically, which is
exactly what the 19:04 window shows. The 10:49 window is the same event
`workstation-nv5l` already recorded (10:47–10:57, `NRestarts=0`, self-recovered,
979 session-path 503s through the door). It is a **different, unfixed failure
class** and this roadmap does not claim it.

So: **step 2 fixes one confirmed incident of a mechanism, not "the wedges".**
Two of the day's three bad windows remain unexplained. Do not let a quiet week
after step 2 be read as a fix for `nv5l`.



Every number below was measured on cloudbox on 2026-08-01 between 19:42 and
19:50 EDT, in this worktree, read-only. Re-measure before acting; do not trust
this summary over a fresh check. The re-measure command is given for each.

### The wedge mechanism — CONFIRMED

Forensics dir: `/var/lib/opencode-serve-canary/wedge-20260801T191003-4098/`
(root-owned; read it with `/run/wrappers/bin/sudo` — the `sudo` on `PATH` in an
opencode bash session is the non-setuid system-path copy and always fails).

| File | Value | Meaning |
|---|---|---|
| `memory.current` | `7892549632` (7.35 GiB) | above `MemoryHigh` |
| `memory.max` | `9663676416` (9 GiB) | never reached → **no OOM, no restart** |
| `memory.peak` | `7893729280` | it plateaued at the throttle band, it did not climb |
| `memory.pressure` | `full avg10=67.38` | **two-thirds of wall time fully stalled in reclaim** |
| `cpu.pressure` | `full avg10=0.00` | not CPU contention |
| `cpu-io-split` | `utime 66343→66353` over 2 s | ~5 % of one core → **not a JS spin** |
| `threads` | 13 of 65 in `mem_cgroup_handle_over_high` | 12 × `notify-rs debounce` + 1 × `.opencode-wrapp` |

**Correction to the inherited report.** The prior session wrote "main thread +
notify-rs debounce workers parked in `mem_cgroup_handle_over_high`". The main
thread (PID 3110807, = the unit's `MainPID`) was in `futex_wait_queue`, not
`over_high`; the `.opencode-wrapp` thread that *was* in `over_high` is a
different TID (3110865). The mechanism is unchanged — 13 threads stalled in
direct reclaim, PSI full 67 %, CPU flat — but the specific claim was wrong and
must not be re-propagated. The `eu-stack.*` dumps contain **zero** `over_high`
frames, which is expected (they are userspace stacks; `over_high` is kernel) and
is not evidence against the diagnosis.

**Why it does not self-recover.** Between `MemoryHigh` and `MemoryMax` the
kernel throttles the allocating thread instead of killing the cgroup.
`MemoryMax` never fires, so `OOMPolicy=stop` never fires, so `Restart=always`
never fires. The serve gets monotonically slower and stays alive. Only the
canary (`opencode-serve-canary.timer`, minutely, 7 consecutive `/global/health`
failures) recovers it — 6 minutes to detect, then a 90 s `TimeoutStopSec` before
`SIGKILL`, because a frozen loop never runs the JS `SIGTERM` handler.

### The zram problem — why the precedented fix may not work here

**This is the hole in the whole plan and it must be closed before step 2 runs.**

```bash
swapon --show
cat '/sys/fs/cgroup/system.slice/system-opencode\x2dserve.slice/opencode-serve@4096.service/memory.swap.max'
sudo grep -E '^(anon|file|active_file|swapcached) ' <wedge-dir>/memory.stat
```

| Measurement | Value |
|---|---|
| swap device | `/dev/zram0`, **31.3 G**, 2.9 G used |
| serve cgroup `memory.swap.max` | **`max`** — unbounded |
| wedge `memory.stat` `anon` | 7 761 285 120 (**everything**) |
| wedge `memory.stat` `file` / `active_file` | 12 288 / **0** — nothing page-cache-reclaimable |
| wedge `memory.stat` `swapcached` | 167 936 — it *was already swapping* |

The kernel OOM-kills at `memory.max` only when reclaim makes **no progress**.
This workload is ~100 % anonymous memory with ~28 G of free zram beneath it, so
reclaim can always make progress by swapping. The likely outcome of dropping
`MemoryHigh` alone is therefore **not** a kill — it is the same stall relocated
from 7 G to 9 G, now thrashing zram.

And a naive scratch-unit test would *pass* while production still stalls: a
stress allocator writing fast, incompressible pages outruns zram and OOMs
promptly. The test must be swap-faithful or it is theatre.

The devbox precedent has the **same hole**. `users/dev/home.devbox.nix` sets no
`MemorySwapMax`, devbox has zram, and `workstation-94g8` records no
post-fix OOM kill ever demonstrated. "No wedges since July" is absence of
trigger, not proof of the kill path. **Do not import devbox's confidence.**

Devbox removed `MemoryHigh` for exactly this reason on 2026-07-03
(`users/dev/home.devbox.nix:811-824`, bead `workstation-94g8`,
`docs/investigations/2026-07-03-serve-4096-wedge.md`). Cloudbox never got the
change and still runs the split at `hosts/cloudbox/configuration.nix:841-842`.

### Current unit configuration — cloudbox

```bash
systemctl show opencode-serve@4096 -p MemoryHigh,MemoryMax,Restart,RestartUSec,TimeoutStopUSec,OOMPolicy,Slice
```

| Property | cloudbox | devbox | Note |
|---|---|---|---|
| `MemoryMax` | 9 G | 6 G | |
| `MemoryHigh` | **7 G** | *absent* | the bug |
| `Restart` / `RestartUSec` | `always` / 10 s | same | |
| `TimeoutStopUSec` | **1 min 30 s** (default) | **15 s** (explicit) | second, smaller gap |
| `OOMPolicy` | `stop` | (default `stop`) | |
| `Slice` | `system-opencode\x2dserve.slice`, `MemoryHigh=infinity` | user slice | no parent throttle |

`TimeoutStopUSec` matters because a wedged serve's `SIGTERM` handler is a
JS-level `process.once` that a frozen event loop provably never runs
(`workstation-94g8`). Cloudbox therefore waits the full 90 s before `SIGKILL`
on every stop of a wedged serve — including inside the nightly reset.

**Cloudbox serves are SYSTEM units** (`hosts/cloudbox/configuration.nix`),
whereas devbox serves are **user** units (`users/dev/home.devbox.nix`). This
asymmetry is the single most load-bearing fact for step 1 — see below.

### State of the four serves right now

```bash
for p in 4096 4097 4098 4099; do systemctl show opencode-serve@$p \
  -p ActiveState,NRestarts,MemoryCurrent,ActiveEnterTimestamp; done
```

All four `active`, `NRestarts=0`. 4096/4097/4099 started 18:11:48 (the gen-528
home-manager deploy); 4098 started 19:10:26 (the canary restart).
`MemoryCurrent` at 19:42: 1.14 G / 0.67 G / 0.63 G / 0.67 G.

**This is the most under-weighted number in the whole investigation.** Three
serves that have been up since 18:11 sit under 1.2 G, yet 4098 reached 7.35 G.
The working set is *not* uniform per-serve; something session-specific or
watcher-specific drives one member into the band. `MemoryHigh` removal fixes the
*consequence* (silent stall → fast kill + 10 s restart). It does not explain the
7.35 G. See step 3.

### Phantom-busy sweeper — ABSENT from cloudbox

```bash
systemctl list-timers --all --no-legend | grep -i opencode
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user list-timers --all --no-legend
```

System timers: only `opencode-frontdoor-canary` and `opencode-serve-canary`.
User timers: `pull-workstation`, `home-manager-auto-expire`, `disk-cleanup`,
`opencode-llm-audit-logrotate`, `systemd-tmpfiles-clean`. **No sweeper.**
It exists on devbox only, at `users/dev/home.devbox.nix:1312-1358`.

Orphan count measured 19:45 (read-only, via `nix run nixpkgs#sqlite`; there is
no `sqlite3` on `PATH`):

```
phantom (assistant, no completed, no error)      304
phantom_stale30m (also time_updated > 30m old)   303
```

### opencode.db

```bash
nix run nixpkgs#sqlite -- "file:$HOME/.local/share/opencode/opencode.db?mode=ro" \
  "PRAGMA page_count; PRAGMA freelist_count; PRAGMA page_size;"
```

`page_count=3184258`, `freelist_count=1622821`, `page_size=4096` → 12.15 GiB
file, **51.0 % free pages ≈ 6.19 GiB reclaimable**. Live rows: 8886 sessions,
360 041 messages, 1 463 378 parts.

**Disk is not under pressure:** `/` is 393 G, 268 G used, **109 G available
(72 %)**. The 6 GiB is 1.6 % of the volume. This reframes VACUUM from "urgent"
to "hygiene" and is the reason it is sequenced last.

### The nightly window

`systemd.timers.nightly-restart-background`, `OnCalendar=*-*-* 03:00:00`,
`Persistent=true` (`hosts/cloudbox/configuration.nix:2196-2204`). It restarts
`pigeon-daemon` then runs `reset-workspace --yes`, which `pkill -9`s all `nvim`
(the parent of the attach TUIs), bounces the serve pool, and restores **only**
attach TUIs whose pid was a descendant of a `main` tmux pane
(`pkgs/reset-workspace/default.nix:47-48`).

Consequence: **duplicate attach TUIs are already cleared every night**, and only
legitimately-parented ones come back. Consequence 2: **03:00 is the one moment
per day when killing in-flight turns is already the expected behaviour**, so any
step that bounces the pool or stops the DB belongs in that window.

---

## Per-step spine

Every step below runs this sequence. The spine is the point of the document: it
survives even when the step's details are lost.

1. **Compact** — `preparing-for-compaction`. Persist to the step's bead and
   update *this file* before compacting, never after.
2. **Consult `oracle-fable`** *(optional)* — only when the step has a genuinely
   open design decision. Skip for mechanical steps.
3. **SDD** *(if applicable)* — `subagent-driven-development`; dispatch
   `implementer`, then `spec-reviewer`. Skip for single-file changes.
4. **`adversarial-reviewer-fable`** — **mandatory, before writing code.**
5. **PR** *(if applicable)* — throwaway worktree off `origin/main`. The body
   states what was verified *and how*.
6. **Update this roadmap** — tick the step, file beads for what was discovered,
   state what the next step inherits.

> Steps 2 and 4 name the `fable` variants, which are otherwise
> use-only-when-explicitly-asked. The user requested them for this roadmap; that
> standing request applies to these steps only.

---

### None of this is new work

Both fixes were **already filed, a month ago, by someone who had already
identified the traps.**

| Bead | Filed | Says |
|---|---|---|
| `workstation-h1y6` | **2026-07-03** | port devbox's Max-only memory + `TimeoutStopSec=15` + canary to cloudbox; *already notes* the system-unit asymmetry |
| `workstation-s5gl` | **2026-07-05** | port the sweeper; *already notes* "its serve units are SYSTEM-level so the ps-etimes dead-owner probe needs the system unit names, not user units" |

They sat at P2 and were never scheduled. In the intervening four weeks cloudbox
took a confirmed band wedge and two unexplained stall windows. The investigation
that produced this roadmap re-derived, from scratch and at some cost, a trap
that was written down on 2026-07-05.

Two consequences, both binding:

1. **Do not create new beads for steps 1, 2 and 4.** They exist. The fresh
   measurements are folded into their notes; the placeholder duplicates created
   during step 0 (`workstation-lgyk`, `workstation-ue47`, `workstation-d3iv`)
   were closed as duplicates the same hour. Both survivors are promoted to P1.
2. **The real failure here was scheduling, not analysis.** A roadmap that only
   fixes the memory band and leaves the same "correct bead, never picked up"
   process in place will produce the next four-week gap. `workstation-h1y6` also
   listed a third item — the liveness canary — which *did* get built; the two
   that did not are exactly the two that need config changes in files nobody was
   otherwise editing.

`workstation-h1y6`'s original description is also **stale on numbers**: it says
cloudbox runs a `MemoryHigh=32G / MemoryMax=40G` shared envelope. That was true
pre-K=4; the live config is per-instance 7 G/9 G. And its item (3), the canary,
is **already done** — it is what dumped the forensics this roadmap rests on.
Trust the measurements in this file over that description.

---

## Step order, and why

**Sweeper (1) before memory (2), as a preference — not a hard block.**

Removing `MemoryHigh` should raise the *frequency* of hard kills: today a
band excursion sometimes self-recovers with no kill at all, and when it does end
in a kill it is the canary's `SIGKILL` six minutes later. Each killed member
abandons every in-flight assistant turn it held, and each abandoned turn becomes
a phantom-busy row — a session stuck in the busy shimmer that cannot be prompted
again. Cloudbox has no sweeper and already carries ~305 such rows.

The honest strength of that argument is **moderate, not decisive**, for three
reasons, all of which were missed on the first draft:

- The confirmed band episode *already* ended in a `SIGKILL`. Step 2 moves the
  kill earlier; it does not invent a new orphan source.
- `reset-workspace` bounces the whole pool nightly at 03:00 with in-flight turns
  running. Kill-with-orphans is already a daily event.
- **The sweeper's SQL is retroactive.** Whenever it lands it finalizes every
  stale orphan, including any that step 2 created in the meantime. Getting the
  order wrong costs a busy-shimmer window of hours, not permanent damage.

So: prefer 1 → 2, land them in the same or consecutive 03:00 windows, and **do
not let step 1's full spine serialize step 2 by days** on a host that took three
bad windows in one day. There is no blocking edge in the bead graph for this
reason.

**Step 3's sampling starts now, before step 2.** It is read-only and zero-risk,
and step 2 *destroys its evidence*: once a member is OOM-killed at the cap
within seconds, there is no hours-long 7.35 G plateau to autopsy and no canary
forensics dump. Today's regime is the best leak-observation window available.

---

## Step 0 — This roadmap · **DONE 2026-08-01**

Produce the spine, wire the beads, pressure-test the whole thing with
`adversarial-reviewer-fable`, fold the findings back in.

- **Exit:** this file committed and pushed; every step's bead carries the fresh
  evidence and its dependencies are wired; the reviewer's material findings
  either folded in or explicitly recorded as rejected with a reason.

Dependency graph as wired: `7za8` blocks `s5gl`, `h1y6`, `9b3o`; `s5gl` blocks
`bm1i`; `s5gl → h1y6` is **`related`, not `blocks`** — the ordering preference is
real but soft (see below), and `9b3o` is deliberately unblocked so its sampling
can start before `h1y6` lands.

### Review record — `adversarial-reviewer-fable`, 2026-08-01

Ten findings, **all accepted, none rejected**; both blockers were independently
re-measured before being folded in. What changed as a result:

| Finding | Change |
|---|---|
| BLOCKER — "three episodes, all canary-recovered" is false | new episode table; headline, residuals, and three beads' notes rewritten |
| BLOCKER — 31 G unbounded zram probably prevents the OOM kill | step 2 grows `MemorySwapMax` + a swap-faithful control and a negative control |
| MAJOR — sequencing argument overstated | `blocks` → `related`; the three counter-arguments written down |
| MAJOR — step 3 sequenced backwards | unblocked; sampling starts *before* step 2 |
| MAJOR — step 2's week-later criterion is vacuous | replaced with a three-outcome observation incl. "inconclusive"; rollback + daemon-reload added |
| MINOR — W3 rejection is correct | strengthened with the manifest-dedupe evidence; intra-day cost named |
| MINOR — canary retention prune is dead | filed `workstation-lbe2` |
| NIT — step 4 SQLite gaps | `journal_mode` + stale `-wal`/`-shm` checks added |
| NIT — step 1 "dry run" undefined | mechanics specified |

The first draft's most confident paragraph — the sequencing argument — was its
weakest. Note that for next time.

## Step 1 — Port the phantom-busy sweeper to cloudbox · **DONE 2026-08-01**

**Bead:** `workstation-s5gl` (filed **2026-07-05**) · **Precedes** step 2 (soft).

> **Landed as a SYSTEM timer, not the user timer this section originally
> mandated.** The reversal and the results are at the end of the section; the
> analysis below is preserved because the *trap* it describes is still the whole
> point. Read "What actually shipped" before touching this.

The SQL is host-invariant. **The serve-discovery is not**, and that is the trap:

```sh
# devbox, home.devbox.nix:1325 — serves are USER units there
for u in $(systemctl --user list-units 'opencode-serve@*.service' ...); do
```

On cloudbox the serves are **system** units, so that loop finds nothing,
`MAX_ETIMES` stays `0`, and the script's own fallback sets `CUTOFF=$NOW`. The
live-owner guard silently degrades to staleness-only, and a legitimately
long-running turn that has been quiet for 30 minutes gets finalized with a fake
`MessageAbortedError` while it is still executing. A copy-paste port is a
correctness regression, not a no-op.

**Design call, as first written — and WRONG. Kept for the record.** *"User
timer, not system timer. The DB is owned by `dev`; a root-run system unit
touching it creates root-owned `-wal`/`-shm` files the serves cannot write,
turning a hygiene job into an outage. That combination is the only one that is
both correct and safe."*

The `oracle-fable` consult killed it in one line: **`User=dev` is available in
the system-unit path**, so the root-owned-WAL hazard was a strawman — nobody
proposed a root-run unit. The proof is on the host and had been sitting in the
evidence the whole time: the serves *are* system units with `User=dev`, and
`opencode.db-wal` is `dev:dev`. `adversarial-reviewer-fable` then tried to
re-reverse the decision, hunted `umask`, `ProtectSystem`/`ProtectHome`/
`PrivateTmp` defaults, supplementary groups, cgroup/OOM scope and SELinux, and
found no hazard. Two advisors, opposite mandates, same answer.

### What actually shipped

`hosts/cloudbox/configuration.nix`, a **system** service + timer with
`User=dev; Group=dev`, next to the canary that already queries these same units
from this same file. Reasons: same bus as the discovery target, so there is no
`--user` footgun left for a future editor — *that footgun is the exact bug this
step exists to fix*; a pool resize in this file lands in the same diff; and a
user unit would deploy by a different command (`home-manager switch` vs
`nixos-rebuild switch`), opening a skew window.

Five changes beyond a port:

1. **`ActiveEnterTimestamp`, not `MainPID` + `ps etimes`.** `CUTOFF = min(boot
   epoch)` is exactly devbox's `NOW - max(etimes)`, minus a pid race (a pid
   exiting between the two calls silently skips a unit and *loosens* the gate)
   and minus the `procps` dep. Truncation now rounds the cutoff earlier
   (conservative) rather than later. `systemctl show --timestamp=unix` yields
   `@1785622308` directly, so no `date -d "Sat … EDT"` parsing.
2. **Discovery = explicit port list ∪ running glob.** The list comes from
   `users/dev/serve-pool.nix`, so a renamed template is caught instead of
   matching nothing; the glob additionally catches a **stray** instance still
   running after its port was dropped from the pool (nothing stops it until
   03:00), whose rows must keep protecting themselves. Two guards, opposite
   drift directions.
3. **The silent fallback is split in two.** Devbox conflates them. Discovery
   *failure* — `list-units` exits non-zero, an expected unit is not `loaded`, or
   **any** active unit's timestamp will not parse — now **fails closed**
   (`exit 1`, visible in `systemctl --failed`). Only a genuinely *drained* pool
   (every unit queried fine, none active) keeps `CUTOFF=NOW`, which in that case
   is maximally correct. Note `systemctl show` exits **0** for a not-found unit,
   so `LoadState` must be checked explicitly — measured, the exit code proves
   nothing. The `2>/dev/null` redirects devbox has on both `systemctl` calls are
   deleted; they swallow precisely this signal.
4. **`--dry-run`** prints per-unit boot epoch, the active count, the computed
   `CUTOFF`, and a `SELECT count(*)` against a `mode=ro` handle. It exists so the
   acceptance test is executable.
5. **The SQL is byte-identical to devbox's**, including
   `json_extract(data,'$.time.created')` where the `time_created` column would
   do. Verified they never disagree (360 314 / 360 314 rows) — and verified the
   column buys nothing, since the only index is `(session_id, time_created, id)`
   and this query has no session filter, so both variants full-scan. Parity with
   a month-proven script costs literally zero here.

### Results — all exit criteria met

| Criterion | Result |
|---|---|
| Sweeper present, **system** scope | `systemctl list-timers` → next run `20:35`, `OnCalendar=*:0/5` |
| **Discovery found the system units** — the test a copy-paste port fails | dry run: `active=4` (== `servePool.k`), all four listed with boot epochs |
| `CUTOFF` == oldest live serve boot | `cutoff=1785622308` == `18:11:48` == `min(ActiveEnterTimestamp)` |
| Control: a row created *after* the oldest boot is **not** finalized | 303 stale, **6 held back by gate (b)**, 297 swept — the gate does real work, it is not a no-op |
| Backlog finalized | `finalized 297 orphaned message(s)`, `Result=success` |
| Residual consistent with only live turns | `phantom_all` 304 → **17** (11 genuinely in-flight + the 6 protected) |
| `opencode.db-wal` still `dev`-owned | `-rw-r--r-- 1 dev dev … opencode.db-wal` |
| Pool not restarted | all four `active`, `NRestarts=0`, boot epochs unchanged across the switch |

Fail-closed paths were exercised directly rather than assumed, by running
mutated copies of the built script:

- expected unit renamed → `LoadState=not-found … refusing to run`, `exit 1`
- active unit with an unparseable timestamp → `refusing to run`, `exit 1`
- drained pool (no units at all) → `active=0 cutoff=<now>`, `exit 0`, sweeps all
  303 — the one case where `CUTOFF=NOW` is right

Deploy safety was enumerated, not asserted: `nixos-rebuild build` produced
**6 derivations, all sweeper-related**, and a file-level diff of
`/run/current-system/etc/systemd/system` against the new one showed **two new
units and zero changed units**. `switch` then reported exactly `the following
new units were started: opencode-phantom-busy-sweeper.timer`.

### Residuals carried forward

- **The min-over-pool cutoff defers the common case by up to a day.** An
  intraday single-member kill orphans rows *younger* than the other members'
  boots, so they stay invisible until 03:00 bounces the whole pool via
  `opencode-serve-pool.target` (`partOf` fan-out) and resets every boot epoch.
  The backlog and the drained-pool case sweep immediately; a fresh intraday
  orphan can shimmer until ~03:05. **Step 2 makes this the steady state**, since
  it converts silent stalls into faster kills. Fixing it needs per-session owner
  attribution — the routing DB already holds session→serve leases — and is
  deliberately not in this step. Filed as `workstation-63wo`.
- **Non-pool executors are unprotected**, as on devbox: a row created by a
  standalone `opencode` process predates no serve boot, so only the 30-minute
  silence gate guards it. Measured: cloudbox has none today (the ~20 other
  opencode processes are all `attach` clients, which execute nothing locally).
  Accepted, not fixed.
- **The write transaction holds the single writer slot for ~1.3 s every 5
  minutes** (1.8 s measured wall, ~0.5 s of it `nix run` startup), because the
  predicate scan runs inside it. Tolerable — four serves already contend
  continuously — but it is a real number, it grows with the table, and step 4's
  VACUUM shrinks the scan. Recorded so step 4's priority argument has a datum.

### Review record — step 1

`oracle-fable` (design consult) then `adversarial-reviewer-fable` (mandatory,
pre-code). Zero blockers on the second pass; both MAJORs fixed before writing
any Nix:

| Finding | Change |
|---|---|
| oracle: user-scope rationale is a strawman | scope reversed to system + `User=dev` |
| oracle: `MainPID`+`ps etimes` has a pid race | `ActiveEnterTimestamp`, `min(boot)` |
| oracle: glob can silently match nothing | explicit `serve-pool.nix` port list |
| oracle: fallback conflates broken-discovery with drained-pool | split; broken → `exit 1` |
| MAJOR — fail-closed quantifier was **"none parse"**, must be **"any active fails to parse"** | one-word fix, but it is the whole difference between fail-closed and fail-open: if the unparseable unit were the *oldest*, `CUTOFF` lands too late and the loot-incident class returns through the error path |
| MAJOR — roadmap + bead still mandated the abandoned user timer, so this step's own exit criteria were unpassable by its own implementation | both rewritten in this commit |
| MINOR — explicit list is weaker than the glob against a *stray* instance | discovery is the **union** of both |
| MINOR — the min-over-pool residual is the common case, not an edge | quantified, written down, filed as `workstation-63wo` |
| MINOR — acceptance test hardcoded tonight's boot time and `K=4` | asserts against `servePool.k` and the live `min()` |
| MINOR — deploy safety asserted, not enumerated | `build` + unit-file diff before `switch` |
| NIT — `--timestamp=unix` removes `date -d`; `[ -f "$DB" ] \|\| exit 0` is a permanent silent success | both applied (`exit 1`) |

Two claims the reviewer raised were **checked and dismissed by measurement, not
argument**: the 13 GB DB does not need a `time_updated` index (the predicate
scans in 1.8 s, and no index helps since there is no session filter), and gate
(b) is structurally immune to the stalled-but-alive class — a row a serve is
executing was created *by* that serve, hence after its boot, hence above
`CUTOFF`, for a stall of any length. That second one is what makes step 2 safe
to land next.

---

## Step 2 — Bound the swap, drop `MemoryHigh`, tighten `TimeoutStopSec`

**Bead:** `workstation-h1y6` (filed **2026-07-03**) · **Prefers** step 1 first.

`hosts/cloudbox/configuration.nix:841-842` → keep `MemoryMax=9G`, delete
`MemoryHigh`, add `TimeoutStopSec=15` (mirroring devbox's rationale), and — the
part devbox does *not* have — **add `MemorySwapMax`**. Rewrite the `DM5-5`
comment so it explains Max-only rather than the band.

**`MemorySwapMax` is not optional garnish; without it the step probably does
nothing.** See "The zram problem" above: the serve cgroup currently has
`memory.swap.max=max` against a 31.3 G zram device, and the wedged serve's
working set was 100 % anon with zero reclaimable page cache. Reclaim into zram
can make progress indefinitely, so `memory.max` need never escalate to an OOM
kill — the stall just relocates from 7 G to 9 G. Setting a small
`MemorySwapMax` (`0`, or a deliberate 256 M–1 G) is what makes "reclaim fails →
OOM → restart" true. Pick the value deliberately and write down the reasoning:
`0` forfeits zram's benefit for the serves entirely, which may be the right
trade for a process whose whole failure mode is thrashing.

**Do not ship this on the argument "devbox did it."** Devbox's serves are user
units in a user slice with a different `MemoryMax`; the recovery path must be
demonstrated *on cloudbox*. The premise is a chain — `MemoryMax` exceeded →
kernel OOM kill → `OOMPolicy=stop` → `Restart=always` fires within 10 s — and
`OOMPolicy=stop` is exactly the link that a reasonable person would expect to
*prevent* a restart. Prove it, on a scratch unit, before touching the pool.

- Spine: 2 optional, 3 no, **4 mandatory**.
- **Deploy in the 03:00 window**, or by an explicit `reset-workspace` run — a
  pool restart abandons in-flight turns on all four members at once, which is
  strictly worse than the bug on any ordinary afternoon. Note that
  `nixos-rebuild switch` will **not** restart the serves by itself if only
  `serviceConfig` changed in a way systemd applies live; verify what actually
  took effect rather than assuming.
- **Exit criteria:**
  - **Swap-faithful scratch control.** A unit carrying *the same* `MemoryMax`
    **and `MemorySwapMax`** as the pool, allocating **slowly-growing,
    compressible anonymous** memory, is OOM-killed and restarted inside ~10 s
    with the kill visible in `journalctl -k`. Both halves — killed *and*
    restarted. A fast allocator writing incompressible pages outruns zram and
    passes vacuously; that variant does not count.
  - Same control **without** `MemorySwapMax` must **fail to OOM** within a
    generous window. If it OOMs anyway, the zram analysis is wrong and
    `MemorySwapMax` should be reconsidered rather than shipped on a bad reason.
  - After deploy, on all four members: `MemoryHigh` = `infinity`,
    `MemorySwapMax` = the chosen value, `TimeoutStopUSec` = 15 s.
  - **Seven-day observation, reported as one of three outcomes** — never as a
    bare "no wedges":
    1. record daily max `MemoryCurrent` per member;
    2. **if any member exceeded ~8.5 G**: require a matching `journalctl -k` OOM
       entry, an `NRestarts` increment, and health restored within 60 s — this
       is the only outcome that *confirms* the fix;
    3. **if no member approached the cap**: record **"no trigger —
       inconclusive"**. Explicitly not success.

  > The first draft's criterion was "zero canary wedge dumps attributable to the
  > throttle band". Once `MemoryHigh` is gone **no** future dump can be
  > attributed to the band, so that passes by construction. It is exactly the
  > kind of criterion a tired future agent ticks without doing anything.

- **Rollback.** Trigger: **≥3 OOM kills on one member within an hour** (a kill
  loop), or any member failing to come back healthy after a kill. Action:
  `git revert` the config commit and rebuild; the pre-change band is a known,
  survivable state. `RestartSec=10` is well inside systemd's default start-limit,
  so systemd will not give up on its own — you must notice.
- **If the deploy did not take effect:** `nixos-rebuild switch` may leave the
  running units on the old cgroup properties. `systemctl daemon-reload`
  reapplies cgroup settings to running units; if the properties still read old
  after that, restart the pool in the 03:00 window. Verify with
  `systemctl show`, never by reading the Nix source (`workstation-am5v`).

## Step 3 — Why does one member reach 7.35 G? · **ANSWERED 2026-08-02**

**Bead:** `workstation-9b3o` · **Sampling starts BEFORE step 2. Do not wait.**

> **The question contains a false premise.** No member "reaches 7.35 G" as a
> standing state. Every member bursts, the bursting member *moves*, and the
> baseline is 1–2.7 G for all four. The answer, and the two things it changes
> about step 2, are at the end of this section. The suspect list below is
> preserved because one of the two suspects died and that is worth showing.

Step 2 makes the *symptom* recoverable in 10 s. It does not explain why 4098
grew 6× past its peers — and once step 2 lands, a ballooning member is killed by
the kernel within seconds, bypassing the canary, leaving **no forensics dump and
no plateau to autopsy**. The current, broken regime is the best observation
window this problem will ever get. Start the sampler now and let it run across
the change.

This matters doubly because two of the day's three bad windows are unattributed
(see the episode table). Deferring all investigation until after the fix risks
declaring victory over the minority class.

Two named suspects, neither confirmed:

- **12 `notify-rs debounce` threads.** File-watcher debouncers, one per watched
  tree. A serve that has accumulated many worktree watchers holds correspondingly
  many watch sets. Cheapest thing to check.
- **Mega-sessions.** Largest session 8729 messages;
  `ses_069f33c28ffenocH2RrfU83cZ5` has 4312 and was live-attached by two TUIs.
  A serve that happens to hold two of these carries their full message history.

Method: sample `MemoryCurrent` + thread counts per member hourly against the set
of sessions each is serving, and see which correlates. Deliberately
measurement-only — do not pre-commit to a remedy.

- **Exit:** a written answer, or an honest "did not correlate", plus a decision
  on whether any follow-up is warranted. A step whose output is "we do not know"
  is a valid outcome and must be recorded as such rather than quietly dropped.

### The answer — 3 928 ticks over 17.5 h (08-01 21:34 → 08-02 15:00)

Sampler: `/home/dev/s3-sampling/sample.sh`, appending
`/home/dev/s3-sampling/samples.tsv` every 15 s from a **transient** `systemd
--user` timer (`s3-sampler.timer`). Read-only: `/proc`, `systemctl show`,
cgroup `memory.stat`, and a `mode=ro` handle on pigeon's routing DB. It survived
this session, the 03:01 nightly reset and the 10:25 deploy; it would not survive
a reboot.

**1. It is bursts, and the burster moves.** 4098 burst on 08-01; **4096** burst
on 08-02, peaking at *exactly* 7.00 G — `MemoryHigh` — five samples pinned
there. 4097 and 4099 never crossed 6.0 G in the entire window. Every member
returns to a 1.0–2.7 G baseline; **nothing accumulates.** The headline
"7.35 G vs 0.67 G" pair was one sample of an oscillation taken while the peers
happened to be idle.

**2. Session count does not predict memory. Watcher/fd count does.** Pearson
*r* against `MemoryCurrent`, computed *within* each port's own series:

| metric | 4096 | 4097 | 4098 | 4099 |
|---|---|---|---|---|
| `threads` | 0.83 | 0.98 | 0.89 | 0.96 |
| `fds` | 0.78 | 0.97 | 0.89 | 0.92 |
| `inotify_fds` | 0.79 | 0.97 | 0.89 | 0.92 |
| `notify_debounce` | 0.79 | 0.97 | 0.89 | 0.92 |
| `inotify_watches` | 0.83 | 0.88 | 0.73 | 0.89 |
| **`assign_total`** | **0.33** | **0.02** | **−0.18** | **−0.18** |
| **`assign_active_1h`** | **0.39** | **0.01** | **0.05** | **0.06** |
| **`assign_active_10m`** | **0.18** | **0.00** | **−0.08** | **0.01** |

`rss`, `pagetables` and `file` also score 0.8–1.0 but are restatements of
memory itself and are not evidence.

**Suspect 2 (mega-sessions) is dead.** Between members the relationship is if
anything *inverse*: 4098 medians 2.65 G on **38** assignments; 4097 medians
0.65 G on **191**. Message history does not travel with memory.

**Suspect 1 (notify-rs watchers) survives, in modified form:** what tracks is
the count of watcher **instances** (≈ one per open project tree), not the raw
watch count — 4097 and 4099 each hold ~43 k watches at a third of 4098's memory.

*Honest caveat:* threads, fds and watchers all rise together when a session
opens a tree, so this is co-movement, not isolated causation. The **negative**
result is the solid one; the positive one is consistent but not proven.

**3. An instrumented band entry** — 4096, 08-02, 48 s between rows:

```
11:18:23  1.75G  anon 1.18  file 0.51  swap 0.00
11:19:59  6.73G  anon 2.99  file 3.53  swap 0.00   <- ramp is ~50% PAGE CACHE
11:21:35  7.00G  anon 4.52  file 2.25  swap 0.00   <- pinned at MemoryHigh
11:22:23  7.00G  anon 5.82  file 0.77  swap 1.49   <- cache evicted, now swapping
11:23:11  2.93G  anon 2.30  file 0.38  swap 1.54   <- collapsed, recovered itself
11:33:35  7.00G  anon 6.25  file 0.29  swap 6.22   <- second entry, 6.2G into zram
11:34:23  1.30G  anon 0.97  file 0.08  swap 2.68
```

`assign_active_10m` was 0–1 throughout: **one session**, doing a burst of file
reading — a big scan, not a leak.

### What this changes about step 2 — read before deploying it

- **BLOCKER-2 is confirmed on a real serve, not inferred from config.** The
  cgroup pinned at exactly `MemoryHigh` and relieved the pressure by pushing
  **6.22 GiB into zram**, then recovered. `MemorySwapMax` is not optional; without
  it, dropping `MemoryHigh` most likely relocates this to 9 G instead of
  converting it to a fast kill.
- **Band entry is routine and usually harmless.** 4096 entered the band **three
  times in 15 minutes** and the canary logged *nothing* — health probes never
  failed. So hitting `MemoryHigh` is not the wedge; a band entry that *fails to
  recover* is. This is the self-recovering class from the 08-01 episode table,
  now captured with instrumentation. Removing `MemoryHigh` therefore removes
  something that fires often and mostly benignly, and the open question becomes
  whether `MemoryMax=9G` sits far enough above these routine 7.00 G peaks — or
  whether the peaks simply move up and start dying. Decide that deliberately
  rather than by devbox precedent.
- **"100 % anonymous" was the post-throttle endpoint, not the composition.** The
  ramp is roughly half reclaimable page cache, so reclaim gets ~2 G of cheap
  progress before it is forced onto anon and swap.

### Follow-up

`workstation-9b3o` is answered and closed. The residual question — *what makes
one session's file scan cost 5 GiB* — is not this roadmap's; it needs an
application-level look at the watcher/scan path, and is worth filing only if the
band entries stop self-recovering.

## Step 4 — Reclaim the 6.2 GiB of dead pages *(low priority)*

**Bead:** `workstation-bm1i` (cloudbox arm; the devbox arm is done) · **Depends on:** step 1.

51 % of the DB is freelist. Reclaim it — but note what this step is **not**: it
does not reduce any serve's RSS, so it has nothing to do with the wedge. It is
disk hygiene, on a volume with 109 G free. It is in this roadmap because it was
asked for, and it is last because of that ordering.

Prefer **`VACUUM INTO` a new file, then swap**, over in-place `VACUUM`: in-place
requires the original writable and leaves the DB unusable and unrecoverable if
interrupted mid-run, whereas `VACUUM INTO` writes a fresh file and the original
stays intact until an atomic `mv`. Both still require quiescence — a snapshot
taken while a serve is writing loses everything written after the read
transaction opened — so the copy must be made with the pool stopped.

- Run inside the 03:00 window, after `reset-workspace` has stopped the pool.
- Detach it (`setsid nohup … & disown`) with a grace `sleep` so that stopping
  the DB holders cannot kill the job itself mid-write.
- **Exit criteria:** `PRAGMA integrity_check` = `ok` on the new file *before*
  the swap; **`PRAGMA journal_mode` on the new file is `wal`** — `VACUUM INTO`
  is *suspected* not to carry the mode across, and a delete-mode DB under four
  concurrent serves is a lock storm; session/message/part counts match
  pre-vacuum exactly; no stale `-wal`/`-shm` remains beside the swapped-in file
  before the pool starts; the old file is kept until the pool is back healthy;
  `freelist_count` near zero.

---

## Deliberately NOT doing

**Killing the 3 duplicate attach TUIs as a step of its own.** Rejected on two
grounds. (1) It is already handled, **structurally**: `reset-workspace`
`pkill -9`s every `nvim` (`pkgs/reset-workspace/default.nix:739`), restores only
TUIs descended from a `main` tmux pane (`:436-448`, `:548`, `:598`), *and*
dedupes the restore manifest by session id (`:646`,
`awk 'NF && !seen[$0]++'`) — so even two `main`-parented TUIs on the same
session come back as one. Duplicates cannot survive the night. (2) There is no
reliable way to tell which member of a duplicate pair is the abandoned one; the
failure mode of guessing wrong is killing a session a swarm worker is actively
driving. The load itself was measured and mostly exonerated — of the top 6
spinners only one session had phantom-busy rows, so the CPU is largely **genuine
swarm work**. Load 11–26 on 16 cores is busy, not broken.

Accepted cost, named rather than hidden: duplicates re-created during the day do
double that session's SSE and render load on its serve until 03:00.

**Reducing `MemoryMax` below 9 G.** 4 × 9 G = 36 G worst case on a 62 GiB box
with a `user-1000` slice `MemoryHigh` of 56 G and `OOMScoreAdjust=500` on the
serves. There is headroom; tightening the cap would trade one throttle problem
for a kill-loop.

**Touching the canary.** It worked: it detected all three episodes and recovered
the serve. Step 2 aims to make it *unnecessary* for this failure class, not to
replace it. Keep it as the backstop for the classes it still owns (see
`workstation-nv5l`, the alive-but-stalling member).

**Anything about `global-ro` / the front door / pool failover.** Owned by
`workstation-nv5l` and the frontdoor session. Do not start it here.

---

## Known residuals

- **`workstation-lbe2`** — found during this roadmap's review, not scheduled
  here. The canary's forensics-retention prune is dead: it calls `xargs`, which
  is not on its `PATH`, and the failure is swallowed by `|| true`. Dump
  directories accumulate unbounded. Harmless today (one dump exists); it will
  bite exactly when wedges get frequent.

- **`workstation-nv5l`** is the 10:47–10:57 stall, and the episode table above
  now shows it is **not** the throttle band: the canary counter reset mid-window,
  so `/global/health` was intermittently succeeding. Cloudbox has a second wedge
  class that degrades service without ever tripping the canary — 979 session-path
  503s through the door during that window. The 15:29–15:43 window has the same
  signature and no forensics. **This roadmap does not claim to fix either.**
  Two of three bad windows on the day remain unexplained.
- The canary's health probe is a liveness check, not a latency check. A serve
  that answers `/global/health` in 3 s while stalling every real request stays
  invisible to it.
