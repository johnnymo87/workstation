# Opaque serve-pool reverse proxy — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task. Companion design:
> `docs/plans/2026-07-12-serve-reverse-proxy-design.md` (revision 2).
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
Phase 0 is resolved.

---

## Phase 1 — Forwarder core (node)

### Task 1.1: Scaffold (node, minimal deps)
`package.json` (vitest devDep), `tsconfig.json`, `vitest.config.ts`,
`src/config.ts` (`port`, `pigeonUrl`, `anchorUrl` from `OPENCODE_ANCHOR_URL`,
optional `pigeonAuthToken`, `routeTimeoutMs=3000`, `cheapFirstByteMs=5000`,
`stickyTtlMs=30000`). TDD defaults. Commit `feat(frontdoor): scaffold (node)`.

### Task 1.2: sid extraction (TDD)
`src/sid.ts`. Path / query (`session_ids`, `session`) / create→null /
malformed→null. **Multi-value `session_ids`:** single→route; same-owner→route;
mixed-owner→400. Commit `feat(frontdoor): session-id extraction`.

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

## Phase 2 — Event streams (SSE + drop-leg-on-drift)  [0.6 PASS by source; run the root live-test first]

- **2.1** `src/sse.ts` unbuffered pass-through, survives 10 s heartbeat. Commit.
- **2.2** confirm-twice re-resolve timer (**read-only**, no promote — NEW-2); on
  drift **close the client leg** (no silent re-dial — C2). Assert clean close +
  no re-dial. Commit `feat(frontdoor): drop SSE leg on drift`.

---

## Phase 3 — Health / failover + stickiness

- **3.1** endpoint-class first-byte timeout (`src/timeouts.ts`): cheap GET / SSE
  handshake = **time-to-response-headers** → 503; turn POSTs = no first-byte
  timeout. Commit.
- **3.2** wedge health-probe for turn POSTs: probe target `/global/health`; 503
  only on probe failure. Commit.
- **3.3** native `/healthz` (`src/healthz.ts`): 200 iff loop live AND (pigeon OR
  anchor reachable); report `degraded` + counter + **build/version marker**
  (store path / hash — NEW-8, closes the `restartIfChanged=false` staleness gap).
  Never proxies. Commit.
- **3.4** **corrected** per-sid stickiness (`src/sticky.ts`) — fixes M5/NEW-5:
  map `{sid→lastForwardedServe, expiry}` **refreshed on every forwarded request
  and observed SSE activity**; break stickiness **only when the sticky target
  fails a direct `/global/health` probe** (reuse 3.2), NOT when pigeon merely
  disagrees (pigeon persistently disagrees during a lease-less turn — that's
  exactly when we must stay stuck). Sticky check runs **before** resolve/promote.
  TDD the abort-follows-the-runaway-turn case explicitly. Commit
  `feat(frontdoor): health-broken short-TTL stickiness`.

---

## Phase 4 — create → /place → respond
- **4.1** `POST /session`→forward to anchor→parse `.id`→`POST /place`→return
  create response only after place; place-fail→return+degrade+log. No serve
  choice (pigeon HRW). Concurrent-create + serve-dies-mid-choreography tests.
  Commit `feat(frontdoor): create->place`.

---

## Phase 5 — /global/* + PTY policies  (**collapsed — PTY unused, Phase-0.5**)

- **5.1** PTY → **501 + log, out-of-scope for v1** (Phase 0.5 proved the deployed
  TUI/clients never construct `/pty/*`). **No WebSocket proxying, no raw tunnel,
  no bun-vs-node WS concern in v1.** Documented future: if a client ever adds
  PTY, revisit with a node raw duplex tunnel (node verified; bun 1.3.3's hijack
  silently fails — audit findings §0.5/§0.7). TDD the 501 branch. Commit
  `feat(frontdoor): PTY 501 (out of scope v1)`.
- **5.2** `/global/dispose|upgrade`→deny(405)+log; `/global/event`→pass-to-anchor
  with loud "legacy firehose" log (Phase 0.3 decision; the deployed TUI streams
  `/global/event` directly + self-resolves around the door until Phase 8, so this
  path is a legacy bridge); unrecognized→404-loud. Commit
  `feat(frontdoor): global + unrecognized policies`.

---

## Phase 6 — Nix packaging + **system** units + canary (cloudbox)

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
- **6.4** front-door canary on `/healthz` (system unit). Commit.
- **6.5** **deploy + through-front-door gate** (M2): `/healthz` UP + **version
  marker matches the just-built store path** (NEW-8); run `probe.sh` **through
  the door** and diff vs direct-to-serve; `curl -N "$FRONTDOOR/event?session_ids=<sid>"`
  while triggering a turn (confirm the door's SSE path carries the events).
  (No PTY smoke-test — PTY is 501, Phase-0.5.) Commit results.

---

## Phase 7 — Client cutover + infra-plane exemption
[**C1 gate:** Task 1.4 live before 7.3/7.4 drop client `/place`.]

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
→ `/event?session_ids=<sid>`; preserve Task-0.5 non-session events; remove the
TUI's `/route` self-resolve; add tripwire; **jittered reconnect** (herd). Rollback
= hold to previous patched release. Coordinate with #7/#10/#11/#14/#15.
**Gate:** a migrated session's attach TUI survives idle migration hands-off.

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
