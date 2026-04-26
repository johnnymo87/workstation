# reset-workspace cgroup survival Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `reset-workspace` survive the `opencode-serve.service` restart it triggers when invoked from inside that service's cgroup, so all post-restart steps (respawn nvims, restore TUIs, verify sockets) actually run.

**Architecture:** Add a self-detach step at the script's entry. If `/proc/self/cgroup` contains `/opencode-serve.service`, re-exec via `systemd-run --user --scope` into a transient user scope outside the danger cgroup. All other invocations skip the re-exec.

**Tech Stack:** Bash (writeShellApplication), systemd-run --user --scope, NixOS cgroup v2.

**Authoritative companions:**
- Design: `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md`
- Bead: `workstation-pqu`

---

## Compaction-resilience checklist

If this plan resumes after compaction, the next agent should verify:
- [ ] `bd show workstation-pqu` is in_progress and has the root-cause notes block.
- [ ] Design doc at `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` is committed and pushed.
- [ ] No uncommitted changes to `pkgs/reset-workspace/default.nix` (Task 1) or `.opencode/skills/resetting-workspace/SKILL.md` (Task 4) — if there are, finish whichever task is in progress before starting fresh ones.
- [ ] Confirm we are still on cloudbox (`hostname` → `cloudbox`) and the cwd is `~/projects/workstation`.

---

## Task 1: Add cgroup-survival re-exec to reset-workspace

**Files:**
- Modify: `pkgs/reset-workspace/default.nix:13-66` (insert new block before the existing flock re-exec block)

**Step 1: Read the current file**

Run: `cat pkgs/reset-workspace/default.nix`
Confirm lines 56–66 are the existing flock re-exec block (begins with `# ---- Concurrency: re-exec under flock if not already locked ----`).

**Step 2: Add `systemd` to runtimeInputs**

Edit `pkgs/reset-workspace/default.nix`, change the `runtimeInputs` list to add `systemd`:

```nix
  runtimeInputs = with pkgs; [
    curl
    jq
    tmux
    procps         # pkill, pgrep
    util-linux     # flock
    coreutils      # timeout
    systemd        # systemd-run for cgroup re-exec
  ];
```

**Step 3: Insert the cgroup re-exec block**

In `pkgs/reset-workspace/default.nix`, immediately before the line `# ---- Concurrency: re-exec under flock if not already locked ----`, insert this block (note the `''` escapes for Nix):

```bash
    # ---- Cgroup survival: re-exec out of opencode-serve.service's cgroup ----
    # If we're running inside opencode-serve.service's cgroup (because we were
    # invoked from an agent's bash tool whose TUI is attached to that service),
    # the script will be SIGTERM'd mid-flight when it restarts opencode-serve
    # (default KillMode=control-group kills the whole cgroup). Re-exec via
    # `systemd-run --user --scope` to relocate into a fresh user-side scope
    # outside the danger cgroup. See:
    #   docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md
    if [ "''${RESET_WORKSPACE_DETACHED:-}" != "1" ] \
       && grep -qF '/opencode-serve.service' /proc/self/cgroup 2>/dev/null; then
      log "detected opencode-serve.service cgroup; re-execing in user scope..."
      export RESET_WORKSPACE_DETACHED=1
      # --collect: GC the transient scope as soon as we exit.
      # --quiet: suppress the "Running scope as unit run-rXXX.scope" banner.
      # --pty: preserve a TTY so the [y/N] prompt path still works (no-op with --yes).
      # XDG_RUNTIME_DIR: required for --user (path to the user manager's socket).
      # Fall back to running in-place if systemd-run is unavailable or fails.
      if ! exec env XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
           systemd-run --user --scope --collect --quiet --pty -- "$0" "$@"; then
        log "WARNING: systemd-run --user --scope failed; running in-place (script may die mid-flight)"
        # Continue past the re-exec block. The flock re-exec below will still run.
      fi
    fi

```

The blank line at the end is intentional — it separates this block from the flock block visually.

**Step 4: Verify the file evaluates as a Nix expression**

Run: `nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.toString (import /home/dev/projects/workstation/pkgs/reset-workspace { inherit pkgs; })'`

Expected: prints `"/nix/store/...-reset-workspace"`. If it errors with a parse/escaping issue, your `''${...}` Nix escapes for shell variable expansion are wrong — re-check.

**Step 5: Build the package and read the generated script**

