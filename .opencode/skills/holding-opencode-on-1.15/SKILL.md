---
name: holding-opencode-on-1.15
description: Use when touching the opencode version pin in home.base.nix, planning or executing the 1.15→1.17 cutover, considering an opencode 1.16.x/1.17.x upgrade, or debugging opencode.db corruption — blank/empty launched sessions, subagent/Task dispatch or opencode-launch failing with "NOT NULL constraint failed: session_message.seq" or "table session_message has no column named seq", or a re-migrated v2 schema on cloudbox/devbox.
---

# Holding OpenCode on the 1.15 Line (v1.16 V2 DB Corruption)

## TL;DR (current state as of 2026-06-11)

- **opencode is currently still pinned to `v1.15.13-patched.3`** — but the hold is
  **cleared to lift via a cutover**, not held indefinitely. Empirical testing on
  **2026-06-11** disproved the corruption fears for our topology (details below).
  Don't bump the pin ad hoc; follow the cutover runbook:
  `docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md`.
- **What flipped:** the original fear was that v1.16/1.17 corrupts the DB even fresh
  (#31072) and that migrating an existing DB wipes/breaks it. Both were tested
  against real **v1.17.2** on copies of the live DB:
  - **#31072 does NOT reproduce here.** 42 subagent sessions across in-process,
    multi-process (13-way), and combined stress → **0 orphaned, 0 missing
    `session_message`, 0 duplicate `(aggregate_id,seq)`**. The race can't bite our
    one-DB topology: `commitSyncEvent` reads `latest` *inside* a `BEGIN IMMEDIATE`
    transaction, and a 1-permit semaphore serializes all transactions per process.
  - **Migrating loads our history fine.** 64/64 sampled sessions load (#29908 does
    not bite us); the destructive migration won't re-fire (all 32 already applied).
    The only catch is self-inflicted (see "Lifting the hold").
- **The historical hazard was real but self-inflicted:** running **mixed 1.15 + 1.16
  binaries on the one shared DB** caused split-brain (`NOT NULL constraint failed:
  session_message.seq`). cloudbox/devbox were repaired (v2 `seq` column dropped) and
  ran on 1.15.13.3. A clean, all-at-once cutover (no mixed binaries) avoids this.
- Full upstream investigation: `~/projects/opencode/DB-CORRUPTION-RESEARCH.md` (untracked).
- Related but different failure mode: see the `fixing-opencode-db` skill (SIGABRT/core-dump
  from individual corrupt rows; binary-search repair). This skill is about the **v1.16 v2
  schema migration** specifically.

## Why the v2 schema broke 1.15 (the original cause — now a transition hazard, not a wall)

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

**The crucial nuance (why this is no longer a wall):** that failure is a **mixed-version**
problem — a 1.15 *projector* writing the *v2* schema. It is **not** a defect that makes 1.17
itself unusable. Run 1.17 *everywhere* (no 1.15 writer on the DB) and the symptom disappears;
that's what the cutover does. The corruption issues below are real upstream bugs but, per the
2026-06-11 testing, do not reproduce on our topology.

Upstream issues, all still OPEN as of 2026-06-11: #31119 ("no such column: name"),
#30953 (account_state mismatch), #29908 (legacy rows → 400), #31072 (commitSyncEvent `seq`
race), #30963 (event-log-deleting migration). None merged into a release — but see
"Upstream status" for why each is inert for us.

### #31072 (the subagent seq race) — does NOT reproduce on our topology

**This was the scariest claim and it did not hold up under testing (2026-06-11).**

