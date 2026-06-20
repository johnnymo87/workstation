# zao4 — Pigeon Ingress Router Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the session→serve ingress router inside the pigeon daemon so that, in a pool of K opencode serves sharing one SQLite DB, every control/query/discovery operation (and crucially cross-serve session→session messaging) resolves to the serve that owns the target session.

**Architecture:** pigeon stays the single control plane (`:4731`). A new `routing/` module adds three SQLite tables (serve registry, session→serve assignment, per-session lease), a pure rendezvous-hash (HRW) placement function that consumes the published `sticky-router` library for stickiness, an `IngressRouter` service that does assignment + lease CAS, a `/route` discovery endpoint, an auth layer (loopback bind + bearer token, enforce-when-configured), and a per-session `OpencodeClient` factory that replaces the single fixed `:4096` base URL. Pigeon is the **sole lease authority** (it health-checks serves and owns the lease rows); serve-side lease *enforcement* is out of scope (deferred to mn9r). Built **router-first against the existing single serve as a degenerate K=1 pool**; mn9r later grows K→4 and adds the serve-pool supervisor + DB-safety.

**Tech Stack:** TypeScript (ESM, `node:http`, no framework), `better-sqlite3` (synchronous, hand-written SQL), `vitest`, `tsx`. Dependency: `sticky-router` v0.1.0 (`git+ssh://git@github.com/johnnymo87/sticky-router.git#v0.1.0`), pure ESM, zero runtime deps, committed `dist/`.

**Repo:** ALL code in `/home/dev/projects/pigeon` (its own git repo; single writer = this work). Plan doc lives in `workstation/docs/plans/`. Any `pigeon-daemon.service` env / sops / Nix change is OUT of this plan and coordinated separately with the sibling session (workstation shared tree).

**Design source:** `workstation/docs/plans/2026-06-19-pool-replace-design.md` §3 (assignment≠lease + schemas), §4 (discovery/reconnect), §5 (control/query routing + reconstitution + auth), §11 (open items). Open items resolved for this plan: #3 sticky-router published (done); #4 **uniform HRW + sticky assignments** (existing assignments never recomputed; HRW only for new/dormant placement; capacity-weighting deferred); #5 `ensureRuntime` = "ensure assigned + leased on a healthy serve", and zao4 rewires existing pigeon delivery paths; #1 `/event` session-scope filter landed (x8wi); #2 bounded-load thresholds seeded as config constants, tuned later.

---

## Key decisions baked into this plan

1. **Pigeon-authoritative leases (no opencode patches).** Pigeon writes/owns `serve_instance` (via its own health poll) and `session_lease`/`session_assignment` via CAS. The lease's correctness role here is "pigeon never double-assigns + records ownership for crash-reassignment". A serve refusing to run a session it doesn't hold a lease for = mn9r.
2. **Tables live in the pigeon DB** alongside `sessions`/`swarm_messages` (the daemon cannot read opencode.db today; recon confirmed). New `initRouteSchema(db)` mirrors `initSwarmSchema`.
3. **K=1 degenerate first.** `serveEndpoints` config defaults to `[opencodeUrl]` (the existing `:4096`). Rewiring consumers to a per-session client factory is a **behavior-preserving refactor** in K=1 (existing tests stay green). Cross-serve correctness is proven with **2 fake serves** in an integration test (no real opencode needed).
4. **Auth is enforce-when-configured.** If `PIGEON_DAEMON_AUTH_TOKEN` is unset (current deployment + most tests), routes behave as today. When set, mutating/control/`/route` routes require `Authorization: Bearer <token>`. The actual token (sops) + loopback enforcement in Nix is coordinated later; this plan only adds the mechanism + the default loopback `bind` arg.
5. **Stickiness via `sticky-router`.** `IngressRouter` holds one `StickyRouter<string, string>` (key=sessionId, target=serveId). Caller computes `desired` = HRW pick over healthy serves; `StickyRouter.route` enforces pin + idle-migration. The DB `session_assignment` row is the *durable* mirror; `StickyRouter` is the in-memory hot path that survives within a daemon process and is rebuilt from the assignment table on boot.

---

## Module layout (new files under `packages/daemon/src/routing/`)

