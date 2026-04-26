# reset-workspace TUI Restoration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Make `reset-workspace` snapshot every live opencode TUI/headless process before the kill, then re-attach each captured session via `oc-auto-attach` after the respawn — so the post-reset workspace looks like the pre-reset workspace from the user's point of view.

**Architecture:** Two new bash blocks in `pkgs/reset-workspace/default.nix`. The snapshot block sits between the existing tmux manifest snapshot (Step 1) and the user confirmation (Step 3). The restore block sits between the nvims respawn (current Step 6) and the socket verification (current Step 7). The session-deletion block (current Step 4) is removed entirely. The user-facing confirmation prompt is updated. No changes outside `pkgs/reset-workspace/default.nix`.

**Tech Stack:** Bash (writeShellApplication; `set -e -o pipefail -o nounset`), `pgrep`/`/proc` for process discovery, `oc-auto-attach` for restoration.

**Authoritative design:** `docs/plans/2026-04-25-reset-workspace-restore-design.md`

**Companion docs:**
- `docs/plans/2026-04-24-reset-workspace-design.md` — original reset-workspace design
- `docs/plans/2026-04-22-launch-auto-attach-design.md` — `oc-auto-attach` design

---

## Pre-flight: process-discovery primitives

Before touching the script, **manually verify these primitives** so we don't bake a wrong assumption into the snapshot.

### Spike 1: `pgrep` finds opencode TUIs but excludes serve

**Why:** the snapshot loops `pgrep -u dev -f opencode`, then filters out `opencode serve`.

**Run:**
```bash
pgrep -u dev -f opencode -a | head -20
```

Expected: at least one line for `opencode serve --port 4096 ...`, plus zero or more `.opencode-wrapp /home/dev/.nix-profile/bin/opencode ...` lines (one per TUI). The `serve` process MUST be distinguishable by the literal word `serve` in its argv (it is — see `cmdline=$(... | grep -qw 'serve')` in `hosts/cloudbox/configuration.nix:476`).

### Spike 2: `/proc/<pid>/cmdline` is null-delimited; argv parsing works

**Why:** the snapshot reads `/proc/<pid>/cmdline` (NUL-delimited) and parses for `-s ses_xxx`.

**Run:**
```bash
# Pick the PID of any opencode process (NOT serve)
PID=$(pgrep -u dev -f opencode | while read p; do
  cmdline=$(tr '\0' ' ' < /proc/$p/cmdline)
  if ! echo "$cmdline" | grep -qw serve; then echo "$p"; break; fi
done)
echo "candidate PID: $PID"
tr '\0' ' ' < /proc/$PID/cmdline; echo
tr '\0' ' ' < /proc/$PID/cmdline | grep -oE -- '-s ses_[A-Za-z0-9]+' || echo "(no -s arg)"
```

Expected: cmdline prints. If a `-s ses_xxx` is present, the grep extracts it. If not, "(no -s arg)" prints — which means we'll need the log-file fallback for this PID.

### Spike 3: Find the TUI's open log file via /proc/<pid>/fd

**Why:** the snapshot's fallback walks `/proc/<pid>/fd/` for an open `~/.local/share/opencode/log/*.log` file.

**Run (against the same PID from Spike 2, if it had no `-s`):**
```bash
LOG=$(ls -la /proc/$PID/fd/ 2>/dev/null | awk '/-> .*opencode\/log\/.*\.log$/ { print $NF }' | head -1)
echo "log file: $LOG"
ls -la "$LOG" 2>&1
```

Expected: a log file path under `~/.local/share/opencode/log/`. Owned by `dev`, readable.

If you see no log file: bare opencode TUIs may close stderr/stdout in some environments. The snapshot will skip these with a WARNING.

### Spike 4: Extract session id from log

**Why:** the fallback greps the log for `path=/session/(ses_[A-Za-z0-9]+)`.

**Run:**
```bash
grep -oE 'path=/session/(ses_[A-Za-z0-9]+)' "$LOG" | head -3
```

Expected: at least one line like `path=/session/ses_248fe4897ffeeQEfW6z06AxFie`. The first match is the session this TUI is bound to (it hits `GET /session/<id>` immediately after startup).

### Spike 5: `oc-auto-attach` works against an existing session

**Why:** the restore loop calls `/home/dev/.nix-profile/bin/oc-auto-attach $sid` per captured id. Confirm it works for a session that already has a TUI.

