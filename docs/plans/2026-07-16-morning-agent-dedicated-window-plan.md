# Morning Agent Dedicated Window Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the nightly `reset-workspace` morning agent land in a dedicated,
clearly-named `morning` tmux window instead of running headless / hijacking the
home shell, by launching it in `$HOME/morning` instead of `~`.

**Architecture:** Change the launch cwd in `pkgs/reset-workspace/default.nix`
from `~` to `$HOME/morning` (created with `mkdir -p`). This reuses
`oc-auto-attach`'s existing `basename`-derived window naming and cwd-based pane
matching to produce a fresh `morning` window that can never hijack the
`/home/dev` shell pane. No changes to `oc-auto-attach` or `opencode-launch`.
Telegram flow is unchanged. See
`docs/plans/2026-07-16-morning-agent-dedicated-window-design.md`.

**Tech Stack:** Nix (`pkgs.writeShellApplication`), Bash (`set -euo pipefail`,
shellcheck-gated at build), a source-grep test harness (`test.sh`).

---

## Task 1: Launch the morning agent in `$HOME/morning`

**Files:**
- Modify: `pkgs/reset-workspace/default.nix:566-612` (the Step 6 launch block)
- Test: `pkgs/reset-workspace/test.sh` (source-grep assertions)

**Step 1: Write the failing test**

The harness greps `$default_nix` with `grep -qF` (fixed string). Two helpers
already exist — `want_grep` (fails if absent) and `refuse_grep` (fails if
present); confirm with `grep -n 'want_grep()\|refuse_grep()' pkgs/reset-workspace/test.sh`.
Do **not** add a new `want_no_grep` — use `refuse_grep`.

**Escaping note (load-bearing):** because the assertions are fixed-string
greps, the *source* must contain the exact bytes we grep for. Write the new
launch line **unescaped** — `opencode-launch "$MORNING_DIR" "$RECOMMENDATION_PROMPT"`
— which is valid Nix (a bare `$X` not followed by `{` is literal in an indented
string; the file already mixes styles, e.g. `"$MONO_ROOT"` at `:559`). Then the
fixed-string patterns below match. (If you instead write `"''$MORNING_DIR"`, the
source becomes `"''$MORNING_DIR"` and `grep -qF '"$MORNING_DIR"'` will NOT match
— that was the bug this note prevents.)

Add these assertions near the existing Phase 3.5 launch-ordering block (after
line ~189):

```bash
  # 2026-07-16: morning agent lands in a dedicated $HOME/morning window
  # (not headless/cwd=~). See docs/plans/2026-07-16-morning-agent-dedicated-window-design.md
  want_grep "morning agent dir is defined"          'MORNING_DIR="$HOME/morning"'
  want_grep "morning agent dir is created"          'mkdir -p "$MORNING_DIR"'
  want_grep "launch targets the morning dir"        'opencode-launch "$MORNING_DIR" "$RECOMMENDATION_PROMPT"'
  # The old cwd=~ launch must be gone. This substring matches current source
  # (opencode-launch '~' "''${RECOMMENDATION_PROMPT}") and disappears after the change.
  refuse_grep "no legacy tilde launch"              "opencode-launch '~'"
```

**Step 2: Run the test to verify it fails**

Run: `bash pkgs/reset-workspace/test.sh`
Expected: FAIL on the four new assertions (`MORNING_DIR`, `mkdir -p`, launch
target present; legacy tilde launch absent) — none exist yet.

**Step 3: Write the minimal implementation**

In `pkgs/reset-workspace/default.nix`, in the `else` branch of the Step 6 block
(currently `:576-611`), edit as follows.

