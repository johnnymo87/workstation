# Cloudbox serve memory — attribute the burst, land the residuals

**Spine bead:** `workstation-rdsq` · **Started:** 2026-08-03 · **Host:** cloudbox only

**Predecessor:** `docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md`
(spine `workstation-7za8`). Steps 0–3 deployed; step 4 handed to
`workstation-yvxh.4`. That roadmap fixed the **consequence** of the memory
bursts. This one is about the **cause**, plus the residuals it left open.

**Status:** S0 done · S1 done · S4 worked (fix **rejected**, deferred to S2) ·
S6 done (pigeon PR #56 + sampler v3) · **nothing unblocked; every remaining step
is time- or peer-gated**

- **S2** is time-blocked: 7-day window ends **2026-08-09 22:37 Z**. It is **no
  longer a zero-event window** — the first kernel **OOM kill landed 2026-08-03
  21:56:21 Z** on `:4098` (details below). Still do not report early; one kill is
  an event, not a verdict.
- **S3** (`le0a`) is gated on a peer's `workstation-yvxh.4`; wake set 08-10.
- **S4** (`63wo`) is worked, fix rejected — and its **pre-committed trigger has now
  fired** (the 21:56 Z kill), so the 08-10 wake is an execution trigger, not a
  decision: build the provenance stamp. The per-owner gate it originally proposed
  remains rejected as unsound; measured harm was 7-and-1 rows.
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

### Reading the memory series — three traps that have each already caught someone

These live here rather than in a transcript because all three produced a wrong answer
at least once during this spine, and each is invisible to someone who just opens the
files.

**1. Parse BY HEADER NAME. Never by column position.** The series is spread over files
with different shapes, and two of them share a column count while differing in meaning:

| file | columns | note |
|---|---|---|
| `samples.tsv` | 22 | v1 |
| `samples-v2.tsv` | 23 | `main_swap_kb` **inserted at position 8**, shifting everything after it |
| `samples-v3.tsv` | 22 | same count as v1, **different meaning** — `lease_live` replaced `assign_active_*` |
| `~/metrics/pressure-v1-*.tsv` | 17 | separate instrument (PSI), long format |
| `~/metrics/pressure-v2-*.tsv` | 22 | adds `kernel`/`slab`/`pagetables`/`shmem` |

A positional parser silently reads the wrong column on v2 and *looks fine* on v1 vs v3.
The schema version is in the pressure files' names for exactly this reason.

**2. Judge demand on `anon` + `swap`. Never on `memory.current`.** `memory.current`
includes reclaimable page cache, and on this box the gap is enormous, not marginal: in
the 7-day window `memory.current` touched the 14 G cap on **eight member-days** where
`anon+swap` was 6–9 G lower. A report counting cap-touches would have overstated
roughly fourfold. Concretely, `:4098` at 14.00 G on 08-06 was `anon` 1.40 G with `file`
6.82 G and `oom_kill=0` — the cgroup filling its allowance with cache, not dying.
The inverse also occurs (`:4099` was once 90% anon), so the ratio must be *read*, never
assumed in either direction.

**3. Counters are per cgroup INSTANCE, and slice counters are lifetime.**
`memory.peak`, `memory.events` and PSI totals all reset when a cgroup is destroyed and
recreated — which happens on every serve restart and every nightly reset. Two failures
follow, both observed:

- **A peak can be erased.** `:4098` reached exactly 14.00 G at 2026-08-06 15:18:13Z; by
  19:41Z its live `memory.peak` read 2.81 G because the serve had restarted. Only the
  sampled series retained the event. **Never build a peak claim from a cgroup file read
  at report time** — read it from the series.
- **A slice reports its dead children's history.** The serve slice read
  `peak=42.14 G, oom_kill=4` while all four live leaves read `0`, on a box up 86 days.
  Those kills were from cgroups destroyed days earlier. Sizing an aggregate cap from
  that number would be sizing against a regime that no longer exists. `pressure-sampler`
  records `memory.events.local` alongside the hierarchical counter precisely so the two
  can be separated.

**Window boundary:** the S2 regime starts **2026-08-02 22:37:12Z** — when the kernel
got the limits, not when the config shipped (deploy was 18:57Z; the live cgroup did not
change until 22:37:12Z, visible as `mem_high` going `7516192768 → max` with the pid
unchanged). The **28.50 G episode of 08-02 19:52–20:05 is pre-regime** and must not
appear in any post-fix table — `mem_high` was still 7 G, so it compares across the very
change being measured.

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

### S2 — The 7-day report on the memory posture · `workstation-h1y6` · **CLOSED 2026-08-09 — OUTCOME 2**

Wakes fire **2026-08-09 23:00 UTC** (primary) and **2026-08-10 00:30 UTC**
(backstop), moved 2026-08-03 from 14:00/15:30: the window starts when the kernel
got the limits (22:37:12 Z), not when the config shipped (18:57 Z), so the
original times fired **8.6 h before the 7 days were up**. Report as one of the
four outcomes with the pre-declared cap-adjustment rule; the criteria live in the
predecessor roadmap's step 2 and must not be improvised.

**FIRST KILL: 2026-08-03 21:56:21 Z, `:4098`.** Found incidentally during S6, ~45
minutes after the "interim state" paragraph below was written.

```
21:56:21Z opencode-serve@4098.service: A process of this unit has been killed by the OOM killer.
21:56:24Z opencode-serve@4098.service: Main process exited, code=killed, status=9/KILL
21:56:24Z opencode-serve@4098.service: Failed with result 'oom-kill'.
21:56:24Z ... Consumed 3h 26min CPU, 14G memory peak, 1G memory swap peak
21:56:34Z opencode-serve@4098.service: Scheduled restart job, restart counter is at 1.
```

Peak was **exactly `MemoryMax`=14 G and `MemorySwapMax`=1 G**, and the unit was
back up **13 s later**. That is the max-only regime doing what it was designed to
do — terminate rather than swap-thrash — as against the pre-regime episode that
pinned at `MemoryHigh`=7 G and dragged swap to 22.43 G for 13 minutes. It is
**one event, not the verdict**; S2 still reports at the window's end.

> #### The detector that said "zero" cannot see this, and never could
>
> **`memory.events oom_kill` resets when the cgroup is recreated.** Right now it
> reads `oom_kill 0` for `:4098` — *after* the kill — because the restart made a
> new cgroup. `NRestarts` is no better: `systemctl reset-failed` clears it, and it
> counts restarts of any cause, not kills.
>
> **The journal is the only durable record.** Use it, and measure its reach rather
> than assuming it (`journalctl -o short-iso | head -1` → currently 2026-07-30,
> about 5 days, 2.1 G cap):
>
> ```bash
> for p in 4096 4097 4098 4099; do
>   journalctl -u opencode-serve@$p --no-pager -o short-iso |
>     grep -iE 'oom-kill|OOM killer'
> done
> ```
>
> Every earlier "zero OOM kills" claim in this doc was produced by the resetting
> instrument and is **not evidence of a quiet window** — it is evidence that
> nothing had restarted recently enough to be counted. Over the journal's full
> reach there is exactly **one** kill (this one) and one unrelated `:4098` restart
> at 2026-08-01 18:11 with no OOM lines.

**Interim state as of 2026-08-03 21:10 Z (0.94 d elapsed) — superseded by the
above, kept for the trend:** post-regime peak `anon+swap` of 8.51 / 4.92 / 6.56 /
8.01 G against the 14 G cap.

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


#### The 7-day report — **OUTCOME 2, closed 2026-08-09**

Window `2026-08-02 22:37:12Z .. 2026-08-09 22:37Z`, reported against the four
pre-declared outcomes in step 2 of the predecessor roadmap. Criteria not improvised.

**Outcome 2 — a member was killed at the cap.** Not outcome 3. Six kill events
occurred, so the kill path is *tested*, and the mechanism behaved as designed every
time: a matching `journalctl -k` memcg-OOM entry, a systemd restart, the member back
in seconds. But the fix is confirmed only narrowly — see the adjustment rule below.

**(1) Daily max demand (`anon`+`swap`) per member.** 151,372 in-window samples,
parsed by header name across `samples.tsv` (22 col) / `-v2` (23) / `-v3` (22).
`memory.current` is shown only for contrast and is never the criterion.

| day | :4096 dem/cur | :4097 dem/cur | :4098 dem/cur | :4099 dem/cur |
|---|---|---|---|---|
| 08-02 | 2.75 / 4.76 | 0.10 / 0.11 | 0.09 / 0.11 | 0.55 / 0.55 |
| 08-03 | 8.51 / 14.00 | 5.20 / 6.69 | 10.49 / 14.00 | 8.80 / 14.00 |
| 08-04 | 9.03 / 14.00 | 4.80 / 5.44 | **13.79** / 14.00 | 11.33 / 14.00 |
| 08-05 | 8.36 / 14.00 | 8.11 / 11.80 | 7.48 / 13.76 | 4.27 / 10.09 |
| 08-06 | 6.30 / 8.05 | 5.58 / 13.95 | 7.23 / 14.00 | 5.93 / 7.92 |
| 08-07 | 3.28 / 4.68 | 2.61 / 5.16 | 2.47 / 3.66 | 3.77 / 6.58 |
| 08-08 | 3.09 / 5.15 | 4.20 / 9.89 | 2.96 / 3.78 | 2.66 / 8.49 |
| 08-09 | 2.49 / 3.49 | **13.00** / 14.00 | 2.83 / 7.08 | 2.12 / 8.15 |

Bold = demand within 1 G of the cap; those two member-days are exactly the kill days.
This confirms the pre-declared warning in the sharpest possible way: `memory.current`
touches 14.00 G on **eight** member-days where demand is 6–9 G lower. A report counting
cap-touches on `memory.current` would have overstated the problem roughly fourfold.

**(2) The kills.** All six carry a memcg-OOM line and a restart (08-09 16:52:24Z kill →
restart scheduled +12 s, new process resident at +21 s). On *health restored within
60 s* the evidence is partial and is recorded as such: the canary's first post-kill
probe was at **+102 s** and passed — it restarts wedged serves and restarted nothing —
so there is no affirmative probe inside the 60 s window. Consistent with the criterion,
not a demonstration of it.

**(4) Kill frequency pool-wide:** 08-03 → 1, 08-04 → 3, 08-05…08-08 → 0, 08-09 → 2
events. Peak **3/day**, below the pre-declared `> 5/day` threshold, so the
raise-the-cap-for-churn rule does not fire.

**(5) Orphaned phantom rows, tagged by kill-adjacency.** Counted with the sweeper's
`--dry-run` (no write lock). It runs every 5 minutes — 2022 runs in window, 13 non-zero.
The sweep *immediately after every kill* finalized **0**, because its cutoff is the
oldest active serve start, so a kill's orphans only become candidates once that cutoff
advances at the nightly restart. Reading that 0 as "kills cost nothing" would be wrong.

| sweep (EDT) | orphans | kills since previous sweep | tag |
|---|---|---|---|
| 08-04 03:05 | **15** | four (08-03 17:56…23:25) | kill-adjacent |
| 08-06 14:25 | **12** | none | **no kill** |
| 08-06 03:05 / 13:55 | 3 / 2 | none | **no kill** |
| 08-05 03:05, 05:30; 08-06 09:05, 09:35; 08-07 03:05; 08-08 03:05, 03:40 | 1 each | none | **no kill** |
| 08-09 03:05 | 1 | one (08-08 20:36) | kill-adjacent |

**16 kill-adjacent, 24 with no kill nearby.** N is not zero, and the majority are *not*
from kills — direct evidence for the peer's SQLite lock-contention path. Lumping them
together would have both overstated the cap's cost and hidden that separate defect. The
14 orphans of 08-06 13:55+14:25 follow the 13:54 EDT **scheduled** restart in which
`:4097` exited non-zero — a non-OOM event. Per-kill cost is highly variable: ~14 excess
over baseline for the four 08-03/04 kills (~3.5 each) but ~0 excess for the 08-08 kill,
so orphan production tracks whether sessions were **mid-turn**, not the kill itself.

#### The adjustment rule is not applied, because its premise is violated

The rule branches on whether the killed episode was door-clean up to death (⇒ cap too
low, raise to 16 G) or already degraded (⇒ confirmed, leave it). Both branches assume
the demand approaching the cap is **opencode's**. In all six kills it was not:

- the four 08-03/04 kills of `:4098` were **bazel** (7.61 G of a 9.04 G cgroup, 35 s pre-kill)
- the two 08-09 kills of `:4097` were **vitest** (`task=node (vitest 8)`, `(vitest 2)`)

opencode's own steady demand across the whole window is 2.5–9 G; the cap is approached
only during foreign bursts. And both `:4097` ramps were near-vertical.

> **Ramp figures re-derived 2026-08-11 — the originals were wrong, and this
> document had already warned why.** The numbers first recorded here (anon
> 2.51 → 13.29 G in 33 s, page cache 4.06 → 0.01 G, swap saturated) came from a
> positional read across sampler schema versions — the exact hazard the "Reading
> the sampler" section below documents, which names 13.29 G as its known-bogus
> output. A peer (pigeon-80gy) could not reproduce the ramp and flagged it, which
> is what prompted the recheck. Re-read **by header name** from `samples-v3.tsv`:
>
> | | recorded | measured |
> |---|---|---|
> | anon ramp | 2.51 → 13.29 G in 33 s | **1.61 → 13.00 G in 48 s** |
> | page cache | 4.06 → 0.01 G | **9.10 → 0.39 G** |
> | swap | "saturated" | **0.00 G throughout — it never moved** |
>
> The phenomenon is **real and survives**: `:4097` anon went 1.61 → 9.41 → 13.00 G
> across 12:51:27–12:52:15 on 08-09 while page cache was reclaimed out from under
> it, and the slot was dead by 12:52:47 (anon 0.29 G, threads 62 → 22). Only the
> digits were wrong. The "swap saturated" clause was wrong outright, and mattered:
> there was no swap thrash before this kill.
>
> **It was one slot, not the box.** At the peak second `:4097` held 13.00 G while
> `:4096`/`:4098`/`:4099` held 1.41/1.18/1.09 G. That is evidence against
> box-wide multi-tenant contention as the explanation, and for something local to
> that cgroup.

So a 16 G cap buys seconds, not minutes, before an identical kill.

**Recommendation: do not raise the cap.** Fix the class instead: `workstation-mqp3`
moved *bazel* out of the serve cgroup and that held, but the defect was never
bazel-specific — the agent's bash tool spawns work as children of `opencode serve`, so
whatever it runs next is charged there. Filed as `workstation-yt0p`. This also blocks
`workstation-8rou`: shrinking 14 G → 10 G while foreign workloads can still land in the
cgroup would make these kills *more* frequent, not less.

The 28.50 G episode of 08-02 19:52–20:05 is pre-regime (`mem_high` was still 7 G) and
appears nowhere above; the series starts at 22:37:12Z.

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

### S4 — Bound the cost of a kill · `workstation-63wo` · **RULE FIRED 2026-08-10 → BUILD**

> **2026-08-10, the pre-committed rule was executed.** S4's decision rule (set on
> 08-03, *before* the data existed, so it could not be rationalised afterwards)
> asked one question: did the S2 window record ≥1 kernel OOM kill of a pool serve?
> It did — `h1y6` recorded **six**, memcg-OOM logged each time, and an independent
> journal check over the *measured* window (`2026-08-02T18:22:44-04:00` → now,
> ~7.8 d visible) shows `Memory cgroup out of memory` naming both
> `opencode-serve@4097` and `@4098`. So: **build the write-time provenance stamp**
> (section 3 of the bead notes). Not the per-owner routing gate (unsound), not the
> kill-time capture (struck).
>
> **New constraint, measured the same day, and it resizes the job:** the stamp
> cannot be done from a plugin. `@opencode-ai/plugin`'s `chat.message` hook exposes
> only `message: UserMessage`; nothing mutates the *assistant* row at creation. It
> therefore needs a patch in the `opencode-patched` fork, a release, and a hash
> bump — cross-repo, not a one-file edit. Section 3's door-log alternative was
> rejected *on cost, not soundness*, back when the stamp was assumed cheap; that
> comparison deserves re-reading with the true costs before anyone starts.
>
> **`yt0p` (shipped 08-10) does not unfire this**, and is not the main
> justification anyway: `h1y6` measured 40 orphaned rows of which **24 had no kill
> nearby**, so most phantom rows come from something other than OOM kills, and the
> stamp covers all of them.
>
> **Section 9 is still unverified** — is a phantom row cosmetic, or does it *block*
> new turns? Two attempts failed (written up in the bead). It gates a *close*, not
> this build; but if phantom rows block turns, this stops being tidiness and
> becomes session-availability.

