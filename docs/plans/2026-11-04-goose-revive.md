# Goose session revive (oc-revive + picker) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Bead:** `eng-agent-platform-c87c.1` (epic `eng-agent-platform-c87c`). Read the bead's notes with
`cd ~/projects/eng-agent-platform && bd show eng-agent-platform-c87c.1`. They hold the reviewer's
required changes and the experiment result.

**Goal:** a goose session whose worktree was deleted can be revived from the nvim session picker
with one keypress, the same way an opencode session can.

**Architecture:** for goose, the revive recreates the worktree **at the session's original path**.
It does not move the session to a new path, as opencode's revive does.
- `oc-revive` dispatches on the id prefix: `goose:<native>` takes the goose path, `ses_...` takes
  the existing opencode path, which stays byte-for-byte the same in behaviour.
- The git half (branch candidates, the trunk, root and checked-out filters, the lock, the
  failed-hook verification) is shared.
- The session half (row lookup, commit evidence, path choice, apply steps) is per-backend.
- The picker offers the revive for `goose:` rows.

**Tech Stack:** Python 3 stdlib (`pkgs/oc-revive/oc_revive.py`, unittest suite
`test_oc_revive.py`), Lua for nvim (`assets/nvim/lua/user/session_switcher/`, suite
`assets/nvim/test-session-switcher-spec.lua`), Nix flake checks.

---

## Why the same path is right for goose (do not "fix" this into a new path)

opencode needs a NEW path because its serve memoizes the failed path lookup (`pkgs/oc-revive/README.md`).

Goose does not. Measured 2026-11-04 on cloudbox: goose-serve patched.10 plus the live honkd, a
held session with its agent loaded.
- Deleting the worktree made the shell tool fail with ENOENT. The session was not refused.
- `git worktree add` at the same path and branch, with no restarts, made the next turn's
  `pwd; git rev-parse HEAD; touch x` succeed.

Code reading agrees: honkd re-reads the cwd from goose on every activation and caches nothing per
path; goose's shell spawns with `current_dir(path)`.

Moving a goose session is not even possible without a honk change, because honkd ignores a
client's cwd.

## The one hazard same-path recreation adds: opencode siblings

If any **opencode** session row has the dead dir, or a directory under it, as its `directory`,
recreating the dir turns that opencode session into a silent zombie, and the picker stops offering
its revive.

So the goose plan and apply **refuse** in that case:
- reason prefix `opencode_sibling:`, naming the opencode sid;
- the check uses the existing `get_session_referencing_path` against opencode.db, opened read-only;
- opencode.db missing: no siblings;
- opencode.db present but unreadable: refuse (`opencode_db_unreadable:`). Fail safe.

Other goose sessions at the same path are fine: recreation revives them too.

## Explicitly decided

- **No notice to the agent.**
  - Goose has no `noReply` prompt, so any notice costs an LLM turn the human did not ask for.
  - The human revives from the picker and lands in `honk chat` on that session at once, so they
    can tell it.
  - `apply` prints, on stdout, one line the human can paste: worktree recreated at `<path>` on
    `<branch>` @ `<tip>`; uncommitted work from before the deletion is gone; verify HEAD before
    continuing.
  - Document this in the README.
- **No busy check for goose.**
  - opencode's busy guard protects the move.
  - Recreating a directory under a running goose turn only makes its shell start working again.
  - honkd is the only place goose's running state lives, and the picker's 5 s plan budget cannot
    afford a `honk list` call (measured 1.7–3.5 s).
- **No ledger, no move, no resume subcommand for goose.** If `apply` dies after `git worktree add`,
  the directory exists, so the session works and `plan` reports `directory_exists`. There is nothing
  left to resume.
- **Branch gone** (for example deleted by `work --prune-merged`): refuse with `no_candidates`, as
  opencode does. A branch that prune-merged deleted was merged, so its tip is already in trunk.
- **`gse_...` input:** not accepted (YAGNI; the picker passes `goose:<native>`).
- **Reaping again:** a tree recreated at the dead path gets fresh mtimes from checkout, so the merged
  path's 2-day floor (`disk-cleanup.nix`, `remove_merged_worktree`) keeps it. The *abandoned* path
  (last commit ≥14 d, no origin branch) has no floor. That is fixed in bead
  `eng-agent-platform-6w8g`'s PR, not here, because both touch the same disk-cleanup test file and
  pin.

## Goose DB facts (read-only, `?mode=ro`)

`~/.local/share/goose/sessions/sessions.db` (override: env `GOOSE_SESSION_DB`, flag `--goose-db`).

- `sessions(id TEXT, session_type TEXT, working_dir TEXT, parent_session_id TEXT, archived_at, updated_at, name, ...)`.
- `session_type` values seen: `acp` (everything honkd or `honk launch` creates), `user`, `hidden`,
  `sub_agent`, `scheduled`.
- Revivable: `acp` and `user` only, `parent_session_id IS NULL`, `archived_at IS NULL`. Otherwise:
  - `child_session:` when `parent_session_id` is set;
  - `unsupported_session_type:` for any other type;
  - `archived_session:` when archived.
