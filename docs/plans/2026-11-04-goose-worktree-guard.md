# Goose Sessions Pin Their Worktrees: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (or subagent-driven-development) to implement this plan task-by-task.

**Bead:** eng-agent-platform-1bdy

**Goal:** Neither worktree reaper (`work --prune-merged`, run nightly by reset-workspace,
and disk-cleanup's worktree sweep) deletes the working directory of a goose session that
was active in the last 7 days. Today both ask only opencode.db.

**Architecture:** Each reaper already has a fail-closed "does a recent session live here?"
probe against opencode.db. Add a second probe against goose's session DB with the same
contract (0 = a recent session lives here, 1 = none, 2 = could not tell). A MISSING goose
DB means "no goose on this host", so the answer is no. An unreadable one keeps the tree.

**Tech Stack:** bash (`writeShellApplication`, `sqlite3` already in `runtimeInputs`),
inline Python `sqlite3` in disk-cleanup, and the existing shell test harnesses wired as
flake checks (`git-work-tests`, `disk-cleanup-worktree-tests`).

---

## Facts the implementer needs

- Goose DB: `~/.local/share/goose/sessions/sessions.db`. It is in WAL mode, and a live
  goose-serve or honkd is writing it, so open it **read-only**.
- Table `sessions`. The relevant columns are `id TEXT`, `working_dir TEXT NOT NULL`,
  and `updated_at TIMESTAMP`.
- `updated_at` is stored as TEXT `'YYYY-MM-DD HH:MM:SS'` in UTC. All 2925 rows on
  cloudbox are 19 characters long and typed text.
- Compare in SQL with `updated_at >= datetime('now', '-N days')`. That is a
  lexicographic comparison of the same format, so it is correct.
- Do not convert the cutoff in bash or Python with local time.
- Session ids look like `20261104_3`. Log them as `goose session <id>` so they are
  not mistaken for opencode `ses_` ids.
- Path matching: match the worktree itself or any directory under it. Use `substr`,
  never `LIKE`, because worktree names contain `_`, which is a `LIKE` wildcard.
  git-work's existing opencode query already does this; copy its shape.
- Archived sessions (`archived_at`) are NOT filtered out. The 7-day window already
  bounds them, and erring toward keeping a tree costs one day of disk.
- Real-world case on cloudbox today: `/home/dev/projects/honk/.worktrees/markdown-formatting`
  is the `working_dir` of a goose session updated within 7 days. No opencode session
  names it.

## Task 1: `work --prune-merged` consults goose

**Files:**
- Modify: `pkgs/git-work/default.nix`. The guard comment is at ~L131-151,
  `session_owner` at ~L169-194, `prune_one` at ~L291-298, and the `prune_merged`
  doc comment at ~L196-207.
- Test: `pkgs/git-work/test.sh`. The setup is near the top, and Test 9e is at ~L400-440.

**Step 1: Isolate the suite from the real goose DB.**
Near the top of `test.sh`, after `work_script` is resolved, add
`export WORK_PRUNE_GOOSE_DB="${WORK_PRUNE_GOOSE_DB_TEST:-/nonexistent/goose-sessions.db}"`.
Simpler and also fine: `export WORK_PRUNE_GOOSE_DB=/nonexistent/goose-sessions.db`.
Without this, a developer run would read the real DB.

**Step 2: Write the failing test (Test 9f).** Put it after Test 9e, in the same style.
In `$fresh_clone`:
- Create worktrees `goose_live`, `goose-sub`, and `goose-stale` with `--no-fetch`.
- Build `$tmpdir/goose.db` with
  `create table sessions (id text primary key, working_dir text not null, updated_at timestamp);`.
- Insert three rows:
  - `('20261104_1', '<wt_goose_live>', datetime('now'))`
  - `('20261104_2', '<wt_goose_sub>/crates/x', datetime('now'))`
  - `('20261001_9', '<wt_goose_stale>', datetime('now','-30 days'))`
- Run
  `WORK_PRUNE_GRACE_DAYS=0 WORK_PRUNE_SESSION_DB=/nonexistent/opencode.db WORK_PRUNE_GOOSE_DB="$tmpdir/goose.db" "$work_script" --prune-merged`.
- Assert:
  - `goose_live` is KEPT.
  - `goose-sub` is KEPT.
  - `goose-stale` is REMOVED.
  - The output contains `goose_live (goose session 20261104_1 lives here)`.
- Then write garbage into `$tmpdir/goose-broken.db` and recreate one worktree
  (e.g. `goose-broken`). Run with `WORK_PRUNE_GOOSE_DB="$tmpdir/goose-broken.db"`.
- Assert that worktree is KEPT and the output contains `goose session probe failed`.

**Step 3: Run it and watch it fail:** `bash pkgs/git-work/test.sh` (it builds `.#git-work`).
Expected: the goose assertions FAIL, because `goose_live` and `goose-sub` are removed.

**Step 4: Implement.**
- Add `PRUNE_GOOSE_DB="''${WORK_PRUNE_GOOSE_DB:-$HOME/.local/share/goose/sessions/sessions.db}"`
  next to `PRUNE_SESSION_DB`.
- Add `goose_session_owner()` with the same contract and the same `sqlite3 -readonly
  -cmd '.timeout 5000'` invocation as `session_owner`. Missing file returns 1.
- Its query:
  ```sql
  select id from sessions
   where (working_dir = '$sql_path'
          or substr(working_dir, 1, length('$sql_path') + 1) = '$sql_path' || '/')
     and updated_at >= datetime('now', '-$PRUNE_SESSION_ACTIVE_DAYS days')
   order by updated_at desc limit 1;
  ```
- A shared helper is fine if it stays readable. Do not over-abstract.
- In `prune_one`, after the opencode check:
  ```bash
  owner_rc=0; owner="$(goose_session_owner "$real_wt")" || owner_rc=$?
  case "$owner_rc" in
    0) log "prune-merged: keep $wt_path (goose session $owner lives here)"; return 1 ;;
    1) : ;;
    *) log "prune-merged: keep $wt_path (goose session probe failed: $owner)"; return 1 ;;
  esac
  ```
- Update the LIVE SESSION guard comment and the `prune_merged` doc bullet to say
  "opencode or goose session". Mention briefly why: goose workers started with
  `honk launch` have their worktree as `working_dir`, and goose rows are in a
  separate DB.

**Step 5: Run the tests.** `bash pkgs/git-work/test.sh` must end in `ALL PASS`.

**Step 6: Commit.** `git commit -m "[NO-JIRA] work --prune-merged: keep worktrees of recent goose sessions"`.
Run bare `git commit`, with no identity flags.

## Task 2: disk-cleanup's worktree sweep consults goose

**Files:**
- Modify: `users/dev/disk-cleanup.nix`. The GUARD 1b comment and `SESSION_DB` are at
  ~L1483-1513, and `session_owns_worktree` is at ~L1545-1680.
- Test: `users/dev/test-disk-cleanup-worktrees.sh`.

**Step 1: Write the failing tests.**
- In the fixture, add two worktrees alongside `session_clean_wt`: `goose_session_wt`
  (`goose-session-merged`) and `goose_idle_wt` (`goose-idle-merged`).
- Create them the same way as the others and age them 20 days, like `session_clean_wt`.
- Create `$home/.local/share/goose/sessions/sessions.db` with Python `sqlite3`, using
  the same `sessions` schema as Task 1. Insert two rows:
  - `goose_session_wt`'s resolved path, with `updated_at` 3 days ago.
  - `goose_idle_wt`'s resolved path, with `updated_at` 30 days ago.
  - Write both timestamps as `'%Y-%m-%d %H:%M:%S'` in UTC
    (`time.strftime(..., time.gmtime(...))`).
- Assert after the main harness run:
  - `assert_remove_not_logged "$goose_session_wt" "aged clean worktree owned by a live goose session is not selected for removal"`
  - `assert_remove_logged "$goose_idle_wt" "aged clean worktree whose goose session went idle weeks ago is still selected for removal"`
- Add a fail-closed case with a new re-run after the cache re-runs:
  1. Replace the goose DB with garbage, keeping a backup copy so later runs are unaffected.
  2. Re-run the harness.
  3. Assert that `goose_session_wt` and `clean_wt` are NOT logged. The goose probe
     failing keeps every tree it is asked about.
  4. Restore the DB.
- Add a "no opencode DB, goose only" case:
  1. Move the opencode DB away temporarily and re-run.
  2. Assert that `goose_session_wt` is not logged and `goose_idle_wt` is logged.
  3. Restore it.
- These re-runs guard against the bug the current code would have:
  `[ -f "$SESSION_DB" ] || return 1` short-circuits before goose is ever asked.

**Step 2: Run the suite and watch it fail.** The suite needs the deployed script's bytes.
Run it the same way as the flake check:
`nix build --no-link -L .#checks.aarch64-linux.disk-cleanup-worktree-tests`.
Expected: FAIL on the goose assertions.

**Step 3: Implement.**
- Add `GOOSE_SESSION_DB="$HOME/.local/share/goose/sessions/sessions.db"` next to `SESSION_DB`.
- In `session_owns_worktree`, replace `[ -f "$SESSION_DB" ] || return 1` with:
  return 1 only when NEITHER file exists.
- Pass `GOOSE_SESSION_DB` as an extra argv to the Python probe.
- In Python, query opencode only if `os.path.isfile(db_path)`. Keep the existing rows
  and the 1c logic, with `rows = []` when the file is absent.
- Before the opencode recent check (or right after it, before 1c), if the goose DB is a
  file, open it read-only with `uri=True, timeout=10` and run:
  ```sql
  select id from sessions
   where (working_dir in (<candidates>)
          or <any candidate> prefix-match via substr(working_dir,1,length(?)+1) = ? || '/')
     and updated_at >= datetime('now', ?)
   order by updated_at desc limit 1
  ```
  - Bind `'-%d days' % active_days`.
  - Any exception prints `PROBE-FAILED: goose: <exc>` and exits 0.
  - A hit prints `SESSION goose:<id>` and exits 0.
- Goose sessions do not take part in GUARD 1c. lgtm's attribution cache maps PRs to
  opencode sessions only. Say this in one comment line.
- Extend the GUARD 1b comment with a short paragraph on goose workers: their
  `working_dir` is a row in a second DB, and both DBs are consulted.

**Step 4: Run the suite and watch it pass.** Run the same `nix build` command. It must
reach `all disk-cleanup worktree tests passed`.

**Step 5: Commit.** `git commit -m "[NO-JIRA] disk-cleanup: keep worktrees of recent goose sessions"`.

## Verification (both tasks)

- `bash pkgs/git-work/test.sh` should end in `ALL PASS`.
- `nix build --no-link .#checks.aarch64-linux.git-work-tests .#checks.aarch64-linux.disk-cleanup-worktree-tests`.
- Smoke-test against the real DB on cloudbox, read-only. Source the built `work` and
  call `goose_session_owner /home/dev/projects/honk/.worktrees/markdown-formatting`.
  It should print a goose id and return 0, unless that session has aged out by then.

## Out of scope

Disk-cleanup's tmp-scratch, venv, cargo and bazel reapers are also opencode-only.
Losing one of those costs a rebuild, not a session, so they are not part of this
change; the PR description will name them.
