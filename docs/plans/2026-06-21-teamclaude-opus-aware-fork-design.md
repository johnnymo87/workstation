# Opus-aware teamclaude fork — Design (R2)

> **For the reviewer:** DESIGN doc (the "what and why"), not a task-by-task plan.
> Self-contained. **R2** supersedes R1 after a Vertex Opus 4.8 review and a real-payload
> capture from devbox that together forced a data-model pivot (see §0). The next step
> after approval is an implementation plan (separate doc, via writing-plans).

**Status:** R2, revised 2026-06-21 after review + evidence capture. Decisions are recorded
inline as **[decision]**. Items closed from the R1 review are mapped in §13.

**Upstream:** `KarpelesLab/teamclaude` (MIT). devbox runtime: **1.0.7** (nix-packaged npm
tarball, `pkgs/teamclaude/default.nix`). Survey HEAD: `654ace1`. Gap exists in both.

**Scope:** a *focused fork* (upstreamable later, not now) that makes the proxy aware of
Anthropic's **per-model scoped weekly limits** (Opus in particular) and fails over across
Claude Max accounts accordingly, on the **base-URL relay only**.

---

## 0. What changed in R2 (changelog)
The R1 design tracked a flat `seven_day_opus` field and added per-field buckets
(`unified7dOpus`). A review (3 blockers, 5 majors) plus a captured `/api/oauth/usage`
payload changed three things:

1. **Data model pivot [decision].** The authoritative structure is a generic **`limits[]`
   array** (each entry: `kind, group, percent, severity, resets_at, scope.model, is_active`).
   The flat `seven_day_opus` field *exists* but is **`null` unless an Opus-scoped limit is
   active**, so building on it would silently no-op. R2 drives everything off `limits[]`.
2. **MITM relay scoped out [decision].** A second relay (`mitm.js`) selects an account
   *per-CONNECT* before any request body exists; per-request model-awareness is structurally
   impossible there. R2 covers the **base-URL relay only** (what devbox/opencode uses) and
   documents the caveat.
3. **Evidence-first [decision].** Root cause is a strong hypothesis, **not proven** (the
   live surviving account currently shows *no active Opus scope*). We enabled `--log-to`
   capture on devbox to record the next real limit response, and design the reactive
   backstop defensively (structured signals, not message strings).

---

## 1. Problem & root cause

### 1.1 Symptom
Heavy Opus agentic workloads on devbox (default model `anthropic/claude-opus-4-8`, routed
through teamclaude at `127.0.0.1:3456`) intermittently surface Anthropic's verbatim
`The usage limit has been reached` to opencode (opencode `SessionRetry` retries it; pigeon
surfaces a "🤖 Retry … Next attempt" notice) **while teamclaude reports both accounts
healthy** (one account 3% of 5h / ~10% unified weekly, status `allowed`).

### 1.2 Why (code-level — verified against src/)
teamclaude tracks three Claude-Max buckets and has **no per-model Opus concept** (`grep -ri
opus src/` → 0 hits):
- **Passive headers** (`account-manager.js:340-367`) read `anthropic-ratelimit-unified-5h-
  utilization`, `-7d-utilization`, `-status`, plus standard tokens/requests. **No per-model
  breakdown.**
- **Active usage probe** (`oauth.js:201-206`, opt-in via `quotaProbeSeconds`) normalizes only
  `five_hour`, `seven_day`, **`seven_day_sonnet`**. Never reads any Opus bucket.
- **Proactive failover** `_isNearQuota()` (`account-manager.js:213-233`) trips only on
  `unified5h`/`unified7d`/standard ≥ threshold. It does **not** consult `unifiedStatus`
  (stored `:359`, never read) nor any per-model bucket.
- **Reactive path** (`server.js:299-326`) special-cases **HTTP 429 only** and `cancel()`s
  the body unread (`:308`). A limit delivered as a mid-stream SSE `error` inside a 200 (the
  common subscription shape) is streamed straight through with no failover, no log line.

### 1.3 Status: strong hypothesis, not proven
The verbatim "usage limit has been reached" *rules out* the issue-#5 IP-throttle (whose
message is "Server is temporarily limiting requests (not your usage limit)"). But the live
capture (§2.5) shows the surviving account currently has **no active Opus-scoped limit** —
so we have not yet observed the exact limiting bucket/wire-shape. The `--log-to` capture
(§2.5) is in place to confirm on the next real event. (Separately, the second account is
operationally dead — expired token + `invalid_grant` refresh — which removes the only
failover target; that is an **auth** problem, a non-goal here.)

---

## 2. Prior art (upstream issues/PRs)
- **Issue #1** (Sonnet 7d view) — maintainer states the **passive-only** philosophy: the
  proxy never calls Anthropic itself. Per-model buckets are only in `/api/oauth/usage`.
