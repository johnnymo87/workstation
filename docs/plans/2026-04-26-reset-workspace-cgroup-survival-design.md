# reset-workspace: surviving the cgroup it restarts

**Status:** draft 2026-04-26
**Bead:** `workstation-pqu`
**Authoritative companions:**
- `2026-04-24-reset-workspace-design.md` — original reset-workspace design
- `2026-04-24-reset-workspace-plan.md` — original implementation plan
- `2026-04-25-reset-workspace-restore-design.md` — TUI restoration design
- `2026-04-25-reset-workspace-restore-plan.md` — TUI restoration plan

## Goal

Make `reset-workspace` work correctly when invoked from inside `opencode-serve.service`'s control group (i.e. when an opencode TUI/agent attached to the systemd serve daemon calls it via the bash tool). Today the script silently dies mid-flight in this scenario, leaving nvims dead and TUIs unrestored.

## Non-goals

- Change the user-facing CLI surface. `reset-workspace [--yes]` stays as it is.
- Change the snapshot, kill, restore, or socket-verification logic. Only the cgroup-survival mechanism changes.
- Re-design the systemd unit hierarchy or move opencode-serve to a different `KillMode`. Those would have wider blast radius and are not necessary.

## Background: why the script dies

`opencode-serve.service` runs with the systemd default `KillMode=control-group`. When `systemctl restart opencode-serve.service` fires, systemd sends `SIGTERM` (then `SIGKILL` after `TimeoutStopSec`) to **every PID in the unit's cgroup**.

When the user's opencode TUI is the systemd-managed one (attached via `opencode attach http://127.0.0.1:4096 --session ...`), the bash subprocess that the agent's bash tool spawns is parented by the project-server worker, which itself lives inside `opencode-serve.service`'s cgroup. So the script that triggered the restart is a child of the unit it just restarted — and dies in the SIGTERM cascade.

Evidence (from `/home/dev/.local/share/opencode/log/2026-04-26T173506.log`, this incident):
```
50007  18:15:06   bash tool runs `reset-workspace --yes 2>&1 | tail -30`
50013  18:15:06   116ms later: server-proxy worker shutting down
50023  18:15:06   ERROR session.processor session.id=ses_2352... error=Aborted process
```

Steps 1–5 (snapshot, kill nvims, fire systemctl restart) had time to run. Steps 6–7 (respawn nvims, restore TUIs, verify sockets) did not. We confirmed this by:
- Inspecting tmux state post-incident: nvims absent in 3 of 4 panes, exactly the cgroup death pattern.
- Confirming the systemd journal shows no health-check polling activity for opencode-serve in the window between the script's restart and the user's bug report.
- Verifying the nightly cron unit (`nightly-restart-background.service`) is in its own cgroup and does not have this problem; same for tmux-pane invocations parented by `tmux-spawn-*.scope`.

## Architecture

Add a single self-detach step at the script's entry point, layered on top of the existing flock re-exec. If — and only if — the script detects that its own cgroup contains `opencode-serve.service`, it re-execs itself in a transient user scope unit via `systemd-run --user --scope`. Once relocated, it falls through to the normal flock + main pipeline. All other invocations (nightly cron, tmux pane shell, devbox without opencode-serve at all) skip the re-exec entirely.

```
                              [entry]
                                 |
                                 v
                  cgroup contains opencode-serve.service?
                                 |
                       no -------+------- yes
                       |                   |
                       |                   v
                       |     RESET_WORKSPACE_DETACHED already set?
                       |                   |
                       |          no ------+------ yes
                       |          |                |
                       |          v                |
                       |    re-exec via            |
                       |    systemd-run --user     |
                       |    --scope $0 "$@"        |
                       |    (then exit)            |
                       |                           |
                       +-----------+---------------+
                                   |
                                   v
                       existing flock re-exec block (unchanged)
                                   |
                                   v
                       Steps 1–7 (unchanged)
```

## Detection algorithm

Read `/proc/self/cgroup`. Each line is `hierarchy:controllers:path`. On cgroup v2 (which cloudbox uses) there is exactly one line, prefix `0::`. The path looks like one of:

```
0::/system.slice/opencode-serve.service                                       <-- DANGER
0::/user.slice/user-1000.slice/user@1000.service/.../tmux-spawn-*.scope        <-- safe (tmux)
0::/system.slice/nightly-restart-background.service                            <-- safe (cron)
0::/system.slice/system-getty.slice/getty@tty1.service                         <-- safe (login shell)
```

Detection: `grep -qF '/opencode-serve.service' /proc/self/cgroup`. We use `-F` (fixed string, not regex) and the leading `/` to avoid matching a hypothetical `not-opencode-serve.service` substring. If grep returns 0, we're in danger.

This works on cgroup v2. We do not need v1 fallback — cloudbox is NixOS 25.11 with systemd 258 (cgroup v2 unified hierarchy).

## Re-exec algorithm

If detection fires AND `RESET_WORKSPACE_DETACHED` is unset:

```bash
export RESET_WORKSPACE_DETACHED=1
# Pass --collect so the scope is GC'd as soon as we exit, otherwise it lingers as failed/inactive.
# Pass --quiet to suppress the "Running scope as unit run-rXXXXX.scope" banner on stderr.
# Use --pty so the child still has a TTY (for the [y/N] prompt path; --yes path doesn't need it).
# Pass -- to terminate systemd-run options before our argv.
exec systemd-run --user --scope --collect --quiet --pty -- "$0" "$@"
```

Why `--user` (not system-wide):
- We are user `dev`. `--user` requires no sudo, and the resulting transient scope is parented by `user@1000.service`, completely outside `opencode-serve.service`'s cgroup.
- The user systemd manager (PID 714 on cloudbox) is always running on cloudbox and is the right home for ephemeral user-side scopes.

