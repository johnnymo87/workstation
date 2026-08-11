# Roadmap: generalizing the worktree guard beyond mono (spine)

Bead spine: **`workstation-v03j`** (epic), items **`.7 .9 .10 .11 .12`**.
Read this file with `bd show workstation-v03j.7` (etc.) open — **the beads carry
the detail, this file carries the shape.** Evidence and rejected alternatives
live in the sibling design doc; do not re-derive either.

- Design + evidence: [`2026-08-11-worktree-guard-generalization-design.md`](2026-08-11-worktree-guard-generalization-design.md)
- Original mono v1 design: [`2026-07-08-worktree-guard-readonly-main-design.md`](2026-07-08-worktree-guard-readonly-main-design.md)
- The mono *freshness* half of the same epic: [`2026-08-04-mono-root-freshness-roadmap.md`](2026-08-04-mono-root-freshness-roadmap.md)
- PR that opened this line of work: [#348](https://github.com/johnnymo87/workstation/pull/348)

## Recovering after compaction — read this first

If you are a session that has lost context, this is the whole state in four lines:

```bash
cd ~/projects/workstation
bd show workstation-v03j.7 workstation-v03j.9 workstation-v03j.10 workstation-v03j.11 workstation-v03j.12
bd ready --json | head          # what is unblocked right now
git log --oneline -5 -- docs/plans/2026-08-11-worktree-guard-*
```

**Nothing in this roadmap has been implemented.** As of 2026-08-11 the only
shipped guard is the mono-only pre-commit hook. If `bd show` disagrees with that
sentence, trust `bd`.

## The problem, in one paragraph

A *primary* git checkout is a shared, writable tree that every session's cwd
defaults to. Agents therefore edit and commit there instead of in a worktree.
The convention against it is real and widely followed — pigeon had 13 worktrees
in use on the day it was violated — but it is stated only in prose, and prose is
advisory. Of the six controls that exist today, **exactly one blocks a write, and
it blocks only the commit**, in only one repo. The edit-blocking layer was built,
never loaded, and deleted on 2026-07-25.

## Measurements that justify the work

Do not re-derive these; they are the evidence base. Survey of every primary clone
under `~/projects`, 2026-08-11:

| Repo | Dirty at root | Unpushed on trunk | Guarded? |
|---|---|---|---|
| `mono` | **11** | 0 | hook installed |
| `workstation` | 0 | **1** (`af6307c`, same day) | no |
| `meridian` | 0 | **1** (17 days) | no |
| `opencode-cached` | 0 | **1** (17 days) | no |
| `k8s-gitops` | 0 | **1** (**140 days**) | no |
| `pigeon` | 0 | 0 (post-rescue) | no |

Two things this table says that nothing else does. **The guarded repo is the
dirtiest** — the hook stops commits, not edits. And **four roots carry stranded
commits right now, one for 140 days, one of them workstation itself** — the
failure is endemic and unobserved, not a pigeon anomaly.

**The incident that makes this non-theoretical (2026-08-11):** a session
committed `300304d` (`pigeon-ud6s`) directly onto local `main` in
`~/projects/pigeon` — unpushed, branchless — and it sat for hours while
`origin/main` moved on. It was found only because a third session needed to pull
for a deploy. Rescued onto `pigeon-ud6s-300304d`. Pigeon's daemon runs `tsx`
against the working tree, so that root is production.

## Shipped

Nothing from this roadmap. Prior art from the same epic that this builds on:

- **`work` helper** — `pkgs/git-work`. Repo-agnostic, on PATH on all hosts. `v03j` Phase 1.
- **mono-only pre-commit hook** — `assets/git-hooks/pre-commit`, enrolled by
  `installMonoWorktreeGuardHook` in `users/dev/home.base.nix:850-870`. `v03j.4`, closed 2026-08-04.
- **`ff-mono-root`** staleness timer — PR #307. `v03j.6`.
- **`opencode-launch --worktree`** — exists, opt-in, not default. Phase 3.5.

## The steps

Each row is one step = one PR = one compaction boundary. Run the per-step
cadence below for every one of them.

| # | Bead | P | What | Gate / blocked by |
|---|---|---|---|---|
| 1 | `workstation-v03j.7` + `.10` | 1 / 2 | Enroll `{mono, pigeon, workstation}` via a `worktreeGuardRepos` list; state the rule in workstation `AGENTS.md`; give the hook's block message a real escape hatch | ready. **Ship as one PR** — `.10` is what makes `.7`'s block survivable |
| 2 | `workstation-v03j.9` | 1 | Trunk-drift detector: report any primary root that is dirty-on-trunk or ahead of origin | ready. Independent of step 1 — could go first if step 1 stalls |
| 3 | `workstation-v03j.11` | 2 | `opencode-launch` defaults writable sessions into a worktree | **blocked by `.9`** (needs churn baseline). Own design pass first |
| 4 | `workstation-v03j.12` | 3 | Retire `reset-workspace`'s mono-only prune in favour of `disk-cleanup` | **blocked by `.7`** |

`.10`'s pigeon half lands in **another repo** (`~/projects/pigeon/AGENTS.md`) and
must go through pigeon's own PR flow. Do not commit it from workstation.

### Why this order

Step 1 is an hour and closes the commit-onto-trunk failure for the three repos
that matter. Step 2 is the only item that addresses the *dirty root* failure at
all, and the only one that covers the ~20 repos that will never be enrolled — on
benefit alone it ties with step 1; it is second only because it is 3h to step
1's 1h. Step 3 is the actual fix (prevention by construction, stops both failure
modes) and is deliberately last because it is the only one with real blast
radius. Step 4 is cleanup.

