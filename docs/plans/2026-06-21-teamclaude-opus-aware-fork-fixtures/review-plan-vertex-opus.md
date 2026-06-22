# Pre-implementation review of the teamclaude opus-aware fork PLAN (Vertex Opus 4.8)

Method: every code-level claim in the plan was checked against the actual upstream
tree at `/tmp/teamclaude-review` (git `654ace1`, npm `1.0.7`) and against the
workstation deploy files. The captured fixture
(`usage-account0-healthy.json`) was used to trace the parser. Where a claim
depends on an un-captured Anthropic wire shape, an external GitHub fork state, or
an aarch64 cross-build that can't run on this macOS host, it is marked
**UNVERIFIABLE FROM REPO** and judged as an assumption, with attention to whether
the plan's own evidence-gating makes that assumption safe. Every file:line below
was opened and confirmed.

---

## 1. Summary verdict

This is a strong, faithful plan: it implements the approved R2 decisions without
meaningful scope creep, its line-references are accurate to the upstream tree, the
TDD steps are mostly bite-sized, and Phases 1–4 (the proactive `limits[]`→
`scopedLimits` half — the part that actually carries the load) are correct and
will pass against both the real fixture and the existing suite. The stateless
`getActiveAccountFor` overlay genuinely resolves the M1 thrash, the `_soonestResetMs`
unification is the right shape, and the `classifyLimitResponse` IP-throttle guard
is fail-safe by construction. However, two concrete defects in the lower-confidence
phases keep this from being merge-ready as written: (a) **the mid-stream backstop's
own classifier can structurally never fire on the design's stated *primary* limit
shape** (a `rate_limit_error`-typed "usage limit has been reached" message inside a
200 stream), because the message predicate is gated on `status === 429` while the
mid-stream call passes `200` — and the Phase 5 test masks this by asserting an
*invented* `usage_limit_error` type; and (b) **the cloudbox Phase 6.2 snippet
references `localPkgs.teamclaude`, which is not in scope in
`hosts/cloudbox/configuration.nix`** (a NixOS module that `callPackage`s local pkgs
directly), so it will fail to evaluate. Both are localized and easily fixed, plus a
handful of MINORs (a real `percent === 1` boundary bug inherited via
`normalizeUsageBucket`, an untested non-behavior-preserving `_selectNext` change, an
under-specified `scopedResetFromHeaders`, dropped `scopedThreshold` config wiring,
and the dropped m6 drift-log). Recommend **REVISE** — Phases 1–4 are
approve-worthy; the revisions are confined to Phase 5's classifier gate, Phase 6.2's
package reference, and the MINORs.

---

## 2. Findings by severity

### BLOCKER
None. Nothing prevents *starting* implementation; Phases 1–4 are fully specified and
correct, and the riskier phases are explicitly evidence-gated. The two MAJORs below
must be fixed before their respective phases ship, but they do not block Phase 1.

### MAJOR

#### MAJOR-1 — Mid-stream backstop cannot detect the design's primary limit shape
**Where:** plan Task 5.1 (`src/limit-classify.js`, lines 914–932 of the plan) +
Task 5.2 (`classifyLimitResponse(200, {}, data)`, plan line 993).

`classifyLimitResponse` only treats a body as a usage limit via:

```js
const isUsageLimit =
  type === 'usage_limit_error' ||
  (status === 429 && /usage limit has been reached/i.test(msg));
```

The mid-stream arm calls it with `status = 200` (plan Task 5.2, line 993:
`classifyLimitResponse(200, {}, data)`). So mid-stream, the message branch is
**unreachable** — detection collapses to `type === 'usage_limit_error'`, a type for
which there is **zero evidence** (it is invented by this plan). But design §1.2/§6
state the limit "commonly arrives as a *mid-stream SSE error inside a 200*", and the
§1.1 symptom is the **verbatim message** "The usage limit has been reached" — which,
if it carries the shared `rate_limit_error` type (design §6 explicitly warns the type
is shared), will be classified `unknown` mid-stream and **never mark the scope**. The
Task 5.2 test passes only because it feeds the invented `usage_limit_error` type, so
the suite gives false confidence that mid-stream detection works.

This is fail-safe (unrecognized → back-off, never a misclassification storm) and the
plan gates tightening to Phase 7, so it does not endanger Phases 1–4. But as written,
the Phase 5 mid-stream mechanism is effectively inert for the most-likely real shape,
and the plan presents it as functional.