Why `--scope` (not `--unit` or `--service`):
- `--scope` registers the *current* (about-to-be-execed) process tree as a transient scope unit. No fork-and-track gymnastics, no PID-1 wrapping. The `exec` replaces the current process image; systemd places it in the new scope before it starts.
- `--service` would daemonize and detach our stdout/stderr/stdin from the agent's bash tool — we'd lose all output capture.

Why preserve `RESET_WORKSPACE_DETACHED`:
- After re-exec, the new process re-evaluates the detection check. Without the env guard, we'd loop infinitely (the script would still be in opencode-serve's cgroup at the instant the new shell starts, until systemd-run finishes the cgroup migration — race-prone). The env var short-circuits any second pass.

Why this is safe to layer with the existing flock re-exec (lines 56–66):
- Cgroup re-exec runs first. After it succeeds, the second-pass script enters with `RESET_WORKSPACE_DETACHED=1` set, falls through detection, and proceeds to the flock block. flock then sees `RESET_WORKSPACE_LOCKED` is unset, takes the lock via its own self-re-exec, and proceeds. Two re-execs in series, fine.

## Edge cases

- **systemd-run not on PATH.** The script's `runtimeInputs` already includes `util-linux` (for `flock`). systemd is in the system PATH on every cloudbox/devbox; we add `pkgs.systemd` to `runtimeInputs` to make this explicit and robust.
- **`--user --scope` requires `XDG_RUNTIME_DIR`.** systemd-run --user reads `XDG_RUNTIME_DIR` to find the user manager's private socket. The agent's bash tool inherits the env from opencode-serve, which inherits from systemd, which sets `XDG_RUNTIME_DIR=/run/user/1000`. Verified manually on cloudbox: `XDG_RUNTIME_DIR=/run/user/1000 systemd-run --user --scope -- /bin/echo hi` succeeds (the echo failure in the verification was a missing /bin/echo on NixOS, not a systemd-run failure).
- **`--user --scope` from inside a system-slice cgroup.** systemd-run is happy to relocate processes across user/system slice boundaries. The new scope lives under `user@1000.service` regardless of where it was invoked from.
- **No user systemd manager (e.g. minimal CI/sandbox).** `systemd-run --user --scope ...` returns non-zero with `Failed to start transient scope unit`. The script logs the error and falls through to running in-place — same failure mode the user already lives with today, so we don't make anything worse. We do log a WARNING so the operator notices.
- **Re-exec'd script needs the same args.** `"$@"` preserves them verbatim including `--yes` and any future flags.
- **stdin for the [y/N] prompt.** `--pty` allocates a pseudo-tty for the new scope so the prompt still works on interactive invocations. With `--yes`, the prompt is skipped, so the pty is unused but harmless.
- **Output buffering.** The agent's bash tool reads stdout/stderr from the script. With `--scope`, the new process inherits the original fds — no buffering layer is added.
- **Exit code propagation.** `exec systemd-run ...` replaces the current process, so the original caller sees systemd-run's exit code, which is the script's exit code. Standard.

## Behavior changes vs. existing reset-workspace

| Concern | Today | After fix |
|---|---|---|
| Invocation from tmux pane shell | works | works (no re-exec, detection is false) |
| Invocation from `nightly-restart-background.service` | works | works (no re-exec) |
| Invocation from agent bash tool inside opencode-serve | **silent half-failure** | works (re-exec'd into user scope) |
| Invocation from agent bash tool in standalone TUI (e.g. `opencode -s ses_xxx` from tmux) | works (already in tmux's cgroup) | works (no re-exec) |
| Output visible in caller | yes | yes (--pty preserves stdio) |
| Exit code | propagated | propagated |
| Adds a transient user-scope unit per invocation | no | yes (`run-rXXXXX.scope`, GC'd via `--collect`) |
| Adds a runtime dep | no | `pkgs.systemd` (already in system PATH) |

## Verification matrix

| Scenario | Detection | Re-exec? | Expected outcome |
|---|---|---|---|
| `bash` shell in tmux pane | cgroup contains `tmux-spawn-*.scope` | no | runs in-place, succeeds |
| `sudo systemctl start nightly-restart-background.service` | cgroup contains `nightly-restart-background.service` | no | runs in-place, succeeds |
| Agent bash tool inside opencode-serve.service | cgroup contains `opencode-serve.service` | yes | re-exec into `user@1000.service/run-rXXX.scope`, succeeds |
| Agent bash tool inside standalone `opencode -s` (no serve) | cgroup contains `tmux-spawn-*.scope` | no | runs in-place, succeeds |

Each row will get a manual reproduction step in the implementation plan.

## Documentation update

Add a short paragraph to `.opencode/skills/resetting-workspace/SKILL.md` under a new "Caveats" item:

> **Cgroup gotcha (fixed 2026-04-26):** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. The script now self-detaches into a user systemd scope before doing destructive work, so it survives the restart it triggers. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.

## Out of scope (filed as separate beads if pursued)

- Switch `opencode-serve.service` to `KillMode=mixed` so only MainPID gets killed, not the cgroup. Would also fix this bug, but with much larger blast radius (could leak orphaned children of opencode-serve on every restart). Not chosen.
- Add a `--detach` flag to `reset-workspace` for explicit caller-side control. Not needed; auto-detection is correct in 100% of cases we know of.
- Capture the re-exec'd run's stdout/stderr to a file in addition to streaming back to the caller. Useful for debugging but not necessary for correctness. Defer until we have a concrete need.
