---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — to kill all nvims, clear stale sessions, restart opencode-serve, or understand the nightly reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

## What survives a reset

Nothing on screen. `reset-workspace` tears down every nvim and bounces the
opencode serve pool; no TUI is captured, no tab is reopened, and nothing is
recommended to you afterwards. You wake up to a clean `main` tmux session.

Your **sessions** survive — they live in `opencode.db`, not in the TUI (see
"Sessions persist across resets" below). Reopen one by hand with
`oc-auto-attach <sid>`.

> **Removed 2026-08-10.** Earlier revisions captured the live TUIs into
> `/tmp/reset-workspace-last-manifest.txt` and spawned a "morning agent" in
> `~/morning` that Telegrammed you a numbered list and reopened whatever you
> picked. That whole restore/recommend flow is gone: the manifest is no longer
> written, the morning agent is no longer launched, and `~/morning` is no longer
> created.

## What it does (in order)

1. Confirms with the user (skip with `--yes`).
2. Exits every `nvim` owned by `dev` **one at a time** (`kill -TERM`, wait,
   SIGKILL only a straggler). Not a `pkill -9`: killing a pane's client makes
   its `nvim --embed` server graceful-*write* its ShaDa, and a burst of those
   corrupted the history file. Serialized exits also *merge* history rather
   than clobbering it (workstation-zv0l).
3. Tears down the `lgtm` junk-drawer tmux session (memory hygiene). This runs
   **here**, after the walk, not first: `kill-session` tears down every pane at
   once, and each pane's server graceful-writes ShaDa, so doing it early
   produced exactly the write burst step 2 exists to prevent
   (workstation-n0yh.1). Because it is in the destructive tail, **aborting at
   the `[y/N]` prompt leaves the lgtm session alive** (it used to be destroyed
   before you answered).
4. Repairs a corrupt `main.shada` if one is found, then reaps its temps.
5. Prunes merged `opencode-launch --worktree` leftovers in `~/projects/mono`
   via `work --prune-merged` (best-effort; a failure never fails the reset).
   Runs *before* the pool restart so a restart failure can't skip it.
6. Restarts the opencode serve pool (`opencode-serve-pool.target`; user
   `systemctl --user` on devbox, passwordless sudo on cloudbox) and
   waits for every pool member to report healthy.

Concurrent runs are blocked by `flock /tmp/reset-workspace.lock`.

## When to use

- After landing changes to `nvims`, `oc-auto-attach`, or anything else that needs a fresh process to take effect.
- When opencode-serve has bloated past ~6 GB (memory hygiene).
- When tabs have accumulated past what you want to deal with and you want them all gone.

## Nightly autonomous run

`systemd.services.nightly-restart-background` invokes `reset-workspace --yes` at 3 AM EDT daily. It runs as user `dev` with `TMUX_TMPDIR=/tmp`.

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
- Opencode workers spawned via `opencode-launch` or pigeon `/launch` lose their TUI like everything else; the session itself persists in the DB. Any nvim host dies in the SIGKILL pass regardless.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).
- **Cgroup gotcha (fixed 2026-04-26).** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. The kill + restart steps ran, but the SIGTERM cascade from `KillMode=control-group` killed the script itself before the later steps could run. The script now self-detaches into a `systemd-run --user --scope` transient unit at entry if it detects `opencode-serve.service` in its own cgroup. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.
- **Your session's long-running child processes die, and that is intended, not a bug.** The pool restart bounces every `opencode-serve@<port>.service`, and their `PartOf=` linkage tears down each serve's whole cgroup. So anything a session spawned and left running — `kubectl port-forward`, `kubectl exec`, `kubectl run -it`, `az`, tunnels, watchers, dev servers — is SIGKILLed along with the serve. `tmux kill-session -t '=lgtm'` does the same to that session's panes (since workstation-n0yh.1 it runs after every nvim has already been exited one at a time, so it no longer triggers a ShaDa write burst). A session mid-investigation genuinely loses its port-forwards at 03:00; that is the cost of a workspace reset, not an incidental defect, and there is no fix at the reset layer (avoiding it means launching those processes *outside* the serve cgroup, e.g. under `systemd-run --scope` — session tooling, not `reset-workspace`).

  **It kills local clients, not remote resources.** This distinction has already caused one misdiagnosis (2026-07-27): a session concluded the reset had killed its *prod pods* and broken its *kube context*. Neither was true. `reset-workspace` contains zero kube references; `find ~/.kube -newermt 02:55 ! -newermt 03:10` across the reset window returns empty; `~/.kube/config`'s mtime was four hours *before* the reset. The context had been repointed by **another session** — `~/.kube/config` is one mutable file shared by every session on the box (see `bd workstation-ev9n`) — and the "killed" pods were bare `kubectl run … sleep infinity` pods with no `ownerReferences`, which in fact *survive* resets indefinitely (`bd workstation-oc4g`).  Before blaming the reset for remote state, check whether it could reach that state at all: it only ever kills local processes.

## Sessions persist across resets

`reset-workspace` does not DELETE opencode sessions. Sessions accumulate in the DB across resets (today: ~1500 sessions). A sibling cleanup job for stale session pruning is on the backlog — see git history of this skill or `bd` for details.

## Related

- Original design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
