# Pool-of-K-serves replace — Design (zao4 broker/routing + mn9r DB-safety)

> **For Claude:** DESIGN doc (the "what and why"), not a task-by-task plan. Refines the
> "replace" option of `2026-06-17-process-per-session-design.md` after the serve-bench
> measurement work selected a **pool of K persistent serves** over process-per-session.
> Scope = the two gated beads **`workstation-zao4`** (broker + routing) and
> **`workstation-mn9r`** (multi-process DB safety), plus one new prerequisite: an
> opencode **`/event` session-scope patch**. The unchanged client-migration / removal /
> op-acceptance checklist lives in the prior doc (§12/§13) — not re-derived here.

**Status:** Design approved (user, 2026-06-19) after a ChatGPT deep-research consult
(`/tmp/research-pool-ingress-router-answer.md`). Sub-choices settled: **per-session
lease**; **standalone shared `StickyRouter` package**. Nothing implemented. Next step:
writing-plans → implementation plan.

**Companions:** `serve-bench` `docs/plans/2026-06-19-replace-characterization.md` (the
measurement that justifies this), `2026-06-17-process-per-session-design.md` (full replace
context), beads `workstation-l1qc` (measurement gate, DONE), `workstation-zao4`,
`workstation-mn9r`, `workstation-sqd5` (the prod reconnect-storm bug this prevents),
`workstation-p196` (createNext read-back).

---

## 0. Why a pool (the measured justification)

`opencode serve` is a single Bun event loop. Its `GlobalBus` broadcasts every event to
every `/event` subscriber, so M streaming sessions × subscribers × C chunks ≈ super-linear
deliveries on one thread → the serve wedges on **responsiveness** (canary p99 5 ms → ~500 ms)
while 13 of 16 cores sit idle. It is **fan-out cost, not CPU**.

serve-bench `scripts/pool-probe.ts` proved that **sharding sessions across K independent
serves** clears the wedge, because each serve then does only `M/K`-scale fan-out:

| | K=1 | K=2 | K=4 | K=8 |
|---|---|---|---|---|
| serve-side canary p99 @ M=50 | ~196 ms | ~halved | ~floor | ~floor |
| serve-side canary p99 @ M=80 | ~391 ms | ~halved | ~floor | ~floor |
| CPU mean @ M=80 | 0.84c | 1.42c | 2.08c | 3.06c |
| RSS max @ M=80 | 1.0 GB | 1.8 GB | 3.3 GB | 5.2 GB |

Idle canary = 4–8 ms; the residual ~100 ms "floor" under load was a harness artifact, not
the serve. Cost shape: idle serve ≈ 0.26c + 0.3 GB; per-session in-serve ≈ 0.012c + ~34 MB.
**K≈4 holds M=50–80 at ~2 cores / ~3 GB** — trivial on a 16-vCPU / 62 GiB host (cgroup soft
cap 32 GiB). Persistent serves also sidestep the V3 cold-boot storm (sessions are cheap
in-process objects, not processes).

**The architectural invariant that follows:** never re-centralize `/event` fan-out, event
filtering, or per-client SSE multiplexing on a single event loop — that just rebuilds the
wedge "under a different name." The router stays off the SSE byte path.

---

## 1. Topology — control plane / direct data plane

K=4 persistent `opencode serve` processes on fixed loopback ports, **sharing the one
SQLite WAL DB**. **pigeon** (`:4731`) is the **control plane only**; it is never on the SSE
byte path. Clients reach the owning serve **directly** for `/event` + streaming.

```
client ──control/query/discovery──▶ pigeon ingress router
client ──/event (session-scoped)──────────────────────────▶ serve[i]
client ──prompt/control (or via pigeon forward)───────────▶ serve[i]
                                                              │
                                                              ▼
                                                   claude-failover-proxy (egress)
                                                              │
                                                              ▼
                                                    Anthropic / Vertex / Max
```

| Owner | Responsibilities |
|---|---|
| **pigeon (router)** | session registry; assignment decisions (rendezvous placement); per-session lease CAS; serve health/heartbeat; spawn/reconstitute; discovery/redirect; cheap control forwarding; DB-backed queries; admission control |
| **serve[i]** | its session event loops; `/event` SSE; agent loops; **local fan-out for its shard only** |

