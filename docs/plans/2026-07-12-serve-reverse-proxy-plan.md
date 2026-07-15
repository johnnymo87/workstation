# Opaque serve-pool reverse proxy — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Companion design:
> `docs/plans/2026-07-12-serve-reverse-proxy-design.md` (revision 2).

**Goal:** Put the opencode serve pool (cloudbox K=4, ports 4096–4099) behind a
single opaque `127.0.0.1` front-door port so no client on the box ever addresses
an individual serve.

**Architecture:** A dedicated `opencode-frontdoor` process (bun/TypeScript)
binds one port and is a thin **L7 data plane**: per request it extracts the
session id from opencode's HTTP surface, asks the **pigeon daemon** (the
unchanged **control plane**, via its now-internal `GET /route` / `POST /place`)
which serve owns the session, and forwards HTTP/SSE/WebSocket bytes to that
serve. Owner is re-resolved per request boundary (safe: the serve-lease
invariant keeps the owner stable for a whole turn). On any pigeon hiccup it
degrades to the anchor serve (`serve-0`), preserving today's "never worse than
pre-pool" behavior. It carries the full isolation kit (own systemd unit,
`MemoryMax`, canary on a native `/healthz`).

**Tech Stack:** bun (native HTTP server + WebSocket + streaming + `fetch`
upstream), TypeScript, vitest (matches pigeon), Nix (home-manager/NixOS packaging
+ systemd unit, `isCloudbox`-gated), bash (client rewrites + tests).

**Non-goals (from design):** no reinvented failover; no mid-turn migration
handling; no auth (localhost-only); no front-door placement brain (pigeon HRW
places); no change to `OPENCODE_SERVE_ID`/ports/lease machinery.

---

## Ground truth already gathered (2026-07-12, live cloudbox serves)

Record these so the executor does not re-derive them, but **re-verify in Phase 0**
(serves may have been bumped):

- **Deployed line = `v1.17.13-patched`** (`users/dev/home.base.nix:70`). Verify
  against the *running serves*, NOT `~/projects/opencode` HEAD (a dev branch).
- **Authoritative route table:** every serve serves its OpenAPI 3.1 spec at
  `GET /doc` (also `/openapi.json`, `/spec`). ~478 KB. This is the audit source.
- **Event stream (C1) works on deployed:** `GET /event?session_ids=<sid>` → 200
  (param accepted though undeclared in `/doc`); `GET /session/<sid>/event` → 200.
  A parallel `/api/*` surface exists (`GET /api/session/{sessionID}/event` with
  an `after` cursor param) — audit but do not rely on.
- **PTY is WebSocket:** `GET /pty/{ptyID}/connect` (+ `/api/pty/...`). Real.
- **pigeon `POST /place`** (`~/projects/pigeon/packages/daemon/src/app.ts`):
  request `{"session_id":"ses_..."}`; success 200
  `{ ok, session_id, serve_id, api_base, event_url, owner_generation, instance_uuid, expires_at }`;
  `400` invalid sid, `503` no-healthy-serve / routing-not-configured,
  `409` lease-contended. `GET /route?session_id=<sid>` → same `RouteResult`
  shape or `404 {"error":"session not routed"}`; sid regex `^ses_[A-Za-z0-9_-]+$`.
- **Anchor / defaults:** `OPENCODE_URL=http://127.0.0.1:4096`,
  `PIGEON_DAEMON_URL=http://127.0.0.1:4731` (`home.base.nix:1076,1081`).

---

## Phase 0 — Deployed-line audit & de-risking decisions

**Rationale:** the design's §10 open items must be answered against the deployed
line before writing routing code. Output: a committed findings note the later
phases cite. No product code yet.

### Task 0.1: Snapshot the deployed route table + probe matrix

**Files:**
- Create: `docs/investigations/2026-07-12-frontdoor-route-audit.md`
- Create: `pkgs/opencode-frontdoor/audit/probe.sh` (repeatable probe script)

