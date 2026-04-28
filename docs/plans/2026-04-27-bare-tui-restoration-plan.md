# Bare opencode TUI restoration via cwd→sid resolution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `reset-workspace` step 2's bare-TUI WARNING-only enumeration with a resolve-or-warn loop that converts each bare TUI's `/proc/<pid>/cwd` into a sid via `GET $OPENCODE_URL/session?directory=$cwd&roots=true&limit=1`, then appends the resolved sid to `OPENCODE_MANIFEST` so step 6.5 restores it as an attach client.

**Architecture:** Script-only change to `pkgs/reset-workspace/default.nix` step 2 (the bare-TUI loop, currently lines ~157–176). No changes to `oc-auto-attach`, no opencode source patches. Restoration uses the existing step 6.5 loop (no change). Net effect: every alive opencode TUI survives reset; post-restoration, all are attach clients.

**Tech Stack:** Bash (writeShellApplication via Nix), curl, jq, /proc, tmux, nix-build, home-manager.

**Design:** `docs/plans/2026-04-27-bare-tui-restoration-design.md`

**Predecessor:** `docs/plans/2026-04-27-reset-workspace-snapshot-fix-plan.md` (workstation-0gu — narrow strict-pgrep fix, shipped at e170356).

**Bead:** TBD (file after this plan lands).

---

### Task 1: Replace the bare-TUI loop with resolve-or-warn

**Files:**
- Modify: `pkgs/reset-workspace/default.nix` step 2 — the second `for pid in $OC_ALL_PIDS; do …` loop (currently lines ~157–176, comment-bounded by `# ---- Step 2: Snapshot live opencode attach clients ----` at the top of step 2 and `# Dedupe captured sids.` at the end). The strict-attach loop above it must NOT be touched.

**Step 1: Read the current bare-TUI loop**

```bash
sed -n '/# Observability: enumerate bare opencode TUIs/,/# Dedupe captured sids/p' pkgs/reset-workspace/default.nix
```

Confirm boundaries — the block to replace runs from the comment `# Observability: enumerate bare opencode TUIs that will NOT be restored.` through the closing `done` of the `for pid in $OC_ALL_PIDS; do …` loop. The line `OPENCODE_BARE_COUNT=0` near the top of step 2 (currently next to `OPENCODE_MANIFEST=""`) will also need to be replaced (split into two counters).

**Step 2: Update counter initialization at top of step 2**

Find the line:

```nix
    OPENCODE_BARE_COUNT=0  # observability: bare TUIs we are NOT restoring
```

Replace with:

```nix
    OPENCODE_BARE_RESOLVED=0  # bare TUIs whose cwd resolved to a sid via opencode-serve
    OPENCODE_BARE_SKIPPED=0   # bare TUIs whose cwd had no resolvable sid (or unreadable cwd)
```

**Step 3: Replace the bare-TUI loop body**

Find the block starting with `# Observability: enumerate bare opencode TUIs that will NOT be restored.` and ending with the closing `done` (the one immediately before `# Dedupe captured sids.`). Replace with:

```nix
    # Resolve bare opencode TUIs to sids via opencode-serve.
    # For each bare TUI alive, look up the most-recent root session for its
    # cwd; if found, restore it as an attach client by appending the sid to
    # OPENCODE_MANIFEST. opencode-serve is alive at this point (we restart
    # it later in step 5), so the API is always reachable here.
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

      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
      if [ -z "$cwd" ]; then
        log "  WARNING: bare opencode TUI pid=$pid has no readable cwd; skipping"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
        continue
      fi

      resolved_sid=$(curl -fsS --get "$OPENCODE_URL/session" \
        --data-urlencode "directory=$cwd" \
        --data-urlencode "roots=true" \
        --data-urlencode "limit=1" 2>/dev/null \
        | jq -r '.[0].id // empty' 2>/dev/null)

      if [ -n "$resolved_sid" ] && printf '%s' "$resolved_sid" | grep -qxE 'ses_[A-Za-z0-9]+'; then
        log "  pid=$pid (bare-resolved) sid=$resolved_sid cwd=$cwd"
        OPENCODE_MANIFEST="''${OPENCODE_MANIFEST}''${resolved_sid}"$'\n'
        OPENCODE_BARE_RESOLVED=$((OPENCODE_BARE_RESOLVED + 1))
      else
        log "  WARNING: bare opencode TUI pid=$pid cwd=$cwd has no resolvable session in DB; skipping restoration"
        OPENCODE_BARE_SKIPPED=$((OPENCODE_BARE_SKIPPED + 1))
      fi
    done
```