> **2026-08-10, later: the door-log comparison was re-run, and the bead's stated
> reason for rejecting it is WRONG.** The bead says "rejected on COST, not
> soundness. Say cost, not soundness." Measured: cost is a non-issue — a full 24 h
> door scan is 344,267 lines in **689 ms**, and filtered to POSTs it is 209 lines
> in 1.1 s, on runs that have candidates at all (rare). What actually disqualifies
> it is **coverage**: over 24 h, 166 sessions produced 8,054 assistant rows and the
> door saw a turn-start for only **75** of them. **91 sessions / 3,558 rows (44%)
> are invisible to it** — 60 are subagent *child* sessions (created in-process,
> they never traverse the door) and 31 are root sessions pigeon injected directly.
> That is a ceiling, not a price. Reject the door on **coverage**; do not cite the
> cost sentence.

> **Write side BUILT and reviewed, 2026-08-10 — `opencode-patched` PR #40.**
> Stamps `{serveId, invocationId, port, pid}` onto assistant rows in
> `messageData()`, the single upsert path for creation *and* every later update, so
> it covers every assistant row the sweeper can sweep and always names the **last
> writer** (which is what the sweeper needs: a writer is alive when it writes, so a
> stamp naming a dead invocation proves nothing has touched the row since). Keyed
> on systemd's `INVOCATION_ID` — *not* pid (the unit's MainPID is a wrapper script,
> so `process.pid != MainPID`) and *not* a start timestamp (`Date.now()` never
> equals `ActiveEnterTimestamp`); either comparison would judge **live** rows dead.
>
> **The review found a blocker, and it is the lesson worth keeping.** The gate
> originally required `OPENCODE_SERVE_ID` + `INVOCATION_ID` — both *environment
> variables*, which establish **ancestry** ("descended from a serve") when the
> stamp needs **fate-sharing** ("dies with that serve"). `yt0p`, shipped *hours
> earlier the same day*, is what split those populations: every agent tool
> subprocess now runs in its own scope under `oc-agent.slice`, so it **outlives a
> serve restart** while inheriting the serve's whole environment. Measured on a
> live tool call: `OPENCODE_SERVE_ID=serve-3` with the *scope's*
> `INVOCATION_ID=21efa50c…` while its serve was `8b8f626a…`. Any `opencode run`
> from there would have stamped an invocation the sweeper can never find — one that
> always looks dead — onto rows that are alive, and the sweeper would have aborted
> a **running turn**. Today's min-cutoff gate handles that case *correctly*, so v1
> was not "strictly additive"; it would have made a real case worse. The gate now
> also requires `/proc/self/cgroup` to name `opencode-serve@<port>.service`: with
> `KillMode=control-group`, "invocation dead ⇒ writer dead" then holds by systemd
> *mechanics* rather than env hygiene.
>
> Generalise it: **an env var tells you what a process descended from, never what
> it will die with.** And a change landed the same day can invalidate the
> assumption the next change is about to rest on.
>
> Also fixed: the gate-fail branch now *strips* a foreign stamp (the field is
> declared, so it survives decode/re-publish, and carrying it forward would break
> the last-writer invariant). Replay was checked, not assumed — projector handlers
> run only inside the transaction that first persists an event, and the replay path
> dedupes at `event.ts:282`, so no re-stamping of dead rows.
>
> **Write side SHIPPED AND VERIFIED IN PRODUCTION, 2026-08-11.** Fork PR #40 merged,
> release `v1.17.13-patched.9`, hashes bumped (`749cf17`), and the 03:00 bounce
> carried it — all four serves came up on `.9` at 03:01. Every cell of the matrix
> measured: pool rows stamped with invocations matching their units **4/4**;
> **child/subagent sessions stamped** (the claim that justified the projector choke
> point, previously argued but never observed); a non-pool `opencode run` correctly
> **unstamped**; and a clean split at the deploy boundary — 8,905 rows before
> unstamped, 126 after stamped, zero leakage either way.
>
> That leak test is F1 reproduced live and then defeated: the standalone process
> carried **all three** env gate inputs (`serve-3`, port `4099`, an
> `INVOCATION_ID` matching no unit) and still wrote an unstamped row, because it
> failed the cgroup check. An env-only gate would have aborted a running turn.
>
> **Read side, phase 1 (reporting only) — PR #343.** The sweeper collects each
> active unit's `InvocationID` and logs how many rows the stamped gate *would*
> finalize. It finalizes nothing new. 46 assertions (was 29), non-vacuous by four
> mutations. Review verified against the running host that inactive/activating/
> failed/stray instances report an empty `InvocationID` and are filtered before the
> new fatal path, and measured the extra query at 1.9 s `mode=ro`, no write lock.
>
> **The earlier advice in this section was wrong and is retracted.** Keeping
> `time.created < CUTOFF` as a floor for stamped-dead rows does not "cap the blast
> radius" — it defeats the feature entirely, since the whole point is rows *newer*
> than CUTOFF. Worse, the disjunctive form it implies (`old OR stamp-dead`) would
> finalize a row whose stamp says its writer is **alive** whenever that row also
> predates CUTOFF — reachable through clock skew between the serve's `Date.now()`
> and systemd's epoch, or through a restored DB. The correct gate is:
>
> ```
> stale AND ( (NOT stamped AND created < CUTOFF)
>             OR (stamped AND invocation not live) )
> ```
>
> For a stamped row the stamp is the stronger evidence in both directions, so CUTOFF
> should govern only rows without one. The real blast-radius cap is the 30-minute
> silence requirement, which is kept. The shadow count is identical under either
> formulation, so the number being collected now validates the corrected shape.
>
> **Before the gate gets teeth:** the phase-2 UPDATE re-check must gain the stamped
> predicate (it is the race protection and currently re-checks only the old gate),
> and arming requires *evidence*, not just quiet — no `shadow: FAILED` lines across
> the window **and** at least one nonzero observation, manufactured by killing a
> member if traffic won't produce one. Zeros alone validate nothing.
>
> **Read side, phase 2 (ARMED) — PR #358, 2026-08-12.** Both conditions were met:
> zero `FAILED` across ~58 runs, and a deliberate SIGKILL of a single member
> produced the predicted `0 -> 1` transition in the exact 5-minute window. The gate
> shipped in the corrected conjunctive shape above, built once and interpolated into
> **both** phases. 60 assertions (was 46); 13 fail against pre-arming, 3 more
> against pre-hardening.
>
> Three things worth carrying forward:
>
> **The conjunctive form fixed a hazard that already existed.** `T8j` — a
> live-stamped row older than CUTOFF — fails against the *pre-change* sweeper,
> because the old CUTOFF-only gate is literally the first disjunct. This was not
> merely a wrong shape avoided; the old gate would abort that live turn today.
>
> **Rigor was on the wrong side (found by adversarial review, fixed pre-deploy).**
> The gate validated the *live* ids to 32 lowercase hex but trusted the *row's*
> stamp absolutely, so any unrecognisable value — empty string, dashed UUID,
> uppercase — matched nothing live and read as proof of death. The unhardened build
> finalizes 4 of 5 malformed-stamp fixtures whose writers are alive. This matters
> because the stamp is a **cross-repo contract** produced by opencode-patched, which
> auto-updates every 8 hours: a version rendering the id differently would make every
> live row stop matching at once. The gate now requires a well-formed stamp before
> treating it as evidence of death, and malformed ones fall back to the CUTOFF rule
> rather than being stranded unsweepable. Generalise it: validate the input you do
> **not** control, not the one you do.
>
> **A silent dependency, now commented.** The monotonic-death argument that lets
> phase 2 reuse the discovery-time snapshot holds only because `Type=simple` and
> `TimeoutStopSec=15` keep the running-but-not-`active` window far below the
> 30-minute silence gate. Nothing linked those sites; the serve template now says so.
>
> **Monitoring break:** the log line is now `stamped-gate ARMED: N row(s)`, not
> `stamped-gate shadow: N additional`. Anything grepping the old string reads zero
> forever. Renamed deliberately in the same change — a line saying "would be
> finalized" while rows are being finalized is an instrument that lies.
>
> First armed sweep finalized exactly the one known orphan (dead stamp, 65 min
> silent) and left six live turns across four sessions untouched.

