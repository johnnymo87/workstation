---
name: triaging-opencode-sluggishness
description: Use when opencode on devbox feels sluggish, slow, or frozen; when attach TUIs burn CPU or a session shows the busy/working shimmer forever; when opencode.db has grown to gigabytes; or after canary serve restarts leave sessions stuck mid-turn.
---

# Triaging OpenCode Sluggishness

Runbook distilled from the 2026-07-03 devbox incident (beads workstation-g3iy /
utnw / bm1i): serve-0 wedged 5x in one day, orphaned "busy" TUIs burned ~3
cores for hours, and a 4.3GB opencode.db (2.8GB write-only event log) sat under
every main-thread query. Sluggishness is usually a **feedback loop**, not one
cause — check all four legs.

**REQUIRED BACKGROUND:** monitoring-serve-pool (canary, wedge forensics,
memory-limit rationale).

## Triage checklist (in order)

1. **Serve wedges:** `journalctl --user -u opencode-serve-canary.service --since -6h | grep -E 'WARNING|RESTARTING'`. Restarts = sessions died mid-turn (see phantom-busy below). Forensics land in `/tmp/opencode-serve-canary/wedge-*/` — copy them out of /tmp before they age out.
2. **Spinning TUIs:** `ps aux | grep 'opencode attach'` lifetime %CPU is an *average* — confirm live spin with two samples of `/proc/PID/stat` (fields 14+15, 2s apart; >100 ticks growth in 2s ≈ >50% of a core = spinning; an idle TUI adds ~0-5). A TUI attached to a phantom-busy session renders its shimmer animation at ~30fps forever: strace shows truecolor pty writes with drifting color values; syscalls dominated by `sched_yield`+`futex` (JSC GC storm). **Killing an attach TUI is always safe** — sessions live in opencode.db; reattach later. Also kill duplicate attaches to the same session.
3. **Pile-on onto :4096:** count attaches per port. Sessions that return 404 "session not routed" from pigeon `GET :4731/route?session_id=` fall back to the first pool member (bead workstation-jyax). Skew = serve-0 overload = more wedges.
4. **DB bloat:** `ls -la ~/.local/share/opencode/opencode.db*`. The `event` table is the usual culprit — `message.updated.1` events store full message snapshots (O(n²) per session). Breakdown query: `SELECT type, count(*), sum(length(data))/1024/1024 FROM event GROUP BY type ORDER BY 3 DESC;` (use `nix shell nixpkgs#sqlite -c sqlite3 "file:$DB?mode=ro"`).

## Phantom-busy sessions (the SIGKILL problem)

Any unclean serve death (canary restart, OOM, reboot) leaves in-flight
assistant messages with `time.created` but **no `time.completed`** — every TUI
that loads the session renders "working" forever. The
`opencode-phantom-busy-sweeper` timer (users/dev/home.devbox.nix, every 5min)
finalizes rows that are incomplete, error-free, and untouched >30min, writing
the canonical `MessageAbortedError` shape. Check it:
`journalctl --user -u opencode-phantom-busy-sweeper --since -1h`. If a phantom
persists anyway: run `systemctl --user start opencode-phantom-busy-sweeper`
manually and check the journal for sqlite errors (busy_timeout, locked DB); a
TUI already rendering the phantom needs a reattach to reload from the DB.

## Event-log maintenance

The event table is only read by remote-workspace sync (unused here);
`event-log-gate.patch` (opencode-patched ≥ v1.17.7-patched.10) stops writes
unless `OPENCODE_EXPERIMENTAL_WORKSPACES` is set. On older binaries it regrows
~50 rows/5min. Purge procedure — stop the pool with `systemctl --user stop
opencode-serve-canary.timer opencode-serve@4096 opencode-serve@4097
opencode-serve-pool.target`, restart with `systemctl --user start
opencode-serve-pool.target opencode-serve-canary.timer`. If your own session
runs on the pool, wrap the whole stop→purge→start in a detached script
(`setsid nohup script >log 2>&1 & disown`) that begins with `sleep 30` so your
final message gets delivered before the serve dies under you:

```sql
PRAGMA wal_checkpoint(TRUNCATE);
DELETE FROM event;   -- keep event_sequence (seq counters, tiny)
VACUUM;              -- needs ~DB-size free disk; leaves a DB-size WAL
```

Then force `PRAGMA wal_checkpoint(TRUNCATE);` again after serves restart to
drain the VACUUM's WAL. 2026-07-03 result: 4.5GB → 1.24GB.

## Reading deep wedge forensics

Canary dumps (beyond the cheap /proc files): `cpu-io-split` (utime growth with
flat stime = JS/GC spin; read_bytes growth = sqlite paging) and `eu-stack.{1,2,3}`
native stacks. The bun binary is non-PIE (`ET_EXEC`), so raw addresses are
stable across runs — identical frames across the 3 samples (or across wedges)
fingerprint a tight loop even without symbols.

## Common mistakes

| Mistake | Reality |
|---------|---------|
| Trusting `ps` %CPU for "is it spinning now" | Lifetime average; sample /proc/PID/stat twice |
| Reverting the canary because SIGKILL orphans turns | Any recovery SIGKILLs a frozen loop; fix the orphans (sweeper), keep detection |
| VACUUM without checking disk | Needs ~DB size free, and leaves a same-size WAL until a TRUNCATE checkpoint |
| Purging events on an unknown opencode version | Verify readers first: v1.17.7's are workspace-only, but newer versions may differ |
| Stopping the pool from a session running on it | Your turn dies with the serve; run maintenance as a detached script with a grace sleep |