CRITICAL Nix-string escaping notes (this is a `writeShellApplication` derivation; the script body is a Nix `''...''` indented string):
- `''${OPENCODE_MANIFEST}''${resolved_sid}` is correct: each `''$` is the Nix escape for a literal `$`, so the rendered shell sees `${OPENCODE_MANIFEST}${resolved_sid}`. Do NOT remove the leading `''`.
- The `$'\n'` literal is intentional and works inside the Nix indented string as-is.
- Indentation is 4 spaces (matches strict-attach loop above).
- Per-line `2>/dev/null` on curl + jq prevents transient HTTP / parse errors from polluting the journal.

**Step 4: Update the summary log line at the end of step 2**

Find:

```nix
    log "  captured $OPENCODE_COUNT restorable session(s); $OPENCODE_BARE_COUNT bare TUI(s) skipped"
```

Replace with:

```nix
    OPENCODE_STRICT_COUNT=$((OPENCODE_COUNT - OPENCODE_BARE_RESOLVED))
    log "  captured $OPENCODE_COUNT restorable session(s) ($OPENCODE_STRICT_COUNT strict-attach + $OPENCODE_BARE_RESOLVED bare-resolved); $OPENCODE_BARE_SKIPPED bare TUI(s) skipped"
```

(Note: `OPENCODE_COUNT` is computed by the dedupe `wc -l` step BEFORE this log line, so it already reflects strict + bare-resolved with dedupe. Subtracting `OPENCODE_BARE_RESOLVED` recovers the strict count for display purposes. If the same sid was captured both ways, dedupe absorbs it and the displayed strict count slightly overcounts — acceptable for an observability line.)

**Step 5: Verify the file is well-formed**

```bash
nix-instantiate --parse pkgs/reset-workspace/default.nix > /dev/null && echo "PARSE OK"
```

Expected: `PARSE OK`, exit 0.

**Step 6: Build the package**

```bash
nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>&1 | tail -3
```

Expected: prints a `/nix/store/...-reset-workspace` path with no errors.

**Step 7: Inspect the rendered script**

```bash
STORE=$(nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>/dev/null) && \
  grep -n -A 1 'bare-resolved\|Resolve bare opencode TUIs\|OPENCODE_BARE_RESOLVED' "$STORE/bin/reset-workspace" | head -20
```

Expected: see the new `# Resolve bare opencode TUIs to sids via opencode-serve.` comment, the `OPENCODE_BARE_RESOLVED=0` initialization, and the new "(bare-resolved)" log line.

Also confirm the OLD comment is gone:

```bash
grep -c 'will NOT be restored across reset' "$STORE/bin/reset-workspace"
```

Expected: `0`.

**Step 8: Commit**

```bash
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): restore bare TUIs via cwd→sid resolution (P2.5)

Replace step 2's bare-TUI WARNING-only enumeration with a resolve-or-warn
loop. For each bare opencode TUI alive at snapshot time, query
opencode-serve via GET /session?directory=\$cwd&roots=true&limit=1 to
resolve cwd to the most-recent root session for that directory, then
append to OPENCODE_MANIFEST so step 6.5 restores as an attach client.

Net effect: every opencode TUI alive at snapshot time survives reset.
Post-restoration, all restored TUIs are uniformly attach clients, so
the next reset's strict-pgrep captures all of them via argv directly.

See docs/plans/2026-04-27-bare-tui-restoration-design.md
"
```

---

### Task 2: Update resetting-workspace skill doc

**Files:**
- Modify: `.opencode/skills/resetting-workspace/SKILL.md`

**Step 1: Locate and replace the existing "What survives a reset" section**

The section was added by commit cd6eff2 and currently describes the ONLY-/launch-survives contract. Find it (it starts with `## What survives a reset` and ends just before the next `## ` heading, probably `## What it does (in order)`).

Replace the entire section with:

