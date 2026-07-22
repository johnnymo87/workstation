# Opaque serve-pool reverse proxy — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Companion design:
> `docs/plans/2026-07-12-serve-reverse-proxy-design.md` (revision 2).
>
> **Plan revision 5** — after a THIRD fable review that verified the Phase 0
> findings against live pigeon + upstream v1.17.13 source. Verdict: **GO for
> Phase 1.** Folds in the review's must-do-firsts (NEW-A..H) and corrects two
> Phase-0 over-reads in the findings doc (0.5 method + web-UI PTY carve-out;
> 0.6 backoff-reset nuance). See "Changes from plan rev 4" at the end.
>
> **Plan revision 4** — **Phase 0 investigation EXECUTED** (see
> `docs/investigations/2026-07-12-frontdoor-route-audit.md`). Findings resolved
> several open items and *simplified* the plan: **PTY is unused by the deployed
> TUI → Phase 5 collapses to a 501 stub, no WebSocket proxying, and NEW-1
> (bun's broken raw hijack) is MOOT for v1**; the **event-scope contract is
> locked** (`/event?session_ids=` passes all global/lifecycle events, so a
> session-scoped stream keeps `server.connected` et al.); the **Phase 2 drop-leg
> premise PASSES** by source (it's exactly the shipped tui-follow-owner
> reconnect-resumes-live behavior), with one root live-test still pending;
> **create→/place** confirmed with a three-state `/route` model. Runtime stays
> **node** (now a *free* choice, not forced). Standing human decisions unchanged:
> (1) **port the serve canary to cloudbox**; (2) **dependency-free** (soft
> preference; node stdlib); (3) **repoint `OPENCODE_URL` in Phase 9** host-scoped.
> **Fleet:** crostini decommissioned (removed on `main`); devbox + macOS converge
> on this model later. See "Changes from plan rev 3" at the end.

**Goal:** Put the opencode serve pool (cloudbox K=4, ports 4096–4099) behind a
single opaque `127.0.0.1` front-door port so no client on the box ever addresses
an individual serve. (Cloudbox first; devbox + darwin follow with their own
front doors.)

**Architecture:** A dedicated `opencode-frontdoor` process (**node/TypeScript,
node stdlib** — `node:http`/`net`/`fetch`/streams) binds one port and is a thin
**L7 data plane**: per request it extracts the session id from opencode's HTTP
surface, asks the **pigeon daemon** (the unchanged **control plane**, via its
internal `GET /route` / `POST /place`) which serve owns the session, promotes
*newly-established* streams / turn-starting POSTs / creates to a durable
placement (never on casual reads — NEW-2), and forwards HTTP + SSE bytes
to the owner (**no WebSocket/PTY proxying in v1 — PTY is unused, Phase-0**). Owner is re-resolved per request boundary (safe: the serve-lease
invariant keeps the owner stable for a whole turn), with per-sid short-TTL
stickiness broken by **direct serve health**, not pigeon's opinion (NEW-5). On
any pigeon hiccup it degrades to the anchor serve (`serve-0`, via
`OPENCODE_ANCHOR_URL`), preserving "never worse than pre-pool". Full isolation
kit: own **system** unit, `MemoryMax`, `LimitNOFILE`, `restartIfChanged=false`,
canary on a native `/healthz` (which also reports a build marker).

**Tech Stack:** node (stdlib: `http`/`fetch`/streams; `net` only if PTY is ever
in scope), TypeScript, vitest (devDependency only), Nix (NixOS **system** units
in `hosts/cloudbox/configuration.nix`; thin copy-to-store + wrapper), bash
(client rewrites + tests). **Dependency-free is a soft preference:** prefer node
stdlib, but a small vetted dep is acceptable rather than hand-rolling a fragile
primitive. **Runtime is a free choice post-Phase-0** (no WS proxying needed);
node retained as the safe default (dodges bun's WS landmine if PTY is ever added).

**Non-goals (from design):** no reinvented failover; no mid-turn migration
handling; no auth today (localhost-only, clean identity seam); no front-door
placement *brain* (pigeon HRW places — the front door only *triggers* `/place`,
narrowly); no change to `OPENCODE_SERVE_ID`/ports/lease machinery.

---

## Ground truth (live cloudbox — re-verify in Phase 0)

- **Deployed line = `v1.17.13-patched`** (`users/dev/home.base.nix:238-243`).
  Verify against **running serves**, not `~/projects/opencode` HEAD.
- **Route table:** each serve serves OpenAPI 3.1 at `GET /doc` (~478 KB), but it
  **OMITS patched/undeclared routes** (e.g. `?session_ids=` is accepted-but-
  undeclared) → classify from `/doc` **and** the patch list
  (`home.base.nix:70-249`) (M1).
- **Event stream (C1) works:** `GET /event?session_ids=<sid>` → 200;
  `GET /session/<sid>/event` → 200; `/api/session/<sid>/event` → probe with
  `curl -N`.
- **PTY WS + runtime (NEW-1, verified live):** `/pty/{ptyID}/connect` is a WS
  upgrade. **bun 1.3.3 (deployed) silently drops bytes on a server-side socket
  hijack** — the 101 never reaches the client, no error. **node 22 works
  byte-identically.** The fleet already runs its canary + wedge-watcher on node
  for the same class of bun breakage (`home.devbox.nix:128-129, :981-984`).
  → **runtime = node.**
- **`ss -K` socket-kill is kernel-supported on cloudbox** (`CONFIG_INET_DIAG_DESTROY=y`,
  needs root) — the workable method for the Task 0.6 premise check (socat can't
  interpose because the deployed TUI self-resolves `/route` and dials the serve).
- **pigeon `POST /place`**: body `{"session_id":"ses_..."}`; 200 `{ok,
  session_id, serve_id, api_base, event_url, owner_generation, instance_uuid,
  expires_at}`; 400/503/409. Idempotent (`ensureRouted`). `GET /route` returns a
  `RouteResult` (`prospective:true, expiresAt:0` for unplaced sessions) or 404.
  **`GET /route` is deliberately READ-ONLY**; `resolveProspectiveRoute`
  "Performs NO writes" and idle sessions are *intentionally* left unplaced
  (`router.ts:95-108`, `app.ts:598-600`) — Task 1.4 must respect this (NEW-2).
  Both accept optional `Authorization: Bearer $PIGEON_DAEMON_AUTH_TOKEN`.
- **Anchor / defaults:** raw anchor `http://127.0.0.1:4096`; pigeon `:4731`.
  Real hardcodes at `hosts/cloudbox/configuration.nix:485` (pigeon-daemon) and
  `:530` (lgtm-run) — NOT `:511,556`.
- **No serve canary on cloudbox today** (devbox-only *user* units,
  `home.devbox.nix:868+/:840+`); cloudbox serves+pigeon are **system** units.
  Devbox recovery is ~**7–8 min** (`THRESHOLD=7`), not "~3 min" (NEW-6). Cloudbox
  serves set **no `BUN_INSPECT`**, so the wedge-watcher's inspector is a no-op
  there unless added (NEW-6).
- **`OPENCODE_URL` is a shared cross-host default** baked into packages devbox/
  darwin also consume (crostini being removed); repointing it is a multi-site,
  host-scoped audit, not a one-liner (NEW-4).

---

## Phase 0 — Deployed-line audit & de-risking — **EXECUTED 2026-07-12**

Full results: `docs/investigations/2026-07-12-frontdoor-route-audit.md`. Summary
of what each task found (all against live serves + opencode-patched v1.17.13):

- **0.1 route snapshot** — `/doc` OpenAPI 3.1, 478 KB, dual surface
  (`bare` + `/api/*`). Snapshot + `probe.sh` idiom captured. *Remaining product
  artifact: commit `pkgs/opencode-frontdoor/audit/probe.sh` in Phase 1.*
- **0.2 classification** — 40 `session-path` routes; **`session_ids` is
  UNDECLARED in `/doc`** (patch-only → classify from patches, M1 confirmed); PTY
  (9 routes, **unused**); `/global/{config,health}` ro, `{dispose,upgrade}`
  side-effect, `event` firehose.
- **0.3 event contract — LOCKED** (source `patches/event-session-scope.patch`):
  `/event?session_ids=` filters by `event.data.sessionID`, **but all
  global/lifecycle `server.*` events ALWAYS pass** (incl. `server.connected`).
  **Live-only** (no SSE `id:`/Last-Event-ID cursor). ⇒ a session-scoped stream
  keeps the lifecycle events the TUI needs. `/global/event` policy for v1:
  pass-to-anchor-with-loud-log (revisit at Phase 8).
- **0.4 create→place — CONFIRMED** (live): three `/route` states —
  **never-placed → 404**, **leased → real route**, **idle → `prospective:true`**.
  Fresh create 404s until `POST /place`. ⇒ Task 1.4 promotes **both** the
  404-but-exists and prospective states.
- **0.5 PTY — UNUSED** (exhaustive grep of opencode-patched: no client builds
  `/pty/*`). ⇒ **Phase 5.1 = 501 stub; no WS proxying; NEW-1 MOOT for v1;
  runtime is a free choice** (node retained).
- **0.6 drop-leg premise — PASS (source), one root live-test pending.**
  `tui-follow-owner` already does end-attempt→reconnect-to-new-owner
  (resume-live, not re-bootstrap) — the shipped yl00 fix; `runSseAttempt` is a
  reconnect loop that fires on a server-initiated close; full `bootstrap()` only
  on `server.instance.disposed`. Safe because **drift is idle-only** (no missed
  events). **`sudo -n` = NO blocked the root `ss -K` live test** — see the
  pre-Phase-2 gate below.
- **0.7 node duplex tunnel — moot** (PTY unused); node 22 present.
- **0.8 packaging — node stdlib, dependency-free thin wrapper** (decided).

**Pre-Phase-2 gate (the one Phase 0 residual):** run the **root `ss -K`
socket-kill + gap-injection** live test once (attach a TUI, kill its SSE socket,
trigger a turn while disconnected, confirm the TUI shows the turn after
reconnect). Source strongly predicts PASS; if it FAILS, STOP and redesign Phase 2
(cursor-resume via `/api` `after`, or stream-stitching). Everything else in
Phase 0 is resolved. **RE-SCOPED (fable review):** this test is NOT a blocker to
*writing* Phase 2 (`sse.ts`) — nothing real rides door-SSE until Phase 6/7, and
the TUI (the client the premise concerns) not until Phase 8. It IS a **hard
pre-Phase-6-deploy blocker** and an **absolute Phase-8 blocker**. Run it before
first real SSE consumers, not before coding.

---

## Phase 1 — Forwarder core (node)

### Task 1.0: Materialize the Phase-0 artifacts (NEW-F)
Before any routing code, commit the two Phase-0 deliverables that were left as
prose: `pkgs/opencode-frontdoor/audit/probe.sh` (the live `curl -N` probe
matrix) and `src/routes.classification.ts` — the **enumerated** route→class
table (regenerate from `/doc` + the patch list; do NOT ship only counts). The
dispatcher (1.5) and sid map (1.2) are only as good as this table. Commit
`feat(frontdoor): route classification table + probe.sh`.

### Task 1.1: Scaffold (node, minimal deps)
`package.json` (vitest devDep), `tsconfig.json`, `vitest.config.ts`,
`src/config.ts` (`port`, `pigeonUrl`, `anchorUrl` from `OPENCODE_ANCHOR_URL`,
optional `pigeonAuthToken`, `routeTimeoutMs=3000`, `cheapFirstByteMs=5000`,
`stickyTtlMs=30000`). TDD defaults. Commit `feat(frontdoor): scaffold (node)`.

### Task 1.2: sid extraction (TDD)
`src/sid.ts`. Path / query (`session_ids`, `session`) / create→null /
malformed→null. **Enforce `^ses_[A-Za-z0-9_-]+$`** on any extracted sid (NEW-E) —
pigeon's `/place` does NOT validate the sid (asymmetric with `/route`), so the
front door must gate it before ever calling `/place`. **Multi-value
`session_ids`:** single→route; same-owner→route; mixed-owner→400. Commit
`feat(frontdoor): session-id extraction`.

### Task 1.3: pigeon resolver with anchor degrade (TDD)
`src/resolve.ts`. `resolveOwner(sid) → {url, prospective, degraded}` via GET
`/route` (bounded, optional Bearer; degrade→anchor). **READ-ONLY** — never
writes (NEW-2). Accept `.apiBase`/`.api_base`. Commit `feat(frontdoor): resolver + anchor degrade`.

### Task 1.4: **scoped** promote→placed (TDD) — fixes C1, corrected per NEW-2
`src/place.ts`. Issue `POST /place` **only** for: (a) SSE-stream *establishment*,
(b) turn-starting POSTs (`…/message|prompt|compact|shell|command|summarize`,
`init`), (c) the create choreography (Phase 4). **Never** on casual GETs or the
Task 2.2 drift-timer re-resolve — those stay read-only. Promote for **both**
unplaced states confirmed in Phase 0.4: a `404 "session not routed"` (never
placed — but confirm the sid exists first, e.g. the create response or a
`GET /session/<sid>` 200) **and** a `prospective:true` route (placed-but-idle).
Guard: **place at most once per sid per `stickyTtlMs`** (avoid the
assigned/dormant oscillation, load-skew, and idle-migrate suppression that
unscoped promotion causes — `router.ts:174-287`). The sticky check (3.4) runs
*before* promotion so a lease-less in-flight turn is never clobbered. TDD:
establishment→place-once; casual GET→no write; second establishment within
TTL→no re-place; 404-unknown-sid→no place. Commit `feat(frontdoor): scoped promote-to-placed`.

### Task 1.5: request dispatcher (TDD)
`src/dispatch.ts`. (method,path)→class→action. `unrecognized`→404-loud. Commit
`feat(frontdoor): dispatcher`.

### Task 1.6: structured request log + degrade counter (TDD) — M8
`src/log.ts`: `{class, sid, target, prospective, degraded, status, durationMs}`
+ `degraded_to_anchor` counter surfaced on `/healthz`. Commit `feat(frontdoor): request logging`.

### Task 1.7: HTTP forwarder + integration harness + auth seam (TDD)
`src/proxy.ts`, `src/server.ts` (node `http.createServer`), `src/identity.ts`
(no-op seam), `test/integration.test.ts` (fake serves + pigeon). Assert route-to-
owner, unknown→anchor, header/body/status passthrough, **no-retry-after-send**.
Note in tests: SSE/turn-end realities are covered by the Phase 6 through-door
gate, not fakes. Also commit the `audit/probe.sh` from Phase 0.1 here. Commit
`feat(frontdoor): HTTP forwarder + harness`.

---

## Phase 2 — Event streams (SSE + drop-leg-on-drift) — **DONE 2026-07-16** (commits `bc164fb`..`4cebab2`, remediation in follow-up commits; `src/sse.ts` + `src/drift.ts`; spec+code+final review + **2nd fable adversarial pass** passed. FABLE-B2 degrade→no-evidence and C2 clean-close implemented & tested. Root `ss -K` live-test still owed pre-Phase-6-deploy, not a coding blocker.)

- **2.1** `src/sse.ts` unbuffered pass-through, survives the upstream 10 s
  `server.heartbeat`. Commit. (**FABLE2-B1 correction:** upstream `/event` emits
  a `server.heartbeat` every 10 s with `properties:{}` — no `sessionID`, so it
  passes the session-scope filter. An SSE-byte "activity" signal therefore can
  NEVER distinguish a live turn from an idle heartbeat; do not build a drift
  guard on it — see 2.2 / 3.4.)
- **2.2** confirm-twice re-resolve timer (**read-only**, no promote — NEW-2); on
  confirmed drift **close the client leg** (no silent re-dial — C2). **Drop on
  confirmed drift, deployed-TUI parity (no active-guard in Phase 2).**
  The **lease invariant already prevents mid-turn drops**: a mid-turn session
  holds a renewed lease, so pigeon `/route` keeps naming the same owner and drift
  cannot confirm mid-turn; the only exception (owner serve dies → reassign)
  leaves a dead/silent serve → quiescent leg → dropping is the *correct* outcome.
  This matches `tui-follow-owner.patch`, which has no guard and works.
  **NEW-H's "don't drop an active leg" moves to Task 3.4**, sourced from
  *forwarded-request* stickiness (turn POSTs the door forwards) — the signal
  NEW-H actually described — NOT SSE bytes (FABLE2-B1: heartbeats pollute the
  byte signal; the old byte-guard defaulted `quiesceMs`=10 s = the heartbeat
  period and thus suppressed the drop **permanently**, making the door strictly
  *less* capable than the guardless TUI).
  **DRIFT-EVIDENCE RULE (FABLE-B2 — in the impl):** drift = **two consecutive
  `active`/`prospective` resolves that name a *different real owner***. A
  `degraded`/`not-routed`/`pigeon-error`/`pigeon-unreachable` resolve is
  **never** drift evidence (RESETS the chain) — otherwise a transient pigeon blip
  (which `resolveOwner` maps to `url=anchor`) looks like drift and drops a healthy
  leg, and with NEW-A's non-resetting backoff inflates TUI reconnect delay on
  every hiccup. Assert: pigeon-blip during a live stream → NO drop; **a leg still
  receiving heartbeats but with a confirmed different owner → DOES drop**
  (FABLE2-B1 regression test).
  **FABLE2-S1 (multi-sid divergence):** ≥2 diverging *real* owners for one
  `session_ids` leg (parent on A, child actively leased on C) can't be served by
  one leg; v1 logs loudly on first divergence (visible decision, not a silent
  starve) and holds; establishment already 400s this. **FABLE2-S2
  (degraded-anchor baseline):** a leg established while pigeon was degraded pipes
  from the anchor and heals via the drift-drop once pigeon recovers (tested);
  requires `OPENCODE_ANCHOR_URL` to *textually* match pigeon's registered anchor
  endpoint (`127.0.0.1` vs `localhost` spelling drift → one spurious drop cycle)
  — documented constraint. Commit `feat(frontdoor): drop SSE leg on drift`.

---

## Phase 3 — Health / failover + stickiness  **[DONE]**

**Status:** Complete via SDD (implement → spec-review → code-review → fixup per task).
Commits on `serve-reverse-proxy`: 3.1 `578720d`, 3.2 `5c53ec0`, 3.3 `7ba8db3`,
3.4a `f1d691f`, 3.4b `8ca9d1e`. 215 tests green, typecheck clean. Notable
decisions folded in during build:
- **3.1**: derived the no-first-byte-timeout set from the route table (turn/stream
  POSTs + `POST …/wait`); reclassified all `/tui/*` → 501 (so `control/next` is
  never forwarded, mooting its timeout exemption); replaced the socket-idle
  `setTimeout` with a true wall-clock time-to-headers timer → **503** (FABLE-W9).
- **3.2**: wedge probe requires **2 consecutive** `/global/health` failures
  (canary-parity blip-immunity) before 503; probe body discarded (socket hygiene).
- **3.3**: `/healthz` returns 200 unless **both** pigeon AND anchor are
  unreachable (reconciles plan "pigeon OR anchor" with design §7 "don't let a
  pigeon blip restart a healthy door"); pigeon-reachable = any HTTP response,
  anchor-reachable = 200; degraded counter + `FRONTDOOR_VERSION` marker (NEW-8).
- **3.4**: sticky check runs before resolve/promote and is broken ONLY on a failed
  `/global/health` probe (never on pigeon disagreement); **FABLE-S2** write/read
  split (mutating + pigeon-down + no-sticky → retryable **503**, reads still
  anchor-degrade); NEW-H wires the drift monitor to the sticky map to suppress the
  SSE drop mid-turn. Shared `discardBody`/`probeServeHealth` helpers extracted.
- **Deferred (low):** drain `boundedFetch` bodies on non-200 early returns in
  `place.ts`/`resolve.ts` (now that `discardBody` exists).

- **3.1** endpoint-class first-byte timeout (`src/timeouts.ts`): cheap GET / SSE
  handshake = **time-to-response-headers** → 503; turn POSTs = no first-byte
  timeout. **FABLE-S3/S4 — re-derive the "no-first-byte-timeout" set from the
  route table, do NOT reuse the promoting-suffix list:** it MUST also include the
  long-*blockers* that aren't turn-starts, notably **`POST /api/session/{id}/wait`**
  (blocks until the agent loop goes idle → returns 204 only at turn end; today it
  gets `cheapFirstByteMs` → guaranteed 504) and **`GET /tui/control/next`** (an
  in-process long-poll). Audit the whole table for other blockers. **FABLE-S4 —
  fix `/tui/*` classification (Phase 5.2 or here):** `/tui/control/next` is
  currently `global-ro`→anchor (wrong process + 504); its sibling POSTs are
  `global-sideeffect`→405. The `/tui/*` subsystem is per-process stateful →
  reclassify ALL of `/tui/*` to a **deny/501** class (no silent anchor-forward),
  per design §6 "404-loud, never silent forward." Also **Phase-1.7 seam fix
  (FABLE-W9):** `upstreamReq.setTimeout` is a socket-*idle* timeout (slow body
  uploads reset it); `timeouts.ts` must implement true time-to-response-headers.
  Commit.
- **3.2** wedge health-probe for turn POSTs: probe target `/global/health`; 503
  only on probe failure. Commit.
- **3.3** native `/healthz` (`src/healthz.ts`): 200 iff loop live AND (pigeon OR
  anchor reachable); report `degraded` + counter + **build/version marker**
  (store path / hash — NEW-8, closes the `restartIfChanged=false` staleness gap).
  Never proxies. Commit.
- **3.4** **corrected** per-sid stickiness (`src/sticky.ts`) — fixes M5/NEW-5:
  map `{sid→lastForwardedServe, expiry}` **refreshed on every forwarded request**
  (a turn POST/mutating request the door forwards — NOT SSE bytes: FABLE2-B1
  proved the 10 s `server.heartbeat` makes SSE-byte activity useless as a
  liveness signal); break stickiness **only when the sticky target
  fails a direct `/global/health` probe** (reuse 3.2), NOT when pigeon merely
  disagrees (pigeon persistently disagrees during a lease-less turn — that's
  exactly when we must stay stuck). Sticky check runs **before** resolve/promote.
  **NEW-H (deferred from Phase 2):** this is the correct home for "don't drop an
  actively-flowing SSE leg mid-turn" — the drift monitor (2.2) consults this
  sticky map: a sid with a fresh forwarded-request entry is mid-turn → suppress
  the drift-drop. Wire the 2.2 monitor to the sticky map here.
  TDD the abort-follows-the-runaway-turn case explicitly. **FABLE-S2 —
  write-vs-read degrade split (NEW, load-bearing):** Phase 1 degrades EVERY
  session request (incl. mutating `POST …/message|abort|permission|question`
  replies) to the anchor on `pigeon-unreachable`/`pigeon-error`, and re-resolves
  *per request* (vs the old clients' once-per-attach) — so a pigeon blip can run
  a turn on a serve that doesn't own the session (duplicate/wrong-process
  execution, `abort` no-ops, events on the wrong bus). Anchor-degrade is correct
  ONLY for **reads** (shared `opencode.db`). For **mutating session routes** with
  `reason ∈ {pigeon-unreachable, pigeon-error}` and **no sticky hit**, return a
  **retryable 503**, not an anchor-forward. **3.4 is therefore a HARD correctness
  prerequisite of deployment (Phase 6), not just an optimization** — state that in
  6.2/6.5. Commit `feat(frontdoor): health-broken short-TTL stickiness`.

---

## Phase 4 — create → /place → respond  **[DONE]**

**Status:** Complete via SDD (implement → spec-review → code-review → fixup per
task) **plus a fable adversarial pass** (findings folded below). Commits on
`serve-reverse-proxy`: 4.1 `309c098` + hardening `01d6d3b`, 4.2 `a4f5af5` +
cleanup `cc66fd4`, fable remediations `92f7d46`. 232 tests green, typecheck
clean. Notable decisions folded in during build:
- **4.1**: replaced the `create` stub with a **buffered** forward to the anchor →
  parse top-level `.id` → `placeSession` → relay only after place resolves.
  place-fail / missing-id → `degraded=true` (counter via the `logResponse`
  finish-hook) + warn, **still returns the created session** (never fails the
  create). Seeds stickiness on the brand-new sid (`apiBase` from `/place`) so the
  first turn survives a pigeon blip. Code-review hardening (all 8 accepted):
  strip `content-length`/`content-encoding` on the decoded relay (undici
  auto-decodes `.text()`), 1 MiB request-body cap → **413**, UTF-8-safe
  `Buffer.concat` buffering, exclude client `Host` (parity with `proxyRequest`),
  **504** (not 502) on anchor timeout via `boundedFetch.timedOut`, reuse
  `stripTrailingSlashes`, dedupe header filtering (`forwardableResponseHeaders`),
  and extract the choreography into a helper.
- **4.2 (FABLE-W5)**: **Option A — readback-and-place the forked session.** Fork
  mints a NEW *independent root* session (verified upstream: `Session.fork` calls
  `createNext` with **no** `parentID`; it's a message-copy, session.ts:697), sid
  in the response `.id`. Reclassified `POST /session/{id}/fork` to its own `fork`
  action (out of the streaming `route-session` path). Extracted the shared
  `placeAfterCreate(target, …)` core; `handleFork` resolves the parent's owner
  (`resolveOwner(parent).url`) and runs the create core against it, **placing the
  CHILD sid** and seeding its stickiness. Fork is create-like → **no FABLE-S2 503
  on pigeon-down** (degrade, don't block). Placement also fixes the "unplaced fork
  trips the multi-sid path" concern (resolveOwner(forkSid) now yields a real
  owner).
  > **Correction (FABLE-P4/LOW-1):** the earlier "freshest parent state" rationale
  > for forwarding fork to the parent's owner is **wrong** — upstream `Session.fork`
  > reads the parent via `get()`/`messages()`, both **shared-db reads**
  > (`session.ts:543,830`), and non-durable `message.part.delta`s are lost on every
  > serve equally, so the owner has **no** freshness advantage. Any serve (incl. the
  > anchor) forks identical state. Parent-owner forwarding is therefore neutral-to-
  > slightly-worse (it burns the copy-loop CPU on the serve most likely mid-turn);
  > it is retained as a reviewed, working choice. **Anchor-always is a valid future
  > simplification** (drops a `/route`, mirrors create) — deferred, not required.
  **Minter re-scan (verified against live `/doc` + upstream):** only `POST /session`
  (+ `/api/session`) and `POST /session/{id}/fork` mint sids; the `/api` mirror has
  **no** fork route; `GET /session/{id}/children` is a read/list;
  `update`/`share`/`unshare`/part-update return `Session.Info` for an existing path
  sid (not minters); no auto-create-on-message path exists.

### Phase 4 fable adversarial pass — findings & disposition
A fable pass verified the strongest design claim to the bottom — the create→place
**"no registration window"** holds: pigeon's `POST /place`→`ensureRouted` does
synchronous better-sqlite3 `assignments.upsert`+`leases.acquireCAS`
(`router.ts:196-218`), so any later `GET /route` on any connection sees the
assignment (strict read-after-write); a >30s-idle lease expiry still resolves via
the persisted assignment. Areas cleared: registration window, minter completeness,
fork-to-degraded-target (shared-db reads ⇒ no staleness; nonexistent parent → serve
404 → relay, never placed), degrade accounting.
**Folded into code (`92f7d46`):**
- **HIGH-1 (mint timeout):** the buffered mint forward used the 3s control-plane
  `routeTimeoutMs`; a large fork's per-message/part copy loop blows it → 504 +
  half-copied orphan. Split out `mintTimeoutMs` (`FRONTDOOR_MINT_TIMEOUT_MS`,
  default **60s**) for the data-plane forward; pigeon `/place` stays on
  `routeTimeoutMs`.
- **MED-1 (sid validation):** `placeAfterCreate` now requires `SID_REGEX.test(id)`
  before `POST /place` (pigeon `/place` itself does not validate) — junk `.id` →
  degrade path, never placed.
- **MED-2 (2xx relay):** success gate widened to any 2xx and the **upstream status
  is relayed** (not hardcoded 200), so a future 201/204 neither silently skips
  placement nor gets status-rewritten.
- **LOW-4/LOW-5:** documented the intentional no-wall-clock-bound on
  `readIncomingBody` (localhost + Node `requestTimeout`); fixed the mislabeled
  create test to actually guard the missing-id degrade branch.
**Deferred to before Phase 6 deploy (tracked, NOT fixed in Phase 4):**
- **FABLE-P4-HIGH-2 (sticky/lease divergence) — must fix before deploy.** The
  sticky short-circuit **refreshes its own TTL on every mutating hit**
  (`proxy.ts:547`), while pigeon's lease renews **only** via `placeSession`
  (`router.touch` has no callers). A session mutated more often than the 30s TTL
  keeps its sticky entry alive forever without re-confirming pigeon; if pigeon later
  re-places that sid onto a different (also-healthy) serve, the door pins to the
  stale owner — the exact wrong-process-turn shape FABLE-S2 exists to prevent (rare:
  needs an eligible-set change coinciding with an expired lease). **Do NOT** apply
  the naive "stop refreshing" fix — it regresses FABLE-S2 resilience (sticky must
  outlive pigeon outages >30s). Correct fix: on a sticky hit older than ~½ the lease
  TTL, fire-and-forget a `POST /place` to renew the lease + re-confirm the owner
  (keeps outage resilience *and* convergence). Own task.
- **LOW-2:** `stickyTtlMs ≤ leaseTtlMs` is currently coincidental (30s==30s) but
  they're independent env knobs — document/assert the invariant in the Phase 6 unit.
- **LOW-3:** `POST /session {parentID}` mints a *child* whose owner is unrelated to
  the parent's; handled mechanically, no through-door consumer today — model note.
- **Interrupted-fork orphans:** upstream `Session.fork`'s copy loop is **not**
  transactional, so a client disconnect / >60s fork can still leave a half-copied
  unplaced child in the shared db. The door can't fix this (upstream concern); note
  a reaper / wrapping-transaction as a future upstream item.
- **Tripwire:** pin "create/fork success is exactly 200" as an opencode-patched CI
  tripwire alongside the `session_ids` one (design C1).

---

## Phase 5 — /global/* + PTY policies  (**collapsed — PTY unused, Phase-0.5**)  **[DONE]**

**Status:** Complete via SDD (implement → spec-review → code-review → fixup per
task) **plus a fable adversarial pass** (findings folded below). Commits on
`serve-reverse-proxy`: 5.1 `6fc9554` + review fixup `dfe29f7`, 5.2 `f56a3d4` +
review fixup `31a44b3`. 235 tests green, typecheck clean. **Most of Phase 5's
machinery was front-loaded during Phase 1** — the 191-row classification table
(`routes.classification.ts`), the dispatch map (`dispatch.ts`: `pty`→`pty-501`,
`tui`→`tui-501`, `global-sideeffect`→`deny-405`, `global-event`→`gone-410`,
`web-ui`/`unrecognized`→`not-found-404`), the proxy action branches, and their
dispatch/integration tests already existed and passed. The FABLE-S4 `/tui/*`
reclassification (Phase 3) was also already landed (`tui` class → `tui-501`).
Phase 5's actual delta was: **make the policies fail-loud** (add the missing
`console.warn` shakeout signals) + document PTY/web-ui scope + widen tests.

- **5.1**: added the PTY `console.warn` (`[FRONTDOOR WARN] PTY request denied
  (out of scope v1): …`, parity with the existing `tui-501`/unrecognized warns)
  + a code comment recording the out-of-scope rationale and future path (Node raw
  duplex tunnel; Node 22 verified; bun 1.3.3 hijack silently fails; `/pty/{id}/
  connect` is a WS upgrade keyed by `ptyID` needing a `ptyID→serve` pin).
  Strengthened integration tests to assert the 501 body across `/pty/*` +
  `/api/pty/*` shapes and that a warn fires. **No WS proxying / raw tunnel in v1.**
  Review fixup (`dfe29f7`): keep the warn-spy over the whole dispatch-policy test
  so later hits don't spam stderr.
- **5.2**: added fail-loud `console.warn` to `deny-405` (denied mutating-global:
  "…per-process state; call a serve directly…") and `gone-410` (`/global/event`
  "…firehose is gone from the front-door contract…"); extended `not-found-404` to
  warn for the `web-ui` class too (keeps the loud-404 invariant honest if a `/`
  route is ever classified web-ui). **Verified the classification table against
  the live `/doc`** — the `/global/*`, `/pty/*`, `/api/pty/*`, `/tui/*`,
  `/instance/*` rows match the deployed line exactly (no drift). **Web-UI scope
  (NEW-D):** `/` + static assets are undeclared in `/doc` and intentionally fall
  through to `unrecognized`→404-loud (PTY→501); use direct serve ports — recorded
  as a comment above the `RouteClass` union. `/global/event`→410 (NEW-C):
  pass-to-anchor is the yl00 missed-events shape (sessions on serve-1..3 emit only
  on their own buses) and there are **zero** non-TUI `/global/event` consumers, so
  anchor-forwarding is dead code that can only mis-serve — fail loud instead.
  Review fixups (`31a44b3`): flatten the web-ui/unrecognized conditional, hoist
  the NEW-D comment above the union, and add `vi.restoreAllMocks()` to the
  integration `beforeEach` so a mid-test failure can't leak a mocked console.

  > **Scope note — broad `global-sideeffect`→405.** The implemented policy denies
  > **all** mutating global routes (not just `/global/dispose|upgrade`): `PATCH
  > /config`+`/global/config`, `PUT/DELETE /auth/{providerID}`, `POST /mcp/*`,
  > `/sync/*`, `POST /log`, `POST /permission|question/{id}/reply` (the *bare*,
  > non-session-scoped ones), most `/experimental/*` mutations, `/vcs/apply`,
  > `POST /project/git/init`, `/instance/dispose`, etc. Denying 405 (fail-loud,
  > never silent-forward) is the safe v1 choice and the dispatch **code is correct
  > for everything that reaches it today** (Phase-5 fable verdict). It was
  > decided/tested/reviewed in Phase 1 (`dispatch.test.ts` asserts
  > `PATCH /global/config`→405) and re-affirmed here.
  > **CORRECTIONS (Phase-5 fable):** two justifications originally written here were
  > wrong and are retracted: (1) the "per-process state ⇒ split-brain" reason is
  > **false for the shared-storage writes** — `PUT/DELETE /auth/{providerID}` writes
  > the **shared** `auth.json`, `POST /log` just writes the receiving process's log,
  > `POST /vcs/apply` / `POST /project/git/init` mutate the **shared** on-disk
  > worktree; for these, forward-anchor would be semantically identical to "call a
  > serve directly," so denying them is a **safe-but-gratuitous** regression (kept
  > denied in v1 for uniformity; the real per-process cases are mcp/config-reload/
  > permission/question). (2) "client calls a serve directly for these **rare** ops"
  > is **false**: the deployed TUI hits bare `POST /permission/{requestID}/reply`
  > **interactively, mid-turn** (auto-approve fires on every permission), and a
  > door-attached TUI has **no** per-route escape hatch — see **NEW-P5-F1** (Phase 8
  > must migrate the TUI to the session-scoped reply routes **before** the Phase 9
  > `OPENCODE_URL` repoint, or interactive turns wedge). `POST /log` warn-volume is
  > a **non-issue** (fable verified ≈0 through-door callers; the TUI never calls
  > `app.log`).

### Phase 5 fable adversarial pass — findings & disposition
Fable verdict: **the dispatch code is safe to deploy — nothing deployed reaches a
denied route through the door today** (attach bypasses the door until Phase 8).
The defects are in the *justifying docs* and in *latent* traps for later phases.
Verified-sound by fable: table completeness is **exact** vs live `/doc` (0 real
routes fall to `unrecognized`); PTY→501 still true on 1.17.13 (TUI builds no
`/pty/*`); `/global/event`→410 has no through-door consumer; the
lifecycle-events-pass-the-`session_ids`-filter claim holds; dispatcher
exact-before-pattern + HEAD→GET mechanics are correct; no GET-with-side-effect
snuck into `global-ro`; policy warns log only `method`+`pathname` (no query/sids,
no body — leak-clean).
- **F1 (HIGH) — folded (docs).** "rare ops / call directly" is false for the TUI;
  405 mechanism is right but the client must migrate. Retracted the false text
  above; added **NEW-P5-F1** to Phase 8 (+ its gate) and a TUI-REST-surface row to
  the Phase-9.0 audit gating 9.1.
- **F2 (MED-HIGH) — folded (code annotations + design §6).** Inverse hazard:
  `global-ro`→anchor rows that read **per-process** memory (`/session/status`,
  `/permission`, `/question`, `/api/{permission,question}/request`, `/mcp`) return
  the anchor's view only. Latent (no through-door consumer today). Annotated those
  rows (`note: FABLE-P5-F2` in `routes.classification.ts`) and corrected design §6's
  blanket "shared `opencode.db`" claim. Revisit (deny or per-owner fan-in) before
  Phase 7/9 client reads.
- **F3 (MED) — DEFERRED to Phase 6 (pre-deploy).** `deny-405` omits the RFC-9110
  `Allow` header and its body (`method_not_allowed`) misleads shakeout debugging
  (the real cause is "policy-forbidden through the proxy," not a wrong verb). Not
  changed at Phase 5's tail because it's a deliberate contract choice (405 + `Allow:
  GET` where a RO twin forwards, vs 403 + policy body, vs 501-like the PTY/TUI
  denials) best made with the Phase-6 through-door probe/gate work; nothing hits it
  through the door today. **Action in 6.x:** pick the contract, add `Allow` where a
  forwarded GET twin exists, and put the real reason in the body.
- **F4 (LOW-MED) — DEFERRED to Phase 6 (DX).** The serve *does* serve a web UI at
  `GET /` (live: 200 `text/html`); through the door a browser gets a bare
  `{"error":"not_found"}`. NEW-D documents the unsupported scope, but the `GET /`
  404 body should say "web UI is not served through the front door; use a serve
  port" (one string; optionally classify `/` as `web-ui` to use that class + a
  distinct body). Fold with the F3 body work in 6.x.

---

## Phase 6 — Nix packaging + **system** units + canary (cloudbox)

- **6.0** **deny-response polish (Phase-5 fable F3+F4), TDD.** Before the through-
  door shakeout (6.5): (a) `deny-405` — decide the contract and make it honest: add
  an RFC-9110 `Allow` header (`GET` where a forwarded RO twin exists) and put the
  real reason in the body (policy-forbidden through the front door), or switch to
  403/501 to match the PTY/TUI denial semantics — pick one and update the contract
  tests. (b) `not-found-404` for `GET /` — return a body that says the web UI isn't
  served through the front door (use a serve port), optionally by classifying `/` as
  `web-ui`. Commit `feat(frontdoor): honest deny responses (405 Allow/body, web-ui /)`.
- **6.1** dependency-free node Nix package (`pkgs/opencode-frontdoor/default.nix`:
  copy sources + wrap `node`/`tsx`; `test.sh` runs vitest outside sandbox).
  Commit.
- **6.2** **system** unit in `hosts/cloudbox/configuration.nix`:
  `127.0.0.1:$FRONTDOOR_PORT`; env `PIGEON_DAEMON_URL`/`OPENCODE_ANCHOR_URL`/
  optional Bearer; **`restartIfChanged=false`** (+ documented intentional-restart
  procedure, precedent `configuration.nix:606`); `MemoryMax≈1.5G` (stream-holder);
  `Restart=always`; `TimeoutStopSec` allowing a bounded stream drain; **high
  `LimitNOFILE`** (conn-doubling; #14 saw ~900 conns); `After=`/`Wants=` pigeon +
  pool (soft). Commit `feat(frontdoor): system unit + isolation kit`.
- **6.3** **port the serve canary to cloudbox** (M4/NEW-6) — as **system** units
  in `configuration.nix`. Capture the user→system deltas: `systemctl --user`→
  system `systemctl` (three call sites, `home.devbox.nix:909,930-931,989`); drop
  the `sudo -n`/`/run/wrappers` dance (runs as root); `/tmp/opencode-serve-canary`
  + `/tmp/opencode-wedge-watcher` become root-owned (adjust the `.force`/cleanup
  convention); retune `THRESHOLD` for cloudbox; `/tmp/reset-workspace.lock` check
  ports as-is. **Decide `BUN_INSPECT`**: cloudbox serves set none, so port it to
  the cloudbox serve env too, or scope this task to the liveness canary only
  (not the inspector wedge-watcher). Update `monitoring-serve-pool` skill.
  Commit `feat(serve-pool): port canary to cloudbox`.
- **6.4** front-door canary on `/healthz` (system unit). Commit. **DONE** (`f1a4048`
  + review fixups `e049707`: probe `--max-time 5` > door's 3s `routeTimeoutMs`; no
  `-f` so a 503 = door-alive; THRESHOLD=2; instant-only forensics; keep-latest-10
  prune on both canaries).
- **6.5** **deploy + through-front-door gate** (M2). **DONE 2026-07-22** — merged
  `serve-reverse-proxy`→`main` (`2691e6b`, throwaway-worktree merge, clean auto-merge
  of the one `flake.nix` overlap), deployed live on cloudbox via `sudo nixos-rebuild
  switch --flake .#cloudbox` (closure `van969v…`; new units started:
  `opencode-frontdoor.service`, `opencode-frontdoor-canary.timer`,
  `opencode-serve-canary.timer`). Gate results:
  1. ✅ `test.sh` gate: 239 tests + typecheck green on the deploy tree.
  2. ✅ switch started the (new) unit fresh; `/healthz` version marker ==
     `g4s6z5…-opencode-frontdoor-1.0.0` (== ExecStart store path). NEW-8 confirmed.
  3. ✅ `/healthz` `status:ok, pigeon:true, anchor:true, degraded:false`, listening
     127.0.0.1:4700.
  4. ✅ `probe.sh` through-door (no `--mutate`) vs direct: only the intended policy
     deltas — `pty` 200→**501**, `global-event` 200→**410**, `web-ui /` 200→**404
     web_ui_not_served**, `unrecognized` 200(SPA)→**404**; `session-path`,
     `session-query /event` (SSE `server.connected` streamed through door),
     `global-ro` pass 200.
  5. ✅ SSE turn delivery: with a throwaway session owned by **serve-2 (:4098,
     prospective)**, a `noReply` message to the owner produced
     `message.updated`/`message.part.updated`/`session.updated` **relayed through the
     door's** `/event?session_ids=` — proving the door owner-routes SSE to a
     non-anchor serve. (No LLM cost; throwaway session deleted.)
  6. ✅ deny-contract through door: `PATCH /config`→405+`Allow: GET`+honest body;
     `POST /global/dispose`→403; `POST /mcp`→405+`Allow: GET` (F3 per-process twin).
  7. ✅ canary self-test: SIGSTOP the **listener child** → `/healthz` timed out →
     canary logged `1/2` then `2/2 consecutive` → restarted the door + dumped
     forensics to `/var/lib/opencode-frontdoor-canary/wedge-20260722T091823/`; door
     recovered to a new PID, `/healthz` 200, failfile cleared.
  8. ✅ degrade drill: `systemctl stop pigeon-daemon` → door stayed **active**,
     `/healthz` `status:ok, degraded:true, pigeon:false, anchor:true`; restarting
     pigeon → `degraded:false`. Confirms §7 degrade + `Wants`-not-`Requires` +
     Total-Isolation-healthz.

  **Two live findings (deferred, non-blocking — canary carries no through-door
  traffic):**
  - **F10 (front-door canary forensics target the wrong PID):** the tsx wrapper runs
    TWO processes — MainPID is the tsx *parent* (`node …/tsx/bin/tsx …/main.ts`), but
    the actual `:4700` listener is a *child* (`node --require …/tsx/dist/preflight.cjs
    --import …/tsx/dist/loader.mjs …/main.ts`). The **front-door** canary dumps
    `/proc/$MainPID/…` (parent), not the listener child, so a real listener wedge
    captures the parent's (idle `epoll_wait`) stacks. RECOVERY is unaffected
    (`systemctl restart` kills the whole cgroup). NB (delta F-D7): the *serve* canary
    is NOT affected — its serve units `exec` the bun binary so their MainPID IS the
    listener. (First surfaced because SIGSTOP-ing the parent MainPID left `/healthz`
    answering — the child kept serving.)
    **Fix (Phase-7 task 0) — see the corrected recipe in the Phase-7 blocker list.**
    ⚠️ The originally-recorded recipe `node --import tsx main.ts` is **BROKEN** under
    this packaging (delta F-D1): `tsx` is a bare specifier with no vendored
    `node_modules`, so it won't resolve — it would ship a green build that dies on
    restart. The right fix is compile-to-JS (see below), which also closes F5 + F-D2.
  - Confirms fable **F2**: the initial `/event` probe DID exercise the promoting path
    but wrote no sticky entry (as predicted); the deploy created no sticky state.

  **Execution order used (kept for the record):**
  1. Run `./pkgs/opencode-frontdoor/test.sh` (mandatory pre-rebuild gate, F5).
  2. `sudo nixos-rebuild switch --flake .#cloudbox`; then — because
     `restartIfChanged=false` — **explicitly** `sudo systemctl restart
     opencode-frontdoor.service` to activate the new build.
  3. `/healthz` UP + **version marker matches the just-built store path** (NEW-8).
  4. `probe.sh` **through the door**, diff vs direct-to-serve — **run WITHOUT
     `--mutate`** (a `--mutate` run would drive POST /session → the full
     mint→place→`sticky.record` path; the canary must not create sticky state —
     see the HIGH-2 note below).
  5. `curl -N "$FRONTDOOR/event?session_ids=<sid>"` while triggering a turn (confirm
     the door's SSE path carries events). NOTE (fable F2): `/event` is a *promoting*
     request — through the door it may issue an idempotent `POST /place` to pigeon.
     That is expected and safe (it's what direct clients do); it writes **no sticky
     entry**. Log it, don't be surprised by it.
  6. **Deny-contract-through-door drill (fable Q7):** `curl -i -X PATCH $FRONTDOOR/config`
     → expect `405` + `Allow: GET`; one 403 case (e.g. `POST $FRONTDOOR/global/dispose`).
  7. **Canary self-test drill (fable Q7):** `systemctl kill -s SIGSTOP opencode-frontdoor`
     → expect the frontdoor-canary to restart it within ~3 min + a dump in
     `/var/lib/opencode-frontdoor-canary/`; `SIGCONT`/verify recovery.
  8. **Degrade drill (fable Q7 — tests the `Wants`-not-`Requires` + §7 invariant):**
     stop pigeon ~30s → confirm the door stays up and `/healthz` reports
     `status:ok, degraded:true` (falls back to anchor); restart pigeon.
  9. Optional: reboot once to prove auto-start ordering with a soft-dep pigeon.
  (No PTY smoke-test — PTY is 501, Phase-0.5.) Commit results.

---

## Phase 6 — DONE (2026-07-21 tasks 6.0–6.4; 6.5 deployed live on cloudbox 2026-07-22)

Tasks 6.0–6.4 landed via task-by-task SDD (implement → spec-review → code-review →
fixup), each pushed, then an `adversarial-reviewer-fable` pass over the whole phase.
Commits: `c7e80b0`+`a892d04` (6.0 honest deny 405+Allow/403 + web-ui `/`),
`67bf3aa` (6.1 node/tsx nix package), `e25fb9e`+`2eb36cb` (6.2 system unit +
isolation kit), `95b6330`+`dc4a277` (6.3 serve liveness canary → cloudbox system
units), `f1a4048`+`e049707` (6.4 front-door `/healthz` canary), `096752b` (6.0
fable-F1 table-driven twin coverage). Package: **239 tests green, typecheck clean**;
cloudbox system closure builds.

### Phase-6 fable adversarial passes — findings & disposition
Two passes: (1) the main pass over 6.0–6.4 + design/plan + the 6.5 gate *design*
(F1–F9, below); (2) a **delta pass after the 6.5 live execution** covering the deploy
itself + F10 (findings F-D1…F-D7; verdict: **6.5 canary deploy is sound as-is**, no
gate claim falsifiable, but the F10 *fix recipe* was broken (F-D1) and a "confirmed
sound" SIGTERM claim was wrong (F-D2) — both corrected here; F-D3/D4/D5/D6 folded into
the Phase-7 blocker list). Combined verdict: **safe to deploy as a Phase-6 canary**
(nothing points at `:4700` until Phase 7). Confirmed sound: `allowedMethods` pattern-fallback has no false twins;
tsx runs Node 22; the `/healthz` wedge signal + `--max-time 5 > 3s` coupling;
MemoryMax-only; forensics hygiene; and the sticky map genuinely cannot populate in
Phase 6.
- **CORRECTION (delta pass, F-D2):** the original claim here — "no SIGTERM handler ⇒
  prompt shutdown" — is **false at the runtime level**. The *app* installs no handler,
  but **tsx installs SIGTERM handlers in BOTH the parent CLI and the child** (verified
  live: `SigCgt` bit 14 set on both PIDs; tsx's `preflight.cjs` binds a hidden handler
  in the child). Healthy-path shutdown is still prompt — but because of tsx's internal
  signal *relay*, not kernel-default disposition. Consequences: a genuinely wedged
  *listener child* can't run its handler and recovery rides on the tsx parent's
  ~30ms→forward→~30ms→SIGKILL fallback (a third-party bundler's minified internals are
  load-bearing for SPOF recovery latency); and a wedged *parent* ignores SIGTERM →
  every such restart eats the full `TimeoutStopSec=15s` SIGKILL path (never drilled).
  The compile-to-JS / single-process F10 fix (below) restores kernel-default SIGTERM
  and erases all of this.
- **F1 (HIGH, folded):** the generic twin mechanism yields **six** 405 paths, not the
  3 hand-listed. Added a table-driven test (`096752b`) that derives the expected
  405/403 set from `ROUTE_CLASSIFICATION_TABLE` and pins the six twins.
- **F2 (HIGH reasoning, folded):** the "6.5 gate does only reads" rationale was
  **false** (`/event` promotes → possible `POST /place`; `probe.sh --mutate` mints).
  Corrected the invariant to **"no sticky *writes* in Phase 6"** (`sticky.record`
  only at `proxy.ts:379/587/623` — create/fork/mutating; none hit by the pinned
  gate) and pinned 6.5 to run `probe.sh` **without `--mutate`** (see 6.5 above). The
  HIGH-2 re-scope stands on the corrected invariant.
- **F5 (MED, folded/doc):** the nix build does NOT typecheck — documented `test.sh`
  as the MANDATORY pre-rebuild gate in `default.nix` and step 6.5.1.
- **F3/F4/F6/F7/F8/F9 + gate drills:** deferred to the Phase-7 pre-cutover blocker
  list below (none reachable by canary traffic).

### Phase 7 pre-cutover blockers (fable — MUST resolve before pointing any client at the door)
- **FABLE-P4-HIGH-2 (sticky/lease divergence):** `proxy.ts:587` refreshes sticky TTL
  on every mutating hit with no background lease renewal → a sticky entry can outlive
  pigeon's lease and pin to a stale owner. Fix: on a sticky hit older than ~½ lease
  TTL, fire-and-forget `POST /place` to renew+re-confirm. (Cannot manifest in Phase 6
  — no through-door mutating client traffic.)
- **LOW-2 (invariant, now UNVERIFIED):** `stickyTtlMs`(default 30s, `config.ts:44`) must
  be `≤` pigeon's actual serve-lease TTL. The 30s==30s equality was assumed, **never
  measured in this branch** — measure pigeon's real lease TTL and assert/doc the
  invariant as a Phase-7 entry gate.
- **FABLE-S1 (under-placement):** `checkSidExists` GET to the anchor can block 5–15s
  under load. Preferred fix: a pigeon `/place` sid-validation patch.
- **F3 (`/mcp` misleading Allow):** `POST /mcp` → `405 Allow: GET`, but `GET /mcp`
  reads PER-PROCESS state (FABLE-P5-F2). Resolve with the F2-row decision (deny, or
  per-owner fan-in) — don't advertise a per-process twin. (Of the six twins, only
  `/mcp`'s is per-process; the other five are shared reads.)
- **F4 (front-door canary false-negative):** a door-side sickness (fd exhaustion,
  undici pool wedge) presents as `/healthz` 503 = "backends down", which the no-`-f`
  rule never restarts → silent-forever outage. Fix: on a 503 streak, cross-probe the
  anchor directly; N rounds of "anchor fine directly, door says anchor unreachable"
  ⇒ restart the door.
- **F6 (crash policy):** no `unhandledRejection`/`uncaughtException` handlers; a sync
  throw in a `proxyRequest` event callback crashes the process (all SSE dropped). Add
  at least logging handlers (log + `process.exit(1)` to preserve crash+Restart) and
  decide crash-vs-continue deliberately.
- **F8 (canary tuning): (b)** re-derive serve-canary `THRESHOLD=7` for cloudbox (it's a
  verbatim devbox value citing the devbox g3iy burn); **(c)** verify the cloudbox
  **aarch64** bun binary is ET_EXEC before trusting the eu-stack cross-wedge
  stable-address fingerprint (the claim came from x86 devbox). Re-justify front-door
  `THRESHOLD=2` for a live-traffic SPOF.
- **F10 + F-D1 + F-D2 + F-D3 (single-process the front door — Phase-7 TASK 0):** the
  tsx wrapper runs a parent (MainPID) + a child (the `:4700` listener), which causes
  three coupled problems: (F10) the front-door canary dumps the parent's `/proc`, not
  the wedged listener child's; (F-D2) tsx installs SIGTERM handlers in both processes,
  so a wedged parent eats the full 15s SIGKILL path and recovery latency depends on
  tsx internals; (F-D3) a wedged *parent* while the child serves is INVISIBLE —
  `/healthz` stays 200, the canary never fires, any dump is misleading (`State:
  S(sleeping)`). **Recommended fix — compile to JS at build** (`tsc` emit → run
  `node dist/main.js`): a SINGLE process (MainPID == listener → fixes F10+F-D3),
  kernel-default SIGTERM so a wedged listener dies instantly (fixes F-D2), AND a
  build-time typecheck (fixes **F5**) — three findings closed at once, and it drops the
  tsx runtime dep entirely. **⚠️ Do NOT use the originally-recorded `node --import tsx
  main.ts` recipe (F-D1): `tsx` is a bare specifier, no `node_modules` is vendored, so
  it won't resolve — green build, dead on restart.** If tsx must be retained instead of
  compiling, mirror the child's exact argv with ABSOLUTE store paths
  (`node --require ${tsx}/lib/tsx/dist/preflight.cjs --import file://${tsx}/lib/tsx/dist/loader.mjs …/src/main.ts`;
  pin a comment — `lib/tsx/dist/*` is tsx-internal layout, re-verify on a tsx bump).
  Retest surface: rebuild → explicit restart → re-run 6.5 gate steps 3–8 + `SigCgt`
  bit-14 CLEAR + a SIGSTOP-**MainPID** drill proving `/healthz` goes dark, the canary
  restarts, forensics now capture the listener, and restart latency < 5s.
- **F-D4 (Phase-7 entry gate — real turn through the door):** the 6.5 SSE check used a
  `noReply` message (relay proven, but no LLM turn), so the sticky/drift/mid-turn
  machinery has NEVER run live. Before any client repoints: drive ONE real cheap-model
  turn THROUGH the door (prompt POST through door → sticky recorded → watch
  `/event?session_ids=` through the door across >2 `driftCheckMs`=5s cycles → confirm
  no spurious drop and NEW-H mid-turn suppression). Pairs with the HIGH-2/LOW-2 work
  (same never-run-live machinery).
- **F-D5 (Phase-7 — codify the gate):** `probe.sh` only prints a matrix and exits 0;
  the "only intended deltas" + deny-contract (405 twins / 403) checks were operator
  eyeballing. Add an `--assert` mode (or `gate.sh`) pinning expected through-door
   statuses per class — incl. the **five** 405 `Allow:GET` twins (six→five after T2/F3
   moved `POST /mcp` to the 403 set) + the 403 set already derived table-driven in vitest
   (`096752b`, updated in T2) — exiting non-zero on any delta, so the gate is a
   reproducible regression instrument for the F10-redeploy re-gate and cutover.
- **F8 (canary tuning): (b)** re-derive serve-canary `THRESHOLD=7` for cloudbox (it's a
  verbatim devbox value citing the devbox g3iy burn); **(c)** verify the cloudbox
  **aarch64** bun binary is ET_EXEC before trusting the eu-stack cross-wedge
  stable-address fingerprint (the claim came from x86 devbox). Re-justify front-door
  `THRESHOLD=2` for a live-traffic SPOF.
- **F7/F9/F-D6 (runbook + drift detection):** `Restart=always`+`RestartSec=5` never
  trips systemd's start-limit → a bad env/broken build crash-loops silently (no
  alerting layer). And unit-`Environment` changes / canary-triggered restarts activate
  new state with no gate run. Runbook: always `/healthz` (+ version marker) after every
  rebuild+restart. Cheap automation (F-D6): the canary can compare `/healthz .version`
  against the unit's `ExecStart` store path on each healthy probe and LOG (never
  restart) on mismatch — turning silent version drift into a journal line.

## Phase 7 — Client cutover + infra-plane exemption
[**C1 gate:** Task 1.4 live before 7.3/7.4 drop client `/place`. **STATUS: satisfied**
— scoped promote-once-per-TTL is live in merged `place.ts` (`shouldAttempt`/`record`
+ `checkSidExists`).]

### Phase 7 execution order (SDD) — added 2026-07-22
The fable pre-cutover blockers (see "Phase 7 pre-cutover blockers" above) reshape this
phase: the front door's own correctness/observability holes must be closed, redeployed,
and re-gated **before** any client is repointed at it. Execution splits into two
milestones separated by a live-deploy checkpoint. Worktree: `.worktrees/frontdoor-phase7`
(branch `frontdoor-phase7` off `main`). Every task = implement → spec-review →
code-review → fixup → `test.sh` green → commit; **no `nixos-rebuild switch` until the
deploy checkpoint, and only with explicit user go-ahead.**

**Milestone 1 — front-door code + observability hardening (package + host config; zero client impact):**
_Progress (2026-07-22, branch `frontdoor-phase7`): **T0 ✅ DONE** (`92d834e`), **T1 ✅ DONE**
(`defb4ce` + `13672ac`; FABLE-S1 pigeon patch deferred), **T2 ✅ DONE** (`GET /mcp`→501
per-process-ro, `POST /mcp`→403, twins 6→5). Suite: 247 green, typecheck clean. Not yet
deployed (Checkpoint 1 pending). Remaining: T3, T4, T5._
- **T0 — compile-to-JS single process (F10/F-D1/F-D2/F-D3, closes F5).** Convert
  `default.nix` to build emitted JS (`tsc` emit → wrapper runs `node dist/main.js`),
  dropping the tsx runtime wrapper. Recommended mechanism: `buildNpmPackage` (hermetic
  `npm ci` + `npm run build`), which also makes the nix build **typecheck** (closes F5).
  Add a `build` script (`tsc` with emit; new `tsconfig.build.json` emitting `dist/` from
  `src/` only, no tests). ⚠️ NOT the broken `node --import tsx main.ts` recipe (F-D1).
  Retest surface (at checkpoint): 6.5 gate steps 3–8 + `SigCgt` bit-14 CLEAR on the sole
  PID + SIGSTOP-MainPID drill (`/healthz` goes dark → canary restarts → forensics capture
  the listener → restart < 5s).
- **T1 — sticky/lease renewal + TTL invariant (HIGH-2 + LOW-2 + FABLE-S1 interim).**
  (a) HIGH-2: on a healthy sticky hit whose pigeon lease hasn't been renewed within ~½
  `stickyTtlMs`, fire-and-forget `POST /place` to renew the lease (non-blocking; errors
  logged) so a sticky-pinned session never outlives its lease
  (`proxy.ts:582-593`/`sticky.ts`/`place.ts`). (b) LOW-2 **MEASURED 2026-07-22**: pigeon
  `leaseTtlMs` = **30s** (`~/projects/pigeon` `config.ts:88`, `numOr(env.PIGEON_LEASE_TTL_MS,
  30_000)`, NOT overridden on cloudbox) and frontdoor `stickyTtlMs` = **30s**
  (`config.ts:44`, not overridden) → invariant `stickyTtl ≤ leaseTtl` holds at EQUALITY
  (knife-edge); the HIGH-2 renew-at-½-TTL (15s) keeps the lease alive with margin. Doc the
  invariant in `config.ts` (frontdoor can't read pigeon's config at runtime, so it's
  doc+mechanism, not a cross-check). (c) FABLE-S1 interim (in-repo): fix
  `checkSidExists` (`place.ts:169-190`) so a **timeout / network-error / 5xx** returns
  "place anyway (logged)" instead of the current `if (!result.ok) return false` which
  **silently skips placement** on exactly the 5-15s anchor block the finding is about
  (fail-safe, not fail-open); only a clean **404** (serve reachable, session absent)
  means don't-place. Probe a prospective-owner serve rather than the anchor where one is
  available.
  **FABLE-S1 pigeon-patch DECISION — RESOLVED (defer):** the *preferred* fix (a pigeon
  `/place` "shared-DB existence check") does NOT hold up: pigeon's routing DB
  (`pigeon-daemon.db`) owns only `serve_instance`/`session_assignment`/`session_lease`/
  `routing_meta` — it has **no session-existence data** and never reads opencode's session
  DB (a separate file, `OPENCODE_DB`). A pigeon-side check would therefore either couple
  the control plane to opencode's session schema or do the *same* HTTP probe frontdoor
  already does (just relocating the block). Not cheap, cross-repo, control-plane-critical
  → **defer as a follow-up**; the in-repo interim (fail-safe) closes the acute risk now.
- **T2 — `/mcp` misleading Allow (F3).** `GET /mcp` reads per-process state; stop
  advertising a per-process twin. Resolve the F2-row decision (deny, or per-owner
  fan-in) in `routes.classification.ts`; update the table-driven deny test.
- **T3 — crash policy (F6).** Add `unhandledRejection`/`uncaughtException` handlers
  (log + `process.exit(1)` to preserve crash+Restart); decide crash-vs-continue per site.
- **T4 — codify the gate (F-D5).** `probe.sh --assert` (or `gate.sh`) pinning expected
  through-door statuses per class — incl. the **five** `405 Allow:GET` twins (post-T2) +
  the 403 set (now incl. `POST /mcp`) + `GET /mcp`→501 —
  exit non-zero on any delta. This is the reproducible instrument for the T0-redeploy
  re-gate and the cutover gate.
- **T5 — canary + systemd hardening (F4 + F8 + F7/F9/F-D6).** (F4) front-door canary
  cross-probes the anchor on a 503 streak and restarts the door when "anchor fine
  directly, door says unreachable" for N rounds. (F8b) re-derive serve-canary
  `THRESHOLD` for cloudbox; (F8c) verify the aarch64 bun binary is ET_EXEC; re-justify
  front-door `THRESHOLD=2`. (F7/F9/F-D6) post-rebuild `/healthz`+version runbook; canary
  logs (never restarts on) `/healthz .version` vs `ExecStart` store-path drift. All in
  `hosts/cloudbox/configuration.nix`.

**► DEPLOY CHECKPOINT 1 (requires user go-ahead):** `test.sh` green → build-only verify
(`nix build .#nixosConfigurations.cloudbox.config.system.build.toplevel`) → PAUSE →
`sudo nixos-rebuild switch --flake .#cloudbox` → explicit `systemctl restart` → run the
codified gate (T4) + T0 retest surface + **F-D4 entry gate** (one real cheap-model turn
THROUGH the door: prompt POST → sticky recorded → watch `/event?session_ids=` across >2
`driftCheckMs`=5s cycles → no spurious drop, NEW-H mid-turn suppression holds). Nothing
points at `:4700` yet, so a regression here is contained to the canary.

**Milestone 2 — client cutover (home-manager + scripts; the actual repoint), tasks 7.1–7.8 below.**
Gated on Milestone-1 checkpoint PASS. Each is SDD'd the same way; the deploy vehicle is
`home-manager switch --flake .#cloudbox` (fast, no sudo) except the `configuration.nix`
hardcodes in 7.1 (system rebuild). **► DEPLOY CHECKPOINT 2 (user go-ahead)** after 7.1–7.8
land: verify each client class actually reaches the door and infra-plane clients still
hit the raw anchor.

- **7.1** introduce `OPENCODE_ANCHOR_URL` (raw anchor) + `FRONTDOOR_URL` in
  `home.base.nix`; keep `OPENCODE_URL` unchanged (repointed in Phase 9); fix real
  hardcodes `configuration.nix:485,530`. Commit.
- **7.2** `oc-pool-attach` (+ a `/healthz` reachability idiom replacing
  `ses_poolprobe`; keep `--strict` selfhost bail).
- **7.3** `oc-auto-attach` (drops `/place` — after 1.4).
- **7.4** `opencode-launch`/`opencode-send` (drops `/place` — after 1.4).
- **7.5** `lgtm-sessions` inline (`home.base.nix:1198-1223`) + retarget
  `test-pool-route-clients.sh`.
- **7.6** `opencode-llm-audit`, `my-podcasts`, Telegram launch path.
- **7.7** `serve-distribution-probe.sh` + reset-workspace enrichment.
- **7.8** infra-plane exemption (**now includes pigeon-daemon — NEW-3**): the
  canary, wedge-watcher, reset-workspace per-serve probes, **AND pigeon-daemon's
  own `OPENCODE_URL`** keep the **raw anchor** (`OPENCODE_ANCHOR_URL`). Pigeon is
  the control plane; pointing its fallback at the data plane creates circular
  coupling + a startup cycle. Document + grep-guard. Commit
  `docs(frontdoor): infra-plane + pigeon exemption`.

---

## Phase 8 — opencode-patched: attach → session-scoped event stream (own mini-plan)
Cross-repo epic → its own plan in `opencode-patched`. Move attach `/global/event`
→ `/event?session_ids=<sid>`; remove the TUI's `/route` self-resolve; **jittered
reconnect** (herd). Rollback = hold to previous patched release. Coordinate with
#7/#10/#11/#14/#15. **First-class requirements surfaced by review #3:**
- **NEW-A (backoff reset):** once the door's drop-leg is the *only* migration
  follow path, the TUI's `attempt` counter (which resets **only** on self-detected
  drift and never on a successful open) must be fixed to **reset on a successful
  stream open** — else routine drift-drops inflate the reconnect delay toward the
  ~30 s cap and a turn starting in that window loses early events silently.
- **NEW-B (sibling/child-session events):** a `?session_ids=<sid>` stream drops
  **other sids' events by design** — incl. `session.created/updated` for the
  session list/switcher and **all events of child/subagent sessions** (distinct
  sids). Decide explicitly: fetch-on-demand for lists; include child sids in
  `session_ids`; or accept staleness. (Globals still pass — 0.3.)
- **NEW-G (real tripwire):** there is **no** CI test guard today —
  `build-release.yml` applies patches + smoke-tests but **never runs the suite**;
  the only standing guard is `apply.sh` + the `opencodePatchedHold` pin. Add the
  `/event?session_ids=` tripwire here as genuine new work; "event contract
  LOCKED" means *locked on the current pin*.
- **NEW-P5-F1 (TUI mutating-REST surface — HARD prereq of Phase 9 repoint):**
  Phase-5 fable found the deployed 1.17.13 TUI drives its **entire** mutating-global
  surface through its single attach-URL SDK client (`packages/tui/src/context/
  sdk.tsx`), including **interactive, mid-turn** calls that the front door denies
  405 (`global-sideeffect`): the **bare** `POST /permission/{requestID}/reply`
  (auto-approve replies to *every* `permission.asked` via this bare route —
  `context/sync.tsx`), bare `POST /question/{requestID}/reply|reject`,
  `POST /instance/dispose` (auth-reload flow), `PUT /auth/{providerID}`,
  `POST /mcp/{name}/connect|disconnect`, oauth authorize/callback,
  `experimental.workspace.*`, `POST /experimental/control-plane/move-session`.
  This is harmless **only** while attach bypasses the door; the moment a TUI is
  handed the front-door URL (Phase 9 `OPENCODE_URL` repoint), **permission approval
  breaks** (turn wedged on an unanswerable prompt — the design-§8 "user can't
  control a running turn" failure). The 405 at the door is the correct *mechanism*
  (the door cannot route the bare replies: no sid in path, `requestID→serve`
  unknown to pigeon, pending state in-process), so the fix is **client-side**:
  migrate the TUI to the **session-scoped** reply routes, which already exist and
  are `session-path`-routed — `POST /api/session/{sid}/permission/{requestID}/reply`
  and `POST /session/{sid}/permissions/{permissionID}` — and the TUI has the
  `sessionID` at every call site (`context/sync.tsx`). Do this migration in this
  Phase-8 opencode-patched epic (same repo/release as the event move).

**Gate:** a migrated session's attach TUI survives idle migration hands-off,
**with no reconnect-delay inflation across repeated migrations** (NEW-A), **and
answers a mid-turn permission prompt through the front-door URL** (NEW-P5-F1).

---

## Phase 9 — Full opacity (after Phase 8)

- **9.0** **`OPENCODE_URL` consumer audit** (NEW-4) — grep every consumer
  (shared package defaults `oc-pool-attach:67`, `opencode-launch:16`,
  `oc-auto-attach:28`, `reset-workspace:23,117`, `home.base.nix:1075`; per-host
  env `configuration.nix:485,530`, `hosts/devbox/configuration.nix:290`,
  `home.darwin.nix:124`; crostini gone). Produce a per-site disposition table
  {repoint / anchor / exempt / **host-scoped**}. Specify the host-scoping
  mechanism: **only front-door hosts repoint** (cloudbox now; devbox/darwin when
  they get front doors); doorless hosts keep the raw anchor. reset-workspace's
  `pool_health_urls_from_wants` fallback (`reset-workspace/default.nix:117`) stays
  raw anchor (infra exemption). Commit the audit.
  - **TUI REST-surface disposition (NEW-P5-F1) is a named row in this audit:**
    confirm the Phase-8 TUI migration off the door-denied bare mutating-global
    routes (esp. permission/question replies) actually shipped in the pinned
    opencode-patched release **before** repointing `OPENCODE_URL` on any host —
    otherwise repoint wedges interactive turns. Gate 9.1 on it.
- **9.1** repoint `OPENCODE_URL`→`FRONTDOOR_URL` **per the 9.0 table** (cloudbox
  first). Keep `OPENCODE_ANCHOR_URL` for degrade/infra. Commit.
- **9.2** internalize pigeon `/route`/`/place` — pigeon is already localhost-bound
  (NEW-9), so pick a real mechanism: **require `PIGEON_DAEMON_AUTH_TOKEN`** on
  those routes (front door carries it) + a grep-guard "no non-frontdoor callers"
  test. Commit `feat(frontdoor): make pigeon /route front-door-private`.

---

## Rollout / sequencing
**Phase 0 DONE** (audit executed; one root live-test residual before Phase 2) →
1–5 (scoped **1.4**, health-broken **3.4**, obs **1.6**, node runtime, **Phase 5
now just 501+global policies**) → 6 (**system units**, `restartIfChanged=false`,
`LimitNOFILE`, **ported canary**, version-marked through-door gate) → 7 (client
`/place` kept until 1.4 live; **pigeon exempt**) → 8 (attach move, own mini-plan)
→ 9 (**consumer audit** → repoint → internalize).

**Cross-cutting deps:** crostini removal **DONE** (merged to `main`) — shrinks the
9.0 audit; devbox+darwin front-door convergence is a *follow-on* that reuses this
package (host-scope everything).

## Risks
- Total-outage SPOF → full isolation kit mandatory.
- `/event?session_ids=` hard-deps patch #7 → hold-pin + tripwire; **no `patched.N`
  release cut during Phases 0–8, else re-run the 0.2 probe-diff** (NEW-7).
- **Pre-Phase-2 residual:** the root `ss -K` live re-bootstrap test (Phase 0
  predicted PASS from source; couldn't run headless — `sudo -n` = NO). If it
  FAILS, redesign Phase 2.
- Over-eager promotion (NEW-2) → scoped + TTL-guarded in 1.4.
- **Under-place under load (FABLE-S1):** the `checkSidExists` anchor-GET blocks
  5–15 s on a busy/mid-canary-restart serve → not-routed turn-starts skip placement
  → lease-less turn on the anchor → missed events. Preferred mitigation is the
  pigeon `/place` validation patch (deletes the check). Until then it's a real
  gap on exactly the busy pools placement exists for.
- **Write-degrade-to-wrong-serve (FABLE-S2):** per-request anchor-degrade of
  mutating routes during a pigeon outage → duplicate/wrong-process turns. Mitigated
  only once Task 3.4 lands the write-vs-read split → 3.4 gates deploy.

## Post-Phase-1 fable adversarial review (folded here)
A fable adversarial pass over the built Phase 1 + design/plan **confirmed the
invariants hold** (read-only-except-place, no-retry-after-send, 190/190 table
fidelity, sid extraction vs the real surface) and found policy holes the plan had
encoded. Disposition:
- **FABLE-B1 (fixed in Phase-1 code):** multi-`session_ids` used a raw-URL
  `allSame` check; child/subagent sessions are *never* placed (404→anchor), so a
  legit `parent,child` stream 400'd — worse-than-pre-pool. Fixed to **union of
  real owners only** (not-routed/degraded = "no opinion"; exactly one real owner
  → forward; zero → anchor; ≥2 → 400). This also unblocks Phase-8 NEW-B.
- **FABLE-S5 (fixed in Phase-1 code):** promotion target (`promo.apiBase`) now
  gets the same absolute-http(s)-URL validation the resolver has.
- **FABLE-W2/W4/W6/W7 (fixed in Phase-1 code):** bare `/event` (no `session_ids`)
  → **400 "session_ids required"** not silent anchor (distinct from `/global/event`
  410: that firehose is *gone* from the door; bare `/event` is the supported
  endpoint missing its scoping param); cap multi-`session_ids` fan-out; add
  `GET /doc`→global-ro (else the 6.5 probe-diff trips); HEAD→GET classification.
- **FABLE-B2 → Task 2.2** (drift-evidence rule). **FABLE-S2 → Task 3.4**
  (write-vs-read degrade split; 3.4 now a deploy prerequisite). **FABLE-S3/S4 →
  Task 3.1** (`session/{id}/wait` + `/tui/*`). **FABLE-W5 → Task 4.2** (fork).
- **FABLE-S1 (pigeon-side recommendation):** `place.ts:checkSidExists` does a
  `GET {anchor}/session/{sid}` that production notes say "returns in 20ms or
  blocks 5–15s" on a busy serve → under-place → lease-less turn → yl00-shaped
  missed events. **Preferred fix: a small pigeon `/place` patch** (sid-regex +
  shared-DB existence check in the daemon we own) deletes `checkSidExists`, its
  anchor dependency, and this failure mode. Do before Phase 3. Interim (if not):
  distinguish clean-404 (don't place) from timeout/5xx (place anyway, logged);
  probe the *prospective owner*, not the anchor. See Risks.
- **Note (promotion acquires a real lease):** an SSE-attach promotion runs
  pigeon `ensureRouted`→`placeSession`, which takes a **lease** (pins the session
  vs `reassignFromDeadServe` for the TTL) and feeds `countActiveForServe`
  (attach storms skew bounded-load HRW). Pre-existing, but the door does it far
  more often — state it near Task 1.4 / Phase 6 capacity notes.

## Changes from plan rev 4 (3rd review — GO for Phase 1)
1. **NEW-F:** new **Task 1.0** materializes the enumerated route-classification
   table + `probe.sh` before any routing code (rev-3's `classification.ts`
   deliverable had been reduced to counts).
2. **NEW-E:** Task 1.2 enforces the `^ses_` regex before any `/place` (pigeon's
   `/place` doesn't validate).
3. **NEW-C:** Task 5.2 `/global/event` → **fail-loud 410** (was pass-to-anchor;
   zero consumers, yl00-shaped risk).
4. **NEW-D:** Task 5.2/9.0 web-UI carve-out (web UI is a PTY client, unsupported
   through the door).
5. **NEW-H:** ~~Task 2.2 consults the 3.4 sticky map~~ **(revised by 2nd fable
   pass, FABLE2-B1): moved to Task 3.4** — the SSE-byte active-guard was removed
   from Phase 2 (heartbeats make byte-activity useless); the real active-guard is
   sourced from forwarded-request stickiness in 3.4. Phase 2 drops on confirmed
   drift (TUI parity), safe by the lease invariant. Original note:
   pre-Phase-2 gate PASS criterion sharpened to *eventual consistency*, not replay.
6. **NEW-A / NEW-B / NEW-G:** added to the Phase 8 mini-plan as first-class
   requirements (backoff-reset; sibling/child-session events; the real tripwire).
7. Findings doc corrected: 0.5 method (source = upstream v1.17.13 checkout, not
   the patch-only overlay) + web-UI carve-out; 0.6 backoff-reset nuance.

## Changes from plan rev 3 (Phase 0 findings)
1. **PTY unused (0.5):** Phase 5 collapses to a 501 stub — **no WS proxying, no
   raw tunnel; NEW-1 (bun hijack) MOOT for v1**; runtime a free choice, node kept.
2. **Event contract locked (0.3):** `/event?session_ids=` passes all
   global/lifecycle events → session-scoped stream keeps `server.connected` et al;
   live-only (no cursor). `/global/event` v1 policy = pass-to-anchor-with-log.
3. **Drop-leg premise PASS (0.6, source):** it's the shipped tui-follow-owner
   reconnect-resumes-live behavior; safe because drift is idle-only. One root
   live-test residual noted as the pre-Phase-2 gate.
4. **create→place three-state model (0.4):** Task 1.4 promotes **both** 404-exists
   and prospective; fresh create 404s until placed.
5. Runtime **node** retained but reframed as free (post-Phase-0), not forced.
6. Phase 0 marked EXECUTED; findings at
   `docs/investigations/2026-07-12-frontdoor-route-audit.md`.

## Changes from plan rev 2
1. **NEW-1:** runtime = **node** (bun 1.3.3 raw-hijack verified-broken, silent);
   Task 0.7 confirms the node server-side tunnel; Task 5.1 uses node.
2. **NEW-2:** Task 1.4 promotion **scoped** to stream-establishment / turn POSTs /
   create + at-most-once-per-TTL; drift-timer + casual reads stay read-only.
3. **NEW-3:** pigeon-daemon moved from *cutover* to the **infra exemption** (7.8);
   old Task 7.8 cutover deleted.
4. **NEW-4:** Phase 9 gains **Task 9.0 consumer audit** + host-scoping; 9.1
   repoints per the table (front-door hosts only).
5. **NEW-5:** Task 3.4 stickiness broken by **direct serve health**, not pigeon
   disagreement; refresh-on-activity; runs before resolve/promote.
6. **NEW-6:** Task 6.3 spells out user→system canary deltas + the `BUN_INSPECT`
   gap; narrative fixed to ~7–8 min recovery.
7. **NEW-7:** hold caveat (no `patched.N` during Phases 0–8).
8. **NEW-8:** `/healthz` build/version marker; 6.5 gate checks it.
9. **NEW-9:** Task 9.2 given a real internalization mechanism (auth-gate + guard).
10. Fleet: crostini removed (parallel); devbox+darwin convergence noted as
    follow-on; dependency-free relaxed to a soft preference (node stdlib default).