- **PR #36** — opt-in background probe; **Sonnet-only**.
- **PR #2** — earlier Sonnet attempt, closed for *active polling* (we accept active polling).
- **Issue #5 / PR #25** — the "temporarily limiting requests" 429 is **IP-keyed** (hits all
  accounts; must back off, not fail over). The trap §6 must avoid.
- **PR #22** — `/fast` priority-tier 429s misread as quota exhaustion; same misclassification
  family.
- No issue/PR mentions `opus`/`seven_day_opus`/`per-model`. Unreported gap; no dependency on
  upstream work landing. *(PR/issue numbers are external; not verifiable from the tree.)*

## 2.5 Captured evidence (devbox, account 0, healthy) [decision: fixture-driven]
Real `GET /api/oauth/usage` (beta `oauth-2025-04-20`), saved as fixture
`fixtures/usage-account0-healthy.json`:
- Top-level buckets: `five_hour`, `seven_day`, `seven_day_opus`(**null**),
  `seven_day_sonnet`, `seven_day_cowork`, `seven_day_oauth_apps`, `seven_day_omelette`,
  `extra_usage`, `spend`, `limits`, plus opaque flags.
- **`limits[]`** (authoritative): e.g.
  - `{kind:"session", group:"session", percent:3, severity:"normal", resets_at, scope:null, is_active:false}`
  - `{kind:"weekly_all", group:"weekly", percent:11, severity:"normal", resets_at, scope:null, is_active:true}`
  - `{kind:"weekly_scoped", group:"weekly", percent:4, severity:"normal", resets_at, scope:{model:{id:null,display_name:"Sonnet"}}, is_active:false}`
- **No Opus-scoped entry** present for this account right now; **no `five_hour_opus`** →
  Opus cap is **weekly-only** (resolves R1 review m4).
- **Scales:** bucket `utilization` and `limits[].percent` are **0–100**.
  `normalizeUsageBucket` (`oauth.js:151-154`) divides by 100 when `>1` (→ 0–1) and parses
  ISO `resets_at` → ms; reuse it for `limits[]`.

**Implication:** model the per-scope limits generically from `limits[]` (match
`scope.model.display_name` case-insensitively, use `percent`, `severity`, `is_active`,
`resets_at`). Do **not** depend on the flat `seven_day_opus` field.

---

## 3. Goals / Non-goals
**Goal [decision]:** Track per-model **scoped weekly** limits from `limits[]` and perform
**per-request, model-aware failover** so a request whose model matches an active/severe
scoped limit rotates to an account where that scope is healthy, instead of passing the
limit through.

**Non-goals [decision — YAGNI]:** graceful Opus→Sonnet degradation; general error
classification beyond the scoped backstop; auth self-healing/auto-relogin; metrics beyond
surfacing scoped state in existing status outputs; **the `mitm.js`/forward-proxy relay**
(unified-only failover there; documented caveat).

**Hard dependency [decision, from review M4]:** proactive scoped failover **requires the
usage probe on** (`quotaProbeSeconds > 0`); passive headers carry no per-model data. With
the probe off, scoped limits are handled **reactively only** (§6).

---

## 4. Architecture — `limits[]`-driven model-class quota [decision]
Generic over model scope (subsumes Opus + Sonnet + future), additive to upstream:

- **Quota model:** add a normalized `scopedLimits` map to each account's quota:
  `{ "<modelKeyLowercased>": { utilization (0-1), resetAt (ms), severity, isActive } }`,
  derived from `limits[]` entries with `group:"weekly"` and `scope.model` set. Keep the
  existing unified `unified5h`/`unified7d` (still useful + free from headers). Persist the
  scoped map (extend `PERSISTED_QUOTA_FIELDS`).
- **`modelClass(modelId)`** helper (`/opus/i`→`"opus"`, `/sonnet/i`→`"sonnet"`, else
  `null`). Robust to opencode's provider-prefixed id (`anthropic/claude-opus-4-8`) and the
  wire value (`claude-opus-4-…`).
- **Near-quota for a class** = `unified5h ≥ t` **OR** `unified7d ≥ t` **OR** (a matching
  active scoped limit is near: `scopedLimits[class].isActive && (severity ≠ "normal" ||
  utilization ≥ t_scoped)`). Generic gating **[decision]** applies to whichever scope
  matches the request model (Opus and Sonnet uniformly). This *is* a deliberate behavior
  change for Sonnet (was display-only) — driven by `is_active`/`severity` so it only fires
  on a real active scope (review M5: accepted + tested, not a silent regression).

