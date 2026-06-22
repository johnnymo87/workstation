# Re-review (R2) of the teamclaude opus-aware fork PLAN (Vertex Opus 4.8)

Method: this is a *re-review* of the revised plan
(`2026-06-21-teamclaude-opus-aware-fork-plan.md`, R2). Every prior finding from
`review-plan-vertex-opus.md` was re-checked against the live upstream tree at
`/tmp/teamclaude-review` (git `654ace1`, npm `1.0.7`) and the workstation deploy
files — not against the plan's or the author's word. I re-opened each cited
`file:line`, re-traced the classifier and `_selectNext` logic by hand, and ran a
fresh skeptical pass for regressions the revisions introduced. Anthropic wire
shapes, the not-yet-captured real *limit* response, the aarch64 cloudbox
cross-build, and the GitHub fork state remain **UNVERIFIABLE FROM REPO** and are
judged against the plan's Phase-7 evidence gate.

---

## 1. Summary

R2 correctly and verifiably resolves **all** prior findings. The two MAJORs are
genuinely fixed against real source: the mid-stream classifier no longer gates the
message clause on `status===429` (so the design's primary 200/`rate_limit_error`/
"usage limit has been reached" shape now classifies as `usage_limit`, with
`THROTTLE_RE` still short-circuiting first so it stays IP-throttle-safe), and the
Task 5.2b test now asserts that real shape instead of the invented
`usage_limit_error` type; the cloudbox unify now uses a `pkgs.callPackage` let-binding
mirroring `claude-failover-proxy` at `configuration.nix:44` (confirmed the module
header is `{ config, pkgs, lib, ... }:` with no `localPkgs`). All five MINORs and the
six NITs are fixed or explicitly documented, the percent boundary is now a direct
`/100` clamp with a `percent:1→0.01` test, the `_selectNext` reactivation guard is
correct *and* does not over-block, and Phases 1–4 (the proactive load-bearing half)
remain line-accurate and pass against the real fixture + existing suite. The fresh
pass surfaced only MINOR/NIT-level residue, all confined to the **explicitly
additive, fail-safe, Phase-7-gated** reactive backstop (a non-expiring scope entry
when no reset is known; healthy probes not correcting a reactively-marked scope; a
stale-reset skew in `computeRetryAfterSeconds`) plus cosmetic line-ref drift in Task
6.2. None block starting or completing the bulk of the work; the riskiest phase is
gated. **APPROVE-FOR-IMPLEMENTATION.**

---

## 2. PART A — prior-finding resolution

