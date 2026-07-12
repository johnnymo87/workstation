# Opaque reverse proxy for the opencode serve pool

**Date:** 2026-07-12
**Status:** Design — awaiting adversarial review, then implementation planning
(`writing-plans`). Do NOT implement yet.
**Host focus:** cloudbox (K=4) first; design kept cross-host-capable.
**Repos touched:** `workstation` (new systemd unit + client rewrites),
`pigeon` (internal-only `/route`, possible routing helpers), `opencode`
(attach event-stream path change) — see §10.

## Motivation

Today the rest of the machine must know the serve pool's internals to reach a
session. A client:

1. calls pigeon `GET /route?session_id=<sid>` (:4731),
2. parses `apiBase` out of the JSON (e.g. `http://127.0.0.1:4097`),
3. connects **directly** to that `409x` port.

That leaks the pool's internals — port range, serve count, individual
endpoints, and the very existence of a pool — to every caller
(`opencode-launch`/`-send`, `reset-workspace`, `opencode-llm-audit`,
`my-podcasts`, the Telegram launch path, `lgtm-sessions` attach hints at
`users/dev/home.base.nix:1211`, and `opencode attach` itself). We want the pool
to be **entirely opaque**: one front-door port, forever, with the pool free to
change shape (K, ports, identity) behind it without touching a single client.

## The two proxy planes (context that shaped this design)

There are two orthogonal proxy planes on this box. This project touches **only
the ingress plane**.

**Plane A — LLM egress (serve → model providers). NOT in scope.**
Already fully proxied: `aigateway` (:8080, cost-capture to Vertex, both
Anthropic + Gemini) and `claude-failover-proxy`/cfp (:8789, budget-gated
Vertex↔Max failover, Anthropic-only, re-bases onto aigateway). The
`session-header.ts` plugin injects `x-opencode-session` on **these** requests so
cfp can do sticky/idle-migrate *cache* affinity at the LLM layer. Direction is
`opencode serve → cfp/aigateway → Vertex`; a serve-pool front door sits
*upstream* of all of it and never intersects it. The only shared vocabulary is
"session-sticky affinity." Consequence: the ingress front door **cannot** rely
on the `x-opencode-session` header (it exists only on the egress plane) — it
must derive the sid from opencode's own client-facing HTTP surface.

**Plane B — client ingress (clients → serve pool). IN scope.**
- K serves on `4096–4099`, `OPENCODE_SERVE_ID=serve-<i>`, `serve-0` (4096) the
  anchor for new sessions (`users/dev/serve-pool.nix`).
- **pigeon (:4731) is already the session-aware router** — but a *control
  plane only*: `GET /route` returns a URL, it does **not** forward bytes
  (`pigeon/packages/daemon/src/routing/router.ts`, `.../src/app.ts:586-611`).
  It owns HRW placement (`placeSession`), sticky pinning, per-session lease CAS,
  health polling, serve-lease migration, and dead-serve reassignment.

**Crux:** a "single front-door port" ≈ pigeon's existing routing brain **+ a new
HTTP/SSE data-plane forwarder on one port**, turning "here's the URL, go connect
yourself" into "send me the bytes, I'll forward them to the lease owner."

## Decisions (from the scoping session)

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the front door? | **Session-aware opaque data plane.** `/route` drops off the client contract (kept internal). Kills the "dumb proxy / path-prefix" option. |
| 2 | Trust boundary | **Localhost-only, no auth** (matches serves + pigeon today), with a clean seam so a future remote front bolts on later. |
| 3 | Migration transparency | **No mid-turn migration to handle** — rely on the serve-lease invariant; re-resolve owner at each request boundary; the long-lived event stream re-targets on **idle** drift. |
| 4 | Health / failover | **Fail-fast pass-through** — connect/first-byte timeout → retryable `503`; do NOT reinvent recovery. |
| 5 | Identity + anchor | Keep `OPENCODE_SERVE_ID`/ports **internal, unchanged**. **Spread new sessions** across the healthy pool; anchor demoted to fallback-when-nothing-healthy. |
| 6 | Where the forwarder runs | **Dedicated `opencode-frontdoor` process** (own unit + `MemoryMax` + canary), NOT inside the pigeon daemon. |

## Architecture

