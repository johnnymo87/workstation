# Opaque serve-pool reverse proxy — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Companion design:
> `docs/plans/2026-07-12-serve-reverse-proxy-design.md` (revision 2).
>
> **Plan revision 2** — post fable adversarial review of plan rev 1. Folds in
> CRITICAL C1/C2 + MAJOR M1–M9 + MINOR fixes, plus three approved decisions:
> (1) **port the serve canary to cloudbox** as part of this work; (2) the front
> door is **dependency-free** (thin Nix wrapper, no runtime `node_modules`);
> (3) **repoint `OPENCODE_URL` at the front door once Phase 8 lands** (full
> opacity). See "Changes from plan rev 1" at the end.

**Goal:** Put the opencode serve pool (cloudbox K=4, ports 4096–4099) behind a
single opaque `127.0.0.1` front-door port so no client on the box ever addresses
an individual serve.

**Architecture:** A dedicated **dependency-free** `opencode-frontdoor` process
(bun/TypeScript, bun stdlib only) binds one port and is a thin **L7 data plane**:
per request it extracts the session id from opencode's HTTP surface, asks the
**pigeon daemon** (the unchanged **control plane**, via its internal
`GET /route` / `POST /place`) which serve owns the session, promotes prospective/
unrouted sessions to a durable placement, and forwards HTTP/SSE/WebSocket bytes
to the owner. Owner is re-resolved per request boundary (safe: the serve-lease
invariant keeps the owner stable for a whole turn), with per-sid short-TTL
stickiness for the lease-less/draining edge. On any pigeon hiccup it degrades to
the anchor serve (`serve-0`, via `OPENCODE_ANCHOR_URL`), preserving today's
"never worse than pre-pool" behavior. It carries the full isolation kit (own
**system** systemd unit, `MemoryMax`, `LimitNOFILE`, `restartIfChanged=false`,
canary on a native `/healthz`).

**Tech Stack:** bun (native HTTP server + WebSocket/raw-socket + streaming +
`fetch`; **stdlib only, zero runtime deps** so the Nix build is a thin wrapper),
TypeScript, vitest (devDependency only, runs outside the Nix sandbox), Nix
(NixOS **system** units in `hosts/cloudbox/configuration.nix`), bash (client
rewrites + tests).

**Non-goals (from design):** no reinvented failover; no mid-turn migration
handling; no auth today (localhost-only, but a clean identity seam); no
front-door placement *brain* (pigeon HRW places — the front door only *triggers*
`/place`); no change to `OPENCODE_SERVE_ID`/ports/lease machinery.

---

## Ground truth (2026-07-12, live cloudbox serves — re-verify in Phase 0)

- **Deployed line = `v1.17.13-patched`** (`users/dev/home.base.nix:238-243`,
  `upstreamVersion="1.17.13"`; hold at `home.base.nix:246-251`). Verify against
  the **running serves**, NOT `~/projects/opencode` HEAD (a dev branch).
  **⚠️ Pin `opencodePatchedHold` at 1.17.13 for the entire duration of Phases
  0–8** — the `update-opencode-patched.yml` workflow auto-merges a new release
  every 8h when unheld and would shift the deployed HTTP surface mid-execution
  (M1).
- **Authoritative route table:** each serve serves OpenAPI 3.1 at `GET /doc`
  (~478 KB). **But `/doc` OMITS patched/undeclared routes** (e.g.
  `?session_ids=` is accepted but undeclared) — so the route classification MUST
  also read the patch list (`home.base.nix:70-249`), not `/doc` alone (M1).
- **Event stream (C1) works on deployed:** `GET /event?session_ids=<sid>` → 200;
  `GET /session/<sid>/event` → 200; `GET /api/session/<sid>/event` → 000 (audit
  with `curl -N`, MINOR-6). Parallel `/api/*` effect surface has an `after`
  cursor (future C2 upgrade, not v1).
- **PTY is WebSocket:** `GET /pty/{ptyID}/connect`. **bun 1.3.3 (deployed,
  `home.base.nix:499`) has a documented-broken WS *client*** (`home.devbox.nix:129`,
  `:981-983`) — so PTY proxying must be a **raw duplex byte tunnel** (socket
  hijack post-101), not a terminating WebSocket client (M7).