| Prior finding | Status | Note (checked against real code) |
|---|---|---|
| **MAJOR-1** mid-stream classifier can't see the primary shape | **FIXED** | `limit-classify.js` predicate (plan 1000–1002) is `type==='usage_limit_error' \|\| /usage limit has been reached/i.test(msg)` — **no `status===429` gate**. Hand-traced `classifyLimitResponse(200,{},{type:'error',error:{type:'rate_limit_error',message:'The usage limit has been reached'}})` → `THROTTLE_RE` (`/temporarily limiting requests\|not your usage limit/i`) runs first (plan 991) and misses → returns `{kind:'usage_limit'}`, not `unknown`. The issue-#5 body ("temporarily limiting requests") still returns `{kind:'throttle'}` regardless of status. Task 5.2b test (plan 1082–1087) now asserts the message-based 200 shape, not the invented type. |
| **MAJOR-2** cloudbox `localPkgs` out of scope | **FIXED** | Verified `hosts/cloudbox/configuration.nix:14` is `{ config, pkgs, lib, ... }:` (no `localPkgs`); the precedent `claude-failover-proxy = pkgs.callPackage ../../pkgs/claude-failover-proxy { };` is at `:44` with the explanatory comment at `:42–44`. Plan Task 6.2 (1285–1304) adds `teamclaude = pkgs.callPackage ../../pkgs/teamclaude { };` to the `let` and uses `${teamclaude}/bin/teamclaude server --headless` — the correct mirror. (See PART B NIT-A on line-number drift.) |
| **MINOR-1** `percent===1` silently 100% | **FIXED** | Plan Task 1.2 (262–263) computes `Math.max(0, Math.min(1, pct/100))` directly and uses `normalizeUsageBucket` *only* for `resets_at` (266), bypassing the `oauth.js:153-154` `>1?/100:x` heuristic. Boundary test `percent:1→0.01` present (225–231). |
| **MINOR-2** `_selectNext` refactor non-behavior-preserving + untested | **FIXED** | Guard added (plan 758–759): reactivation now also requires `!rateLimitedUntil \|\| rateLimitedUntil <= Date.now()`, against the unchanged block at `account-manager.js:321-327`. Regression test present (766–775). Re-derivation below confirms it is correct and **does not over-block** legitimate reactivations. |
| **MINOR-3** `scopedResetFromHeaders` undefined/untested | **FIXED** | Defined + `export`ed (plan 1182–1186), unit-tested for the `×1000` path and the `{}→null` path (1131–1134). `parseInt(undefined,10)→NaN→null` verified. |
| **MINOR-4** `scopedThreshold` config not wired | **FIXED** | Plan Task 2.1 (449) adds `const scopedThreshold = config.scopedThreshold \|\| 0.90;` near `index.js:114` and passes it as the 3rd ctor arg — matches the existing `config.switchThreshold` read at `index.js:114-115`. |
| **MINOR-5** design m6 drift-log dropped silently | **FIXED (substantively)** | Plan risk-register item 6 (1391) records the drop + rationale (Opus-absence is the healthy state per design §2.5/§12.2). Residual doc nit: design `§13` (`...-design.md:280`) still lists "m6 wire-drift log" inline among resolved items without a "dropped" annotation, so the two docs agree only because the *plan* now says so. Cosmetic; not implementer-affecting. |
| **NIT-1** `computeRetryAfter` line range | **FIXED** | Plan Task 3.2 (825) now says delete `server.js:486-496` (whole function incl. closing brace). Confirmed the function spans exactly 486–496. |
| **NIT-2** diverts never set `probing` | **FIXED (documented)** | Plan Task 2.3 note (571–575) documents the intended divergence (divert uses `_pickBestAvailable`, not `_selectNext`, so no `probing`/`requalify`). |
| **NIT-3** cancel/text reorder | **FIXED** | Plan Task 5.3 (1148–1153) makes the reorder mandatory and explicit: delete the unconditional `:308` cancel; terminal branch reads `text()`, non-terminal branch cancels. |
| **NIT-4** assert-only "red" test | **FIXED** | Plan Task 4.1 (862–866) labels it a regression guard, not strict red→green. |
| **NIT-5** non-streaming 200 error body uncovered | **FIXED** | Risk-register item 7 (1392) records it as an accepted non-goal. |
| **NIT-6** scoped CLI line inside the unified-null guard | **FIXED (documented)** | Plan Task 4.1 note (881–886) explains the probe populates unified+scoped together, so the `index.js:497` guard holds in practice. |
| **Task 5.2 overloaded** | **FIXED** | Split into 5.2a (`markScopeExhausted` unit, plan 1027) and 5.2b (server wiring + integration, 1074). |
| **static-import-only for `classifyLimitResponse`** | **FIXED** | Task 5.2b step 3 (1092) mandates a static `import`, forbids the dynamic `await import(...)`. `limit-classify.js` has no imports, so no new cycle. |

### MINOR-2 guard — full re-derivation (does it over-block?)

No. Walked the path against `account-manager.js`:
- A throttled account whose `rateLimitedUntil` has **passed** is reactivated by
  `_isAvailable` (`:99-104`, sets `status='active'`, nulls `rateLimitedUntil`)
  *during* `_pickBestAvailable` (`:256`), which runs before the fallback. So by the
  time the fallback's guard reads `soonestAccount.rateLimitedUntil`, it is already
  `null` for any throttle that truly elapsed → guard clause `!rateLimitedUntil` is
  true → reactivation is **allowed**. The "rateLimitedUntil passed but other windows
  future" case the brief asks about therefore never reaches the fallback as a
  *throttled* account.
- The only case the guard blocks is exactly the bug it targets: `rateLimitedUntil`
  still in the future while `_soonestResetMs` (plan 720–734, min across *all* fields
  incl. a stale already-passed `unified7dReset`) returns a past time. Confirmed the
  original first-truthy reset (`:310-313`) hid this because `rateLimitedUntil` came
  first; `_soonestResetMs` exposes it; the guard re-suppresses it. The regression
  test (plan 766–775) covers it.

Verdict: guard is correct and not over-eager.