**Not serve-2:** the router is pure I/O/control — no agent loops, no SSE fan-out — so it
cannot recreate the bottleneck.

---

## 2. Placement key — session-scoped `/event` (new prerequisite workstream)

**Decision:** assign by **`session_id`** with even spread (not by directory). This requires
patching opencode `/event` to be session-scoped, because today `GET /event?directory=…` is
**directory-global** (`event.ts:35-39` filters in-stream by `instance.directory`), which does
not compose with per-session ownership.

**The patch (small, localized):**
- Add `?session_ids=a,b,c` to the `/event` subscribe schema (`server/event.ts` group +
  `routes/instance/httpapi/handlers/event.ts`).
- Add one `Stream.filter` keeping an event iff its **aggregate id = `sessionID`** is in the
  requested set; **always pass** non-session global events (`server.connected`,
  `server.heartbeat`, `server.instance.disposed`).
- Feasible: EventV2 already aggregates session events by `sessionID`
  (`core/src/session/event.ts:31,37` → `aggregate: "sessionID"`; `EventSequenceTable.aggregate_id`).
- **Implementation-plan check:** confirm every event a client UI needs carries a filterable
  `sessionID` (aggregate or `data.sessionID`); `Location.Ref` does NOT (directory/workspace
  only), so the filter keys on the aggregate/data, not `location`.

**Client model:** a client opens a session-scoped subscription to each serve owning a
session it cares about. The common `opencode attach --session X` / `opencode run` case is
**1 session → 1 serve → 1 stream** — fully transparent. A multi-session client opens one
subscription per owning serve (discovered via §4); no router-side fan-in (that would be a
new GlobalBus).

**Patch home:** our maintained fork (deployment holds at `1.17.7-patched`); land on the
pool's standardized serve binary. Draft an upstream PR opportunistically (it is a generally
useful feature) but do not block on upstream.

---

## 3. Assignment ≠ lease (mn9r core, sub-choice A = per-session lease)

Two distinct DB concepts (avoids naive `hash % K`, which reshuffles on resize and has
nowhere to encode health/load/epoch/drain):

```sql
-- desired routing / scheduling decision (source of truth)
session_assignment (
  session_id        TEXT PRIMARY KEY,
  directory_key     TEXT NOT NULL,   -- retained for diagnostics / future co-location
  desired_serve_id  TEXT NOT NULL,
  owner_generation  INTEGER NOT NULL,
  state             TEXT NOT NULL,   -- assigned | draining | dormant | migrating
  last_active_at    INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
)

-- exclusive right to RUN the agent loop (prevents two runtimes for one session)
session_lease (
  session_id        TEXT PRIMARY KEY,
  serve_id          TEXT NOT NULL,
  instance_uuid     TEXT NOT NULL,
  owner_generation  INTEGER NOT NULL,
  lease_expires_at  INTEGER NOT NULL,
  heartbeat_at      INTEGER NOT NULL,
  binary_epoch      INTEGER NOT NULL
)

serve_instance (
  serve_id          TEXT PRIMARY KEY, -- stable slot id, e.g. serve-0
  instance_uuid     TEXT NOT NULL,    -- changes on every (re)boot
  endpoint          TEXT NOT NULL,    -- http://127.0.0.1:<port>
  binary_epoch      INTEGER NOT NULL,
  health_state      TEXT NOT NULL,
  heartbeat_at      INTEGER NOT NULL,
  draining          INTEGER NOT NULL
)
```

- **assignment** = where it *should* run; **lease** = the exclusive right to run it now.
- A serve serves traffic for a session only when assignment + lease agree (or it can
  atomically CAS-acquire/renew the lease). The router never trusts hash alone for an
  existing session: read assignment → validate serve heartbeat/lease → route/discover.
- **New/stale placement:** filter healthy + same-`binary_epoch` + non-draining serves →
  **rendezvous (HRW) hash** over `session_id` → bounded-load correction (skip a serve over
  active-turn/subscriber/memory thresholds) → persist assignment → serve CAS-acquires lease.
- **Sub-choice A (settled): per-session leases** (M≈50–80 rows — trivial; correctness of
  crash-reassignment + dormant-load > row count).
- SQLite WAL is fine for this small registry/lease workload on **one host** (WAL's shared
  memory requires same-host); keep lease/registry write txns tiny + `busy_timeout`.

---

