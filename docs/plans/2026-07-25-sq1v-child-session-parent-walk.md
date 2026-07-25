# sq1v — front door: route child (subagent) sessions to their parent's serve

**Bead:** `workstation-sq1v` (P1, LIVE) · **Closing-plan item 1 of 5**
(`2026-07-24-frontdoor-remaining-roadmap.md`)
**Status:** design reviewed by adversarial-reviewer-fable 2026-07-25 —
**SOUND WITH ADDITIONS**; all findings folded in below.

## Problem (see bead for the full verified analysis — not re-derived here)

A subagent session is minted *inside* the owning serve by the Task tool and never
goes through pigeon's placement flow. It therefore has no assignment, pigeon
`/route` 404s, and the door degrades the request to the anchor (`resolve.ts:49-58`)
instead of the parent's serve. Subagent permissions/questions are keyed by the
CHILD sessionID, so `POST /session/{child}/permissions/{id}` lands on the wrong
process unless the parent happens to own the anchor (~1 in 4 with a 4-serve pool).

## Verified premises (re-checked live 2026-07-25, this box)

| # | Premise | Evidence |
|---|---------|----------|
| P1 | `GET /session/{sid}` on the anchor returns `parentID` for a child | live: `ses_0dc429…` → `parentID: ses_0de5f3…`; field is `parentID` on the wire, `parent_id` in opencode.db |
| P2 | pigeon `/route` 404s for any sid with no assignment; door then degrades to anchor | `router.ts:110-113`, `app.ts:607-609`, `resolve.ts:49-58`; live 404 for the child above |
| P3 | pigeon `placeSession` is HRW over the healthy pool with **no parent awareness**, and has no "pin to this serve" API at all | `router.ts:157-181`; `/place` → `ensureRouted` `app.ts:552-564` |
| P4 | children are ubiquitous but almost never *placed* | opencode.db: **4219 children / 7958 sessions**; pigeon: **1** child holds its own assignment (of 366) |
| P5 | `/event?session_ids={one-child}` is a **promoting** request | `sid.ts:67-68` → `kind:"single"`; `place.ts:100` → `isPromotingRequest` true → `maybePromote` would `placeSession(child)` |
| P6 | **parentage is immutable on the DEPLOYED rev** (`opencode-patched-1.17.13.4`) | live probe on a throwaway session: `PATCH /session/{id}` with `parentID` applied the title and **silently ignored `parentID`**; `POST /session/{id}/fork` returned `parentID: None` → **forks are roots, not children**. (Fable's C1/C2 were verified against `~/projects/opencode`, which is **1.15.10** — two minors behind; re-verified here against the deployed binary.) |

P4 + P5 are load-bearing: the harm today is **mis-resolution**, not mis-placement —
but placement, when it fires, writes a durable HRW assignment for the child, after
which `/route` 200s and a 404-triggered parent-walk **never runs again for that
session**. A routing fix alone is therefore silently defeatable.

## Design

### Core: parent-walk inside `resolveOwner` (resolve.ts)

`ResolvedOwner` gains:

```ts
/** sid that pigeon lease ops (place / lease renewal) must use = ROOT of the tree.
 *  null  => parentage UNKNOWN (walk failed) => MUST NOT be placed. */
routingSid: string | null;
/** owner came from an ancestor's route (logging/metrics) */
viaParent?: boolean;
/** the walk got a 200 for routingSid, so maybePromote can skip checkSidExists */
rootExists?: boolean;
```

Resolution order:

1. `GET /route?session_id={sid}` → **200** → as today; `routingSid = sid`.
2. **404** → `rootOf(sid)`:
   - cache hit → root;
   - miss → `GET {anchor}/session/{sid}` → read `parentID`, repeat upward.
     Bounded at **depth 8**, visited-set cycle guard, and **one overall walk
     deadline** (not 8 × `routeTimeoutMs`) — LOW-3.
3. **parentage unknown** (any walk failure) → anchor, `degraded`, reason
   `not-routed`, **`routingSid = null`** (HIGH-1 — see below).
4. `root === sid` (confirmed root) → today's behavior: anchor, `degraded`, reason
   `not-routed`, `routingSid = sid`, `rootExists = true`.
5. `root !== sid` → `GET /route?session_id={root}`:
   - 200 → that owner, `routingSid = root`, `viaParent = true`, reason
     `active`/`prospective`;
   - 404 → anchor, `degraded`, reason `not-routed`, `routingSid = root`;
   - **error → propagate the root lookup's actual reason** (`pigeon-unreachable` /
     `pigeon-error`), *not* `not-routed` (MEDIUM-1 — flattening would let a
     mutating child request slip past the FABLE-S2 503 guard at `proxy.ts:637-641`
     during a pigeon blip).

