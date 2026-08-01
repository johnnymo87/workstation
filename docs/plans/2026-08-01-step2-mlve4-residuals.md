# Step 2 — dispose of `mlve.4`'s residuals, close Phase 9

Spine: `docs/plans/2026-07-31-frontdoor-next-roadmap.md`, Step 2. This file is the
implementation plan for the code half; the disposition record for all five residuals is
the table at the bottom.

## Disposition of the five residuals

| # | residual | disposition |
|---|---|---|
| (a) | door's own error text instructs bypass (`u417`) | **FIXED HERE** — and made enforceable |
| (b) | out-of-repo consumers unenumerated | **BEADED** (new), with the limitation stated |
| (c) | create→connect ownership race (`vjq0`) | **FIXED HERE** — one Set entry + gate fix + tests |
| (d) | post-launch migration strips MCP | **FOLDED INTO `vjq0`** (it already records it) |
| (e) | structural opacity (`pcf3`) | **STAYS P3**, explicitly |

## (a) The door stops manufacturing its own violations

**The finding, restated precisely.** The guard armed in Step 1 governs
`pkgs/*/default.nix` and the four `users/dev/home.*.nix` + two `hosts/*/configuration.nix`
files (grep `Files the guard governs` in `users/dev/test-frontdoor-opacity.sh`). It does
**not** scan `pkgs/opencode-frontdoor/src/*.ts`, and it cannot scan a string that only
exists on the wire. So the door's denial bodies are a consumer-instruction channel with
**no guard at all** — and today they instruct bypass:

- `proxy.ts`, the `deny-global-mutation` branch: fallback remedy `"To mutate, call a serve
  port directly."` for every row with no `remedy`.
- `proxy.ts`, the `web-ui` 404 branch: `"Use a serve port directly."`
- `routes.dispositions.ts`, `POOL_CREDENTIAL_REMEDY`: ships a literal
  `for p in 4096 4097 4098 4099` loop **and** the `/run/secrets/...` password path.

Five terminal-denial rows carry no `userMessage`/`remedy` at all, so they inherit the
generic hint: `POST /instance/dispose` (where direct-to-a-serve is the documented *trap* —
a cold member boots the instance and then the door times out without disposing it) and the
four MCP-OAuth rows (where direct-to-one-serve IS correct, but is silently breakable by the
fixed-port-19876 squat).

**Changes:**

1. Give all five rows a real `userMessage` + `remedy`.
2. Replace both generic `proxy.ts` strings with text that names the constraint and points
   at the runbook instead of at a port.
3. `POOL_CREDENTIAL_REMEDY`: keep the *constraint* and the *hazard warning* on the wire;
   move the port-enumerated recipe into the runbook.
4. New `docs/runbooks/frontdoor-per-serve-operations.md` — the operator procedures, in the
   repo, where they belong. (Docs are outside the guard's file set by design, so this
   needs no exemption row.)
5. **Enforcement, the analogue of Step 1:** new test asserting no wire-facing string
   (`userMessage`, `remedy`, and the two `proxy.ts` fallbacks) contains a pool-port literal
   or a bypass phrase. Without this, item 1-3 is prose and rots the way the table rotted.

## (c) `vjq0`: `connect` becomes promoting

**Why the urgency argument in the spine is WRONG, recorded so it is not re-inflated.**
I claimed the `prospective` path was a second, uncounted route to the same symptom, and
that 12/12 observed agreement was luck. The code says otherwise, twice:

- `proxy.ts:placeAfterCreate` already calls `placeSession` **and** `sticky.record` on
  `POST /session`. The only consumer (`pkgs/opencode-launch`) creates through the door, so
  the session is active-leased *before* connect is issued. `not-routed` at connect
  therefore requires create-placement to have already failed.
- `resolve.ts` returns `degraded:false` on the prospective branch, and connect is mutating
  (`sticky.ts:isMutatingSessionRequest` — POST with the sid in the path), so a prospective
  connect **records sticky**. The launcher's `prompt_async` follows seconds later and hits
  the sticky path before `maybePromote` is ever reached.

So 12/12 is structural, and 0/94 is explained. **Measured, 7 days of door journal:** 94
connects, 0 `degraded:true`, spread 27/20/26/21 across the pool.

**The honest case for fixing anyway:** it is one string in a Set, on a door restart that
residual (a) already requires, and the failure mode is silent — no error, no counter, no
log — and lands as "the agent didn't use its tools", which gets misattributed to the model.

**Changes:**

6. Add `"connect"` to `PROMOTING_SUFFIXES` (`place.ts`). Matching is exact-last-segment via
   `Set.has`, so `disconnect` is NOT caught — verified, and now unit-tested.
   Update the set's comment: it now means *turn-starting **or state-pinning***.
