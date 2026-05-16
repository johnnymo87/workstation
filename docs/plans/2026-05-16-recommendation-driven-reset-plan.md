# Recommendation-driven nightly reset Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `reset-workspace`'s auto-restore (oc-auto-attach loop + nvim respawn) with a single headless recommendation session that messages the user via Telegram with conversational recommendations and selectively re-opens chosen sessions on reply.

**Architecture:** Modify `pkgs/reset-workspace/default.nix` to drop the nvim-snapshot, nvim-respawn, socket-verify, and oc-auto-attach steps; keep the snapshot, SIGKILL, and serve-restart steps; add a final step that writes the captured sids to a known path and shells out to `opencode-launch ~ "<recommendation prompt>"`. The prompt is baked as a heredoc. The recommendation session handles enrichment, message formatting, Telegram round-trip (via the existing pigeon plugin), and per-sid `oc-auto-attach` exec.

**Tech Stack:** Bash (NixOS `writeShellApplication`), `opencode-launch` (existing shell script in `users/dev/home.base.nix`), `oc-auto-attach` (existing), pigeon Telegram daemon (existing), opencode-serve HTTP API.

**Beads issue:** workstation-6bz

**Design:** `docs/plans/2026-05-16-recommendation-driven-reset-design.md`

---

## Pre-Flight: Read Context

Before starting Task 1, read these files in full to load context:

