---
name: holding-opencode-on-1.15
description: Use when touching the opencode version pin in home.base.nix, considering an opencode 1.16.x upgrade, or debugging opencode.db corruption — blank/empty launched sessions, "NOT NULL constraint failed: session_message.seq", or a re-migrated v2 schema on cloudbox/devbox.
---

# Holding OpenCode on the 1.15 Line (v1.16 V2 DB Corruption)

## TL;DR (current state as of 2026-06-07)

- **opencode is deliberately pinned to `v1.15.13-patched.3`.** Do **NOT** bump to 1.16.x.
- v1.16 introduced a **v2 event-sourced session schema**. Its migration rewrites the
  shared `~/.local/share/opencode/opencode.db` into a v2 schema that the 1.15 line
  **cannot write**, and that crashes new sessions. There is **no released upstream fix**.
- cloudbox is currently healthy: serve + profile + `opencode-launch` all on 1.15.13.3,
  the DB has been repaired (v2 `seq` column removed), and it survived the 03:00 nightly
  restart. The config pin is durable (committed in `home.base.nix`).
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

Other tells: `opencode-launch` sessions are blank in the TUI; serve logs / journal show
`NOT NULL constraint failed: session_message.seq`; `session_message` has `seq` and the
`migration` table exists.

## Repairing a re-poisoned DB

`session_message` is a re-derivable projection (and is usually empty after the v2 wipe), so
the fix is to **drop the `seq` column and recreate the 1.15 schema** — `message`/`part`/
`session` (the real history) are untouched. The clean May-31 backup
`opencode.db.bak.20260531-171450` (pre-v2, no `seq`) is the fallback; the 8 GB
`opencode.db.poisoned-v2.*` holds orphaned v2 data.

**Critical gotcha:** stopping `opencode-serve` from inside an opencode session **kills your
own session** (you run inside the serve's cgroup). Run the disruptive part as a **detached
root transient unit** so it survives:

```bash
sudo systemd-run --unit=oc-fix-$(date +%H%M%S) \
  /run/current-system/sw/bin/bash /path/to/fix.sh   # use the setuid /run/wrappers/bin/sudo
```

The fix script (template proven on 2026-06-07; logs to `/tmp/opencode/oc-fix.log`) must:
1. set an explicit `PATH` (transient units get a stripped PATH — this broke the first attempt),
2. `systemctl stop opencode-serve.service`,
3. kill any remaining standalone procs holding `opencode.db` (re-poisoners), poll `/proc/*/fd`,
4. `DROP TABLE session_message` then recreate it with the 1.15 schema (id, session_id FK,
   type, time_created, time_updated, data + 3 indexes); `PRAGMA quick_check`,
5. `chown dev:dev` the db files,
6. `systemctl start opencode-serve.service` (comes up on the pinned 1.15.13.3 profile),
7. self-verify: health, `readlink /proc/<MainPID>/exe` is `...-1.15.13.3`, and a test
   `opencode-launch` produces ≥1 message.
   Use a `trap ... EXIT` that restarts the serve so it is never left down.

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