```
                         ┌───────────────────────────────┐
   all local clients ───►│  opencode-frontdoor (ONE port) │
 (attach, launch, reset, │  - extract sid from request    │
  audit, lgtm, telegram) │  - resolve owner (internal)    │──┐  internal /route
                         │  - forward HTTP+SSE bytes      │  │  (localhost only)
                         │  - fail-fast timeout → 503     │  ▼
                         └───────────────┬───────────────┘  pigeon daemon :4731
                                         │                  (control plane:
                     forward to owner    │                   HRW/lease/health/
                                         ▼                   migration/reassign)
                              serve-0..serve-K (4096..409x)  ← internal only
                                   shared opencode.db
```

Pigeon stays the **control plane** (routing brain, single source of truth for
`sid→serve`). The front door is a thin **data plane** that asks pigeon *where*
and moves the bytes.

### 1. Trust boundary (Decision 2)

Binds `127.0.0.1:<frontdoor-port>`; no auth. Everything on this box is already
`127.0.0.1`-bound (serves, pigeon, aigateway, cfp), and the existing remote
story (`remote-workstation-cutover`) is SSH-tunnel-based, so day-one remote/auth
is out of scope. The identity/auth seam is kept clean (a single place where "who
is calling" would be established) so a future Tailscale/reverse-tunnel front can
be added without redesign.

### 2. Request routing (Decisions 1, 5)

- **sid extraction.** The front door carries a small map of opencode's
  session-scoped endpoints and pulls the sid from the path (`/session/<sid>/…`)
  or query (`?session_ids=<sid>`, `?session=<sid>`). This map is a hard
  dependency on opencode's HTTP surface and must be verified against
  `~/projects/opencode` before/while planning.
- **session-scoped request** → internal `/route` lookup → forward bytes to the
  lease-owning serve. **Owner is re-resolved per request boundary.** This is
  safe because the serve-lease invariant keeps the owner stable for the duration
  of a turn: `reassignFromDeadServe` explicitly refuses to migrate a session
  whose lease is still valid — "an unexpired lease proves the serve is still
  alive and actively running the turn; migrating it bumps `owner_generation` and
  yanks the lease out from under the in-flight run"
  (`router.ts:296-315`). Migration happens only after the lease expires at idle
  (`sweep` → dormant) or past the sticky `idleMigrateMs` window.
- **sid-less create** → **spread across the healthy pool** (least-loaded / HRW),
  anchor as fallback. See §9 for the registration-window problem this creates.
- **global / non-session endpoints** (`/global/*`, config, app) → any healthy
  serve; anchor as default. Safe because global state is backed by the shared
  `opencode.db`.

### 3. Long-lived event streams (Decision 3, the hard part)

opencode's attach TUI today subscribes to a **per-process `/global/event`
firehose**, pinned at attach time to whatever serve `/route` named then, and
filters client-side (`users/dev/home.base.nix:122-133`). A per-serve firehose is
ambiguous behind an opaque, K-serve door.

**Change:** attach moves to the **session-scoped `/event?session_ids=<sid>`**
path (the same URL pigeon already advertises in `RouteResult.eventUrl`,
`router.ts:90`). The front door then:

1. holds the client's SSE leg open on the one port;
2. **re-resolves the owner on a timer** (internal `/route`);
3. on **owner drift** — which only happens at **idle**, so nothing is in flight
   and no event is lost — tears down the old upstream leg and re-dials the new
   owner, keeping the client leg open.

This is the front-door-internalized version of the `#15 tui-follow-owner` /
`yl00` logic that currently lives in the `attach-route-resolve` patch. It is
**not** the hard mid-turn byte-splicing case (that was explicitly rejected in
Decision 3): idle-only re-targeting loses no bytes.

### 4. Health / failover (Decision 4)

- **Dead serve:** handled for free by pigeon — `resolveRoute` returns null for
  an unhealthy owner (`isServeHealthy`, `router.ts:49-57`), and
  `placeSession`/`reassignFromDeadServe` re-pick from `listHealthy`. The front
  door just re-resolves.
- **Wedged serve ("alive but frozen"):** the trap. pigeon's health stays green
  because the heartbeat is on a worker thread attesting "worker can write
  sqlite," not "serve can serve" (`.opencode/skills/monitoring-serve-pool`). So
  pigeon still routes to it and the client would hang until the minutely
  **canary** restarts it (~3 min).
  **Front-door posture:** trust pigeon for *selection*, but add a
  **connect/first-byte timeout**. A wedged owner returns a fast retryable
  **`503`** instead of a stall; the client retries and re-resolves onto a
  healthy owner after the canary restart + lease expiry. The front door does
  **not** reinvent failover. Optionally it reports the stall to nudge the health
  poller/canary to react faster.

### 5. Identity & isolation (Decisions 5, 6)

`OPENCODE_SERVE_ID=serve-<i>` and ports `4096–4099` stay **internal and
unchanged** — they remain pigeon's routing key (`seedServes` order →
`assignment.desired_serve_id` → lease CAS; the drift-firewall invariant in
`serve-pool.nix`) and the key the approved session-switcher overlays state on.

