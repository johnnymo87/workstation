---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — to kill all nvims, clear stale sessions, restart opencode-serve, or understand the nightly reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

## What survives a reset

`reset-workspace` captures the live opencode TUIs at reset time but
does NOT auto-restore them. Instead, right after capture is confirmed —
before the SIGKILL + pool-restart gauntlet, so a failed restart can't
discard a successful capture (workstation-3smg) — it writes the
captured session ids to `/tmp/reset-workspace-last-manifest.txt`. Once
the pool is back and healthy, it launches a headless opencode session
in `~` with a baked-in prompt instructing it to:

1. Read the manifest.
2. Enrich each sid via `GET http://127.0.0.1:4096/session/<sid>` (title,
   directory, last update, optionally recent messages).
3. Send a conversational Telegram message recommending which sessions
   to reopen and why, with numbered options.
4. Wait for your Telegram reply (free-form: "1,3", "all", "none", etc).
5. For each chosen sid, exec `oc-auto-attach --tmux-session main <sid>`
   to create the tab. The `--tmux-session main` is mandatory: the
   recommendation session is headless (not attached to tmux), so a bare
   `oc-auto-attach` would drop the tab into whatever session tmux deems
   "current" instead of the user's `main` session.

You wake up to: no tabs if you ignored the Telegram message, exactly
the tabs you asked for if you replied.

**Capture scope: the `main` tmux session only (allowlist).** Before
snapshotting, the script builds an allowlist of every pid in the
process subtree of every pane in your interactive `main` tmux session.
A TUI is captured only if its pid is in that set. This is why you only
ever get your `main` session back: lgtm review TUIs (which live in a
separate `lgtm` tmux session) and orphaned attach clients (whose pane
was torn down, leaving the process reparented to init and in no
session) are structurally excluded. If there is no `main` session the
allowlist is empty and the manifest comes out empty.

> Why an allowlist? The prior revision used a *denylist* — capture every
> `opencode attach` process, then subtract the lgtm tmux subtree. It
> leaked: orphaned lgtm attach clients weren't in any pane subtree, so
> they slipped past the subtraction and dominated the morning
> recommendations. The allowlist (capture only what's in `main`) is
> robust against orphans and any future junk-drawer sessions. See
> workstation commit `4b47b82`.

Within that `main` scope, the snapshot captures TUIs in two ways --
both feed the manifest the recommendation session reads:

1. **Direct (argv-based)**: TUIs launched via Telegram `/launch` or
   `opencode-launch` (CLI) carry their session id in the
   `--session ses_xxx` argv, captured directly by the strict-attach
   regex.

2. **Resolved (cwd-based)**: Bare `:te opencode` TUIs have no sid in
   argv; the bare loop resolves their `/proc/<pid>/cwd` to the
   most-recent root session for that directory via
   `GET <healthy-pool-member>/session?directory=...&roots=true&limit=1`.
   Before either loop runs, the whole pool (not just serve-0 / 4096) is
   probed for `/global/health`; the first serve to answer becomes the
   resolution target. If none answer, this cwd-resolve loop is skipped,
   but the argv-based loop above still runs — it reads `/proc` directly
   and touches no serve, so a fully-wedged pool doesn't empty the
   manifest (workstation-3smg).

Each reset's journal includes a summary line of the form:

    captured N restorable session(s) (raw: M strict-attach + K bare-resolved; dedupe may collapse); J bare TUI(s) skipped

If a TUI you expected to see in the recommendation message was missing,
it most likely wasn't in the `main` tmux session at reset time. The
journal logs `main-session allowlist pids:...` for the set it built and
`skipping pid=... (not in main tmux session)` for each excluded
process — check those plus the per-pid context lines. If the
recommendation session itself failed to spawn (e.g. opencode-launch
missing from PATH), you'll see a `WARNING: opencode-launch failed` or
`WARNING: opencode-launch not on PATH` line.

## What it does (in order)

1. Tears down the `lgtm` junk-drawer tmux session (memory hygiene; its
   sessions are excluded from recommendations structurally, not by pid).
2. Builds the `main` tmux session allowlist (pid subtree of every
   `main` pane).
3. Snapshots live opencode TUIs whose pid is in the allowlist (both
   argv-based and cwd-resolved branches).
4. Confirms with the user (skip with `--yes`).
5. Writes the captured sids to `/tmp/reset-workspace-last-manifest.txt`
   (before the kill/restart gauntlet, so a failed restart can't discard
   the capture — workstation-3smg).
6. SIGKILLs all `nvim` processes owned by `dev`.
7. Restarts the opencode serve pool (`opencode-serve-pool.target`; user
   `systemctl --user` on devbox, passwordless sudo on cloudbox) and
   waits for every pool member to report healthy.
8. Launches a headless opencode session in `~` with a baked-in prompt
   that handles enrichment, Telegram messaging, and selective re-open
   on reply.

Concurrent runs are blocked by `flock /tmp/reset-workspace.lock`.

## When to use

- After landing changes to `nvims`, `oc-auto-attach`, or anything else that needs a fresh process to take effect.
- When opencode-serve has bloated past ~6 GB (memory hygiene).
- When tabs have accumulated past what you want to deal with and you want the recommendation flow to help you sort out what's worth reopening.

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
- Opencode workers spawned via `opencode-launch` or pigeon `/launch` get a TUI attached (via `oc-auto-attach`) in whatever tmux session is current at launch — usually `main`, in which case their sid is captured and shows up in the morning recommendation (no TUI is auto-restored; the session persists in the DB). A worker whose TUI landed outside `main`, or that has no tmux TUI at all, is not in the allowlist and won't be recommended, though its session still persists in the DB. Any nvim host dies in the SIGKILL pass regardless.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).
- **Cgroup gotcha (fixed 2026-04-26).** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. Steps 1–5 (snapshot + kill nvims + fire systemctl restart) ran, but the SIGTERM cascade from `KillMode=control-group` killed the script itself before steps 6–7 (respawn nvims, restore TUIs) could run. The script now self-detaches into a `systemd-run --user --scope` transient unit at entry if it detects `opencode-serve.service` in its own cgroup. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.
- **Recommendation session failure mode.** If the recommendation session fails to spawn, crashes mid-work, never sends a Telegram message, or you're offline / ignoring Telegram, no tabs come back. This is intentional — the alternative (auto-restore as a fallback) would re-introduce the wall-of-tabs problem the recommendation flow was designed to solve. Observe via `journalctl -u nightly-restart-background.service` (look for the `[reset-workspace]` `wrote N sid(s) ...` / `launching recommendation session in ~ ...` lines, or for `WARNING:` lines if it didn't get that far).

## Sessions persist across resets

Unlike the original design, `reset-workspace` no longer DELETEs opencode sessions. Sessions accumulate in the DB across resets (today: ~1500 sessions). A sibling cleanup job for stale session pruning is on the backlog — see git history of this skill or `bd` for details.

## Related

- Design (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-design.md`
- Plan (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-plan.md`
- Capture scoping (main allowlist): workstation commit `4b47b82`, which supersedes the lgtm-denylist plan `docs/plans/2026-06-04-reset-workspace-exclude-lgtm-plan.md`.
- Original design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