Run:
```bash
nix build --no-link --print-out-paths .#reset-workspace 2>&1
```

Expected: prints `/nix/store/...-reset-workspace`.

Then:
```bash
cat $(nix build --no-link --print-out-paths .#reset-workspace)/bin/reset-workspace | head -100
```

Expected: shows the generated bash script with the new cgroup re-exec block at the top, before the flock block. Verify the `''` Nix escapes flattened correctly into single `$` shell expansions (e.g. `${RESET_WORKSPACE_DETACHED:-}`, not `${''RESET_WORKSPACE_DETACHED:-}'`).

**Step 6: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "fix(reset-workspace): re-exec into user scope when in opencode-serve cgroup

The script dies mid-flight when invoked from an opencode-agent bash
tool whose TUI is attached to opencode-serve.service: the systemctl
restart kills the whole cgroup (default KillMode=control-group)
including the script itself. Steps 1-5 run, steps 6-7 (respawn nvims,
restore TUIs) do not.

Detect at entry whether /proc/self/cgroup contains opencode-serve.service.
If so, re-exec via 'systemd-run --user --scope' to relocate into a fresh
user-side scope outside the danger cgroup. All other invocation paths
(tmux pane, nightly cron, standalone TUI) skip the re-exec and run in-place.

Closes part of workstation-pqu (Task 1 of 4).

Companion design: docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md"
```

---

## Task 2: Build into home-manager and verify the new binary is on PATH

**Files:**
- (no edits — just apply the existing build)

**Step 1: Apply home-manager**

Run: `nix run home-manager -- switch --flake .#cloudbox`

Expected: completes successfully, swaps `~/.nix-profile/bin/reset-workspace` to the new derivation.

**Step 2: Verify the new binary contains the new block**

Run: `grep -A1 'Cgroup survival' $(readlink -f ~/.nix-profile/bin/reset-workspace)`

Expected: prints the comment header from the new block.

**Step 3: Verify --help still works (smoke test the script doesn't crash on parse)**

Run: `reset-workspace --help`

Expected: prints the existing usage banner. Exit code 0.

---

## Task 3: Manual reproduction — verify each scenario works

For this task, we manually walk the verification matrix from the design doc. We do NOT use `reset-workspace --yes` — we use a **diagnostic-only invocation** that exits before any destructive step. To make this safe, we set up a minimal test wrapper that runs only the cgroup detection + re-exec logic and prints the resulting cgroup, then exits.

**Files:**
- (no edits — just verification)

**Step 1: Build the diagnostic test wrapper**

Create `/tmp/reset-workspace-cgroup-check.sh`:
```bash
#!/usr/bin/env bash
# Minimal mirror of reset-workspace's cgroup-survival logic, prints
# resulting cgroup and exits. Safe to run anywhere — no destructive ops.
log() { printf '[diag] %s\n' "$*" >&2; }

if [ "${RESET_WORKSPACE_DETACHED:-}" != "1" ] \
   && grep -qF '/opencode-serve.service' /proc/self/cgroup 2>/dev/null; then
  log "DETECTION: in opencode-serve.service cgroup, re-execing..."
  export RESET_WORKSPACE_DETACHED=1
  exec env XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
       systemd-run --user --scope --collect --quiet --pty -- "$0" "$@"
fi

log "FINAL CGROUP:"
cat /proc/self/cgroup
log "FINAL EUID: $(id -u)"
```

Make executable: `chmod +x /tmp/reset-workspace-cgroup-check.sh`

**Step 2: Verification row 1 — bash shell in tmux pane**

Run from THIS agent's bash tool (which is in tmux's cgroup):
```bash
/tmp/reset-workspace-cgroup-check.sh
```

Expected output includes:
- NO "DETECTION: in opencode-serve.service cgroup" line.
- `FINAL CGROUP: 0::/user.slice/user-1000.slice/user@1000.service/.../tmux-spawn-*.scope`

Confirms: tmux-pane invocations are not re-exec'd.

**Step 3: Verification row 2 — invocation inside opencode-serve.service cgroup**

This is the critical row. We can't directly invoke the script from an agent attached to opencode-serve without tearing down our current session, so we synthesize the conditions: launch a sacrificial bash inside opencode-serve's cgroup via `systemd-run --pipe --wait --collect`.