## 4. Discovery & client reconnect

- **Primary:** `GET /route?session_id=…` on pigeon →
  `{ sessionId, serveId, instanceUuid, ownerGeneration, apiBase, eventUrl, expiresAt }`.
- **Convenience:** `307` redirect on a routed `/event?session_id=…` → owning serve
  (the HTML spec allows event-stream redirects; clients reconnect on close). Not the only
  mechanism — discovery is easier to cache/debug and carries generation/instance metadata.
- **Rediscover triggers:** SSE disconnect; `409/410/421/503`; connection refused;
  `instanceUuid` or `ownerGeneration` mismatch; router TTL expiry.
- **SSE replay:** opencode events have ids but no durable per-session replay buffer →
  **treat SSE as live/invalidation; reload messages from SQLite on reconnect.**
- **Idempotency:** prompt submission carries a `client_request_id`;
  `UNIQUE(session_id, client_request_id)` dedupes at the DB boundary (internal delivery is
  at-least-once).

---

## 5. Control & query routing + reconstitution

- **Cheap control** (prompt/abort/kill/delete/compact/summarize/model/mcp): pigeon forwards
  to the owning serve's endpoint (generalizes today's direct-channel). Low volume; safe on
  the router loop.
- **Query** (list/resolve/messages): pigeon reads the shared DB directly. Split DB-reads
  from live runtime ops (provider/MCP/model) which forward to the owning serve (prior §6 M6).
- **Reconstitution (dormant session):** message arrives → router sees no valid lease → picks
  a healthy serve → CAS assignment (bump `owner_generation`) → serve loads session from
  SQLite + CAS-acquires lease → deliver. **Cheap** — no process boot (serves are warm).
- **Auth (prior §6 M4, required before pigeon holds control authority):** bind loopback or a
  unix socket; require a daemon token on mutating routes; validate registration
  pid/session ownership before accepting a `backendEndpoint` overwrite.

---

## 6. Composability with `claude-failover-proxy` (sub-choice B = standalone lib)

Two proxies at different layers, **separate ownership, shared code:**

| Ingress router (pigeon) | Egress proxy (claude-failover-proxy) |
|---|---|
| "where does this session **run**?" | "which LLM **backend/account**?" |
| session→serve, lease, health, spawn, discovery, admission | session→LLM, budget failover, usage/cost metering, upstream SSE passthrough |

- Both key on session id and do **sticky + idle-migration**, but answer different questions
  and migrate independently (ingress moves a session between serves only when no active
  turn / no client stream / lease idle; egress flips backend only after `idleMigrateMs`).
- **Shared, pure library `StickyRouter<Key, Target>`** (sub-choice B settled: **standalone
  package** both repos depend on): pin/migrate state machine, idle-migration, TTL sweep,
  target-health, desired-target calc, in-flight tracking, deterministic tests. Seed = the
  failover proxy's existing pure `SessionRouter` (`claude-failover-proxy/src/router.ts`),
  generalized over `Target`.
- **Do not** share a state table or merge the proxies (merging tempts re-centralizing both
  client SSE and upstream SSE on one loop). Propagate headers:
  `X-Opencode-Session-Id`, `X-Pigeon-Serve-Id`, `X-Pigeon-Owner-Generation`,
  `X-Pigeon-Request-Id`, `X-Failover-Backend`.
- **Stream-path note:** with topology B the two SSE paths are already separate
  (`client ◀ serve[i]` and `serve[i] ◀ egress ◀ LLM`); the ingress router is not on the
  client SSE path, and the egress proxy is necessarily on the upstream token stream (it
  meters/failovers). No double-buffering of a single stream.

---

## 7. Pool sizing & admission control

**Fixed K=4 warm serves + admission control now; slow elasticity later.** Memory is not the
binding constraint (K=8 @ M=80 ≈ 5.2 GB vs 32 GiB soft cap); per-loop responsiveness +
cgroup CPU scheduling is.

- **Admission:** when all healthy serves exceed a hard active-turn cap (start ~25/serve,
  tune), queue `prompt_async` briefly or return `429`/`503` with `Retry-After`.
- **Elasticity (later):** `K_min=4`, `K_max=8`; scale out when per-serve canary p99 > 500 ms
  for N consecutive windows or active-turns/subscribers per serve over threshold; scale in
  only when a serve has no leased sessions + no subscribers + idle 10–30 min + above K_min.
  Keep it slow (fast scaling = reassignment churn, cold caches, more lease traffic).