**Suggested change:** Drop the `status === 429` qualifier from the message clause
(the `THROTTLE_RE` check already runs first and protects the IP-throttle case
regardless of status, so a message-based usage-limit predicate is still
IP-throttle-safe at 200). Then change the Task 5.2 test to assert the *message-based*
200 shape (`{type:'error',error:{type:'rate_limit_error',message:'The usage limit has
been reached'}}`) is recognized, not the invented type. Keep the `usage_limit_error`
type branch as a forward-compatible bonus, but do not let it be the only mid-stream
path. Add a code comment that the predicate is provisional until the Phase 7 capture.

#### MAJOR-2 — Phase 6.2 cloudbox ExecStart uses `localPkgs`, which is out of scope there
**Where:** plan Task 6.2 (lines 1141–1150), targeting
`hosts/cloudbox/configuration.nix:760-771`.

The plan's snippet is `exec ${localPkgs.teamclaude}/bin/teamclaude server --headless`,
"mirroring devbox's `home.devbox.nix:615`." But devbox's reference works because
`users/dev/home.devbox.nix` is a **home-manager** module that receives `localPkgs`
in its arg set (`home.devbox.nix:3` → `{ config, pkgs, lib, localPkgs, ... }`;
uses it at `:556` and `:615`). `hosts/cloudbox/configuration.nix` is a **NixOS
system** module that does **not** receive `localPkgs` — the file says so explicitly
(`configuration.nix:42-44`: "NixOS configs don't receive the flake's localPkgs, so
callPackage it directly here") and demonstrates the correct pattern for
`claude-failover-proxy` (`configuration.nix:44`:
`claude-failover-proxy = pkgs.callPackage ../../pkgs/claude-failover-proxy { };`).
Copying the plan's snippet verbatim yields an undefined-variable eval error. Also
note the cloudbox unit is `systemd.services.teamclaude` (system,
`configuration.nix:744`), not the user service devbox uses — so it's not a 1:1 mirror.

**Suggested change:** Add `teamclaude = pkgs.callPackage ../../pkgs/teamclaude { };`
to the `let` block (`configuration.nix:16-64`, next to `claude-failover-proxy` at
:44), then use `exec ${teamclaude}/bin/teamclaude server --headless` in the ExecStart
script. Remove the `~/projects/teamclaude/src/index.js` existence check
(`configuration.nix:762-765`) and the now-obsolete comment block (`:722-730`).

### MINOR

#### MINOR-1 — `normalizeUsageBucket` reuse: `percent === 1` is silently `100%`
**Where:** plan Task 1.2, line 243
(`normalizeUsageBucket({ utilization: lim.percent, resets_at: lim.resets_at })`)
against `oauth.js:151-155`.

`normalizeUsageBucket` divides by 100 only when the raw value is `> 1`
(`oauth.js:153-154`). For `limits[].percent`, which is *definitively* a 0–100 integer
(fixture: `session` 3, `weekly_all` 11, `weekly_scoped` 4), the value `1` (a 1%-used
scope) is left as `1.0` → interpreted as **100% exhausted**. If such an entry is also
`is_active`, `_isNearQuota(acct, class)` trips on `utilization >= scopedThreshold`
(plan Task 2.1, line 435) and the scope is treated as exhausted at 1% usage. The plan
acknowledges the ambiguity in a comment (plan lines 218–219) and deliberately steers
the test away from `1`, so the test cannot catch it and the bug ships latent. (Note:
this is a pre-existing upstream quirk for the unified probe buckets too — a 1%
`five_hour` from a probe becomes `1.0` via the same path — so the fork merely
propagates it to scoped limits.)

**Suggested change:** For `limits[]`, compute `utilization = clamp01(lim.percent /
100)` directly (the scale is known) rather than reusing the `>1` heuristic; keep
`normalizeUsageBucket` only for the ISO `resets_at` → ms parse. Add an explicit test
at `percent: 1` asserting `0.01`.

#### MINOR-2 — `_selectNext` fallback refactor is NOT strictly behavior-preserving (and untested)
**Where:** plan Task 3.1 (`_soonestResetMs`, lines 693–707; `_selectNext` fallback,
lines 711–719) against `account-manager.js:305-329`.

The plan claims the `_selectNext` change is "behavior-preserving (esp. the
`soonestTime <= now` reactivation block)." It is not, strictly. The current fallback
computes per account a **first-truthy** reset:
`rateLimitedUntil || unified5hReset || unified7dReset || resetsAt`
(`account-manager.js:310-313`). `_soonestResetMs` instead takes the **min across all**
fields, *additionally* including `unified7dSonnetReset` and every `scopedLimits[*].resetAt`.
These diverge whenever a non-first field is the smallest. The dangerous case: an account
that is genuinely rate-limited (`rateLimitedUntil` in the future) but carries a stale,
already-passed quota reset in another field → `_soonestResetMs` returns a past time →
the *unchanged* reactivation block (`account-manager.js:321-327`) sets
`status='active'`, clears `rateLimitedUntil`, and returns a still-throttled account.