> **Trap, cost one confused minute on 08-10.** S4's load-bearing assumption is
> "a nightly whole-pool bounce still exists". It does — but the unit is
> **`nightly-restart-background.timer`**, a *system* timer, **not** named
> `reset-workspace`. `systemctl --user list-timers | grep reset` returns nothing
> and looks exactly like the backstop was removed. Check
> `systemctl list-timers | grep nightly-restart` instead.

### S4 (original, 2026-08-03) — **FIX REJECTED, DEFERRED TO S2**

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

> **THE TRIGGER HAS FIRED.** `:4098` was OOM-killed at **2026-08-03 21:56:21 Z**,
> inside the window (see S2). The condition is `≥1` and the count is monotonic, so
> the outcome is already settled: **build the write-time provenance stamp.** The
> 08-10 wake is now an execution trigger, not a decision point — and it must not
> re-derive the count from `memory.events oom_kill`, which reads 0 for `:4098`
> *after* the kill because the cgroup was recreated. Read the journal.
>
> Honouring this is the entire point of pre-committing: the rule was written when
> zero kills looked likely, and it would be trivially easy to now discover reasons
> why one kill "doesn't really count".

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

### S7 — Reap idle instances in serve mode · `workstation-rdsq.1` · **DESIGNED 2026-08-04, NOT YET BUILT**