---

## 8. DB safety & binary cutover (rest of mn9r)

- **Pin `OPENCODE_DB`** (+ `OPENCODE_DISABLE_CHANNEL_DB=1`) on **all** launchers — service
  envs don't today (`hosts/cloudbox/configuration.nix`, `users/dev/home.devbox.nix`): a
  latent channel-DB split-brain.
- **`createNext` read-back** before register/start (mirror core `V2Session.create`) → no
  live-but-rowless sessions (bead `workstation-p196`).
- **Tiny short** lease/registry write txns + `busy_timeout`; never hold a write txn across
  network I/O, process spawn, stream setup, or LLM calls.
- **Atomic cutover** (more important here — more writers to quiesce): add `binary_epoch` to
  `serve_instance` + `session_lease`. Procedure: router `accepting_new_work=false` → mark
  all serves `draining` → wait for active turns to finish (or abort by policy) → stop all
  serve processes → (optional SQLite checkpoint/backup) → bump `binary_epoch` → start new
  serves → resume routing. **Old serves must not renew leases after the epoch changes.** A
  real maintenance fence is honored by every launcher (pigeon, oc-launch, oc-revive, lgtm,
  timers, user shells); verify zero opencode DB FDs before a swap.

---

## 9. Failure modes (explicit patterns)

| Failure | Pattern |
|---|---|
| **Serve crash, N sessions assigned** | heartbeat stops → router marks unhealthy → leases expire → bump `owner_generation` → new serve CAS-acquires lease → reconstitute from SQLite → clients rediscover. Do **not** try to preserve the in-flight SSE; client reloads messages, agent resumes or reports a deterministic failed turn. |
| **Router restart** | active client SSE continues (direct to serves, topology B). Only new discovery/control/query is affected. Router rebuilds purely from SQLite (serve/assignment/lease/epoch tables). |
| **Stale endpoint / port reuse** | every endpoint implies `serve_id` + `instance_uuid` + `owner_generation` + `binary_epoch`; client rediscovers on mismatch. Stable slot ports never reused for a different logical serve without generation invalidation. |
| **Dormant session message** | §5 reconstitution. |
| **Duplicate delivery** | `UNIQUE(session_id, client_request_id)`, `UNIQUE(session_id, intersession_message_id)`; at-least-once internally, dedupe at DB boundary. |
| **SQLite busy** | tiny serialized lease CAS writes + `busy_timeout`; no long-held write txns. |

---

## 10. Phasing (scoped to zao4 + mn9r + the /event patch)

1. **opencode `/event` session-scope patch** (§2) — incl. verifying session-id filterability
   on all relevant event types. *Gate for per-session placement.*
2. **Shared `StickyRouter` standalone package** (§6) — extracted/generalized from the
   failover proxy's `SessionRouter`; deterministic tests.
3. **pigeon router** (§3,§4,§5): registry + assignment/lease/serve tables + rendezvous
   placement + lease CAS + discovery/redirect + cheap control forwarding + auth.
4. **Serve-pool supervisor** (§1,§7,§8): boot K, health/heartbeat, drain, atomic cutover,
   admission control.
5. **Client migration** (prior doc §12): attach / run / oc-launch / oc-revive / lgtm /
   reset-workspace → discovery + per-session `/event`. Remove `:4096` single endpoint.
6. **Elasticity** (§7) — last, slow, optional.

Removal gate (prior §12) + op-acceptance gates (prior §13) still apply before serve is
deleted; not re-derived here.

---

## 11. Open items for the implementation plan

- Confirm the exact set of UI-relevant event types and that each is session-filterable
  (aggregate or `data.sessionID`); decide handling for any genuinely global-but-useful event.
- Concrete bounded-load thresholds (active turns / subscribers / memory per serve) — seed
  from §7, tune empirically against the pool-probe harness.
- `StickyRouter` package name + repo location + how both repos consume it (workspace dep vs
  published).
- Rendezvous-hash weight function (uniform vs capacity-weighted) and reshuffle behavior on
  K change.
- Whether `oc-launch`/`oc-revive` (`ensureRuntime`) target "assign + ensure leased on a
  pool serve" instead of the prior "spawn a process."