Rejected: R1's per-field `unified7dOpus` (null/conditional, §0/§2.5); Opus-only overlay
(the `limits[]` loop makes generic essentially free).

---

## 5. Components & data flow (base-URL relay)

### 5a. Background poller (reuse `quotaProbeSeconds`) [decision, review M3]
**No new config keys.** Extend the existing prober. `fetchUsage` (`oauth.js`) additionally
parses `limits[]` into the normalized `scopedLimits` map (and may keep populating
`seven_day_sonnet`/`seven_day_opus` for display). Poll every `quotaProbeSeconds` (fork
deploy default **90**, floor 30 already enforced `index.js:726`); idle accounts polled too
so failover targets are known-good. Passive header reads on each response remain.

### 5b. Per-request model-aware selection [decision] — stateless [review M1]
Request body already buffered (`server.js:80-84`). Parse JSON (guarded; fallback to
unified-only on failure/missing `model`) → `modelClass`. Introduce a **stateless**
`bestAccountFor(modelClass)` that returns the pick **without** mutating `currentIndex`,
`probing`, `requalify`, or emitting "Switched to account" logs. Only commit rotation state
(`currentIndex`, logs) when the **primary** account actually changes — never per-request —
to avoid the mixed Opus/Sonnet thrash + log-spam M1 identified. Enumerate the ripple:
`_isAvailable`, `_isNearQuota`, `_pickBestAvailable`, `_selectNext`, `_switchOnSessionReset`,
`selectActiveAccount` all gain an optional `modelClass` and must stay class-free by default.

### 5c. Reactive scoped backstop — see §6.

### 5d. All-scope-exhausted [decision] — generalized retry-after [review M2]
When `bestAccountFor(class)` returns null → **429** with `retry-after` = **soonest of all
known resets**. **Rewrite** `computeRetryAfter` (`server.js:486-495`, today only
`rateLimitedUntil`/`resetsAt`, ignoring unified resets for Max accounts) to take the min of
`rateLimitedUntil, unified5hReset, unified7dReset, scopedLimits[*].resetAt, resetsAt`, and
**unify** it with the `_selectNext` all-unavailable fallback (`account-manager.js:309-319`)
so the two "soonest reset" computations cannot diverge.

---

## 6. Reactive scoped backstop (highest-risk; defensive) [decision]
Proactive polling lags (interval + sub-threshold window), so also react to upstream limit
signals — but **only genuine per-account usage limits**, never the IP-keyed throttle.