```
routing/
  route-schema.ts          # initRouteSchema(db): 3 tables + indexes + additive ALTERs
  route-repo.ts            # ServeInstanceRepo, SessionAssignmentRepo, SessionLeaseRepo
  rendezvous.ts            # pure HRW: rankServes(), pickServe()
  router.ts                # IngressRouter service (resolveRoute/placeSession/ensureRouted/lease CAS/sweep)
  serve-registry.ts        # in-memory healthy-serve view backed by serve_instance
  serve-health-poller.ts   # periodic GET <endpoint>/global/health -> serve_instance
  client-factory.ts        # clientForSession(sessionId) -> OpencodeClient bound to owning serve
  types.ts                 # RouteResult, ServeInstanceRecord, AssignmentRecord, LeaseRecord
```
Tests live in `packages/daemon/test/routing/` (vitest `include: ["test/**/*.test.ts"]`).

---

## Milestones → sub-beads

| Milestone | Sub-bead (create under zao4) | Depends on |
|---|---|---|
| M1 Route storage (schema + repos) | zao4-m1 | — |
| M2 Rendezvous HRW (pure) + dep | zao4-m2 | — |
| M3 IngressRouter service | zao4-m3 | M1, M2 |
| M4 Serve health (registry + poller) | zao4-m4 | M1 |
| M5 `/route` discovery endpoint | zao4-m5 | M3, M4 |
| M6 Auth + loopback bind | zao4-m6 | — (independent) |
| M7 Per-session client factory + rewire | zao4-m7 | M3 |
| M8 Cross-serve swarm delivery + integ test | zao4-m8 | M7 |
| M9 K=1 end-to-end verify + docs | zao4-m9 | all |

Each milestone ends with: `npm run typecheck -w packages/daemon` + `npm test -w packages/daemon` green, then a commit. Use **`git status` pre-commit + `git add <explicit paths>`** even though pigeon isn't the shared tree (good hygiene).

---

## Task 0: Branch + dependency wiring

**Files:** `packages/daemon/package.json`

**Step 1:** Create a feature branch in pigeon.
```bash
cd /home/dev/projects/pigeon && git checkout -b zao4-ingress-router && git status
```

**Step 2:** Add the sticky-router git dependency.
Edit `packages/daemon/package.json` dependencies, add:
```json
"sticky-router": "git+ssh://git@github.com/johnnymo87/sticky-router.git#v0.1.0"
```

**Step 3:** Install + verify the import resolves.
```bash
cd /home/dev/projects/pigeon && npm install
node --input-type=module -e "import {StickyRouter} from 'sticky-router'; const r=new StickyRouter(1000); console.log(typeof r.route)"
```
Expected: `function`. (Confirms committed `dist/` + ESM resolution work over the git dep.)

**Step 4:** Commit.
```bash
git add packages/daemon/package.json package-lock.json && git commit -m "build(daemon): add sticky-router git dependency"
```

---

## Task M1: Route storage — schema + repos

**Files:**
- Create: `packages/daemon/src/routing/route-schema.ts`
- Create: `packages/daemon/src/routing/types.ts`
- Create: `packages/daemon/src/routing/route-repo.ts`
- Modify: `packages/daemon/src/storage/database.ts` (wire `initRouteSchema` + repos onto `StorageDb`)
- Test: `packages/daemon/test/routing/route-repo.test.ts`