Worked against upstream **v1.17.13** (`10c894bdee`) in `/home/dev/projects/opencode`,
which is the exact version the pool runs as `opencode-patched-1.17.13.7`. Newer tags
exist (v1.17.15..v1.17.19); they are the wrong tree for this.

#### The defect

`opencode serve` is long-lived and serves many directories; each is an "Instance".
`InstanceStore`'s cache is `new Map<string, Entry>()` (`instance-store.ts:43`) —
**unbounded, no TTL, no LRU, no timestamps**; `Entry` holds only a `Deferred`. Disposal
exists but **in serve mode nothing ever calls it for an idle directory**. Every caller
is something else: CLI one-shot exit (`cli/effect-cmd.ts:88`), worktree removal
(`worktree/index.ts:397,417`), the explicit HTTP lifecycle endpoints, and
config-change/shutdown `disposeAll` (`instance-store.ts:192`).

So one directory routed once pins its child fleet for the life of the process.

The teardown plumbing is already complete and correct — this is worth knowing before
anyone tries to build it: `disposeContext` → `runDisposers` (`instance-registry.ts`)
→ `ScopedCache.invalidate` → scope close → finalizer → MCP `SIGTERM`s client **and
descendants** (`mcp/index.ts:523+`), LSP `client.shutdown()` (`lsp.ts:198-202`).
**Nothing needs to be built to kill the children. Only the decision to call it.**

