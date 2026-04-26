# reset-workspace: opencode TUI restoration

**Status:** approved 2026-04-25
**Authoritative companions:**
- `2026-04-24-reset-workspace-design.md` — original reset-workspace design
- `2026-04-22-launch-auto-attach-design.md` — `oc-auto-attach` design
- `2026-04-24-reset-workspace-plan.md` — original implementation plan (Tasks 1–10, all merged)

## Goal

Bring "what was open before the reset" back after the reset. Today, `reset-workspace` SIGKILLs nvims, DELETEs all opencode sessions, restarts serve, and respawns empty nvims — sessions and TUIs are gone forever. We want the post-reset state to look like the pre-reset state for opencode TUIs: every session that had a live TUI before the reset is re-`:te opencode -s ses_xxx`'d in an appropriate nvim after the reset.

## Non-goals

- Restore non-opencode terminal buffers (plain `:te bash`, `:te lazygit`, etc). Out of scope.
- Restore nvim editor state (open files, splits, marks, jumplist). Out of scope. Plain `nvims` respawn from the manifest pane's cwd is the contract.
- Restore opencode TUIs across reboots. The snapshot is in-memory in the script; if the host reboots between snapshot and restore, we lose the manifest. Acceptable.

## Architecture

Two new steps slotted into the existing reset-workspace pipeline. Step 4 (DELETE all sessions) is removed.

```
Step 1:  snapshot tmux nvim panes -> $MANIFEST                          [unchanged]
Step 2:  snapshot live opencode TUIs -> $OPENCODE_MANIFEST              [NEW]
Step 3:  confirm with user                                              [text updated]
Step 4:  SIGKILL all nvims                                              [unchanged]
Step 5:  [REMOVED — was: DELETE all opencode sessions]
Step 6:  restart opencode-serve.service + health-check                  [renumbered, unchanged otherwise]
Step 7:  respawn nvims in each manifest pane                            [renumbered, unchanged otherwise]
Step 8:  restore opencode TUIs via oc-auto-attach loop                  [NEW]
Step 9:  verify nvim sockets exist                                      [renumbered, unchanged otherwise]
```

## Discovery: what counts as "live opencode TUI"?

Per the user: "all currently running opencodes (TUI open + opencode serve sessions)" — meaning every opencode process the operating system shows running, except `opencode serve` itself.

This is the same set `reap-stale-opencode` already operates on (`hosts/cloudbox/configuration.nix:436-491`):
- `pgrep -u dev -f opencode`, then filter out anything matching `serve` in the cmdline
- For each survivor, walk `/proc/<pid>/cmdline`

`opencode-serve`'s HTTP API does not expose a "list active TUI clients" endpoint (the documented OpenAPI lists only `/auth/...` and `/log`; `/session*` works but is undocumented and exposes only metadata). So OS-level discovery is the only authoritative source.

## Snapshot algorithm (step 2)

For each pid in `pgrep -u dev -f opencode`:
1. Read `/proc/<pid>/cmdline`. If the process is `opencode serve`, skip.
2. **First attempt — argv:** parse `cmdline` for `-s ses_[A-Za-z0-9]+`. If found, capture that session id.
3. **Second attempt — log file:** if no `-s` in argv, walk `/proc/<pid>/fd/` for an open file matching `~/.local/share/opencode/log/*.log`. Grep its contents for the first `path=/session/(ses_[A-Za-z0-9]+)` match. Capture that.
4. **Validate:** the captured id must match `^ses_[A-Za-z0-9]+$`. Drop invalid captures with a WARNING log.
5. **Skip-and-warn:** if neither attempt yields a session id, log `WARNING: skipping bare opencode pid=<N> cmdline=<...> — could not determine session id`.

After the loop, deduplicate. The deduplicated list is `$OPENCODE_MANIFEST`.

## Restore algorithm (step 8)

After step 7 (respawn) succeeds:
- If `$OPENCODE_MANIFEST` is empty: log `no opencode TUIs to restore` and skip.
- Otherwise, for each `sid` in `$OPENCODE_MANIFEST`, serially:
  - Invoke `/home/dev/.nix-profile/bin/oc-auto-attach $sid`.
  - Log per-session: `restoring $sid` before, then propagate oc-auto-attach's own per-line stderr to the journal.

