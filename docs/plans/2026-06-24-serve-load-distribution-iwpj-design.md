# Serve load distribution: place sessions at creation (concentration fix)

- **Date:** 2026-06-24
- **Status:** Design only (investigation). No code changed; no beads written.
- **Tracking bead:** `workstation-iwpj`
- **Host of investigation:** cloudbox (live pool of 4 `opencode serve`, ports 4096–4099, pigeon on 4731)
- **Scope (recommended):** workstation `pkgs/opencode-launch`, `pkgs/oc-auto-attach` + a new pigeon daemon POST endpoint. Optionally an `opencode-patched` TUI change for the interactive create path (higher rebase cost — see open questions).
- **Companion:** `pigeon/docs/plans/2026-06-24-prospective-route-idle-sessions-design.md` (boi9) — this design fills the gap boi9 explicitly punted on (its "Limitations: never-placed real sessions still fall back to :4096").

---

## TL;DR

The serve-0 concentration is **not** a placement-algorithm bug. HRW placement is
sound and, where it actually runs, spreads sessions evenly (live DB confirms
serve-0 holds the *fewest* routing assignments). The problem is that **the busy
interactive coding sessions never get placed at all**: they are created against
the hard-wired default `OPENCODE_URL=http://127.0.0.1:4096` (serve-0), the
serve-lease guard **fails open** when a session has no assignment row, so the
agent loop runs on serve-0 — and because no assignment row exists, both the
active route and the boi9 prospective route 404, so every attach TUI also falls
back to serve-0.

Placement (`placeSession`, HRW) is only reachable from pigeon's **in-process
control path** (`clientForSession → ensureRouted → placeSession`). The telegram
`/launch` path already uses this to place-at-create and spreads correctly.
External creators (`opencode-launch` CLI, the interactive nvim TUI) have **no way
to trigger placement** because the only HTTP surface, `GET /route`, is
deliberately read-only.

**Recommended fix:** add a pigeon `POST /place` endpoint that runs `placeSession`
for a freshly-created session and returns the owning serve, and change the
external creators to call it *between create and first prompt* (exactly the
pattern `launch-ingest.ts` already uses internally). This keeps pigeon the single
writer of `session_assignment`, avoids mid-run lease kills, and makes boi9 +
lease enforcement + any future admission cap actually function for these
sessions.

---

## Verified root cause

### The placement data path (what writes `session_assignment`)

`session_assignment` is the source of truth for "which serve owns this session."
It is written in exactly **two** places, both inside the pigeon process:

1. `IngressRouter.placeSession()` — `pigeon/.../routing/router.ts:157-237`.
   Picks a serve via HRW over the healthy pool (`pickServe`,
   `rendezvous.ts:18`), applies a bounded-load skip
   (`countActiveForServe(id) < activeTurnCap`, router.ts:174-179) and the
   sticky-router pin (router.ts:182), then `assignments.upsert(...)` +
   `leases.acquireCAS(...)`.
2. `reassignFromDeadServe()` — `router.ts:296-315` (dead-serve recovery only).

`placeSession` is reached only via `ensureRouted` (`router.ts:239-241`:
`resolveRoute ?? placeSession`), which is called only by
`OpencodeClientFactory.forSession` (`routing/client-factory.ts:13-22`), wired in
the daemon as `clientForSession` (`index.ts:72-75`). So **a session gets an
assignment row only when pigeon itself initiates contact with it** (telegram
launch/reply, swarm send, command ingest — every `clientForSession(...)` call in
`index.ts`).

The serve side **never writes** an assignment. `routing-lease.ts`'s `acquire`
only *reads* `session_assignment` and succeeds only if an existing row already
names this serve (`serve-lease.patch:333-352`: `assignmentExists =
assignmentRow && desired_serve_id === this.serveId`).

### The fail-open hole (what runs the turn when there is no assignment)

`withSessionLease` wraps every agent turn (`serve-lease.patch:1510-1587`,
invoked at the run loop, patch:1589-1598). The decisive branch
(`serve-lease.patch:1521-1527`):

