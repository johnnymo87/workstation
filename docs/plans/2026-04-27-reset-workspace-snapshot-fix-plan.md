# reset-workspace snapshot fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `reset-workspace` step 2's session-snapshot logic so it reliably captures `/launch` + `opencode-launch` sessions via a strict argv match on `opencode attach --session ses_xxx`, drops the broken log-file fallback, and adds observability for bare TUIs that won't be restored.

**Architecture:** Modify only the body of step 2 in `pkgs/reset-workspace/default.nix`. Steps 3–7 and `pkgs/oc-auto-attach/default.nix` are untouched. Update `.opencode/skills/resetting-workspace/SKILL.md` to document the new contract. Verify by deploying via home-manager and running `reset-workspace --yes` live.

**Tech Stack:** Bash (writeShellApplication via Nix), pgrep, /proc, tmux, nix-build, home-manager.

**Design:** `docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md`

**Bead:** workstation-0gu

---

### Task 1: Replace step 2 session-snapshot block

**Files:**
- Modify: `pkgs/reset-workspace/default.nix:126-213` (the `# ---- Step 2: Snapshot live opencode TUIs/processes ----` block, ending just before `# If we never set OPENCODE_COUNT (e.g. no opencode processes at all)...`)

**Step 1: Read the current block**

Read `pkgs/reset-workspace/default.nix` lines 126–213 to confirm the boundaries match. The block starts with the comment `# ---- Step 2: Snapshot live opencode TUIs/processes ----` and ends with the line `OPENCODE_COUNT=''${OPENCODE_COUNT:-0}` (line 213).

**Step 2: Replace the block with the new logic**

Use the Edit tool to replace the entire step-2 body. The new content:

```nix
    # ---- Step 2: Snapshot live opencode attach clients ----
    # Restoration scope: ONLY sessions launched via Telegram /launch or
    # `opencode-launch` CLI. Both produce TUI processes with cmdline of the
    # form `<binary>/opencode attach <url> --session ses_xxx` -- the sid is
    # reliably in argv. Bare `:te opencode` TUIs (no --session) are NOT
    # restored across reset; they are intended for ad-hoc work. See
    # docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md
    log "snapshotting live opencode attach clients..."

    OPENCODE_MANIFEST=""
    OPENCODE_BARE_COUNT=0  # observability: bare TUIs we are NOT restoring

    # Loose pgrep + strict per-pid validation. Strict regex anchors on the
    # binary path prefix, the literal `attach` subcommand, an http(s) url,
    # and a syntactically valid sid -- false positives are essentially
    # impossible.
    OC_ATTACH_PIDS=$(pgrep -u dev -f 'opencode attach' 2>/dev/null || true)
    for pid in $OC_ATTACH_PIDS; do
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
      [ -n "$cmdline" ] || continue

      if [[ "$cmdline" =~ ^[^[:space:]]+/opencode[[:space:]]+attach[[:space:]]+https?://[^[:space:]]+[[:space:]]+--session[[:space:]]+(ses_[A-Za-z0-9]+)$ ]]; then
        sid="''${BASH_REMATCH[1]}"
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
        log "  pid=$pid sid=$sid cwd=$cwd"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${sid}"$'\n'
      else
        log "  WARNING: skipping pid=$pid (no --session in argv) cmdline=$cmdline"
      fi
    done

    # Observability: enumerate bare opencode TUIs that will NOT be restored.
    # We log them so each reset's journal makes it obvious what was dropped.
    OC_ALL_PIDS=$(pgrep -u dev -f opencode 2>/dev/null || true)
    for pid in $OC_ALL_PIDS; do
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
      exe_base=$(basename "$exe")
      if ! printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
        continue
      fi
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
      [ -n "$cmdline" ] || continue
      arg2=$(printf '%s' "$cmdline" | awk '{print $2}')
      # Skip serve (we restart it, not restore it) and attach clients
      # (already enumerated in the strict loop above).
      [ "$arg2" = "serve" ] && continue
      [ "$arg2" = "attach" ] && continue
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
      log "  WARNING: bare opencode TUI pid=$pid cwd=$cwd will NOT be restored across reset (use /launch or opencode-launch for restorable sessions)"
      OPENCODE_BARE_COUNT=$((OPENCODE_BARE_COUNT + 1))
    done

    # Dedupe captured sids.
    OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')
    if [ -z "$OPENCODE_MANIFEST" ]; then
      OPENCODE_COUNT=0
    else
      OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
    fi

    log "  captured $OPENCODE_COUNT restorable session(s); $OPENCODE_BARE_COUNT bare TUI(s) skipped"
```

**Step 3: Verify the resulting file is well-formed**

```bash
nix-instantiate --parse pkgs/reset-workspace/default.nix > /dev/null
```

Expected: command exits 0 with no output.

Then check the rendered shell script via build:

```bash
nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>&1 | tail -3
```

Expected: prints a `/nix/store/...-reset-workspace` path with no errors.