- **pigeon `POST /place`** (`~/projects/pigeon/packages/daemon/src/app.ts`): body
  `{"session_id":"ses_..."}`; 200 `{ok, session_id, serve_id, api_base,
  event_url, owner_generation, instance_uuid, expires_at}`; 400/503/409 errors.
  Idempotent (`ensureRouted`). `GET /route?session_id=<sid>` → `RouteResult`
  (note `prospective:true, expiresAt:0` for unplaced-but-guessable sessions) or
  `404`. **Both accept optional `Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN`**
  (`pigeon/.../routing/README.md`; unset on cloudbox today, but carry the header
  like `oc-pool-attach/default.nix:89-90`) (MINOR-3).
- **Anchor / defaults:** raw anchor `http://127.0.0.1:4096`; pigeon
  `http://127.0.0.1:4731` (`home.base.nix:1076,1081`). Hardcoded anchor lives at
  `hosts/cloudbox/configuration.nix:485` (pigeon-daemon env) and `:530`
  (lgtm-run) — **NOT** `:511,556` (rev-1 citation was wrong, MINOR-1).
- **No serve canary on cloudbox today** — canary + wedge-watcher are
  **devbox-only user units** (`home.devbox.nix:868+`, `:840+`); cloudbox serves
  + pigeon are **system** units. So the "503 → wait ~3 min for canary" story is
  false on cloudbox until we port it (M4).

---

## Phase 0 — Deployed-line audit & de-risking (no product code)

Output: a committed findings note the later phases cite. This phase now also
front-loads the two premise-checks that plan rev 1 deferred to the end (M6, M7).

### Task 0.1: Snapshot route table + probe matrix (live)
**Files:** `docs/investigations/2026-07-12-frontdoor-route-audit.md`;
`pkgs/opencode-frontdoor/audit/probe.sh`.
- `curl -s http://127.0.0.1:4096/doc > /tmp/frontdoor-openapi.json` (record
  version/size). `probe.sh` uses `curl -N` with separate connect/read phases so
  `000` results are disambiguated (refused vs timeout-before-headers, MINOR-6),
  probing the event/session/pty/global endpoints for a live sid.
- Commit `docs(frontdoor): audit deployed v1.17.13 route table`.