The issue says `commitSyncEvent` (`packages/core/src/event.ts`) computes the next event
`seq` as `latest + 1` in JS and upserts a static value, so two concurrent writers grab the
same seq and the loser's event is silently dropped — reporting **331/333 subagent sessions
(99.4%) orphaned** on one production DB (a Windows **desktop** install). The issue is still
OPEN (no fix PR for #31072).

But the *current* code (v1.16.2 == v1.17.2 for this path) is **not** an unguarded upsert:

- `commitSyncEvent` reads `latest` **inside** `db.transaction(…, { behavior: "immediate" })`
  → `BEGIN IMMEDIATE` takes a RESERVED lock before the read, so read-compute-write is atomic.
- Intra-process, `sqlite.bun.ts` gates the single `bun:sqlite` connection behind a
  `Semaphore.make(1)` (1 permit), held for the whole transaction — so two fibers (parallel
  subagents) **cannot** interleave. Task subagents run **in-process** (`tool/task.ts` →
  `Effect.forkIn`), not as separate processes.
- Cross-process writers serialize via `BEGIN IMMEDIATE` + `busy_timeout = 5000`.

**Empirical result on a fresh v1.17.2 v2 DB:** 42 subagent sessions across in-process
(10 parallel), multi-process (12 concurrent `opencode run` + serve = 13-way), and combined
worst-case (4 procs × 8 parallel) → **0 orphaned, 0 missing `session_message`, 0 duplicate
`(aggregate_id,seq)`, `quick_check ok`.** The reporter's 99.4% was almost certainly the
desktop app's genuinely multi-process design on an older snapshot, which our headless
serve does not reproduce.

## The core fragility: one shared DB, mixed binaries

All opencode processes on the host share **one** SQLite file (`~/.local/share/opencode/opencode.db`):
the `opencode-serve.service` plus every standalone `opencode` / `opencode-launch` invocation.
`opencode-launch` itself just POSTs to the serve at `:4096` (no standalone binary). The danger
is a **stray 1.16.x process** opening that shared DB: it silently runs the v2 migration and
**re-poisons** the DB out from under the running 1.15 serve. This is exactly what happened on
2026-06-06 (a 1.16.2 process re-migrated the DB at ~23:44 after a partial rollback).

**Topology reality (measured 2026-06-11): cloudbox is heavily multi-writer, not single-serve.**
At a typical moment ~**15 processes** held `opencode.db` open: the systemd serve (`:4096`)
**plus ~14 standalone `opencode` TUIs** (started from interactive shells, each embedding its
own server on its own port). They are not `opencode attach` clients (those are thin HTTP
clients of the serve). This is harmless on 1.15 (no v2 write path) and safe on 1.17 (the
intra-process semaphore + cross-process `BEGIN IMMEDIATE` serialize writers — see #31072
above), but it is **why the cutover must stop every opencode process at once**: a single
stray binary of the *other* major version on the shared DB is what causes split-brain.

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

## Upstream status (re-checked 2026-06-11)

Released tags now: **v1.16.0, v1.16.2, v1.17.0, v1.17.1, v1.17.2** (v1.17.2 tagged
2026-06-10). The six corruption issues are **all still OPEN** (last activity 06-05..06-07,
before v1.17.2), and `migration.ts` is **unchanged** v1.16.2→v1.17.2; `event.ts` changed
only via a logger refactor (#31310) and a typed-app-layer-graph refactor (#31531), neither
touching the seq logic. So at the *file* level 1.17.2 == v1.16.2 for the DB paths — **yet
empirical testing (above) shows those paths are safe on our topology.** "Issue OPEN" here
means "nobody upstream closed it," not "it breaks us." Re-run before any reconsideration:

```bash
cd ~/projects/opencode && git fetch --all --tags --prune
git tag --list 'v1.16*' 'v1.17*' --sort=-creatordate
git log --oneline v1.16.2..v1.17.2 -- packages/core/src/database/migration.ts packages/core/src/event.ts
```

| # | Title | State (06-11) | In v1.17.2? | Bites us? |
|---|---|---|---|---|
| 31119 | no such column: name (migration) | OPEN | bug present; PR #31121 **unmerged** | No — only on legacy drizzle journal; our DB already migrated |
| 30953 | account_state mismatch on upgrade | OPEN | present | No — already migrated |
| 17270 | CREATE TABLE account skip | OPEN | present | No — already migrated |
| 29908 | legacy rows → 400 on load | OPEN | present; PR #29965 **unmerged** | **No — tested: 64/64 old sessions load** |
| **31072** | subagent first-message seq race | OPEN | present | **No — tested: 0/42 subagents orphaned** (BEGIN IMMEDIATE + semaphore) |
| 30963 | migration deletes entire event log | OPEN | present | No — won't re-fire (all 32 migrations already applied) |

## Lifting the hold (the cutover)

The corruption issues are **no longer a reason to stay on 1.15** — they don't reproduce on
our single-DB headless topology (validated 2026-06-11 against v1.17.2 on copies of the live
DB). What remains is **operational**, not waiting for upstream:

1. Cut a `v1.17.2-patched` fork release carrying our patches (retry-cap, caching, vim) — they
   don't touch the DB layer, so DB behavior == upstream v1.17.2.
2. Execute the **atomic** cutover (stop *every* opencode process first — see multi-writer note):
   `docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md`.
3. Pick a DB strategy: **fresh + archive** (recommended; clean/fast, history stays searchable
   via the archived file) or **migrate in place** (keeps sessions live-resumable but carries
   4.2 GB bloat). **Migrate requires re-adding `session_message.seq`** that our `fix.sh` repair
   dropped — without it 1.17 can't write (`table session_message has no column named seq`):

   ```sql
   DELETE FROM session_message;            -- stale, re-derivable projection rows
   ALTER TABLE session_message ADD COLUMN seq integer NOT NULL;
   CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
   CREATE INDEX session_message_session_type_seq_idx ON session_message (session_id, type, seq);
   ```
4. Gate `update-opencode-patched` to track the 1.17 line.

**Known open fast-follow (not a DB issue, not a blocker):** on 1.16.x, `self_compact_and_resume`
sometimes left the post-compaction resumption message sitting with no turn firing. Couldn't
repro headlessly (needs the interactive serve+TUI compaction→resume flow). Verify during an
interactive 1.17 trial; file/fix separately.

## Cross-references

- `fixing-opencode-db` — different failure (SIGABRT from individual corrupt rows).
- `rebuilding` — host → flake-target mapping for `home-manager switch`.
- `auditing-opencode-llm-calls` / `operating-aigateway` — the serve's model routing.
- `~/projects/opencode/DB-CORRUPTION-RESEARCH.md` — upstream issue/PR investigation.
- `docs/plans/2026-06-11-opencode-1.17-cutover-runbook.md` — the validated cutover procedure.
- `home.base.nix` commits `88713e1` (.2 hold) and `8923b77` (.3 retry-cap) on `main`.