#### Two corrections to S1's numbers — read before tuning anything

**S1's headline equation does not add and its metrics are not addable.** The note
read `cgroup anon 6.55G = main 1.88G + 44 children 6.31G`; 1.88 + 6.31 = 8.19.
Recomputed from `child-capture.tsv` at 19:32:56Z on `:4098`:

| quantity | value |
|---|---|
| `cg_anon` (cgroup anonymous charge) | **6.551 G** |
| sum of per-process RSS | **8.182 G** |
| main RSS / children RSS | 1.875 G / 6.306 G |

Sum-of-RSS exceeds cgroup anon because RSS counts file-backed pages (which are not
anon) and **double-counts shared/COW pages** across parent and children. You may not
add per-process RSS and compare the total to `cg_anon`. What survives, stated as RSS
ratios: children are **77.1%** of total RSS and **3.36x** the main process.

**That capture is also unrepresentative, and it misdirected the fix.** Classifying all
28 captures by cmdline, share of summed RSS:

| class | share |
|---|---|
| MAIN (opencode itself) | 32.7% |
| **BAZEL/JVM** | **32.6%** |
| LSP: tsserver | 12.9% |
| MCP | 12.0% |
| node-misc | 4.2% |
| LSP: other | 3.8% |

LSP+MCP — everything an instance eviction can reclaim — is **~29%**, not the dominant
term. In the 19:32 capture LSP happened to be 49% of children, which is the only
reason the original note reads as an LSP story. Two consequences, both filed:
`workstation-mqp3` (bazel/JVM in the serve cgroup, ~33%, **not evictable by this fix**)
and `workstation-0svg` (the main process alone holds 1.5–2.8G and climbs).

**S7 is therefore not "the root cause of the OOM".** It reclaims a standing floor.
`:4098` was 5.43G at 21:51:34Z and was killed at 21:56:21Z at 14G+1G — ~9.5G in under
five minutes, which no term in the floor moves fast enough to explain. The floor
removes headroom; something else does the killing. The instrument cannot see it
(`workstation-lwde`).

#### The design

Split mechanism from policy. **Mechanism** in `instance-store.ts` (~40 lines,
additive): `Entry` gains `lastAccess` and `evicting?: Deferred`; `load()`'s hot path
adds one synchronous property write and one branch (if evicting, await the deferred
then **retry the lookup**); new `tryEvict(dir, guard)` marks synchronously, runs the
guard, then disposes through the existing `disposeEntry`; new `snapshot()`.
**Policy** in a new serve-only file composed only by the httpapi server, so CLI and
TUI behaviour is byte-identical: a 60s fiber evicting entries idle past a TTL whose
guard passes.

