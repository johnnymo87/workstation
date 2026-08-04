# Cloudbox serve memory — attribute the burst, land the residuals

**Spine bead:** `workstation-rdsq` · **Started:** 2026-08-03 · **Host:** cloudbox only

**Predecessor:** `docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md`
(spine `workstation-7za8`). Steps 0–3 deployed; step 4 handed to
`workstation-yvxh.4`. That roadmap fixed the **consequence** of the memory
bursts. This one is about the **cause**, plus the residuals it left open.

**Status:** S0 done · S1 done · S4 worked (fix **rejected**, deferred to S2) ·
S6 done (pigeon PR #56 + sampler v3) · **nothing unblocked; every remaining step
is time- or peer-gated**

- **S2** is time-blocked: 7-day window ends **2026-08-09 22:37 Z**; ~0.9 days
  elapsed, and **zero OOM kills so far** (`NRestarts=0` on all four,
  `memory.events oom_kill=0`). Reporting now would be the "passes by
  construction" non-result the step explicitly forbids.
- **S3** (`le0a`) is gated on a peer's `workstation-yvxh.4`; wake set 08-10.
- **S4** (`63wo`) is **worked and closed out for now**: the proposed per-owner
  gate is unsound, measured harm is 7-and-1 rows, and a pre-committed rule ties
  the build/wontfix decision to S2's kill count. Wake set 08-10.
- **S5** (`yvxh.6`, P3) is largely landed.
- **S6** (`29k3`) is **done**: pigeon PR #56 (merged `04401f5`) renames the field
  and deletes the dead renewal path; the sampler rotated to `samples-v3.tsv` and
  now emits `lease_live` instead of the two lying `assign_active_*` columns. Note
  the merged pigeon commit is **not yet deployed** — the live checkout is a pull
  behind and the daemon runs off it, so the operator's next pull+restart picks up
  #54 and #56 together.

---

## Facts that must survive compaction

### What is already deployed, and what it did

The serves run **max-only** memory (`hosts/cloudbox/configuration.nix`):
`MemoryHigh` removed, `MemoryMax` 9 G → **14 G**, `MemorySwapMax=1G`,
`TimeoutStopSec=15`.

> **Two different start times, and the observation window uses the later one.**
> The config was deployed at **2026-08-02 18:57 Z**, but the live cgroup did not
> get it until **2026-08-02 22:37:12 Z** — the sampler's `mem_high` column shows
> `7516192768` → `max` at that instant, under an unchanged pid (2601066), i.e.
> applied without a process restart. Earlier revisions of this doc dated the
> regime from 18:57, which is the config-vs-kernel error this spine exists to
> stamp out. **The S2 window runs from 22:37:12 Z and ends 2026-08-09 22:37 Z.**
>
> This also re-scopes the 28.50 G episode: at 19:52–20:05 on 08-02 `mem_high`
> was still 7 G, so that episode is **pre-regime**, not a post-fix burst. Any
> S2 table that includes it is comparing across the change it is measuring.

Day-1 result over 14.1 h:

| | before | after |
|---|---|---|
| door 5xx | 3.05 % during swap ≥5 G episodes | **0 of 112 034** |
| max swap | 22.43 GiB | **0** |
| PSI `full` | 483 s on 4099 | **0 s** |
| `memory.events high` | 1 064 918 | **0** |

**The cause was never found.** A serve still reached 14.00 G on 08-02 23:54
(93 % page cache, harmless, not killed). The 28.5 G anonymous burst that
motivated all of this is unexplained.

### What is dead, what is only *scoped* dead, and what is still live

Read the scoping. Three of these rows kill a **standing/accumulative** claim and
do **not** kill its episodic form, which matters because the thing we are hunting
*is* episodic: 28.5 G in 13 minutes, then GC'd back.

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Mega-sessions / message history **as standing memory** | dead | `assign_total` vs memory *r* = −0.18…0.33 |
| Session count **as standing memory** | dead | 4098 medians 2.65 G on 38 assignments; 4097 0.65 G on 191 |
| Permanent single-member accumulation | dead | the bursting member *moves*; all four return to 1.0–2.7 G |
| **Cumulative** distinct directories ever routed | dead | 24/25/26/24 dirs → 12.47/2.17/6.33/**28.50** G peaks |

**Still live, and not to be confused with the dead rows above:**

- **Episodic history hydration.** Nothing above measures *message-history size* —
  `assign_total` counts assignments. A one-shot unbounded load (attach,
  compaction, summarisation) has exactly the observed shape. Our own
  `compaction-bounded-load` patch exists *because* history loads were once
  unbounded.
- **Concurrently-live instances / per-request directory resolution.** The dead
  row above only kills the *cumulative* form, which converges by construction:
  over 20 h every serve sees roughly every directory, so 24/25/26/24 is an
  artifact of the window, not a finding. Every `/children?directory=` poll runs
  through the workspace-routing middleware, which resolves the directory **per
  request** (`packages/opencode/src/server/routes/instance/httpapi/middleware/`
  `workspace-routing.ts`, `defaultDirectory`). How many instances are live *at
  once*, and whether they are ever disposed, is **untested**.

> **A number that looks like evidence and is not.** An earlier draft cited
> within-serve *r* ≤ 0 between cumulative-distinct-dirs and memory. That is a
> statistical artifact: cumulative dirs is monotone nondecreasing while memory
> oscillates back to baseline, so the correlation is forced negative regardless
> of the truth. It has been removed. Do not reintroduce it.

> **RETRACTED 2026-08-03 by S1.** An earlier revision called this the cleanest
> clue: "`threads` (~70) and `fds` (~95) stayed flat through the entire 28.5 G
> ramp — whatever allocated 28 GiB did so **without opening anything**." That
> inference is an **instrument artifact**. `sample.sh` reads `threads`, `fds`
> and `rss_kb` from `/proc/<MainPID>/status` but reads `anon`, `swap` and
> `pagetables` from the **cgroup**, which spans every process in the unit. The
> flatness is therefore true of the *main opencode process only* and says
> nothing about its children — which is precisely where the memory turned out
> to be. Do not reintroduce it. It is the same failure mode as
> `assign_active_10m`: a convenient surface answering a slightly different
> question.

Caveat on all four rows: they were measured **under the old band regime**
(forced reclaim at 7 G, heavy swap churn). Post-2026-08-02 bursts may differ in
shape; the standing-memory verdicts survive the regime change, the quantitative
details may not.

### The premise of the whole question was wrong

`workstation-vpid` was filed as "28 GiB in an **idle** serve". It was not idle.
During the episode 4099 served **602 requests from 5 distinct sessions**
(580 session-path), at **p50 132 ms / p95 1629 ms / max 5008 ms** — degraded
while serving. One of the five sessions was the roadmap session itself.

The "idle" reading came from `assign_active_10m=0`, which is a lie of naming.
`S6` fixed it; the mechanism is not what this section first said, and the first
correction was wrong too, so it is worth stating exactly.

`session_assignment.last_active_at` is written by **one** path: `RouteRepo.upsert`,
whose only caller is `Router.placeSession`. It records when pigeon last **placed**
the session on a serve. (This doc previously said "written only by
`RouteRepo.touchActive` on lease renewal". `touchActive` was real but **dead** —
its only caller, `Router.touch()`, had no production callers and never had one.
pigeon renews nothing; the **serve** renews its own lease out of process.)

Placement recency is not a weak activity signal, it is a **path-dependent** one,
which is worse:

- **A live lease suppresses placement.** `placeSession` runs only when
  `resolveRoute` returns null, and `resolveRoute` succeeds while a live lease
  exists — which the serve renews on a 10s fiber for the whole duration of a turn.
  Sustained work suppresses the very placement one wants to read as evidence of it.
- **Most traffic never places at all.** Placement happens only on pigeon's own
  paths (`POST /place`, `OpencodeClientFactory.forSession`). A TUI or front-door
  request is served by `GET /route`, which is deliberately read-only.

So the field is fresh for pigeon-delivered sessions and arbitrarily ancient for
TUI-driven ones. A uniformly wrong metric gets distrusted the first time anyone
checks it; this one stays plausible on whichever session you spot-check, which is
exactly how it survived to frame this investigation.

**Every "idle" claim anywhere in the predecessor roadmap must be re-read as "no
recent pigeon *placement*", which implies nothing whatsoever about load.** Where
you need real activity, read `session_lease` — the serve holds a lease for the
duration of a turn and releases it in a finalizer at turn end.

### The episode itself — the one worked example

**2026-08-02 19:52–20:05 UTC** (15:52–16:05 EDT), epoch **1785699000–1785700900**,
serve **:4099**, pid 2601066. `memory.current` pinned at exactly 7.00 G
(= the then-`MemoryHigh`) for 13 minutes while `anon` held 6.1–6.5 G, `file` fell
to ~0, and swap climbed monotonically 8.6 → **22.43 GiB**, then drained. Total
anonymous demand ≈ **28.5 G**. `threads` ~70 and `fds` ~95 **flat throughout**.

Five sessions were routed to :4099 during it; three were polling steadily
(`ses_04028cb5bffer1Ji74FUOZ2jVi`, `ses_0404b7301ffeBjtSrUv9u1u3Ub` — the
roadmap session itself — and `ses_04501f627ffeDB3OoNmTnAZdc8`), at 192/192/191
requests each.

**The door log for this window is archived** at
`docs/investigations/2026-08-02-serve-memory-bursts/episode-4099-door-log.jsonl.gz`
(5 630 request lines, 19:45–20:12 UTC). Archived deliberately: journald here is
size-rotated with no explicit retention, and that log is the evidence under most
of the table above. Once it rotates, the table becomes unfalsifiable folklore.

### The workload during the burst

Near-exclusively `GET /session/<id>/children?directory=<path>` — 192 + 192 + 191
calls from three sessions over ~17 min, i.e. one per session per ~5 s (the TUI
child-session poll). `Session.children` itself is **ruled out**: in v1.17.13
(`packages/opencode/src/session/session.ts:598`) it is a plain SELECT on
`parent_id` returning session rows only — no messages, no parts.

### Environment

We run **`opencode-patched-1.17.13.7`** = upstream **v1.17.13** + 26 local
patches (`~/projects/opencode-patched/patches`). Memory-relevant ones:
`project-copy-debounce`, `globalbus-maxlisteners`, `event-log-gate`,
`compaction-bounded-load`, `step-end-diff-bound`, `tui-reconcile-bound`,
`event-session-scope`, `bootstrap-disposed-filter`.

`~/projects/opencode` is checked out at **v1.17.13** as of 2026-08-03. Three
locally-authored, never-pushed commits that were on a detached HEAD are
preserved on branch **`wip/pre-v1.17.13-checkout-20260803`** — two of them
(`share memoMap between TCP listener and in-process webHandler`,
`make InstanceBootstrap injectable`) are plausibly relevant to S1 and are worth
reading before profiling. Untracked `DB-CORRUPTION-RESEARCH.md` and 4 stashes in
that clone belong to other work; leave them alone.

### Instruments that already exist — use them before building anything

- **Sampler**: `/home/dev/s3-sampling/sample.sh`, 15 s, per-cgroup memory +
  threads/fds/inotify + pigeon assignments → `samples.tsv`. Transient user
  timer; does **not** survive reboot. Relaunch command and column semantics in
  `docs/investigations/2026-08-02-serve-memory-bursts/README.md`.
- **Door log join**: `journalctl -u opencode-frontdoor` emits one JSON object
  per request with `target`, `sid`, `class`, `status`, `durationMs`, `query`.
  Joined per-minute against the sampler, this is what killed three of the four
  dead hypotheses and what proved the serve was not idle. **It fires without a
  wedge**, which the canary's forensics dumps cannot. The dumps remain strictly
  better for mechanism autopsy (`memory.stat` composition, kernel/user stacks
  mid-wedge) — different axes, not a replacement.
- **Two timestamp traps** in that join, both of which have already produced a
  false result once: the door's `ts` is **UTC** while the sampler's is epoch —
  build comparison bounds in UTC explicitly. And `memory.current` **includes
  page cache**, so judge demand on `anon`+`swap`, never `MemoryCurrent`.

### The verification rule, and the two traps that apply to THIS spine

**Verify against the built artifact and the kernel, not the config.** Every
failure in the predecessor roadmap came from reading a convenient surface that
answers a slightly different question, confidently. Two of those are live hazards
for the work below:

| Surface | What it actually answers |
|---|---|
| `assign_active_10m` | lease-renewal recency, **not** activity (cost: this spine's entire framing) |
| `memory.current` | includes page cache — a serve pinned at the cap can be 93 % cache and perfectly healthy. Judge demand on `anon`+`swap`. |

The others (`systemctl show` vs cgroupfs, unit `Environment=` vs a script's own
exported PATH, a grep hit vs two hits in the same service) are recorded in the
predecessor roadmap and belong in a skill, not here.

---

## Per-step protocol

Same as the predecessor spine, which worked: **compact → optional `oracle-fable`
consult → SDD if applicable → mandatory `adversarial-reviewer-fable` → PR if
applicable → update roadmap and beads**. Both subagents are standing-authorized
for this spine.

## Steps

### S0 — This roadmap · `workstation-rdsq` · **DONE 2026-08-03**

### S1 — Attribute the burst · `workstation-vpid` · **DONE 2026-08-03**

**Mechanism: the burst memory is allocated outside the main opencode process,
in the serve unit's child processes.** Identity is *suspected*, not proven —
read the scoping below, it is the whole point of this section.

#### The instrument defect that hid it for two sessions

`sample.sh` mixes two scopes in one row: `threads`, `fds`, `inotify_*`, `rss_kb`
come from `/proc/<MainPID>/status`; `anon`, `swap`, `pagetables` come from the
**cgroup**, which spans every process in the unit. Every "flat threads/fds"
conclusion built on that row was scoped to the main process only. See the
retraction above. Both scripts now carry that warning in a header comment.

#### The proof, chosen to be confound-free

The tempting statistic — `(anon+swap) − mainRSS` — is confounded: `VmRSS`
excludes swapped-out pages, so a main process pushed to swap looks like it "lost"
memory to children. `sample.sh` never recorded `VmSwap`, so that confound cannot
be retired retroactively.

**Resident anon at ignition retires it anyway, because swap was still zero:**

| 19:51 UTC | cgroup resident `anon` | main-PID RSS | non-main resident | `swap` |
|---|---|---|---|---|
| :24 | 1.26 G | 1.35 G | ~0 | **0.00 G** |
| :40 | **3.47 G** | **1.36 G** | **+2.11 G** | **0.00 G** |

Main-process RSS is flat *across the ignition* while 2.11 GiB of **resident**
anonymous memory appears in the cgroup, with no swap in existence to explain it.

Three reasons this estimator is safe. `VmRSS = RssAnon + RssFile + RssShmem`, so
main's *anon* ≤ `VmRSS` — the slack biases **against** the claim, making
`cg_anon − VmRSS` a lower bound on non-main anon. Cgroup-v2 `anon` excludes
shmem/tmpfs (charged to `file`) and excludes kernel-side charges (`slab`,
`pagetables` are separate counters), so neither can fabricate it. And split-RSS
counter lag is bounded by ~64 pages/thread ≈ 18 MB at 72 threads — three orders
of magnitude short of 2.11 G.

Nor is this a one-sample artifact: the plateau holds **≥5.7 G of non-main
resident anon at every one of ~50 consecutive samples** across 19:51:56–20:02.
No within-gap transient can alias that.

**Shape correction.** Not the "~1 G/min for 13 min" this spine assumed: 1.26 →
17.60 G in **65 seconds** (~5.8 G per 15 s tick, *while* `memory.high` was
throttling the allocator), then a slow climb to 28.50 G at 20:00, then full
release to 1.30 G by 20:06.

#### Prime suspect: eager MCP fan-out on new-directory bootstrap — not tsserver

The obvious story (tsserver indexing a big repo) **has no trigger and is close to
excluded**. LSP clients spawn only via `lsp.touchFile`, whose only callers are the
`read`/`write`/`edit`/`lsp`/`apply_patch` tools (`tool/read.ts:119`,
`write.ts:75`, `edit.ts:197`, `tool/lsp.ts:80`, `apply_patch.ts:269`) plus a debug
command. And **zero tool parts of any kind** were recorded for :4099's five tenant
sessions or their direct children across 19:30–20:10. No tool touch on that serve
means no LSP spawn from its tenants.

MCP clients need no such trigger: the instance-state initializer spawns **every
configured MCP server eagerly**, `concurrency: "unbounded"`, on instance
creation (`mcp/index.ts:496-520`).

The timeline fits that and only that:

| UTC | event |
|---|---|
| 19:50:26.378 | first-ever appearance on :4099 of `/home/dev/projects/culinary-operations-server/.worktrees/pr-4602` — sid-less `global-ro` TUI-startup traffic (`/experimental/capabilities`, `/api/integration` 463 ms, `/api/command` 462 ms) |
| 19:50:36 | main-pid `inotify_watches` +258, threads 68→72 — instance bootstrap |
| 19:51:40 | ignition, +2.11 G resident anon outside main |

74 seconds, bootstrap to ignition. tsserver is demoted to "possible only if a
trigger is found"; the file-watcher bump is real but is a **main-process** metric
(`sample.sh` reads `/proc/MainPID/fdinfo`, so it can never see a child's watches)
— it evidences the bootstrap, not the allocation.

#### Why the child fleet is never reclaimed

- `LSP.state` and `MCP.state` are both `InstanceState.make<State>` — **per
  instance, i.e. per directory** (`lsp.ts:145`, `mcp/index.ts:484`).
- Teardown is an `Effect.addFinalizer` that runs **only on instance dispose**
  (`lsp.ts:198`).
- `InstanceStore` caches instances in a plain unbounded `Map` with **no TTL and
  no LRU** (`instance-store.ts:43,108-124`); dispose happens only on explicit
  `dispose`/`disposeDirectory`/`disposeAll` or process shutdown
  (`instance-store.ts:192`).

So one directory routed once to a serve pins a child fleet in that serve's cgroup
for the life of the process. Verified live today: **24 MCP child processes on
:4097**, in repeating identical trios. Grepped all 26 patches in
`opencode-patched` — **none touch `lsp.ts`, `instance-store.ts`, or MCP spawn/
dispose lifecycle**, so upstream v1.17.13 is the right source to read.

This also retires the last directory-fan-out lead, but not in its favour:
per-request resolution is cheap (`InstanceStore.load` is memoised, and for
session-path requests `session.directory` wins over `?directory=` anyway —
`workspace-routing.ts:182`). The cost is not *resolving* a directory; it is the
**child fleet the first resolution spawns and never reaps**.

#### Scope of the claim — what is proven, suspected, and unmeasured

- **Proven:** allocation is non-main, for the resident core — ≥2.11 G at
  ignition, ≥5.7 G at every sample through the plateau.
- **Suspected, not proven:** that the children are the MCP/LSP fleet. The live
  `cgroup.procs` inventory is a **different process generation** (unit has since
  restarted, main pids differ) and is legitimate only as "this structure exists
  and reproduces today" — never as episode identity. A fork transient or another
  spawned helper is not excluded.
- **Unmeasured:** the ~22 G that went to **swap** is attributed by parsimony
  only. Without `VmSwap` we cannot exclude the main process allocating and
  immediately swapping under `memory.high` — its RSS staying pinned low is
  exactly what the band would do. **So "28.5 G was in children" is NOT
  established; "≥6 G resident was, at every instant" is.**
- The tool-part negative means "no tool-part rows recorded in-window for tenants
  one level deep". It does not cover grandchildren, processes backgrounded
  before 19:45 that linger in the cgroup, or sid-less actors — and the bootstrap
  traffic itself was sid-less, hence invisible to any session join.
- **Cut as unsound:** an earlier draft argued page-table overhead rising 0.39 % →
  2.8 % showed "many sparse address spaces". Wrong. Per-byte PTE cost is ~0.195 %
  *regardless of process count*; reaching 819 M that way needs thousands of
  processes. High overhead indicates **sparse/fragmented VA** — which one
  JS-engine heap produces just as well (GC/`MADV_DONTNEED` zaps PTEs without
  freeing page-table pages). It discriminates neither count nor identity.

#### The escalation was armed at the wrong target — corrected and deployed

The pre-declared escalation was "JS stacks from the main process via the Bun
inspector". Given the above that would have profiled the **wrong address space**.

Deployed instead: `child-capture.sh` + `child-capture.timer` (transient user
timer, 15 s). On any serve crossing `anon+swap ≥ 6 G` it writes **one row per
process in the cgroup**, including `VmSwap` — the column whose absence is the one
confound S1 could not retire. Threshold is 6 G not 8 G because the observed ramp
was 5.8 G/tick *while throttled*; with the band gone a burst can cross 8 G, hit
the 14 G `MemoryMax`, be killed and fall back inside one timer interval.
Cooldown is **per port**, so one serve parked above threshold cannot suppress
another's fresh ignition. `sample.sh` gained `main_swap_kb` and rotated to
`samples-v2.tsv` (23 cols) so no file ever carries two column counts.

**Free second instrument:** a `MemoryMax` OOM kill dumps a full per-process
RSS/swap table to the kernel log. `journalctl -k` around any kill gives
attribution for exactly the episode `child-capture` would outrun.

Both are transient units and **do not survive reboot**.

#### First live capture, 2026-08-03 19:32:56 UTC — identity confirmed

`child-capture` fired within minutes of arming, on **:4098 at 6.55 G**, and the
row set says exactly what S1 predicted:

| | |
|---|---|
| cgroup `anon` | 6.55 G |
| main opencode process | **1.88 G** |
| 44 child processes | **6.31 G** |

| child category | procs | sum RSS |
|---|---|---|
| `typescript-language-server` / `tsserver` | **16** | **3.05 G** |
| other node helpers | 13 | 2.21 G |
| MCP servers | 11 | 0.75 G |
| `bash` / `pyright` / `eslint` / `lua` LSP | 4 | 0.30 G |

This **upgrades child identity from suspected to confirmed** for a live episode:
the children are real, they are the LSP/MCP fleet, and they hold 3.4× the main
process. It does not retroactively identify the 08-02 episode's children — that
still requires a capture during a burst of that size — and the swap-attribution
gap for the original 22 G stands unchanged.

It also makes `workstation-rdsq.1` concrete rather than theoretical: those 16
TypeScript LSP processes serve only **two** project roots (`pigeon` ×9,
`internal-frontends` ×3). Nine language servers for one repository is the
never-reaped fleet, measured.

#### Follow-on filed

`workstation-rdsq.1` — LSP/MCP child fleets are never reaped because instances are
never evicted. That is the standing-memory defect behind both the burst headroom
and the duplicate-MCP accumulation. Not fixed here; S1 was scoped to attribution.

### S2 — The 7-day report on the memory posture · `workstation-h1y6`

Wakes fire **2026-08-09 23:00 UTC** (primary) and **2026-08-10 00:30 UTC**
(backstop), moved 2026-08-03 from 14:00/15:30: the window starts when the kernel
got the limits (22:37:12 Z), not when the config shipped (18:57 Z), so the
original times fired **8.6 h before the 7 days were up**. Report as one of the
four outcomes with the pre-declared cap-adjustment rule; the criteria live in the
predecessor roadmap's step 2 and must not be improvised.

**Interim state as of 2026-08-03 21:10 Z (0.94 d elapsed) — not a result:**
zero kills, `memory.events oom_kill=0` on all four, and post-regime peak
`anon+swap` of 8.51 / 4.92 / 6.56 / 8.01 G against the 14 G cap. Recorded so the
reporter can see the trend, *not* as an early finding — a quiet window is what
this design produces when nothing is being stressed.

**Redundant ownership, because a wake pointed at one session id is a single
point of failure** and this doc's whole premise is surviving the loss of a
session. Three independent triggers now exist: the primary wake (14:00 UTC), a
**backstop wake to the morning agent** at 15:30 UTC which checks whether the
report was already written before doing anything, and a **`due: 2026-08-09` on
`h1y6`** so it surfaces in any `bd` listing regardless of wakes. The full
procedure lives in the bead's notes, so any session can execute it.

- A **kill** is the only outcome that confirms the fix. "No wedges" passes by
  construction now that the band is gone and must not be reported as success.
- Count **orphaned phantom rows per kill**: an OOM-killed serve never runs
  `SessionProcessor.cleanup`, so it strands a `time.completed=NULL` row that
  shimmers until the sweeper cutoff. `<sweeper> --dry-run` reports the count and
  takes no write lock.

### S3 — Attach the aggregate slice cap · `workstation-le0a`

One-line change: `Slice = "opencode-serve.slice"` on the serve units. The slice
is already defined with `MemoryMax=32G`.

**It cannot ship without restarting the pool in the same deploy.** Shipping it
with `restartIfChanged=false` made systemd re-realize the units into the new
slice while the processes stayed in the old one, dropping `memory` from the old
slice's `cgroup.subtree_control` — the per-serve limit files **ceased to exist**
and all four serves ran unbounded, while `systemctl show` reported the new
values. Reverted in PR #264.

Coupling to `yvxh`'s W3 drain is **released**: land it in an announced nightly
reset if W3 slips. **Check `bd show workstation-yvxh.4` to decide — the calendar
is only a tiebreak**, and ~2026-08-17 is the point at which to stop waiting; a
reader after that date cannot otherwise tell slipped from landed. Their one hard constraint stands — **no pool
restart between their VACUUM snapshot and their `mv`**. Verify on cgroupfs at
the new path afterwards.

### S4 — Bound the cost of a kill · `workstation-63wo` · **WORKED 2026-08-03 — FIX REJECTED, DEFERRED TO S2**

**The sweeper ships unchanged.** The bead's own fix direction — a per-owner gate
via the routing DB — is unsound, and the measured harm does not yet buy even a
sound fix. Full reasoning in the bead; the load-bearing parts:

**Per-owner attribution has no sound source.** It needs "which serve owned
session S at time T", and every candidate fails: `session_assignment` is
current-state only; `session_lease` has a 30 s TTL and is released by `sweep()`
long before the sweeper's 5-min timer plus 30-min staleness gate; and
`reassignment_event` is **lossy by construction** — its insert is deliberately
swallowed (`router.ts:259-269`) because an observability write must never fail a
route, and the comment notes SQLITE_BUSY "happens on this shared DB **when
serves restart together**", i.e. it is lossiest exactly around restarts. It also
records only *moves*, never initial placements (measured: 0 rows with
`from_serve_id IS NULL`).

**The lease-liveness alternative fails on our own motivating case.** The lease is
genuinely turn-scoped (`serve-lease.patch:1596`, TTL 30 s, renewal every 10 s),
but three fail-open paths run turns with **no lease at all**, and a
wedged-but-alive serve starves its own renewal fiber (`router.ts:361-380`) so its
leases expire *while the turn still executes*. It would false-abort precisely the
canary-wedge scenario that motivated the bead.

> **The rejection is scoped to the routing DB — attribution is NOT impossible.**
> Two sound signals exist. The **door log** carries `sid` + the target the request
> was actually forwarded to, and the serve that received the turn-starting POST is
> the serve that created the row; that is a sound condition, rejected on **cost**
> (parsing journald JSON inside a destructive shell script), not soundness. Better
> still is a **write-time provenance stamp**: we already patch the serve and it
> already knows its identity, so stamping the serve instance into the row at
> creation dissolves the whole problem, covers kernel OOM and pigeon-originated
> turns alike, and degrades to today's gate for unstamped rows. **If S2 forces a
> build, build the stamp.**

**Corrected evidence — the first measurement was wrong.** An earlier pass claimed
"2 weeks of journal, one single-member restart". This box's journal only reaches
back to **2026-07-30** (4.8 days); `--since 2026-07-20` returned a *result* that
was reported as a *window*. Same assert-instead-of-measure error as the S2 start
time and the S1 scope mix — third instance in this spine. Corrected: **two**
deferral-triggering events in the visible window, both on 08-01 — the
17:45–17:46 restart of 4096/4097/4098 **without 4099** (a 3-of-4 partial defers
identically, since `min` does not move) and the 19:10 canary kill.

**Measured harm is what justifies waiting.** Across all 387 sweeper runs the
finalize history is 297 (first run, unbounded historical backlog) → **7** → **1**.
Right now: 11 phantom rows, 0 stale, 0 deferred. The honest defense is not
"attribution is impossible" — it is *harm measured at 7-and-1 rows does not yet
buy even a small patch*.

**Pre-committed decision rule**, set before the data so "wait for S2" cannot decay
into "never": if the S2 window records **≥1 kernel OOM kill** of a pool serve,
build the provenance stamp; if it records zero, close `63wo` as wontfix. Wake
scheduled 2026-08-10.

**Assumption named so it can be invalidated:** "the 03:00 bounce is an adequate
backstop" holds *only while a nightly whole-pool restart exists*. This spine's own
direction makes single-member restarts a larger share of all restarts and could
eventually remove that bounce, at which point the deferral becomes unbounded.
**Reopen if the reset cadence changes.**

**Open verify before any close:** confirm a phantom row is purely *cosmetic* on
the restarted serve. Believed so (queueing is in-process) but unverified; if a
phantom row blocks new turns, harm jumps to session-unusable-until-03:00 and this
calculus changes.

#### Found in passing — `workstation-rdsq.2` · **CLOSED: education, not tooling**

**The sweeper did not run at all for 13 hours** (08-01 21:25 → 08-02 10:25). A
`nixos-rebuild switch` from `/tmp/wsdeploy` — a stale scratch checkout — silently
removed the timer **57 minutes after it landed**. It was the *only* unit stopped
in that switch and nothing restarted it, which is the signature of a unit absent
from the new generation rather than a restart failure. Several sessions deploy
this host from different worktrees; any deploy from a checkout lacking a peer's
just-landed change reverts it, with no error and no alert.

**Disposition:** no guard will be built. A deploy applies the *whole* config the
deploying checkout contains, so no tool can distinguish "intentionally removed a
unit" from "accidentally missing a peer's unit" from the diff alone. Shipped
instead as a convention in `.opencode/skills/rebuilding/SKILL.md` — deploy from
`~/projects/workstation`, never a worktree or scratch dir — carrying this
incident as the cost and the *`Stopped` with no matching `Started`* signature as
the diagnostic.

### S5 — Record the wedge-attribution method · `workstation-yvxh.6` · P3

**Do not run the correlation.** It has zero usable data points: the only
forensics dump (`wedge-20260801T191003-4098`, 19:10:18) predates the sweeper's
first run on this host (20:32:12) by 82 minutes. It is also retrospective on two
mechanisms since removed — the throttle band and the sweeper's write lock.
Record the door-log-join method instead. W1's effect must be measured
**prospectively** (wedges after 2026-08-03 12:07); there is no before-sample.

**Landed 2026-08-03 — main-thread wait-channel time series in the canary dump.**
A peer session (W2a) established that `bun:sqlite`'s busy-wait runs on the serve's
**main JS thread**, so `busy_timeout=5000` means a contended write freezes the
event loop for up to 5 s — not a cousin of the "alive but frozen" wedge
signature but a mechanism that produces it exactly.

The canary already dumped `/proc/PID/wchan` and per-thread wchan, but only as a
**single snapshot**, which cannot discriminate — sampling a *healthy* serve by
hand returns `0` or `do_epoll_wait` depending purely on when you look. The
discriminator is whether the loop ever returns to epoll across a window:

| main-thread wchan across ~2 s | reading |
|---|---|
| `do_epoll_wait` | loop free — an HTTP stall is request serialization, **not** a blocked loop |
| `hrtimer_nanosleep`, never returning to epoll | SQLite busy handler spinning |

So the dump now samples the main thread 20× at 100 ms into `wchan-series`,
inside the 2 s window `cpu-io-split` was already sleeping through — **zero added
wedge-time**. `/proc/<tid>/syscall` would be richer but yama `ptrace_scope=1` on
this host makes it unreadable; `wchan` is readable.

Two incidental fixes made in the same edit, both in this spine's own spirit:
`interval=2s` was **asserted** in the output and is now **measured** (it is
really ~2.11 s, and the utime/stime delta is divided by it); and the sampler
uses a plain shell counter rather than `seq`, because `lbe2` was a silent no-op
caused by exactly one assumed-present binary.

Deployed and verified **against the built artifact** (`systemctl cat` →
`ExecStart` → grep the store path), not against the Nix source. `nixos-rebuild`
rebuilt only the canary derivation; serve pool `NRestarts=0`, all four still
active.

### S6 — Fix the metric that caused all this · `workstation-29k3` · **DONE**

Two halves, because the lying name and the lying instrument live in different
repos.

**pigeon — [PR #56](https://github.com/johnnymo87/pigeon/pull/56), merged
`04401f5`.** The TS field is now `AssignmentRecord.lastPlacedAt`. `Router.touch()`
and `RouteRepo.touchActive()` are deleted as dead code, following the
`countActiveForServe` precedent from `pigeon-76k`.

**The SQL column keeps its wrong name on purpose**, and this is the part worth
remembering: `ROUTING_DDL` is sha256'd into `routing_meta.ddl_checksum`, and every
serve validates that digest against a constant compiled into `opencode-patched`.
Renaming the column — or editing *any byte* of that string, including adding a SQL
comment inside it — forks the digest and **crash-loops the entire serve pool**
until a lockstep serve release ships. The explanation therefore lives in a TS
comment *above* the string. Verified byte-identical across `origin/main`, the
branch, the live DB, and the serve's compiled constant (`e5c8e409…`).

`renewCAS` was deliberately **not** followed down the dead-code thread. It has no
TS caller, but renewal is emphatically not dead — the serve writes this same
SQLite file directly. Deleting it would silently break out-of-process renewal and
no TypeScript test would notice.

**sampler — `/home/dev/s3-sampling/sample.sh`, rotated to `samples-v3.tsv`.**
`assign_active_1h` / `assign_active_10m` are **gone**, replaced by `lease_live`:
sessions holding an unexpired lease at the current binary epoch, which is what
pigeon's own load measure counts (`countLiveForServe`). The epoch fence matters —
after a restart bumps the epoch, the previous process's leases survive up to one
TTL and would inflate the count exactly during the restart window we care about.

`lease_live` is an instantaneous gauge, not a window: it means "turns in flight
right now" and will miss turns shorter than the 15s tick. Fine for memory
attribution, useless as a request rate — the routing DB cannot give you one.

#### Consequences for S2, which is mid-window

**The S2 series now spans three files** (it already spanned two):

| file | cols | covers |
|---|---|---|
| `samples.tsv` | 22 | 2026-08-02 01:34Z → 08-03 19:27Z |
| `samples-v2.tsv` | 23 | 08-03 19:27Z → 08-04 00:08Z |
| `samples-v3.tsv` | 22 | 08-04 00:08Z → |

The memory columns are named identically across all three, so a **header-name**
read concatenates cleanly. **`v1` and `v3` have the same column count and
different meanings** — a positional read across them yields plausible, wrong
numbers, which has already happened once across v1/v2 and produced a bogus 13.29 G
peak.

#### Found in passing — the instrument is more fragile than assumed

`s3-sampler.timer` and `child-capture.timer` are **transient** `systemd --user`
units (created via `systemd-run`, living in `/run/user/1000/systemd/transient`).
They are on tmpfs and are **not** recreated on reboot or user-manager restart. S2
depends on this series running unbroken until 08-09; if it has a hole, check the
timer exists before theorising about the serves.

Worse, the obvious check silently lies: `systemctl --user list-timers` from an
opencode bash call reports **nothing at all** because `XDG_RUNTIME_DIR` is unset,
which reads exactly like "the timer is gone". It cost a detour here. Use:

```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers
```

## Deliberately NOT doing

- **The opencode.db vacuum.** `workstation-yvxh.4` owns it and owns the `mv`.
  Two sessions swapping that file in one window means whichever swaps second
  silently discards the other's writes.
- **A reproduction harness or heap profiler for S1 before the cheap test.**
- **Anything about `workstation-nv5l`** (the second wedge class, 979 session-path
  503s at 10:47 on 08-01). Still unexplained, still not claimed here.
