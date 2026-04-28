---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — to kill all nvims, clear stale sessions, restart opencode-serve, or understand the nightly reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

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
captured N restorable session(s) (raw: M strict-attach + K bare-resolved; dedupe may collapse); J bare TUI(s) skipped
```

The "raw: …; dedupe may collapse" wording is intentional: M and K are
pre-dedupe counts (raw TUIs / pgrep matches) and may exceed N when sids
collide.

If you expected a session to be restored and it wasn't, check the journal for:
- `pid=... sid=... cwd=...` (strict-attach success)
- `pid=... (bare-resolved) sid=... cwd=...` (bare-resolved success)
- `WARNING: bare opencode TUI pid=... cwd=...` (skipped)

See `docs/plans/2026-04-27-bare-tui-restoration-design.md` for the
design rationale, including the deferred tear-down-rebuild
simplification.

## What it does (in order)

1. Snapshots the tmux panes currently running `nvim`/`nvims`.
2. Snapshots live opencode TUIs/processes (one session id per non-serve `opencode` process).
3. Confirms with the user (skip with `--yes`).
4. SIGKILLs all `nvim` processes owned by `dev`.
5. Restarts `opencode-serve.service` (passwordless sudo).
6. Respawns `nvims` in each manifest pane (with original cwd).
7. Restores each captured opencode TUI via `oc-auto-attach <session-id>`.
8. Verifies each `/tmp/nvim-${PANE#%}.sock` exists.

Concurrent runs are blocked by `flock /tmp/reset-workspace.lock`.

## When to use

- After landing changes to `nvims`, `oc-auto-attach`, or anything else that needs a fresh process to take effect.
- When opencode-serve has bloated past ~6 GB (memory hygiene).
- When the auto-attach plumbing is misbehaving and you want a known-good baseline.

## Nightly autonomous run

`systemd.services.nightly-restart-background` invokes `reset-workspace --yes` at 3 AM EDT daily. It runs as user `dev` with `TMUX_TMPDIR=/tmp/tmux-1000`.

To inspect:
```bash
systemctl list-timers nightly-restart-background
journalctl -u nightly-restart-background.service --since today
```

To trigger early (any time):
```bash
sudo systemctl start nightly-restart-background.service
```

## Caveats

- This Claude session's TUI will reconnect when serve restarts. Brief flicker.
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will have their PROCESSES killed by the SIGKILL pass and their session ids captured. Post-respawn, those sessions get a TUI restored via `oc-auto-attach` — but the headless worker is NOT re-launched (we only restore TUIs, not arbitrary headless invocations). Sessions persist in the DB.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).
- **Cgroup gotcha (fixed 2026-04-26).** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. Steps 1–5 (snapshot + kill nvims + fire systemctl restart) ran, but the SIGTERM cascade from `KillMode=control-group` killed the script itself before steps 6–7 (respawn nvims, restore TUIs) could run. The script now self-detaches into a `systemd-run --user --scope` transient unit at entry if it detects `opencode-serve.service` in its own cgroup. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.

## Sessions persist across resets

Unlike the original design, `reset-workspace` no longer DELETEs opencode sessions. Sessions accumulate in the DB across resets (today: ~1500 sessions). A sibling cleanup job for stale session pruning is on the backlog — see git history of this skill or `bd` for details.

## Related

- Design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Plan: `docs/plans/2026-04-24-reset-workspace-plan.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
