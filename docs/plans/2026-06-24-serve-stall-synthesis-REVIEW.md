# Adversarial review — serve-stall synthesis

**Reviewer:** Vertex Opus 4.8 (adversarial), session driven by coordinator ses_10959f45
**Date:** 2026-06-24
**Target:** `docs/plans/2026-06-24-serve-stall-synthesis.md` (+ the iwpj/qjk4-M3.1/yoa2 design docs)
**Method:** verified every load-bearing claim against applied source. Citations are
to the actual files read: `~/projects/opencode-patched/patches/*.patch`,
`~/projects/pigeon/packages/daemon/src/*`, `/tmp/opencode/v1177(-apply)` (clean +
TUI v1.17.7), `~/projects/workstation/pkgs/*`, `/tmp/lyj0-*.ts`.

**One-line verdict:** A, B, D, E **HOLD**. C and F are **FLAWED in framing/priority,
not in mechanism**. The single biggest problem is in **F**: the root-cause model is
**mono-causal (N×M fan-out)** but never isolates the event-loop-pin mechanism, while
the *same patch stack* ships two other documented loop-pinning fixes
(step-end-diff, project-copy) that produce the *identical* symptom.

---

## A. lyj0 re-closure (SSE reconnect leak is fixed; reopen was conn pile-up) — **HOLDS**

The re-closure is sound and **not** premature.

- The **deployed** `runSseAttempt` (`attach-route-resolve.patch:417-448`) matches the
  repros' "faithful copy" exactly: a **fresh per-attempt `AbortController`**, aborted in
  `finally` (`:425,:445`), with a **balanced** parent→attempt bridge
  (`addEventListener … {once:true}` + `removeEventListener` in finally, `:431,:446`). By
  construction one client holds **≤1** SSE connection.
- The `releaseLock()`-vs-`cancel()` worry is closed: in the deployed loop the SSE is opened
  via `sdk.global.event({ signal })` where `signal` **is** `attempt.signal`
  (`attach-route-resolve.patch:160-163,435`), so `attempt.abort()` always fires the SDK's
  still-registered abort handler → `reader.cancel()` (socket closed) *before* the
  generator's `finally` runs `releaseLock()`. Repro 5 (`/tmp/lyj0-midabort.ts`) exercises
  exactly this path = 0 leaked.
- **The "leak only under load" counter-hypothesis is largely closed**, because load = churn
  = reconnects, and the repros *do* exercise churn against a **real** serve (repro 3: real
  SDK, FIN/RST, 30 reconnects = 1/0/0; blackhole 27 s = 1). The live steady-state obs (one
  client, 1 ESTAB, same ephemeral port for 2.5 min, 0 reconnects) is corroborating, not the
  sole basis.
- **The one path not isolated in a repro** is the `currentUrl` migration that calls
  `sdk = createSDK()` mid-loop (`attach-route-resolve.patch:155-158`). This is **reasoned-
  safe, not measured**: Bun's keep-alive pool is the *global* `fetch` pool (not per-client),
  so rebuilding the client object frees nothing/leaks nothing, and the SSE remains bound to
  the per-attempt signal. The residual REST requests left in flight to the old serve are
  exactly the yoa2 pile-up (REST, GET) — *consistent with* the synthesis, not an SSE leak.

**Caveat (not a flaw):** A holds **independently** of what causes the stall. The re-closure
proves "the 89-141 growing conns were not the SSE loop"; it does **not** prove they were
fan-out (see F).

## B. Unified root cause (fail-open + nothing places at create) — **HOLDS** (one soft spot)