```
const acq = await lease.acquire({ sessionId, serveId: self, ... })
if (!acq.ok) {
  if (acq.assignmentExists) {
    return Effect.die(... "session lease held by another instance ...")  // FAIL-CLOSED
  }
  logWarning(`No assignment found for session ${sessionID}. Failing open.`)
  return work                                                            // FAIL-OPEN
}
```

So when a session has **no assignment row**, the serve that received the prompt
runs the turn locally, unconditionally. For a session created on serve-0 that
pigeon never contacts, that serve is always serve-0.

### Why HRW "should spread but doesn't" — it is simply not on the hot path

The hypothesis "assignment = the serve the create request hit" is **false**:
nothing writes an assignment at create time. And "assignment is HRW-by-session-
id, so it should spread" is **true but irrelevant for these sessions** — HRW
(`placeSession`) is never invoked for a session pigeon doesn't contact. The HRW
path works fine where it runs (telegram launches; see below).

### Why boi9 (prospective `/route`) does not catch these

`resolveProspectiveRoute` gates on assignment existence first
(`router.ts:110-113`: `const a = assignments.get(sessionId); if (!a) return
null`). A never-placed session has no assignment → prospective returns null →
`GET /route` 404s (`app.ts:560-565`) → every consumer
(`resolveServeUrl`/`parse_serve_url`) degrades to its `OPENCODE_URL` default =
serve-0. boi9's own design doc flags this exact case under *Limitations*
("Never-placed real sessions … still fall back to `:4096`. Rare …"). The live
evidence shows it is **not rare** — it is the dominant load.

### Where sessions are CREATED (all default to serve-0)

- `opencode-launch` — `pkgs/opencode-launch/default.nix:11`
  (`OPENCODE_URL:-http://127.0.0.1:4096`), `:182` (`POST /session` to
  `$OPENCODE_URL`), `:201-202` (`GET /route` after create → **404, no assignment
  yet** → `serve_url` falls back to `$OPENCODE_URL`), `:238` (`prompt_async` to
  `serve_url` = serve-0). It passively *reads* `/route`; it never *places*.
- `oc-auto-attach` — `pkgs/oc-auto-attach/default.nix:28` (default
  `:4096`), `:250-252` (`parse_serve_url` → fallback `:4096`). Attach-only; for
  an unplaced session it attaches the TUI to serve-0.
- Interactive nvim TUI — `assets/nvim/lua/user/oc_auto_attach.lua:49-56` runs
  `opencode attach <serve_url> --session <sid>`; the TUI re-resolves the owner on
  each SSE (re)connect (`attach-route-resolve.patch` `sdk.tsx`, `route.ts`), but
  **new sessions created inside an attached TUI POST to whatever serve the TUI is
  connected to**, with no placement step.

### Live evidence (cloudbox, 2026-06-24)

Connections / child processes per serve (`ss`, `pgrep`):

| serve | port | ESTABLISHED conns | direct children |
|---|---|---|---|
| serve-0 | 4096 | **34** | **14** (12 npm/LSP + 2 node) |
| serve-1 | 4097 | 0 | 0 |
| serve-2 | 4098 | 0 | 0 |
| serve-3 | 4099 | 8 | 2 (lua-language-server) |

Routing assignments per serve (pigeon-daemon.db snapshot; all 4 serves healthy,
`binary_epoch=0`, heartbeats fresh):

| serve | assigned | dormant |
|---|---|---|
| serve-0 | **1** | **0** |
| serve-1 | 3 | 23 |
| serve-2 | 2 | 118 |
| serve-3 | 2 | 58 |

Total 207 assignments. **The serve carrying ~all live compute and connections
holds the fewest routing assignments.** That is the signature of off-book
fail-open sessions: the busy work on serve-0 is invisible to the routing tables
because nothing ever placed it. (Conversely, the assignments that *do* exist —
pigeon-contacted sessions — are spread across serve-1/2/3 by HRW, confirming the
algorithm is healthy. The exact dormant skew across 1/2/3 is historical and not
fully explained; it does not affect the conclusion.)

### The contrast that proves the fix shape: telegram `/launch` already works

`ingestLaunchCommand` (`worker/launch-ingest.ts:59-63`) does the right thing:

```
const session = await opencodeClient.createSession(directory);  // create on serve-0
const owner = input.resolveOwnerClient?.(session.id) ?? opencodeClient;  // HRW place
await owner.sendPrompt(session.id, directory, prompt);          // first turn on owner
```