- `docs/plans/2026-05-16-recommendation-driven-reset-design.md` (the design this implements)
- `pkgs/reset-workspace/default.nix` (the file you'll modify in Task 1)
- `users/dev/home.base.nix` lines 1–60 (where `opencode-launch` is defined — confirms how it's invoked)
- `pkgs/oc-auto-attach/default.nix` (what gets called per chosen sid by the recommendation session)
- `.opencode/skills/resetting-workspace/SKILL.md` (the doc you'll update in Task 3)

Reference (no need to read in full, but exists for lookup):

- `docs/plans/2026-04-27-bare-tui-restoration-design.md` — explains the dual-branch snapshot logic
- `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` — explains the `systemd-run --user --scope` re-exec

---

## Task 1: Modify `pkgs/reset-workspace/default.nix`

**Files:**

- Modify: `pkgs/reset-workspace/default.nix` (lines 108–124 removed; line 230 added writeout; lines 252–285 removed; lines 312–366 removed; new block added near end)

**Goal:** Drop steps 1, 6, 6.5, and 7. Add a manifest-writeout + `opencode-launch` spawn at the end.

### Step 1.1: Read the current file end-to-end

Run:
```bash
cat -n pkgs/reset-workspace/default.nix | sed -n '108,370p'
```
Expected: you can see the four sections you're about to modify. Note the line numbers may shift as you edit; use the section comments (`# ---- Step 1: ...`, `# ---- Step 2: ...`, etc.) as anchors, not line numbers.

### Step 1.2: Delete Step 1 (tmux pane snapshot)

Use `mcp_Edit` to remove this entire block, starting with the `# ---- Step 1: Snapshot tmux manifest ----` comment through the closing `fi` of the inner `else` branch (currently lines 108–124):

```nix
    # ---- Step 1: Snapshot tmux manifest ----
    log "snapshotting tmux panes running nvim/nvims..."

    MANIFEST=$(tmux list-panes -a \
      -F '#{pane_id}'$'\t'''#{window_name}'$'\t'''#{pane_current_command}'$'\t'''#{pane_current_path}' 2>/dev/null \
      | awk -F'\t' '$3 == "nvim" || $3 == "nvims" { print }' || true)

    if [ -z "$MANIFEST" ]; then
      log "no nvim/nvims panes found"
      MANIFEST_COUNT=0
    else
      MANIFEST_COUNT=$(printf '%s\n' "$MANIFEST" | wc -l)
      log "found $MANIFEST_COUNT nvim/nvims pane(s):"
      printf '%s\n' "$MANIFEST" | while IFS=$'\t' read -r pane window cmd path; do
        log "  $pane  $window  ($cmd)  $path"
      done
    fi
```

Replace with a single blank line separator so the file still flows. The `MANIFEST` and `MANIFEST_COUNT` variables are no longer needed; any later reference to them will break the build, which we'll catch in Task 2's parse check.

### Step 1.3: Update the confirmation summary

In the Step 2 confirm block (currently lines 232–250), the log lines reference `$MANIFEST_COUNT`. Replace:

```nix
    log "About to:"
    log "  1. SIGKILL $MANIFEST_COUNT nvim/nvims process(es)"
    log "  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  3. Respawn nvims in $MANIFEST_COUNT pane(s)"
    log "  4. Restore $OPENCODE_COUNT opencode TUI(s) via oc-auto-attach"
```

With:

```nix
    log "About to:"
    log "  1. SIGKILL all dev-owned nvim processes"
    log "  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)"
    log "  3. Launch recommendation session referencing $OPENCODE_COUNT captured sid(s)"
```

### Step 1.4: Simplify Step 3 (SIGKILL block)

Currently Step 3 is gated on `[ "$MANIFEST_COUNT" -gt 0 ]` and also polls tmux panes for return-to-shell. Drop the gate and the poll — we always SIGKILL all nvims and don't care about tmux pane state after.

Replace the entire block from `# ---- Step 3: Kill all nvims ----` through its closing `fi` (currently lines 252–285) with:

```nix
    # ---- Step 3: Kill all nvims ----
    log "killing all nvim/nvims processes (SIGKILL)..."
    # -x nvim matches both `nvim` (TTY frontend) and `nvim --embed`
    # (embedded server) because both have comm = `nvim`.
    if pkill -9 -u dev -x nvim 2>/dev/null; then
      log "  pkill returned matches"
    else
      log "  pkill returned no matches (none running, or already dead)"
    fi
```

(We no longer need the per-pane poll, since we don't care whether tmux panes show "shell again" — we're not respawning into them.)

### Step 1.5: Delete Step 6 (nvim respawn) and Step 6.5 (oc-auto-attach loop) and Step 7 (socket verify)

Remove these three blocks (currently lines 312–366) entirely. The boundaries are:

- Start: `# ---- Step 6: Respawn nvims in each manifest pane ----`
- End: the closing `fi` of Step 7's `if [ "$MANIFEST_COUNT" -gt 0 ]; then ... fi`

After this delete, the only remaining content between the Step 5 health-poll and the final `log "reset-workspace complete"` should be a blank line.

### Step 1.6: Insert the new Step 6 (manifest writeout + recommendation session)

Immediately after the Step 5 block (the `opencode-serve did not become healthy` `die`), insert:

```nix
    # ---- Step 6: Write manifest + launch recommendation session ----
    # Replaces the old auto-restore (nvim respawn + oc-auto-attach loop).
    # The recommendation session reads the manifest, enriches each sid via
    # opencode-serve, messages the user via Telegram with conversational
    # recommendations, and re-opens only the chosen sessions on reply.
    # Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md
    MANIFEST_PATH="/tmp/reset-workspace-last-manifest.txt"
    if [ -n "$OPENCODE_MANIFEST" ]; then
      printf '%s\n' "$OPENCODE_MANIFEST" > "$MANIFEST_PATH"
      log "wrote $OPENCODE_COUNT sid(s) to $MANIFEST_PATH"
    else
      : > "$MANIFEST_PATH"
      log "wrote empty $MANIFEST_PATH (no captured sids)"
    fi

    if [ "$OPENCODE_COUNT" -eq 0 ]; then
      log "no sessions to recommend; skipping recommendation session launch"
    elif ! command -v opencode-launch >/dev/null 2>&1; then
      log "WARNING: opencode-launch not on PATH; cannot spawn recommendation session"
    else
      log "launching recommendation session in ~ ..."
      # The prompt is intentionally loose/judgmental. The recommendation
      # session does its own enrichment via the opencode-serve HTTP API.
      # See design doc for the rationale.
      RECOMMENDATION_PROMPT=$(cat <<'PROMPT'
You're the morning recommendation agent. The user has just gone through a nightly reset of their workspace. Read the file at /tmp/reset-workspace-last-manifest.txt -- it contains one opencode session id per line, representing sessions that had a live TUI at reset time.

For each sid, fetch its metadata from GET http://127.0.0.1:4096/session/<sid> and look at the title, directory, and last update time. If useful, also fetch recent messages from GET http://127.0.0.1:4096/session/<sid>/message to get a sense of whether the session was mid-task or wrapped up.

Build a short, conversational Telegram message recommending which sessions to reopen and why. Be opinionated. Group by project. If something looks finished (a PR landed, a question got resolved), say so. If something looks mid-flight, say that too. Number the recommendations so the user can refer to them by number.

Then use the question tool to ask the user which to reopen. Accept free-form replies like "1,3,5", "all", "none", "the mono ones".

When they reply, parse their selection and for each chosen sid, run `oc-auto-attach <sid>` in a bash tool. Report a brief summary of what was opened.

If the manifest file is missing or empty, message the user "Nightly reset complete, no sessions to recommend." and exit.
PROMPT
)
      # opencode-launch first arg is directory, second is the prompt.
      # ~ resolves inside opencode-launch via "${directory/#\~/$HOME}".
      if ! opencode-launch '~' "$RECOMMENDATION_PROMPT" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
        log "WARNING: opencode-launch failed (non-zero exit); recommendation session not started"
      fi
    fi
```

Notes for the implementer:

- `OPENCODE_MANIFEST` is the newline-separated, deduped sid list produced by Step 2 (already exists in the file). Don't re-dedupe.
- `OPENCODE_COUNT` is set by the existing Step 2 code (already exists). Don't recompute.
- The `'~'` literal is intentional — `opencode-launch` itself resolves `~` to `$HOME` via parameter expansion (see `users/dev/home.base.nix:33`-ish), so we don't pre-expand here.
- The trailing `| while IFS= read -r line; do log "  $line"; done` pipe is for journal observability — surfaces opencode-launch's stdout/stderr through our log prefix.
- The whole `opencode-launch` invocation is wrapped in `if !` so a non-zero exit just logs a warning and continues to the final `log "reset-workspace complete"`. The reset itself is considered successful as long as steps 4–5 ran.

### Step 1.7: Parse-check the file

Run:
```bash
nix-instantiate --parse pkgs/reset-workspace/default.nix > /dev/null && echo "PARSE OK"
```
Expected: `PARSE OK` with no errors.

If you get a parse error, the most likely culprits are:
- A stray reference to `MANIFEST` or `MANIFEST_COUNT` we missed deleting.
- A heredoc delimiter mismatch in the `RECOMMENDATION_PROMPT` block.
- A Nix-level `''${...}` escape that got mangled.

### Step 1.8: Build the derivation

Run:
```bash
nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>&1 | tail -5
```
Expected: prints a `/nix/store/...-reset-workspace` path with no errors.

If the build complains about an unbound variable (typical bash error from `writeShellApplication`'s shellcheck pass), find the offending line and fix.

### Step 1.9: Smoke-test the built script grep

Run:
```bash
STORE=$(nix build --no-link --print-out-paths .#packages.aarch64-linux.reset-workspace 2>/dev/null)
echo "=== references to removed concepts (should be ZERO) ==="
grep -c -E 'snapshotting tmux panes|Respawn nvims|verifying nvim sockets|MANIFEST_COUNT' "$STORE/bin/reset-workspace" || true
echo "=== new concepts (should be 1+ each) ==="
grep -c 'Write manifest + launch recommendation session' "$STORE/bin/reset-workspace"
grep -c 'reset-workspace-last-manifest.txt' "$STORE/bin/reset-workspace"
grep -c "opencode-launch '~'" "$STORE/bin/reset-workspace"
grep -c "morning recommendation agent" "$STORE/bin/reset-workspace"
```
Expected:
- First grep: `0` (or empty output) for each of the four patterns.
- Second group: each prints a positive integer.

### Step 1.10: Commit

```bash
cd /home/dev/projects/workstation
git add pkgs/reset-workspace/default.nix
git commit -m "feat(reset-workspace): replace auto-restore with recommendation session (workstation-6bz)

Drop step 1 (tmux snapshot), step 6 (nvim respawn), step 6.5
(oc-auto-attach loop), and step 7 (socket verify). Replace with a single
new step 6 that writes the captured manifest to
/tmp/reset-workspace-last-manifest.txt and launches a headless
opencode session in ~ with a baked-in prompt instructing it to enrich
each sid via the serve API, message the user via Telegram with
conversational recommendations, and re-open only the chosen sessions on
reply.

Snapshot logic (both strict-attach and bare-resolved branches) is
unchanged -- still populates OPENCODE_MANIFEST. cgroup re-exec, flock
re-exec, SIGKILL pass, and serve restart are all unchanged.

Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md"
```

---

## Task 2: Update `.opencode/skills/resetting-workspace/SKILL.md`

**Files:**

- Modify: `.opencode/skills/resetting-workspace/SKILL.md`

**Goal:** Reflect the new flow. The current doc is structured around "auto-restore both via direct argv-based and cwd-resolved paths". The new doc should describe "capture manifest, then ask a recommendation session to interactively decide what to re-open".

### Step 2.1: Read the current skill

Run:
```bash
cat .opencode/skills/resetting-workspace/SKILL.md
```

### Step 2.2: Rewrite the "What survives a reset" section

Currently this section (lines 8–30ish) talks about two restoration paths: direct (argv-based) and resolved (cwd-based). Replace that entire block with text that explains:

1. The snapshot captures live opencode TUIs (both branches still — that's how we know what was alive).
2. No tabs are auto-restored. Instead, a fresh headless opencode session is launched in `~` with a prompt that tells it to:
   - read the manifest at `/tmp/reset-workspace-last-manifest.txt`,
   - enrich each sid via the opencode-serve API,
   - Telegram-message the user with conversational recommendations,
   - and re-open only the chosen sessions on reply.
3. The journal still includes the snapshot summary line (`captured N restorable session(s) ...`) for diagnostics — the snapshot logic itself is unchanged.
4. Failure mode: if the recommendation session fails to spawn or crashes, no Telegram message arrives. User wakes up to no tabs. Visible in `journalctl -u nightly-restart-background.service`.

Proposed replacement text (adapt as needed for tone consistency with the rest of the skill):

```markdown
## What survives a reset

`reset-workspace` captures the live opencode TUIs at reset time but
does NOT auto-restore them. Instead, after the SIGKILL + serve-restart,
it writes the captured session ids to
`/tmp/reset-workspace-last-manifest.txt` and launches a headless
opencode session in `~` with a baked-in prompt instructing it to:

1. Read the manifest.
2. Enrich each sid via `GET http://127.0.0.1:4096/session/<sid>` (title,
   directory, last update, optionally recent messages).
3. Send a conversational Telegram message recommending which sessions
   to reopen and why, with numbered options.
4. Wait for your Telegram reply (free-form: "1,3", "all", "none", etc).
5. For each chosen sid, exec `oc-auto-attach <sid>` to create the tab.

You wake up to: no tabs if you ignored the Telegram message, exactly
the tabs you asked for if you replied.

The snapshot captures TUIs in two ways (unchanged from the prior
revision -- both feed the manifest the recommendation session reads):

1. **Direct (argv-based)**: TUIs launched via Telegram `/launch` or
   `opencode-launch` (CLI) carry their session id in the
   `--session ses_xxx` argv, captured directly by step 2's strict
   regex.

2. **Resolved (cwd-based)**: Bare `:te opencode` TUIs have no sid in
   argv; step 2 resolves their `/proc/<pid>/cwd` to the
   most-recent root session for that directory via
   `GET $OPENCODE_URL/session?directory=...&roots=true&limit=1`.

Each reset's journal includes a summary line of the form:

    captured N restorable session(s) (raw: M strict-attach + K bare-resolved; dedupe may collapse); J bare TUI(s) skipped

If a TUI you expected to see in the recommendation message was missing,
check the journal for that line and the per-pid context lines above
it. If the recommendation session itself failed to spawn (e.g.
opencode-launch missing from PATH), you'll see a `WARNING:
opencode-launch failed` or `WARNING: opencode-launch not on PATH`
line.
```

### Step 2.3: Update the "What it does (in order)" section

Currently it lists 8 steps. The new flow is:

```markdown
## What it does (in order)

1. Snapshots live opencode TUIs (one session id per non-serve `opencode`
   process; both argv-based and cwd-resolved branches).
2. Confirms with the user (skip with `--yes`).
3. SIGKILLs all `nvim` processes owned by `dev`.
4. Restarts `opencode-serve.service` (passwordless sudo).
5. Writes the captured sids to `/tmp/reset-workspace-last-manifest.txt`.
6. Launches a headless opencode session in `~` with a baked-in prompt
   that handles enrichment, Telegram messaging, and selective re-open
   on reply.

Concurrent runs are blocked by `flock /tmp/reset-workspace.lock`.
```

(Drop the old steps about respawning nvims, restoring TUIs via
`oc-auto-attach`, and verifying nvim sockets — those are gone.)

### Step 2.4: Update the "Caveats" section

The current caveats mention nvim being disposable, the cgroup gotcha,
in-flight headless workers losing their process but having TUIs
restored, etc. Update to reflect:

- nvim being disposable — still true; keep.
- cgroup gotcha — still true; keep.
- The in-flight headless workers note — UPDATE: now their TUIs are NOT
  automatically restored either; they need to be picked from the
  recommendation message.
- Add a new caveat: "If the recommendation session crashes, never
  messages you, or your Telegram is offline, no tabs come back. This is
  intentional — the alternative (auto-restore as a fallback) would
  re-introduce the wall-of-tabs problem. Observe via `journalctl -u
  nightly-restart-background.service`."

### Step 2.5: Update the "Related" section

Add the new design + plan doc references:

```markdown
## Related

- Design (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-design.md`
- Plan (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-plan.md`
- Original design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
```

### Step 2.6: Commit

```bash
cd /home/dev/projects/workstation
git add .opencode/skills/resetting-workspace/SKILL.md
git commit -m "docs(skill): describe recommendation-driven reset flow (workstation-6bz)

Reset no longer auto-restores tabs. Instead a single recommendation
session reads the captured manifest, enriches via the serve API,
Telegram-messages the user with conversational recommendations, and
re-opens only the chosen sessions on reply.

Design: docs/plans/2026-05-16-recommendation-driven-reset-design.md"
```

---

## Task 3: Deploy + live verify

**Files:** none modified; this is the deploy + smoke test.

### Step 3.1: Deploy via home-manager

Run:
```bash
nix run home-manager -- switch --flake .#cloudbox 2>&1 | tail -20
```
Expected: `Activation finished` line; no errors. The new `reset-workspace` binary lands at `~/.nix-profile/bin/reset-workspace`.

### Step 3.2: Confirm the deployed binary has the new content

Run:
```bash
which reset-workspace
grep -c 'Write manifest + launch recommendation session' "$(which reset-workspace)"
grep -c 'reset-workspace-last-manifest.txt' "$(which reset-workspace)"
grep -c "opencode-launch '~'" "$(which reset-workspace)"
grep -c 'morning recommendation agent' "$(which reset-workspace)"
echo "--- should-be-gone patterns ---"
grep -c -E 'snapshotting tmux panes|Respawn nvims|verifying nvim sockets|MANIFEST_COUNT' "$(which reset-workspace)" || true
```
Expected:
- The deployed path is under `/nix/store/...-reset-workspace/bin/reset-workspace` and symlinked from `~/.nix-profile/bin/reset-workspace`.
- Each of the first four grepc commands prints a positive integer.
- The "should-be-gone" grep prints `0`.

### Step 3.3: Live trigger via the systemd unit

**Critical:** Do NOT run `reset-workspace --yes` inline from your opencode bash tool, even though it has the cgroup re-exec. Trigger the systemd unit instead, because:

- The systemd unit's PATH and Environment match what the nightly run will see at 3 AM.
- It exercises the full path including any service-level state.
- It avoids any chance of confusing the cgroup detector when invoked from an opencode-attached bash.

Run:
```bash
TRIGGER_TS="$(date '+%Y-%m-%d %H:%M:%S')"
sudo systemctl --no-block start nightly-restart-background.service
```
Expected: returns immediately with no output.

### Step 3.4: Tail the journal

Run:
```bash
# Give the service a moment to start emitting log lines, then dump.
for i in $(seq 1 20); do
  if journalctl -u nightly-restart-background.service --since "$TRIGGER_TS" --no-pager 2>&1 | grep -q 'reset-workspace complete\|FATAL\|WARNING: opencode-launch'; then
    break
  fi
done
journalctl -u nightly-restart-background.service --since "$TRIGGER_TS" --no-pager 2>&1 | tail -80
```

Expected lines you should see (in this order):
- `[reset-workspace] detaching into fresh user systemd scope...` (only if detector fires)
- `[reset-workspace] snapshotting live opencode attach clients...`
- `[reset-workspace]   captured N restorable session(s) (raw: M strict-attach + K bare-resolved; ...)`
- `[reset-workspace] About to:` (the new 3-line summary, NOT the old 4-line one)
- `[reset-workspace] (--yes: skipping confirmation)`
- `[reset-workspace] killing all nvim/nvims processes (SIGKILL)...`
- `[reset-workspace] restarting opencode-serve.service...`
- `[reset-workspace] polling /global/health for serve readiness...`
- `[reset-workspace]   serve healthy`
- `[reset-workspace] wrote N sid(s) to /tmp/reset-workspace-last-manifest.txt` (OR `wrote empty ...` if N=0)
- `[reset-workspace] launching recommendation session in ~ ...` (OR `no sessions to recommend; skipping recommendation session launch` if N=0)
- `[reset-workspace]   Session launched: ses_xxxxx` (from opencode-launch's stdout)
- `[reset-workspace] reset-workspace complete`

You should NOT see:
- Anything about "Respawn nvims" or "verifying nvim sockets" — those are deleted.
- `WARNING: opencode-launch not on PATH` (it should be on PATH).

### Step 3.5: Confirm the manifest file exists

Run:
```bash
ls -la /tmp/reset-workspace-last-manifest.txt
cat /tmp/reset-workspace-last-manifest.txt
```
Expected: file exists, contains zero or more lines each matching `ses_[A-Za-z0-9]+`.

### Step 3.6: Confirm a recommendation session was created

Run:
```bash
# Find the most-recent session in ~ created in the last 60 seconds.
curl -s --get http://127.0.0.1:4096/session \
  --data-urlencode "directory=$HOME" \
  --data-urlencode "limit=5" 2>/dev/null \
  | jq -r '.[] | "\(.id) updated=\(.time.updated) title=\(.title)"' \
  | head -5
```
Expected: one of the listed sessions should be brand-new (its `updated` timestamp within the last minute) and live in `~`. That's the recommendation session.

You can confirm it's still running:
```bash
pgrep -u dev -fa 'opencode' | grep -v 'serve' | head -5
```
Expected: there's a process running the recommendation session OR (if it has already messaged you and exited cleanly) it's gone — both are fine. The journal evidence above is what matters for confirming reset's behavior.

### Step 3.7: Verify Telegram message arrives (interactive)

This step requires your active participation: check Telegram for a message from pigeon with the conversational recommendations. If it arrives, the end-to-end is working.

If it does NOT arrive within ~2 minutes:
- Check `journalctl -u opencode-serve --since "$TRIGGER_TS" --no-pager | tail -50` for errors from the recommendation session.
- Check `journalctl -t pigeon-daemon --since "$TRIGGER_TS" --no-pager | tail -50` for pigeon-side errors.
- Check the session's message log: `curl -s http://127.0.0.1:4096/session/ses_xxxxx/message | jq '.[] | .role, .content[0:200]'` — replace `ses_xxxxx` with the sid from Step 3.6.

### Step 3.8: Verify reply round-trip (interactive)

Reply to the Telegram message with a selection (e.g. `1` for the first numbered recommendation, or `none` for none). Confirm:
- The recommendation session resumes and acts on your reply.
- For each chosen sid, a tab opens in the appropriate project's nvim+tmux (visible by attaching the tmux session or checking `/tmp/oc-auto-attach.log`).

If `none`: confirm no new tabs appear, and the session sends a "OK, nothing reopened" style summary message back.

### Step 3.9: Close the beads issue

```bash
cd /home/dev/projects/workstation
bd close workstation-6bz --reason "Implemented per docs/plans/2026-05-16-recommendation-driven-reset-design.md and -plan.md. Deployed via 'nix run home-manager -- switch --flake .#cloudbox'. Live-verified via 'sudo systemctl --no-block start nightly-restart-background.service' on $(date +%Y-%m-%d): journal shows the new flow lines (manifest writeout + recommendation session launch); /tmp/reset-workspace-last-manifest.txt populated; Telegram message arrived and reply round-trip executed oc-auto-attach for the chosen sids."
bd sync
```

### Step 3.10: Commit any beads changes

```bash
cd /home/dev/projects/workstation
git add .beads/issues.jsonl
git commit -m "chore(beads): close workstation-6bz (recommendation-driven reset)" 2>&1 | tail -3 || echo "(no beads changes to commit)"
```

### Step 3.11: Push

```bash
cd /home/dev/projects/workstation
git pull --rebase
git push
git status
```
Expected: final status shows "up to date with origin".

---

## Task 4 (deferred / optional): Add `bd` followup for runtime TUI manifest

This is NOT part of the current scope. It's listed here so the implementer doesn't forget the future-work signal noted in the design doc.

Action:
```bash
bd create "Add runtime TUI manifest under \$XDG_RUNTIME_DIR/opencode/tui/<pid>.json" \
  --type=feature --priority=3 \
  --description "Currently reset-workspace step 2 has two snapshot branches: strict-attach (precise) and bare-resolved (best-effort cwd-based lookup, which collapses worktrees). A runtime manifest written by opencode at TUI startup (sid + cwd + project + pid) would let us drop the bare-resolved branch entirely and use precise sid-from-pid resolution for every TUI.

Discovered-from: workstation-6bz (recommendation-driven reset). Independent simplification; not blocking. Design discussion in docs/plans/2026-04-27-bare-tui-restoration-design.md."
bd dep add workstation-<new-id> workstation-6bz --type=discovered-from
bd sync
```

(Skip this task if the user hasn't asked for it — it's just a placeholder so the future-work signal isn't lost.)

---

## Verification checklist (consolidated)

By the end of Task 3:

- [ ] `pkgs/reset-workspace/default.nix` parses + builds cleanly.
- [ ] The deployed binary contains the new manifest writeout + opencode-launch invocation.
- [ ] The deployed binary contains NO references to `MANIFEST_COUNT`, `snapshotting tmux panes`, `Respawn nvims`, or `verifying nvim sockets`.
- [ ] `.opencode/skills/resetting-workspace/SKILL.md` describes the new flow.
- [ ] `sudo systemctl --no-block start nightly-restart-background.service` produces the expected journal sequence.
- [ ] `/tmp/reset-workspace-last-manifest.txt` is created and populated.
- [ ] A recommendation session exists in `~` per the serve API.
- [ ] Telegram message arrives (interactive confirmation).
- [ ] Reply round-trip opens the chosen tabs (interactive confirmation).
- [ ] workstation-6bz is closed in beads.
- [ ] Changes are pushed to `origin/main`.
