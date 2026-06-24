# Serve-0 stall: unified root cause + three-fix synthesis

**Date:** 2026-06-24
**Author:** coordinator session ses_10959f45 (cloudbox)
**Status:** design synthesis, pre-implementation. For adversarial review.

This ties together the investigation that re-closed `workstation-lyj0` and the
three design passes that followed. It is the single source of truth for "what
actually wedges serve-0 and what to do about it."

## 1. What was misdiagnosed (lyj0)

`lyj0` was reopened as "the patched.7 SSE reconnect leak didn't hold." That was
**wrong**. The patched.7 `runSseAttempt` fix holds: proven by 6 controlled Bun
repros (active-abort, graceful-close, FIN, RST, wedged-blackhole, mid-stream
parent-abort — all 0 leaked or stable-at-1) **and** live observation (an idle
TUI holds exactly 1 ESTABLISHED conn on one ephemeral port for minutes; no
steady-state reconnects). `lyj0` is closed as fixed.

The "89-141 conns growing ~0.9/min" reopen symptom was **connection pile-up from
serve-0's event loop transiently stalling**, then draining on recovery — not an
SSE leak. Repro scripts: `/tmp/lyj0-*.ts`.

## 2. Unified root-cause model of the stall

serve-0 stalls because **N (clients) × M (events) SSE fan-out runs on one event
loop**, and serve-0 accumulates disproportionate N and M:

- **Why the load concentrates (iwpj — the real cause).** HRW placement is *not*
  broken and spreads correctly *where it runs*. But **nothing places a session
  at create time**: `placeSession` (HRW) is only reachable from pigeon's
  in-process control path; the only HTTP surface (`GET /route`) is read-only.
  The serve-side lease guard **fails open** when no assignment row exists, so a
  session's turns run on whatever serve received the create — always serve-0,
  because every external creator defaults `OPENCODE_URL=:4096`. These busy
  sessions are **off-book** (no `session_assignment` row), so boi9 prospective
  routing 404s them (it gates on assignment existence) and every attach TUI
  *also* falls back to serve-0. Net: serve-0 holds the *fewest* assignments yet
  the *most* compute (live: 1 assignment / 34 ESTAB / 14 child procs vs 0/0/8).
  Proof the fix shape is right: the telegram `/launch` path already
  places-at-create and spreads correctly.

- **Why the fan-out is expensive (qjk4).** The TUI subscribes to `/global/event`
  (`handlers/global.ts`, `GlobalBus.on`, **no filter**). Every GlobalBus event is
  offered to every connected client's queue and serialized per client. With ~16
  clients × the event volume of ~16 busy sessions on one loop, that is the
  O(N×M) amplification **hypothesized** to pin the loop. **⚠ NOT YET PROVEN — see
  §7.1.** Live evidence establishes load *concentration*, not the loop-pin
  *mechanism*; the same patch stack carries other pin candidates (jsdiff spin,
  copy-refresh wedge, GC). Treat the fan-out attribution as a hypothesis until a
  live stall is profiled.

- **Why a stall becomes a visible pile-up (yoa2).** When the loop pins, the
  kernel still completes TCP handshakes into the backlog (ESTABLISHED) but the
  app never responds. The TUI's periodic **GET** requests — notably the
  `sync.tsx` bootstrap GET fan-out, which *re-runs on every
  `server.instance.disposed`* — hang as ESTABLISHED and accumulate to the 256
  per-origin keep-alive pool cap. (All long agent work is POST and withholds
  headers until done, so it is indistinguishable from a stall by timing alone.)

## 3. The three fixes and how they compose

| Fix | Bead | Role | Status |
|---|---|---|---|
| `setMaxListeners(0)` | qjk4 M3.3 | hygiene (uncap GlobalBus listeners; kill a false-positive warning) | **shipped** (opencode-patched 13e3747) |
| **place-at-create** | iwpj | **PRIMARY** — shrink N and M per serve by spreading sessions | designed |
| `/global/event` `?session_ids=` filter | qjk4 M3.1 | secondary — cut per-event serialize/offer amplification on a still-hot serve | designed, **DEFER (ship-on-trigger)** |
| attach GET request timeout | yoa2 | defense-in-depth — bound the GET pile-up symptom | designed |

**They are complementary, not redundant:**
- iwpj shrinks the **O(N) emit floor** itself (fewer clients+sessions per serve).
  M3.1 *cannot* — `GlobalBus.emit` iterates all N listeners regardless of filter;
  M3.1 only removes the per-listener serialize+offer work for non-matching events.
- So **iwpj is the primary lever.** M3.1 is insurance for a serve that is hot
  *despite* good distribution (e.g. a swarm coordinator + workers colocated by
  HRW). yoa2 makes *any* stall (from any cause) degrade gracefully instead of
  saturating the client pool.

## 4. Recommended sequencing

1. **iwpj Phase 1** (place-at-create): pigeon `POST /place` + `opencode-launch`
   calls it between create and first prompt. **No opencode-patched release** —
   fastest, attacks the real cause, and makes boi9 + lease enforcement actually
   function. Measure residual interactive-TUI load on serve-0 after.
2. **yoa2** (attach GET timeout): client-only opencode-patched patch; rides the
   next patched.8 build + serve-pool reload (which also deploys the already-landed
   qjk4 M3.3 and the s08x swarm_send fix).
3. **iwpj Phase 2** (interactive-TUI create path) and **qjk4 M3.1**: ship on
   trigger, i.e. if a serve is measured still stalling after Phases 1-2. M3.1 has
   a real blocker to resolve first (child/sub-session set, see §5).

## 5. Cross-cutting open questions (need a human/coordinator call)

