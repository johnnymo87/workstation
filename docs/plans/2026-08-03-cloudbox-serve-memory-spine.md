# Cloudbox serve memory — attribute the burst, land the residuals

**Spine bead:** `workstation-rdsq` · **Started:** 2026-08-03 · **Host:** cloudbox only

**Predecessor:** `docs/plans/2026-08-01-cloudbox-serve-reliability-roadmap.md`
(spine `workstation-7za8`). Steps 0–3 deployed; step 4 handed to
`workstation-yvxh.4`. That roadmap fixed the **consequence** of the memory
bursts. This one is about the **cause**, plus the residuals it left open.

**Status:** S0 done · S1 next

---

## Facts that must survive compaction

### What is already deployed, and what it did

Since 2026-08-02 18:57 the serves run **max-only** memory
(`hosts/cloudbox/configuration.nix`): `MemoryHigh` removed, `MemoryMax` 9 G →
**14 G**, `MemorySwapMax=1G`, `TimeoutStopSec=15`. Day-1 result over 14.1 h:

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

**The cleanest evidence against a watcher-driven burst** is not the directory
count at all — it is that **`threads` (~70) and `fds` (~95) stayed flat through
the entire 28.5 G ramp**. Watchers cost threads and fds; this ramp cost neither.
That also constrains any explanation: whatever allocated 28 GiB did so **without
opening anything**.

Caveat on all four rows: they were measured **under the old band regime**
(forced reclaim at 7 G, heavy swap churn). Post-2026-08-02 bursts may differ in
shape; the standing-memory verdicts survive the regime change, the quantitative
details may not.

### The premise of the whole question was wrong

`workstation-vpid` was filed as "28 GiB in an **idle** serve". It was not idle.
During the episode 4099 served **602 requests from 5 distinct sessions**
(580 session-path), at **p50 132 ms / p95 1629 ms / max 5008 ms** — degraded
while serving. One of the five sessions was the roadmap session itself.

The "idle" reading came from `assign_active_10m=0`, which is a lie of naming:
`session_assignment.last_active_at` is written **only** by
`RouteRepo.touchActive`, called from `Router.touch()` on **lease renewal**
(`pigeon/packages/daemon/src/routing/router.ts:294`). Ordinary route resolution
does not touch it, so it reads 0 under continuous load. That is `S6`.

**Every "idle" claim anywhere in the predecessor roadmap must be re-read as
"no recent lease renewal".**

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

### S1 — Attribute the burst · `workstation-vpid` · **NEXT**

The discriminator between 4097 (2.17 G peak) and 4099 (28.50 G) is unidentified.
It is episodic, not accumulative, and it allocated 28 GiB **without opening a
single thread or fd**.

**Test in this order. Each is cheaper than the one after it.**

1. **Read the per-request directory → instance path in the *patched* build.**
   Code reading, no correlation needed. `defaultDirectory` resolves `?directory`
   per request; find what that costs on a cache miss, how instances are keyed,
   and whether they are ever disposed. Read
   `wip/pre-v1.17.13-checkout-20260803` first — `share memoMap between TCP
   listener and in-process webHandler` and `make InstanceBootstrap injectable`
   are prior local work on exactly this path and may already contain the answer
   or the reason it was abandoned.
2. **The ~27 non-`/children` requests in the episode.** Of 969 requests to :4099
   in the archived window, most are the poll; the remainder are the interesting
   ones. Check for message/history/compaction/summarise endpoints — that is the
   cheap test for the *episodic hydration* lead. One pass over the archived
   `.jsonl.gz`.
3. **Replicate across all four peaks, not one pair.** 28.50 / 12.47 / 6.33 /
   2.17 G gives four points; any property proposed as the discriminator must
   order all four, not just separate 4099 from 4097. At n=1 episode, *any*
   post-hoc property separates one serve from another.

**Explicitly rejected as the opening move:** "subagent child count, because the
hot endpoint is `/children`". The doc's own facts refute it — the TUI polls every
~5 s regardless of child count, and `Session.children` returns session rows only,
so even 100 children is tens of KB against 28.5 G. Three polling sessions means
three attached TUIs, nothing more.

- **Escalation trigger, declared now so "inconclusive" cannot loop forever:** if
  1–3 do not name a mechanism, arm a threshold capture — `anon > 8 G` on any
  serve → collect JS stacks via the Bun inspector (prior art and its WS-contention
  caveat in `users/dev/home.devbox.nix`, the canary's js-stacks connect). Bursts
  crossed 9 G roughly four times per 20.6 h before the deploy, so a threshold
  capture should catch one within days.
- **Exit criteria:** either a named mechanism that orders all four peaks, or a
  written statement of what was excluded and why, with the threshold capture
  armed. **Do not** re-run anything in the dead table.

### S2 — The 7-day report on the memory posture · `workstation-h1y6`

Scheduled wake fires **2026-08-09 14:00 UTC**. Report as one of the four
outcomes with the pre-declared cap-adjustment rule; the criteria live in the
predecessor roadmap's step 2 and must not be improvised.

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

### S4 — Bound the cost of a kill · `workstation-63wo`

The sweeper's min-over-pool cutoff defers intraday orphans up to 24 h. Before
step 2 this was cosmetic; now that OOM kills are possible it is what bounds
their user-visible cost. Per-owner gate via routing leases.

### S5 — Record the wedge-attribution method · `workstation-yvxh.6` · P3

**Do not run the correlation.** It has zero usable data points: the only
forensics dump (`wedge-20260801T191003-4098`, 19:10:18) predates the sweeper's
first run on this host (20:32:12) by 82 minutes. It is also retrospective on two
mechanisms since removed — the throttle band and the sweeper's write lock.
Record the door-log-join method instead. W1's effect must be measured
**prospectively** (wedges after 2026-08-03 12:07); there is no before-sample.

### S6 — Fix the metric that caused all this · `workstation-29k3`

Rename `last_active_at` to say what it means, or touch it on route resolution.
Renaming is cheaper and does not churn the hot path.

## Deliberately NOT doing

- **The opencode.db vacuum.** `workstation-yvxh.4` owns it and owns the `mv`.
  Two sessions swapping that file in one window means whichever swaps second
  silently discards the other's writes.
- **A reproduction harness or heap profiler for S1 before the cheap test.**
- **Anything about `workstation-nv5l`** (the second wedge class, 979 session-path
  503s at 10:47 on 08-01). Still unexplained, still not claimed here.