```markdown
## What survives a reset

reset-workspace restores opencode TUIs in two ways:

1. **Direct (argv-based)**: TUIs launched via Telegram `/launch` or
   `opencode-launch` (CLI) carry their session id in the
   `--session ses_xxx` argv, captured directly by step 2's strict
   regex.

2. **Resolved (cwd-based)**: Bare `:te opencode` TUIs have no sid in
   argv, but step 2 resolves their `/proc/<pid>/cwd` to the
   most-recent root session for that directory via
   `GET $OPENCODE_URL/session?directory=...&roots=true&limit=1`.
   Restored TUIs come back as `opencode attach` clients (regardless of
   how they were originally launched).

A bare TUI is only skipped if its cwd has no matching root session in
opencode.db (rare — only if the TUI was opened but never used to create
or load a session).

**Edge case:** two bare TUIs in the *same* cwd will both resolve to the
same sid (the most-recently-updated one) and dedupe to a single
restoration. The user effectively loses one of the two windows.
A future enhancement (a runtime manifest under
`$XDG_RUNTIME_DIR/opencode/tui/<pid>.json`) would resolve this precisely.

Each reset's journal includes a summary line of the form:

```
captured N restorable session(s) (M strict-attach + K bare-resolved); J bare TUI(s) skipped
```

If you expected a session to be restored and it wasn't, check the journal for:
- `pid=... sid=... cwd=...` (strict-attach success)
- `pid=... (bare-resolved) sid=... cwd=...` (bare-resolved success)
- `WARNING: bare opencode TUI pid=... cwd=...` (skipped)

See `docs/plans/2026-04-27-bare-tui-restoration-design.md` for the
design rationale, including the deferred tear-down-rebuild
simplification.
```

**Step 2: Verify markdown well-formedness**

```bash
grep -n '^## ' .opencode/skills/resetting-workspace/SKILL.md | head -10
```

Expected: heading hierarchy is consistent; no broken nesting.

**Step 3: Commit**

```bash
git add .opencode/skills/resetting-workspace/SKILL.md
git commit -m "docs(skill): update resetting-workspace contract for bare-TUI restoration (P2.5)

Documents the two-path restoration contract: direct (argv-based) for
/launch + opencode-launch sessions, resolved (cwd-based) for bare
:te opencode TUIs. Updates the journal-summary format and points
readers at the design doc.
"
```

---

### Task 3: Deploy via home-manager

**Files:** none (deployment, not code).

**Step 1: Run home-manager switch**

```bash
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -20
```

Expected: `Activation finished` line; no errors. The new `reset-workspace` binary lands at `~/.nix-profile/bin/reset-workspace`.

**Step 2: Verify the on-PATH binary has the new logic**

```bash
which reset-workspace
echo "--- new resolve-or-warn comment count (expect >=1):"
grep -c 'Resolve bare opencode TUIs to sids via opencode-serve' "$(which reset-workspace)"
echo "--- bare-resolved log line count (expect >=1):"
grep -c 'bare-resolved' "$(which reset-workspace)"
echo "--- old WARNING line count (expect 0):"
grep -c 'will NOT be restored across reset' "$(which reset-workspace)"
echo "--- strict-attach pgrep block still present (regression check on workstation-0gu):"
grep -c 'snapshotting live opencode attach clients' "$(which reset-workspace)"
```

Expected:
- First grep: `1`
- Second grep: `1` or `2` (the log line + summary)
- Third grep: `0` (old comment is gone)
- Fourth grep: `1` (strict-attach loop unchanged)

**Step 3: No commit** — deployment is a side effect.

---

### Task 4: Live verification (orchestrator runs via systemd, NOT inline)

**Files:** none.