**Steps:**
1. `curl -s http://127.0.0.1:4096/doc > /tmp/frontdoor-openapi.json`; record
   version + byte size.
2. Write `probe.sh` that, for a live sid (`GET /session?limit=1`), probes:
   `/event?session_ids=<sid>`, `/session/<sid>/event`,
   `/api/session/<sid>/event`, `/global/event`, `/session/<sid>` (GET),
   `/pty` (GET), and records HTTP status + whether the body streams.
3. Run it; paste the matrix into the findings note.
4. Commit: `docs(frontdoor): audit deployed v1.17.13 route table`.

### Task 0.2: Classify every path into a routing class

**Files:** append to the findings note; create
`pkgs/opencode-frontdoor/src/routes.classification.ts` (data-only, no logic yet).

Classify each `/doc` path into exactly one class (this table drives §2/§6 of the
design and Task 1.4):

| Class | Meaning | Routing |
|---|---|---|
| `session-path` | sid in path (`/session/{sessionID}/…`) | resolve owner |
| `session-query` | sid in query (`/event?session_ids=`, `?session=`) | resolve owner |
| `session-event` | long-lived per-session SSE | resolve owner + drift-drop (Phase 2) |
| `create` | mints a new session (`POST /session`, `POST /api/session`) | create→place (Phase 4) |
| `pty-ws` | WebSocket keyed by `ptyID` | Phase 5 policy |
| `global-ro` | read-only, DB-backed (`/global/health`, `/config`, `/find`, …) | any healthy → anchor default |
| `global-sideeffect` | per-process mutation (`/global/dispose`, `/global/upgrade`) | Phase 5 policy (deny/anchor/fan-out) |
| `unrecognized` | anything not enumerated | 404-loud + log (shakeout) |

Step: for each `/doc` path, assert its class in a vitest snapshot test so a
future opencode bump that adds a path fails the test (forces re-classification).

Commit: `feat(frontdoor): classify deployed routes into routing classes`.

### Task 0.3: Decide the event-stream contract

Answer in the findings note, with probe evidence:
1. Confirm `/event?session_ids=<sid>` streams session-scoped events (attach one,
   trigger a turn on that sid, confirm events arrive; trigger on a *different*
   sid, confirm they do NOT). Record whether events carry an `id:` (replay?).
2. Evaluate the `/api/session/{sessionID}/event` `after` cursor: does it replay
   missed events? If yes, note it as a *future* C2 upgrade (cursor-resume instead
   of drop-leg) but **do not adopt for v1** — drop-leg is the v1 decision.
3. Decision recorded: **v1 uses `/event?session_ids=<sid>` + drop-leg-on-drift.**

Commit: `docs(frontdoor): decide event-stream contract (session_ids + drop-leg)`.

### Task 0.4: Confirm create → /place choreography end-to-end (manual)

Manually reproduce the shipped `oc-pool-attach` flow against live serves:
`POST /session` (with `x-opencode-directory`) → parse `.id` → `POST /place
{session_id}` → `GET /route?session_id=<sid>` resolves. Record the exact request
headers/bodies and responses in the findings note. This is the spec for Phase 4.

Commit: `docs(frontdoor): confirm create->place choreography`.

### Task 0.5: Inventory the TUI event diet + PTY usage

From the deployed opencode-patched source (clone `johnnymo87/opencode-patched`
at the pinned rev; do NOT use `~/projects/opencode`) + a live attach:
1. Which non-session event types does the attach TUI consume from `/global/event`
   today (e.g. `server.instance.disposed`, `server.connected`)? Moving to
   `/event?session_ids=` must not starve these — note which must be preserved or
   synthesized (feeds Phase 8).
2. Does the deployed TUI use PTY (`/pty/*`)? Determines Phase 5 (proxy WS vs
   block PTY).

Commit: `docs(frontdoor): inventory TUI event diet + PTY usage`.

### Task 0.6: opencode-patched `/event?session_ids=` tripwire test

**Files (in the `opencode-patched` repo, separate PR):**
- A CI test asserting `GET /event?session_ids=ses_x` is accepted (not 400) and
  is session-scoped.