**Why eviction works at all despite every directory having an attached TUI** — this is
not obvious and nearly sank the design. Disposal emits `server.instance.disposed`
(`instance-store.ts:97`); the SSE stream self-terminates on it (`handlers/event.ts:61`,
`Stream.takeUntil`) and the TUI **immediately re-bootstraps**
(`packages/tui/src/context/sync.tsx:172-173`). On cloudbox every hosted directory has
a TUI attached, so eviction is followed by re-boot within seconds. That is acceptable
only because the expensive children do **not** come back: `InstanceBootstrap`'s deps
are Config/Format/LSP/Plugin/Project/ShareNext/Snapshot/Vcs (`bootstrap.ts:55`) —
**MCP is absent entirely**, and `LSP.init()` (`lsp.ts:309-311`) only materialises
config; language servers spawn lazily per file. A reaper cycle costs a JS re-bootstrap
and reclaims the child RSS. Verify churn in canary before trusting it.

#### Six defects found in adversarial review — all must be in the spec before coding

1. **Counter ordering.** The in-flight counter must be acquired **before**
   `store.load()`, keyed by `FSUtil.resolve(decode(route.directory))` — the same
   normalisation as `instance-store.ts:109`. Acquiring after `load` leaves a window
   where a fiber holds a ctx with counter 0 and no busy status. TTL mode survives it
   by luck (the fresh `lastAccess` write); **pressure mode ignores TTL and walks
   straight into it**.
2. **BackgroundJob.** A finished turn deletes its `SessionStatus` entry
   (`status.ts:42-46`) while a background job still runs, and owner-scope closure
   interrupts those jobs. `SessionStatus`-empty alone silently kills the user's
   background processes.
3. **Disposal timeout.** `runDisposers` is `Promise.allSettled`
   (`instance-registry.ts:11`) — never rejects, but **can hang**: the MCP finalizer
   awaits `client.close()` untimed (`mcp/index.ts:542`), LSP awaits `client.shutdown()`
   untimed. A hung disposal leaves the evicting deferred incomplete and **every future
   `load` for that directory awaits forever**. Complete it via `ensuring` on all exits
   including defect.
4. **`reload`/`dispose`/`disposeDirectory` must await an in-progress eviction.**
   `reload` swaps a new entry in synchronously (`instance-store.ts:132`) then disposes
   the old in a forked fiber — concurrent with `tryEvict` that reproduces the exact
   boot-races-teardown collision the design claims to close, because `InstanceState`
   ScopedCaches are keyed by bare directory string globally (`instance-state.ts:30-38`).
5. **`lastAccess` is written at request start only**, so a long turn that goes idle is
   evicted ~60s later and the user pays a full re-boot on their next prompt. Touch it
   on release too.
6. **Cross-generation resurrection.** A fiber holding a pre-eviction ctx from an
   uncounted loader (`acp/usage.ts:129`, `acp/directory.ts:117`, `worktree/index.ts:250`,
   `control-plane/workspace.ts:273`) that later calls `InstanceState.get` **re-runs init
   in the still-registered ScopedCache**, respawning e.g. the whole MCP fleet with no
   store entry tracking it.

#### Rollout, and what is explicitly rejected

Default-**off** behind an env var (unset ⇒ the reaper layer is never composed). Stage:
mechanism patch alone → enable TTL on **one** serve via a unit env override (no
lockstep nix release needed to toggle) → watch churn by counting
`server.instance.disposed` → pressure mode last, and triggered on `memory.stat` **anon**,
not `memory.current` (which includes reclaimable page cache and would fire on
cache-warm workloads that would never OOM).

Rejected: a TTL on the `instance-state.ts` ScopedCache (wrong granularity — expires
`SessionRunState` independently and cancels live runners, `run-state.ts:39-45`);
calling `runDisposers` directly from the reaper (leaves a stale entry serving a dead
ctx); per-instance RSS attribution; an LRU capacity cap (count is uncorrelated with
memory — two roots held 6.31G).

The review also recommended shipping LSP bounding **first** on the grounds the problem
is "80% LSP". That generalised from the single 19:32 capture; across all 28 it is 16.7%.
Not adopted on those grounds. LSP-specific idle shutdown remains a reasonable smaller
alternative, but it is not 80% of the win.

### S8 — Stop builds OOM-killing their serve · `workstation-mqp3` · **FIXED 2026-08-05 — shim shipped and verified; soaking**

Found while reviewing S7. S7 was scoped to instance retention; this is a different
consumer that S7 cannot touch, and it is the one that was actually killing serves.

#### Four kills, not one

`opencode-serve@4098` was OOM-killed **four times in about six hours**: 17:56:21,
20:22:56, 23:00:38, 23:25:17 EDT (restart counter reached 3, reset, climbed again).
S2 had recorded only the first. Kills 2–4 all landed *after* the existing `~/.bazelrc`
worker and idle-server limits were live, which is the evidence that those limits were
aimed at the wrong thing.

The agent's bash tool spawns builds as children of `opencode serve`, so every bazel
process is charged to that serve's cgroup. A per-process capture **35 seconds before
kill #3** shows `:4098` at 114 processes and 9.04 G anon, of which **7.61 G was
bazel/JVM** (workspace server JVMs plus ~100 `processwrapper-sandbox` javac actions at
~0.5 G each). LSP was 1.04 G; MCP was zero.

#### Victim selection is a red herring — `OOMPolicy=stop`

It is true, and verified, that every child inherits `oom_score_adj=500` from the unit,
so the adjustment cancels out and the kernel kills the **largest single anon process** —
which is opencode itself (1.5–2.9 G) rather than any one of bazel's ~100 small actions.
It is tempting to conclude the fix is to redirect the victim.

It is not. The unit sets **`OOMPolicy=stop`**, so *any* OOM kill inside that cgroup
stops and restarts the whole serve and takes every session on it down. Killing bazel
instead would restart the serve just the same. **Do not spend effort on `oom_score_adj`.**
Either the ceiling is not reached, or the build does not live in that cgroup.

#### Why the limits that were already there did nothing

| existing flag | what it actually bounds |
|---|---|
| `--worker_max_instances`, `--experimental_total_worker_memory_limit_mb` | **persistent workers** |
| `--max_idle_secs=900` | **idle servers** (verified honored — resident servers were merely recently used) |
| `--shutdown_on_low_sys_mem` | **`/proc/meminfo`**, i.e. host-wide free RAM |