1. **M3.1 child-session set (blocker).** A TUI renders child/sub-session events
   too. Filtering `/global/event` to only `props.sessionID` would drop sub-agent
   events. Needs descendant enumeration + SSE re-subscribe on child spawn, OR
   server-side parent→child expansion. Must resolve before M3.1 ships.
2. **iwpj interactive-TUI create path.** Patch the TUI (full coverage, opencode-
   patched rebase cost) vs an out-of-band auto-attach placer (cheaper, partial).
   Recommend: ship Phase 1, measure, then decide.
3. **yoa2 live confirmation.** Confirm via `ss -tnp` on an actually-stalled serve
   that the pile-up is GET-dominated (strong code evidence already; one live
   check would close it).
4. **Deploy batching.** qjk4 M3.3 + s08x are landed-but-undeployed; both need a
   serve-pool reload. yoa2 is also client-only opencode-patched. Batch all three
   into one patched.8 build + reload to pay the disruption once.

## 6. Design docs
- iwpj: `~/projects/workstation/docs/plans/2026-06-24-serve-load-distribution-iwpj-design.md`
- qjk4 M3.1: `~/projects/opencode-patched/docs/plans/2026-06-24-global-event-filter-qjk4-m31-design.md`
- yoa2: `~/projects/opencode-patched/docs/plans/2026-06-24-client-request-timeout-yoa2-design.md`

## 7. Adversarial review corrections (incorporated 2026-06-24)

Reviewer ses_1041f9881 verified the synthesis against applied source. Verdicts:
A (lyj0 re-close) HOLDS, B (fail-open + no create-time placement) HOLDS, C (iwpj
mechanism) HOLDS but framing flawed, D (M3.1 defer) HOLDS, E (yoa2 GET-only)
HOLDS, F (cross-cutting) partially flawed. Full doc:
`2026-06-24-serve-stall-synthesis-REVIEW.md`. Five corrections fold in:

### 7.1 GATING STEP (was missing): isolate the loop-pin MECHANISM before fixing
The model was mono-causal (N×M fan-out) but **no event-loop-lag / CPU profile was
ever taken** — live evidence proves *concentration*, not *mechanism*. The same
deployed patch stack ships **other** loop-pin sources: `step-end-diff-bound.patch`
(jsdiff `structuredPatch` pins the Bun loop for minutes at 100% one core — bead
`0lik`), `project-copy-debounce.patch` ("1.17.x reconnect-storm wedge" — bead
`sqd5`), and **GC pauses** are plausible at 5-6GB RSS. **If the residual spin is
diff/copy/GC-shaped, qjk4 M3.1 does nothing** and "M3.1 is insurance for a hot
serve" is misplaced. **ACTION: profile-attribute a live stall** (event-loop lag +
CPU/JSC sampling profile, per the `0lik` profiling plan) **before committing to
any fan-out fix.** This is bead `xci9` (P1: reproduce the wedge + measure serve
responsiveness). Until then, frame the root cause as **multi-causal: concentration
proven, mechanism unproven.**

### 7.2 iwpj framing corrected — Phase 1 cuts M not N; Phase 2 is the real lever
`opencode-launch` sessions are headless `prompt_async` with **no persistent SSE
client**, so Phase 1 adds event volume (M) handling but does **not** remove any of
the ~16 persistent TUI SSE clients (N) — and N (interactive TUIs) is the dominant
load (iwpj design doc's own §220). So **Phase 2 (interactive-TUI place-at-create)
is the primary lever, not Phase 1.** Revised priority: Phase 1 is a cheap
down-payment; Phase 2 is the fix.

### 7.3 iwpj — prefer the EXISTING create-time hook over a new POST /place
Pigeon **already learns every session's serve at create** via the
`POST /session-start` `backend_endpoint` (`pigeon app.ts:236-238`). That both
(a) offers a cheaper place-at-create insertion point than a brand-new `POST /place`
+ launcher changes, and (b) **falsifies** the iwpj doc's option-(b) claim that
"there is no discovery mechanism." Re-evaluate iwpj against this hook first.

### 7.4 iwpj — interactive place must finish BEFORE first prompt (split-brain risk)
For an interactive TUI, if placement races the first prompt, fail-open does **not**
fail safe — it **split-brains**: the turn's compute runs on serve-0 (fail-open)
while the TUI re-resolves to the placed serve and then sees **no events** after
reconnect. Placement + submit-client rebuild must complete before the first prompt.

### 7.5 yoa2 — it suppresses the primary stall observable; sequence accordingly
yoa2's GET timeout hides the conn-pile-up (34 ESTAB / ~0.9/min) that is currently
the main *visible* stall signal — blinding both the iwpj-Phase-2 trigger and
yoa2's own `ss -tnp` GET-domination confirmation. **Therefore:** (1) do the live
`ss -tnp` GET-domination check **before** shipping yoa2; (2) stand up a
CPU/event-loop-lag stall detector **before** yoa2 removes the conn-count signal,
so we don't go blind. (Minor: §2 "HRW healthy" → "HRW is not the concentration
cause"; the 5× dormant-assignment skew 23/118/58 is unexplained and worth a look.)

### Revised top-level sequencing
0. **Profile a live stall (xci9)** → attribute the loop-pin. GATES everything below.
1. Stand up a CPU/event-loop-lag stall detector (so yoa2 doesn't blind us).
2. Live `ss -tnp` GET-domination check (confirms yoa2 premise).
3. iwpj via the `POST /session-start` hook — **Phase 2 (TUI) is the real lever**.
4. yoa2 (after 1-2) + qjk4 M3.3 (shipped) + s08x → one patched.8 + serve-pool reload.
5. qjk4 M3.1 **only if** step 0 attributes the residual spin to fan-out AND the
   child/sub-session set problem (§5.1) is solved.