This makes the front door's hard dependency (design C1) fail loudly if the patch
is ever dropped on an upstream roll-forward. Cross-repo: track as a bead; link
from the findings note.

**Phase 0 gate:** all classes assigned, event contract decided, create→place
confirmed, TUI event diet known. Only then start Phase 1.

---

## Phase 1 — Forwarder core (scaffold + sid extraction + resolve + degrade + basic HTTP proxy)

New package `pkgs/opencode-frontdoor` (bun + vitest). No systemd/Nix wiring yet —
pure logic + a locally-runnable server, fully unit-tested.

### Task 1.1: Scaffold the package

**Files:**
- Create: `pkgs/opencode-frontdoor/package.json` (bun, vitest, type: module)
- Create: `pkgs/opencode-frontdoor/tsconfig.json`
- Create: `pkgs/opencode-frontdoor/vitest.config.ts`
- Create: `pkgs/opencode-frontdoor/src/config.ts`

**Step 1 — `config.ts` (env-driven, matches existing conventions):**
```ts
export interface FrontdoorConfig {
  port: number;              // FRONTDOOR_PORT
  pigeonUrl: string;         // PIGEON_DAEMON_URL, default http://127.0.0.1:4731
  anchorUrl: string;         // OPENCODE_URL,       default http://127.0.0.1:4096
  routeTimeoutMs: number;    // internal /route lookup budget, default 3000
  cheapFirstByteMs: number;  // Phase 3, default 5000
}
export function loadConfig(env = process.env): FrontdoorConfig { /* parse + defaults */ }
```
**Step 2:** vitest test for defaults + overrides. Run `bun run test` → PASS.
**Step 3:** Commit `feat(frontdoor): scaffold package + config`.

### Task 1.2: sid extraction (TDD)

**Files:** `src/sid.ts`, `test/sid.test.ts`.

**Step 1 — failing test** (drive off the Phase 0 classification):
```ts
import { extractSessionId } from "../src/sid";
test("sid in path", () => {
  expect(extractSessionId("GET", "/session/ses_abc/message")).toBe("ses_abc");
});
test("sid in session_ids query", () => {
  expect(extractSessionId("GET", "/event?session_ids=ses_abc")).toBe("ses_abc");
});
test("no sid on create", () => {
  expect(extractSessionId("POST", "/session")).toBeNull();
});
test("rejects malformed sid", () => {
  expect(extractSessionId("GET", "/session/not-a-sid/x")).toBeNull();
});
```
**Step 2:** run → FAIL. **Step 3:** implement using the `^ses_[A-Za-z0-9_-]+$`
regex + the Phase 0 route map (port the logic of opencode's
`getWorkspaceRouteSessionID`, verified against `/doc`). **Step 4:** PASS.
**Step 5:** Commit `feat(frontdoor): session-id extraction`.

### Task 1.3: pigeon resolver core with anchor degrade (TDD)

**Files:** `src/resolve.ts`, `test/resolve.test.ts`.

Mirrors the shell `parse_serve_url` + `pigeon_reachable` idioms, unified.

**Step 1 — failing tests** (mock `fetch`):
```ts
// GET /route 200 -> apiBase
// GET /route 404 -> anchor (degrade, "never worse than pre-pool")
// pigeon unreachable / timeout -> anchor
// malformed body -> anchor
// accepts both .apiBase (/route) and .api_base (/place)
```
**Step 2:** FAIL. **Step 3:** implement `resolveOwner(sid): Promise<{url, degraded}>`
(GET `${pigeonUrl}/route?session_id=${sid}`, bounded by `routeTimeoutMs`, any
failure → `{url: anchorUrl, degraded: true}`). **Step 4:** PASS. **Step 5:**
Commit `feat(frontdoor): pigeon resolver with anchor degrade`.

### Task 1.4: request dispatcher — class → action (TDD)

**Files:** `src/dispatch.ts`, `test/dispatch.test.ts`.

