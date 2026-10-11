# Kill, don't throttle: user-slice OOM containment (devbox + cloudbox)

Status: approved by owner 2026-10-11; revised after adversarial review
(oomd dry-run only, serve adj 200, honest goal, strict drill).

## Incident (2026-10-10 23:47 → 2026-10-11 11:45 EDT, devbox)

An agent session (eternal-machinery `cartographer`) launched
`systemd-run --user --unit=m1-heal-…` running an Elixir test that enabled
`:dbg.p(:all, :c)` with an unbounded tracer mailbox. The unit landed in
`user@1000.service/app.slice` (no memory limit). Within ~6 min
`user-1000.slice` reached its `MemoryHigh=20G` / `MemorySwapMax=6G` ceiling
(systemd-reported peaks: 21G / 6G) and stayed there ~12 h:

- `MemoryHigh` throttles (reclaim in the allocating thread) and never kills.
  Every process in the slice crawled: both opencode serves (pigeon then
  bounced sessions between them, "serve not running"), and new SSH logins
  (a `hostname` took ~8 min).
- earlyoom watches host-wide free memory; the host sat at ~19% available
  because the slice was capped, so its 10% threshold never tripped until
  10:33, when it picked serve :4096 (`--prefer` matches `.opencode-wrapp`),
  which was too frozen to exit; it retried every 10 s for an hour.
- systemd-oomd was running but monitored **zero** cgroups (nothing sets
  `ManagedOOM*`).
- healthchecks.io stayed green: em-ci-monitor is a system unit outside the
  throttled slice.

Recovered by reboot. Evidence: journal boot -2 on devbox
(`journalctl -b -2 -u earlyoom`, `… | grep 'memory peak'`), opencode.db
session `ses_0da8fafd6ffe6PGPonX4kleAik` bash parts 23:47:07–23:47:17.

## Goal and non-goals

**Goal:** a runaway in the dev user's slice ends in a kill, not a 12-hour
throttle, and the opencode serves are not the preferred victim.