Wait — that runs a command in a new transient unit, not inside opencode-serve. Better approach: temporarily inject a bash subprocess into opencode-serve.service's cgroup using `systemd-run --slice=<existing>` is not the right tool either. The correct primitive is `systemctl set-property` on a transient unit pointing at opencode-serve.service's cgroup, but that's overkill.

Simplest reliable approach: use `cgexec`-style cgroup migration via the cgroup v2 sysfs:

```bash
# Find opencode-serve.service's cgroup directory
SERVE_CG=/sys/fs/cgroup/system.slice/opencode-serve.service
ls -la $SERVE_CG/cgroup.procs 2>&1

# Spawn a sacrificial bash, get its pid, migrate it into opencode-serve.service's cgroup,
# run our diagnostic, observe.
( bash -c '
  echo "PID=$$, before:"
  cat /proc/self/cgroup
  echo $$ | sudo tee /sys/fs/cgroup/system.slice/opencode-serve.service/cgroup.procs >/dev/null
  echo "PID=$$, after:"
  cat /proc/self/cgroup
  /tmp/reset-workspace-cgroup-check.sh
' )
```

Expected:
- "before:" line shows tmux scope.
- "after:" line shows `0::/system.slice/opencode-serve.service`.
- Diagnostic output includes "DETECTION: in opencode-serve.service cgroup, re-execing..."
- "FINAL CGROUP:" shows `/user.slice/user-1000.slice/user@1000.service/app.slice/run-r*.scope` (a fresh user scope, NOT inside opencode-serve.service).

**If `sudo tee` requires a password:** that's a problem on devbox but should be passwordless on cloudbox via `security.sudo.wheelNeedsPassword=false`. Verify with `sudo -n true` first; if it returns non-zero, document the limitation and skip this row's full repro, falling back to a static `cat /proc/self/cgroup` check on opencode-serve to confirm the cgroup path string format.

**Step 4: Verification row 3 — re-exec loop guard**

Confirm that once `RESET_WORKSPACE_DETACHED=1` is set, the script doesn't re-exec again.

```bash
RESET_WORKSPACE_DETACHED=1 /tmp/reset-workspace-cgroup-check.sh
```

Expected:
- NO "DETECTION" line (env-var guard short-circuits).
- "FINAL CGROUP:" shows whatever the current shell's cgroup is.

**Step 5: Cleanup**

```bash
rm /tmp/reset-workspace-cgroup-check.sh
```

**Step 6: Commit**

No code changes to commit in this task. If verification revealed problems, return to Task 1 to fix them.

---

## Task 4: Document the gotcha in the resetting-workspace skill

**Files:**
- Modify: `.opencode/skills/resetting-workspace/SKILL.md` (add a paragraph under "Caveats")

**Step 1: Read the current Caveats section**

Run: `cat .opencode/skills/resetting-workspace/SKILL.md`

Locate the "## Caveats" section (around line 38 in the current version).

**Step 2: Add the cgroup gotcha paragraph**

Append a new bullet at the end of the Caveats section (before the next `##` heading):

```markdown
- **Cgroup gotcha (fixed 2026-04-26).** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. Steps 1–5 (snapshot + kill nvims + fire systemctl restart) ran, but the SIGTERM cascade from `KillMode=control-group` killed the script itself before steps 6–7 (respawn nvims, restore TUIs) could run. The script now self-detaches into a `systemd-run --user --scope` transient unit at entry if it detects `opencode-serve.service` in its own cgroup. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.
```

**Step 3: Commit**

```bash
git add .opencode/skills/resetting-workspace/SKILL.md
git commit -m "docs(resetting-workspace): document cgroup survival gotcha

When invoked from an opencode-agent bash tool whose TUI is attached
to opencode-serve.service, earlier versions of reset-workspace would
die mid-flight in the SIGTERM cascade from the systemctl restart.
The script now self-detaches into a user systemd scope. Surface this
as a caveat for future debuggers.

Closes part of workstation-pqu (Task 4 of 4).

Companion design: docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md"
```

---

## Task 5: End-to-end live test from this very agent (RISKY — coordinator decides)

This is the only test that actually proves the fix works in production. It also momentarily kills opencode-serve, which causes any TUIs attached to it to flicker/reconnect. **My current TUI (this conversation) is on a standalone `opencode -s ses_xxx` invocation, NOT attached to opencode-serve, so my session is safe** — but if the user has any other opencode TUIs running attached to opencode-serve, they'll briefly disconnect.