Given (method, path) → classify (Task 0.2 table) → decide `{action, targetUrl}`:
`resolve-owner` | `create-place` (stub) | `pty-ws` (stub) | `global-ro`
(anchor) | `global-sideeffect` (stub) | `unrecognized` (404).
TDD each branch. Commit `feat(frontdoor): request dispatcher`.

### Task 1.5: basic HTTP forwarder (non-stream) (TDD + integration)

**Files:** `src/proxy.ts`, `src/server.ts`, `test/proxy.test.ts`,
`test/integration.test.ts`.

**Step 1 — integration test:** spin up two fake bun servers (fake "serve-0" +
"serve-1") and a fake pigeon that routes sid→serve-1; start the front door
pointed at them; assert `GET /session/ses_x/message` reaches serve-1 and the
response body + status + headers pass through; assert an unknown-sid GET degrades
to the anchor (serve-0).
**Step 2:** FAIL. **Step 3:** implement `Bun.serve({ fetch })` → dispatch →
resolve → `fetch(target)` → stream response back (hop-by-hop headers stripped;
method/body/query preserved). **Step 4:** PASS. **Step 5:** Commit
`feat(frontdoor): basic HTTP forwarder + integration harness`.

> **Guard (design MINOR):** never internally retry a request after any bytes were
> forwarded upstream (a replayed `POST …/message` double-starts a turn). Add a
> test asserting no-retry-after-send.

---

## Phase 2 — Long-lived event streams (SSE proxy + drift-drop)

### Task 2.1: SSE pass-through (TDD)

**Files:** `src/sse.ts`, `test/sse.test.ts`.

Fake serve emits an SSE stream; assert the front door forwards chunks unbuffered
(no compression, no buffering — `Content-Type: text/event-stream`), keeps the
connection open past the 10 s heartbeat, and closes when upstream closes.
Commit `feat(frontdoor): SSE pass-through`.

### Task 2.2: owner-drift detection → drop client leg (TDD)

**Files:** extend `src/sse.ts`, `test/sse-drift.test.ts`.

