# Opaque reverse proxy for the opencode serve pool

**Date:** 2026-07-12
**Status:** Design — **revision 2**, post fable adversarial review (2026-07-12).
Front-door architecture **confirmed** (network opacity is the goal). Awaiting
implementation planning (`writing-plans`). Do NOT implement yet.
**Host focus:** cloudbox (K=4) first; design kept cross-host-capable.
**Repos touched:** `workstation` (new systemd unit + client rewrites),
`pigeon` (internal-only `/route`), `opencode-patched` (attach event-stream path
+ the `/event?session_ids=` hard dependency) — see §11.

> **Revision 2 note.** Draft 1 was pressure-tested by the fable adversarial
> reviewer. The architecture (pigeon = control plane, thin data-plane front
> door, no mid-turn migration handling) survived; three of six decisions rested
> on false source claims and were corrected. Key changes: verification
> re-anchored on the **deployed v1.17.13-patched line** (not `~/projects/opencode`
> HEAD); event-stream drift now **drops the client leg** instead of silently
> swapping upstream (§4); wedge detection is **endpoint-class-aware** (§5);
> new-session placement uses the **shipped create→`/place` choreography** and
> **drops "least-loaded" spread** (§3); added the **pigeon-down degrade path**,
> **native `/healthz`**, **WebSocket/PTY + `/global/*` policies**, and an
> **infra-plane exemption** (§5–§8). See "Changes from draft 1" at the end.

## The goal: network opacity (one port)

Today every client reaches an opencode session by (1) calling pigeon
`GET /route?session_id=<sid>` (:4731), (2) parsing an `apiBase` URL out of the
JSON (e.g. `http://127.0.0.1:4097`), and (3) connecting **directly** to that
`409x` port. That leaks the K=4 serve pool's internals — port range, serve
count, `OPENCODE_SERVE_ID`s, the very existence of a pool — to every caller.

We want **network opacity**: a single `127.0.0.1` front-door port is the *only*
address the rest of the machine ever uses, with the pool free to change shape
(K, ports, identity) behind it without touching a single client.

