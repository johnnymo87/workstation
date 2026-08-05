# Roadmap: keeping the mono root honest (spine)

Bead spine: **`workstation-v03j`** (epic). Read this file with `bd show workstation-v03j`
open; the beads carry the detail, this file carries the shape.

Supersedes the planning half of
[`2026-07-08-worktree-guard-readonly-main-plan.md`](2026-07-08-worktree-guard-readonly-main-plan.md),
whose Phase 1–3 checkboxes are all shipped. That document is now history; this one
is the live view.

## The problem, in one paragraph

`~/projects/mono` is a *primary* checkout that two things keep going wrong with.
It gets **written to** (agents commit onto whatever branch it is parked on,
instead of working in a worktree), and it goes **stale** (nothing pulls it). Both
are worse than they sound, because `mono/.agents/skills` is a real directory in
that tree and every agent session loads its skills from there. A dirty root
corrupts other sessions' work; a stale root feeds every session obsolete
instructions.

Neither failure announces itself. That is the through-line of this whole epic:
each phase converts a silent failure into a loud one.

## Measurements that justify the work

Do not re-derive these; they are the evidence base.

| Date | Root behind `origin/main` |
|---|---|
| 2026-07-08 | 84 commits |
| 2026-07-27 | 175 |
| 2026-08-03 | 272 |
| 2026-08-04 (24h after a manual refresh to zero) | 27 |

Roughly **25 commits/day** of drift. `reset-workspace` only prunes merged
worktrees; nothing pulled.

**The incident that makes this non-theoretical:** on 2026-08-03 the stale root
served a 3.5-week-old observability skill that predated an environment-scoping
rule. A session followed it and published a production finding that was 100x
wrong — 90,391 reported where prod was 904 — because its queries blended a `uat`
environment into a `prod` aggregation. Tracked in mono's own tracker as
`mono-1rhe`.

## Shipped

- **Phase 1 — `work` helper.** `pkgs/git-work`. Makes the right thing easy.
- **Phase 2/3 — write containment.** A per-repo `core.hooksPath` pre-commit hook
  (`assets/git-hooks/pre-commit`, installed in `users/dev/home.base.nix`) blocks
  commits at the mono primary root and allows them in linked worktrees.
  `workstation-v03j.4`, closed 2026-08-04.
  - The two-layer design (opencode plugin + git hook) collapsed to one: the
    plugin layer was removed 2026-07-25 (it never loaded, and its path heuristic
    flagged every relative path). The surviving layer has no warn mode, which is
    why v03j.4's "bake in warn mode" prerequisite was closed as unsatisfiable
    rather than done.
- **Staleness containment.** `assets/scripts/ff-mono-root` + a cloudbox user
  timer, PR #307, merged 2026-08-05. `workstation-v03j.6`.

### Why `ff-mono-root` is shaped the way it is

Four decisions that look arbitrary until you know what they are avoiding. If you
are tempted to "simplify" any of them, read this first.

1. **No `git status --porcelain` dirty-check**, unlike its neighbour
   `pull-workstation`. The mono root is *permanently* dirty (8 untracked entries
   plus a modified submodule pointer). That check would skip on every run while
   logging a healthy-looking line — a silent no-op, i.e. the exact failure the
   bead exists to end. Instead: attempt the fast-forward, let git refuse.
2. **Never reset/stash/clean.** The root is a *shared* tree; peer sessions keep
   uncommitted and untracked data in it, and a "cleanup" in a shared tree has
   already destroyed a peer's uncommitted database once.
3. **Only fast-forwards `main`.** On a feature branch, `merge --ff-only
   origin/main` fast-forwards *that branch* onto main's tip whenever it is an
   ancestor, silently relocating a branch someone is using.
4. **Fires 02:45, daily, no `Persistent`.** OpenCode snapshots skills at *session
   start*, so a mid-day refresh helps nobody already running while still mutating
   a tree under live readers. 02:45 lands it before the 03:00 session turnover,
   which is what makes the *next* day's sessions fresh.

Failure semantics: known skips exit 0 (never wedge the timer chain); a root stuck
behind >150 commits (~6 days) exits nonzero so the unit goes `failed`.

## Open