**Run (use this Claude session's id — get it from the log fd above OR from `curl http://127.0.0.1:4096/session | jq '.[0].id'`):**
```bash
SID=$(curl -sf http://127.0.0.1:4096/session | jq -r '.[0].id')
echo "test sid: $SID"
oc-auto-attach "$SID"
```

Expected: a NEW tab opens in the matching nvim, running `opencode attach --session $SID`. (If the session is already TUI-open in that pane, you'll have two tabs of the same session — that's fine for spike purposes.)

**STOP and discuss if any spike fails before starting Task 1.**

---

## Task 1: Snapshot live opencode processes (no behavior change yet)

**Goal:** Add a "Step 2 (snapshot opencode TUIs)" block to the script that runs after the tmux manifest snapshot. It should populate `OPENCODE_MANIFEST` with one session id per line. Don't change existing behavior — the new manifest is built but not yet used. Print it for visual inspection.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Locate insertion point**

Read `pkgs/reset-workspace/default.nix`. Find the end of the tmux manifest snapshot block (the `# ---- Step 1: Snapshot tmux manifest ----` block; ends with the closing `fi` after the manifest count log). New block goes immediately after.

**Step 2: Insert the snapshot block**

```bash
    # ---- Step 2: Snapshot live opencode TUIs/processes ----
    # Walk every opencode process owned by `dev`, except `opencode serve`.
    # For each, derive the session id:
    #   1. Parse `-s ses_xxx` from /proc/<pid>/cmdline if present.
    #   2. Otherwise grep the open log file for the first GET /session/ses_xxx line.
    # Skip with WARNING if neither attempt yields a valid id.
    log "snapshotting live opencode TUIs..."

    # Collect into a tmp variable; deduplicate at the end.
    OPENCODE_MANIFEST=""

    # Tolerate empty pgrep result (no matches => exit 1) under set -e.
    OC_PIDS=$(pgrep -u dev -f opencode 2>/dev/null || true)

    if [ -z "$OC_PIDS" ]; then
      log "  no opencode processes found"
    else
      for pid in $OC_PIDS; do
        # Skip if process is gone (race) or unreadable.
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        [ -n "$cmdline" ] || continue

        # Skip opencode-serve itself (we restart it, we don't restore it).
        if printf '%s' "$cmdline" | grep -qw 'serve'; then
          continue
        fi

        # Skip processes that aren't actually opencode (e.g. our own shell
        # if it happens to have "opencode" in its argv).
        if ! printf '%s' "$cmdline" | grep -q '/opencode'; then
          continue
        fi

        # Attempt 1: -s ses_xxx in argv.
        sid=$(printf '%s' "$cmdline" | grep -oE -- '-s ses_[A-Za-z0-9]+' | head -1 | awk '{print $2}' || true)

        # Attempt 2: log file fallback.
        if [ -z "$sid" ]; then
          log_file=$(ls -la "/proc/$pid/fd/" 2>/dev/null \
            | awk '/-> .*opencode\/log\/.*\.log$/ { print $NF; exit }' || true)
          if [ -n "$log_file" ] && [ -r "$log_file" ]; then
            sid=$(grep -oE 'path=/session/ses_[A-Za-z0-9]+' "$log_file" 2>/dev/null \
              | head -1 \
              | sed 's|^path=/session/||' || true)
          fi
        fi

        # Validate.
        if [ -z "$sid" ]; then
          log "  WARNING: skipping pid=$pid (no session id) cmdline=$cmdline"
          continue
        fi
        if ! printf '%s' "$sid" | grep -qxE 'ses_[A-Za-z0-9]+'; then
          log "  WARNING: skipping pid=$pid (invalid sid='$sid')"
          continue
        fi

        log "  pid=$pid -> $sid"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${sid}"$'\n'
      done

      # Deduplicate.
      OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')

      if [ -z "$OPENCODE_MANIFEST" ]; then
        OPENCODE_COUNT=0
        log "  (no session ids captured)"
      else
        OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
        log "  captured $OPENCODE_COUNT session id(s)"
      fi
    fi

    # If we never set OPENCODE_COUNT (e.g. no opencode processes at all), set it now.
    OPENCODE_COUNT=''${OPENCODE_COUNT:-0}
```

Watch the Nix `''` escaping: `''${OPENCODE_MANIFEST}` → bash `${OPENCODE_MANIFEST}`, `''${sid}` → bash `${sid}`, `''${OPENCODE_COUNT:-0}` → bash `${OPENCODE_COUNT:-0}`.

**Step 3: Verify Nix parses**

```bash
nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.toString (import /home/dev/projects/workstation/pkgs/reset-workspace { inherit pkgs; })'
```

Expected: prints `"/nix/store/...-reset-workspace"`. If it errors, your Nix escaping is wrong.

**Step 4: Apply**

```bash
cd /home/dev/projects/workstation
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5
```

Expected: succeeds.

**Step 5: Smoke test (non-destructive)**

```bash
echo n | reset-workspace 2>&1 | head -40
```

Expected: tmux manifest prints, then "snapshotting live opencode TUIs...", then for each opencode process either `pid=N -> ses_xxx` or a `WARNING: skipping pid=N (no session id)`, then `captured N session id(s)`. Then the existing "About to:" block with the OLD text (we haven't updated it yet — Task 3). Then "FATAL: aborted by user" because we typed `n`.

**Verify expectations against ground truth:**

```bash
# Ground truth: every non-serve opencode process and its session
for p in $(pgrep -u dev -f opencode); do
  cmdline=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  echo "$cmdline" | grep -qw serve && continue
  echo "$p: $cmdline"
done
```

Compare to the script's captured manifest. They should match — every non-serve opencode pid should appear in the script's per-pid logs. The captured session ids should be valid (sanity-check against `curl -sf http://127.0.0.1:4096/session/<sid> | jq '.id'` — should echo the same id back).

**Step 6: Verify clean working tree**

```bash
git status
```

Expected: only `pkgs/reset-workspace/default.nix` modified. No scratch test files.

**Step 7: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): snapshot live opencode TUIs/processes

Walks every opencode process owned by dev (excluding opencode serve),
extracts the session id from argv (-s ses_xxx) or falls back to grepping
the process's open log file for the first GET /session/<id> line.

The captured manifest is logged but not yet used \xe2\x80\x94 Task 4 wires it into
the post-respawn restore loop.

Companion design: docs/plans/2026-04-25-reset-workspace-restore-design.md"
```

---

## Task 2: Remove the DELETE-all-sessions step

**Goal:** Delete the existing Step 4 block (`fetching opencode session list... deleted N session(s)...`). Sessions must persist across resets so the new restore step has something to attach to.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Locate the block**

Find the `# ---- Step 4: Delete all opencode sessions ----` block. It starts with `log "fetching opencode session list..."` and ends after `log "  deleted $DELETED session(s), $FAILED failure(s)"`.

**Step 2: Delete the entire block**

Remove all lines from `    # ---- Step 4: Delete all opencode sessions ----` through the closing `fi` of the inner if-else. The next block (Step 5: restart opencode-serve) should immediately follow the kill+poll block.

**Step 3: Verify Nix parses**

```bash
nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.toString (import /home/dev/projects/workstation/pkgs/reset-workspace { inherit pkgs; })'
```

Expected: prints `"/nix/store/...-reset-workspace"`.

**Step 4: Apply**

```bash
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5
```

**Step 5: Smoke test**

```bash
echo n | reset-workspace 2>&1 | head -30
```

Expected: tmux snapshot, opencode snapshot, then "About to:" block. The block STILL says `2. DELETE M opencode session(s)...` — we update that text in Task 3. The script aborts on `n`. The actual delete code path is gone.

**Verify with one extra trace (don't actually run, just inspect the generated script):**

```bash
cat $(which reset-workspace) | grep -E '(DELETE|deleted .* session)'
```

Expected: only matches in the confirmation prompt text (which we haven't updated yet). NO matches like `curl -sf -X DELETE` (which is the actual deletion call).

**Step 6: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): keep opencode sessions across reset

Sessions must persist so the upcoming restore step (Task 4) has something
to attach to. The DELETE-all-sessions block from the original Task 4 is
removed.

Note: the user-facing confirmation prompt still mentions deletion \xe2\x80\x94 Task 3
updates that. DB growth is now monotonic; a sibling cleanup job is filed
as a separate follow-up (NOT this work).

Companion design: docs/plans/2026-04-25-reset-workspace-restore-design.md"
```

---

## Task 3: Update the confirmation prompt text

**Goal:** Make the `About to:` block accurately reflect the new pipeline. Drop the DELETE line, add a "Restore K opencode TUI(s)" line.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Locate the block**

Find the `# ---- Step 2: Confirm with user ----` block. Specifically the four `log "  N. ..."` lines starting with `1. SIGKILL`.

**Step 2: Replace the four log lines**

Old:
```bash
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. DELETE $SESSION_COUNT opencode session(s) via HTTP API"
    log "  3. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  4. Respawn nvims in $MANIFEST_COUNT pane(s)"
    log ""
```

New:
```bash
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  3. Respawn nvims in $MANIFEST_COUNT pane(s)"
    log "  4. Restore $OPENCODE_COUNT opencode TUI(s) via oc-auto-attach"
    log ""
```

Also delete the now-unused `SESSION_COUNT` line above this (the `SESSION_COUNT=$(curl -sf "$OPENCODE_URL/session" 2>/dev/null | jq -r 'length' 2>/dev/null || echo "?")` line). It's dead code now.

**Step 3: Verify Nix parses + apply**

```bash
nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.toString (import /home/dev/projects/workstation/pkgs/reset-workspace { inherit pkgs; })'
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5
```

**Step 4: Smoke test**

```bash
echo n | reset-workspace 2>&1 | head -30
```

Expected: the "About to:" block now reads:
```
About to:
  1. SIGKILL N nvim/nvims process(es)
  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)
  3. Respawn nvims in N pane(s)
  4. Restore K opencode TUI(s) via oc-auto-attach
```

Where `K` is whatever Task 1's snapshot captured. Aborts on `n`.

**Step 5: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): update confirmation prompt for new pipeline

Drops the DELETE line (Task 2 removed deletion). Adds the restore line.
Removes dead SESSION_COUNT computation that fed the old DELETE line."
```

---

## Task 4: Restore opencode TUIs via oc-auto-attach

**Goal:** After the nvims respawn step, iterate `OPENCODE_MANIFEST` and call `oc-auto-attach` for each session id, serially.

**Files:**
- Modify: `pkgs/reset-workspace/default.nix`

**Step 1: Locate insertion point**

Find the end of the `# ---- Step 6: Respawn nvims in each manifest pane ----` block (closes with `fi` after the inner while loop). New block goes immediately after, BEFORE the `# ---- Step 7: Verify nvim sockets exist ----` block.

**Step 2: Insert the restore block**

```bash
    # ---- Step 6.5: Restore opencode TUIs via oc-auto-attach ----
    # OPENCODE_MANIFEST was captured in Step 2 (one session id per line).
    # oc-auto-attach handles its own polling for nvim socket + helper
    # readiness, project-key resolution, and pane creation.
    if [ "$OPENCODE_COUNT" -gt 0 ]; then
      log "restoring $OPENCODE_COUNT opencode TUI(s)..."
      while IFS= read -r sid; do
        [ -n "$sid" ] || continue
        log "  restoring $sid"
        # oc-auto-attach exits 0 even on internal failure (by design).
        # Pipe its own stderr through to our log for visibility.
        if ! /home/dev/.nix-profile/bin/oc-auto-attach "$sid" 2>&1; then
          log "  WARNING: oc-auto-attach $sid returned non-zero"
        fi
      done <<< "$OPENCODE_MANIFEST"
    else
      log "no opencode TUIs to restore"
    fi
```

**Step 3: Verify Nix parses + apply**

```bash
nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.toString (import /home/dev/projects/workstation/pkgs/reset-workspace { inherit pkgs; })'
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -5
```

**Step 4: Verify the block lands in the generated script**

```bash
cat $(which reset-workspace) | grep -E '(restoring .* opencode|oc-auto-attach "\$sid")'
```

Expected: at least the line `log "  restoring $sid"` and the `if ! /home/dev/.nix-profile/bin/oc-auto-attach "$sid" 2>&1; then`.

**Step 5: Non-destructive smoke test**

```bash
echo n | reset-workspace 2>&1 | head -30
```

Expected: aborts at the prompt before any restoration happens. Just confirms we didn't break the early-abort path.

**Step 6: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): restore opencode TUIs after respawn