None of them is the sandboxed action fleet. The last one is the sharpest trap: it never
fires in our failure mode, because one cgroup starves while the box still has 19 G free.

#### Shipped (PR #287), Linux-only

```
build --jobs=8                       # the enforced knob
build --local_resources=memory=4096  # belt: default is HOST_RAM*0.67 ~= 41G, so the
                                     # scheduler believed it had 3x the cgroup's room
test  --local_test_jobs=4            # see below
startup --host_jvm_args=-Xmx2g       # JVM is container-aware and otherwise sizes heap
                                     # from the cgroup at 14G/4 = 3.5G PER server
```

`--local_test_jobs` closes a hole found in review: `mono/.bazelrc` pairs
`build:remote --jobs=50` (:191) with `test:remote --strategy=TestRunner=local` (:202),
so a `--config=remote` **test** run keeps its runners local — the one path that
overrides the `--jobs` cap.

#### A verification error worth not repeating

I checked flag existence with `bazel help build` from `/tmp` and concluded
`--local_ram_resources` "does not exist in 9.2.0". But `bazel` here is **bazelisk**,
which outside a workspace runs a *fallback* version. Every `mono` checkout pins
**8.5.1** via `.bazelversion` (`rules_kotlin` pins 9.0.0), and 8.5.1 still has the
deprecated flag. The new spelling was still the right choice — `mono/.bazelrc:101`
already uses `--local_resources=memory=4096` — but the stated reason was wrong.
**Check `.bazelversion` before asserting anything about bazel flags on this box.**

#### This is a mitigation. What is still open

`--jobs` is **per-invocation**: two concurrent builds on one serve still breach 14 G,
and nothing here bounds the aggregate across invocations, server JVMs, or throwaway
worktrees — a server for a `mktemp` worktree (`tmp.93BNSzRJBR`) was observed resident,
so "six checkouts" is not a real bound. Worst-case arithmetic for a *single* build
post-caps lands near 13.7 G against a 14 G ceiling.

The structural fix is a `bazel` shim running builds in their own
`systemd-run --user --scope` with an **explicit `MemoryMax`** — explicit because the
JVM is container-aware, so an uncapped scope would size heap against 62 G rather than
the cgroup. Shim hazards are already in `AGENTS.md`: needs `XDG_RUNTIME_DIR`, transient
units get a minimal `PATH`, must call the real binary by absolute path to avoid
recursion, and must degrade to raw bazel if `systemd-run` fails.

Also standing, and not caused by this: **three of four serves sit at
`swap.current == MemorySwapMax == 1.00G`** — swap is fully consumed, no cushion. And
4 × 14 G = 56 G of `MemoryMax` on a 62 G box with the parent slice at
`MemoryMax=infinity` (`workstation-le0a` owns the aggregate cap).

#### The mitigation was verified, and it was not enough

Over 07:01Z→14:45Z on 08-04, with the caps live: **zero OOM kills**, down from four in
about six hours. But it was not a quiet window, so this is a real result rather than an
absence of events — `:4098` **rode the ceiling for about six minutes**, from 8.35 G at
14:29:10 to **13.99 G** at 14:31:18, oscillating, touching **14.00 G exactly** at
14:35:02, and falling back to 7.50 G by 14:41. 6755 reclaim events, no kill. It survived
on reclaim where the same approach had killed it four times.

Composition during the ride, from `child-capture`: bazel was **88%** of anon at
14:31:39 and **93%** at 14:36:42. So every per-invocation cap was honored — `--jobs=8`
held, the implied ~3.2 G of actions is consistent with 8 × ~0.4 G — and bazel still
walked the cgroup to its ceiling. That is exactly the predicted limit of a
per-invocation mitigation, and it is what justified building the shim.