Replace the log line (`:577`):
```bash
      log "launching recommendation session in ~ ..."
```
with:
```bash
      # Land the morning agent in a dedicated dir so oc-auto-attach gives it a
      # recognizable `morning` tmux window (basename of the dir) instead of a
      # generic `dev` window / a hijacked ~ shell pane. cwd=~ has no clean home
      # for it; see docs/plans/2026-07-16-morning-agent-dedicated-window-design.md.
      # mkdir is best-effort: a failure must not abort the (already best-effort)
      # launch — opencode/tmux fall back to a default cwd.
      MORNING_DIR="$HOME/morning"
      mkdir -p "$MORNING_DIR" || log "WARNING: could not create $MORNING_DIR; launching anyway"
      log "launching recommendation session in $MORNING_DIR ..."
```

Replace the launch invocation (`:607-609`):
```bash
      # opencode-launch first arg is directory, second is the prompt.
      # ~ resolves inside opencode-launch via "''${directory/#\~/$HOME}".
      if ! opencode-launch '~' "''$RECOMMENDATION_PROMPT" 2>&1 | while IFS= read -r line; do log "  ''$line"; done; then
```
with (note: `$MORNING_DIR` / `$RECOMMENDATION_PROMPT` are written **unescaped**
so the fixed-string test assertions match — see the escaping note in Step 1;
`''$line` stays escaped as before to preserve the existing style):
```bash
      # opencode-launch first arg is directory, second is the prompt.
      if ! opencode-launch "$MORNING_DIR" "$RECOMMENDATION_PROMPT" 2>&1 | while IFS= read -r line; do log "  ''$line"; done; then
```

**Step 4: Run the test to verify it passes**

Run: `bash pkgs/reset-workspace/test.sh`
Expected: PASS (all assertions, including the four new ones).

**Step 5: Verify the script still builds (shellcheck gate)**

Run: `nix build .#reset-workspace --no-link 2>&1 | tail -20`
Expected: builds cleanly (exit 0), no shellcheck errors.

**Step 6: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "feat(reset-workspace): morning agent lands in dedicated ~/morning window"
```

---

## Task 2: Fix the prompt (rationale + self-skip + scratch dir)

**Files:**
- Modify: `pkgs/reset-workspace/default.nix` — the `RECOMMENDATION_PROMPT`
  heredoc (`:581-606`), specifically the manifest-read instruction (`:586`) and
  the `--tmux-session main` justification (`:594`).

**Step 1: Write the failing test**

Add to `pkgs/reset-workspace/test.sh`:

```bash
  # The --tmux-session main mandate stays, but its rationale must no longer
  # claim the agent is "a headless session" (it now has a `morning` TUI tab).
  want_grep "reopen still forces --tmux-session main" 'oc-auto-attach --tmux-session main <sid>'
  refuse_grep "prompt no longer calls itself headless"  'you are a headless session not attached to tmux'
  # The agent must skip its own predecessor (captured at ~/morning) and keep
  # scratch out of the marker dir so it stays uninhabited.
  want_grep "prompt self-skips the morning dir"        '$HOME/morning'
```

Note: `want_grep '$HOME/morning'` matches literally (the heredoc is quoted
`<<'PROMPT'`, so `$HOME` is emitted verbatim into the prompt text; the agent
resolves it at runtime). Confirm the heredoc delimiter is `'PROMPT'` (quoted)
before relying on this.

**Step 2: Run the test to verify it fails**

Run: `bash pkgs/reset-workspace/test.sh`
Expected: FAIL on `refuse_grep` (headless phrase still at `:594`) and on the
self-skip `want_grep` (no `$HOME/morning` mention yet).

**Step 3: Write the minimal implementation**

(a) In the heredoc at `:594`, replace the sentence:

> ALWAYS pass `--tmux-session main` -- you are a headless session not attached
> to tmux, so without it the reopened tab lands in whatever session tmux
> considers "current" rather than reliably in the user's `main` session.

with (rationale corrected — `oc-auto-attach` already defaults `target_session`
to `main` per `oc-auto-attach/default.nix:199`, so the honest reason is
determinism, not "headless"):

> ALWAYS pass `--tmux-session main` -- `oc-auto-attach` defaults to `main`, but
> pass it explicitly so a reopened tab never silently depends on that default
> and always lands in the user's `main` session.

Keep the `oc-auto-attach --tmux-session main <sid>` instruction earlier in the
same paragraph unchanged.

(b) In the manifest-read instruction at `:586`, append a self-skip + scratch
directive, e.g. after the existing "If the manifest file is missing or empty..."
sentence add:

> You are yesterday's morning agent's successor: skip any manifest sid whose
> session directory is `$HOME/morning` — that is a previous morning agent, not a
> user session. If you need scratch files, write them under `/tmp`, never in
> `$HOME/morning` (keeping that dir uninhabited is what guarantees your own tab
> never clobbers a user pane).

**Step 4: Run the test to verify it passes**

Run: `bash pkgs/reset-workspace/test.sh`
Expected: PASS.

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix pkgs/reset-workspace/test.sh
git commit -m "docs(reset-workspace): morning prompt drops headless claim, self-skips ~/morning"
```

