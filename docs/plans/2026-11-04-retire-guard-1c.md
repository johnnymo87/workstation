# Retire disk-cleanup GUARD 1c, and floor the abandoned-worktree path

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Bead:** `eng-agent-platform-6w8g` (epic `eng-agent-platform-c87c`). Read its notes:
`cd ~/projects/eng-agent-platform && bd show eng-agent-platform-6w8g`.

**Goal:** delete the open-PR keep (GUARD 1c) from the nightly worktree sweep, and give the sweep's
abandoned-worktree path the same 2-day minimum-age floor its merged path already has. The floor
keeps a just-revived worktree from being reaped the following night.

**Architecture:** both changes are in `users/dev/disk-cleanup.nix`, in the worktree sweep (section
2), with tests in `users/dev/test-disk-cleanup-worktrees.sh`. The flake check
`checks.disk-cleanup-worktree-tests` pins the number of `PASS ` lines (34 today).

---

## Why delete 1c instead of teaching it lgtm's cache v3

All measured on cloudbox, 2026-11-04 (plan review by adversarial-reviewer-opus):
- **It never kept anything.** Active from 09-28 to 10-21, 1c kept **zero** trees: no
  `still owns open PR` line anywhere in the journal.
- **It has been inert since 10-22**, because lgtm writes attribution cache v3. That produces a
  nightly WARN `open-PR guard is INACTIVE`, 47 of them on 11-04.
- **The case it guards against barely happens.** Over those 13 inert nights the sweep reaped 289
  trees, and exactly one held an open PR at reap time (mono#5398; cross-repo; it then closed
  unmerged).
- **It is redundant by construction.** The sweep removes only trees whose HEAD is in origin/main,
  or trees whose last commit is 14 days old or more with no origin branch. An open PR's tree
  rarely qualifies.
- **It couples two repos.** It depends on another repo's cache format and has already failed
  silently once.
- **Restore on demand exists**: `oc-revive`, offered by the nvim picker. For goose that arrives in
  workstation#792.

## Why the abandoned path needs the floor

The merged path's GUARD 2 refuses to reap a tree touched within `WORKTREE_MIN_AGE_DAYS` (2). The
abandoned path (last commit 14 days old or more, no `origin/<branch>`) has only the liveness guard.

A revived worktree has fresh checkout mtimes but an old last commit. Its session's DB timestamp
may also be stale: a goose session's `updated_at` does not move until it is prompted. So the
abandoned path can reap it the very next night. Give that path the same floor, fail-closed: when
the freshness scan fails, keep the tree.

---

### Task 1: Delete GUARD 1c

**Files:** `users/dev/disk-cleanup.nix` (`session_owns_worktree`, ~lines 1521-1727),
`users/dev/test-disk-cleanup-worktrees.sh`, `flake.nix` (pin).

Code:
1. Remove from disk-cleanup.nix:
   - the GUARD 1c comment block;
   - `LGTM_ATTRIBUTION_CACHE`;
   - the cache argument to the python probe;
   - the attribution and `gh pr view` code;
   - the `OPEN-PR` and `FREE-UNRECOGNISED-CACHE` verdicts and their log lines.
2. With 1c gone, the opencode probe needs only recent rows. Filter them in SQL
   (`time_updated >= cutoff_ms`) instead of fetching every row.
3. Keep behaviour otherwise identical:
   - GUARD 1b, opencode and goose;
   - missing DB means none;
   - unreadable DB is `PROBE-FAILED`, which keeps the tree;
   - goose prefix matching.
4. Remove every comment that only made sense with 1c, such as "an idle one is still an owner if it
   opened a PR" and "Goose sessions do not take part in GUARD 1c".
5. Keep the separate `lgtm-pr-<N>` / `pr-<N>` handling (keyed by PR state via `gh`, ~line 1911).
   It is unrelated to 1c.

Tests:
6. Remove the 1c fixtures and assertions:
   - the attribution cache;
   - the openpr, subagent-openpr, mergedpr, ghfail, nopr, norepo and manypr trees;
   - the cache-variant reruns (~lines 455-490);
   - any fake `gh` that exists only for 1c. Keep a fake `gh` if the lgtm-pr-N tests use it.
7. Add ONE regression assertion: an idle (30-day) opencode session's merged, aged, clean tree is
   reaped even when an attribution cache naming its session with an OPEN PR exists. This proves
   1c is gone and does not come back by accident.
8. Update the `PASS` pin in flake.nix to the new count.

Then:
9. Run `nix build --no-link .#checks.aarch64-linux.disk-cleanup-worktree-tests`. Also run the
   docker and logrotate disk-cleanup checks, since they share the generated script:
   `.#checks.aarch64-linux.disk-cleanup-docker-tests .#checks.aarch64-linux.disk-cleanup-logrotate-tests`.
10. Commit `[NO-JIRA] disk-cleanup: retire GUARD 1c (open-PR keep), inert since 2026-10-22`.

### Task 2: Floor the abandoned path

**Files:** `users/dev/disk-cleanup.nix` (abandoned branch, ~lines 1930-1955), the test file, and
`flake.nix` (pin).

1. Failing tests first:
   - Abandoned-shape tree (branch with no origin, last commit ≥14 days old via
     `GIT_COMMITTER_DATE`), freshly checked out (mtimes fresh), no session: **kept**, with a log
     line naming it.
   - The same shape, with the whole tree aged 20 days (`find ... -exec touch -d`): **removed**.
     Existing abandoned fixtures (dirty-abandoned, live-abandoned) may need ageing so they keep
     testing what they test; adjust them deliberately and say so in the commit.
2. Implement: before `log "Removing abandoned worktree ..."`, call
   `tree_touched_since "$wt_dir" "$WORKTREE_MIN_AGE_DAYS"`.
   - rc 0: keep, logging `WARN: keeping abandoned worktree (tree touched within ...d)`.
   - rc ≠ 1: keep, logging `freshness scan failed`.
   - Mirror `remove_merged_worktree`'s wording.
   - Add a short why-comment: a revived worktree has fresh mtimes but an old last commit, and the
     revived session's DB timestamp may be stale.
3. Run the checks from Task 1 step 9 and update the pin.
4. Commit `[NO-JIRA] disk-cleanup: minimum-age floor on the abandoned-worktree path`.

### Task 3: Skill text

`assets/opencode/skills/reviving-worktree-orphaned-sessions/SKILL.md`, in the `## Who deletes
these` table only (line ~134).
- Replace "It spares a worktree whose session was active in the last 7 days or still owns an open
  PR, so an older or quieter session is fair game." with:
  "It spares a worktree that a live process is in, that an opencode or goose session used in the
  last 7 days, or that was touched in the last 2 days. An older or quieter session is fair game:
  revive it with `oc-revive`."
- Commit `[NO-JIRA] reviving-worktree-orphaned-sessions: disk-cleanup no longer keeps open-PR trees`.