The front door is its **own systemd unit** with its **own `MemoryMax`** and a
**canary probe** on its own `/global/health`, independently restartable. This
matches the fleet's per-risk isolation discipline (every risky thing here
already gets its own unit + memory cap + canary) and keeps a data-plane bug from
taking swarm messaging + the routing DB down with it (the reason Decision 6
rejected an in-pigeon forwarder).

## Migration surface (clients rewritten to the one URL)

All of these drop "ask `/route`, parse `apiBase`, dial `409x`" for the single
front-door URL:

- `opencode-launch` / `opencode-send`
- `reset-workspace` (health-probe + recommendation session enrichment)
- `opencode-llm-audit` follower
- `my-podcasts`
- Telegram launch path
- `lgtm-sessions` attach hints (`users/dev/home.base.nix:1198-1223`)
- `opencode attach` itself (drops its own `/route` self-resolve; the front door
  now owns owner-following)

## Impact on the approved session-switcher design (do not break)

`docs/plans/2026-07-12-opencode-session-switcher-{design,plan}.md` is
approved-but-unbuilt. Its **verified facts hold**:

- serve identity keyed on `OPENCODE_SERVE_ID` (not port) — **unchanged**;
- global `opencode.db` as base list — **unchanged**;
- nvim-socket discovery for location — **unchanged**;
- per-instance heartbeated state overlay — **unchanged**.

The **only** coupling that changes is its **attach URL**, and it changes in the
*simplifying* direction: from "call pigeon `/route`, parse `apiBase`, `opencode
attach <apiBase> --session <sid>`" to a fixed **`opencode attach <FRONT_DOOR>
--session <sid>`** — no discovery call, no `apiBase` parsing, no port knowledge.
The switcher's jump-or-attach (§4 of that doc) should be adjusted to use the
front-door URL. **Nothing about serve count / identity scheme / routing here
invalidates its "verified facts."**

## Open items (to resolve in planning, not blockers to review)

1. **create→assignment registration window.** With new-session spreading
   (Decision 5B), the front door sends a sid-less create to (say) least-loaded
   `serve-2`; opencode mints the sid there, but pigeon's routing DB doesn't know
   `sid→serve-2` until the lease CAS records it — a window where an immediate
   follow-up request could mis-route.
   - **Preferred:** front-door-minted sid → `placeSession(sid)` via pigeon (HRW,
     atomic assignment *before* the create) → forward create carrying that sid.
     **Depends on whether opencode accepts a client-supplied session id** —
     verify against `~/projects/opencode`.
   - **Fallback:** parse the create *response* for the minted sid and pin
     `sid→serve` in a short-lived front-door map until the lease lands.
2. **opencode attach event-stream change.** Moving attach from `/global/event`
   to `/event?session_ids=<sid>` is an opencode-client change that must
   coordinate with the existing patch set (`#10 attach-route-resolve`, `#15
   tui-follow-owner` in `users/dev/home.base.nix`). Decide: extend the patch set
   vs. front-door-only shim.
3. **internal `/route` cutover.** Keep pigeon `/route`, bind it localhost-only,
   and remove it from every client caller (it becomes a front-door-private API).
4. **host scope.** cloudbox-first (K=4). Cross-host is trivial at crostini K=1
   and useful at devbox/darwin K=2, but the initial unit + client rewrites can
   land cloudbox-only behind an `isCloudbox` gate, mirroring `session-header.ts`.
5. **sid-extraction map fidelity.** The front door's model of which opencode
   endpoints are session-scoped is a hard contract with opencode's HTTP surface;
   enumerate and test it against the real server, and decide the default for an
   unrecognized endpoint (anchor vs any-healthy).
6. **front-door port choice** and whether `OPENCODE_URL` (today
   `http://127.0.0.1:4096`, `home.base.nix:1076`) is repointed at the front door
   or a new var is introduced.