---

## Task 3: Update the skill/AGENTS wording

**Files:**
- Modify: `.opencode/skills/resetting-workspace/SKILL.md` (`:8`, `:17`, `:30-33`, `:110`)
- Modify: `assets/opencode/skills/understanding-workspace-reset/SKILL.md` (`:3`, `:27-28`, and any "headless from ~" body text)
- Modify: `assets/opencode/AGENTS.md:38` ("headless morning recommendation agent")

**Step 1: Read each file's relevant sections**

Run: `sed -n '1,55p' .opencode/skills/resetting-workspace/SKILL.md` and the
equivalent for the other two files, to see exact current wording.

**Step 2: Make the edits (docs only, no test)**

Change "headless" framing to the dedicated-window model. Specifically:

- `resetting-workspace/SKILL.md:17` — "launches a headless opencode session in
  `~`" → "launches an opencode session in a dedicated `~/morning` dir, which
  `oc-auto-attach` opens as a `morning` window in your `main` tmux session."
- `resetting-workspace/SKILL.md:30-33` — the "recommendation session is headless
  (not attached to tmux)" justification → "`oc-auto-attach` already defaults to
  `main`; the session passes `--tmux-session main` explicitly so a reopened tab
  never silently depends on that default." (Keep the mandatory-flag note; drop
  the stale "whatever session tmux considers current" claim.)
- `resetting-workspace/SKILL.md:110` — "Launches a headless opencode session in
  `~`" → "Launches an opencode session in `~/morning` (opened as a `morning`
  window in `main`)."
- `understanding-workspace-reset/SKILL.md:3` and body — replace "runs headless
  from ~, outside the workstation repo" with "runs in a dedicated `~/morning`
  dir and lands as a `morning` window in `main`; still reaches you over
  Telegram." Preserve the "outside any project" nuance where it explains why it
  is not tied to a project window.
- `AGENTS.md:38` — "headless morning recommendation agent" → "morning
  recommendation agent (dedicated `morning` tmux window; Telegram-reachable)".

Keep changes tight and factual; do not restructure the docs.

**Step 3: Sanity-check no stray "headless" claims remain about the agent**

Run: `grep -rn 'headless' .opencode/skills/resetting-workspace/SKILL.md assets/opencode/skills/understanding-workspace-reset/SKILL.md assets/opencode/AGENTS.md`
Expected: any remaining "headless" hits refer to the *host* (e.g. cloudbox
headless path), not to the morning agent by design.

**Step 4: Commit**

```bash
git add .opencode/skills/resetting-workspace/SKILL.md assets/opencode/skills/understanding-workspace-reset/SKILL.md assets/opencode/AGENTS.md
git commit -m "docs: morning agent lands in a dedicated window, not headless"
```

---

## Task 4: Lock the project_key derivation with a unit test

The whole fix rests on `oc-auto-attach` deriving `project_key=/home/dev/morning`,
`window_name=morning` from a `~/morning` session dir. `oc-auto-attach` has a pure
mirror of that logic under unit test — pin the new case there so a future refactor
of the derivation can't silently break the morning window.