**Schema (`route-schema.ts`)** — mirror `swarm-schema.ts` style:
```ts
import type BetterSqlite3 from "better-sqlite3";

export function initRouteSchema(db: BetterSqlite3.Database): void {
  db.exec(`
    CREATE TABLE IF NOT EXISTS serve_instance (
      serve_id       TEXT PRIMARY KEY,
      instance_uuid  TEXT NOT NULL,
      endpoint       TEXT NOT NULL,
      binary_epoch   INTEGER NOT NULL DEFAULT 0,
      health_state   TEXT NOT NULL DEFAULT 'unknown',  -- healthy | unhealthy | unknown
      heartbeat_at   INTEGER NOT NULL,
      draining       INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS session_assignment (
      session_id        TEXT PRIMARY KEY,
      directory_key     TEXT,
      desired_serve_id  TEXT NOT NULL,
      owner_generation  INTEGER NOT NULL DEFAULT 1,
      state             TEXT NOT NULL DEFAULT 'assigned', -- assigned|draining|dormant|migrating
      last_active_at    INTEGER NOT NULL,
      updated_at        INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_assignment_serve
      ON session_assignment(desired_serve_id, state);

    CREATE TABLE IF NOT EXISTS session_lease (
      session_id        TEXT PRIMARY KEY,
      serve_id          TEXT NOT NULL,
      instance_uuid     TEXT NOT NULL,
      owner_generation  INTEGER NOT NULL,
      lease_expires_at  INTEGER NOT NULL,
      heartbeat_at      INTEGER NOT NULL,
      binary_epoch      INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_lease_serve ON session_lease(serve_id);
    CREATE INDEX IF NOT EXISTS idx_lease_expiry ON session_lease(lease_expires_at);
  `);
}
```

**types.ts** — `ServeInstanceRecord`, `AssignmentRecord`, `LeaseRecord`, and:
```ts
export interface RouteResult {
  sessionId: string;
  serveId: string;
  instanceUuid: string;
  ownerGeneration: number;
  apiBase: string;     // serve endpoint, e.g. http://127.0.0.1:4096
  eventUrl: string;    // `${apiBase}/event?session_ids=${sessionId}`
  expiresAt: number;   // lease_expires_at
}
```

**route-repo.ts** — three repo classes following `swarm-repo.ts` (constructor `(db)`, `asRecord` mappers, prepared statements). Required methods (drive each with a test):
- `ServeInstanceRepo`: `upsert(rec)`, `get(serveId)`, `listHealthy(now, staleMs, binaryEpoch)` (health_state='healthy' AND heartbeat_at > now-staleMs AND draining=0 AND binary_epoch=?), `setHealth(serveId, state, now)`, `setDraining(serveId, bool)`, `all()`.
- `SessionAssignmentRepo`: `get(sessionId)`, `upsert(rec)`, `bumpGeneration(sessionId, now)` (owner_generation+1, return new value), `touchActive(sessionId, now)`, `setState(sessionId, state, now)`, `listForServe(serveId)`.
- `SessionLeaseRepo`: `get(sessionId)`, `acquireCAS(input, now)` (INSERT or UPDATE only if expired or same owner_generation — returns boolean acquired), `renewCAS(sessionId, serveId, instanceUuid, ownerGeneration, now, ttlMs)` (UPDATE … WHERE session_id=? AND serve_id=? AND instance_uuid=? AND owner_generation=?; return changes>0), `release(sessionId)`, `listExpired(now)`.

**Lease CAS detail (the correctness heart):** `acquireCAS` must be a single SQL statement (atomic under better-sqlite3's serialized writes). Use INSERT…ON CONFLICT with a guarded UPDATE:
```ts
acquireCAS(i: { sessionId:string; serveId:string; instanceUuid:string; ownerGeneration:number; binaryEpoch:number }, now:number, ttlMs:number): boolean {
  const res = this.db.prepare(`
    INSERT INTO session_lease
      (session_id, serve_id, instance_uuid, owner_generation, lease_expires_at, heartbeat_at, binary_epoch)
    VALUES (@sid, @serve, @uuid, @gen, @exp, @now, @epoch)
    ON CONFLICT(session_id) DO UPDATE SET
      serve_id=@serve, instance_uuid=@uuid, owner_generation=@gen,
      lease_expires_at=@exp, heartbeat_at=@now, binary_epoch=@epoch
    WHERE session_lease.lease_expires_at <= @now          -- expired
       OR session_lease.owner_generation < @gen           -- newer generation wins
       OR (session_lease.serve_id=@serve AND session_lease.instance_uuid=@uuid) -- our own renew
  `).run({ sid:i.sessionId, serve:i.serveId, uuid:i.instanceUuid, gen:i.ownerGeneration, epoch:i.binaryEpoch, exp: now+ttlMs, now });
  return res.changes > 0;
}
```

**Step 1 (test, write first):** `test/routing/route-repo.test.ts` with `openStorageDb(":memory:")`. Cases:
- serve upsert→get round trips; `listHealthy` excludes stale/unhealthy/draining/wrong-epoch.
- assignment upsert→get; `bumpGeneration` increments and returns new value.
- lease `acquireCAS` succeeds on empty; a **second** acquire by a *different* serve with the *same* generation **fails** (returns false); acquire by a higher generation **succeeds** (crash-reassignment); same-owner renew **succeeds**; acquire after `lease_expires_at` passes **succeeds**.

**Step 2:** Run, expect FAIL (repos not implemented).
`cd /home/dev/projects/pigeon && npm test -w packages/daemon -- route-repo`

**Step 3:** Implement schema + types + repos. Wire into `database.ts`: import `initRouteSchema`, call after `initSwarmSchema(db)` (line 35); add `serves`, `assignments`, `leases` to `StorageDb` interface + returned object.

**Step 4:** Run, expect PASS. Then `npm run typecheck -w packages/daemon`.

**Step 5:** Commit.
```bash
git add packages/daemon/src/routing/route-schema.ts packages/daemon/src/routing/types.ts packages/daemon/src/routing/route-repo.ts packages/daemon/src/storage/database.ts packages/daemon/test/routing/route-repo.test.ts
git commit -m "feat(routing): serve/assignment/lease tables + repos with lease CAS"
```

---

## Task M2: Rendezvous HRW placement (pure) + sticky-router seam

**Files:**
- Create: `packages/daemon/src/routing/rendezvous.ts`
- Test: `packages/daemon/test/routing/rendezvous.test.ts`

**rendezvous.ts** — uniform HRW (highest-random-weight). Deterministic, no clock, no I/O:
```ts
import { createHash } from "node:crypto";

/** HRW score = hash(serveId + ":" + sessionId) as a number; highest wins. */
function score(serveId: string, sessionId: string): bigint {
  const h = createHash("sha256").update(`${serveId}:${sessionId}`).digest();
  // first 8 bytes as unsigned bigint — stable, uniform
  return h.readBigUInt64BE(0);
}

/** Rank candidate serves for a session, highest score first. Pure + deterministic. */
export function rankServes(sessionId: string, serveIds: readonly string[]): string[] {
  return [...serveIds].sort((a, b) => {
    const d = score(b, sessionId) - score(a, sessionId);
    return d > 0n ? 1 : d < 0n ? -1 : a < b ? -1 : 1; // tie-break on id for determinism
  });
}

/** Top-ranked healthy serve, or undefined if none. */
export function pickServe(sessionId: string, serveIds: readonly string[]): string | undefined {
  return rankServes(sessionId, serveIds)[0];
}
```

**Step 1 (test first):** cases:
- `pickServe` is deterministic for the same inputs.
- Removing a non-owning serve from the candidate set does **not** change the pick (HRW minimal-reshuffle property): pick over `[s0,s1,s2,s3]` == pick over `[s0,s1,s2,s3]` minus a serve that wasn't the winner.
- Removing the *winning* serve promotes the **next-ranked** serve (the only session that moves).
- Distribution sanity: 1000 session ids over 4 serves each get a pick; rough even spread (assert each serve gets >150).

**Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** PASS + typecheck.

**Step 5:** Commit `feat(routing): uniform rendezvous-hash placement`.

> Note: `sticky-router` is consumed in M3 (it needs `now` + the router lifecycle), not here. M2 is the pure `desired`-computation half; `StickyRouter` enforces stickiness on top.

---

## Task M3: IngressRouter service (assignment + lease CAS + stickiness)

**Files:**
- Create: `packages/daemon/src/routing/router.ts`
- Test: `packages/daemon/test/routing/router.test.ts`

**router.ts** — composes repos + `StickyRouter` + rendezvous. Constructor takes `{ serves, assignments, leases }` repos + options `{ leaseTtlMs, staleServeMs, idleMigrateMs, activeTurnCap, nowFn }`. Holds `private sticky = new StickyRouter<string,string>(idleMigrateMs)`.

Core methods (each TDD'd):
- `rebuildFromDb()`: load `session_assignment` rows → seed `sticky` so in-memory state matches durable state after a daemon restart. (StickyRouter has no bulk-seed; seed by calling `route(sid, lastActiveAt, desiredServeId)` per row — pins each key to its persisted serve.)
- `resolveRoute(sessionId, now): RouteResult | null`
  1. `a = assignments.get(sessionId)`; if none → return null (caller calls `placeSession`).
  2. `serve = serves.get(a.desiredServeId)`; if missing/unhealthy/stale/draining → return null (needs replacement).
  3. `lease = leases.get(sessionId)`; if missing/expired or `lease.owner_generation !== a.owner_generation` → return null.
  4. else build `RouteResult` from serve + lease.
- `placeSession(sessionId, now, opts?): RouteResult`
  1. `candidates = serves.listHealthy(now, staleServeMs, binaryEpoch)` → their ids; throw `NoHealthyServeError` if empty.
  2. Apply **bounded-load skip** (M3 minimal: drop serves whose `assignments.listForServe(id).length >= activeTurnCap`; if all over cap, keep full set = best effort). Result = `eligible`.
  3. `desired = pickServe(sessionId, eligible)` (HRW).
  4. `chosen = sticky.route(sessionId, now, desired)` — stickiness: an existing in-memory pin stays unless idle ≥ idleMigrateMs.
  5. **Sticky-vs-health guard:** if `chosen` is not in `candidates` (its serve died) → force `chosen = desired` and treat as migration.
  6. `existing = assignments.get(sessionId)`; compute `ownerGeneration`: if new, 1; if `chosen !== existing.desired_serve_id` (migration), `assignments.bumpGeneration` else keep.
  7. `assignments.upsert({...})` (state 'assigned', last_active_at=now).
  8. `acquired = leases.acquireCAS({sessionId, serveId:chosen, instanceUuid: serve.instance_uuid, ownerGeneration, binaryEpoch}, now, leaseTtlMs)`. If `!acquired` → re-`resolveRoute` (someone else holds a valid lease) and return that, else throw `LeaseContendedError`.
  9. Return `RouteResult`.
- `ensureRouted(sessionId, now): RouteResult` = `resolveRoute(sessionId, now) ?? placeSession(sessionId, now)`. **This is `ensureRuntime`.**
- `touch(sessionId, now)`: `assignments.touchActive` + `leases.renewCAS` (called on activity to keep the lease + stickiness warm).
- `sweep(now)`: `sticky.sweep(now, ttlMs)`; mark assignments dormant whose lease expired; (do NOT delete rows — reconstitution rebuilds).
- `reassignFromDeadServe(serveId, now)`: for each `assignments.listForServe(serveId)` → bumpGeneration + placeSession (picks a new healthy serve). Used by the health poller (M4) when a serve goes unhealthy.

**Step 1 (tests first)** — use real `:memory:` repos + injected `nowFn`. Cases:
- new session → `ensureRouted` places it on the HRW serve, writes assignment + lease, RouteResult fields correct (`eventUrl` = `${apiBase}/event?session_ids=${sid}`).
- second `ensureRouted` (same now) → `resolveRoute` hits, **no** generation bump, same serve.
- serve goes unhealthy (`serves.setHealth(...,'unhealthy')`) → `resolveRoute` returns null → `placeSession` migrates to another healthy serve, **owner_generation bumps**, new lease acquired (old generation can't renew).
- stickiness: with 2 healthy serves where HRW `desired` flips for a session, a **continuously active** session (touch each step) does NOT migrate before `idleMigrateMs`; after idle ≥ idleMigrateMs it migrates.
- `NoHealthyServeError` when no healthy serves.
- `rebuildFromDb` after constructing a fresh router over a populated db → `resolveRoute` works without a prior `placeSession` (pin restored).

**Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS + typecheck. **Step 5:** Commit `feat(routing): IngressRouter assignment+lease+stickiness service`.

---

## Task M4: Serve registry + health poller

**Files:**
- Create: `packages/daemon/src/routing/serve-registry.ts` (thin: seeds `serve_instance` from configured endpoints, assigns stable `serve_id` slots `serve-0..serve-(K-1)`, generates `instance_uuid` per boot)
- Create: `packages/daemon/src/routing/serve-health-poller.ts`
- Test: `packages/daemon/test/routing/serve-health-poller.test.ts`
- Modify: `packages/daemon/src/config.ts` (add `serveEndpoints: string[]`, `leaseTtlMs`, `staleServeMs`, `healthPollMs`, `activeTurnCap`, `idleMigrateMs` with defaults; `serveEndpoints` defaults to `opencodeUrl ? [opencodeUrl] : []`)

**serve-health-poller.ts:** a loop (injectable `fetchFn`, `nowFn`, `setInterval`-free for tests — expose `pollOnce()`):
- `pollOnce(now)`: for each serve in `serves.all()`, `GET ${endpoint}/global/health` with a short timeout → on 2xx `serves.setHealth(id,'healthy',now)`; on error/timeout `serves.setHealth(id,'unhealthy',now)` and call `router.reassignFromDeadServe(id, now)` (so assigned sessions migrate). Update `heartbeat_at`.
- `start()`/`stop()` wrap `pollOnce` on `healthPollMs`.

**Config defaults:**
```ts
serveEndpoints: parseList(env.PIGEON_SERVE_ENDPOINTS) ?? (opencodeUrl ? [opencodeUrl] : []),
leaseTtlMs:   Number(env.PIGEON_LEASE_TTL_MS   ?? 30_000),
staleServeMs: Number(env.PIGEON_SERVE_STALE_MS ?? 15_000),
healthPollMs: Number(env.PIGEON_HEALTH_POLL_MS ?? 5_000),
activeTurnCap: Number(env.PIGEON_ACTIVE_TURN_CAP ?? 25),   // §7 seed
idleMigrateMs: Number(env.PIGEON_IDLE_MIGRATE_MS ?? 60_000),
```

**Step 1 (tests first):** fake `fetchFn`:
- healthy endpoint → serve marked healthy, heartbeat advances.
- failing endpoint → marked unhealthy + `reassignFromDeadServe` invoked (spy) → sessions assigned to it get re-placed onto a healthy serve.
- recovery: endpoint healthy again → marked healthy; new placements may use it.

**Step 2–4:** FAIL → implement → PASS + typecheck. **Step 5:** Commit `feat(routing): serve registry + health poller with dead-serve reassignment`.

---

## Task M5: `/route` discovery endpoint

**Files:**
- Modify: `packages/daemon/src/app.ts` (add `GET /route` case; insert near `/sessions/:id` at app.ts:504, before the 404 at :524)
- Modify: `packages/daemon/src/index.ts` (construct `IngressRouter` + `ServeRegistry` + poller from config/storage; pass router into `createApp`)
- Test: `packages/daemon/test/routing/route-endpoint.test.ts` (drive `createApp(...)` `handleRequest` with a `Request`)

**Endpoint contract:** `GET /route?session_id=ses_…`
- 400 if missing/!`^ses_` (mirror app.ts:152 validation).
- `router.ensureRouted(sessionId, now)` → 200 JSON `RouteResult`.
- `NoHealthyServeError` → 503 `{ error, retryAfter }` + `Retry-After` header (admission control seed, §7).

**Step 1 (tests first):** wire a `createApp` test harness with `:memory:` storage + a router seeded with one healthy serve. Cases: valid session → 200 with `serveId/apiBase/eventUrl/expiresAt`; bad id → 400; no healthy serve → 503 + `Retry-After`.

**Step 2–4:** FAIL → implement → PASS + typecheck. **Step 5:** Commit `feat(daemon): GET /route session discovery endpoint`.

---

## Task M6: Auth layer + loopback bind

**Files:**
- Modify: `packages/daemon/src/config.ts` (`bindHost` default `127.0.0.1`; `authToken` from `PIGEON_DAEMON_AUTH_TOKEN`)
- Modify: `packages/daemon/src/server.ts` (`server.listen(config.port, config.bindHost)`)
- Create: `packages/daemon/src/auth.ts` (`requireAuth(request, token): Response | null` — null = OK; 401 Response otherwise)
- Modify: `packages/daemon/src/app.ts` (call `requireAuth` at top of `handleRequest` for mutating/control/`/route` routes when `authToken` set; allowlist `GET /health`)
- Modify: `packages/daemon/src/opencode-plugin/.../daemon-client.ts` (send `Authorization: Bearer` when `PIGEON_DAEMON_AUTH_TOKEN` present) — so the plugin keeps registering when auth is enabled
- Test: `packages/daemon/test/auth.test.ts`

**Behavior:** auth **disabled when `authToken` falsy** (current deployment + existing tests untouched). When set: missing/wrong bearer on a protected route → 401; correct → proceeds; `/health` always open.

**Step 1 (tests first):** token unset → protected route works without header (back-comp); token set → 401 without header, 200 with correct header, `/health` open regardless.

**Step 2–4:** FAIL → implement → PASS + typecheck (run **root** `npm test` so plugin package compiles too). **Step 5:** Commit `feat(daemon): loopback bind + optional bearer auth on control routes`.

> The sops token + `pigeon-daemon.service` env + bind enforcement in workstation Nix is OUT of scope here and coordinated with the sibling.

---

## Task M7: Per-session OpencodeClient factory + rewire consumers

**Files:**
- Create: `packages/daemon/src/routing/client-factory.ts`
- Modify: consumers that hold the single shared `OpencodeClient` (from index.ts:31): `worker/command-ingest.ts`, `worker/revive-and-deliver.ts`, `worker/kill-ingest.ts`, `worker/interrupt-ingest.ts`, `worker/compact-ingest.ts`, `worker/mcp-ingest.ts`, `worker/model-ingest.ts`, `worker/current-state-ingest.ts`, `worker/launch-ingest.ts`, and the swarm `arbiter`
- Test: `packages/daemon/test/routing/client-factory.test.ts` + update any consumer tests

**client-factory.ts:**
```ts
export class OpencodeClientFactory {
  private cache = new Map<string, OpencodeClient>(); // keyed by endpoint
  constructor(private router: IngressRouter, private nowFn = () => Date.now()) {}
  forSession(sessionId: string): OpencodeClient {
    const r = this.router.ensureRouted(sessionId, this.nowFn());
    let c = this.cache.get(r.apiBase);
    if (!c) { c = new OpencodeClient(r.apiBase); this.cache.set(r.apiBase, c); }
    return c;
  }
  forEndpoint(apiBase: string): OpencodeClient { /* cache get-or-create */ }
}
```

**Rewire pattern:** each consumer currently closes over one `opencodeClient`. Change index.ts to construct an `OpencodeClientFactory` and pass it (or a `forSession` fn) to each ingest. Inside each handler, replace `opencodeClient.X(sessionId, …)` with `factory.forSession(sessionId).X(sessionId, …)`.

**K=1 invariant:** with `serveEndpoints=[:4096]`, `forSession` always returns the `:4096` client → identical behavior. **Existing worker tests must stay green** — this is the proof the refactor is safe. If a test constructs `OpencodeClient` directly, give it a factory whose `forSession` returns that client.

**Step 1:** Run the **existing** suite to capture green baseline: `npm test -w packages/daemon`.
**Step 2 (test):** `client-factory.test.ts` — `forSession` returns a client whose base == the routed serve; two sessions on different serves → different clients; same serve → cached same instance.
**Step 3:** Implement factory; rewire consumers one file at a time, running `npm test -w packages/daemon` after each to keep green.
**Step 4:** Full suite + typecheck green.
**Step 5:** Commit `refactor(daemon): resolve opencode client per session via ingress router`.

---

## Task M8: Cross-serve swarm delivery + integration test

**Files:**
- Modify: `packages/daemon/src/worker/revive-and-deliver.ts` (use `factory.forSession(targetSessionId)` instead of the fixed serve client; resolve the owning serve via router)
- Modify: `packages/daemon/src/worker/command-ingest.ts` delivery/fallback path so swarm/command delivery to a target session forwards to the **owning serve** (router-resolved), not `:4096`
- Test: `packages/daemon/test/routing/cross-serve-delivery.test.ts` (the headline acceptance test)

**Headline integration test (proves the user's requirement):**
1. Stand up **two fake serves** as `node:http` stubs (or `fetchFn` doubles) `serve-0`@portA, `serve-1`@portB, each recording POSTed prompts with the session id.
2. Seed `serve_instance` with both (healthy). Build `IngressRouter` + factory.
3. Assign `ses_A` → serve-0, `ses_B` → serve-1 (force via HRW or direct `placeSession` with a stubbed candidate order).
4. Simulate `ses_A` sending a swarm message to `ses_B` (`/swarm/send` then trigger delivery, OR call the delivery path directly with `to=ses_B`).
5. **Assert** the prompt landed on **serve-1's** stub (carrying `ses_B`), and **not** serve-0. Reverse direction too (B→A lands on serve-0).
6. Assert delivery after the target's serve goes unhealthy re-routes to the surviving serve (reassignment path).

**Step 1:** Write the failing integration test. **Step 2:** FAIL. **Step 3:** Implement the rewiring. **Step 4:** PASS + full suite + typecheck. **Step 5:** Commit `feat(routing): cross-serve session→session delivery via owning-serve resolution`.

---

## Task M9: K=1 end-to-end verification + docs

**Files:**
- Modify: `packages/daemon/README.md` / `docs/` in pigeon (document the routing module, `/route`, env vars, K=1 vs K=N)
- No new feature code (verification milestone)

**Steps:**
1. Full green gate: `npm run typecheck` + `npm test` at repo root (all 3 packages).
2. **Real K=1 e2e** against the running serve on this host: start the daemon with `PIGEON_SERVE_ENDPOINTS=http://127.0.0.1:4096`, then:
   - `curl 'http://127.0.0.1:4731/route?session_id=<a real ses_ id>'` → expect a `RouteResult` pointing at `:4096`.
   - Drive an actual `/swarm/send` between two real local sessions → confirm delivery still works (regression of today's behavior under the new resolution path).
3. Document the deferred-to-mn9r items inline: serve-side lease enforcement, OPENCODE_DB pinning, K=4 supervisor, atomic cutover, sops auth token + Nix env.
4. Update bead `workstation-zao4` notes with "what's done / what mn9r must pick up", set status, `bd dolt push`.
5. Commit `docs(routing): ingress router usage + mn9r handoff notes`. Push the pigeon branch + open PR (pigeon follows normal push rules).

---

## Out of scope (explicitly mn9r or later)

- Serve-pool **supervisor** (boot K serves, fixed ports) — mn9r.
- **Serve-side lease enforcement** (serve refuses unleased sessions) + `createNext` read-back — mn9r / p196.
- `OPENCODE_DB` pinning + `OPENCODE_DISABLE_CHANNEL_DB` on launchers; **atomic binary cutover** + maintenance fence — mn9r §8.
- **sops auth token**, `pigeon-daemon.service` env, loopback enforcement in **workstation Nix** — coordinated with sibling (shared tree).
- **Client migration** (attach/run/oc-launch/oc-revive/lgtm/reset-workspace → discovery + per-session `/event`) and removal of the `:4096` single endpoint — prior-doc §12, phase 5.
- **Elasticity** (K_min/K_max autoscale), **capacity-weighted** HRW — §7, last.
- **307 redirect** convenience on `/event` — optional; discovery `/route` is the primary mechanism, add later if a client wants it.
- **All-devices deployment** (constraint from human, 2026-06-19 via sibling): this stack ultimately ships to **devbox, macOS, crostini** too, not just cloudbox. zao4's pigeon-repo code is host-agnostic (K = `PIGEON_SERVE_ENDPOINTS` config), so no zao4 impact — but **mn9r** must size the pool per device (a Chromebook can't run K=4 like a 16-vCPU box) and the deferred Nix env must be **host-gated**. Captured here so it isn't lost when mn9r starts.

---

## Risks / watch-items

- **better-sqlite3 is synchronous** → all repo calls block the event loop. Keep lease/registry txns tiny (single statements); never await network inside a write (design §8). The health poller does network *outside* the DB writes.
- **StickyRouter in-memory vs durable assignment drift** after a daemon crash mid-`placeSession`: order writes assignment→lease; `rebuildFromDb` re-pins from the assignment table on boot; a torn write self-heals on next `resolveRoute` (lease/assignment mismatch → re-place).
- **Auth rollout ordering:** enabling the token in Nix before the plugin sends it would 401 registrations. Mitigation: mechanism ships disabled-by-default; the sibling-coordinated Nix change sets the token on BOTH daemon and serve/plugin env in one commit.
- **Cross-package test compile:** M6 touches the plugin; run root `npm test`, not just the daemon workspace.
