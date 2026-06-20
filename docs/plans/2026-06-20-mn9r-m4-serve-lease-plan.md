# mn9r M4 — Serve-Side Lease Participation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: execute via **superpowers:subagent-driven-development** (SDD) — fresh `implementer` subagent per task, `spec-reviewer` + `code-reviewer` between tasks, orchestrator reviews each. This is the **HIGH-BLAST-RADIUS** core of mn9r. **Design decisions RESOLVED 2026-06-20: D1a + D2a** (see §"Design decisions" below — both gaps are now decided; the plan reflects them).

**Goal:** Make the opencode `serve` process hold a fenced, time-boxed lease (against pigeon's routing DB) for the duration of a session's agent run, so that under the K-serve pool exactly one process ever runs a given session's loop — and an old-epoch / superseded serve cannot keep running after a cutover or reassignment.

**Architecture:** A new opencode-patched patch (`serve-lease.patch`) adds (1) a dedicated SQLite connection to pigeon's routing DB that speaks M1's exact lease CAS SQL, (2) serve-boot identity + epoch-fence + heartbeat, and (3) an `Effect.acquireRelease` wrap around the real once-per-run agent loop with a TTL/3 renewal fiber. The whole feature is **gated on `OPENCODE_ROUTING_DB` being set** — unset ⇒ today's behavior, byte-for-byte (safe to ship before the M5 pool exists).

**Tech stack:** opencode v1.17.7 (Effect-TS, `bun:sqlite`/`node:sqlite` via `#sqlite` import + drizzle), pigeon routing DB (`better-sqlite3`, `pigeon-daemon.db`), workstation Nix env plumbing.

---

## 0. Verified ground truth (recon 2026-06-20)

### Lease contract (pigeon, HEAD `c938053` → on `main`)
- **Routing DB = `pigeon-daemon.db`** (env `PIGEON_DAEMON_DB_PATH`, default `<cwd>/data/pigeon-daemon.db`). **There is NO dedicated `routing.db`.** Driver: `better-sqlite3`. Prod opens it with **only `PRAGMA foreign_keys=ON`** — **no WAL, no busy_timeout** (those are set by the *test* participants). ⇒ the serve must set **WAL** (persists on the file) and its **own `busy_timeout`** defensively.
- **`routing_meta`** singleton: `id INTEGER PRIMARY KEY CHECK (id=1)`, cols `schema_version, ddl_checksum, binary_epoch, updated_at`. `binary_epoch` starts 0; only pigeon bumps it. The serve **reads** it.
- **`session_lease`** PK `session_id`. Lease token = **`(session_id, serve_id, instance_uuid, owner_generation, binary_epoch)`**. Cols: `serve_id, instance_uuid, owner_generation, lease_expires_at, heartbeat_at, binary_epoch`. ms-epoch ints.
- **`session_assignment`** PK `session_id`: `directory_key, desired_serve_id, owner_generation, state(assigned|draining|dormant|migrating), last_active_at, updated_at`. **Pigeon owns this.** A serve can only `acquireCAS` if a matching assignment (`desired_serve_id = my serve_id`, `owner_generation = @gen`) already exists — the acquire is `INSERT…SELECT…WHERE` against this table joined to `routing_meta`.
- **`serve_instance`** PK `serve_id`: `instance_uuid, endpoint, binary_epoch, health_state, heartbeat_at, draining`. **Today pigeon mints `serve_id` (= `serve-<i>` from `PIGEON_SERVE_ENDPOINTS` order) and `instance_uuid` (`randomUUID()`), and heartbeats via HTTP `GET /global/health` polling — the serve does NOT self-register or self-heartbeat.**
- Exact CAS SQL (named `@params`), quoted verbatim in Appendix A.
- Constants: `PIGEON_LEASE_TTL_MS=30000`, `PIGEON_SERVE_STALE_MS=15000`, `PIGEON_HEALTH_POLL_MS=5000`. **No grace constant** — expiry is exactly `lease_expires_at <= now`.
- Reader fence (`resolveRoute`, must replicate when checking "is my lease still valid"): lease exists ∧ `lease_expires_at > now` ∧ `owner_generation == assignment.owner_generation` ∧ `serve_id == assignment.desired_serve_id` ∧ `binary_epoch == routing_meta.binary_epoch`.
- Cross-binding proof recipe: any writer that opens the same file with **WAL + busy_timeout** and issues the exact `acquire/renew/release` SQL with the same token, reading `gen`+`epoch` fresh before each acquire, plugs into `test/routing/lease-cas-concurrency.test.ts` and the zero-overlap assertion holds.

### opencode insertion points (v1.17.7, `/tmp/opencode/v1177-apply` @ `4ed4f749e`)
- **`cli/cmd/serve.ts`** — 24-line handler. `Server.listen` resolves at **line 19**; `Effect.never` at **line 22**. Insertion window = **between line 20 and 22**. Handler runs in a scope; scope-close finalizer already kills the child on SIGTERM (no manual signal hook needed). `Flag` already imported (line 4).
- **`session/prompt.ts`** —
  - `loop` at **1404-1408**; the once-per-run work is `runLoop(input.sessionID)` passed to `state.ensureRunning(...)` at **1407** → **wrap THIS with `Effect.acquireRelease`**.
  - `runLoop` body **1134-…**; per-iteration `status.set busy` at **1142** fires every step (double-acquire trap — do NOT hook here; use 1142 only as a *guard*: "can I still renew? else pause/cancel").
  - `shell()` at **1410-1415** (body `shellImpl` at 435, returns `Session.BusyError`).
- **`effect/runner.ts`** — true Idle→Running at `ensureRunning` **115-138**; `work` is executed **exactly once** in `case "Idle"` (line 133); `Running`/`ShellThenRun` callers dedupe and **discard** `work` (line 122). `onBusy` is referenced ONLY in `startShell` (runner.ts:148) — **not a reliable per-run hook**. ⇒ wrapping `work` at prompt.ts:1407 = exactly-once acquire/release per real run.
- **`status.ts`** — process-local busy map, no cross-process awareness (the gap the lease fills).
- **SQLite**: dual binding via `packages/core/package.json` `imports["#sqlite"]` (`bun:sqlite` / `node:sqlite`) + drizzle. Native-connection templates at `sqlite.bun.ts:154-167` / `sqlite.node.ts:151-160`; full PRAGMA set (incl. `busy_timeout=5000`) at `database.ts:22-37`; path resolver `Database.path()` at `database.ts:43-55`; flag pattern `flag.ts:47` (`OPENCODE_DB`). Compiler emits **positional `?`**; raw handles accept named too.
- **Best structural template for the whole feature**: `packages/core/src/util/effect-flock.ts:253-266` — `Effect.acquireRelease` + a scoped heartbeat fiber (`utimes … Effect.repeat(Schedule.spaced(HEARTBEAT_MS)) … Effect.forkScoped`). This is literally a lease; mirror its shape.
- **Tests to model**: `test/cli/serve/serve-process.test.ts` (subprocess), `test/session/prompt.test.ts` (in-process layer-wired), `test/effect/runner.test.ts` (dedupe/state).

---

## ✅ Design decisions — RESOLVED 2026-06-20: **D1a + D2a**

### D1 — Serve identity bootstrap → **D1a CHOSEN: serve self-registers + self-heartbeats (touches pigeon)**
The serve generates its own `instance_uuid` (`randomUUID()`), takes `serve_id` from a new env `OPENCODE_SERVE_ID` (set per-unit by M5; for M4 tests, supplied directly), and **upserts its own `serve_instance` row** on boot (endpoint = `127.0.0.1:<port>`, `binary_epoch` = current, `health_state='healthy'`, `heartbeat_at=now`), then **self-heartbeats** on a timer fiber. **Pigeon-side change required** (this milestone now spans the pigeon repo too):
- `seedServes()` (`packages/daemon/src/routing/serve-registry.ts`) must STOP minting `instance_uuid` / owning liveness. It should reconcile by `serve_id` — never overwrite the serve-owned `instance_uuid` / `heartbeat_at` / `health_state`. Config (`PIGEON_SERVE_ENDPOINTS`) may still seed the *expected* serve_id↔endpoint mapping, but the live identity row is the serve's.
- **Retire (or demote to secondary) the HTTP `ServeHealthPoller`** (`serve-health-poller.ts`): liveness now comes from the serve's self-written `heartbeat_at` + the existing `isServeHealthy` staleness check (`heartbeat_at > now - staleServeMs`). Keep a fallback path or feature-gate the swap so pigeon doesn't go blind if a serve predates self-registration.
- Rationale: serve owns its own liveness (correct long-term); avoids the D1b boot-ordering dependency and the split where pigeon heartbeats a process it doesn't run.
- **D1b REJECTED** (serve reads pigeon-minted identity): keeps the awkward "pigeon heartbeats someone else's process" model and a boot-ordering dependency.

### D2 — No assignment for (session, this serve) → **D2a CHOSEN: gated + fail-open-when-unrouted**
- `OPENCODE_ROUTING_DB` **unset** ⇒ feature OFF — today's behavior byte-for-byte (safe to ship before M5).
- Set **and** a `session_assignment` exists for this session pointing at this serve ⇒ acquire/enforce the lease (fail the run if acquire fails on an *assigned* session).
- Set but **no assignment** ⇒ run WITHOUT a lease (log once). Direct/pre-pool sessions keep working.
- **D2b REJECTED** (serve self-creates assignment): usurps pigeon's HRW placement authority.

---

## Settled sub-decisions (from recon)
- **Routing DB file**: reuse `pigeon-daemon.db` (tables already live there; no split). New env `OPENCODE_ROUTING_DB` points at it. (Master sub-decision #1 → reuse, not dedicated.)
- **I/O threading**: start **inline** (dedicated `bun:sqlite`/`node:sqlite` raw handle, WAL + `busy_timeout≈2000` + retry/jitter on `SQLITE_BUSY`). Move to a Worker only if the canary p99 regresses. (Sub-decision #2.)
- **Cadence**: TTL=30s (read from routing config defaults / mirror `PIGEON_LEASE_TTL_MS`), renew=TTL/3≈10s, jitter ±15%. (Sub-decision #3.)
- **No-grace** expiry semantics, matching M1.

---

## Tasks

> All TDD against a clean v1.17.7 worktree: `git -C ~/projects/opencode worktree add /tmp/opencode/m4 4ed4f749e` (then `apply.sh` the existing stack first so the new patch stacks cleanly). Run tests from `packages/opencode`. Final deliverable = `opencode-patched/patches/serve-lease.patch` + apply.sh registration (+ pigeon change if D1a).

### Task 1: `OPENCODE_ROUTING_DB` flag + routing-DB connection module
**Files:**
- Modify: `packages/core/src/flag/flag.ts:47` (add `OPENCODE_ROUTING_DB`)
- Create: `packages/core/src/serve/routing-lease.ts` (the lease adapter)
- Test: `packages/core/test/serve/routing-lease.test.ts`

**Step 1 (red):** Write a test that opens a temp routing DB seeded with the M1 schema (copy `route-schema.ts` DDL into a test fixture), inserts a `serve_instance` + `session_assignment`, then calls `RoutingLease.acquire({sessionID, serveId, instanceUuid})` and asserts it returns `{ok:true, token}` and a `session_lease` row exists with the right token. Run: `bun test test/serve/routing-lease.test.ts` → FAIL (module missing).

**Step 2 (green):** Implement `routing-lease.ts`: open a raw handle at `Flag.OPENCODE_ROUTING_DB` (resolve via the `Database.path()` pattern), `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000;`, boot-assert `routing_meta.schema_version`/`ddl_checksum` (fail closed on mismatch), and implement `acquire/renew/release/readValid` using the **exact SQL in Appendix A** (read `owner_generation`+`binary_epoch` fresh from `session_assignment`/`routing_meta` before acquire). Retry on `SQLITE_BUSY` with jitter. Run → PASS.

**Step 3:** Add tests for renew (full-token), release (full-token), and **fail-closed** (renew after a simulated `bumpEpoch`/`bumpGeneration` returns `ok:false`). Commit.

### Task 2: Cross-binding zero-overlap proof
**Files:** extend `pigeon` `test/routing/lease-cas-concurrency.test.ts` to fork ONE worker that drives the opencode `routing-lease.ts` adapter (or a thin harness around it) alongside the better-sqlite3 workers.
**Steps:** red (worker not wired) → green (wire it) → assert the existing zero-overlap invariant still holds with a mixed-binding writer set. This is the cross-binding multi-writer proof. Commit. *(If D1a, this also covers serve self-registration.)*

### Task 3: Serve self-registration + boot fence + self-heartbeat (`serve.ts`) — **D1a**
**Files:** Modify `packages/opencode/src/cli/cmd/serve.ts` (insert between line 20 and 22) + add `OPENCODE_SERVE_ID` to `flag.ts`. Reuse the `routing-lease.ts` connection from Task 1 (add `registerSelf`/`heartbeat`/`markDead` methods there). Test: `test/cli/serve/serve-process.test.ts`.
**Steps:** generate `instance_uuid` (`randomUUID()`); read `serve_id` from `Flag.OPENCODE_SERVE_ID`; assert `routing_meta` schema/checksum (fail closed); **upsert own `serve_instance` row** (endpoint `127.0.0.1:<port>`, current `binary_epoch`, `health_state='healthy'`, `heartbeat_at=now`); `Effect.forkScoped` a self-heartbeat fiber (`Effect.repeat(Schedule.spaced(...))`, cadence < `staleServeMs`) updating `serve_instance.heartbeat_at`; `Effect.addFinalizer` to mark the row `draining`/dead on shutdown. Gate the whole block on `Flag.OPENCODE_ROUTING_DB`. Red: extend serve-process test to assert a `serve_instance` row appears with the serve-minted `instance_uuid` after boot (routing env set) and flips dead/gone after scope close. Green. Commit.

### Task 3b: Pigeon-side reconcile + retire HTTP poller (pigeon repo) — **D1a**
**Files (pigeon):** `packages/daemon/src/routing/serve-registry.ts` (`seedServes`), `packages/daemon/src/routing/serve-health-poller.ts`, wiring in `packages/daemon/src/index.ts`. Tests under `packages/daemon/test/routing/`.
**Steps:** (1) Change `seedServes()` to reconcile by `serve_id` WITHOUT overwriting serve-owned `instance_uuid`/`heartbeat_at`/`health_state` (config still maps expected serve_id↔endpoint; the live identity row is the serve's). Red: test that an existing serve-written row survives a `seedServes()` call (instance_uuid + heartbeat preserved). (2) Retire/demote `ServeHealthPoller`: liveness = serve self-heartbeat staleness via existing `isServeHealthy`; feature-gate or keep a fallback so pigeon doesn't go blind for a serve that predates self-registration. Red: test that a serve with a fresh self-written `heartbeat_at` is `isServeHealthy` even with the poller off; a stale one is not. Green + commit. **Single writer on pigeon (sibling pre-cleared); use explicit-pathspec commits; PR + ff to main like M1.**

### Task 4: Agent-loop lease wrap (`prompt.ts:1407`)
**Files:** Modify `packages/opencode/src/session/prompt.ts:1407`. Test: `test/session/prompt.test.ts`.
**Step (red):** add a prompt test (routing env set, assignment pre-seeded for the test serve) asserting: a `session_lease` row exists *while* the loop runs and is gone after it completes; and that with NO assignment (D2a) the loop still runs (fail-open) but writes no lease.
**Step (green):** wrap `runLoop(input.sessionID)` in `Effect.acquireRelease(acquireLease, releaseLease)` (mirror `effect-flock.ts:253-266`). Acquire: if routing off → no-op sentinel; if on + assignment present → `RoutingLease.acquire` (fail the run if acquire fails on an *assigned* session); if on + no assignment → no-op (D2a). Release: fenced `release` on success/cancel/interrupt. Fork the TTL/3 renewal fiber **into the same scope** so it's interrupted before release. Commit.

### Task 5: Per-iteration renewal guard (`prompt.ts:1142`)
**Files:** Modify `packages/opencode/src/session/prompt.ts` around 1142 (guard only, NOT acquire). Test: extend prompt.test.ts.
**Behavior:** before a long/side-effecting step, check the local lease deadline; if it can't be renewed before a safety margin, pause/cancel the run (fail-closed — never proceed past the deadline). Red (simulate a renewal failure → loop must stop) → green → commit.

### Task 6: Generate patch + register + full-chain verify
**Steps:** `git diff` the opencode changes → `opencode-patched/patches/serve-lease.patch`; add `serve-lease` to `apply.sh` `PATCHES` (after `createnext-readback`) + header entry #9; run the **full** `apply.sh` chain on a fresh v1.17.7 worktree (`git apply --check` all 9) and run the session/serve test subset green with the full stack. Commit + push opencode-patched. The pigeon-side D1a change lands separately (Task 3b: PR + ff to pigeon main, like M1).

### Task 7: Canary p99 measurement (inline-vs-Worker gate)
Run the serve under the pool-probe / a representative active-session load with lease writes ON; capture event-loop p99 (the harness from the Phase-0 measurement work). If p99 regresses materially, open a follow-up to move lease I/O to a Bun Worker. Record the result in the bead. (Does not block M4 landing if inline is acceptable.)

---

## Risks (carry into execution)
- **Bun event-loop stalls from sync SQLite** — inline raw `bun:sqlite` calls on the serve's main loop; mitigated by WAL + short `busy_timeout` + jitter, measured in Task 7; Worker fallback.
- **Lease boundary correctness** — acquire ONLY at the prompt.ts:1407 once-per-run point; NEVER at status.set (1142) or `onBusy`. Verified once-per-run via runner.ts dedupe.
- **Identity / assignment dependency (D1/D2)** — the real blockers; resolve before coding.
- **Patch durability** — must apply against v1.17.7 and survive opencode upgrades; keep changes localized; the new module under `packages/core/src/serve/` minimizes diff against churny files.
- **Pigeon coupling (if D1a)** — retiring the HTTP health poller for serve self-heartbeat changes pigeon's liveness model; coordinate + keep a fallback.

---

## Appendix A — exact lease CAS SQL (from pigeon `route-repo.ts`, named `@params`)

```sql
-- acquireCAS (route-repo.ts:264-304): @sid,@serve,@uuid,@gen,@epoch,@now,@ttlMs
INSERT INTO session_lease (session_id, serve_id, instance_uuid, owner_generation, lease_expires_at, heartbeat_at, binary_epoch)
SELECT @sid, @serve, @uuid, sa.owner_generation, @now + @ttlMs, @now, rm.binary_epoch
FROM session_assignment sa JOIN routing_meta rm ON rm.id = 1
WHERE sa.session_id=@sid AND sa.desired_serve_id=@serve AND sa.owner_generation=@gen AND rm.binary_epoch=@epoch
ON CONFLICT(session_id) DO UPDATE SET
  serve_id=excluded.serve_id, instance_uuid=excluded.instance_uuid, owner_generation=excluded.owner_generation,
  lease_expires_at=excluded.lease_expires_at, heartbeat_at=excluded.heartbeat_at, binary_epoch=excluded.binary_epoch
WHERE EXISTS (SELECT 1 FROM session_assignment sa JOIN routing_meta rm ON rm.id=1
              WHERE sa.session_id=excluded.session_id AND sa.desired_serve_id=excluded.serve_id
                AND sa.owner_generation=excluded.owner_generation AND rm.binary_epoch=excluded.binary_epoch)
  AND ( session_lease.binary_epoch < excluded.binary_epoch
        OR (session_lease.binary_epoch = excluded.binary_epoch AND session_lease.owner_generation < excluded.owner_generation)
        OR (session_lease.binary_epoch = excluded.binary_epoch AND session_lease.owner_generation = excluded.owner_generation
            AND (session_lease.lease_expires_at <= @now
                 OR (session_lease.serve_id = excluded.serve_id AND session_lease.instance_uuid = excluded.instance_uuid))) );

-- renewCAS (route-repo.ts:306-335): @sid,@serve,@uuid,@gen,@epoch,@now,@ttlMs
UPDATE session_lease SET lease_expires_at=@now+@ttlMs, heartbeat_at=@now
WHERE session_id=@sid AND serve_id=@serve AND instance_uuid=@uuid AND owner_generation=@gen AND binary_epoch=@epoch
  AND EXISTS (SELECT 1 FROM session_assignment sa JOIN routing_meta rm ON rm.id=1
              WHERE sa.session_id=@sid AND sa.desired_serve_id=@serve AND sa.owner_generation=@gen AND rm.binary_epoch=@epoch);

-- release (route-repo.ts:337-357): @sid,@serve,@uuid,@gen,@epoch
DELETE FROM session_lease
WHERE session_id=@sid AND serve_id=@serve AND instance_uuid=@uuid AND owner_generation=@gen AND binary_epoch=@epoch;
```
`changes > 0` ⇒ success; `changes == 0` on renew/release ⇒ **ownership lost (fail closed)**. Read `owner_generation` (from `session_assignment`) and `binary_epoch` (from `routing_meta`) FRESH before each acquire.