`resolveOwnerClient` is wired to `clientForSession` (`index.ts:142`), so calling
it *places* the session (HRW) before the first prompt, and the first turn runs on
the assigned serve — which then `acquire`s the lease cleanly (assignment matches
serve). This is precisely the pattern the external creators are missing.

---

## The core gap

> **Placement is reachable only from inside the pigeon process. External session
> creators have no HTTP verb that places a session.** `GET /route` is read-only by
> design (pigeon-eup: a placing GET manufactured phantom routes for stale sids).

Every fix below is, at bottom, about closing this gap for the external-creator
paths without reintroducing phantom routes and without breaking the single-writer
invariant on `session_assignment`.

---

## Options

### (a) Place the session at creation  — RECOMMENDED

Give external creators an explicit, deliberate placement call and route the first
turn (and the attach) to the returned owner — the `launch-ingest` pattern,
generalized.

**Mechanism**

1. New pigeon endpoint `POST /place` (auth-protected like the other mutating
   routes, `auth.ts:8`):
   - body/query: `session_id` (a real, just-created sid).
   - runs `router.ensureRouted(sid, now)` (i.e. `resolveRoute ?? placeSession`) —
     writes the assignment + lease via HRW, returns the `RouteResult`
     (`apiBase`, `serveId`, …).
   - Safe re: pigeon-eup because it is an explicit POST tied to a real session
     the caller just created — not a speculative GET on an arbitrary sid. (We can
     additionally gate on `storage.sessions.get(sid)` existence to refuse
     placing a phantom.)
2. Creators call it **between create and first prompt**, then send the first
   prompt / attach to the returned `apiBase`. Fall back to `:4096` on any failure
   ("never worse than single-serve").

**Per-creator change**

- `opencode-launch` (`pkgs/opencode-launch/default.nix`): after `POST /session`
  (`:182`), `curl -X POST $PIGEON_DAEMON_URL/place -d session_id=$id`, parse
  `.apiBase` into `serve_url`, then send `prompt_async` there (`:238`). Replaces
  the passive `GET /route` at `:201-202` (which 404s pre-placement) with an
  active place. ~5 lines.
- Telegram `/launch`: already correct (no change).
- Interactive nvim TUI new-session: the create-then-first-prompt happens inside
  the TUI's own client, pointed at the connected serve. Two sub-options:
  - **(a-i) Patch the TUI** so that on session create it calls `/place` and, if
    the owner differs, rebuilds the SDK client (the SSE loop already re-resolves;
    the *submit* client must move too). Highest leverage (interactive coding is
    the bulk of the load) but an `opencode-patched` change → rebase cost.
  - **(a-ii) Out-of-band placer.** `oc-auto-attach` already runs for launched
    sessions; extend the auto-attach trigger to also fire for interactive creates
    and `POST /place` before attaching. Smaller blast radius, but only helps
    sessions that flow through auto-attach.

**Why this is the right shape**