**Step 1 — failing test:** fake pigeon returns serve-1 for sid, front door opens
the client SSE leg to serve-1; then fake pigeon flips to serve-2; on the next
re-resolve tick the front door **closes the client leg** (test asserts the client
connection ends, cleanly). It must NOT silently re-dial serve-2 on the same leg
(design C2).
**Step 2:** FAIL. **Step 3:** implement a per-stream timer that re-resolves
(confirm-twice, like #15) and, on drift, ends the client response so the client
reconnects and re-bootstraps. **Step 4:** PASS. **Step 5:** Commit
`feat(frontdoor): drop client SSE leg on owner drift`.

---

## Phase 3 — Health / failover (endpoint-class timeouts + native /healthz)

### Task 3.1: endpoint-class first-byte timeout (TDD)

**Files:** `src/timeouts.ts`, `test/timeouts.test.ts`.

- cheap GET / SSE-handshake: enforce `cheapFirstByteMs` first-byte timeout → 503.
- turn-running POST (`/session/…/message|prompt|compact|shell|command|summarize`,
  `init`): **no** first-byte timeout.
TDD: a slow-first-byte cheap GET → 503; a slow turn POST → passes through.
Commit `feat(frontdoor): endpoint-class first-byte timeouts`.

### Task 3.2: wedge health-probe for turn POSTs (TDD)

**Files:** extend `src/timeouts.ts`.

On a turn POST that stalls beyond a soft budget, probe the *target serve's*
`/global/health` directly (bounded); 503 only if the probe fails (serve wedged),
else keep waiting (legit long turn). TDD both branches.
Commit `feat(frontdoor): wedge detection via target health-probe`.

### Task 3.3: native unproxied `/healthz` (TDD)

**Files:** `src/healthz.ts`, wire into `server.ts`, `test/healthz.test.ts`.

`GET /healthz` returns 200 iff the forwarder's own event loop is live and it can
reach pigeon OR the anchor (report `degraded:true` when pigeon is down but anchor
is up). Must NOT proxy to a serve (design M2). This is the canary's probe target.
Commit `feat(frontdoor): native /healthz`.

---

## Phase 4 — New-session creation (create → /place → respond)

### Task 4.1: create-place choreography (TDD + integration)

**Files:** `src/create.ts`, `test/create.test.ts`, extend integration test.

**Step 1 — integration test:** `POST /session` through the front door →
forwarded to a serve → front door parses `.id` → `POST /place {session_id}` to
fake pigeon (which records assignment) → front door returns the create response
to the client **only after** place succeeds → a subsequent `GET /route` resolves
(no window). If `/place` fails, still return the create response (session exists;
degrade to anchor for follow-ups) but log loudly.
**Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS. **Step 5:** Commit
`feat(frontdoor): create->place choreography (no registration window)`.

> The front door does **not** choose serves (design M1): it forwards create to
> the anchor and lets pigeon HRW place. No "least-loaded" logic.

---

## Phase 5 — WebSocket/PTY + /global/* policies

### Task 5.1: PTY policy (driven by Phase 0.5)

**Files:** `src/pty.ts`, `test/pty.test.ts`.

- If the deployed TUI uses PTY: implement WS-upgrade proxying with a
  `ptyID→serve` pin (create-on-serve then connect-to-same-serve). TDD the pin.
- If not: block `/pty/*` with a clear 501 + log, documented as out-of-scope.
Commit `feat(frontdoor): PTY policy`.

### Task 5.2: /global side-effect + unrecognized policy (TDD)

**Files:** extend `src/dispatch.ts`.

`/global/dispose`, `/global/upgrade` → the Phase 0 decision (default: **deny**
with 405 + log; these are infra ops that must target a serve directly).
Unrecognized paths → 404-loud + structured log. TDD both.
Commit `feat(frontdoor): global-sideeffect + unrecognized policies`.

---

## Phase 6 — Nix packaging + systemd unit (cloudbox, isCloudbox-gated)

> Study first how `pigeon-daemon` is packaged/run as a service on cloudbox
> (`~/projects/pigeon`, `users/dev/home.*.nix`, `hosts/cloudbox/configuration.nix`)
> and mirror it.

### Task 6.1: Nix package for the front door

**Files:** `pkgs/opencode-frontdoor/default.nix`; register in the pkgs set.
Build the bun app into a runnable artifact (mirror how pigeon/opencode are built
+ run). Add `test.sh` running `bun run test`. Commit
`feat(frontdoor): nix package`.

### Task 6.2: systemd unit + isolation kit

**Files:** `hosts/cloudbox/configuration.nix` (or `users/dev/home.cloudbox.nix`,
matching where the serve pool + pigeon live).
- `opencode-frontdoor.service`: `127.0.0.1:<port>`, `MemoryMax` (sized like a
  serve, e.g. 1–2G — it holds only streams + a small map), `Restart=always`,
  `TimeoutStopSec=15`, `After=`/`Wants=` pigeon + the serve pool (soft; it
  degrades if they're not up), env `FRONTDOOR_PORT`/`PIGEON_DAEMON_URL`/`OPENCODE_URL`.
- **Do NOT** put a data plane in pigeon (design Decision 6).
Commit `feat(frontdoor): systemd unit + memory cap`.

### Task 6.3: front-door canary on /healthz

**Files:** same host file; mirror `opencode-serve-canary`
(`users/dev/home.devbox.nix:868+`, cloudbox analog).
Minutely probe `GET /healthz` (3 s); after 3 consecutive failures, dump
forensics + `systemctl restart opencode-frontdoor`. Commit
`feat(frontdoor): liveness canary`.

**Gate:** deploy on cloudbox (`nixos-rebuild`/`home-manager switch` per host
table), confirm `/healthz` UP and a manual `opencode attach <FRONT_DOOR>
--session <sid>` works end-to-end, BEFORE any client cutover (Phase 7).

---

## Phase 7 — Client cutover (rewrite to the one URL) + infra-plane exemption

Incremental, one client per task, each independently revertable. Keep the
anchor-degrade so a front-door outage is "never worse than pre-pool."

### Task 7.1: introduce `FRONTDOOR_URL` + repoint the generic entrypoints

**Files:** `users/dev/home.base.nix` (add `FRONTDOOR_URL` default;
decide whether `OPENCODE_URL` is repointed or kept as the raw anchor —
**keep `OPENCODE_URL` = raw anchor** for the degrade path; add a new
`FRONTDOOR_URL`), `hosts/cloudbox/configuration.nix:511,556`.
Commit `feat(frontdoor): introduce FRONTDOOR_URL`.

### Tasks 7.2–7.7: migrate each client (one commit each, with its `test.sh`)

For each: replace "`GET /route` → parse `apiBase` → dial `409x`" with "dial
`FRONTDOOR_URL`"; update its `test.sh`; keep anchor fallback.
- 7.2 `pkgs/oc-pool-attach` (richest; also drops its internal `/place` — front
  door owns create-place; keep a `--strict` selfhost bail on front-door-down).
- 7.3 `pkgs/oc-auto-attach` (also drops its `/place` call).
- 7.4 `pkgs/opencode-launch` / `opencode-send`.
- 7.5 `lgtm-sessions` inline (`users/dev/home.base.nix:1198-1223`) + retarget
  `users/dev/test-pool-route-clients.sh`.
- 7.6 `opencode-llm-audit` follower, `my-podcasts`, Telegram launch path.
- 7.7 `docs/plans/serve-distribution-probe.sh` + reset-workspace enrichment.

### Task 7.8: infra-plane exemption (documented + enforced)

**Files:** `.opencode/skills/monitoring-serve-pool/SKILL.md`,
`.opencode/skills/resetting-workspace/SKILL.md`, comments in the canary /
wedge-watcher / reset units.
State explicitly: **canary, wedge-watcher, and reset-workspace per-serve health
probes MUST keep dialing `4096–409x` directly** (routing them through the front
door destroys wedge detection). Add a test/grep-guard if practical.
Commit `docs(frontdoor): infra-plane direct-access exemption`.

---

## Phase 8 — opencode-patched: attach → session-scoped event stream

**Files (opencode-patched repo, separate PR; coordinate with the #10/#15 patch set):**
Move the attach client from the per-process `/global/event` firehose to
`/event?session_ids=<sid>`, and drop its own `/route` self-resolve (the front
door owns owner-following via drop-leg-on-drift). Preserve consumption of the
non-session event types Phase 0.5 flagged (re-subscribe or synthesize). Land the
Phase 0.6 tripwire in the same PR.

**Gate:** with Phase 8 deployed, a migrated session's attach TUI survives an
idle serve migration (drop-leg → reconnect → re-bootstrap) with no manual
intervention. This closes the loop.

---

## Rollout / verification summary

1. Phases 1–5 are pure package work (no live impact) — land behind tests.
2. Phase 6 deploys the process cloudbox-only; verify `/healthz` + manual attach
   before touching clients.
3. Phase 7 cuts clients over one at a time, each revertable, anchor-degrade
   intact throughout.
4. Phase 8 completes attach's event-stream move.
5. **Session-switcher:** update its plan's attach URL to `FRONTDOOR_URL` +
   `--session <sid>` (a simplification; no "verified facts" change).

## Risks carried from the design (watch during execution)

- Front door is a **total-outage SPOF** for opencode access; the isolation kit
  (unit + `MemoryMax` + `/healthz` canary + anchor-degrade) is mandatory, not
  optional.
- `/event?session_ids=` is a **hard dependency on patch #7** — the Phase 0.6
  tripwire is the guardrail.
- Residual owner-stability windows (lease-less fail-open turns, draining serves)
  — mitigate with per-sid short-TTL stickiness (confirm-twice) and document.
- The dual `/api/*` surface may become the default in a future bump — the Phase
  0.2 snapshot test forces re-audit when paths change.