Existing tests stay green only because `rotation-priority.test.js` never drives all
accounts unavailable into the fallback (every case leaves one available → returns via
`_pickBestAvailable`), and `server-429.test.js`'s single-account throttle path was
traced and still returns 429 correctly. So the change is low-harm (worst case: one
extra 429/re-throttle) and undetected — but the plan should not assert
"behavior-preserving."

**Suggested change:** Either keep `rateLimitedUntil` precedence for the reactivation
decision (a throttled account cannot return before `rateLimitedUntil` regardless of
quota windows), or add an explicit test for "rate-limited account with a stale quota
reset is NOT prematurely reactivated," and soften the plan's wording to
"behavior-equivalent for the cases the suite exercises."

#### MINOR-3 — `scopedResetFromHeaders` is referenced but never defined or tested
**Where:** plan Task 5.3, line 1035
(`const resetMs = scopedResetFromHeaders(headers);`) and the prose at line 1048.

The terminal-429 backstop calls a helper that the plan only describes ("reads
`anthropic-ratelimit-unified-7d-reset` (×1000) … or null") but never gives an
implementation or a test for. An implementer will guess at header casing (it's
lowercase after `Object.fromEntries(upstreamRes.headers.entries())`, fine) and the
×1000 unit. Under-specified for a value that feeds `markScopeExhausted`.

**Suggested change:** Specify the helper inline with a one-line unit test:
`scopedResetFromHeaders({'anthropic-ratelimit-unified-7d-reset':'1700000000'})
=== 1700000000000`, and `=== null` when absent.

#### MINOR-4 — `scopedThreshold` configurability dropped vs design §8
**Where:** plan Task 2.1 (ctor default `scopedThreshold = 0.90`, line 428); design §8
("Optional per-class `switchThresholds` override").

The plan adds the third ctor parameter but never wires `index.js:114-115`
(`new AccountManager(accounts, threshold)`) to read a config key, so the scoped
threshold is hardcoded at 0.90 in every deployment. The design framed configurability
as optional, so this is within scope to drop — but it's a silent divergence from a
design decision and should be stated, since "severity is the primary signal" only
holds if a `severity !== 'normal'` actually appears (open question §12).

**Suggested change:** Either wire `config.scopedThreshold` (mirroring
`config.switchThreshold` at `index.js:114`) into the ctor call, or note explicitly in
the plan that scoped configurability is intentionally deferred.

#### MINOR-5 — Design m6 wire-drift log is silently dropped
**Where:** design §9/§13 ("m6 wire-drift log"); plan has no corresponding task.

Design §13 lists m6 (log once if a probe returns a Sonnet scope but the expected
Opus key/scope is absent) as a resolved item. The plan never implements it. This is
arguably *correct* given §2.5/§12.2 found Opus-scope absence is the normal healthy
state (logging it would be noise), but it is a fidelity gap against a design item
marked resolved.

**Suggested change:** Either add a guarded one-shot log keyed on a *real* drift
signal (e.g. an unexpected unscoped weekly shape), or update design §13 to record m6
as "dropped: Opus absence is expected per §2.5," so design and plan agree.

### NIT

- **NIT-1** — `computeRetryAfter` spans `server.js:486-496` (closing brace at 496);
  plan Task 3.2 (line 770) says "486-495." Delete the whole function. Harmless.
- **NIT-2** — Diverted accounts never get `probing` set. `getActiveAccountFor`'s
  divert path calls `_pickBestAvailable` directly (plan Task 2.3, line 546), which —
  unlike `_selectNext` (`account-manager.js:298`) — does not set
  `best.probing = best.quota.unified7dReset == null`. So a diverted account with an
  unknown weekly window won't flag `requalify` on its next live response
  (`account-manager.js:352`). Low impact (the diverted account isn't `currentIndex`),
  but worth a comment.
- **NIT-3** — Task 5.3 correctness hinges on reordering so `upstreamRes.body?.cancel()`
  (`server.js:308`) runs **only** on the non-terminal path; the snippet is partial.
  If botched (cancel before `upstreamRes.text()`), `text()` throws → caught →
  `bodyJson = null` → `unknown` → back-off, i.e. it fails safe. Call this out so the
  implementer doesn't leave the unconditional `:308` cancel in place.
- **NIT-4** — Task 4.1's assert-only test "likely PASS already" (plan line 807)
  violates strict red→green TDD; it's a regression guard, which is fine, but say so.
- **NIT-5** — Non-streaming 200 responses carrying an error JSON body are not covered
  by the backstop (only pre-stream 429 and mid-stream SSE). Almost certainly not a
  real limit shape; note it as a known non-goal.
- **NIT-6** — Plan Task 4.1 puts the scoped CLI line *inside* the
  `if (q.unified5h != null || q.unified7d != null || q.unified7dSonnet != null)`
  block (`index.js:497-502`); an account with `scopedLimits` but null unified data
  would fall to the `else` and not print it. The probe sets unified+scoped together,
  so this is fine in practice.

---

## 3. Answers to the six evaluation areas

### Area 1 — DESIGN→PLAN FIDELITY
Faithful. Verified each approved decision:
- **Generic `limits[]`-driven `scopedLimits`, not flat `seven_day_opus`:** ✅
  `parseUsagePayload` (plan Task 1.2) builds the map from `limits[]` entries with
  `group==='weekly'` and `scope.model` set; it does **not** add a `sevenDayOpus`
  field. Matches §0/§4.
- **Generic gating via `is_active`/`severity`:** ✅ `_isNearQuota` (plan Task 2.1,
  lines 431–437) keys on `isActive`, then `severity !== 'normal'`, then threshold —
  exactly §4. Sonnet gating is applied uniformly and is driven by `is_active`
  (M5 accepted, tested in Task 2.1).
- **MITM scoped out:** ✅ `src/mitm.js` is untouched; plan §"Scope guard" (line 47)
  and Phase 6 caveat hold.
- **Reuse `quotaProbeSeconds`, on-by-default only in deploy not code:** ✅ no new
  config keys; `prober.js` default stays off. **Caveat:** the fork "default 90" is
  applied *imperatively* via `teamclaude probe 90` at deploy (plan line 1175), not as
  committed config — so a reseed/redeploy could lose it. Minor; design §8 implied a
  declarative "fork deploy config."
- **Stateless `bestAccountFor`/`getActiveAccountFor`, no `currentIndex` thrash:** ✅
  (named `getActiveAccountFor`; design called it `bestAccountFor` — naming only). See
  Area 2.
- **Rewrite `computeRetryAfter` to soonest of ALL resets, unified with `_selectNext`:**
  ✅ `_soonestResetMs` is the single source used by both `computeRetryAfterSeconds`
  and the `_selectNext` fallback (with the MINOR-2 caveat).
- **Real-fixture tests:** ✅ Task 1.2 asserts against `usage-account0-healthy.json`;
  the limit fixture is deferred to Phase 7 per §10/§12.
- **Deploy via `fetchFromGitHub`, cloudbox unified on nix pkg:** ✅ intent matches;
  see MAJOR-2 for the cloudbox mechanics.

Drift to flag: MINOR-4 (`scopedThreshold` configurability dropped), MINOR-5 (m6
drift-log dropped), and the imperative-vs-declarative probe-enable above. Additions
beyond design are all justified and in-spirit: `parseUsagePayload` (pure extraction
for fixture testing), `markScopeExhausted`, `classifyLimitResponse`/`limit-classify.js`,
`scopedResetFromHeaders` (under-specified, MINOR-3).

### Area 2 — CODE CORRECTNESS
All cited line numbers are accurate to upstream `654ace1`. Spot-confirmed: body
buffer `server.js:84`; initial `forwardRequest` `:88`; signature `:203`; selection
`:207`; no-account branch `:211-212`; recursive self-calls `:234,:318,:325,:390`;
429 block `:299-326`; blind `cancel()` `:308`; `parseSSEUsage` `:459-473`;
`computeRetryAfter` `:486-496`. account-manager: `emptyQuota` `13-30`,
`PERSISTED_QUOTA_FIELDS` `7-11`, `_selectNext` fallback `305-329`, `_isNearQuota`
`213-233`, `_pickBestAvailable` `246-269`, `_clearExpiredQuotas` `119-157`,
`applyUsageData` `422-446`, `getStatus` `597-615`. index.js status printer `490-512`
(insert at `500-502`), probe floor `726`. tui.js account line `548-554`. All correct.

- **Task 1.2 `parseUsagePayload` + the oauth↔account-manager ESM cycle:** **Benign.**
  The cycle is `account-manager.js:1` (imports oauth) ↔ new `oauth.js` import of
  `modelClass`. It is safe in *both* entry orders because neither module *invokes* the
  other's imported binding at module-evaluation time — `modelClass` is only called
  inside `parseUsagePayload` (runtime), and `refreshAccessToken`/`isTokenExpiringSoon`
  only inside method bodies. The precise guarantee is "no top-level use of the
  cross-imported binding" (the plan's phrasing "no module-load side effects" gets the
  right conclusion). I confirmed the fork's `eslint.config.js` has **no**
  `eslint-plugin-import`/`import/no-cycle` rule, so Task 5.4's lint gate will not trip
  on it either. **Recommendation:** ship as-is; the `src/model-class.js` extraction
  (plan's fallback, lines 266–269) is the cleaner long-term form and worth doing
  pre-emptively if you ever add `import/no-cycle`, but it is not required now.
  The fixture trace is correct: `five_hour 3.0→0.03`, `seven_day 11.0→0.11`,
  `seven_day_sonnet 4.0→0.04`, `scopedLimits.sonnet` present (`is_active:false`,
  `severity:'normal'`, `0.04`, `resetAt = Date.parse(...)`), `scopedLimits.opus`
  undefined. The synthetic active-Opus test also parses correctly. `quota-probe.test.js`
  stays green (it never asserts the `fetchUsage` object shape; `parseUsagePayload`
  returns a superset).
- **`normalizeUsageBucket` reuse / boundary at exactly 1:** handling is correct for
  every percent except `1` → see MINOR-1. The test deliberately avoids `1` (plan
  lines 218–219), so it passes but doesn't cover the bug.
- **Task 2.3 `getActiveAccountFor` (M1 thrash):** **Genuinely avoids the thrash.** It
  calls the mutating `getActiveAccount()` exactly once per request — identical to
  today's single call at `server.js:207` — so class-free primary rotation/log behavior
  is byte-for-byte preserved. The divert path is `_pickBestAvailable(modelClass)`
  (`account-manager.js:246-269`), which I confirmed performs **no** mutation of
  `currentIndex`/`probing`/logs. So mixed Opus/Sonnet traffic cannot flip the pointer.
  Edge cases check out: primary `null` → returns `null` (and a class filter can only
  *narrow* availability, so `_pickBestAvailable(class)` would also be null — correct →
  caller 429); preemption mirrors `getActiveAccount` (strictly-lower priority only,
  stays sticky within a tier); the three Task 2.3 tests trace correctly, and
  `currentIndex` stays `0` across the opus-divert + sonnet-stay sequence. The only
  leak of rotation state on the per-request path is the *same* mutation that happens
  today (via the inner `getActiveAccount()`), which is intended. NIT-2 (probing not set
  on diverts) is the lone behavioral nuance.
- **Phase 3 `_soonestResetMs` + `computeRetryAfterSeconds`; deleting server's
  `computeRetryAfter`; no-account branch:** `computeRetryAfterSeconds` is correct and
  the live-ms vs ISO-string shape change is *resolved by construction* — the
  computation moves into `AccountManager` and reads raw ms (`rateLimitedUntil`,
  `unified*Reset`, `scopedLimits[*].resetAt`) instead of `getStatus`'s ISO strings.
  The only caller of the deleted `computeRetryAfter` was `server.js:212`, so the delete
  is clean (no shape break). The `_selectNext` refactor is **not** strictly
  behavior-preserving (MINOR-2) but the existing suite stays green and `server-429`'s
  fallback was traced and still returns `429` with the right retry-after. The
  `soonestTime <= now` reactivation block is left textually unchanged but now consumes
  a different (broader-min) `soonestTime` — that's the source of MINOR-2.
- **Phase 5 classifier safety vs issue-#5:** **Safe against the IP-throttle trap.**
  `THROTTLE_RE` (`/temporarily limiting requests|not your usage limit/i`) is tested
  *first* and short-circuits to `{kind:'throttle'}`; the usage-limit predicate
  deliberately does **not** key on the ambiguous shared `rate_limit_error` type; and
  anything unrecognized is `{kind:'unknown'}` → back-off. So a misclassification storm
  (the issue-#5/#22 failure mode) cannot occur. The defect is the *opposite* —
  under-detection mid-stream (MAJOR-1) — not a false positive.
  **Buffering the terminal 429 body via `upstreamRes.text()`:** correct and safe
  relative to the non-terminal `cancel()`, *provided* the reorder is done (NIT-3); the
  body is unread at `:308`, so the first `text()`/`cancel()` is valid, and the terminal
  path never needs to reuse the response.
  **Mid-stream `parseSSEUsage` arm:** correct to keep **synchronous** with a static
  `import { classifyLimitResponse } from './limit-classify.js'` (the plan's
  `await importClassifier()` snippet on line 992 is the wrong variant; the plan itself
  steers to the static import on line 999 — make sure the implementer takes that one).
  Threading `modelClass` through `streamResponse` (`server.js:361,407`) and both
  `parseSSEUsage` call sites (`:434,:450`) holds.
  **Threading `modelClass` through all `forwardRequest` recursion:** holds — the four
  existing recursive calls (`:234,:318,:325,:390`) plus the initial call (`:88`) plus
  the two *new* re-dispatch calls in Task 5.3's terminal branch all pass it; I checked
  each. Note Task 2.4 and Task 5.3 both edit the 429 block/recursion — sequencing is
  fine (2.4 before 5.3) but 5.3 restructures what 2.4 touched, so the implementer must
  preserve `modelClass` threading through the rewrite.

### Area 3 — NIX/DEPLOY (Phase 6)
- **`fetchFromGitHub` + `cp -r .`:** **Correct.** The current `default.nix` already
  uses `cp -r . "$dest/"` with the wrapper pointing at `$dest/src/index.js`
  (`pkgs/teamclaude/default.nix:42-45`). With `fetchurl` the tarball unpacked to
  `./package`; with `fetchFromGitHub` `sourceRoot` is the repo root, where `src/` +
  `package.json` already sit at top level — so `cp -r .` copies the whole tree
  (incl. `test/`, harmless) and `$dest/src/index.js` still resolves. The plan's
  removal of the "unpacks into ./package" comment and header-bump note is right.
- **hash/rev bump:** correct approach (`nix store prefetch-file --json --unpack` on the
  GitHub archive yields the unpacked-tree SRI hash that `fetchFromGitHub` expects; or
  `nix-prefetch-github`). Per-commit churn is acknowledged (review n3).
- **cloudbox ExecStart unify:** **broken as written — see MAJOR-2** (`localPkgs` not in
  scope in the NixOS module; use a `pkgs.callPackage ../../pkgs/teamclaude { }`
  let-binding like `claude-failover-proxy` at `configuration.nix:44`). The `~lines
  744-771` reference is accurate (actual `744-775`).
- **UNVERIFIABLE FROM REPO:** the exact flake attr for `nix build .#teamclaude` (the
  plan hedges "or the flake attr path for this host"); the aarch64-linux cloudbox
  build cannot be exercised on this macOS host (the plan correctly defers the switch to
  a cloudbox session); and the GitHub fork's existence/owner (`johnnymo87`). Treated as
  assumptions; the plan's deferral is sufficient.

### Area 4 — TEST DESIGN
- **Real-fixture vs guesses:** Task 1.2 is genuinely fixture-driven (good). The Task
  1.2 synthetic active-Opus entry and the entire Phase 5 `limit-classify` suite are
  **hand-authored guesses** — the `usage_limit_error` type in particular is invented
  (no evidence). The plan is honest about this and gates tightening to Phase 7, but
  see MAJOR-1: the mid-stream test passing on the invented type *masks* a real
  reachability defect, so it's worse than a neutral guess — it's a false-green.
- **Coverage gaps:** no test for the `_selectNext` reactivation/`rateLimitedUntil`
  interplay (MINOR-2); none for `scopedResetFromHeaders` (MINOR-3); none for the
  `percent === 1` boundary (deliberately, MINOR-1); none asserting `getActiveAccountFor`
  leaves `probing`/`requalify` untouched (NIT-2). The pre-stream throttle-vs-usage-limit
  test correctly insists `server-429.test.js` stays green (the upstream body there is
  `{error:{type:'rate_limit_error'}}` with no message → `unknown`/`null` modelClass →
  back-off; traced, stays green).
- **Wrong assertions:** none are arithmetically wrong. The mid-stream Task 5.2 test is
  the problem case (passes, but for a shape that may not exist).

### Area 5 — SEQUENCING / GRANULARITY
Mostly clean red→green→commit. Issues:
- **Task 5.2 is overloaded:** it adds `markScopeExhausted` (account-manager) *plus*
  threads `modelClass` through `streamResponse`/`parseSSEUsage` *plus* the error arm
  *plus* "add an integration test in `server-model-routing`" — two source files and two
  test files in one task. Split into 5.2a (`markScopeExhausted` unit) and 5.2b
  (mid-stream wiring + integration test).
- **Task 2.4 / Task 5.3 overlap** the same 429 block and recursive calls; ordering is
  correct but call it out so 5.3's rewrite preserves 2.4's threading.
- Phase order (1–4 proactive → 5 reactive → 6 deploy → 7 capture) is sound and matches
  the design's risk posture: ship the high-confidence proactive path first, keep the
  reactive path additive and fail-safe.

### Area 6 — MISSING / BLOCKERS
No hard blocker to starting. Items an implementer would otherwise guess wrong:
`scopedResetFromHeaders` (MINOR-3, undefined); `scopedThreshold` config wiring
(MINOR-4); which `classifyLimitResponse` snippet variant to use (static import, not
`await importClassifier()`); the cancel/text reorder (NIT-3); and — most importantly —
that the mid-stream classifier as written can't fire on the design's primary shape
(MAJOR-1). The cloudbox `localPkgs` reference (MAJOR-2) blocks Phase 6.2 evaluation if
copied verbatim. All are localized and fixable without re-architecting.

---

## 4. Verdict

The plan is well-researched, line-accurate, and faithful to the approved R2 design;
Phases 1–4 are correct and ready. The two MAJORs (mid-stream classifier
status-gate masking the design's primary shape with a false-green test; cloudbox
`localPkgs` out-of-scope eval error) plus the MINORs (percent-1 boundary, the
non-behavior-preserving and untested `_selectNext` change, the under-specified
`scopedResetFromHeaders`, dropped `scopedThreshold` wiring, dropped m6 log) are
concrete and should be addressed — the first two before their phases ship — so the
plan needs a focused revision rather than a green light as-is.

VERDICT: REVISE

---

## 5. R2 disposition (author response, 2026-06-21)

All findings accepted; plan revised to R2. MAJOR-1: dropped the `status===429` gate
from the classifier message clause + Task 5.2 test now asserts the message-based 200
`rate_limit_error` shape (THROTTLE_RE still runs first → IP-throttle-safe). MAJOR-2:
cloudbox ExecStart now uses a `teamclaude = pkgs.callPackage ../../pkgs/teamclaude {}`
let-binding (verified `configuration.nix:14` is `{config,pkgs,lib,...}`, no `localPkgs`;
mirrors `claude-failover-proxy` at `:44`). MINOR-1: `limits[].percent` divided by 100
directly (clamped) + boundary test at `percent:1→0.01`. MINOR-2: reactivation guard on
`rateLimitedUntil` + regression test. MINOR-3: `scopedResetFromHeaders` defined inline +
unit test. MINOR-4: `config.scopedThreshold` wired into the ctor. MINOR-5: m6 drift-log
recorded as intentionally dropped (Opus absence is the expected healthy state per
§2.5/§12.2). NITs 1–6 + the Task 5.2 split (5.2a/5.2b) + static-import-only for the
classifier all applied.