- Single writer preserved: only pigeon writes `session_assignment`.
- No mid-run kill: placement happens before the first turn, so the turn runs on
  the assigned serve and `acquire` matches (no fail-closed "lease held
  elsewhere"). Placing *after* a turn starts would bump `owner_generation` and
  kill the in-flight run (`router.ts:299-312` documents exactly this hazard).
- Makes everything downstream work: assignment exists ⇒ active `/route` resolves,
  boi9 prospective resolves, lease enforcement engages, `countActiveForServe`
  (admission) finally sees the load.

**Cost / blast radius**

- Pigeon: one new endpoint reusing `ensureRouted` (small, well-tested core).
- Workstation: `opencode-launch` (small), optionally `oc-auto-attach` (small).
- TUI interactive path: optional `opencode-patched` change (medium; rebase cost
  on every opencode bump). Can be deferred — CLI + launch coverage alone removes
  a large fraction of off-book load.

### (b) serve-lease REBALANCE (migrate assigned-but-idle sessions off a hot serve)

Pigeon periodically moves sessions off an overloaded serve; the TUI reconnect
loop follows `/route` to the new serve.

**Why it is weak here**

- **Blind to the actual load.** The hot sessions on serve-0 have *no assignment
  row* (that is the whole problem), so a rebalancer that operates on
  `session_assignment` cannot see them. It would need a *new* off-book discovery
  mechanism (e.g. poll each serve's `GET /session`, or read the plugin's
  registered `backend_endpoint`) before it could act.
- **Cannot touch the busy ones safely.** The compute on serve-0 is *active*
  turns. Migrating an active session yanks its lease and kills the run
  (`router.ts:299-312`). Rebalancing only *idle* sessions does nothing for the
  live event-loop pressure that causes the stall.
- Adds a continuously-running control loop (more moving parts, more failure
  modes) for a strictly worse outcome than fixing creation.

Verdict: not recommended as the primary lever. (A *bounded* idle re-pick could be
a minor future complement once (a) is in place and assignments exist for all
sessions.)

### (c) pigeon admission cap (refuse > N sessions on one serve)

Pigeon already has the cap primitive: `placeSession` skips serves at/over
`activeTurnCap` (default 25, `config.ts:78`; `countActiveForServe`,
`route-repo.ts:266-271`).

**Why it is a refinement of (a), not an independent fix**

- The cap counts only `state='assigned'` assignment rows. Off-book fail-open
  sessions are not rows, so the cap is **blind** to the real serve-0 load.
- Pigeon has **no admission point at creation today** — creators POST to `:4096`
  directly. There is nothing for a cap to gate until creation is routed through
  pigeon, i.e. until (a) exists.

Verdict: do (a) first; then optionally make the creation-serve choice
load-aware (least-loaded / live-conn-weighted, not just assignment-count) so the
cap reflects reality. Fold into (a), do not pursue standalone.

---

## Recommendation

**Adopt option (a): place-at-creation via a new pigeon `POST /place`, with the
external creators calling it between create and first prompt.** Sequence the
rollout by leverage-vs-cost:

1. **Phase 1 (low cost, high value):** `POST /place` in pigeon + `opencode-launch`
   change. Removes off-book concentration for all CLI/launch-created sessions and
   validates the endpoint. No `opencode-patched` release.
2. **Phase 2 (decide after Phase 1):** cover the interactive TUI create path —
   either (a-i) TUI patch or (a-ii) auto-attach placer — guided by how much of
   the residual serve-0 load is interactive vs launched (measure after Phase 1).
3. **Phase 3 (optional):** make pigeon's creation-serve choice load-aware (fold
   in (c)); revisit a bounded idle rebalance (light (b)) only if needed.

Rationale: (a) is the only option that attacks the actual root cause (sessions
never being placed), preserves the single-writer invariant and the
never-worse-than-single-serve fallback, avoids mid-run lease kills, and turns the
already-built machinery (HRW, boi9 prospective, lease enforcement, admission cap)
from dormant into effective. (b) and (c) are structurally downstream of (a).

---

## Exact files / functions to change (recommended path)

Pigeon (`~/projects/pigeon/packages/daemon/src`):
- `app.ts` — add `POST /place` handler near the `GET /route` block (`:541-567`);
  call `options.router.ensureRouted(sid, now)`; optional `storage.sessions.get`
  existence gate; return the `RouteResult`. Protect via `auth.ts` (extend the
  mutating-method guard, `auth.ts:8`).
- `routing/router.ts` — no change to `placeSession`/`ensureRouted` needed; reuse
  as-is. (Optional Phase 3: load-aware candidate ordering in `placeSession`.)
- Tests: `test/routing/route-endpoint.test.ts` (new `POST /place` cases),
  `test/routing/router.test.ts` (placement idempotency / generation behavior).

Workstation:
- `pkgs/opencode-launch/default.nix` — between `POST /session` (`:182`) and
  `prompt_async` (`:238`), `POST $PIGEON_DAEMON_URL/place`, parse `.apiBase` →
  `serve_url`; degrade to `$OPENCODE_URL` on any failure. Update the
  `parse_serve_url` usage comment.
- (Phase 2, a-ii) `pkgs/oc-auto-attach/default.nix` — optional `POST /place`
  before the Step-0 `GET /route` (`:250`) when invoked for a fresh session.