Iterates OPENCODE_MANIFEST (captured pre-kill in Task 1) and invokes
/home/dev/.nix-profile/bin/oc-auto-attach for each session id, serially.
oc-auto-attach handles its own polling, pane resolution, and tab
creation; we just feed it the ids and propagate its stderr.

Companion design: docs/plans/2026-04-25-reset-workspace-restore-design.md"
```

---

## Task 5: End-to-end verification via systemd unit

**Goal:** Trigger `nightly-restart-background.service` with a known set of opencode TUIs open. Verify the journal shows snapshot \xe2\x86\x92 kill \xe2\x86\x92 restart \xe2\x86\x92 respawn \xe2\x86\x92 restore. Visually verify post-reset that the captured TUIs reappear.

**Files:** none modified.

**Step 1: Confirm preconditions**

```bash
echo "=== nvim panes ==="
tmux list-panes -a -F '#{pane_id} #{window_name} #{pane_current_command}' | grep -E '(nvim|nvims)'
echo
echo "=== live opencode processes (excluding serve) ==="
for p in $(pgrep -u dev -f opencode); do
  c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  echo "$c" | grep -qw serve && continue
  echo "$p: $c"
done
```

Expected: \xe2\x89\xa54 nvim panes; \xe2\x89\xa51 non-serve opencode (this Claude session). Note the session ids you expect to see restored.

**Step 2: Trigger the unit**

```bash
sudo systemctl start nightly-restart-background.service
```

**Step 3: Watch the journal**

```bash
journalctl -u nightly-restart-background.service --since '60 seconds ago' --no-pager
```

Expected sequence:
- `[reset-workspace] snapshotting tmux panes ...`
- `[reset-workspace] found N nvim/nvims pane(s): ...`
- `[reset-workspace] snapshotting live opencode TUIs...`
- `[reset-workspace]   pid=... -> ses_...` (one per non-serve opencode)
- `[reset-workspace]   captured K session id(s)`
- `[reset-workspace] About to: ...`  (with the new 4-item list)
- `[reset-workspace] (--yes: skipping confirmation)`
- `[reset-workspace] killing all nvim/nvims processes (SIGKILL)...`
- `[reset-workspace] polling panes for return to shell...`
- `[reset-workspace]   %N: now running bash`  (one per pane)
- `[reset-workspace] restarting opencode-serve.service...`
- `[reset-workspace] polling /global/health for serve readiness...`
- `[reset-workspace]   serve healthy`
- `[reset-workspace] respawning nvims in N pane(s)...`
- `[reset-workspace]   %N: sent 'cd ... && nvims'`  (one per pane)
- `[reset-workspace] restoring K opencode TUI(s)...`
- `[reset-workspace]   restoring ses_...`
- `[oc-auto-attach] session ses_... dir=...`
- `[oc-auto-attach] project_key=... window_name=...`
- `[oc-auto-attach] matched existing pane %N` OR `created new pane %N`
- `[oc-auto-attach] socket=/tmp/nvim-N.sock`
- `[oc-auto-attach] nvim at /tmp/nvim-N.sock is ready`
- `[oc-auto-attach] tab opened in pane %N for ses_...`
- `[reset-workspace] verifying nvim sockets...`
- `[reset-workspace]   %N: socket /tmp/nvim-N.sock ✓`  (one per pane)
- `[reset-workspace] reset-workspace complete`

Unit final state: `Result=success`, `ExecMainStatus=0`.

**Step 4: Visually verify**

For each session id you noted in Step 1, switch to its pane (or the pane oc-auto-attach selected) and confirm the opencode TUI is back on that session.

The Claude session you're running THIS plan in will also restart \xe2\x80\x94 you'll see the TUI flicker, then reattach. After restoration, your session and any others should be live.

**Step 5: Recovery if anything goes wrong**

If the journal shows a failure at any step: the existing unit will exit non-zero. Recover by:
1. Manually re-running `nvims` in any pane that didn't respawn.
2. Manually re-running `opencode -s ses_xxx` (or `opencode attach http://127.0.0.1:4096 --session ses_xxx`) for any TUI that didn't restore.