- **Pre-stream limit** (error status, before bytes forwarded): **buffer and parse the 429
  body** (replacing the blind `cancel()` for the *terminal/non-retry* case only), match a
  **structured** discriminator from the §2.5/`--log-to` capture (`error.type`/code; and
  `anthropic-ratelimit-unified-status` *if* the capture shows it correlates to the scope —
  prior is it's unified-only, review B2/Q2). Mark the matching `scopedLimits[class]`
  exhausted (`utilization=1`, `resetAt` from the response/limits) and **re-dispatch to
  another account**. **Do not** ship message-string matching as the primary predicate.
- **Mid-stream limit** (SSE `error` event after bytes flowed): **extend `parseSSEUsage`**
  (`server.js:430-434,459`, which already JSON-parses every `data:` event — so this is a few
  lines, ~zero marginal cost; review m1) with an `else if (data.type==='error')` arm. Mark
  the bucket; cannot transparently retry (bytes sent), so opencode's retry re-dispatches and
  now routes to a fresh account.
- **Disambiguation:** only structured per-account usage-limit signals touch `scopedLimits`;
  the "temporarily limiting requests" 429 keeps the existing back-off path (review B2).
- **Reset source [review m2]:** prefer the matching `limits[].resets_at`; fall back to
  `anthropic-ratelimit-unified-7d-reset` (approximate — documented).
- **Observability [review "missing #8"]:** `console.log` once whenever the backstop fires
  (pre- or mid-stream), else it's as invisible as the current bug.

**Residual risk:** exact limit wire-shape unconfirmed until the `--log-to` capture catches a
real event; predicates are written against the capture, defaulting to back-off (never
mis-mark) on anything unrecognized.

---

## 7. Terminal behavior [decision]
No graceful degradation. All matching scopes exhausted → **429 + generalized Retry-After**
(§5d). opencode backs off until the scope frees.

---

## 8. Config & defaults [decision, review M3/M4]
- **Reuse `quotaProbeSeconds`** (no `pollIntervalSec`/`usageProbe`). Fork deploy config sets
  it to **90**; **upstream default stays off** (preserves passive-only philosophy — the
  on-by-default flip is fork-deploy-only, not part of the upstreamable diff).
- Optional per-class `switchThresholds` override; default reuse `switchThreshold` (0.98) for
  unified, **scoped default 0.90** [review Q3] for early rotation given poll lag (severity is
  the primary signal; threshold secondary).
- Unknown scoped data (probe hasn't populated / `null`) ⇒ **available**; backstop covers it.

---

## 9. Error handling / edge cases
- **Dead account** (invalid_grant): `status:"error"`, skipped, logged once, backoff; all-dead
  ⇒ clear error.
- **Body parse failure / missing `model`:** unified-only selection (guarded `JSON.parse`;
  cheap pre-scan optional, review m7).
- **Scope reset expiry:** extend `_clearExpiredQuotas` for `scopedLimits[*].resetAt`.
- **Wire-drift visibility [review m6]:** if a probe returns `seven_day_sonnet`/Sonnet scope
  but the expected Opus key/scope shape is absent, log once so silent drift is visible.
- **Concurrency window [review "missing #7"]:** up to *in-flight count* Opus requests can
  pass before headers/poll/backstop mark the bucket; acceptable, documented bound.
- **Status surfacing [review m3]:** add scoped (Opus/Sonnet) to **all three**:
  `/teamclaude/status` (`getStatus` spreads quota — near-free), the TUI bar
  (`tui.js:548-554`), **and** the `teamclaude status` CLI printer (`index.js:497-507`).

## 10. Testing (extend existing CI; Node 18–24) [decision: real fixtures]
Commit captured fixtures (the §2.5 healthy payload + the first real limit response once
`--log-to` catches one) and assert against them, not hand-authored guesses. Unit:
`fetchUsage` parses `limits[]`→`scopedLimits` (incl. null Opus); `modelClass()`;
`_isNearQuota(acct,"opus")` trips on an active Opus scope while unified low; **stateless
`bestAccountFor`** does not mutate `currentIndex`/logs; mixed Opus/Sonnet sequence causes no
primary thrash; `computeRetryAfter` = soonest across *all* reset fields; backstop marks scope
on a structured limit but **not** on an IP-throttle 429; persistence round-trips
`scopedLimits`. Integration: mock upstream pre-stream + mid-stream limit → assert
re-dispatch / state-update.

## 11. Deployment — GitHub fork + fetchFromGitHub [decision]
Fork to `github.com/<you>/teamclaude` (focused commits). Repackage `pkgs/teamclaude/
default.nix`: `fetchurl`(npm) → `fetchFromGitHub(owner,repo,rev,hash)`, keep zero-dep
vendoring (note `fetchFromGitHub` pulls the whole repo incl. `test/`; harmless; expect a new
`hash` per fork commit — review n3). **cloudbox: unify on the nix package** [decision, review
Q4] (drop the ad-hoc `~/projects/teamclaude` checkout; `teamclaude login` runs from the
packaged binary — it needs a browser/stdin, not a source checkout). Validate the package
builds the `bin` from `fetchFromGitHub` during deploy.

## 12. Open questions (remaining)
1. **B2 wire-shape** — exact status/headers/`error.type` of a real scoped limit: **pending**
   the `--log-to` capture; predicates finalized once observed (defensive default until then).
2. **Does a scoped limit appear in `limits[]` only when near/active**, or always at low
   percent? The healthy capture shows Sonnet scope present at 4%/`is_active:false` but **no
   Opus scope at all** — so Opus scope may be plan/usage-conditional. Confirm via a capture
   when Opus has been exercised; affects whether absence ⇒ "available" is always safe.

## 13. R1 review items → resolution
- **B1** (seven_day_opus unverified) → field exists but null/conditional; **pivoted to
  `limits[]`** (§0/§2.5/§4). **B2** (429 body discarded; unverified discriminator) →
  buffer-on-terminal + structured predicates + `--log-to` capture; defensive default (§6).
  **B3** (mitm.js) → **scoped out** (§0/§3). 
- **M1** (stateful currentIndex) → stateless `bestAccountFor`, commit only on primary switch
  (§5b). **M2** (computeRetryAfter) → generalized + unified with `_selectNext` (§5d). **M3**
  (config collision) → reuse `quotaProbeSeconds` (§8). **M4** (on-by-default / upstreamable)
  → fork-deploy-only default + explicit hard dependency (§3/§8). **M5** (Sonnet gating) →
  accepted as deliberate, severity/is_active-driven, tested (§4).
- **m1** extend `parseSSEUsage` not a new scanner; **m2** prefer `limits[].resets_at`; **m3**
  CLI printer; **m4** weekly-only Opus confirmed; **m5** root cause = hypothesis (§1.3);
  **m6** wire-drift log; **m7** guarded parse / `/opus/i`. **n1–n3** line-ref/PR/nix caveats
  noted.