**HIGH-1 — walk failure must be non-placeable.** Failing open to "today's
behavior" is *not* safe here: today's behavior on the promoting path is
`checkSidExists(child)` → `placeSession(child)` (`place.ts:246-259`) → a durable
arbitrary-HRW assignment (`router.ts:181`). So a single anchor timeout coinciding
with one promoting child request would permanently pin that child to a random
serve — and post-defeat it resolves *confidently* (`degraded:false`), so FABLE-S2
won't 503 its mutations and drift will drop legs toward the wrong owner. Strictly
worse than today. Hence `routingSid = null` ⇒ `maybePromote` and lease renewal
both decline. This deliberately flips `checkSidExists`'s fail-open-toward-placing
stance (`place.ts:183-194`) for this sub-case; the cost is that an idle root's
placement is delayed while the anchor is down, which is acceptable because the
anchor is also the fallback forwarding target.

**Why inside `resolveOwner`.** Four call sites share it — proxy single-sid
(`617`), multi-sid (`664`), `handleFork` (`414`), drift (`drift.ts:100/105`) — so
one change covers all four. Note the justification is **not** SSE flapping:
`drift.ts:102` maps any `degraded` result to `currentOwner` ("no signal"), so an
unshared fix would produce *zero* flaps. The real hazard is the opposite —
call-site-only would leave drift **permanently blind** on child legs, so when the
root genuinely migrates the child's SSE leg is never dropped and goes silently
stale on the old serve.

### Cache (`rootOf`)

Parentage is immutable (P6), so *confirmed* results cache **permanently**:

- `200` + `parentID` → cache `sid → root`
- `200`, no `parentID` → cache `sid → sid` (this negative caching matters: most
  not-routed sids are idle **roots**, and without it every such request repeats
  the anchor GET)
- `404` / non-200 / network error / timeout → **short TTL ≈ 30s**, not permanent
  and not uncached (LOW-3: an uncached error path makes a drift monitor on a
  deleted sid pay `/route` 404 + anchor GET every 5s forever, and makes a wedged
  anchor add up to `routeTimeoutMs`=3000ms to every not-routed resolve, sustained)

Bounded Map, cap **2000**, **FIFO** insertion-order eviction — *not* LRU, since
`Map.set` on an existing key does not refresh insertion order (LOW-4; do not call
it LRU in code or comments). Per-process; lost on door restart, re-warmed lazily
(cold-restart herd is ~10² by-id sqlite reads on loopback — a non-issue).

### Cost

| Path | Pigeon calls | Anchor calls |
|------|--------------|--------------|
| routed sid (happy path) | 1 (unchanged) | 0 (unchanged) |
| not-routed root | 1 | +1 first encounter, then cached |
| not-routed child | 2 | +1 first encounter, then cached |

### Task 3 — placement and lease renewal must follow the root (LOAD-BEARING)

Not "beyond scope, but small" — **mandatory, and the more dangerous of the two
defeat paths.** The core fix *creates* it: today a mutating child POST resolves
degraded, so sticky is never recorded (`proxy.ts:645` requires `!degraded`). After
the fix it resolves clean → sticky recorded with `leaseRenewedAt=0`
(`proxy.ts:648`) → the **second** mutating child request within the TTL takes the
sticky fast path and fires `placeSession(childSid)` (`proxy.ts:595-606`) → pigeon
manufactures an arbitrary HRW child assignment → permanent confident mis-route.
**Permission-answer POSTs are exactly this traffic** — the fix would break the
thing it exists to fix. Merely "skip promotion for children" does **not** close
this; only threading the routing sid does.

Therefore:
- `StickyEntry` carries `routingSid: string | null`; the renewal path places it and
  declines when null. TTL-refresh (`proxy.ts:608`) must preserve it, like
  `leaseRenewedAt`.