7. **The `PromotionGate` burn** (found by adversarial review of this plan, not by me).
   `maybePromote` calls `gate.record(placementSid)`, TTL = `stickyTtlMs`. A promoting
   connect burns the budget, so a `prompt_async` arriving within the TTL and finding itself
   not-routed is `ttl-guarded` → falls back to the anchor → **a mutating turn on a
   possibly-wrong process**. That is louder-bad than the silent tool loss being fixed.
   Fix: namespace the gate key for state-pinning promotions (`connect:<sid>`) so a connect
   cannot consume the turn-starting budget.
8. **Counter blinding.** Post-fix a not-routed connect that places no longer increments
   `notRoutedMutationToAnchor` — the only existing signal for this class. Add
   `promotedOnConnect` to the metrics/healthz surface so the fix is observable.

**Tests (the 4-MCP matrix in `vjq0` is NOT the right axis — the bug is routing, and four
servers is one server run four times):**

9. Unit (`test/place.test.ts`): `.../mcp/slack/connect` promotes; `.../disconnect` and
   `.../auth` do not.
10. Integration (`test/integration.test.ts`): fake pigeon 404s the sid → connect → assert
    the door POSTed `/place` and forwarded to the **placed member, not the anchor**.
    **This test must FAIL on pre-fix code** — that is the anti-"gate that cannot fail"
    property, and it is checked by reverting the one-line change and re-running.
11. Integration: a promoting connect must not ttl-guard a following turn-start (item 7).

## Not fixed here, recorded

`vjq0`'s deeper half stays open: **nothing reconciles MCP after the owner moves.** Sticky
health-probe failure, lease lapse, or a pool-membership change still lands a turn on a
member with no MCP connection, and the tools map still claims connected. Promoting on
connect removes one entry route; it does not close the class.

## Bookkeeping

- `a0zj` / `m96n`: decide one, deliberately.
- `ss -K` residual: retire explicitly.
- Stale comments: **already swept** — both now narrate the old claim as history. Verify,
  record, do not re-do.

---

## Adversarial review outcomes (2026-08-01, on the real diff)

**F1 — BLOCKING, fixed.** `promotedOnConnect` as first written counted EVERY state-pinning
placement, including `prospective` connects — which `maybePromote` also places, which
measured 12/week, and which were already safe pre-fix. The counter built to answer "did
the fix rescue anything?" would have read ~12/week and invited exactly the wrong
conclusion: that the race fires weekly. It does not; it measured 0/94. Now scoped to
`resolved.reason === "not-routed"`. A nonzero-but-meaningless counter is its own silence.

**New behaviour this diff introduces, named because the plan had not named it:** prospective
connects now issue `POST /place` (~12/week). Benign — it is what promoting requests already
do — but it is a change, not a no-op.

**F3/F4 — fixed here rather than deferred**, because a guard that ships armed and
launderable is the exact Step 1 lesson:
- The port patterns required a colon and matched a loop only when the variable was
  literally `p`. So `for port in 4096 4097 4098 4099` and "send the write to port 4096"
  both passed. Bare pool-port numerals are now banned outright. All three laundering
  shapes were re-tested against the hardened guard and are caught.
- The extraction only ever saw two enumerated `proxy.ts` fallbacks, so a bypass hint in any
  of the ~10 other denial bodies would have shipped unguarded. The whole `proxy.ts` source
  is now scanned. (A bare `127.0.0.1` in a comment describing what the door binds is
  legitimate, so the source scan bans addressable targets and pool-port numerals, while
  wire strings keep the stricter rule.)

**F2 — BEADED, not fixed here.** `proxy.ts:proxyRequest`'s 502 branch and the catch-all 500
return upstream `err.message`, which for a downed member is
`connect ECONNREFUSED 127.0.0.1:<port>` — a pool address on the wire, on a common failure
path, unreachable by any static guard. Pre-existing and a disclosure rather than an
instruction, so not blocking. The commit-message claim "no wire-facing string may contain a
loopback address" was an OVERCLAIM; the guard's header now states the static-only scope.

**F5 — my diagnosis was wrong, in the benign direction.** I recorded a "pre-existing failing
route-classification gate" after measuring one `[FAIL]` line on both pristine `main` and my
branch. The measurement was right; the reading was not. That line is **stderr from a
PASSING negative test** (`test/route-gate.test.ts`, "exits 1 on unrecognized route in doc
file") which deliberately runs the gate against a bad fixture. `./test.sh` exits **0** with
495/495 passing. There is no known-failing gate. Recorded here so the next reader does not
inherit phantom debt — which is how this kind of folklore calcifies.