---

## 3. PART B — fresh findings

### BLOCKER
None.

### MAJOR
None. The original two MAJORs are resolved against real source; nothing the
revisions introduced rises to MAJOR.

### MINOR

#### MINOR-A — A reactively-marked scope can become **non-expiring** when no reset is known
`markScopeExhausted` (plan Task 5.2a, 1054–1063) sets
`resetAt: resetAtMs ?? account.quota.unified7dReset ?? null`. The scoped-expiry
sweep added in Task 1.4 only deletes entries with a *truthy* `resetAt`
(`if (sl?.resetAt && now >= sl.resetAt)`, plan 385, mirroring
`account-manager.js:119-157`). So if both `resetAtMs` and `unified7dReset` are
`null` (a fresh/un-probed account, or a 429 whose headers lacked
`anthropic-ratelimit-unified-7d-reset` so `scopedResetFromHeaders`→`null`), the
class is marked exhausted with `resetAt:null` and `_clearExpiredQuotas` will
**never** drop it. R1 never hit this because the mid-stream arm was inert (old
MAJOR-1); R2's fix makes `markScopeExhausted` reachable on the primary shape, so the
edge is now live. Fail-safe in direction (over-diverts *away* from a possibly-fine
account, never routes *into* a limit), but unbounded in duration.
**Fix:** in `markScopeExhausted`, default the reset to a bounded window when nothing
is known, e.g. `resetAt: resetAtMs ?? account.quota.unified7dReset ?? (Date.now() + 7*86400_000)`,
and/or have `_clearExpiredQuotas` treat a null-`resetAt` scoped entry as expired
after a max age. Cite the §6 m2 "approximate reset" rationale.