Honest scope of "fast": a fast allocator (the incident's `:dbg` mailbox) is
killed within seconds of reaching the slice's RAM+swap cap. A slow leak can
still thrash for a long time at `memory.max`: the kernel retries the charge
as long as reclaim frees anything (`mm/memcontrol.c:2235`, v6.12), and
neighbours refaulting file cache count as progress. This repo has seen exactly
that, with `bazel.slice` thrashing ~2.5 h at its own MemoryMax
(`users/dev/home.cloudbox.nix:730-741`). Closing that case needs a working
pressure killer (oomd, §2), which is gated on soak data.

Applies to devbox fully. On cloudbox the serves live in a root-level
`opencode.slice` outside `user-1000.slice` (`hosts/cloudbox/configuration.nix:1503,1822`),
and 56G + the serve pool exceeds the 62 GiB host, so earlyoom fires before the
slice cap. There, change 1 only removes the throttle band and buys no
containment. It is applied for consistency.

**Non-goals (owner decision: treat as a one-off; do not trade off agent
productivity):** preventing deliberate escape. Known, accepted gaps:
- `sudo` (dev has NOPASSWD) and `docker run` (dev is in the docker group; rootful
  `docker.service` in `system.slice`) both place work outside any user-slice cap.
- A same-UID agent can name any slice/unit; only an ancestor's hard limit holds.
  `user-1000.slice` is the ancestor of everything dev starts via the user
  manager or SSH, so that is where the hard limit goes.
- No separate agent UID, no systemd-run guard/shim, no Docker cap.

NVIDIA OpenShell was evaluated and rejected for this
(`docs/investigations/2026-10-11-openshell-evaluation.md`).

## Changes

### 1. `user-1000.slice`: MemoryHigh → MemoryMax (same values)

| Host | Today | New |
|---|---|---|
| devbox (`hosts/devbox/configuration.nix:1387-1391`) | `MemoryHigh=20G`, `MemorySwapMax=6G` | `MemoryMax=20G`, `MemorySwapMax=6G` |
| cloudbox (`hosts/cloudbox/configuration.nix:5780-5787`) | `MemoryHigh=56G`, `MemorySwapMax=24G` | `MemoryMax=56G`, `MemorySwapMax=24G` |

Ceiling unchanged; reaching it now means the kernel OOM-kills inside the slice
(highest `oom_score`, i.e. the runaway by RSS) instead of throttling all of it.
Same reasoning as the per-serve change of 2026-07-03 (Max-only; the High band
is the wedge zone). Swap still absorbs up to the swap cap first, so expect a
short reclaim phase before the kill, not an instant one.

Rewrite the comment that justified slice-level High ("plenty of reclaimable
page cache … earlyoom backstops") — the incident refutes both halves.

### 2. systemd-oomd on user slices — DRY-RUN soak, kill mode deferred

`systemd.oomd.enableUserSlices = true` on devbox, with oomd started with
`--dry-run` (override `ExecStart`), for at least a week of normal use plus the
drill. Kill mode is a separate later decision based on its "Would have
killed" logs. Not enabled on cloudbox in this change.

Why not kill mode now (adversarial review, read from systemd v258
`src/oom/*`):
- Victim = highest pgscan delta (`oomd-util.h:73-91`). Once the slice's swap
  cap is exhausted (the incident did exhaust it), an anon-only runaway has
  almost no pgscan; the scanned cgroups are the ones holding file cache:
  serves, dev-daemons, tmux panes.
- `ManagedOOMPreference` is ignored when the candidate's owner differs from
  the monitored cgroup's owner (`oomd-util.c:161-175`). `/user.slice` is
  uid 0 and the serve cgroups are uid 1000, so `avoid` doesn't protect them
  on that path.
- Candidates include whole tmux pane scopes and the SSH/mosh session scope.
- Kills can repeat every 15 s while pressure stays above the limit.
- The 80% limit is PSI `full` avg10, so CPU-bound tasks in the slice can keep
  it from firing at all.

Original rationale, kept for the later decision: From the nixpkgs module
(`nixos/modules/system/boot/systemd/oomd.nix:72-80`): sets
`ManagedOOMMemoryPressure=kill`, `ManagedOOMMemoryPressureLimit=80%` on
`user.slice` and on every user-manager slice (`systemd.user.units."slice"`).
oomd then kills the descendant cgroup with the most reclaim activity once
pressure exceeds 80% for the default 30 s. Kills a unit/scope, not a session.

If kill mode is adopted later, monitor only through the user-manager drop-in
(ownership matches, so `ManagedOOMPreference=omit` works on the serves), and
weigh `MemoryLow` on the serve path (`user@1000.service` → `app.slice` →
serve slice; `memory_recursiveprot` is on) as stronger serve protection than
any oomd preference.

### 3. Serve protection

- **devbox earlyoom:** remove `.opencode-wrapp` from `--prefer`
  (`hosts/devbox/configuration.nix:1339`), matching cloudbox's
  workstation-o5s1.5 reasoning (the serve is the most stateful process and,
  under the pressure that brings earlyoom in, cannot run its SIGTERM handler).
  Keep `node|bun|headless_shell|nix-build`. Do not add `beam.smp`: it would
  match the main dev BEAM and docker BEAMs.
- **devbox serve `OOMScoreAdjust`: 500 → 200** (`users/dev/home.devbox.nix:908`).
  For an OOM at a cgroup limit the kernel's sizing base is
  `memory.max + min(swap.max, total_swap)` = 26G, so each adj point is
  worth 26 MB. The serves' 300-point lead over an adj-200 runaway (what a
  `systemd-run --user` unit gets, checked live) is a 7.8G handicap: a
  moderate leak would lose to a serve or a serve's agent child, and under
  `OOMPolicy=stop` that restarts the serve. At 200 they tie with everything
  else the user manager starts, so size decides. Bash children inherit 200,
  which is fine. Going to 0 (cloudbox's shape) still waits on D.
- No `ManagedOOMPreference` in this change (moot with oomd in dry-run).

### 4. AGENTS.md (`assets/opencode/AGENTS.md`)

At the "Correct pattern: escape the cgroup" `systemd-run --user --unit=…`
recipe, add `-p MemoryMax=8G -p MemorySwapMax=0` (with a note to size it) and
one sentence citing this incident: an uncapped job lands in `app.slice` and its
only limit is the whole user slice.

### 5. earlyoom retry loop

Leave as is (it is the whole-host backstop). Document in the earlyoom comment
that a frozen victim produces `kill failed: Timer expired` repeats; no
earlyoom option bounds that.

## Verification (per host, after deploy)

Devbox only. Cloudbox: config checks (1-2) only, no drill.

1. `cat /sys/fs/cgroup/user.slice/user-1000.slice/memory.{max,high}` → max
   20G (cloudbox 56G), high `max`. Serve processes' `oom_score_adj` = 200.
2. `oomctl` lists the monitored cgroups; the oomd unit's command line has
   `--dry-run`.
3. **Drills.** Gate each one on step 1 passing, and give it
   `-p RuntimeMaxSec=300` so a bad deploy can't recreate the wedge.
   Workload: a monotonically growing allocator (python appending 64 MB
   chunks, never freeing), not `stress-ng`, which re-touches its pages.
   - (a) fast: as fast as possible, to about 30G;
   - (b) slow: about 50 MB/s.
   **Pass criteria**, all required:
   - the only cgroup killed is the drill unit: serve
     `memory.events oom_kill` unchanged, no other unit in the
     `journalctl -k` OOM lines, serve `NRestarts` unchanged;
   - `memory.swap.current` of the slice reached `memory.swap.max` before
     the kill (proves the post-swap phase was exercised);
   - both serves answer `/global/health` within 3 s throughout;
   - for (a), killed within 2 min of starting.
   Record: time to kill for (b), or `RuntimeMaxSec` firing (the thrash
   case, an expected and documented limitation), and oomd's dry-run "Would
   have killed …" lines for both drills.

## Rollout

devbox first; cloudbox (change 1 only) after one day without unexpected kills
(`journalctl -k | grep -i oom`). Rollback is a revert per host.

## Follow-ups (beads, not this change)

- D: port `oc-scoped-shell` to devbox; then serve `OOMScoreAdjust=0` there.
- oomd kill-mode decision after the dry-run soak (§2).
- healthchecks.io blind to a starved-but-alive devbox (monitor runs outside
  the user slice).
- Known gaps above (sudo, docker), if the one-off assumption stops holding.