**Step 6: Push everything**

```bash
cd /home/dev/projects/workstation
git pull --rebase
git push
git status
```

Expected: `git status` shows `up to date with origin/main`.

---

## Task 6: Documentation update

**Goal:** Update the `resetting-workspace` skill to reflect the new pipeline (no more deletion; new restoration step).

**Files:**
- Modify: `.opencode/skills/resetting-workspace/SKILL.md`

**Step 1: Update the "What it does" section**

Open `.opencode/skills/resetting-workspace/SKILL.md`. The current numbered list has:
```
1. Snapshots the tmux panes currently running `nvim`/`nvims`.
2. Confirms with the user (skip with `--yes`).
3. SIGKILLs all `nvim` processes owned by `dev`.
4. DELETEs every opencode session via the HTTP API.
5. Restarts `opencode-serve.service` (passwordless sudo).
6. Respawns `nvims` in each manifest pane (with original cwd).
7. Verifies each `/tmp/nvim-${PANE#%}.sock` exists.
```

Replace with:
```
1. Snapshots the tmux panes currently running `nvim`/`nvims`.
2. Snapshots live opencode TUIs/processes (one session id per non-serve `opencode` process).
3. Confirms with the user (skip with `--yes`).
4. SIGKILLs all `nvim` processes owned by `dev`.
5. Restarts `opencode-serve.service` (passwordless sudo).
6. Respawns `nvims` in each manifest pane (with original cwd).
7. Restores each captured opencode TUI via `oc-auto-attach <session-id>`.
8. Verifies each `/tmp/nvim-${PANE#%}.sock` exists.
```

**Step 2: Update the "Caveats" section**

The current caveat reads:
```
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will be killed when their session is deleted. Don't run during important headless work.
```

Replace with:
```
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will have their PROCESSES killed by the SIGKILL pass and their session ids captured. Post-respawn, those sessions get a TUI restored via `oc-auto-attach` \xe2\x80\x94 but the headless worker is NOT re-launched (we only restore TUIs, not arbitrary headless invocations). Sessions persist in the DB.
```

**Step 3: Add a "Sessions persist" subsection (after "Caveats")**

```markdown
## Sessions persist across resets

Unlike the original design, `reset-workspace` no longer DELETEs opencode sessions. Sessions accumulate in the DB across resets (today: ~1500 sessions). A sibling cleanup job for stale session pruning is on the backlog \xe2\x80\x94 see git history of this skill or `bd` for details.
```

**Step 4: Commit**

```bash
git add .opencode/skills/resetting-workspace/SKILL.md
git commit -m "docs(skills): document opencode TUI restoration in reset-workspace"
```

**Step 5: Push**

```bash
git push
git status
```

---

## Risk register

| What could go wrong | How we'd catch it | Recovery |
|---|---|---|
| `pgrep -u dev -f opencode` matches a non-opencode process whose argv contains "opencode" | The `printf '%s' "$cmdline" \| grep -q '/opencode'` filter rejects anything not running an opencode binary. Manual verification in spike 1. | Tighten the filter regex; ship a fix-up commit. |
| Log-file fallback finds the wrong log (e.g., a stale log left open from an earlier crashed process) | The first `path=/session/<id>` line in a log is from the TUI's own startup. Stale fds shouldn't appear in `/proc/$pid/fd/` unless the kernel is broken. | If we see consistent wrong captures, switch fallback to "most-recent log file by mtime" or query the DB instead. |
| `oc-auto-attach` mis-routes a session to the wrong pane (e.g., two sessions in the same project both end up as tabs in one nvim) | This is the existing `oc-auto-attach` behavior (multiple sessions in same project = multiple tabs in one nvim). It's actually the desired outcome. | None needed. |
| Restoration races with the user re-launching opencode manually post-reset | The user gets two TUIs for the same session, both attached to the same backend. opencode handles concurrent attach gracefully (existing behavior). | None needed. |
| DB grows unbounded with deletion removed | Visible in `nix run nixpkgs#sqlite -- ~/.local/share/opencode/opencode.db "SELECT count(*) FROM session"`. | Separate cleanup job (out of scope; file follow-up). |
| Snapshot block crashes the script before kill (e.g., `pgrep` itself errors) | Script exits non-zero before any destructive action. User sees a clear error. | The `\|\| true` and explicit guards on every external call should prevent this; if it happens, fix the offending guard and re-ship. |
| `oc-auto-attach` segfaults / hangs | Each call is bounded by oc-auto-attach's own `timeout 5` calls. Worst case: 5s+5s = 10s per session. With 5 sessions = 50s. | Acceptable. If pathological, parallelize per design's open question. |
