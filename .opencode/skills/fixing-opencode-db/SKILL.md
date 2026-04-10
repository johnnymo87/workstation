---
name: fixing-opencode-db
description: Use when opencode crashes with SIGABRT or "Aborted (core dumped)" on startup, or when opencode won't launch after a hard reboot, DB recreation, or unclean shutdown
---

# Fixing OpenCode Database Crashes

## Overview

OpenCode stores all state in `~/.local/share/opencode/opencode.db` (SQLite). Corrupt or incompatible rows can cause SIGABRT on startup even when `PRAGMA integrity_check` passes — the data is valid SQL but fails Go-level deserialization.

## Symptoms

- `opencode` prints `Aborted (core dumped)` immediately
- Crashes in all project directories (not project-specific)
- `opencode --version` works from `/tmp` (binary is fine)
- `coredumpctl list` shows SIGABRT for `.opencode-wrapp`
- Often appears after hard reboot or DB recreation

## Quick Diagnosis

```bash
# 1. Confirm binary works
cd /tmp && opencode --version

# 2. Confirm DB is the problem (move aside, test, restore)
mv ~/.local/share/opencode/opencode.db ~/.local/share/opencode/opencode.db.safe
opencode --version  # If this works, DB is the cause
mv ~/.local/share/opencode/opencode.db.safe ~/.local/share/opencode/opencode.db
```

## Binary Search Method

**Principle:** Isolate the crashing table, then the crashing rows, using a copy of the DB. Never modify the original until you've identified the exact bad rows.

### Step 1: Identify the bad table

```bash
# Work on a copy
cp ~/.local/share/opencode/opencode.db /tmp/oc-debug.db

# Check table sizes
sqlite3 /tmp/oc-debug.db "
  SELECT 'session', COUNT(*) FROM session UNION ALL
  SELECT 'message', COUNT(*) FROM message UNION ALL
  SELECT 'part', COUNT(*) FROM part UNION ALL
  SELECT 'todo', COUNT(*) FROM todo UNION ALL
  SELECT 'project', COUNT(*) FROM project UNION ALL
  SELECT 'event', COUNT(*) FROM event"
```

Delete all rows from one table at a time in the copy, swap it in, test, swap back:

```bash
# Example: clear session-related tables
sqlite3 /tmp/oc-debug.db "DELETE FROM session; DELETE FROM message; DELETE FROM part; DELETE FROM event; VACUUM;"

# Swap in the copy for testing
mv ~/.local/share/opencode/opencode.db ~/.local/share/opencode/opencode.db.real
cp /tmp/oc-debug.db ~/.local/share/opencode/opencode.db

# Test
timeout 10 opencode --version; echo "exit=$?"

# Always restore original
mv ~/.local/share/opencode/opencode.db.real ~/.local/share/opencode/opencode.db
```

If it still crashes, the bad data is in a different table. Try `todo`, `project`, etc.

### Step 2: Binary search within the table

Once you know the table (e.g., `todo`), find the bad rows:

```bash
# List groupings (e.g., by session_id for todos)
sqlite3 ~/.local/share/opencode/opencode.db "
  SELECT session_id, COUNT(*) FROM todo GROUP BY session_id ORDER BY session_id"

# Delete half, test, narrow down
sqlite3 /tmp/oc-debug.db "DELETE FROM todo WHERE session_id IN (
  SELECT DISTINCT session_id FROM todo ORDER BY session_id LIMIT N)"
```

Repeat: delete half, test, keep narrowing until you find the exact session(s).

### Step 3: Fix the real DB

Once identified, delete only the bad rows from the original:

```bash
sqlite3 ~/.local/share/opencode/opencode.db "DELETE FROM todo WHERE session_id = 'ses_XXX'"
```

**Important:** There may be multiple bad sessions. After fixing one, test again — if it still crashes, continue the search.

## Known Causes

### Stale rows from DB recreation

If the DB was deleted and recreated, orphaned rows from the old schema/era can survive in tables that aren't fully cascade-deleted. These rows have valid SQL data but may reference formats or states that the current opencode version can't deserialize.

**Pattern:** Session IDs with a different prefix (e.g., `ses_3b*` vs current `ses_28*`) indicate rows from a previous database era. Deleting all rows with the old prefix is often the fix:

```bash
sqlite3 ~/.local/share/opencode/opencode.db "DELETE FROM todo WHERE session_id LIKE 'ses_3%'"
```

### Unclean shutdown during write

Hard reboots can leave partially-written rows. The WAL file (`opencode.db-wal`) may contain incomplete transactions. Try renaming it:

```bash
mv ~/.local/share/opencode/opencode.db-wal ~/.local/share/opencode/opencode.db-wal.bak
mv ~/.local/share/opencode/opencode.db-shm ~/.local/share/opencode/opencode.db-shm.bak
```

If this doesn't help, the bad data was already checkpointed into the main DB.

## Safety Rules

- **Never delete the original DB** — always copy first
- **Always restore after testing** — swap the real DB back immediately
- **Test with `timeout`** — prevents hanging if opencode enters a bad state
- **`PRAGMA integrity_check` is necessary but not sufficient** — it validates SQL structure, not application-level data validity
