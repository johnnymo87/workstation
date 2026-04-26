---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — to kill all nvims, clear stale sessions, restart opencode-serve, or understand the nightly reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

## What it does (in order)

1. Snapshots the tmux panes currently running `nvim`/`nvims`.
2. Confirms with the user (skip with `--yes`).
3. SIGKILLs all `nvim` processes owned by `dev`.
4. DELETEs every opencode session via the HTTP API.
5. Restarts `opencode-serve.service` (passwordless sudo).
6. Respawns `nvims` in each manifest pane (with original cwd).
7. Verifies each `/tmp/nvim-${PANE#%}.sock` exists.

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
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will be killed when their session is deleted. Don't run during important headless work.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).

## Related

- Design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Plan: `docs/plans/2026-04-24-reset-workspace-plan.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