**WARNING — CRITICAL LANDMINE:** Per workstation-pqu and Task 4 of the workstation-0gu plan, do NOT delegate this step to a subagent. Run it inline from the orchestrator. Use `sudo systemctl --no-block start nightly-restart-background.service` so the script runs without a pty (no SIGHUP risk when the orchestrator's TUI dies). The bash tool's "User aborted" message during this step is normal — it fires when the underlying TCP connection drops as the TUI is killed.

**Step 1: Get explicit user go-ahead**

Prompt the user: "Ready for live test? This will kill all current opencode TUIs (including this orchestrator). After reset completes, the bare-resolved sid for this orchestrator's cwd should be restored as an attach client in a fresh tmux window. Reattach via `:te opencode -s <orchestrator-sid>` if needed."

WAIT for clear "yes".

**Step 2: Pre-capture state**

```bash
echo "=== Trigger timestamp ==="
date -Iseconds | tee /tmp/p25-trigger-ts.txt
echo ""
echo "=== Pre-state: opencode processes ==="
for pid in $(pgrep -u dev -f opencode 2>/dev/null); do
  exe_base=$(basename "$(readlink /proc/$pid/exe 2>/dev/null)" 2>/dev/null)
  if printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?'; then
    cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | sed 's/ *$//')
    cwd=$(readlink /proc/$pid/cwd 2>/dev/null)
    echo "pid=$pid cwd=$cwd cmdline=$cmdline"
  fi
done | tee /tmp/p25-pre.txt
echo ""
echo "=== Orchestrator's current sid (from log file) ==="
ORCH_PID=$(pgrep -u dev -fa '/opencode$' | head -1 | awk '{print $1}')
[ -n "$ORCH_PID" ] && LOG=$(ls -la /proc/$ORCH_PID/fd/ 2>/dev/null | awk '/-> .*opencode\/log\/.*\.log$/ { print $NF; exit }')
echo "orch_pid=$ORCH_PID log=$LOG"
[ -n "$LOG" ] && grep -oE 'path=/session/ses_[A-Za-z0-9]+' "$LOG" 2>/dev/null | head -1 | sed 's|^path=/session/||' | tee /tmp/p25-orch-sid.txt
```

Note the orchestrator's sid for the user to reattach with.

**Step 3: Trigger via systemd service (no pty, no SIGHUP risk)**

```bash
sudo systemctl --no-block start nightly-restart-background.service
echo "queued at $(date -Iseconds)"
```

The service runs reset-workspace --yes via its existing wrapper unit. No pty involved → no SIGHUP propagation. The detached scope completes without the bash tool's TCP drop affecting it.

**Step 4: User-side verification (after reattach)**

After the user reattaches (via `:te opencode -s <orchestrator-sid>` in a new nvim), run:

```bash
TRIGGER_TS=$(cat /tmp/p25-trigger-ts.txt 2>/dev/null || date -Iseconds -d '5 minutes ago')
echo "=== reset-workspace journal lines ==="
sudo journalctl _UID=1000 --since "$TRIGGER_TS" --no-pager 2>&1 | grep -E '\[reset-workspace\]|\[oc-auto-attach\]' | head -80
echo ""
echo "=== tmux state ==="
tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name} (#{window_panes} panes)'
```

Expected journal output:
- `[reset-workspace] snapshotting live opencode attach clients...`
- For each bare TUI that was alive: either `pid=X (bare-resolved) sid=Y cwd=Z` (success) or `WARNING: bare opencode TUI pid=X cwd=Y has no resolvable session in DB; skipping restoration` (rare)
- For each strict-attach client (if any were alive): `pid=X sid=Y cwd=Z`
- Summary: `captured N restorable session(s) (M strict-attach + K bare-resolved); J bare TUI(s) skipped`
- Step 6.5 lines: `restoring sid=...` followed by `[oc-auto-attach]` lines per restored sid

Expected tmux state: a tmux window exists for each restored session's project cwd. Window panes typically show nvim + a `:te opencode attach …` pane.

**Step 5: Commit any incidental fixups**

If verification revealed a bug needing a one-line fix (e.g., typo in log message), make the fix and commit. Otherwise no commit.

---

### Task 5: Close out (file P2.5 bead, push, file follow-ups)

**Files:** none (beads + git).

**Step 1: File the P2.5 bead retrospectively**

Per `bd` discipline (issues filed before code), this is the one exception — the work is already specified by design + plan documents that exist in git. File now and immediately close:

```bash
bd create "Restore bare opencode TUIs across reset via cwd→sid resolution (P2.5)" \
  --type=feature --priority=2 \
  --description "$(cat <<'EOF'
Extends workstation-0gu's narrow strict-pgrep fix to also restore bare
:te opencode TUIs across reset. For each bare TUI alive at snapshot time,
resolve /proc/<pid>/cwd to the most-recent root session via opencode-serve's
GET /session?directory=...&roots=true&limit=1 endpoint, then restore as
an attach client in step 6.5.

Net effect: every opencode TUI alive at snapshot time survives reset.
Post-restoration, all restored TUIs are attach clients (uniform contract
for next reset).

Design: docs/plans/2026-04-27-bare-tui-restoration-design.md
Plan:   docs/plans/2026-04-27-bare-tui-restoration-plan.md

Discovered-from: workstation-0gu
EOF
)" --json 2>&1 | tail -5
```

Capture the bead id (e.g., `workstation-XXX`) for the next steps.

**Step 2: Add discovered-from dependency**

```bash
bd dep add <new-bead-id> workstation-0gu --type discovered-from --json 2>&1 | tail -3
```

**Step 3: Close the bead**

```bash
bd close <new-bead-id> --reason "Implemented per design + plan; verified live via nightly-restart-background.service on $(date +%Y-%m-%d). Bare TUIs in cwds with recent sessions are now restored as attach clients."
```

**Step 4: File follow-up beads (P4, P3) without closing**

```bash
bd create "TUI runtime manifest at \$XDG_RUNTIME_DIR/opencode/tui/<pid>.json (P4)" \
  --type=feature --priority=3 \
  --description "$(cat <<'EOF'
Per design doc 'Out of scope': add a TUI-side patch (in opencode-patched
fork) that writes {pid, mode, cwd, url, sessionID, lastSeen} per TUI to
\$XDG_RUNTIME_DIR/opencode/tui/<pid>.json. Heartbeat every few seconds,
unlink on clean exit.

Solves the 'two bare TUIs in same cwd' ambiguity that P2.5 collapses to
a single restoration. Defer until the ambiguity proves problematic in
practice.

Design context: docs/plans/2026-04-27-bare-tui-restoration-design.md
EOF
)" --json | tail -3

bd create "Opt-in OPENCODE_ATTACH_URL: route bare opencode through opencode-serve (P3)" \
  --type=feature --priority=3 \
  --description "$(cat <<'EOF'
Per design doc 'Out of scope': patch thread.ts (in opencode-patched fork)
to detect a healthy \$OPENCODE_ATTACH_URL/global/health before Worker
creation. If healthy, construct the TUI's transport with native HTTP
fetch to that URL instead of spawning a private worker. Falls back to
worker on failure. Opt-in via env var (NOT silent default).

Considerations:
- MCP/tool scoping (per-TUI worker vs long-lived serve)
- Reconnect-on-serve-restart behavior
- Auth/password if serve config requires
- Why source patch (not wrapper script): inheritance for IDE/scripts/
  internal invocations, per upstream issue #8948

Reference upstream issues:
- sst/opencode#8948 (Server Registry & Auto-Discovery)
- sst/opencode#7629 (Connect to existing server instead of starting new)
- sst/opencode#6461 (Named Remote Connections)
- sst/opencode#17322 (Config option to auto-attach to remote server)

Design context: docs/plans/2026-04-27-bare-tui-restoration-design.md
EOF
)" --json | tail -3
```

Add P4/P3 dep on this P2.5 bead:

```bash
bd dep add <p4-bead-id> <p25-bead-id> --type discovered-from --json 2>&1 | tail -3
bd dep add <p3-bead-id> <p25-bead-id> --type discovered-from --json 2>&1 | tail -3
```

**Step 5: Sync beads + push**

```bash
bd sync 2>&1 | tail -3
git add .beads/
git commit -m "chore(beads): close P2.5 bare-TUI restoration; file P3 + P4 follow-ups" 2>&1 | tail -3 || echo "(no changes)"
git pull --rebase 2>&1 | tail -3
git push 2>&1 | tail -3
git status
```

Expected: `Your branch is up to date with 'origin/main'`, working tree clean (untracked files in `bin/`, `test-argv*`, etc., from other sessions are tolerable).

---

## Done when

- `pkgs/reset-workspace/default.nix` step 2 has the resolve-or-warn loop replacing the old WARNING-only enumeration.
- `.opencode/skills/resetting-workspace/SKILL.md` documents the two-path contract.
- Live `sudo systemctl --no-block start nightly-restart-background.service` shows journal lines for `pid=X (bare-resolved) sid=Y cwd=Z` for each bare TUI that was alive, and the new summary line format.
- After restoration: bare TUIs come back as attach clients; their tmux windows exist in the right project cwds.
- P2.5 bead closed with verification reason; P3 + P4 beads filed; all commits pushed.
