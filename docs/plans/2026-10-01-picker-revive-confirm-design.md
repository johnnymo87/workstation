# Picker: one-keypress revive (workstation-6lnw.7)

Approved by the human on 2026-10-01 ("option 1", then "looks right, green light").
This replaces the one-line hint shipped in #620. That hint told the user which command to run, but
text in nvim's warning bar cannot be copied, and the ask was a single keypress to accept or decline.

## Flow

Both pickers (the session switcher and the stall-watch picker) accept a row through
`session_switcher.dispatch`, so a change in `exec.refuse_dir_missing` covers both.

1. Enter on a row whose directory is gone. The existing WARN refusal fires synchronously and is
   unchanged.
2. `oc-revive plan <sid>` runs in the background (`vim.system`, 5 s timeout). Any failure, timeout,
   unparseable output, or a plan that fails validation stays silent, as before.
3. If the plan is actionable, a `vim.fn.confirm` prompt appears. **Cancel is the default**, and Esc
   cancels too. Typeahead is discarded first. The prompt arrives asynchronously, so it is shown only
   if the window and mode are unchanged since the Enter and under 3 s have passed. Otherwise a
   prompt could swallow keys typed elsewhere, and a stray `r` would accept. In that case the picker
   says "press Enter on it in the picker again".
   - **Revivable, one candidate.** Shows the session title, the branch and short commit, the commit
     subject and date, the new directory, a warning if the branch is already merged (the worktree is
     swept about 7 days after the session goes idle), and "uncommitted files are NOT carried over".
     Buttons: `&Revive`, `&Cancel`.
   - **Revivable, candidates disagree.** One numbered button per candidate (`&1 <branch>`,
     `&2 <branch>`), then `&Cancel`.
   - **Blocked by an unfinished earlier revive** (`blocked_by_worktree:` plus the structured
     `plan.resume` from #622). Buttons: `&Resume`, `&Cancel`.
     When there is no resumable `plan.resume` (the worktree is held by another session, or an
     `oc-revive` without #622), #620's one-line WARN is kept: "revive blocked: … run `oc-revive <sid>`
     for details". This change therefore depends on #622 being deployed for the Resume button.
4. On accept, a floating terminal runs `oc-revive apply …` (or `oc-revive resume …`). The argv is
   built only from plan fields, never from prose, and the user sees the real output.
   - **Exit 0:** the float closes and the session opens via `oc-auto-attach`.
   - **Non-zero:** the float stays open, scrolled to the last line of output, and `q` closes it.
   - **`q` while running only hides the float.** Deleting a terminal buffer makes nvim SIGHUP, then
     SIGTERM, then SIGKILL the job, and `oc-revive` cannot survive a SIGKILL mid-move. A hidden run
     carries on, and the float reappears if it then fails. `apply` returns 1 for
     a clean refusal, an ambiguous move, and a partial success (moved, notice failed). So the picker
     does not branch on the code; it shows the output. Re-running is safe because `resume` after a
     move is idempotent.

## Safety

- `oc-revive` stays the only code that decides anything. `apply` re-checks the branch tip and the
  dead directory under its lock, so a stale prompt cannot do harm.
- Lua never computes a path. It rejects the whole plan (silently, like any malformed plan) when:
  - `plan.sid` differs from the row, or `plan.dead_dir` differs from the row's directory;
  - a target path is not exactly `<plan.repo>/.worktrees/<one component>`, or equals the dead dir;
  - a branch is empty, contains whitespace, control characters or a backtick, or starts with `-`
    (it becomes an argv value);
  - a full tip is not 40 or 64 hex characters, or a candidate's `action` is not `add`;
  - `resume.expect_old_dir` differs from the dead dir.
- A per-sid in-flight guard means a second Enter while a revive is running does not prompt again.
- If a pane is already attached to the session, that TUI was launched with the OLD directory. After
  a successful revive the picker does not attach. It tells the user to close that pane and reopen
  the session instead.
- Displayed strings (title, subject) have control characters replaced and are truncated. Branch
  names have `&` doubled so they cannot introduce a confirm accelerator.

## Out of scope

Sibling worktree reuse, moving child sessions, and picking up uncommitted files from the snapshot.

## Testing

- Pure unit tests for the new `revive.lua` (validation, prompt text, argv) and for the exec flow
  with stubbed `vim.system`, `vim.schedule`, confirm and terminal.
- A headless test of the real floating terminal: exit 0 closes it; non-zero leaves it open.
- Mutation testing with predictions written before running.
- Live acceptance on `ses_f557e244effexijoBAs1YBALI9` (mono, `k2bq-scanner-budget`), through the
  real picker, with the human pressing the key.
