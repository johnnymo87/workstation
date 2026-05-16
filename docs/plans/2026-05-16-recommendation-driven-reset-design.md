# Recommendation-driven nightly reset

## Context

`reset-workspace` runs at 3 AM EDT via `nightly-restart-background.service`
on cloudbox. Today it does end-to-end auto-restoration: snapshots live
nvim panes and live opencode TUIs, kills nvims, restarts opencode-serve,
respawns nvims in their original cwd, and runs `oc-auto-attach` for each
captured sid to recreate every tab.

Two problems with the auto-restore approach:

1. **Wall-of-tabs in the morning.** Every session you happened to leave
   open the previous night comes back, including ones you'd mentally
   finished with but hadn't dismissed. The user spends morning closing
   tabs.
2. **Information density.** Recreated tabs convey "this was open" but
   nothing about *what was happening* in each session, so deciding which
   to engage with requires opening each one.

The DB tracks ~1953 total sessions (~351 root sessions, ~27 touched in
the last 24h). The pgrep snapshot today picks up only the subset that
have live TUIs — typically much smaller — which matches the desired
"things I haven't dismissed yet" signal.

## Goal

Replace the auto-restore with a single recommendation session that reads
the same snapshot, enriches each entry via the opencode-serve API,
messages the user via Telegram with conversational recommendations, and
on reply selectively re-opens only the chosen sessions.

## Non-goals