(i) **Fail-open is real and is the path turns take.** `serve-lease.patch:1521-1527`: when
`!acq.ok && !acq.assignmentExists` it logs "No assignment found … Failing open" and
`return yield* work` (runs the turn locally). `acquire` returns
`assignmentExists:false` when there is no row (`:343-344`,
`assignmentExists = !!assignmentRow && desired_serve_id === serveId`, `:334`). The run loop
wraps `runLoop` in `withSessionLease` (`:1592-1597`), so this is the live path.
*Precision nit:* turns run on the serve that received the **prompt**, not the **create**;
they coincide for `opencode-launch` only because `GET /route` 404s pre-placement and
`serve_url` falls back to `$OPENCODE_URL` (`opencode-launch/default.nix:182,200-202,238`).
Also note the guard is a no-op unless `OPENCODE_ROUTING_DB` is set (`:1512` transparent
passthrough) — but the turn still runs locally either way, so the conclusion is robust.

(ii) **No create-time placement anywhere — confirmed.** `placeSession` is reached only via
`ensureRouted` (`router.ts:240`) which is called only by `forSession`
(`client-factory.ts:16`); `GET /route` is read-only (`app.ts:541-567`, explicit comment +
`resolveRoute ?? resolveProspectiveRoute`); pigeon exposes no placing POST.
**But the synthesis misses a relevant fact:** pigeon **already learns every session's serve
at create** — `POST /session-start` records `backend_endpoint` (`app.ts:236-238`). It just
doesn't *place*. This (a) means a cheaper fix exists (place inside the existing
`/session-start` hook, no new endpoint), and (b) **undercuts iwpj option (b)'s** claim that
off-book discovery "would need a *new* mechanism" — the `backend_endpoint` discovery channel
already exists.

(iii) **Off-book sessions run heavy compute with no row — consistent, not rejected.**
fail-open runs them; `resolveProspectiveRoute` 404s them (`router.ts:110-113`, `if (!a)
return null`). Nothing rejects an unassigned session.

(iv) **HRW not broken — HOLDS for the conclusion.** serve-0 carries the load with the
*fewest* assignments (1) — the **opposite** of an HRW concentration bug, and HRW isn't even
invoked for off-book sessions. **Soft spot:** the *dormant* skew (23/118/58 across
serve-1/2/3, ~5×) is unexplained and waved off as "historical." It is *not proven* uniform.
But even a real HRW bias cannot explain serve-0 (1 assignment, all the load), so the root
cause survives regardless. Recommend not *claiming* "HRW healthy" beyond "HRW is not the
concentration cause."

## C. iwpj place-at-create — mechanism HOLDS, **sequencing/priority FLAWED**

