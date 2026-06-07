---
name: holding-opencode-on-1.15
description: Use when touching the opencode version pin in home.base.nix, considering an opencode 1.16.x upgrade, or debugging opencode.db corruption — blank/empty launched sessions, subagent/Task dispatch or opencode-launch failing with "NOT NULL constraint failed: session_message.seq", or a re-migrated v2 schema on cloudbox/devbox.
---

# Holding OpenCode on the 1.15 Line (v1.16 V2 DB Corruption)

## TL;DR (current state as of 2026-06-07)

- **opencode is deliberately pinned to `v1.15.13-patched.3`.** Do **NOT** bump to 1.16.x.
- v1.16 introduced a **v2 event-sourced session schema**. Its migration rewrites the
  shared `~/.local/share/opencode/opencode.db` into a v2 schema that the 1.15 line
  **cannot write**, and that crashes new sessions. There is **no released upstream fix**.
- cloudbox AND devbox have both been repaired (v2 `seq` column removed) and run on
  1.15.13.3: serve + profile + `opencode-launch` all healthy. The config pin is durable
  (committed in `home.base.nix`). devbox was re-poisoned and repaired again on 2026-06-07
  via the runbook below (subagent dispatch / `opencode-launch` had started failing with
  the `seq` error).
- Full upstream investigation: `~/projects/opencode/DB-CORRUPTION-RESEARCH.md` (untracked).
- Related but different failure mode: see the `fixing-opencode-db` skill (SIGABRT/core-dump
  from individual corrupt rows; binary-search repair). This skill is about the **v1.16 v2
  schema migration** specifically.

## Why we can't run 1.16.x

The fork `johnnymo87/opencode-patched` tracks upstream `anomalyco/opencode`. In v1.16.0,
PR #29068 moved schema ownership into `packages/core` and added a custom migration engine
plus the **v2 event-sourced session layer**. The migration
`20260604172448_event_sourced_session_input` (PR #30785) and friends:

- `DELETE FROM session_message` / `DELETE FROM event` (wipes the v2 projection), and
- add `session_message.seq INTEGER NOT NULL` plus `event` / `event_sequence` / `migration`
  tables.

The 1.15 line's projector inserts `session_message` rows **without** a `seq` value. Against
the v2 schema that fails with **`NOT NULL constraint failed: session_message.seq`**, which
kills a new session's first-message turn — so `opencode-launch`'d sessions come up **blank**
(0 messages, never advance past creation). Established sessions look fine because display
reads `message`/`part`, not `session_message`.

Upstream issues, all OPEN / unreleased as of 2026-06-07: #31119 ("no such column: name"),
#30953 (account_state mismatch), #29908 (legacy rows → 400), #31072 (commitSyncEvent `seq`
race), #30963 (event-log-deleting migration). None merged into a release.

## The core fragility: one shared DB, mixed binaries

All opencode processes on the host share **one** SQLite file (`~/.local/share/opencode/opencode.db`):
the `opencode-serve.service` plus every standalone `opencode` / `opencode-launch` invocation.
`opencode-launch` itself just POSTs to the serve at `:4096` (no standalone binary). The danger
is a **stray 1.16.x process** opening that shared DB: it silently runs the v2 migration and
**re-poisons** the DB out from under the running 1.15 serve. This is exactly what happened on
2026-06-06 (a 1.16.2 process re-migrated the DB at ~23:44 after a partial rollback).

