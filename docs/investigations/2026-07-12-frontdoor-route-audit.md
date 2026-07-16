# Front-door Phase 0 audit — deployed-line findings

**Date:** 2026-07-12 (executed on live cloudbox; opencode-patched **v1.17.13**,
`~/projects/opencode-patched` @ `fd7712f`).
**Feeds:** `docs/plans/2026-07-12-serve-reverse-proxy-plan.md` (rev 4).
**Method:** live serves (`:4096-4099` healthy), OpenAPI at `GET /doc`, and the
deployed patch set in `~/projects/opencode-patched/patches/` (NOT
`~/projects/opencode` HEAD).

## Environment
- node **v22.22.2**; bun **1.3.3**. `ss` present with `CONFIG_INET_DIAG_DESTROY`.
- **`sudo -n` = NO** — the root `ss -K` socket-kill for the 0.6 live test cannot
  run headless; 0.6 answered by source + a non-root observation (see 0.6).
- opencode-patched cloned at `~/projects/opencode-patched` @ v1.17.13.

## 0.1 Route table snapshot
`GET /doc` = OpenAPI 3.1, 478,546 bytes. Dual surface: legacy bare
(`/session/{sessionID}/…`, `/event`, `/global/event`) + `/api/*` effect surface.

## 0.2 Classification (from /doc + patches)
- **40** paths carry `{sessionID}` in the path → `session-path`.
- **`session-query` is UNDECLARED in /doc** — `/doc` declares *no* session query
  param anywhere; `?session_ids=` comes only from patch #7 (§0.3). **Confirms M1:
  classify from patches, not `/doc` alone.**
- **PTY:** 9 routes (`/pty*`, `/api/pty*`) incl. `…/connect` (WS upgrade) — but
  **unused** (§0.5).
- **`/global`:** `config` (ro), `health` (ro), `event` (firehose), `dispose` +
  `upgrade` (per-process side-effects → deny).

## 0.3 Event-stream contract — RESOLVED (source: `patches/event-session-scope.patch`)
`GET /event?session_ids=a,b` adds a `Stream.filter`:
- keeps events whose `event.data.sessionID` ∈ the set;
- **events with no string `sessionID` (global/lifecycle: `server.*`) ALWAYS
  pass** — including `server.connected`;
- empty `session_ids=` blocks all *session* events but still passes globals;
- a non-existent sid yields only globals.
The patch ships upstream-style tests asserting exactly this. **Live-only:** no
SSE `id:`/Last-Event-ID cursor — the event id rides *inside* the `data` JSON
(`{id,type,properties}`); a dropped stream loses nothing only if the reconnect
resumes live with no gap (§0.6). Implication: a session-scoped `/event` stream
still carries the lifecycle events the TUI needs — the move off `/global/event`
does **not** starve it of globals.

## 0.4 create → /place → route — RESOLVED (live)
Three distinct `/route` states (matters for Task 1.4):
1. **never-placed** → `404 {"error":"session not routed"}` (fresh create).
2. **leased** → real route (`prospective:null`, `expiresAt` set).
3. **idle (placed, lease expired)** → `prospective:true, expiresAt:0` (HRW guess).
Live trace: `POST /session` → `/route` **404** → `POST /place` → `{ok, serve_id:
serve-0, api_base, expires_at}` → `/route` now resolves. So the front door must
place-after-create (Phase 4), and Task 1.4 must promote **both** state 1
(404-but-confirmed-exists) and state 3 (prospective) — narrowly (§NEW-2).

## 0.5 PTY usage — UNUSED (source: exhaustive grep of opencode-patched)
No client/TUI code constructs `/pty/*` URLs (`rg` finds pty only in README prose;
`packages/tui` has zero pty refs). **The deployed TUI does not use PTY.**
Consequences:
- **Phase 5.1 = 501 stub** (PTY out of scope for v1).
- **NEW-1 (bun 1.3.3 broken raw socket hijack) is MOOT for v1** — no WebSocket
  proxying is needed at all. Runtime is therefore a *free* choice; **node
  retained** as the safe default (bun's plain HTTP+SSE proxying is fine, but node
  costs nothing and dodges the WS landmine if a future client adds PTY).

## 0.6 Premise — TUI reconnect heals a dropped SSE leg — PASS (source), live-test pending
Source (`patches/tui-follow-owner.patch`, `patches/bootstrap-disposed-filter.patch`):
- The deployed TUI streams **`/global/event`** (per-process firehose) and runs
  its OWN `/route` drift-poll: on a confirmed owner change it **ends the SSE
  attempt and reconnects to the new owner, resetting backoff — resume-live, NOT
  re-bootstrap** (`sdk.tsx`: `result.drifted → attempt=0; continue`). This is the
  *shipped, accepted* yl00 fix.
- `runSseAttempt` is a `while(true)` reconnect loop; a server-initiated close
  (what the front door will do on drift) ends the attempt → loop → reconnect.
- Full re-sync (`bootstrap()`) fires **only** on `server.instance.disposed`
  (debounced 250 ms), not on ordinary reconnect.
**Conclusion:** the Phase 2 "drop the client leg on drift" mechanism is exactly
what tui-follow-owner already does (relocated into the front door). It is safe
because **drift is idle-only** (lease invariant) → no in-flight events to miss on
the gap. **Residual:** a non-idle gap would not re-bootstrap (acceptable; drift
is idle-only). **Caveat:** the definitive live confirmation is a root `ss -K`
socket-kill + gap-injection, which could not run (`sudo -n` = NO) — recommend one
manual root run before Phase 2 code, but source strongly supports PASS.

## 0.7 node duplex tunnel — moot for v1 (PTY unused)
node 22 present; the 2nd review already verified node server-side hijack works
and bun 1.3.3 silently fails. Not on the v1 path (§0.5). Runtime = node.

## 0.8 Packaging — node stdlib, dependency-free thin wrapper (unchanged)

## Net effect on the plan (rev 4)
- **Phase 5 collapses:** PTY unused → 501 stub; **no WS tunnel, NEW-1 moot**.
- **Phase 2 unblocked** (0.6 PASS, with a one-time root live-test noted).
- **Event contract locked** (globals-always-pass — session-scoped stream keeps
  lifecycle events).
- **Task 1.4** promotes both `404-but-exists` and `prospective` states.
- Runtime **node** retained (now a free choice, not forced).