- **CLI path is safe by construction.** `opencode-launch` is sequential: create returns the
  id (`default.nix:188`), then a `POST /place` could run, then `prompt_async`. The
  "does the TUI know the sid before create?" worry is **moot** for the CLI (create-then-
  place is fine; iwpj open-Q#2 doesn't bite here).
- **Interactive-TUI race is real and the fail-open does NOT fail safe.** If the first prompt
  beats placement, or placement picks a serve ≠ where the prompt landed, the turn runs on
  the *original* serve under fail-open while the TUI's next SSE re-resolve
  (`attach-route-resolve.patch:150-158`) migrates to the *placed* serve → **split-brain**:
  compute + events on serve-0, TUI listening on serve-2, so after the next reconnect the TUI
  sees **no events for its own running session.** Mitigable only by strict ordering (await
  place **and** rebuild the submit client *before* the first prompt) — which is precisely the
  expensive, deferred Phase 2.
- **The real flaw — Phase 1 is mislabeled "PRIMARY / attacks the real cause."** Phase 1
  covers only `opencode-launch`, which uses **`prompt_async`** — headless, **no persistent
  `/global/event` SSE client**. So launched sessions add **M** (event volume) but **not N**
  (listeners). iwpj's *own* doc says "interactive coding is the bulk of the load"
  (`iwpj-design.md:220`). The 16 interactive attach TUIs (the dominant **N**) and their
  sessions' **M** stay pinned to serve-0 until **Phase 2**. So Phase 1 shaves only the
  launched-session fraction of M and leaves N=16 and interactive-M intact. Calling the
  *scheduled, cheap* step the "primary lever that attacks the real cause" risks declaring
  victory after a step that, by the sub-design's own admission, doesn't touch the dominant
  load. Cheap-validation-first is fine; the **rhetoric** is the problem.

## D. qjk4 M3.1 defer + child-session blocker — **HOLDS**

- **Blocker is real.** `/global/event` has **zero** filter
  (`global.ts:36-42`, `Queue.offerUnsafe` per event). The TUI renders child/sub-agent
  sessions keyed by their **own** sessionID: `data.tsx` stores by
  `event.properties.sessionID` (`:133+`), and `routes/session/index.tsx:202-204` builds the
  rendered `children` set by `parentID` (plus `subagent-footer.tsx`, `dialog-subagent.tsx`).
  Filtering to `props.sessionID` drops child events → breaks live sub-agent rendering. The
  "always-forward non-session events" rule does **not** rescue them — child events **carry a
  sessionID**, so they're session-scoped and filtered out. Blocker correctly gates the ship.
- **O(N) emit-floor argument is correct.** `GlobalBus.emit` → `super.emit`
  (`bus/global.ts:14-18`, Node `EventEmitter`) iterates **all** listeners synchronously
  regardless of any in-callback filter; the filter only removes the per-client
  `offer`+`JSON.stringify`+`Sse.encode`. So "iwpj cuts the floor, M3.1 cannot" is accurate.
- **Nuance (already hedged by the doc):** the worked 16× estimate assumes m≈1; with the
  descendant set, m>1 erodes — but does not negate — the win. DEFER is justified (real
  blocker + currently-unobserved failure mode + 3-part coordinated change).

## E. yoa2 GET-only timeout — **HOLDS**

- **Pivotal claim verified.** `prompt` awaits the full turn then constructs the response
  (`session.ts:298-306`) → headers withheld for minutes; TTFB == completion. All blocking
  ops (`prompt/command/shell/summarize/init` + `create/fork/abort/revert/…`) are **POST**
  (`groups/session.ts:203-395`). So "all long ops are POST" is true.
- **Exhaustive streaming-GET check passes.** The only `HttpServerResponse.stream` sites are
  `session.ts:304` (prompt, POST), `event.ts:69` (`/event`, GET SSE), `global.ts:48`
  (`/global/event`, GET SSE). `project-copy`'s `.stream` is an *internal* `llm.stream`; the
  endpoint is POST (`groups/project-copy.ts:15`). So `SSE_PATHS={/global/event,/event}`
  covers **every** streaming GET — the exemption is complete today.
- **Pile-up source confirmed GET.** `sync.tsx:164-165` re-runs `bootstrap()` on
  `server.instance.disposed`; `bootstrap` (`:428`) fires the ~15-GET fan-out. All GET → all
  bounded.
- **Composes with qjk4 M3.1.** The wrapper keys on `new URL(req.url).pathname`, which strips
  the query, so `/global/event?session_ids=…` still matches the exemption. Good.
- **Soft spots (acknowledged, low):** a future long GET or a future SSE endpoint would be
  false-aborted; and under a dispose-*storm* the 30 s window could allow some accumulation
  toward 256 — but bounded, not unbounded, so graceful degradation still holds.

## F. Cross-cutting — **PARTIALLY FLAWED** (two real issues)

**F.1 — Mono-causal root cause (the most important miss).** The synthesis attributes the
stall *entirely* to N×M SSE fan-out. But the **same patch stack** ships two other
event-loop-pinning fixes that produce the *identical* symptom (single core 100 %, no logs,
multi-minute freeze):
- `step-end-diff-bound.patch` — jsdiff `structuredPatch` with unbounded context "blocks the
  Bun event loop … minutes … single core at 100 % — the reported spin" (bead 0lik).
- `project-copy-debounce.patch` — "opencode 1.17.x reconnect-storm wedge … core pegged"
  (bead sqd5).
- The yoa2 doc itself names "the project-copy / step-end-diff CPU spins that other patches
  address" as alternate stall sources.

The live evidence proves load **concentration** on serve-0 (conns / children / RSS 5–6 GB)
but does **not isolate the loop-pin mechanism** — no event-loop-lag sample, no CPU
flamegraph, no attribution of the spin to `message.part.updated` serialization vs. diff vs.
project-copy vs. **GC** (5–6 GB RSS is itself a credible pause source). **If the residual
hotness is diff/copy/GC-shaped, M3.1 does nothing** and "M3.1 is insurance for a hot serve"
is misplaced — the real insurance would be those other patches. The synthesis should
profile-attribute the spin on a live stall, or explicitly frame the stall as a multi-cause
surface where fan-out is one (unquantified) contributor.

**F.2 — yoa2 masks the diagnostic signal the others depend on.** yoa2 makes hung GETs
fail-fast, which **suppresses the conn-pileup symptom** (the 34 ESTAB / "~0.9 conn/min")
that is the primary observable for "is this serve stalling?" After yoa2 ships (batched into
patched.8, open-Q#4), the iwpj-Phase-2 trigger ("residual load on serve-0") and yoa2's *own*
live confirmation (open-Q#3, "`ss -tnp` on a stalled serve to prove GET-domination") lose
their signal. **The `ss -tnp` GET-domination confirmation must be done on a live stall
BEFORE yoa2 deploys.** The synthesis lists both as open questions but never sequences
confirm-before-suppress. Post-yoa2, stall detection must move to CPU / event-loop-lag — which
(to its credit) is already what the M3.1 ship-trigger keys on.

**Priority "iwpj primary, M3.1 defer, yoa2 defense":** *directionally* correct (distribution
is the only lever that cuts the O(N) floor), but weakened by F.1 (if the spin isn't
fan-out-shaped, the fan-out-specific M3.1 is moot and distribution helps for a different
reason) and by C (the cheap Phase 1 that's actually scheduled is not the primary attack).

---

## Prioritized corrections

1. **Stop asserting fan-out as THE root cause.** Take an event-loop-lag + CPU attribution on
   a live stall before committing to the N×M story. The stack's own step-end-diff /
   project-copy fixes and 5–6 GB RSS (GC) are competing, equally-symptom-matching
   explanations. (F.1 — most important)
2. **Sequence diagnostics before defenses.** Do the `ss -tnp` GET-domination confirmation
   (and any fan-out attribution) on a live stall *before* deploying yoa2, which erases the
   pileup signal. (F.2)
3. **Re-label iwpj Phase 1** as cheap validation, not the primary fix: `opencode-launch` is
   headless (`prompt_async`, no SSE client) and — per iwpj's own "interactive is the bulk" —
   Phase 1 leaves the dominant N (16 TUIs) and interactive-M on serve-0. Phase 2 (TUI patch)
   is the real lever. (C)
4. **Specify the interactive-TUI place ordering** to avoid a fail-open split-brain: place +
   rebuild the submit client must complete *before* the first prompt, else compute and the
   TUI's event stream decouple across the next reconnect. (C)
5. **Prefer placing inside the existing `POST /session-start`** (already carries
   `backend_endpoint`, `app.ts:236-238`) over/with a new `POST /place`; pigeon already learns
   every session's serve at create. Also corrects iwpj option-(b)'s "no discovery exists"
   claim. (B.ii)
6. **Soften "HRW is healthy"** to "HRW is not the concentration cause" — the 5× dormant skew
   (23/118/58) is unexplained. (B.iv)

**Minor:** synthesis §2's parenthetical "1 assignment / 34 ESTAB / 14 child procs vs 0/0/8"
doesn't map to the iwpj live table (children 14/0/0/2; no serve shows 0/0/8) — a data-
citation inconsistency, immaterial to the conclusion.