| Bead | P | What | Gate |
|---|---|---|---|
| `workstation-v03j.6` | 1 | ff-only auto-updater | **Merged but unverified on the host.** See below. |
| `workstation-faj7` | 1 | Untracked droppings at the root permanently block the fast-forward | **Live now.** See below |
| `workstation-yb4b` | 2 | Nothing watches failed systemd *user* units | Makes v03j.6's tripwire mean something |
| `workstation-v03j.7` | 2 | Generalize enrollment beyond mono (nix multi-repo list) | — |
| `workstation-v03j.8` | 3 | Live-session-aware worktree prune + reopen-cwd fallback | — |

### Status: deployed, and blocked on its first real run

Home-manager switched on cloudbox 2026-08-04 20:18; the unit exists and the
timer is armed for 02:45. Run by hand once at 20:19, it **refused correctly** —
named the reason, exited 0, touched nothing — so the code is verified. What is
*not* yet verified is a successful fast-forward end to end, because of
`workstation-faj7` below.

To verify once that is cleared:

```bash
systemctl --user list-timers ff-mono-root            # exists, next elapse 02:45
systemctl --user start ff-mono-root                  # run it by hand once
journalctl --user -u ff-mono-root -n 20 --no-pager   # expect a fast-forward or a NAMED skip
git -C ~/projects/mono rev-list --count HEAD..origin/main   # expect 0
```

**Do not verify by loading a skill in a running session.** Skills are cached at
session start, so you will see stale content and wrongly conclude it failed.
Check the file (`wc -l`) or the behind-count.

### `faj7`: the collision class, found on day one

The first real run refused because an **untracked** file at the root
(`wonder/blueapron/fulfillment/docs/plans/2026-08-04-fbm-stranded-cohort-drain.md`)
is now also a **tracked** file on `origin/main` (mono PR #4079). Git will not
fast-forward over it, and will not until the untracked copy moves.

This is structural, not bad luck. The v03j hook blocks *commits* at the root but
nothing stops file *creation* there, so sessions still drop plan docs at the root
and later land the same path from a worktree. Every such file is a future
permanent block. Expect it roughly weekly.

Containment holds — the script refuses safely, and the tripwire converts the
freeze into a failed unit at 150 behind (~6 days) — but containment is not a fix,
and it inherits `yb4b`'s "assumes something looks" problem.

Four options are recorded on the bead, none chosen. Note that the tempting one
(have the timer auto-quarantine colliding files and retry) means the timer moves
a peer's data unattended, which is the never-discard line the script was
deliberately written not to cross.

**Never resolve an instance with `git clean` on the mono root.** Shared worktree,
peer data; a prior cleanup destroyed a peer session's uncommitted database.

### Why `yb4b` matters more than its priority suggests

`v03j.6`'s entire monitoring story is "systemd marks the unit failed". That
assumes something *looks*. If nothing runs `systemctl --user --failed`, then
failed-forever is nearly as invisible as the silent-forever failure the tripwire
was built to replace — and the same hole applies to every other user timer that
signals through failure state (`disk-cleanup`, `em-drift-detector`,
`pull-workstation`, the opencode canaries). Cheapest fix is the morning
recommendation agent, which already runs daily and is Telegram-reachable.

## What is deliberately NOT being done

- **No `git submodule update`** in the auto-updater. It can detach or discard work
  inside a submodule checkout. A dirty submodule pointer is cosmetic and provably
  does not block a fast-forward (pinned by test 12 in
  `assets/scripts/test-ff-mono-root.sh`).
- **No separate read-only clone for skills.** Considered and rejected:
  redirecting the agent's cwd-relative `.agents/skills` lookup would mean
  symlinking a tracked path, i.e. creating permanent dirt to fix dirt, plus two
  trees to reason about. Revisit only if the tripwire fires repeatedly because
  agents keep dirtying tracked files at the root.
- **No devbox counterpart.** Cloudbox is the work machine, devbox is personal,
  mono is work. The `isCloudbox` gating is correct by design, not an oversight.

## Anti-patterns this epic has already paid for

- Copying a neighbouring unit's dirty-check into a context where the tree is
  always dirty (silent no-op that reads as healthy).
- Asserting "exits 0 and nothing moved" without asserting *which path ran* — a
  stub `exit 0` satisfied seven such tests before reason-string assertions were
  added.
- Trusting `Type=oneshot` defaults: `TimeoutStartSec=infinity` plus a hanging
  `git fetch` leaves the unit `activating` forever, and a timer will not re-fire
  a still-activating unit.