**Why a full L7 front door is the only mechanism that delivers this** (rejected
alternatives, so we don't relitigate): an HTTP redirect leaks the `409x` in the
`Location` header; a dumb proxy to a random serve breaks session affinity
(serve-lease gives one serve ownership of a session's loop + per-serve event
bus); serve-side or in-pigeon forwarding just relocates the same data plane to a
worse blast-radius home (§ Considered & rejected). A **shared resolver library**
was considered and rejected for *this* goal: it delivers only *interface*
opacity (clients still dial `409x` via a helper), not the one-port requirement.
Its resolve/place/fallback logic is instead reused as the front door's
**internal routing core**.

## The two proxy planes (context)

Two orthogonal proxy planes exist on this box; this project touches **only the
ingress plane**.

**Plane A — LLM egress (serve → model providers). NOT in scope.** Already
proxied: `aigateway` (:8080, cost capture) and `claude-failover-proxy`/cfp
(:8789, Vertex↔Max failover). `session-header.ts` injects `x-opencode-session`
on **these** requests for LLM-layer cache affinity. Direction:
`serve → cfp/aigateway → Vertex`. Consequence for us: the ingress front door
**cannot** use `x-opencode-session` (it lives only on the egress plane) — it must
derive the sid from opencode's client-facing HTTP surface (§3).

**Plane B — client ingress (clients → serve pool). IN scope.**
- K serves on `4096–4099`, `OPENCODE_SERVE_ID=serve-<i>`, `serve-0` (4096) the
  new-session anchor (`users/dev/serve-pool.nix`).
- pigeon (:4731) is already the session-aware router, but a **control plane
  only**: `GET /route` and `POST /place` return a URL; they do **not** forward
  bytes (`pigeon/packages/daemon/src/routing/router.ts`, `.../src/app.ts`).

## ⚠️ Verification target (meta-hazard from review)

`~/projects/opencode` is a **dev branch** (`origin = anomalyco/opencode`,
mid-`effect-httpapi` rewrite) — **NOT** the deployed line. The fleet runs
**`v1.17.13-patched`** (`users/dev/home.base.nix:70`, source of truth
`github.com/johnnymo87/opencode-patched` main). **Every opencode-HTTP-surface
fact in this design and its plan MUST be verified against v1.17.13 + the current
patch set, never against `~/projects/opencode` HEAD.** Several capabilities this
design relies on (notably `/event?session_ids=`, below) exist **only** as our
patches, not upstream.

## Decisions (scoping session + review corrections)

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the front door? | **Session-aware opaque L7 data plane.** `/route` drops off the client contract (kept internal). |
| 2 | Trust boundary | **Localhost-only, no auth**, with a clean seam for a future remote front. |
| 3 | Migration transparency | **No mid-turn migration handling** (lease invariant); re-resolve owner per request boundary; on event-stream drift **drop the client leg** (rev 2, was: silent upstream swap). |
| 4 | Health / failover | **Fail-fast, endpoint-class-aware** (rev 2): first-byte timeout on cheap paths only; health-probe for turn-running POSTs; retryable `503`; no reinvented failover. |
| 5 | Identity + placement | Keep `OPENCODE_SERVE_ID`/ports **internal, unchanged**. New sessions placed by **pigeon HRW via `POST /place`** (rev 2, **dropped** front-door "least-loaded" spread). |
| 6 | Where the forwarder runs | **Dedicated `opencode-frontdoor` process** (own unit + `MemoryMax` + canary + `/healthz`), NOT inside pigeon. |

## Verified-solid facts (do not relitigate)

From the review's source audit of pigeon + the deployed line:

- **`/route` contract:** active-route → prospective-route → 404, strictly
  read-only, sid regex `^ses_[A-Za-z0-9_-]+$` (`app.ts:586-612`).
- **Lease invariant (the load-bearing one):** `reassignFromDeadServe` refuses to
  evict a session with a valid lease on the flagged serve (`router.ts:296-315`);
  only the owning serve can renew (full-token `renewCAS`, `router.ts:252-263`).
  So the owner is stable for the duration of a turn.
- **Stale-heartbeat CPU-stall is handled better than draft 1 claimed — a
  strength to lean on:** when a busy single-threaded serve's heartbeat goes
  stale, `resolveRoute` returns null but `GET /route` falls through to
  `resolveProspectiveRoute`, which **honors a still-valid lease even with a stale
  heartbeat** (`router.ts:117-123`). So per-request re-resolution during a
  CPU-stalled turn still lands on the true owner.
- **`placeSession` already does bounded-load HRW** (`activeTurnCap` skip,
  `router.ts:174-181`) with lease CAS + `LeaseContendedError` fallback.
- **`POST /place` exists** and runs `ensureRouted` (`app.ts:552-584`) — the
  create-window fix (§3) builds on it.
- **`getWorkspaceRouteSessionID`** (`server/shared/workspace-routing.ts`) is a
  ready sid-from-URL extractor to copy (verify on the deployed line).
- Attach today is a per-process `/global/event` firehose + client-side filter +
  the #15 confirm-twice 5 s `/route` poll (`home.base.nix:122-140`).

## Architecture

```
                         ┌───────────────────────────────────┐
   all local clients ───►│  opencode-frontdoor (ONE port)     │
 (attach, launch, reset, │  - extract sid from request        │
  audit, lgtm, telegram) │  - resolve owner via internal /route│──┐ internal /route + /place
                         │  - forward HTTP+SSE(+WS) bytes      │  │ (localhost only)
                         │  - endpoint-class timeouts → 503    │  ▼
                         │  - pigeon-down → degrade to anchor  │  pigeon daemon :4731
                         │  - native /healthz (unproxied)      │  (control plane:
                         └───────────────┬────────────────────┘   HRW/lease/health/
                                         │                         migration/reassign)
    infra plane (canary, wedge-watcher,  │  forward to owner
    reset per-serve probes) ── EXEMPT ──►│
    dials 4096..409x DIRECTLY            ▼
                              serve-0..serve-K (4096..409x)  ← internal only
                                   shared opencode.db
```

Pigeon stays the **control plane** (single source of truth for `sid→serve`). The
front door is a thin **data plane** that asks pigeon *where* and moves bytes.

### 1. Trust boundary (Decision 2)
Binds `127.0.0.1:<frontdoor-port>`; no auth (matches the all-localhost posture of
serves, pigeon, aigateway, cfp). The remote story (`remote-workstation-cutover`)
is SSH-tunnel-based, so day-one remote/auth is out of scope, but the "who is
calling" seam is kept in one place so a future Tailscale/reverse-tunnel front
bolts on without redesign.

### 2. Request routing (Decisions 1, 5)
- **sid extraction.** A map of opencode's session-scoped endpoints pulls the sid
  from the path (`/session/:sessionID/…`) or query (`?session_ids=`,
  `?session=`). Copy `getWorkspaceRouteSessionID` + the `/route` regex; **verify
  the map against the deployed v1.17.13 route table** (open item, §10).
- **session-scoped request** → internal `/route` → forward bytes to the
  lease-owning serve, **re-resolved per request boundary** (safe via the lease
  invariant, above).
- **new session (create)** → **create → `POST /place` → respond** (§3).
- **global / non-session endpoints** → policy per §6 (not a blanket
  "any healthy serve").

### 3. New-session creation: the shipped choreography, not "least-loaded" (Decision 5, rev 2)
Draft 1's "front door spreads new sessions least-loaded" is **dropped**: (a)
opencode mints sids server-side — `Session.CreateInput` has **no** sid field
(`session/session.ts`), so a client-supplied sid would need yet another patch;
(b) a front-door placement choice would be a *second placement brain* fighting
pigeon's bounded-load HRW (`router.ts:174-181`), building a migration into every
session's first second.

Instead, internalize the **already-shipped** `opencode-launch` / `oc-auto-attach`
choreography (the workstation-iwpj fix, `pkgs/opencode-launch/default.nix:340-370`,
`pkgs/oc-auto-attach/default.nix:345-349`):

1. forward the create to a convenient serve (anchor is fine);
2. parse the minted sid from the create response;
3. `POST /place` with that sid (pigeon HRW-places; writes assignment+lease);
4. **only then** return the create response to the client.

After step 3, `GET /route` resolves and **there is no registration window**. No
pin-map needed. "Spread" still happens (pigeon's HRW), and the anchor is demoted
to "where creates are forwarded" without the front door choosing serves.

> Note: pigeon `POST /place` returns `.api_base` (not `.apiBase`); the internal
> resolver core must accept both (as `oc-pool-attach` already does,
> `default.nix:45`).

### 4. Long-lived event streams (Decision 3, rev 2 — the hard part)

opencode attach today rides a **per-process `/global/event` firehose**, pinned at
attach time, filtering client-side (`home.base.nix:122-133`). A per-serve
firehose is ambiguous behind a K-serve door.

**Change:** attach moves to the **session-scoped `/event?session_ids=<sid>`**
path.

> **⚠️ C1 hard dependency (accepted).** `session_ids` is **NOT upstream** — it
> exists only as our patch **#7 `event-session-scope`** (`home.base.nix:220-226`);
> the deployed HttpApi otherwise **400s on undeclared query params**. We
> **accept** the front door hard-depending on this patch staying in the patched
> line (chosen over a `/global/event`-forwarding fallback). Requirements: (a) a
> **tripwire test in opencode-patched CI** asserting `/event?session_ids=`
> exists and is session-scoped; (b) this design's contract note that the front
> door **requires the patched line** — a plain upstream opencode breaks it by
> design. pigeon already advertises this URL as `RouteResult.eventUrl`
> (`router.ts:90`).

The front door then:
1. holds the client's SSE leg on the one port;
2. **re-resolves the owner on a timer** (internal `/route`, confirm-twice like
   #15);
3. on **owner drift** (only at idle — the lease invariant forbids mid-turn
   migration), **closes the client SSE leg** so the client reconnects and
   re-bootstraps its state through its existing sync machinery.

> **Why drop the leg, not silently swap (rev 2, C2).** The SSE stream has **no
> replay**: events carry `id: undefined`, no Last-Event-ID, live-only (patch #11
> fixed a *cold-start live-delivery* race, not replay). Draft 1's "hold the
> client leg open and swap the upstream silently" would convert today's
> *self-healing* gap (client reconnects → re-bootstraps) into a **permanent
> silent gap**, because the client's heal path (reconnect) never fires.
> Dropping the client leg preserves exactly today's semantics at near-zero
> cost. This is strictly simpler than draft 1.

Before implementing, **inventory which non-session event types the deployed TUI
reacts to** (e.g. `server.instance.disposed` as a re-bootstrap trigger, patch
#14) so the move off `/global/event` doesn't starve it (open item, §10).

### 5. Health / failover (Decision 4, rev 2)
- **Dead serve:** free — pigeon's `resolveRoute` returns null for an unhealthy
  owner and re-picks from `listHealthy`; the front door just re-resolves.
- **Wedged serve ("alive but frozen"):** the trap. Corrections from review:
  - **Connect timeout catches nothing** — the kernel accepts TCP into the listen
    backlog while the JS loop is frozen; connects *succeed*.
  - **A blanket first-byte timeout false-positives on the highest-value
    traffic** — synchronous `POST /session/:id/message` (and `shell`, `command`,
    `summarize`, `init`) legitimately return only when the **turn finishes**,
    minutes later. A blanket timeout would `503` every long prompt; a big
    compaction would `503` the whole box.
  - **Fix — endpoint-class policy:** aggressive first-byte timeout for cheap GETs
    and the SSE handshake; **no first-byte timeout** for turn-running POSTs — on
    suspicion, **probe the target serve's `/global/health` directly** (bounded,
    cheap — exactly what the canary does) and `503` only on probe failure.
- **Retry reality (document, don't overclaim):** most migration-surface clients
  are `curl -sf` scripts that treat any failure as fatal; a client that *does*
  retry re-hits the **same** wedged serve (pigeon's health stays green for
  ~3 min until the canary restarts it). So a `503` means **"wait for the canary,"
  not "instant recovery."** The front door does **not** reinvent failover.

### 6. Endpoint classes beyond sid-routing (rev 2, M3)
The sid model cannot route everything. **Re-inventory on the deployed line**, but
from source the classes are:
- **WebSocket / PTY:** `/pty/:ptyID/connect` is a WS upgrade keyed by `ptyID`
  (not sid), state in-process on the creating serve. The front door needs **WS
  upgrade proxying + a `ptyID→serve` pin**, or PTY declared out of scope and the
  endpoint blocked. Decide based on whether the deployed TUI uses PTY (open item).
- **Per-process globals with side effects:** `/global/dispose`, `/global/upgrade`
  mutate one process — routing to "any healthy serve" disposes/upgrades a random
  serve. Explicit policy required: **deny** / pin-to-anchor / fan-out.
- **Read-only globals** (`/global/health`, config): route to any healthy serve
  (shared `opencode.db`), anchor default.
  - **CORRECTION (Phase-5 fable F2):** the "shared `opencode.db`" premise is
    **false for a subset** of GET globals that read **per-process in-memory
    state**, not the shared db: `GET /session/status` (in-memory `SessionStatus`
    Map — reports *idle* for a session mid-turn on another serve), `GET
    /permission`, `GET /question`, `GET /api/permission/request`, `GET
    /api/question/request` (in-memory pending requests), and `GET /mcp`
    (per-process MCP connection status). Anchor-forwarding these through the door
    returns **only the anchor's view** (silently wrong for a session owned by
    another serve — the same mis-serve shape that justified `/global/event`→410,
    but on the read path). Latent today (no deployed client hits them through the
    door — the TUI uses the session-scoped v2 lists), so they remain
    `global-ro`→anchor for v1, but the rows are annotated (`note:` in
    `routes.classification.ts`) and must be revisited (deny, or a per-owner
    fan-in) before any client is pointed at the door for these reads (Phase 7/9).
- **Unrecognized endpoints:** **404-loud + log** during shakeout, never silent
  forward, so a future stateful endpoint can't silently mis-route.

### 7. Availability: degrade + native health (rev 2, M2)
- **Pigeon-down degrade.** Today every client falls back to `$OPENCODE_URL`
  (anchor) on any pigeon hiccup — "never worse than pre-pool"
  (`opencode-launch/default.nix:30-37`, `oc-auto-attach:79-90`,
  `home.base.nix:1088-1102`). The front door **must preserve this**: when
  internal `/route` is unreachable or 404s, forward to the **anchor**. Otherwise
  opacity turns a graceful degrade into `frontdoor ∧ pigeon ∧ serve` hard-AND.
- **Native `/healthz` (unproxied).** The canary must probe the *forwarder
  itself*, not a proxied `/global/health` (which conflates
  frontdoor+pigeon+serve — a pigeon outage would restart a healthy front door;
  a wedged serve would never trip it). Add a dedicated `/healthz` that tests only
  the forwarder.
- **SPOF, stated plainly.** The front door is a **total-outage single point of
  failure for all opencode access**, with the same "alive but frozen" JS risk as
  everything else here. It carries the full isolation kit: own systemd unit, own
  `MemoryMax`, its own **canary** on `/healthz`, independently restartable. It is
  **stateless** except a short-TTL sticky map (§8), so it needs **no restart
  ordering** vs pigeon/serves and survives the nightly reset / pool restart /
  binary-epoch bump by simply re-resolving — state that in the unit.

### 8. Residual owner-stability windows (rev 2, M5)
Narrow, pre-existing (they already affect `/route` consumers), but the front door
extends per-request re-resolution to *all* traffic, so document + mitigate:
- **Lease-less fail-open turns:** a serve running a turn for a session whose
  `desired_serve_id` mismatches runs **without a lease** (`serve-pool.nix:13`);
  pigeon thinks it idle, so a per-request re-resolve could send `abort` /
  `permissionRespond` to a *different* serve where they no-op (user can't stop a
  runaway turn).
- **Draining serves:** `resolveProspectiveRoute` skips a valid lease if the serve
  is draining (`router.ts:120`).
- **Mitigation:** per-sid **short-TTL front-door stickiness** — route follow-ups
  to where the last turn-starting request went until `/route` disagrees twice
  (the confirm-twice idiom already used for streams). Document the residual.

### 9. Identity & isolation (Decisions 5, 6)
`OPENCODE_SERVE_ID=serve-<i>` and ports `4096–4099` stay **internal and
unchanged** — pigeon's routing key (`seedServes` → `desired_serve_id` → lease
CAS; the `serve-pool.nix` drift firewall) and the session-switcher's overlay key.
The front door is its own unit (own `MemoryMax` + `/healthz` canary), keeping a
data-plane bug from taking swarm messaging + the routing DB down with it (the
reason Decision 6 rejected an in-pigeon forwarder).

## Migration surface (rev 2, M4 — clients rewritten to the one URL)

All drop "ask `/route`, parse `apiBase`, dial `409x`" for the single front-door
URL. **Verified full list** (draft 1 was incomplete):
- `opencode-launch` / `opencode-send`
- **`oc-auto-attach`** (`pkgs/oc-auto-attach/default.nix:250-349`; also calls
  `POST /place`, which becomes front-door-internal)
- **`oc-pool-attach`** (`pkgs/oc-pool-attach/default.nix:45-86`; its
  `ses_poolprobe` reachability idiom needs a front-door equivalent)
- `reset-workspace` (recommendation-session enrichment)
- `opencode-llm-audit` follower
- `my-podcasts`
- Telegram launch path
- `lgtm-sessions` attach hints (`users/dev/home.base.nix:1198-1223`)
- **`docs/plans/serve-distribution-probe.sh`**, **`users/dev/test-pool-route-clients.sh`**
- **Hardcoded `OPENCODE_URL=http://127.0.0.1:4096` in
  `hosts/cloudbox/configuration.nix:511,556`** (systemd env, not just script
  defaults) and `home.base.nix:1076`
- `opencode attach` itself (drops its `/route` self-resolve; the front door owns
  owner-following via the drop-leg-on-drift behavior of §4)

### Infra-plane exemption (MUST state explicitly)
The **canary**, **wedge-watcher**, and **reset-workspace's per-serve health
probes** MUST keep dialing `4096–409x` **directly** — their whole job is
detecting what pigeon cannot see. Routing them through the front door destroys
wedge detection. This is a deliberate whitelist, not an oversight.

## Impact on the approved session-switcher design (do not break)
`docs/plans/2026-07-12-opencode-session-switcher-{design,plan}.md`'s verified
facts **all hold**: serve identity keyed on `OPENCODE_SERVE_ID` (not port),
global `opencode.db`, nvim-socket discovery, per-instance state overlay — all
**unchanged**. The **only** change is a *simplification* of its attach URL: from
a `/route`-derived `apiBase` to a fixed **`opencode attach <FRONT_DOOR>
--session <sid>`** (no discovery call, no `apiBase` parse, no port knowledge).
Adjust that plan's jump-or-attach accordingly. **Nothing here invalidates its
"verified facts."**

## Open items (resolve in planning; not blockers to review)
1. **Deployed-line route-table audit (v1.17.13 + patches).** Enumerate
   session-scoped endpoints + sid location; confirm the create response shape;
   confirm PTY/WS usage by the deployed TUI; confirm which non-session event
   types the TUI needs (§4). This replaces every "verify against
   `~/projects/opencode`" in draft 1.
2. **`/event?session_ids=` tripwire** in opencode-patched CI (§4, C1).
3. **Client-leg-drop re-bootstrap check:** confirm the deployed TUI re-bootstraps
   cleanly when the front door closes its SSE leg on drift (§4).
4. **PTY policy:** proxy WS + `ptyID` pin, vs block PTY (§6) — driven by open
   item 1.
5. **`/global/dispose|upgrade` policy:** deny / anchor / fan-out (§6).
6. **`ses_poolprobe` equivalent:** a front-door reachability idiom for
   `oc-pool-attach` (§ migration surface).
7. **internal `/route` cutover:** keep pigeon `/route`+`/place`, bind localhost,
   remove from client callers.
8. **host scope:** cloudbox-first behind an `isCloudbox` gate (mirroring
   `session-header.ts`); cross-host later.
9. **front-door port choice** and whether `OPENCODE_URL` is repointed at the
   front door or a new var introduced.

## Codebases / files to study (planning)
- `~/projects/workstation`: `users/dev/serve-pool.nix`;
  `users/dev/home.devbox.nix:695-880` (serve `@` unit, canary, wedge-watcher;
  cloudbox analog `hosts/cloudbox/configuration.nix`); `users/dev/home.base.nix`
  (serve-lease / `attach-route-resolve` / `tui-follow-owner` / `yl00` / `#15`
  notes; patch list `:70-249`; lgtm `/route` client `:1198-1223`; `OPENCODE_URL`
  `:1076`); `users/dev/opencode-config.nix` (plugin gating `:352-358`);
  `assets/opencode/plugins/session-header.ts`;
  `pkgs/{opencode-launch,oc-auto-attach,oc-pool-attach}/`;
  `.opencode/skills/{monitoring-serve-pool,resetting-workspace,operating-aigateway}/SKILL.md`;
  `docs/plans/2026-07-12-opencode-session-switcher-{design,plan}.md`.
- `~/projects/pigeon`: `packages/daemon/src/routing/{router,serve-registry,serve-health-poller,client-factory,rendezvous,directory-resolver}.ts`;
  `packages/daemon/src/app.ts` (`/route` `:586-611`, `/place` `:552-584`);
  `packages/daemon/test/routing/*`.
- **opencode-patched @ v1.17.13** (the deployed line — NOT `~/projects/opencode`
  HEAD): server route table (`packages/opencode/src/server/*`), `shared/workspace-routing.ts`,
  the `/event` handler, `session/session.ts` (`CreateInput`), `pty` group, the
  `attach-route-resolve` (#10), `event-session-scope` (#7), `tui-follow-owner`
  (#15) patches.

## Considered & rejected
- **Keep `/route` as a client-facing discovery endpoint** — leaks pool
  internals; the exact opacity failure this project fixes.
- **Shared resolver library only** — delivers *interface* opacity, not the
  one-port *network* opacity that is the goal; reused as the front door's
  internal core instead.
- **Dumb reverse proxy / path-prefix / HTTP redirect** — either leaks `409x`
  (redirect `Location`) or breaks session affinity; doesn't collapse addressing
  for session-targeted traffic.
- **Forwarder inside the pigeon daemon** — welds a high-throughput HTTP/SSE data
  plane onto the swarm-messaging + outbox daemon; a forwarder leak/wedge takes
  messaging + the routing DB down. Bad blast-radius trade on a box with a
  documented "alive but frozen" failure mode.
- **Full mid-turn stream-stitching / zero-break migration** — unnecessary (lease
  invariant forbids mid-turn migration) and, worse, defeats the client's
  reconnect-based self-heal (§4, C2).
- **Silent upstream-swap on event-stream drift (draft 1)** — converts a
  self-healing gap into a permanent silent one; replaced by drop-the-client-leg
  (§4).
- **Front-door "least-loaded" new-session spread (draft 1)** — impossible
  (server-minted sids) and a second placement brain fighting pigeon HRW;
  replaced by create→`/place` (§3).
- **Front door owns active failover** — duplicates pigeon's recovery, fights the
  canary + lease CAS.

## Changes from draft 1 (for the record)
1. Verification re-anchored on **v1.17.13-patched**, not `~/projects/opencode`
   HEAD (meta-hazard).
2. `/event?session_ids=` documented as a **hard dependency on patch #7** +
   tripwire (C1), accepted over a fallback.
3. Event-stream drift: **drop the client leg** instead of silent upstream swap
   (C2).
4. Wedge detection: **endpoint-class-aware** (no first-byte timeout on turn
   POSTs; health-probe instead); retry reality documented (C3).
5. New-session placement: **create→`POST /place`** choreography; **dropped
   "least-loaded" spread** (M1).
6. Added **pigeon-down degrade to anchor** + native **`/healthz`** + explicit
   **SPOF** statement (M2).
7. Added **WebSocket/PTY** + **`/global/dispose|upgrade`** + unrecognized-endpoint
   policies (M3).
8. Migration surface completed (`oc-auto-attach`, `oc-pool-attach`, probe/test
   scripts, `configuration.nix` env) + **infra-plane exemption** (M4).
9. Documented **lease-less / draining** residual windows + short-TTL stickiness
   (M5).
10. Minor: no request-body replay after forwarding; jittered SSE reconnect on
    front-door restart; SSE no-buffer / heartbeat-aware idle timeout; reuse
    `getWorkspaceRouteSessionID` for sid extraction.