## Codebases / files to study (for the reviewer and for planning)

- `~/projects/workstation`
  - `users/dev/serve-pool.nix` — pool sizing, port↔serve-id drift firewall.
  - `users/dev/home.devbox.nix:695-880` — serve `@` template unit, memory caps,
    canary, wedge-watcher (the cloudbox analog is
    `hosts/cloudbox/configuration.nix`).
  - `users/dev/home.base.nix` — serve-lease notes (search `serve-lease`,
    `attach-route-resolve`, `tui-follow-owner`, `yl00`, `#15`), the
    `lgtm-sessions` client that parses `/route` (`:1198-1223`), `OPENCODE_URL`
    default (`:1076`).
  - `users/dev/opencode-config.nix` — plugin gating (`session-header.ts` at
    `:352-358`), aigateway/cfp activation (`:930-1010`).
  - `assets/opencode/plugins/session-header.ts` — the egress-plane header
    (explains why ingress can't use it).
  - `.opencode/skills/monitoring-serve-pool/SKILL.md` — the wedge failure mode +
    canary (the reason for fail-fast, Decision 4).
  - `.opencode/skills/resetting-workspace/SKILL.md` — nightly reset,
    pool-restart, recommendation session (a major front-door client).
  - `.opencode/skills/operating-aigateway/SKILL.md` — the egress plane (out of
    scope, but proves the two-plane separation).
  - `docs/plans/2026-07-12-opencode-session-switcher-{design,plan}.md` — the
    downstream dependency whose attach-URL coupling this changes.
- `~/projects/pigeon`
  - `packages/daemon/src/routing/router.ts` — `IngressRouter`: `resolveRoute`,
    `resolveProspectiveRoute`, `placeSession`, `touch`, `sweep`,
    `reassignFromDeadServe` (the lease invariant Decision 3 rests on).
  - `packages/daemon/src/app.ts:586-611` — the `/route` HTTP endpoint contract.
  - `packages/daemon/src/routing/serve-registry.ts`,
    `serve-health-poller.ts`, `client-factory.ts`, `directory-resolver.ts`,
    `rendezvous.ts` — health model, HRW, and how sessions are placed/resolved.
  - `packages/daemon/test/routing/*` — behavioral spec for routing (esp.
    `route-endpoint.test.ts`, `router.test.ts`, `cross-serve-delivery.test.ts`).
- `~/projects/opencode`
  - HTTP server route table (which endpoints are session-scoped; whether create
    accepts a client-supplied sid) — `packages/opencode/src/server/*`.
  - `packages/opencode/src/plugin/index.ts`, `bus/index.ts` — per-instance
    plugin/bus scoping (context for the switcher and event-stream reasoning).
  - the attach client + `attach-route-resolve`/`tui-follow-owner` patches
    referenced in `home.base.nix` — the code moving into the front door.

## Considered & rejected

- **Keep `/route` as a client-facing discovery endpoint** (front door forwards
  but callers still learn `apiBase`) — rejected: leaks pool internals, the exact
  opacity failure this project exists to fix.
- **Dumb reverse proxy** (forward everything to serve-0, or path-prefix
  `/serve-1/…`) — rejected: doesn't collapse addressing for session-targeted
  traffic; callers still need serve knowledge.
- **Forwarder inside the pigeon daemon** — rejected (Decision 6): welds a
  high-throughput HTTP/SSE data plane onto the swarm-messaging + outbox daemon,
  so a forwarder leak/wedge takes messaging + the routing DB down with it. Bad
  blast-radius trade on a box with a documented "alive but frozen" failure mode.
- **Full mid-turn stream-stitching / zero-break migration** (Q2 option A) —
  rejected (Decision 3): unnecessary given the lease invariant forbids mid-turn
  migration; idle-only re-targeting is sufficient and far simpler.
- **Front door owns active failover** (force lease expiry + re-place + retry) —
  rejected (Decision 4): duplicates pigeon's recovery and risks fighting the
  canary + lease CAS.