### Task 0.2: Classify every route (two sources: /doc + patch list)
**Files:** findings note; `pkgs/opencode-frontdoor/src/routes.classification.ts`
(data only).
Classes: `session-path` | `session-query` | `session-event` | `global-event`
(**new, M2** — per-process firehose; policy below) | `create` | `pty-ws` |
`global-ro` | `global-sideeffect` | `unrecognized`.
- Derive from `/doc` **and** the patch list (undeclared routes like
  `?session_ids=` won't appear in `/doc`, M1). Record each route + class + source.
- **The completeness tripwire is OPERATIONAL, not a hermetic unit test** (M1): a
  `probe.sh`/`/doc`-diff run at the Phase 6 gate and at each Phase 7 task; a
  committed snapshot alone would never change on a serve bump and is worthless.
- Commit `feat(frontdoor): classify deployed routes (doc + patch list)`.

### Task 0.3: Decide event-stream + `/global/event` contracts
- Confirm `/event?session_ids=<sid>` is truly session-scoped (attach, trigger a
  turn on that sid → events arrive; trigger on another sid → they don't). Record
  whether events carry `id:` (replay?).
- **`/global/event` policy (M2):** it's a per-process firehose — bucketing it as
  `global-ro`→anchor silently reintroduces the yl00 missed-events bug (sessions
  on serve-1..3 emit on other buses; patch #15, `home.base.nix:122-131`).
  Decide: pre-Phase-8, **pass to anchor with a loud "legacy firehose" log**, or
  **deny (410)**. Record the decision.
- v1 event decision: `/event?session_ids=<sid>` + drop-leg-on-drift.
- Commit `docs(frontdoor): event-stream + global-event contracts`.

### Task 0.4: Confirm create→/place choreography (manual)
Reproduce `oc-pool-attach`'s flow live: `POST /session` (with
`x-opencode-directory`) → parse `.id` → `POST /place` → `GET /route` resolves.
Record exact headers/bodies. Spec for Phase 4. Commit
`docs(frontdoor): confirm create->place choreography`.

### Task 0.5: Inventory TUI event diet + PTY usage
From `johnnymo87/opencode-patched` @ the pinned rev (NOT `~/projects/opencode`) +
a live attach: which non-session events the TUI consumes from `/global/event`
(e.g. `server.instance.disposed` #14, `server.connected`); whether the TUI uses
PTY. Feeds Phase 8 + Phase 5. Commit `docs(frontdoor): TUI event diet + PTY`.

### Task 0.6: **Premise check — does the deployed TUI re-bootstrap on a dropped SSE leg?** (M6)
This is design open-item 3 and the *premise* of Phase 2 — verify it NOW, with no
front door. Attach a deployed TUI to a live session; kill its SSE socket
mid-stream (a one-off local `socat`/`nc` relay in front of one serve, or an
`ss`-assisted socket kill); observe whether `runSseAttempt` reconnect +
re-bootstrap restores a consistent TUI (patch #10/#15, `home.base.nix:122-140`).
- **If NO:** Phase 2's drop-leg design is invalid — STOP and escalate to redesign
  (cursor-resume via the `/api` `after` param, or full stream-stitching).
- Commit `docs(frontdoor): verify TUI reconnect-heals-gap premise`.

### Task 0.7: **Premise check — bun 1.3.3 WS client against a live serve** (M7)
10-minute probe: bun 1.3.3 `WebSocket` client → live `/pty/<id>/connect`
handshake. Record pass/fail. If fail (expected per `home.devbox.nix:129`), Phase
5 uses a raw duplex byte tunnel. Commit `docs(frontdoor): bun WS client probe`.

### Task 0.8: **Packaging decision — dependency-free** (M3, approved)
Record: the front door imports **only bun stdlib** (HTTP/fetch/streams/sockets);
vitest is a devDependency. The Nix "build" copies sources to the store and wraps
`bun run src/server.ts` — **no runtime `node_modules`**, mirroring the
self-compact bundle precedent (`opencode-config.nix:432-440`), NOT the
run-from-checkout pigeon pattern. Task 1.1 must honor "zero runtime deps."
Commit `docs(frontdoor): packaging = dependency-free bun + thin nix wrapper`.

**Phase 0 gate:** classes assigned (both sources); event + global-event +
create→place contracts recorded; **Task 0.6 premise PASSES**; WS probe recorded;
packaging fixed. Only then start Phase 1.

---

## Phase 1 — Forwarder core (bun, dependency-free)

New package `pkgs/opencode-frontdoor`. Pure logic + a locally-runnable server,
fully unit-tested. No Nix/systemd wiring yet.

### Task 1.1: Scaffold (zero runtime deps)
`package.json` (type module; **only** vitest under devDependencies),
`tsconfig.json`, `vitest.config.ts`, `src/config.ts`:
```ts
export interface FrontdoorConfig {
  port: number;              // FRONTDOOR_PORT
  pigeonUrl: string;         // PIGEON_DAEMON_URL  (default http://127.0.0.1:4731)
  anchorUrl: string;         // OPENCODE_ANCHOR_URL (default http://127.0.0.1:4096)
  pigeonAuthToken?: string;  // PIGEON_DAEMON_AUTH_TOKEN (optional Bearer)
  routeTimeoutMs: number;    // default 3000
  cheapFirstByteMs: number;  // default 5000
  stickyTtlMs: number;       // Phase 3 (default 30000)
}
```
TDD defaults/overrides. Commit `feat(frontdoor): scaffold (zero runtime deps)`.

### Task 1.2: sid extraction (TDD)
`src/sid.ts` + test. Path (`/session/{sessionID}/…`), query
(`session_ids`, `session`), create → null, malformed → null. **Multi-value
`session_ids` policy (MINOR-2):** single → route; multiple-same-owner → route;
multiple-mixed-owner → 400 (or anchor) — test all three. Commit
`feat(frontdoor): session-id extraction`.

### Task 1.3: pigeon resolver with anchor degrade (TDD)
`src/resolve.ts`. `resolveOwner(sid) → {url, prospective, degraded}`: GET
`/route` (bounded by `routeTimeoutMs`, optional Bearer); 200 → apiBase (+ carry
`prospective`); 404/timeout/malformed → `{url: anchorUrl, degraded:true}`.
Accept both `.apiBase` and `.api_base`. TDD each branch. Commit
`feat(frontdoor): pigeon resolver with anchor degrade`.

### Task 1.4: **promote prospective/unrouted → placed** (TDD) — fixes C1
`src/place.ts`. When `resolveOwner` returns `prospective:true` (an HRW guess that
flaps on health blips — verified live) or a 404 for a sid a follow-up confirms
exists, issue `POST /place {session_id}` (idempotent `ensureRouted`) and use its
`api_base`. This is what the shipped clients do (`oc-auto-attach:342-346`) and is
REQUIRED before Phase 7 may drop client `/place` (C1).
TDD: prospective → place-then-forward; placed → forward directly; place 503 →
degrade to anchor + log. Commit `feat(frontdoor): promote prospective to placed`.

### Task 1.5: request dispatcher (TDD)
`src/dispatch.ts`. (method,path) → class → `{action,target}`. Branches:
`resolve-owner` (→1.3/1.4), `create-place` (stub), `pty-ws` (stub),
`global-event` (Phase 0.3 policy), `global-ro` (anchor), `global-sideeffect`
(stub), `unrecognized` (404-loud). Commit `feat(frontdoor): dispatcher`.

### Task 1.6: observability — structured request log (TDD) — M8
`src/log.ts`, wired in Phase 1.7. One line per request: `{class, sid, target,
prospective, degraded, status, durationMs}` + a running `degraded_to_anchor`
counter surfaced on `/healthz` (Phase 3.3). Without this a silently-degraded
front door (pigeon flapping) is invisible while the anchor absorbs everything.
Commit `feat(frontdoor): structured request logging`.

### Task 1.7: HTTP forwarder + integration harness (TDD) — with auth seam
`src/proxy.ts`, `src/server.ts`, `test/integration.test.ts`. Fake serve-0/serve-1
+ fake pigeon; assert sid routes to owner, unknown-sid degrades to anchor, status/
headers/body pass through (hop-by-hop stripped). **Auth seam (MINOR-7):** all
client-identity handling flows through one middleware point (`src/identity.ts`,
no-op today) so a future remote front adds auth in one place.
**No-retry-after-send guard** (design MINOR): assert no internal retry once bytes
are forwarded. Commit `feat(frontdoor): HTTP forwarder + integration harness`.

> **Integration-test honesty (review angle 3):** fake serves cannot prove SSE
> framing, WS upgrade, or "`POST /message` returns at turn-end." Those are
> covered by the **through-front-door live probe matrix** at the Phase 6 gate
> (Task 6.5), not by unit tests. State this in the test files.

---

## Phase 2 — Event streams (SSE proxy + drop-leg-on-drift)

Depends on Task 0.6 PASSING.

### Task 2.1: SSE pass-through (TDD)
`src/sse.ts`. Unbuffered `text/event-stream`, survives the 10 s heartbeat, closes
on upstream close. Commit `feat(frontdoor): SSE pass-through`.

### Task 2.2: drift detect → drop client leg (TDD)
Per-stream confirm-twice re-resolve timer; on drift, **close the client leg** (no
silent re-dial — design C2). Assert the client connection ends cleanly and is
NOT re-dialed. Commit `feat(frontdoor): drop client SSE leg on owner drift`.

---

## Phase 3 — Health / failover + stickiness

### Task 3.1: endpoint-class first-byte timeout (TDD)
`src/timeouts.ts`. Cheap GET / SSE-handshake: `cheapFirstByteMs`
**time-to-response-headers** timeout → 503 (SSE = headers arrive immediately even
if first event doesn't, MINOR-5). Turn POSTs
(`…/message|prompt|compact|shell|command|summarize`, `init`): **no** first-byte
timeout. Commit `feat(frontdoor): endpoint-class first-byte timeouts`.

### Task 3.2: wedge health-probe for turn POSTs (TDD)
On a stalled turn POST, probe the target's `/global/health` directly; 503 only on
probe failure. Commit `feat(frontdoor): wedge detection via target health-probe`.

### Task 3.3: native `/healthz` (TDD)
`src/healthz.ts`. 200 iff own loop live AND (pigeon reachable OR anchor
reachable); report `degraded` + the anchor-degrade counter (1.6). Never proxies.
Commit `feat(frontdoor): native /healthz`.

### Task 3.4: **per-sid short-TTL stickiness** (TDD) — fixes M5
`src/sticky.ts`. Map `{sid → lastForwardedServe, expiry=stickyTtlMs}` seeded on
turn-starting POSTs, overriding `/route` until it disagrees twice. Prevents
`abort`/`permissionRespond` no-op'ing on a different serve during a lease-less
fail-open turn (design §8 — user can't stop a runaway turn otherwise).
TDD the **abort-follows-the-turn** case explicitly. Commit
`feat(frontdoor): per-sid short-TTL stickiness`.

---

## Phase 4 — New-session creation (create → /place → respond)

### Task 4.1: create-place choreography (TDD + integration)
`POST /session` → forward to anchor → parse `.id` → `POST /place` → return create
response **only after** place succeeds (no window). Place fail → still return the
create response, degrade follow-ups to anchor, log loudly. The front door does
**not** choose serves (M1 — pigeon HRW). Concurrent-create + serve-dies-mid-
choreography tests. Commit `feat(frontdoor): create->place (no registration window)`.

---

## Phase 5 — WebSocket/PTY + /global/* policies

### Task 5.1: PTY policy — raw duplex tunnel (Task 0.7-driven)
If the TUI uses PTY: proxy the upgrade as a **raw duplex byte tunnel** (hijack the
socket after the 101, pipe both directions) with a `ptyID→serve` pin
(create-on-serve then connect-same-serve) — sidesteps the broken bun WS client
(M7) and WS-protocol fidelity. Else: 501 + log, documented out-of-scope. TDD the
pin; smoke-test the tunnel at the Phase 6 gate. Commit `feat(frontdoor): PTY raw tunnel policy`.

### Task 5.2: /global side-effect + unrecognized (TDD)
`/global/dispose|upgrade` → deny (405 + log; infra ops target serves directly).
Unrecognized → 404-loud. `/global/event` → the Task 0.3 decision. Commit
`feat(frontdoor): global-sideeffect + unrecognized policies`.

---

## Phase 6 — Nix packaging + **system** units + canary (cloudbox)

### Task 6.1: dependency-free Nix package (M3)
`pkgs/opencode-frontdoor/default.nix`: copy sources to store, wrap
`bun run src/server.ts` (no runtime `node_modules`). `test.sh` runs vitest
outside the sandbox. Register in the pkgs set. Commit `feat(frontdoor): nix package`.

### Task 6.2: **system** systemd unit + isolation kit (M4, C2, M8)
In **`hosts/cloudbox/configuration.nix`** (system unit — cloudbox serves/pigeon
are system units; a user unit can't `After=` them, the DM5-2 trap
`home.devbox.nix:724-726`):
- `127.0.0.1:${FRONTDOOR_PORT}`; env `PIGEON_DAEMON_URL`, `OPENCODE_ANCHOR_URL`,
  optional `PIGEON_DAEMON_AUTH_TOKEN`.
- **`restartIfChanged = false`** (C2 — do NOT bounce on routine rebuilds;
  document the explicit restart procedure, mirroring serve DM5-7
  `configuration.nix:603-606`).
- `MemoryMax` ≈ **1.5G** (stream-holder, not a serve — drop "like a serve",
  MINOR-4); `Restart=always`; `RestartSec=10`; `TimeoutStopSec` sized to allow a
  **bounded stream drain** > 15 s (C2); `OOMScoreAdjust`.
- **`LimitNOFILE`** high (M8 — the door doubles every connection; #14 saw ~900
  conns from 16 TUIs; 2× that blows the 1024 default → total outage).
- `After=`/`Wants=` pigeon + serve pool (soft — it degrades if they're down).
- Commit `feat(frontdoor): system systemd unit + isolation kit`.

### Task 6.3: **port the serve canary to cloudbox** (M4, approved)
Cloudbox has no serve canary today. Port `opencode-serve-canary` (+ the
wedge-watcher if warranted) from `home.devbox.nix:868+` as **cloudbox system
units** in `configuration.nix`; update `.opencode/skills/monitoring-serve-pool/SKILL.md`
(its "cloudbox parity tracked in beads" gap). This makes the front door's "503 →
canary restarts wedged serve in ~3 min" story TRUE on cloudbox. Commit
`feat(serve-pool): port serve canary to cloudbox`.

### Task 6.4: front-door canary on /healthz
Minutely `GET /healthz` (3 s); 3 consecutive fails → forensics dump + `systemctl
restart opencode-frontdoor`. System unit. Commit `feat(frontdoor): liveness canary`.

### Task 6.5: **deploy + through-front-door gate** (M2)
Deploy (`sudo nixos-rebuild switch --flake .#cloudbox`). Gate BEFORE any client
cutover:
- `/healthz` UP;
- **run `probe.sh` THROUGH the front door and diff against direct-to-serve** — the
  gate must exercise the SSE path, not just bootstrap (rev-1's "manual attach
  works" passed while streaming *around* the door, M2). Specifically:
  `curl -N "$FRONTDOOR/event?session_ids=<sid>"` while triggering a turn on that
  sid; confirm events arrive via the door;
- PTY tunnel smoke-test (if applicable).
Commit `docs(frontdoor): phase-6 deploy + through-door gate results`.

---

## Phase 7 — Client cutover + infra-plane exemption

Incremental; one client per task; each revertable; anchor-degrade intact. **C1
gate: Task 1.4 (promote prospective→placed) MUST be live before 7.3/7.4 drop
client `/place`.**

### Task 7.1: introduce `OPENCODE_ANCHOR_URL` + `FRONTDOOR_URL` (M9)
`users/dev/home.base.nix`: add `OPENCODE_ANCHOR_URL` (raw anchor, for degrade +
infra) and `FRONTDOOR_URL`. **Keep `OPENCODE_URL` unchanged for now** (repointed
in Phase 9). Fix the real hardcodes at `configuration.nix:485,530` (MINOR-1).
Commit `feat(frontdoor): introduce OPENCODE_ANCHOR_URL + FRONTDOOR_URL`.

### Tasks 7.2–7.8: migrate each client (one commit + `test.sh` each)
Replace "`/route` → parse → dial `409x`" with "dial `FRONTDOOR_URL`"; keep
anchor fallback via `OPENCODE_ANCHOR_URL`; carry optional Bearer.
- 7.2 `pkgs/oc-pool-attach` (also its `ses_poolprobe` reachability idiom → a
  front-door `/healthz` equivalent; keep `--strict` selfhost bail on door-down).
- 7.3 `pkgs/oc-auto-attach` (drops `/place` — **only after** Task 1.4).
- 7.4 `pkgs/opencode-launch` / `opencode-send` (drops `/place` — after Task 1.4).
- 7.5 `lgtm-sessions` inline (`home.base.nix:1198-1223`) + retarget
  `users/dev/test-pool-route-clients.sh`.
- 7.6 `opencode-llm-audit`, `my-podcasts`, Telegram launch path.
- 7.7 `docs/plans/serve-distribution-probe.sh` + reset-workspace enrichment.
- 7.8 **pigeon-daemon's own `OPENCODE_URL`** (`configuration.nix:485`) — the
  reviewer flagged it was missing from rev 1's list (M9).

### Task 7.9: infra-plane exemption (documented + guarded)
Canary, wedge-watcher, reset-workspace per-serve probes **keep dialing
`4096–409x` directly** (routing them through the door destroys wedge detection).
Document in the two skills + unit comments; add a grep-guard test if practical.
Commit `docs(frontdoor): infra-plane direct-access exemption`.

---

## Phase 8 — opencode-patched: attach → session-scoped event stream (own mini-plan)

**M6: this is a cross-repo epic, not one task.** Write it as its own plan in the
`opencode-patched` repo. Scope: move attach from `/global/event` firehose to
`/event?session_ids=<sid>`; preserve the non-session events Task 0.5 flagged
(re-subscribe or synthesize); remove the TUI's own `/route` self-resolve (the
door owns owner-following via drop-leg); add the Phase 0.6/tripwire test;
**jittered reconnect** so ~16 TUIs don't thundering-herd on a door restart
(design change #10, M8). **Rollback = hold to the previous patched release** (the
`opencodePatchedHold` mechanism). Coordinate with patches #7/#10/#11/#14/#15 (the
most incident-dense surface in the repo).

**Gate:** a migrated session's attach TUI survives an idle serve migration
(drop-leg → reconnect → re-bootstrap) with no manual intervention.

---

## Phase 9 — Full opacity: repoint `OPENCODE_URL` + internalize pigeon `/route` (M9)

Only after Phase 8 (the TUI no longer self-resolves):
### Task 9.1: repoint `OPENCODE_URL` → `FRONTDOOR_URL` (approved decision 3)
Now that no client self-resolves, the ambient default is safe to point at the
door. Keep `OPENCODE_ANCHOR_URL` for degrade/infra. Commit
`feat(frontdoor): repoint OPENCODE_URL at the front door`.
### Task 9.2: internalize pigeon `/route`
Bind pigeon `/route` (and `/place`) to localhost / off the client contract (it
becomes front-door-private). Verify no remaining client calls it. Commit
`feat(frontdoor): make pigeon /route internal`.

---

## Rollout / sequencing summary (amended per review)

Phase 0 (audit + **premise checks 0.6/0.7** + packaging 0.8; pin the hold) →
Phases 1–5 pure package work (incl. **1.4 promote-to-placed**, **3.4 stickiness**,
**1.6 observability**) → Phase 6 **system units, `restartIfChanged=false`,
`LimitNOFILE`, ported serve canary, through-door gate** → Phase 7 per-client
cutover (client `/place` retained until 1.4 is live) → Phase 8 attach move (own
mini-plan) → Phase 9 `OPENCODE_URL` repoint + pigeon `/route` internalization.

**Session-switcher:** update its plan's attach URL to `FRONTDOOR_URL` +
`--session <sid>` (simplification; no "verified facts" change).

## Risks (watch during execution)
- Total-outage SPOF — isolation kit (system unit + `MemoryMax` + `LimitNOFILE` +
  `restartIfChanged=false` + `/healthz` canary + anchor-degrade + observability)
  is mandatory.
- `/event?session_ids=` is a hard dep on patch #7 — the hold-pin + tripwire guard.
- If Task 0.6 fails, Phase 2's drop-leg premise is wrong — redesign before building.
- Dual `/api/*` surface may become default in a future bump — the operational
  probe-diff (0.2) forces re-audit; the hold-pin prevents drift mid-execution.

## Changes from plan rev 1 (for the record)
1. **C1:** new Task 1.4 promotes prospective/unrouted sessions to placed; client
   `/place` retained in Phase 7 until it's live.
2. **C2:** Task 6.2 adds `restartIfChanged=false` + drain policy + jittered
   reconnect (Phase 8) — rebuilds no longer sever all streams.
3. **M1:** pin `opencodePatchedHold` for the duration; classify from `/doc` **and**
   the patch list; the tripwire is an operational probe-diff, not a hermetic test.
4. **M2:** new `global-event` routing class + policy; Phase 6 gate is a
   through-front-door SSE probe matrix (not "manual attach works").
5. **M3:** packaging fixed to **dependency-free bun + thin Nix wrapper** (0.8, 6.1).
6. **M4:** units are **system** units in `configuration.nix`; **port the serve
   canary to cloudbox** (Task 6.3).
7. **M5:** new Task 3.4 short-TTL stickiness (abort-follows-turn).
8. **M6:** premise check pulled into Phase 0 (Task 0.6); Phase 8 is its own
   mini-plan with rollback.
9. **M7:** bun-WS probe (0.7); PTY via raw duplex tunnel (5.1).
10. **M8:** `LimitNOFILE`, structured request log + degrade counter (1.6), jittered
    reconnect (8).
11. **M9:** `OPENCODE_ANCHOR_URL` split; pigeon-daemon added to cutover (7.8);
    Phase 9 repoints `OPENCODE_URL` + internalizes pigeon `/route`.
12. **MINOR:** fixed citations (`:485,530`); multi-value `session_ids` policy;
    optional pigeon Bearer; MemoryMax wording; SSE first-byte semantics; `curl -N`
    probe; auth-seam middleware.