- `maybePromote` places `resolved.routingSid`, declines when null, and (MEDIUM-2)
  keys `PromotionGate` on `routingSid` — otherwise N children of one root each
  fire their own `placeSession(root)` (harmless, `ensureRouted` is idempotent, but
  pointless).
- `checkSidExists` must check the **root** (the thing being placed), not the child
  — checking the child can pass while the root is mid-delete, creating a phantom
  root assignment. Skip it entirely when `rootExists` is already true from the
  walk (MEDIUM-2 + LOW-2: removes a duplicate GET of the identical URL).
- Root placement driven by child activity is *correct*: pigeon's `/place` is
  `ensureRouted` = `resolveRoute ?? placeSession` (`router.ts:239-241`), so a root
  holding a valid lease (i.e. mid-turn, exactly when children are active) is
  returned as-is, never yanked.

### Task 4 — counter

`metrics.notRoutedMutationToAnchor`, incremented where a mutating request is
forwarded to the anchor with reason `not-routed` (`proxy.ts:637-641`
neighborhood), surfaced on `/healthz`. If ~zero after a week, tighten that branch
to 503 — data-driven, retires the silent-wrong-process class. The tightening is
**deliberately deferred**, not part of this change.

## Tasks (SDD, TDD each)

- **T1** new `parent.ts`: `rootOf` + bounded FIFO cache; injectable fetch. Tests:
  child→root, multi-level, confirmed root, 404/error/timeout → short-TTL and
  **no** permanent poisoning, depth bound, cycle guard, overall deadline, eviction.
- **T2** wire into `resolveOwner`; add `routingSid`/`viaParent`/`rootExists`;
  reason propagation per MEDIUM-1. Tests: 404→ancestor routed, 404→ancestor also
  404, root-lookup pigeon error propagates (not flattened), 200 path unchanged,
  anchor-down ⇒ `routingSid: null`.
- **T3** thread `routingSid` through `maybePromote`, `PromotionGate`,
  `StickyEntry` + renewal. Tests: child promote places the ROOT; child is **never**
  placed; `routingSid:null` ⇒ no placement and no renewal; TTL-refresh preserves
  `routingSid`; root path unchanged.
- **T4** `notRoutedMutationToAnchor` counter + `/healthz`. Tests.
- **T5** live verification (below).

## Verification (T5)

1. Unit + integration suite green (baseline: **261 tests, 18 files**).
2. Live: spawn a subagent from a session whose owner is **not** the anchor
   (confirm via `/route?session_id={parent}`), have it request a permission, and
   confirm the prompt renders **and is answerable** through the door.
3. `GET /session/{child}/permissions` through the door returns the child's pending
   permission (not `[]`).
4. Re-run the P4 query: **no new child assignments** in pigeon.
5. **H1 guard:** a session created through the door and kept busy still holds a
   valid pigeon lease >45s in (i.e. `/route` reports a non-zero `expiresAt` that
   keeps advancing), proving lease renewal was not gated off.

## Post-implementation review (2026-07-25)

Three reviewers ran against the finished change (`4bdbc20..31972d3`). The spec
reviewer and code reviewer both passed it with **zero** critical/important
findings; **fable found a real regression they both missed**, which is the whole
argument for keeping the third pass:

- **H1 (fixed, was a genuine regression).** `placeAfterCreate` seeded the sticky
  entry with 3 args (`proxy.ts:379`), so `routingSid` defaulted to `null` and T3's
  new renewal gate turned itself off. **Every session created or forked through
  the door stopped renewing its pigeon lease** for as long as it kept being used.
  It hid well because an expired lease does not break routing —
  `resolveProspectiveRoute` still honors the assignment (`router.ts:117-127`) — but
  the lease is the only thing stopping a heartbeat-stale owner's in-flight run
  from being re-placed out from under it (`router.ts:299-313`), and the door's
  ½-TTL renewal is its only refresher (pigeon exposes no `/renew`). Root cause is
  mine: I specified "default to null (safe: do not place)", which is the safe
  default against placing the *wrong* sid but silently disables a working
  mechanism. Fixed by passing the created sid explicitly; created/forked sessions
  are always roots (P6).