**Pre-flight check.** Before running this task, verify with the user:
- "Are there any opencode TUIs currently attached to opencode-serve.service that you want to preserve? If yes, those will reconnect after restart but in-flight LLM work in those sessions may abort."

If the user OKs:

**Step 1: Snapshot current state**

```bash
echo "=== tmux panes ==="
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid} cmd=#{pane_current_command} cwd=#{pane_current_path}'
echo "=== opencode-serve PID ==="
systemctl show -p MainPID --value opencode-serve.service
echo "=== opencode-serve binary ==="
readlink /proc/$(systemctl show -p MainPID --value opencode-serve.service)/exe
```

Expected: notes the current state. We'll diff against this after the test.

**Step 2: Run reset-workspace through the agent's bash tool**

The whole point: invoke `reset-workspace --yes` exactly the way it failed last time, from the agent's bash tool. The fix should make it succeed end-to-end this time.

```bash
reset-workspace --yes 2>&1 | tail -50
```

Expected output (roughly):
- `[reset-workspace] detected opencode-serve.service cgroup; re-execing in user scope...` — IFF this agent's bash tool is in opencode-serve.service's cgroup. (My current TUI is standalone, so it likely is NOT — the re-exec won't fire and the rest of the script runs in-place. Same as today's tmux-pane behavior.)
- `[reset-workspace] snapshotting tmux panes running nvim/nvims...`
- `[reset-workspace] found N nvim/nvims pane(s):`
- `[reset-workspace] snapshotting live opencode TUIs...`
- `[reset-workspace] killing all nvim/nvims processes (SIGKILL)...`
- `[reset-workspace] polling panes for return to shell...`
- `[reset-workspace] restarting opencode-serve.service...`
- `[reset-workspace] polling /global/health for serve readiness...`
- `[reset-workspace]   serve healthy`
- `[reset-workspace] respawning nvims in N pane(s)...`
- `[reset-workspace] restoring K opencode TUI(s)...`
- `[reset-workspace] verifying nvim sockets...`
- `[reset-workspace] reset-workspace complete`

Exit code 0.

**Step 3: Post-state verification**

```bash
echo "=== tmux panes (should match pre-state, with nvim back in cmd column) ==="
tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} pid=#{pane_pid} cmd=#{pane_current_command} cwd=#{pane_current_path}'
echo "=== opencode-serve PID (should be different from pre-state) ==="
systemctl show -p MainPID --value opencode-serve.service
```

Expected:
- Each tmux window that had `cmd=nvim` pre-state should again have `cmd=nvim` post-state, with the same `cwd`.
- opencode-serve PID has changed (proves the restart actually happened).

**Step 4: If the run failed**

Capture the failure mode in workstation-pqu notes and DO NOT mark the bead closed. Return to Task 1 with the new failure data.

**Step 5: If the run succeeded**

Proceed to Task 6 (close the bead).

---

## Task 6: Close the bead, push, verify clean

**Files:**
- (no edits)

**Step 1: Close workstation-pqu**

```bash
bd close workstation-pqu --reason "Fixed: reset-workspace now self-detaches into user systemd scope when invoked from inside opencode-serve.service's cgroup. See commits ... and docs/plans/2026-04-26-reset-workspace-cgroup-survival-{design,plan}.md."
```

**Step 2: Sync beads + commit + push**

```bash
bd sync
git add .beads/issues.jsonl
git commit -m "chore(beads): close workstation-pqu (reset-workspace cgroup survival fix shipped)"
git pull --rebase
git push
```

**Step 3: Verify clean**

```bash
git status
```

Expected: `On branch main`, `Your branch is up to date with 'origin/main'`, `nothing to commit`.

---

## Hand-off note

After all tasks complete:
- Bead `workstation-pqu` is closed with the fix referenced.
- Design + plan committed under `docs/plans/2026-04-26-reset-workspace-cgroup-survival-{design,plan}.md`.
- `pkgs/reset-workspace/default.nix` patched (one new top-of-script block).
- `.opencode/skills/resetting-workspace/SKILL.md` documents the gotcha.
- The next time we bump opencode-patched and run `reset-workspace --yes` from the agent's bash tool — even if the agent is attached to opencode-serve — the script will self-detach and complete successfully.

If the live end-to-end test in Task 5 was skipped for safety (user wanted to defer), file a follow-up bead `bd create --title="Verify reset-workspace cgroup survival fix end-to-end with live restart" --type=task --priority=3` linking back to workstation-pqu.
