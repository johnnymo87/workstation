# Design: reset-workspace session snapshot via attach-client argv

**Date:** 2026-04-27
**Bead:** workstation-0gu
**Status:** Approved by user 2026-04-27

## Problem

The nightly `reset-workspace` run on 2026-04-27 03:00:06 successfully restarted
opencode-serve and respawned nvim, but restored zero opencode TUIs even though
sessions were live before the reset. The user had to manually `:te opencode`
to recover.

The original hypothesis (workstation-0gu description) was that opencode-serve
restart wipes session memory, invalidating session IDs captured pre-restart.
**That hypothesis is wrong.** opencode-serve persists sessions to
`~/.local/share/opencode/opencode.db` and reloads them on restart;
`GET /session/<sid>` returns the session correctly post-restart for any sid
that ever existed.

The actual root cause is in `pkgs/reset-workspace/default.nix` step 2 (session
snapshot). At 03:00:06 the only opencode TUI alive was a stuck/early-init
bare `:te opencode` (cmdline `/home/dev/.nix-profile/bin/opencode`, no args)
that had loaded plugins but never made any session API calls. Step 2's two
sid-extraction paths both failed:

1. **argv match** (`-s ses_xxx` / `--session ses_xxx`) — bare TUIs don't
   have a sid in argv.
2. **log-file fallback** (grep `path=/session/ses_xxx` from the TUI's open
   log fd) — the stuck TUI's log file (`040130.log`, 1781 bytes) contained
   plugin-loader output but zero `path=/session/` lines.

Result: `OPENCODE_COUNT=0`, step 6.5 logged "no opencode TUIs to restore",
oc-auto-attach was never called.