`oc-auto-attach` already handles:
- Polling `GET /session/$sid` until the session is visible with a non-empty `.directory` (5s timeout).
- Computing the project key (collapses `~/projects/X/.worktrees/Y/...` → `~/projects/X`).
- Finding an existing tmux pane with a matching cwd (preferring exact match), or creating a new tmux window via `tmux new-window -n $window_name -- nvims`.
- Polling the nvim socket + helper module for readiness (5s timeout).
- Calling the lua helper `user.oc_auto_attach.open(...)` which `tabnew`s and `jobstart`s `opencode attach $url --session $sid`.

We rely on this entire mechanism. `oc-auto-attach` exits 0 on its own internal failures by design — we don't need to special-case those; the only loss is one un-restored TUI. The script keeps going.

## Confirmation prompt text (step 3)

Old (current production):
```
About to:
  1. SIGKILL N nvim/nvims process(es)
  2. DELETE M opencode session(s) via HTTP API
  3. Restart opencode-serve.service (this Claude session's TUI will reconnect)
  4. Respawn nvims in N pane(s)
```

New:
```
About to:
  1. SIGKILL N nvim/nvims process(es)
  2. Restart opencode-serve.service (this Claude session's TUI will reconnect)
  3. Respawn nvims in N pane(s)
  4. Restore K opencode TUI(s) via oc-auto-attach
```

(Sessions are no longer deleted, so that line is removed; restoration replaces it as item 4.)

## Error handling

- **Empty OPENCODE_MANIFEST:** step 8 is a no-op. Same path users already see when they run `reset-workspace` with no opencode TUIs running.
- **Snapshot fails entirely** (e.g., `pgrep` itself errors, /proc inaccessible): log error, set `OPENCODE_MANIFEST` to empty, continue. Don't abort — the kill+restart memory-hygiene path should still work even if restoration is broken.
- **Per-session restore failure:** `oc-auto-attach` swallows its own errors and exits 0. We log "restored $sid (or oc-auto-attach declined; see its log lines above)" and move on.
- **Race: a captured TUI's process dies between snapshot and restore.** Doesn't matter — we have the session id, opencode-serve still has the session in the DB, oc-auto-attach will spin up a fresh `opencode attach` for it.

## Behavior changes vs. existing reset-workspace

| Aspect | Old | New |
|---|---|---|
| Session deletion in step 4 | DELETE all sessions | Keep all |
| Memory hygiene goal | Restart serve | Same (still the primary point of the nightly run) |
| Nightly path = manual path | Yes | Yes (same script, same `--yes` flag) |
| Opencode TUI restoration | None | Snapshot live opencode pids, restore via oc-auto-attach loop |
| What "live" means | n/a | Any opencode process owned by `dev` that isn't `opencode serve` |

## Side concerns / out of scope

- **DB growth.** Today's DB has 1,501 sessions; the old reset-workspace was the only thing pruning. With session deletion removed, the DB grows monotonically. We will file a follow-up bd issue for a separate periodic cleanup (e.g., delete sessions whose `time_updated` is >30 days ago, or trim to a max count). NOT in scope here — `reap-stale-opencode` already kills stale opencode *processes*; we want a sibling for *sessions*.
- **Bare opencode with no log file fd.** If the user launched opencode with stdin/stdout/stderr closed (unusual — most launches go via tmux/sshd which keep them open), the log-file fallback finds nothing. We log a WARNING and skip. The TUI doesn't get restored. Rare and acceptable.
- **TUIs whose session.directory isn't under `~/projects/`.** `oc-auto-attach` falls back to `basename $session_dir` for the window name and uses the raw `session_dir` as the project key. Should still work; just may create a new window with an unfamiliar name.

## Testing

- **Per-task smoke tests** as the implementation lands (snapshot block prints expected manifest given current state; restore block invokes oc-auto-attach for each captured id).
- **End-to-end:** trigger `sudo systemctl start nightly-restart-background.service` with at least one opencode TUI open in an nvim pane. Verify in the journal that the TUI's session id is captured in OPENCODE_MANIFEST and a `oc-auto-attach $sid` call is logged. Visually verify post-reset that the TUI re-appears in the appropriate pane.

## Open / deferred

- DB session pruning (separate bd issue, not this work).
- Restoring multi-tab nvims where two `:te opencode -s ses_xxx` tabs were open in the same nvim. The new design handles this naturally — both session ids end up in `OPENCODE_MANIFEST`, and `oc-auto-attach`'s pane resolution will route both to the same nvim, opening two tabs. No special handling needed in our code.