**Files:**
- Modify: `pkgs/oc-auto-attach/test-project-key.sh` (near the existing bare-home
  case, ~`:130-138`)

**Step 1: Read the existing cases**

Run: `sed -n '110,160p' pkgs/oc-auto-attach/test-project-key.sh` to see the
`project_key` / `window_name` mirror and the `assert_eq` style (confirm exact
helper names and whether window_name is asserted separately).

**Step 2: Add the failing assertion**

Add a case mirroring the existing ones, e.g.:

```bash
assert_eq "project_key ~/morning" "$HOME/morning" "$(project_key "$HOME/morning")"
assert_eq "window_name ~/morning" "morning"       "$(window_name "$HOME/morning")"
```

(Match the actual function/assertion names found in Step 1; the mirror may
compute both in one helper.)

**Step 3: Run to verify it passes** (the derivation already behaves this way;
this is a lock-in, so it should pass immediately — that's fine, it's a
regression guard, not red-green)

Run: `bash pkgs/oc-auto-attach/test-project-key.sh`
Expected: PASS, including the two new assertions.

**Step 4: Commit**

```bash
git add pkgs/oc-auto-attach/test-project-key.sh
git commit -m "test(oc-auto-attach): pin ~/morning project_key/window_name derivation"
```

---

## Task 5: Non-destructive live verification

**Do NOT run `reset-workspace --yes` here** — it SIGKILLs all nvims and restarts
the serve pool, which would disrupt the user's live session. Verify the
attach behavior in isolation instead.

**Step 1: Deploy the rebuilt package to PATH**

This check exercises only `opencode-launch` + `oc-auto-attach` (both unchanged)
against a `~/morning` cwd, so no rebuild is required for the check itself.
Ensure `~/morning` exists:

Run: `mkdir -p "$HOME/morning"`

**Step 2: Launch a throwaway session in the morning dir**

Run: `opencode-launch "$HOME/morning" "reply with just: hi, then stop"`
Expected: prints `Session launched: ses_…` and `Directory: /home/dev/morning`.

**Step 3: Confirm the window and no hijack**

Run:
```bash
sleep 3
tmux list-windows -t main -F '#{window_index}:#{window_name} panes=#{window_panes}'
tail -12 /tmp/oc-auto-attach.log
```
Expected:
- a `morning` window is present in `main`;
- `/tmp/oc-auto-attach.log` shows
  `project_key=/home/dev/morning window_name=morning` and
  `created pane … in session main (window morning)` (NOT `matched existing pane`
  / NOT `SEND_NVIMS`);
- no existing pane's cwd was `/home/dev/morning` beforehand, so nothing was
  hijacked.

**Step 4: Clean up the throwaway session**

Run: `curl -sf -X DELETE "http://127.0.0.1:4096/session/<sid>"` (use the sid
from Step 2; try `:4097` if the session was placed there — see the launch
output's `Attach:` line for the correct serve URL). Optionally close the
`morning` tmux window if you don't want it lingering.

**Step 5: (Deferred) full end-to-end**

The full `reset-workspace --yes` path is validated at the next natural 3 AM run
(or a deliberate manual run when the user is ready to lose their current nvims).
Confirm afterward via
`journalctl -u nightly-restart-background.service` (look for
`launching recommendation session in /home/dev/morning ...`) and
`/tmp/oc-auto-attach.log` (`window_name=morning`).

---

## Landing the plane

After all tasks: run `bash pkgs/reset-workspace/test.sh` and
`nix build .#reset-workspace --no-link` one final time, then
`git pull --rebase && git push` and confirm `git status` shows up-to-date.
The deployed change reaches the box on the next
`nix run home-manager -- switch` (devbox `.#dev`, cloudbox `.#cloudbox`) — note
in the handoff that a home-manager switch is required for the new
`reset-workspace` to take effect at 3 AM.