Evidence: `/home/dev/.local/share/opencode/log/2026-04-27T040130.log` (the
failing TUI's log) and journal entries from
`nightly-restart-background.service` at 2026-04-27 03:00:06.

## Decision: narrow the contract

Restoration support is restricted to sessions launched via:

- Telegram `/launch` (which routes through `pigeon → opencode-serve →
  oc-auto-attach`)
- `opencode-launch` CLI (same path)

Both produce a TUI process with cmdline of the form
`<binary>/opencode attach <url> --session ses_xxx`. The sid is reliably in
argv; the cwd is reliably in `/proc/<pid>/cwd` (and matches what
opencode-serve has persisted).

**Bare `:te opencode` TUIs are explicitly NOT restored across reset.** They
are intended for ad-hoc / throwaway work. Anything the user wants to survive
a reset must be launched via `/launch` or `opencode-launch`. This gives a
crisp contract that's easy to reason about and document.

A follow-up bead may extend coverage to bare TUIs later if needed (would
require either a pigeon-cwd join with stale-data risk, or patching
opencode-patched to surface the sid through a stable channel). Out of scope
for this fix.

## Why not pigeon

Pigeon's `/sessions?active=true` does have `(sid, cwd, last_seen)` for every
session that has fired at least one event. But for the narrowed scope:

- `/launch` and `opencode-launch` sessions ALWAYS have a corresponding
  `opencode attach --session <sid>` process while the TUI is alive.
- argv extraction is reliable, real-time, and zero-dependency.
- Pigeon's `state` field is unusable as an alive signal — every session in
  pigeon's DB has `state="running"` regardless of actual liveness. The
  closest pigeon liveness signal is `expires_at > now` (TTL-based), which
  lags reality by minutes/hours.
- Pigeon would only buy us anything if we wanted to restore sessions with
  no live TUI process — out of scope.

The narrowed scope makes pigeon irrelevant for this fix.

## Design (Approach B — Minimal + observability)

Replace the body of `reset-workspace` step 2 (currently lines 126–213 of
`pkgs/reset-workspace/default.nix`). Steps 3, 4, 5, 6, 6.5, 7 unchanged.
`oc-auto-attach` unchanged.

### New step 2 logic (pseudocode)

```bash
log "snapshotting live opencode attach clients..."

OPENCODE_MANIFEST=""
OPENCODE_BARE_COUNT=0  # observability counter

# Loose pgrep, then strict per-pid validation. We use a strict regex on
# /proc/<pid>/cmdline rather than relying on pgrep's pattern.
for pid in $(pgrep -u dev -f 'opencode attach' 2>/dev/null || true); do
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
  [ -n "$cmdline" ] || continue

  # Strict match: <binary>/opencode attach <url> --session <sid>
  if [[ "$cmdline" =~ ^[^[:space:]]+/opencode[[:space:]]+attach[[:space:]]+https?://[^[:space:]]+[[:space:]]+--session[[:space:]]+(ses_[A-Za-z0-9]+)$ ]]; then
    sid="${BASH_REMATCH[1]}"
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
    log "  pid=$pid sid=$sid cwd=$cwd"
    OPENCODE_MANIFEST="${OPENCODE_MANIFEST}${sid}"$'\n'
  else
    log "  WARNING: skipping pid=$pid (no --session in argv) cmdline=$cmdline"
  fi
done

# Also enumerate bare opencode TUIs for observability — they will NOT be
# restored, but we log them so the user can see what's being lost.
for pid in $(pgrep -u dev -f opencode 2>/dev/null || true); do
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
  exe_base=$(basename "$exe")
  printf '%s' "$exe_base" | grep -qxE '\.?opencode(-wrapped)?' || continue
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/ *$//')
  arg2=$(printf '%s' "$cmdline" | awk '{print $2}')
  # Skip serve, skip attach clients (already logged above)
  [ "$arg2" = "serve" ] && continue
  [ "$arg2" = "attach" ] && continue
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "?")
  log "  WARNING: bare opencode TUI pid=$pid cwd=$cwd will NOT be restored across reset (use /launch or opencode-launch for restorable sessions)"
  OPENCODE_BARE_COUNT=$((OPENCODE_BARE_COUNT + 1))
done

# Dedupe captured sids.
OPENCODE_MANIFEST=$(printf '%s' "$OPENCODE_MANIFEST" | awk 'NF && !seen[$0]++')
if [ -z "$OPENCODE_MANIFEST" ]; then
  OPENCODE_COUNT=0
else
  OPENCODE_COUNT=$(printf '%s\n' "$OPENCODE_MANIFEST" | wc -l)
fi

log "  captured $OPENCODE_COUNT restorable session(s); $OPENCODE_BARE_COUNT bare TUI(s) skipped"
```

### Why strict regex (per user direction)

A loose pattern like `pgrep -f 'opencode attach.*ses_'` would catch any
process whose cmdline happens to contain those tokens (including a bash
command like `echo opencode attach foo ses_bar`). The strict regex anchors
on the binary path prefix, the literal `attach` subcommand, an `http(s)://`
url, and a syntactically valid sid — false positives become essentially
impossible.

### Removed code

The following are deleted from step 2:

- `exe_base` filter via `readlink /proc/<pid>/exe` (not needed; the strict
  cmdline regex is more reliable than exe-path matching).
- `-s ses_xxx` short-form argv match (`oc-auto-attach`-launched TUIs always
  use the long form `--session`).
- The log-file fallback (`ls -la /proc/<pid>/fd/` + grep `path=/session/`).
  This was the source of the bug — it's silently fragile for stuck/idle
  TUIs and is no longer needed under the narrowed contract.

### Observability changes

Two new log lines (in addition to existing per-sid `pid=… sid=…` lines):

1. `WARNING: skipping pid=… (no --session in argv) cmdline=…` for any
   process that matched `pgrep 'opencode attach'` but failed the strict
   regex (defensive — should be rare).
2. `WARNING: bare opencode TUI pid=… cwd=… will NOT be restored across
   reset (use /launch or opencode-launch for restorable sessions)` for
   each non-attach, non-serve opencode process.

The summary line changes from "captured N session id(s)" to
"captured N restorable session(s); M bare TUI(s) skipped".

### Skill doc update

`.opencode/skills/resetting-workspace/SKILL.md` gains a new section /
strengthens an existing one to document the contract:

> **What survives a reset:** sessions launched via Telegram `/launch` or
> `opencode-launch` (CLI). These are tracked via the `opencode attach
> --session <sid>` process pattern; if the TUI process is alive at reset
> time, the session is restored into a tmux window for its project's cwd.
>
> **What does NOT survive:** bare `:te opencode` TUIs (no `--session` in
> argv). These are killed and not restored. To preserve a session across
> reset, launch it via `/launch` or `opencode-launch`.
>
> Each reset's journal includes a "bare TUI N skipped" count so you can
> see what was dropped.

## Verification plan

1. **Live smoke test in this session** (post-deploy): orchestrator runs
   `reset-workspace --yes` inline. Expected:
   - Journal shows `WARNING: bare opencode TUI pid=2710872 cwd=...
     will NOT be restored` (this very session).
   - Journal shows `pid=2703803 sid=ses_2317906… cwd=.../pr-4194` capture
     line for the live attach client.
   - After reset: tmux window for `pr-4194` exists with nvims + a `:te
     opencode attach ... --session ses_2317906…` tab.
   - Pane %1 (where this Claude session lives) gets nvims back via the
     existing step 6 respawn but NO opencode TUI tab inside.
   - User restores this session manually via `:te opencode -s …` after
     the test.
2. **Nightly run** the next morning is the second confirmation in a
   real-world cron context.
3. **Unit tests deferred** — file follow-up bead if/when the logic gets
   touched again.

## Files changed

- `pkgs/reset-workspace/default.nix` — step 2 body replaced; step 6.5,
  step 7, etc. untouched.
- `.opencode/skills/resetting-workspace/SKILL.md` — new "What survives a
  reset" section.
- (Bead) `workstation-0gu` updated with corrected diagnosis + this design
  pointer.

## Out of scope (filed as follow-ups if needed)

- Restoring bare `:te opencode` TUIs.
- Unit / shellcheck-bats test harness for `reset-workspace`.
- Changing `oc-auto-attach`'s silent-exit-0 behavior (it's not the bug).
- Surfacing session ID through `/proc/<pid>/environ` or pigeon-cwd join
  (would be needed if bare-TUI restore is ever scoped in).