- **M1 (fixed).** `rootExists` conflated *immutable parentage* with *mutable
  existence*: a permanent cache hit was reported as a live existence proof, so
  `maybePromote` skipped `checkSidExists` and could place an already-deleted root,
  re-creating phantom pigeon assignments. `rootOf` now reports `fetchedLive`, and
  only a 200 obtained in *this* walk sets `rootExists` — which still elides the
  duplicate GET in the only case LOW-2 was actually aimed at.
- **M2 (fixed).** A 404 was cached for the full 30s, including the window where a
  just-minted subagent session is becoming visible to another process — pinning
  that child's permission traffic to the wrong process for exactly the scenario
  this change exists to fix. 404 now gets `NOT_FOUND_TTL_MS` = 5s; network/timeout
  faults keep 30s, since those describe the anchor rather than the session.
- **L1 (fixed).** A failing walk no longer stamps a failure over a success a
  concurrent walk already proved.

Each fix is pinned by a test that was verified to fail without it.

**Accepted, not fixed** (recorded so they are not rediscovered as surprises):
- **L2** N children of one root each renew the root on their own ½-TTL clock →
  duplicate `/place` calls. Idempotent (`router.ts:239-241`); noise only.
- **L3** The new counter has two blind spots as evidence for the deferred 503
  decision: `handleFork` forwarding to a degraded anchor is an uncounted mutation,
  and walk failures during an anchor outage *inflate* it. Inflation is the
  conservative direction (it delays tightening, never wrongly justifies it).
  Counter epoch = deploy day; `reset-workspace` does not restart the door.
- **L4** A walk that dies mid-chain discards the parentage learned at earlier hops.

Also confirmed by fable against the source: no body/socket leak in the new code;
the concurrent-walk stampede is benign (drift polls are serialised per leg,
`drift.ts:72-85`); the double-renew guard is intact; child SSE legs neither flap
nor go permanently blind (worst case ≈40s stale, self-healing); and the additive
`/healthz` field breaks no consumer in the repo (the canary greps `version`,
`oc-pool-attach` checks only the status code).

## T5 live verification — PASSED (2026-07-25, door `imdbm7dr…`)

1. **Suite**: 294 tests / 19 files green; `nix build .#opencode-frontdoor` clean.
2. **Core fix, proven live**: parent `ses_069f33c2` owned by **serve-1 (:4097)**,
   not the anchor; child `ses_0671300e` has **no** pigeon route (404). A door
   request for `GET /session/{child}/permissions` logged
   `target=http://127.0.0.1:4097 degraded=false`. Pre-fix that went to `:4096`
   degraded. The door can only learn `:4097` via the parent walk.
3. **H1 guard**: a session created *through* the door and kept busy re-establishes
   its lease after the 30s lapse (`t=40s expiresAt=0` → `t=50s` new lease). `PATCH`
   is non-promoting so `maybePromote` cannot place it — only the sticky renewal
   path can, which proves `routingSid` is threaded.
4. **No pollution**: children holding their own pigeon assignment still **1 of
   4226** (unchanged baseline). `notRoutedMutationToAnchor` = 0 since deploy.

**Learned during T5 (worth knowing before the deferred 503 decision):** pigeon's
`/place` is `ensureRouted` = `resolveRoute ?? placeSession` (`router.ts:238-240`),
so it **never extends a still-valid lease** — `touch()`/`renewCAS` does, and nothing
calls it over HTTP. The door's ½-TTL "renewal" therefore only re-creates a lease
*after* it lapses, leaving a ≤15s window each cycle where a busy session holds no
lease. Pre-existing, not introduced here, but it means the lease is a weaker
guarantee than the config comment implies.

**Not yet exercised:** a real *pending* subagent permission round-trip (the child
queried had already finished, so `[]` was correct). Routing for that exact path is
proven; the remaining dimension gets covered the next time a subagent raises one.

## Residuals (record on landing)

- If pigeon holds an assignment for an *intermediate* ancestor but not the root, we
  resolve the root and ignore it. Only reachable via pigeon-side `ensureRouted` on
  a non-root sid, which is itself parent-unaware — a pigeon concern, not the door's.
- Cache is per-process and lost on door restart (lazy re-warm; correctness
  unaffected).
- Not-routed resolution now depends on anchor responsiveness (bounded, fail-open
  to non-placeable).
- Task 4's counter lands but the 503 tightening waits a week of data.

## Deploy (USER runs; door restart drops every in-flight SSE leg)

Batch with nothing else; hand over the exact sequence when the code is green.