opencode-patched (only if Phase 2 a-i chosen):
- `packages/tui/src/context/sdk.tsx` / `packages/tui/src/util/route.ts` — on
  session create, `POST /place` and rebuild the submit client if the owner
  differs (the SSE re-resolve at `attach-route-resolve.patch` already follows for
  events; the control/submit client must follow too).

---

## Test strategy

- **Pigeon unit (vitest):** `POST /place` writes an assignment + lease via HRW;
  is idempotent for an already-placed session (returns the active route, no
  generation bump); 400 on bad sid; 404/refuse on a non-existent session (phantom
  guard); 503 when no healthy serve; auth enforced.
- **Pigeon integration:** place N synthetic sessions → assert near-even
  distribution across the healthy pool; place while one serve is unhealthy →
  lands on a healthy serve.
- **opencode-launch (`test-*.sh` harness):** with pigeon up, the resolved
  `serve_url` for the first prompt equals the placed owner; with pigeon down /
  `POST /place` failing, it degrades to `$OPENCODE_URL` (never-worse).
- **End-to-end on cloudbox (manual, post-deploy):** launch ~8 sessions via
  `opencode-launch`; assert ESTABLISHED conns and LSP children spread across
  4096–4099 (today: all on 4096), and that `session_assignment` now contains a
  row per launched session on its running serve.
- **Lease regression:** confirm a placed-then-prompted session never hits
  "session lease held by another instance" (placement precedes the first turn).
- **boi9 interaction:** a freshly placed session's `GET /route` now returns the
  active route (not 404), and after it idles, the boi9 prospective route names
  the same HRW serve.

---

## Interaction with boi9 and the never-worse principle

- **Complements boi9, does not conflict.** boi9 spreads *idle* sessions that
  already have an assignment; (a) ensures *all* sessions get an assignment in the
  first place. Together: new sessions are placed (spread compute), idle attaches
  follow the prospective owner (spread streams).
- **Single-writer preserved.** `POST /place` calls the same `ensureRouted →
  placeSession` core; pigeon remains the only writer of `session_assignment`. No
  serve-side assignment writes are introduced (avoids the multi-writer race the
  CAS ladder in `route-repo.ts:297-337` is built to prevent).
- **Never worse than single-serve.** Every creator keeps its `:4096` fallback on
  any `/place` failure (pigeon down, no healthy serve, timeout). The fix can only
  improve distribution, never strand a creator.
- **Serve-lease coupling unchanged.** Because placement now precedes the first
  turn, the common path is `acquire` *succeeds* (assignment matches the running
  serve) rather than fail-open. The fail-open branch remains as the safety net for
  the unconfigured-pool / pigeon-down case.

---

## Open questions (need a human decision)

1. **Interactive-TUI create path: patch the TUI (a-i) or stay out-of-band
   (a-ii)?** This is the highest-leverage but highest-cost piece. The TUI patch
   gives complete coverage but adds an `opencode-patched` rebase liability on
   every opencode bump; the auto-attach placer is cheaper but only covers
   sessions that flow through auto-attach. **Recommendation:** ship Phase 1
   (CLI + endpoint) first, *measure* the residual interactive load on serve-0,
   then decide. — Needs a call on appetite for TUI patch maintenance.
2. **Does `POST /session` accept a caller-supplied session id?** If yes, the
   clean flow is "generate id → `POST /place` → create on the chosen serve" (no
   create-on-:4096 + move). If no (current assumption: server generates the id),
   we must create first then place — which is fine because the create is just a
   shared-DB insert with no agent loop, so creating on `:4096` costs nothing; the
   heavy compute (first prompt) goes to the placed owner. *opencode source is not
   checked out here (only patches), so this needs verification against the
   upstream `POST /session` handler.*
3. **Should the creation-serve choice be load-aware now, or pure HRW first?**
   Pure HRW is simplest and already spreads ~evenly; a least-loaded / live-conn-
   weighted choice (folding in option (c)) is more robust under skew but needs a
   real load signal beyond `countActiveForServe` (which is assignment-count, not
   live turns/conns). **Recommendation:** ship pure HRW in Phase 1, add
   load-awareness in Phase 3 only if measured skew warrants it. — Needs a call on
   whether to invest in a live-load signal.