- `messages(id INTEGER, session_id TEXT, role TEXT, content_json TEXT, ...)`. Tool results are in
  **role='user'** rows. `content_json` is a JSON list; an item with `"type":"toolResponse"` has
  `toolResult.value.content[]`, and each `{"type":"text","text":...}` there is tool output. Real
  example (session 20261104_12, id 69898):
  `[{"type":"toolResponse","id":"toolu_…","toolResult":{"status":"success","value":{"resultType":"complete","content":[{"type":"text","text":"/tmp/…/probe\nb3d833c…"}]}}}]`
  Commit evidence is the existing `COMMIT_OUTPUT_RE` applied to those texts, in `id` order. The
  last match wins, skipping detached HEAD, exactly as opencode does.

The picker id is `goose:<native>`, where native matches `^[0-9]+_[0-9]+$`. The plan's `sid` field
echoes the id **as given** (`goose:<native>`), because the Lua validator compares `plan.sid == sid`.

---

### Task 1: Split commit evidence from its opencode reader; add the goose plan

**Files:**
- Modify: `pkgs/oc-revive/oc_revive.py`
- Test: `pkgs/oc-revive/test_oc_revive.py`
- Modify: `flake.nix` (`checks.oc-revive-tests` pin `Ran 99 tests` → the new count)

Steps:
1. Write failing tests (a goose fixture DB with the `sessions` and `messages` columns above;
   real throwaway git repos as the existing tests do). Cover:
   - `plan_revive("goose:<id>")` with a dead `.worktrees/<slug>` dir and a surviving slug branch
     returns `revivable: true`, `harness: "goose"`, `sid` equal to the given id, `snapshot: null`,
     and one candidate with `action: "recreate"` and `path == dead_dir`.
   - Commit evidence from a goose toolResponse text picks a second branch. Both candidates are
     listed (`source` `slug` and `bash-evidence`), with `"both"` when they agree.
   - Refusals, each a distinct reason prefix:
     - `session_not_found:`
     - `child_session:`
     - `unsupported_session_type:` (`hidden`)
     - `archived_session:`
     - `directory_exists:`
     - `invalid_directory_shape:`
     - `not_a_git_repo:`
     - `no_candidates:` (branch deleted, or branch checked out elsewhere, or trunk)
     - `opencode_sibling:` (opencode fixture row at the dead dir, and one at a subdir)
     - `opencode_db_unreadable:`
   - A malformed id (`goose:abc`) gives `session_not_found:` or `invalid_session_id:`, never a crash.
   - The opencode plan for a `ses_` id is unchanged (the existing tests keep passing untouched).
2. Run `python3 pkgs/oc-revive/test_oc_revive.py` and confirm the new tests fail.
3. Implement:
   - `last_commit_evidence(outputs: Iterable[str])`: the regex loop, extracted from
     `extract_last_commit_evidence`. The opencode function becomes a thin reader that feeds it.
     Add `goose_tool_outputs(conn, native_id)`.
   - Refactor `find_branch_candidates` to take `evidence` and a `choose_path` callable (or
     equivalent) instead of `db_conn` and `session_id`, so both backends share the filters. Keep
     the opencode call site's behaviour identical.
   - `plan_goose_revive(sid, goose_db_path, opencode_db_path)`, reusing the shape guard and the
     git-repo guard. Factor them out of `plan_revive` only as far as needed to avoid copying them.
   - `plan_revive` dispatches on the `goose:` prefix.
   - The `blocked_by_worktree` and `resume` logic is opencode-only.
4. Run the suite until it is green. Update the flake pin to the new `Ran N tests`.
5. Commit: `[NO-JIRA] oc-revive: plan revives for goose sessions (same-path recreation)`.

### Task 2: Goose apply, and the CLI

**Files:** `pkgs/oc-revive/oc_revive.py`, `pkgs/oc-revive/test_oc_revive.py`, `flake.nix` (pin).

Steps:
1. Write failing tests:
   - `apply` for `goose:<id>` with `--action recreate --path <dead> --expect-old-dir <dead> --branch b --expect-tip T`:
     - creates the worktree at the dead path on branch b at T;
     - returns ok;
     - prints the paste-able line;
     - makes no HTTP call. Assert with a mock that `urllib.request.urlopen` is never called.
   - Under the repo's `oc-revive.lock`, `apply` re-validates and refuses with a clear error when:
     - the fresh goose row's `working_dir` ≠ `--expect-old-dir` (`directory-mismatch`);
     - `--path` ≠ `--expect-old-dir` (`recreate needs --path == --expect-old-dir`);
     - the path now exists (`plan-changed`);
     - the branch tip moved (`plan-changed`);
     - an opencode sibling now exists (`opencode_sibling`);
     - the branch is checked out in another live worktree.
   - Run `git worktree prune` before `add`, so a prunable stale entry for the dead path does not
     block it. Test: a deleted-without-prune worktree leaves a prunable entry, and apply still
     succeeds.
   - A failing post-checkout hook goes through the existing `verify_worktree_after_failed_add`
     (reuse it; adapt its signature only if it needs opencode state).
   - `--action add` for a goose id, and `--action recreate` for a `ses_` id, are both usage errors.
   - Interactive `oc-revive goose:<id>` (with `input` patched to `y`) applies. The human-readable
     plan says "Recreate at" rather than "New cwd".
   - `--goose-db` is honoured by `plan`, `apply` and interactive mode.