(A correction this produced: `workstation-lwde` had claimed 5-minute sampling could not
resolve the spike. That conflated two instruments. `samples-v3.tsv` is **16-second**
resolution and resolved the shape fine; only `child-capture`, the per-process
composition, is on a 5-minute clock — and it happened to fire twice inside the ride.
Retitled and downgraded to P3, reframed as "trigger composition capture on pressure,
not on a clock".)

#### The shim shipped (PR #312) and is verified working

Built by a peer session while this was in flight. `pkgs/bazel-scope` puts a `bazel`
wrapper earlier on `PATH` that re-execs the real bazelisk under
`systemd-run --user --scope`, with `users/dev/test-bazel-scope-shim.sh` covering it.

Verified by direct observation rather than inference — from a shell running *inside* a
serve cgroup:

| | cgroup |
|---|---|
| the shell | `/system.slice/system-opencode\x2dserve.slice/opencode-serve@4099.service` |
| the bazel server it spawned | `/user.slice/…/bazel.slice/run-p731610-i394880965.scope` |

The server escapes into `bazel.slice`. The scope really carries `memory.max` = 10 GiB,
the server JVM runs `-Xmx2g` (so the container-aware heap-sizing hazard is moot — the
heap is explicit), and `:4099` sat at 1.16 G current / 1.31 G peak *during* the build,
i.e. untouched. Contrast the pre-shim measurement above: 14.00 G for six minutes.

Two things for whoever soaks it:

- A bazel **server that predates the switch keeps serving scoped clients from the old
  cgroup**, so its builds stay charged to the serve until it idles out (900 s). Run
  `bazel shutdown` in each active workspace before measuring, or the shim will look
  broken when it is not.
- The scope sets `MemoryMax=10G` but leaves **`memory.swap.max = max`** while the serve
  units cap swap at 1 G. Swap is shared, so an unbounded-swap build scope can thrash the
  box instead of failing fast inside its own cap — which partly defeats the isolation
  the scope exists to give. Folded into `workstation-8rou`.

Follow-ups split out: `workstation-8rou` (post-soak: serve `MemoryMax` 14→10 G,
`OOMPolicy` stop→continue, plus the swap cap above) and `workstation-daa0`
(`bb`, the BuildBuddy bazel, bypasses the shim).

## S9 — the class, not the binary (`workstation-yt0p`, PR #337)

S8 moved *bazel* out of the serve cgroup and that held: zero bazel-caused kills
after 08-05. But the defect was never about bazel. The bash tool spawns every
command as a direct child of `opencode serve`, so anything can OOM the serve.
vitest proved it on 08-09 — twice.

**The obvious next step did not exist.** Shimming `vitest` the way we shimmed
`bazel` has no reachable target: `vitest` is not on PATH (the chain is
`npm test` → `npm run --workspaces test` → 3 × `vitest run`, each with an
`nproc`-sized worker pool), and a shim could not win regardless, because npm
*prepends* `node_modules/.bin` ahead of the inherited PATH. Verified with a
fixture: `WINNER=node_modules_bin`. Shimming launchers instead is unbounded —
across 130,091 historical agent commands the memory-capable tail runs from bazel
and python3 down to `./run-tests.sh`, and **the killers arrive via launchers
whose first token does not name the hog.**

So the wrap moved from the PATH boundary to the *tool* boundary: a plugin
rewrites the bash command to run under `systemd-run --user --scope` in a capped
`oc-agent.slice`. Wrap-everything, no memory selector — a selector's wrong guess
is fail-open into the serve cgroup, which is the bug. Cost is 9.0 ms/command
against 0.11 ms bare.

Verified on the box, not just in tests:

| check | result |
|---|---|
| wrapped command's cgroup | `user@1000.service/oc.slice/oc-agent.slice/oc-agent-*.scope` |
| unwrapped, for contrast | `system-opencode\x2dserve.slice/opencode-serve@4099.service` |
| hog under the scope cap | exits **137**; serve stays `ActiveState=active`, `NRestarts=0` |
| `git --version` vs `echo hello` | git runs **bare**, echo runs **wrapped**, same session |
| bazel shim nested in an agent scope | still lands in `bazel.slice` |

### Three traps, each of which would have shipped a silent defect

**systemd expands the command it is handed.** `$$` collapses to `$`, `${VAR}`
substitutes or errors. `--expand-environment=no` turns it off. *The same flag was
missing from `pkgs/bazel-scope`*, where it is a live bug — every bazel argument
containing `$$` or `${...}` has been mangled since that shim shipped. Found by
review of this change, not by symptom.

**Permissions are evaluated after this hook.** `ShellTool.ask` parses the command
text *inside* the tool's execute, so a wrapped command parses as `systemd-run …`
and `"git reset*": deny` stops matching while `"*": allow` matches everything.
That is the structural guard AGENTS.md leans on, and it exists because a review
subagent once destroyed a peer's uncommitted data. Commands mentioning `git` are
therefore never wrapped — matched anywhere, so `echo hi && git stash` cannot be
laundered — with a test asserting the skip list covers every deny rule shipped.

**Nested scopes collide.** `systemd-run`'s auto name is PID-derived, `--scope`
execs in place, and `bash -c` exec-optimizes a final simple command — so the
bazel shim inside an agent scope inherits the PID that named the outer scope and
fails with *"already loaded"*, silently losing its budget and its slice. Agent
scopes use an explicit `oc-agent-<nonce>` name, and bazel-scope's now-false
"unique by construction" comment is corrected.

## Open work, as of 2026-08-10 (post-`yt0p`)

Every open bead in this spine, so the roadmap and the tracker cannot silently diverge.
Steps S0–S2 and S6–S8 are closed; their sections above are the record.

| bead | P | what it is | state |
|---|---|---|---|
| ~~`workstation-yt0p`~~ | P1 | agent-spawned subprocesses OOM-killing serves — the *class*, not just bazel | **DONE** (PR #337): every bash-tool command now runs in its own capped scope in `oc-agent.slice`. Verified on the box: hog exits 137, serve stays `NRestarts=0` |
| `workstation-le0a` | P2 | attach the `opencode-serve.slice` aggregate cap — still `MemoryMax=infinity` with 4 × 14 G on a 62 G box | needs a pool restart in the same deploy |
| `workstation-rdsq.1` | P2 | S7, no idle reaper in serve mode; LSP/MCP fleets pinned for process life (~29% of RSS) | **designed, not built** (PR #285) |
| `workstation-8rou` | P2 | shrink serve `MemoryMax` 14 G → 10 G, flip `OOMPolicy` | **UNBLOCKED** by `yt0p` — foreign workloads no longer land in the serve cgroup, so the premise for shrinking now holds |
| `workstation-0svg` | P2 | the main opencode process alone holds 1.5–2.8 G and climbs (32.7% of RSS) | uncharacterised |
| `workstation-qyxn` | P2 | `io` controller is not delegated to `user@1000`, so bazel scopes report no IO bytes — and IO is this box's dominant stall | needs a system-level `Delegate=` change |
| `workstation-daa0` | P3 | `bb` (BuildBuddy bazel) bypasses the scope shim | largely mooted by `yt0p` — `bb` is now scoped as a generic agent command, though it still misses `bazel.slice`'s dedicated budget |
| `workstation-63wo` | P2 | phantom-busy sweeper defers intraday orphans up to 24 h (min-over-pool cutoff) | **decision rule fired 2026-08-10 → BUILD** the write-time provenance stamp; see S4. Blocked on nothing, but it needs a fork patch (below) |
| `workstation-yvxh.6` | P3 | correlate historical canary-wedge forensics against sweeper run timestamps | not started |
| `workstation-2dwe` | P2 | `reset-workspace` never reaps `oc-agent.slice` scopes, so a backgrounded survivor holds slice budget indefinitely | new, from the `yt0p` review |
| `workstation-lwde` | P3 | `child-capture`'s 5-minute clock can miss the *composition* of a short spike; trigger on pressure instead | downgraded after measuring |

Standing instruments: `~/s3-sampling/` (S2 series, transient timers, its window is now
closed) and `pressure-sampler` (durable home-manager timer, 15 s, memory + PSI + CPU
time for host / serves / serve-slice / `bazel.slice` / each bazel scope). Read the trap
section above before using either.

## Deliberately NOT doing

- **The opencode.db vacuum.** `workstation-yvxh.4` owns it and owns the `mv`.
  Two sessions swapping that file in one window means whichever swaps second
  silently discards the other's writes.
- **A reproduction harness or heap profiler for S1 before the cheap test.**
- **Anything about `workstation-nv5l`** (the second wedge class, 979 session-path
  503s at 10:47 on 08-01). Still unexplained, still not claimed here.
