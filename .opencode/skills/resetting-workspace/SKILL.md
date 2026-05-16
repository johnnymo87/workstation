---
name: resetting-workspace
description: Use when the user wants a fresh start on cloudbox — to kill all nvims, clear stale sessions, restart opencode-serve, or understand the nightly reset.
---

# Resetting the Workspace

`reset-workspace` is a single command that fully resets the cloudbox dev environment.

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
- All in-flight headless opencode workers (e.g., spawned via `opencode-launch` or pigeon `/launch`) will have their PROCESSES killed by the SIGKILL pass and their session ids captured in the snapshot. Those captured sids are written to the manifest the recommendation session sees, so they'll appear in the morning Telegram recommendation alongside everything else — but no TUI is auto-restored. The session itself persists in the DB.
- nvim is treated as disposable — no graceful quit, no `:wa`. By design (cloudbox nvim is purely a host for opencode tabs).
- **Cgroup gotcha (fixed 2026-04-26).** Earlier versions of `reset-workspace` would silently die when invoked from an opencode-agent bash tool whose TUI was attached to `opencode-serve.service`. Steps 1–5 (snapshot + kill nvims + fire systemctl restart) ran, but the SIGTERM cascade from `KillMode=control-group` killed the script itself before steps 6–7 (respawn nvims, restore TUIs) could run. The script now self-detaches into a `systemd-run --user --scope` transient unit at entry if it detects `opencode-serve.service` in its own cgroup. See `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md` for details.
- **Recommendation session failure mode.** If the recommendation session fails to spawn, crashes mid-work, never sends a Telegram message, or you're offline / ignoring Telegram, no tabs come back. This is intentional — the alternative (auto-restore as a fallback) would re-introduce the wall-of-tabs problem the recommendation flow was designed to solve. Observe via `journalctl -u nightly-restart-background.service` (look for the `[reset-workspace]` `wrote N sid(s) ...` / `launching recommendation session in ~ ...` lines, or for `WARNING:` lines if it didn't get that far).

## Sessions persist across resets

Unlike the original design, `reset-workspace` no longer DELETEs opencode sessions. Sessions accumulate in the DB across resets (today: ~1500 sessions). A sibling cleanup job for stale session pruning is on the backlog — see git history of this skill or `bd` for details.

## Related

- Design (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-design.md`
- Plan (current revision): `docs/plans/2026-05-16-recommendation-driven-reset-plan.md`
- Original design: `docs/plans/2026-04-24-reset-workspace-design.md`
- Companion skill: `.opencode/skills/automated-updates/SKILL.md` (other timer-driven jobs).