## Per-step cadence

Run all six, in order, for each step. Skip a stage only by writing *why* on the
bead.

1. **Compact** (`preparing-for-compaction`). Persist state to the bead + this
   file *before* compacting, and schedule a wake if the step will span a gap.
2. **Consult `oracle-fable`** — optional, use for steps 2 and 3 where the design
   is not already pinned. Skip for step 1 (the design doc already names the exact
   nix edit) and step 4.
3. **SDD** (`subagent-driven-development`) if the step has ≥2 independent tasks.
   Step 3 qualifies; steps 1, 2 and 4 are single-task and go direct with TDD.
   Dispatch `implementer`, then `spec-reviewer`.
4. **`adversarial-reviewer-fable`** — **mandatory, every step, before the PR.**
   This epic has a track record of shipping controls that were never exercised
   (the plugin that never loaded); a pre-merge adversarial pass is the cheapest
   place to catch the next one.
5. **PR** (`shepherding-pull-requests`). Shepherd it until it *lands* — PR
   creation is not a terminal state.
6. **Update this roadmap**: move the row to "Shipped" with the verification
   command that proves it, and file any new beads the step uncovered.

> The `-fable` variants are named deliberately: the operator asked for them by
> name for this epic. Do not silently substitute `-opus`.

## Verification each step must produce

A step is not done because the PR merged. It is done when one of these prints
the right thing on the host:

- **`.7`** — `git -C ~/projects/pigeon config --get core.hooksPath` returns
  `/home/dev/.config/git-hooks`, **and** a real `git commit` attempt at the
  pigeon root is refused, **and** a commit in `pigeon/.worktrees/*` still
  succeeds. Do not accept "home-manager switched" as evidence.
- **`.9`** — the detector, run by hand, names `k8s-gitops` (140 days ahead) or
  whatever has replaced it, and does **not** name mono's permanent dirt.
- **`.11`** — a writable `opencode-launch` with no flags lands in
  `.worktrees/<slug>`; a read-only one still lands at the root.

## Traps this epic has already paid for

Inherited from the freshness roadmap and the 2026-07-08 design. Re-read before
each step.

- **A control that never runs looks identical to no control.** The worktree-guard
  plugin never loaded on any process and nobody noticed until it was deleted.
  Every step must end with the control *observed firing*, not merely installed.
- **Do not copy a neighbour's `git status --porcelain` early-return guard.** In a
  tree that is always dirty (mono is, permanently) that is a silent no-op that
  logs a healthy-looking line.
- **Never `reset`/`stash`/`clean`/auto-quarantine in a shared root.** It has
  already destroyed a peer session's uncommitted database. Detect and report.
- **`core.hooksPath` is winner-take-all.** Enrolling a repo that has real hooks
  silently disables them (`culinary-operations-server` has 11).
- **Signalling only through systemd failure state assumes something looks.**
  That is `workstation-yb4b`, still open; `.9` must not inherit it.
- **Assert which path ran, not just the exit code.** A stub `exit 0` satisfied
  seven tests in this epic before reason-string assertions were added.

## What is deliberately NOT being done

Full reasoning in the design doc §5. Summary, so nobody re-proposes them:

- **A global `core.hooksPath`** — would silently disable
  `culinary-operations-server`'s 11 overcommit hooks and `lgtm`'s `post-merge`,
  and fight `opencode`'s husky. Explicit enrollment instead.
- **A branch-name check** — wrong invariant in both directions. Key on
  primary-worktree identity.
- **Rebuilding the edit-blocking opencode plugin** — the layer whose absence
  hurts most, and still not yet: the last one never loaded. Fix plugin-load
  observability first (`.11` is the alternative route to the same outcome).
- **A `git` shell wrapper** — a second interposition on a binary that
  `agent-scope` deliberately leaves unscoped so the deny globs keep matching.
- **cwd-conditional opencode permission rules** — globs match command text, not
  cwd. Not implementable without a plugin.
- **A `pre-merge-commit` hook** to close the measured `merge` bypass — that
  bypass is load-bearing; `git pull` at the root is pigeon's deploy step.
- **Enrolling all ~40 repos** — value scales with write traffic. Three cover it.