(Use `aarch64-linux` because cloudbox is ARM. If the package isn't exposed at that flake attribute, instead use `nix build --no-link .#homeConfigurations.cloudbox.activationPackage` later in Task 3 — that builds the whole home env which includes reset-workspace.)

**Step 4: Inspect the rendered script for the new step 2**

```bash
STORE=$(nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>/dev/null) && grep -A 3 'snapshotting live opencode attach clients' "$STORE/bin/reset-workspace" | head -10
```

Expected: see the new "snapshotting live opencode attach clients..." log line and the `OPENCODE_BARE_COUNT=0` initialization.

If this nix attribute path doesn't exist, fall back to grepping the deployed binary in Task 3 instead — that's the authoritative on-PATH version.

**Step 5: Commit (code change only, no deploy yet)**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "fix(reset-workspace): snapshot sessions via attach-client argv (workstation-0gu)

Replace step 2's session-snapshot logic with strict pgrep on
'opencode attach.*--session ses_xxx' pattern. Drop the broken
log-file fallback that silently failed for stuck/idle bare TUIs.
Add observability WARNING per bare TUI that will not be restored.

Narrowed contract: only /launch + opencode-launch sessions survive
reset. Bare ':te opencode' TUIs are explicitly out of scope.

See docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md
"
```

---

### Task 2: Update resetting-workspace skill doc

**Files:**
- Modify: `.opencode/skills/resetting-workspace/SKILL.md`

**Step 1: Read the current skill**

```bash
cat .opencode/skills/resetting-workspace/SKILL.md | head -80
```

Note where the existing "Cgroup gotcha" section lives so the new "What survives a reset" section can sit alongside it (typically near the top, in the contract / overview area).

**Step 2: Add the new section**

Insert a new section titled `## What survives a reset` (or strengthen an existing equivalent). Content:

```markdown
## What survives a reset

reset-workspace restores opencode TUIs **only** for sessions launched via:

- Telegram `/launch`
- `opencode-launch` (CLI)

Both produce a TUI process with cmdline `<binary>/opencode attach <url>
--session ses_xxx`. The sid is captured from `/proc/<pid>/cmdline` during
step 2; if the process is alive at snapshot time, the session is restored
into a tmux window for its project's cwd via `oc-auto-attach`.

**Bare `:te opencode` TUIs (no `--session` in argv) are NOT restored.**
They are intended for ad-hoc / throwaway work. To make a session
re-survivable, launch it via `/launch` or `opencode-launch`.

Each reset's journal includes a summary line of the form:

```
captured N restorable session(s); M bare TUI(s) skipped
```

If you expected a session to be restored and it wasn't, check the journal
for `pid=... sid=... cwd=...` (success) vs `WARNING: bare opencode TUI
pid=... cwd=...` (skipped) lines.

See `docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md` for the
rationale.
```

**Step 3: Verify the markdown renders correctly**

```bash
head -100 .opencode/skills/resetting-workspace/SKILL.md
```

Expected: the new section is present, headings are well-formed, fenced code
blocks are balanced.

**Step 4: Commit (skill doc only)**

```bash
git add .opencode/skills/resetting-workspace/SKILL.md
git commit -m "docs(skill): document reset-workspace session-survival contract (workstation-0gu)

Adds 'What survives a reset' section explaining that only /launch and
opencode-launch sessions are restored across reset; bare ':te opencode'
TUIs are killed and not restored. Points readers at the journal summary
line for visibility.
"
```

---

### Task 3: Deploy via home-manager

**Files:** none (deployment, not code)

**Step 1: Run home-manager switch**

```bash
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -20
```

Expected: `Activation finished` line; no errors. The new `reset-workspace`
binary lands at `~/.nix-profile/bin/reset-workspace`.

**Step 2: Verify the on-PATH binary has the new step-2 logic**

```bash
which reset-workspace
grep -c 'snapshotting live opencode attach clients' "$(which reset-workspace)"
grep -c 'bare opencode TUI' "$(which reset-workspace)"
grep -c 'snapshotting live opencode TUIs/processes' "$(which reset-workspace)"
```

Expected:
- First grep: `1` (new comment is present)
- Second grep: `1` or `2` (the bare-TUI WARNING line and possibly a comment)
- Third grep: `0` (the OLD comment is gone)

If the third grep returns non-zero, the deploy didn't pick up the new derivation — investigate before proceeding.

**Step 3: Verify the detach mechanism is still present (regression check on workstation-pqu's fix)**

```bash
grep -A 1 'Process detachment: re-exec into a fresh user systemd scope' "$(which reset-workspace)" | head -5
```

Expected: see the "Process detachment" comment followed by the always-detach block. This must come BEFORE the arg-parser while-loop (per workstation-pqu).

**Step 4: No commit needed** — deployment is a side effect, not a code change.

---

### Task 4: Live verification (orchestrator runs inline)

**Files:** none

**WARNING — CRITICAL LANDMINE:** Per workstation-pqu's notes, do NOT delegate
this step to a subagent. Run it inline from the orchestrator. The subagent
implementer in a prior session ignored explicit "DO NOT RUN" instructions and
destroyed the user's nvim session. The orchestrator runs reset-workspace
directly.

**Step 1: Get explicit user go-ahead**

Ask the user: "Ready for live test? This will kill your current Claude TUI
session (it's a bare `:te opencode`). I'll print the journal command for you
to monitor afterward, and you'll manually re-attach via `:te opencode -s
ses_2352361a3ffebHZ75RZLhPa1Hk` (or whatever the orchestrator's current sid
is) to resume the conversation."

WAIT for a clear "yes" before proceeding.

**Step 2: Capture state for post-mortem comparison**

Before running reset, capture:
- Current opencode TUI PIDs and their argv:
  ```bash
  for pid in $(pgrep -u dev -f opencode); do
    exe_base=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
    if printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
      cwd=$(readlink /proc/$pid/cwd 2>/dev/null)
      echo "pid=$pid exe=$exe_base cwd=$cwd cmdline=$cmdline"
    fi
  done | tee /tmp/reset-workspace-pre.txt
  ```
- Current orchestrator session ID (from log file path):
  ```bash
  ls -la /proc/self/fd/ 2>/dev/null | awk '/-> .*opencode\/log\/.*\.log$/ { print $NF; exit }'
  ```
  Then grep the log for the sid:
  ```bash
  grep -oE 'path=/session/ses_[A-Za-z0-9]+' "<log-path>" | head -1
  ```
  Print the resulting sid for the user so they know what to re-attach to.

**Step 3: Run reset-workspace inline**

```bash
reset-workspace --yes
```

Note: this WILL kill the orchestrator's TUI process. The bash tool may
return "User aborted" or a connection-dropped error — that's the
normal-operation symptom, not a real abort (per workstation-pqu's
landmines).

**Step 4: User-side verification**

User reattaches the new TUI session to opencode-serve (manually, via `:te
opencode -s <sid>`). On resume, the assistant in the new session runs:

```bash
journalctl --user -u 'run-r*.scope' --since "5 minutes ago" --no-pager 2>&1 | grep -E '\[reset-workspace\]|\[oc-auto-attach\]' | head -50
```

Or fall back to the global journal scoped to the dev user:

```bash
journalctl --since "5 minutes ago" --no-pager _UID=1000 2>&1 | grep -E '\[reset-workspace\]|\[oc-auto-attach\]' | head -50
```

Expected output:
- `[reset-workspace] snapshotting live opencode attach clients...` (the new
  log line)
- One `pid=X sid=ses_xxx cwd=/home/dev/projects/...` line per `/launch` or
  `opencode-launch` session that was alive
- One `WARNING: bare opencode TUI pid=X cwd=...` per bare TUI being skipped
- `captured N restorable session(s); M bare TUI(s) skipped` summary
- `restoring sid=...` lines under step 6.5 for each captured sid
- `[oc-auto-attach]` lines from oc-auto-attach itself
- `reset-workspace complete`

Then check tmux state:

```bash
tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} (#{window_panes} panes)'
```

Expected: a tmux window exists for each project cwd that had a captured
session, and `tmux list-panes -t :<window-name>` shows nvim running with
the expected `:te opencode attach --session ses_xxx` tab.

**Step 5: Commit any incidental fixups**

If verification revealed a small bug needing patching (e.g., a typo in the
log message), make the fix and commit. Otherwise no commit.

---

### Task 5: Close out

**Files:** none

**Step 1: Update bead workstation-0gu**

```bash
bd close workstation-0gu --reason "Fixed via strict pgrep on attach-client argv pattern. Step 2 now captures /launch + opencode-launch sessions reliably, skips bare TUIs with observability WARNING. Verified live $(date +%Y-%m-%d). Design: docs/plans/2026-04-27-reset-workspace-snapshot-fix-design.md. Plan: docs/plans/2026-04-27-reset-workspace-snapshot-fix-plan.md."
```

**Step 2: Sync beads + push**

```bash
bd sync
git add .beads/
git commit -m "chore(beads): close workstation-0gu (reset-workspace snapshot fix)" 2>&1 | tail -3 || echo "(no changes to commit)"
git pull --rebase
git push
git status
```

Expected: `Your branch is up to date with 'origin/main'`, working tree clean.

**Step 3: Optionally file a follow-up bead for unit tests**

Per design doc "Out of scope" — file a low-priority bead if we want to track
adding shellcheck-bats coverage for reset-workspace.

```bash
bd create "Add shellcheck-bats unit tests for reset-workspace step 2 snapshot logic" --type=task --priority=3 --description "Defer-from workstation-0gu (which used live verification). Mock pgrep, /proc, and tmux; assert that strict regex captures /launch + opencode-launch argv forms and rejects bare TUIs / shell echoes / serve commands. Currently zero unit-test coverage on pkgs/reset-workspace/default.nix."
```

---

## Done when

- `pkgs/reset-workspace/default.nix` step 2 uses the new strict-pgrep logic.
- `.opencode/skills/resetting-workspace/SKILL.md` documents the new contract.
- Live `reset-workspace --yes` shows expected journal output and tmux state.
- `workstation-0gu` closed, all commits pushed, working tree clean.