#### MINOR-B — A healthy probe does **not** correct a reactively-marked scope (merge keeps it)
`applyUsageData` merges (`q.scopedLimits = { ...q.scopedLimits, ...usage.scopedLimits }`,
plan Task 1.3, 343). For a healthy account, `parseUsagePayload` returns a
`scopedLimits` with **no `opus` key** (the real fixture
`usage-account0-healthy.json` has only a `Sonnet` weekly_scoped entry and no Opus
entry at all). So a falsely- or coarsely-attributed `opus` exhaustion from the
backstop is **not** overwritten by subsequent 90s probes — it persists until
`resetAt` (up to ~7d via MINOR-A's `unified7dReset` fallback) or restart. Compounded
by `scopeFromBody` returning `null` for a body with no `scope` (plan 1011–1016) →
the backstop marks the *request's* class even if the underlying limit was unified —
a single mid-stream "usage limit has been reached" event can divert a whole class
off an account for the rest of the weekly window. Again fail-safe in direction and
Phase-7-gated, but worth an explicit bound.
**Fix:** note this interaction in §6/Phase 7; consider letting a probe that returns
a class as healthy/`is_active:false` clear a prior reactive exhaustion for that class
(i.e. reconcile reactive marks against the authoritative `limits[]` on each probe),
or shorten the reactive `resetAt` default (MINOR-A).

#### MINOR-C — `computeRetryAfterSeconds` consumes stale/past reset fields (narrower upstream lost)
`_soonestResetMs` (plan 720–734) does not filter past timestamps, so an unpaired
stale `unified7dReset` (set without `unified7d`, which `_clearExpiredQuotas:133`
won't null) drags the min into the past; `computeRetryAfterSeconds` (plan 811–819)
then floors it to `1`. The deleted upstream `computeRetryAfter`
(`server.js:486-495`) only looked at `rateLimitedUntil || resetsAt`, so it returned
the *real* throttle window (e.g. 10s) in this case. Net: in the unpaired-stale-field
edge, R2 hands the client a too-short `retry-after` (1s) and it re-polls more
aggressively until the real window passes. The MINOR-2 guard fixes the dangerous
*reactivation* but not this *retry-after* skew (different consumer). Low-harm (extra
429s), edge-triggered.
**Fix:** in `_soonestResetMs`, skip candidates `<= Date.now()` for the
`computeRetryAfterSeconds` consumer (or have that method ignore already-passed
resets), while keeping past-detection for the `_selectNext` reactivation path.

### NIT

- **NIT-A** — Task 6.2 line refs drift from the live file. The plan cites the
  checkout launch at `configuration.nix:760-771` and the obsolete comment at
  `:722-730`/`:762-765`; the actual `ExecStart` script is `765-776`, the checkout
  existence check is `767-770`, and the `~/projects/teamclaude` comment block is
  `727-738`. The structural instruction (drop the checkout `-f` guard at 767–770,
  keep the config guard, `exec ${teamclaude}/bin/teamclaude server --headless`) is
  correct; only the numbers are stale. An implementer searching for `ExecStart`
  lands right.
- **NIT-B** — Reactive tests remain hypothesis-shaped, not capture-shaped. The
  5.1/5.2b/5.3 bodies (`{type:'error',error:{type:'rate_limit_error',message:'The
  usage limit has been reached'}}`) are now aligned to the design §1.1 *observed
  symptom message* (a real improvement over R1's invented `usage_limit_error` type),
  but the *envelope* (mid-stream SSE error inside a 200; 429 body shape) is still
  unconfirmed pending `workstation-yuz7`. The plan is honest about this (Phase 5
  intro evidence-gate; Phase 7 tightening), and the classifier defaults to back-off
  on anything unrecognized, so the residual false-confidence is bounded. Acceptable;
  do not let the green 5.x suite be read as "the real limit path is verified."
- **NIT-C** — `parseSSEUsage` error arm gating. The arm is `else if (data.type ===
  'error' && modelClass)` (plan 1096). Confirmed against `server.js:459-473` it lands
  after the `message_delta` branch and that `parseSSEUsage` already JSON-parses every
  `data:` line, so a non-`error` event (`message_start`, `ping`, etc.) is untouched
  and an `overloaded_error`/transient error → `classifyLimitResponse` → `unknown` →
  no mark (predicate is the verbatim "usage limit has been reached", narrow enough to
  not catch overloaded/transient strings). Marking mid-stream after the client got
  bytes is safe given opencode re-dispatches; only caveat is the attribution/duration
  bound captured in MINOR-A/B.

### Cross-checks that PASSED (no action)

- **Task 5.3 cancel/text reorder vs `server.js:299-326`:** correct. `retryAfter` is
  computed at `:304-306` *before* the branch (plan keeps it there); the unconditional
  `:308` cancel is deleted; the terminal branch (`retryCount >= maxRetries`) reads
  `await upstreamRes.text()` once; the non-terminal path keeps `await
  upstreamRes.body?.cancel()` (plan 1174) followed by the unchanged wait+retry
  (`:321-325`). A body is read XOR cancelled on each path — never both. If `text()`
  throws it's caught → `bodyJson=null` → `unknown` → back-off (fail-safe).
- **`modelClass` threading after the 5.2 split + 5.3 rewrite:** holds. Initial call
  `server.js:88` passes `reqModelClass` (plan 669); recursion at `:234` and `:390`
  threaded by Task 2.4; both new terminal re-dispatches (plan 1166, 1171) and the
  preserved non-terminal retry pass `modelClass` as the trailing arg; `streamResponse`
  (`:407`, one call site `:361`) and `parseSSEUsage` (`:459`, call sites `:434`/`:450`)
  receive it. Sequencing hazard (2.4 before 5.3; preserve threading through the
  rewrite) is called out at plan 1122–1126.
- **`/100` change vs `resetAt`:** `normalizeUsageBucket({resets_at: lim.resets_at})?.resetAt`
  (plan 266) returns the parsed ms; the discarded `utilization:null` from that call is
  irrelevant. No NaN/clamp escape: non-numeric `percent`→`parseFloat`→`NaN`→`null`;
  negative→clamped to 0; >100→clamped to 1. Matches `usage-payload.test.js` against the
  real fixture (sonnet `4→0.04`, resetAt `Date.parse('2026-06-26T04:00:00.128531+00:00')`).
- **Existing suite stays green under the full R2 set:**
  - `server-429.test.js` — upstream body `{error:{type:'rate_limit_error'}}` (no
    message) and request `model:'x'` (→ `reqModelClass=null`). Terminal branch:
    `classifyLimitResponse(429,h,{type:undefined? }...)`→`unknown`; `&& modelClass`
    is `null` anyway → falls to `markRateLimited` + re-dispatch. Returns 429,
    account `throttled`, `upstreamHits` 2 (∈[1,4]). Both tests pass.
  - `rotation-priority.test.js` — every case leaves ≥1 account available, so
    `_selectNext` returns via `_pickBestAvailable` and never enters the refactored
    fallback; `_pickBestAvailable()`/`_selectNext()` are still called with no
    `modelClass` (class-free). Green.
  - `quota-probe.test.js` — `normalizeUsageBucket` unchanged; `parseUsagePayload`
    returns a superset; `applyUsageData` merge only adds `scopedLimits`. Green.
  - `quota-persistence.test.js` — `exportQuotaState` top-level key assert
    (`quota-persistence.test.js:15`) checks the *entry* keys, not `quota` sub-keys, so
    appending `'scopedLimits'` to `PERSISTED_QUOTA_FIELDS` is invisible to it; `{}`
    round-trips through JSON; `restoreQuotaState`'s `!= null` guard accepts the object.
    Green.
- **ESM cycle (oauth↔account-manager via `modelClass`):** benign — `modelClass` is a
  pure top-level export, only *called* at runtime inside `parseUsagePayload`; neither
  module uses a cross-imported binding at module-eval time. Confirmed `eslint.config.js`
  has **no** `eslint-plugin-import`/`import/no-cycle` rule, so Task 5.4 lint won't trip.
  New built-ins used by R2 (`Math`, `Number.isFinite`, `parseInt/Float`, `Object.*`,
  `||=`, `?.`, `??`) are all already used in the baseline under `ecmaVersion: 2022`.

### UNVERIFIABLE FROM REPO (judged against the Phase-7 gate)

- **Anthropic limit wire-shapes** (mid-stream 200 SSE envelope; terminal 429 body;
  whether `error.type` is the shared `rate_limit_error` vs a structured discriminator;
  whether headers carry a scoped reset) — not in the repo. The plan's Phase-5
  conservatism (`THROTTLE_RE` first; `unknown`→back-off; never mark on an unrecognized
  signal) + Phase-7 capture-gating make these assumptions **safe** to ship behind:
  worst case is under-detection, not the issue-#5 misclassification storm.
- **Not-yet-captured real LIMIT fixture** (`workstation-yuz7`) — Phase 7 is explicitly
  blocked on it and is where predicates/`scopeFromBody`/reset-source get tightened.
  MINOR-A/B above should be revisited there.
- **aarch64-linux cloudbox cross-build + `nixos-rebuild switch --flake .#cloudbox`** —
  cannot run on this macOS host; the plan correctly defers the switch to a cloudbox
  session (Task 6.2 step 2) and only requires `nix flake check`/eval locally.
- **GitHub fork existence/owner `johnnymo87`** — external; Phase 0 confirms
  interactively. Safe.

The Phase-ordering (1–4 proactive, high-confidence → 5 reactive, additive + fail-safe
→ 6 deploy → 7 capture) means none of the unverifiable items gate the load-bearing
proactive work, and the reactive residue (MINOR-A/B/C) lives entirely inside the
gated, fail-safe phase.

---

VERDICT: APPROVE-FOR-IMPLEMENTATION

---

## R2.1 disposition (author response, 2026-06-21)

Approved. The three fresh MINORs were folded in immediately (plan now R2.1):
- **MINOR-A** — `markScopeExhausted` now defaults `resetAt` to a bounded 7-day window
  (`resetAtMs ?? unified7dReset ?? Date.now()+7d`), never null, so a reactive mark always
  expires; added a test asserting the bound + that `_clearExpiredQuotas` drops it.
- **MINOR-C** — `_soonestResetMs` gained `{ onlyFuture }`; `computeRetryAfterSeconds`
  passes `onlyFuture:true` so an unpaired stale past field can't floor retry-after to 1s;
  the `_selectNext` reactivation path keeps `onlyFuture:false` to still DETECT a past reset
  (MINOR-2 guard intact). Added a regression test.
- **MINOR-B** — recorded as risk-register item 8 (now bounded by MINOR-A, fail-safe in
  direction) and Phase 7 Step 3b (reconcile reactive marks against authoritative `limits[]`
  once the real shape is captured; tag reactive entries so a healthy probe can clear them).
- **NIT-A** — Task 6.2's `${teamclaude}` ExecStart + `pkgs.callPackage` let-binding are
  correct; only the cited line numbers drift. An implementer searching for `ExecStart` /
  `~/projects/teamclaude` lands right; left as-is.