2. Confirm the tests fail.
3. Implement `apply_goose_revive`, dispatch from `main`, and argparse `--action {add,recreate}` and
   `--goose-db`. The opencode `apply_revive` is untouched apart from the action choices.
4. Run the suite until green, and update the pin.
5. Update `pkgs/oc-revive/README.md`:
   - a "Goose sessions" section: same path and why, the opencode-sibling refusal, no notice, no
     busy check, no resume;
   - the usage line for `goose:<id>`.
6. Commit: `[NO-JIRA] oc-revive: apply goose revives by recreating the worktree in place`.

### Task 3: Picker offers the goose revive

**Files:**
- `assets/nvim/lua/user/session_switcher/revive.lua`
- `assets/nvim/lua/user/session_switcher/exec.lua` (`M.refuse_dir_missing`, ~line 446, and its doc comment)
- `assets/nvim/test-session-switcher-spec.lua`
- `flake.nix` `checks.nvim-lua` pins, if the assertion count line for the spec suite is pinned.
  Check `grep -n "assertions" flake.nix` around the nvim-lua check.

Steps:
1. Write failing tests in the spec suite, next to section 86. Cover:
   - `refuse_dir_missing` runs `{"oc-revive","plan","goose:20261104_12"}` for a goose row, with the
     same opts as for `ses_`.
   - `revive.offers(plan, "goose:…", dead)` accepts a goose plan whose candidates have
     `action == "recreate"` and `path == dead_dir`, the dead dir being exactly
     `<repo>/.worktrees/<leaf>`. It builds argv
     `{"oc-revive","apply",sid,"--branch",b,"--path",dead,"--action","recreate","--expect-tip",tip,"--expect-old-dir",dead}`.
   - It REJECTS:
     - a goose plan with `action == "add"`, or with `path ~= dead_dir`;
     - an opencode plan (`ses_` sid) with `action == "recreate"`;
     - a goose plan carrying a `resume` object or a `blocked_by_worktree:` reason (goose has no
       resume: nil);
     - a sid of `goose:abc`.
   - `revive.blocked` is false for goose ids.
   - `revive.prompt` for a goose offer says `recreate dir <rel path>` (not `new dir`). It still says
     uncommitted files are not carried over.
   - Every existing `ses_` test passes unchanged.
2. Confirm the tests fail (`bash assets/nvim/test-session-switcher.sh`).
3. Implement:
   - `valid_sid` accepts `^ses_[%w]+$` or `^goose:%d+_%d+$`.
   - Goose branches go in `offers` and `prompt`.
   - `exec.lua`'s sid gate uses the same predicate. Export it from `revive.lua`, so the two cannot
     drift.
   - After a successful apply, `M.attach({sid = sid})` already routes `goose:` ids to
     `oc-auto-attach` and then `honk chat`. Verify it with a test; no code change is expected.
4. Run the suite until green, and update the pins.
5. Commit: `[NO-JIRA] session picker: offer revive for goose sessions whose worktree is gone`.

### Task 4: Skill text

**Files:** `assets/opencode/skills/reviving-worktree-orphaned-sessions/SKILL.md`.

Add a short `## Goose sessions` section **immediately before `## Related`**. Do not edit the
`## Who deletes these` table: bead 6w8g's PR edits that, and both PRs must merge cleanly. The
section says:
- `oc-revive goose:<id>`, or Enter in the picker;
- it recreates at the same path, because nothing in goose or honkd caches the path;
- it refuses when an opencode session also lives there;
- no notice is sent, so tell the agent.

Commit: `[NO-JIRA] reviving-worktree-orphaned-sessions: goose sessions`.

## Verification (orchestrator, after all tasks)

- `nix build --no-link .#checks.aarch64-linux.oc-revive-tests .#checks.aarch64-linux.nvim-lua`
- Live check, read-only:
  - `nix build .#oc-revive` (or `nix run`), then `oc-revive plan goose:20261104_12` against the
    real DBs. That is the probe session in `/tmp/opencode/revive-probe`, whose worktree is
    currently deleted.
  - Expect `invalid_directory_shape` or `revivable`, depending on the shape. The probe repo is
    `/tmp/opencode/revive-probe/.worktrees/probe`, which is the valid shape, so expect revivable
    with branch `probe`.
  - Then run `apply` on it with the built binary and prompt the session (`swarm_send` to
    `gse_9fb56b21-…`) to confirm it works.
  - Afterwards, delete the probe repo.