**Therefore the pin must cover every entry point:** the serve, the profile `opencode`
(what `opencode-launch`'s auto-attach and any direct `opencode` use), and any nightly/
reaper services. They all resolve `opencode` via `~/.nix-profile/bin/opencode`, so pinning
the home-manager profile covers them.

## Where the pin lives

`users/dev/home.base.nix`, the `opencode` derivation:

```nix
upstreamVersion = "1.15.13";
patchedRevision = "3";   # -> release tag v1.15.13-patched.3
```

plus the four per-platform `hash`es in `opencode-platforms`. The block has a prominent
`# V2 DB CORRUPTION HOLD` comment. `v1.15.13-patched.3` re-includes `retry-cap.patch` (the
Vertex/Gemini retry-runaway cure) that the earlier published `.2` lacked.

**Cutting a new 1.15 patch release** (e.g. to add/refresh a patch): dispatch the fork's
release workflow on the 1.15 branch, then prefetch hashes and bump `home.base.nix`:

```bash
gh workflow run build-release.yml -R johnnymo87/opencode-patched \
  --ref release/v1.15 --field version=1.15.13 --field revision=N
# after it publishes, for each asset:
nix store prefetch-file --json \
  https://github.com/johnnymo87/opencode-patched/releases/download/v1.15.13-patched.N/<asset> \
  | jq -r .hash
```

Then `nix run home-manager -- switch --flake .#cloudbox` (or `.#dev`).

## Detecting a re-poisoned DB

```bash
python3 - <<'PY'
import sqlite3
c=sqlite3.connect("file:/home/dev/.local/share/opencode/opencode.db?mode=ro",uri=True).cursor()
cols=[r[1] for r in c.execute("PRAGMA table_info(session_message)").fetchall()]
print("session_message cols:", cols, "-> POISONED" if "seq" in cols else "-> ok (1.15)")
PY
```

Other tells: `opencode-launch` sessions are blank in the TUI; **subagent / Task-tool
dispatch fails** (each new session/message insert hits the `seq` constraint) while your
already-running session's own tools keep working; serve logs / journal show `NOT NULL
constraint failed: session_message.seq`; `session_message` has `seq` and the `migration`
table exists.

## Repairing a re-poisoned DB

`session_message` is a re-derivable projection (33 rows on devbox 2026-06-07; often empty
after the v2 wipe), so the fix is to **remove the v2 `seq` column** — `message`/`part`/
`session` (the real history) are untouched.

A ready-to-run, host-agnostic script lives next to this skill: [`fix.sh`](fix.sh). It
performs every step below and logs to `/tmp/opencode/oc-fix.log`.

**Step 0 — back up first; do NOT assume a clean backup exists.** cloudbox had the pre-v2
`opencode.db.bak.20260531-171450`; **devbox had none** (only an April snapshot predating the
`session_message` table). Take a consistent *online* snapshot (safe against the live serve —
`cp` of a DB with a `-wal` is not):

```bash
python3 -c 'import sqlite3,os;s=sqlite3.connect(os.path.expanduser("~/.local/share/opencode/opencode.db"));d=sqlite3.connect(os.path.expanduser("~/.local/share/opencode/opencode.db.bak-"+__import__("datetime").date.today().isoformat()+"-prerepair"));s.backup(d);s.close();d.close()'
```
If the repair goes wrong, restore this snapshot and restart the serve to return to the
status quo (poisoned but established sessions still work).

**Service scope.** On devbox `opencode-serve.service` is a **system** unit
(`/etc/systemd/system/opencode-serve.service`) → use `sudo systemctl`. Note `systemctl
--user` **fails from an opencode bash tool shell** (no `DBUS_SESSION_BUS_ADDRESS` /
`XDG_RUNTIME_DIR`) — don't let that mislead you into thinking it's a user unit. Confirm with
`systemctl cat opencode-serve.service`.

**Gotcha (refined): run it detached — then the session usually SURVIVES.** Running
`systemctl stop opencode-serve` *directly in a tool call* kills that call (it's in the
serve's cgroup). A **detached root transient unit** returns immediately, so the launching
call completes; the serve then bounces in ~9s and the session **reconnects and survives** (no
session death observed on devbox 2026-06-07). Launch it (setuid `/run/wrappers/bin/sudo`,
absolute paths — transient units get a stripped PATH):

```bash
# Stage the bundled script where root can read it, then launch detached:
mkdir -p /tmp/opencode && cp .opencode/skills/holding-opencode-on-1.15/fix.sh /tmp/opencode/oc-fix.sh
/run/wrappers/bin/sudo --non-interactive /run/current-system/sw/bin/systemd-run \
  --unit=oc-fix-$(date +%H%M%S) --collect \
  /run/current-system/sw/bin/bash /tmp/opencode/oc-fix.sh
```

What the script does (proven on cloudbox AND devbox 2026-06-07):
1. set explicit `PATH` (stripped in transient units — broke the first cloudbox attempt) and
   a `trap ... EXIT` that restarts the serve so it is never left down,
2. `systemctl stop opencode-serve.service`,
3. kill any proc still holding `opencode.db` (poll `/proc/*/fd`) — on devbox this was a
   **leftover 1.15 `.opencode-wrapped`**, not necessarily a 1.16 re-poisoner, so do it even
   when no 1.16 stray is visible,
4. **`ALTER TABLE session_message DROP COLUMN seq`** (SQLite ≥3.35; devbox has 3.50.4) —
   preferred over DROP TABLE because it keeps the rows/FK/indexes. You MUST drop the two
   `seq`-based indexes first or the column drop fails: `session_message_session_type_seq_idx`
   and the UNIQUE `session_message_session_seq_idx`. The two 1.15 secondary indexes
   (`session_message_time_created_idx`, `session_message_session_time_created_id_idx`) plus
   the implicit `id` PK stay. *Fallback* if `DROP COLUMN` is unsupported: `DROP TABLE
   session_message` then recreate with that schema. Run `PRAGMA wal_checkpoint(TRUNCATE)`
   before the DDL and `PRAGMA quick_check` after,
5. `chown dev:dev` the `opencode.db`, `-wal`, `-shm` files,
6. `systemctl start opencode-serve.service` (comes up on the pinned 1.15.13.3 profile),
7. self-verify: `is-active`, health, `readlink /proc/<MainPID>/exe` is `...-1.15.13.3`, and
   `session_message` has no `seq` column. After the session reconnects, confirm a real
   subagent dispatch / `opencode-launch` produces ≥1 message (the original failing path).

## Verifying a good state

```bash
systemctl show opencode-serve.service -p MainPID --value | xargs -I{} readlink -f /proc/{}/exe   # ...-1.15.13.3
curl -sf http://127.0.0.1:4096/global/health                                                      # {"healthy":true,"version":"1.15.13"}
readlink -f ~/.nix-profile/bin/opencode                                                           # ...-1.15.13.3
# session_message has NO seq column (see detection script); no 1.16.x procs running
```

## What "done with the hold" looks like (future)

Stay on the 1.15 line until upstream ships a released fix for the v2 migration corruption
(track the issues above and `DB-CORRUPTION-RESEARCH.md`). Only then test 1.16.x against a
**copy** of the DB before any host bump, and ensure no 1.15 and 1.16 binaries ever share the
same live DB during a transition. Also gate any `update-opencode-patched` automation so it
does not auto-bump `upstreamVersion` back into the 1.16 line.

## Cross-references

- `fixing-opencode-db` — different failure (SIGABRT from individual corrupt rows).
- `rebuilding` — host → flake-target mapping for `home-manager switch`.
- `auditing-opencode-llm-calls` / `operating-aigateway` — the serve's model routing.
- `~/projects/opencode/DB-CORRUPTION-RESEARCH.md` — upstream issue/PR investigation.
- `home.base.nix` commits `88713e1` (.2 hold) and `8923b77` (.3 retry-cap) on `main`.