- Widening the snapshot beyond live TUIs (e.g. "all sessions touched in
  the last N hours"). The "live TUI == not yet dismissed" signal is
  exactly what we want.
- Pruning stale sessions from the DB (tracked separately in
  workstation-p2l).
- Replacing the deferred runtime manifest under
  `$XDG_RUNTIME_DIR/opencode/tui/<pid>.json` that would let us drop
  bare-resolution. That's a future simplification, independent of this
  work.
- Adding a fallback "restore everything if the user doesn't reply"
  timer. Failure mode is intentionally "do nothing" — better to wake up
  to no tabs than to the wrong tabs.

## Architecture

```
3 AM EDT
  ↓
nightly-restart-background.service
  ↓ runs as user dev
reset-workspace --yes
  ├─ snapshot live TUIs → sids (both strict-attach + bare-resolved branches)
  ├─ write sids to /tmp/reset-workspace-last-manifest.txt
  ├─ SIGKILL nvims (no respawn)
  ├─ restart opencode-serve, wait healthy
  └─ opencode-launch ~ "<recommendation prompt>"
       ↓ pigeon plugin auto-registers with daemon
recommendation session (headless, cwd=~)
  ├─ reads /tmp/reset-workspace-last-manifest.txt
  ├─ for each sid: GET /session/<sid> on serve, enrich with title/dir/updated
  ├─ ranks / groups, drafts conversational recommendation message
  ├─ sends Telegram message via question tool, blocks awaiting reply
       ↓ user replies in Telegram
       ↓ pigeon routes reply back to this sid
recommendation session resumes
  ├─ parses reply (free-form: "1,3,5" / "all" / "none" / "1 and 4")
  └─ for each chosen sid: exec `oc-auto-attach $sid`
        ↓ oc-auto-attach creates tmux window + nvim if needed,
          opens tab with `opencode attach --session <sid>`
```

User wakes up to: zero tabs if they ignored the message, exactly the
tabs they asked for if they replied.

## Changes to `pkgs/reset-workspace/default.nix`

**Removed:**

- Step 1 (snapshot tmux nvim/nvims panes via `tmux list-panes`).
- Step 6 (respawn nvims via `tmux send-keys "cd $path && nvims"`).
- Step 7 (verify `/tmp/nvim-${PANE#%}.sock` exists for each manifest pane).
- Step 6.5 (the `for sid in $OPENCODE_MANIFEST; do oc-auto-attach ...`
  loop).

**Kept:**

- The `systemd-run --user --scope` re-exec at entry (cgroup survival —
  documented in `docs/plans/2026-04-26-reset-workspace-cgroup-survival-design.md`).
- The flock re-exec (concurrency guard on `/tmp/reset-workspace.lock`).
- Step 2: both pgrep loops (strict-attach + bare-resolved). The strict
  loop captures `opencode attach <url> --session ses_xxx [--dir ...]`
  TUIs; the bare-resolved loop reads `/proc/<pid>/cwd` for bare `:te
  opencode` TUIs and asks serve for the most-recent root session in
  that cwd. Both feed `OPENCODE_MANIFEST`.
- Step 2's confirmation prompt (`--yes` skips it as today).
- Step 4: `pkill -9 -u dev -x nvim`.
- Step 5: `sudo systemctl restart opencode-serve.service` +
  `/global/health` poll.

**Added:**

- Manifest writeout: dedupe `OPENCODE_MANIFEST`, write one sid per line
  to `/tmp/reset-workspace-last-manifest.txt` (overwriting any prior
  file).
- Recommendation session spawn: shell out to
  `opencode-launch ~ "$RECOMMENDATION_PROMPT"`. The prompt is baked
  into the script as a heredoc. If `opencode-launch` is not on PATH or
  exits non-zero, log a warning but exit 0 (don't break the reset).
- A `MANIFEST_COUNT == 0` fast-path: if no sessions to recommend, don't
  spawn a session — write the manifest file empty and log "no sessions
  to recommend; skipping".

## Recommendation prompt (loose, judgmental)

Baked into reset-workspace as a heredoc, passed as the second arg to
`opencode-launch`:

> You're the morning recommendation agent. The user has just gone
> through a nightly reset of their workspace. Read the file at
> `/tmp/reset-workspace-last-manifest.txt` — it contains one opencode
> session id per line, representing sessions that had a live TUI at
> reset time.
>
> For each sid, fetch its metadata from
> `GET http://127.0.0.1:4096/session/<sid>` and look at the title,
> directory, and last update time. If useful, also fetch recent
> messages from `GET http://127.0.0.1:4096/session/<sid>/message` to
> get a sense of whether the session was mid-task or wrapped up.
>
> Build a short, conversational Telegram message recommending which
> sessions to reopen and why. Be opinionated. Group by project. If
> something looks finished (a PR landed, a question got resolved), say
> so. If something looks mid-flight, say that too. Number the
> recommendations so the user can refer to them by number.
>
> Then use the question tool to ask the user which to reopen. Accept
> free-form replies like "1,3,5", "all", "none", "the mono ones".
>
> When they reply, parse their selection and for each chosen sid, run
> `oc-auto-attach <sid>` in a bash tool. Report a brief summary of what
> was opened.
>
> If the manifest file is missing or empty, message the user "Nightly
> reset complete, no sessions to recommend." and exit.

This deliberately gives the LLM room to use judgment about what to
recommend and how to phrase the message. The cost of variability is
acceptable; the value of judgment over a templated message is the whole
point of using an LLM here instead of a bash script.

## Data flow

- `OPENCODE_MANIFEST` (in-script, bash variable, newline-separated sids,
  deduped) → `/tmp/reset-workspace-last-manifest.txt` (filesystem,
  newline-separated sids) → recommendation session reads the file →
  serve API enriches each → Telegram message → user reply →
  recommendation session shells out to `oc-auto-attach` per chosen sid.

## Failure modes

| Failure | Behavior |
|---------|----------|
| `opencode-launch` not on PATH | reset logs warning, exits 0. User wakes up to no tabs and no recommendation. Visible in systemd journal. |
| `opencode-launch` fails to create session | Same — log warning, exit 0. |
| Recommendation session crashes mid-work | Pigeon never sends Telegram message. User wakes up to no tabs. Crash visible via `journalctl -u opencode-serve` or session message log. |
| User ignores Telegram | Recommendation session stays parked indefinitely (cost is not a concern per user). Tomorrow's reset's pgrep will capture it as a live TUI; cwd=~ has no root session, so bare-resolved branch will skip it; it gets SIGKILL'd in step 4 like any other process. |
| User replies with nonsense | Recommendation session does its best to parse; on failure it can ask for clarification (LLM judgment). |
| `oc-auto-attach` fails for one of the chosen sids | Logged to `/tmp/oc-auto-attach.log`; recommendation session reports failure in its summary message. |
| Manifest file missing when recommendation session reads it (race?) | Not possible — reset writes the file synchronously before spawning the session. But if it did happen, the prompt instructs the session to message "no sessions to recommend." |

All non-fatal in user-impact terms. Observability is via the same
journal + log channels that exist today; no new tooling needed.

## What we explicitly chose not to do

| Option | Why rejected |
|--------|--------------|
| Widen scope to "all sessions touched in last N hours" | The "live TUI" signal IS the "not yet dismissed" signal. Widening would resurrect sessions the user had already moved past. |
| Tight templated recommendation prompt | If we want deterministic output we'd skip the LLM. The judgment is the value. |
| Rich pre-computed manifest (sid + title + cwd + updated) | Keeps reset dumb; lets the session enrich via the existing API. |
| Fallback "restore-everything after N minutes if no reply" | Would re-introduce the wall-of-tabs problem on bad-comms mornings. User explicitly chose "do nothing" failure mode. |
| Drop bare-resolved snapshot branch | Reverts workstation-2rn. Bare TUIs would silently fail to make it into recommendations. Independent simplification; pursue only if/when the runtime manifest replaces it. |
| Drop strict-attach branch in favor of bare-resolved alone | Bare-resolution collapses worktrees (workstation-dwb). Loses precision; not safe to consolidate this way. |
| Hard timeout on the recommendation session | No reason — cost isn't a concern, and a stranded session is harmless. |
| Telegram-less variant (write digest to file) | Loses the interactive "reply and have it execute" loop, which is the whole UX win. |

## Out of scope / future work

- **Runtime TUI manifest** (`$XDG_RUNTIME_DIR/opencode/tui/<pid>.json`):
  would let bare TUIs self-register their sid at session-open time,
  removing the need for the bare-resolved branch and its cwd-collapsing
  imprecision. Independent simplification, file separately.
- **Stale session pruning** (workstation-p2l): the recommendation
  session naturally has visibility into "what's still in the DB but
  hasn't been touched in months." Could grow into a sibling
  recommendation flow over time. Not part of this scope.
- **In-flight question protection** (workstation-dg6): if a session has
  an outstanding question at reset time, it gets wedged by the
  opencode-serve restart. Orthogonal to this work; tracked separately.

## Files touched

- `pkgs/reset-workspace/default.nix` — the changes above.
- `.opencode/skills/resetting-workspace/SKILL.md` — update the "What
  survives a reset" + "What it does (in order)" sections to reflect the
  new flow.
- New issue in beads to track this work.

## Sequencing

Per the brainstorming conversation: land this design first; leave the
two-branch snapshot in `pkgs/reset-workspace/default.nix` alone (it
still populates the manifest the recommendation session reads). The
deferred runtime-manifest simplification is independent future work.
