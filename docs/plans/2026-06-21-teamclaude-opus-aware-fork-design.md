# Opus-aware teamclaude fork — Design

> **For the reviewer:** This is a DESIGN doc (the "what and why"), not a task-by-task
> plan. It is self-contained: §1 gives the problem and the code-level root cause, §2 the
> prior-art survey, and §3–§10 the proposed design. The next step after approval is an
> implementation plan (separate doc). Please scrutinize §6 (reactive backstop) and §10
> (open questions) hardest — those are where the design is least certain.

**Status:** Design approved by user (2026-06-21) via brainstorming. Nothing implemented.
Decisions settled during brainstorming are recorded inline as **[decision]**. Next step:
Vertex Opus 4.8 review → revise → writing-plans.

**Upstream:** `KarpelesLab/teamclaude` (MIT). Installed/runtime version on devbox: **1.0.7**
(nix-packaged from the npm tarball, `pkgs/teamclaude/default.nix`). HEAD at survey time:
`654ace1`. The gap described here exists in both 1.0.7 and HEAD.

**Scope of this doc:** a *focused fork* (upstreamable later, not now) that makes the proxy
aware of Anthropic's per-model **Opus weekly** limit and fails over across Claude Max
accounts accordingly.

---

## 1. Problem & root cause

### 1.1 Symptom
Heavy Opus agentic workloads on devbox (default model `anthropic/claude-opus-4-8`, routed
through teamclaude at `127.0.0.1:3456`) intermittently surface Anthropic's verbatim
`The usage limit has been reached` error to opencode — which opencode's `SessionRetry`
then retries and pigeon's plugin surfaces as a "🤖 Retry … Next attempt at …" notice —
**even though teamclaude reports both accounts as healthy** (e.g. one account at 3% of the
5h window / 10% of the unified weekly, status `allowed`).

### 1.2 Why (code-level)
teamclaude tracks exactly three Claude-Max quota buckets and **no per-model Opus bucket
exists anywhere in the codebase** (`grep -ri opus` → zero hits). Specifically:

- **Passive headers** (`account-manager.js:340-367`) read
  `anthropic-ratelimit-unified-5h-utilization`, `-7d-utilization`, `-status`, plus the
  standard `tokens`/`requests` limits. There is **no per-model breakdown** in these headers.
- **Active usage probe** (`oauth.js:202-206`, opt-in, added by upstream PR #36) normalizes
  only `five_hour`, `seven_day`, **`seven_day_sonnet`** from `/api/oauth/usage`. Anthropic's
  usage endpoint also returns a **`seven_day_opus`** bucket on Max plans, but teamclaude
  never reads it. This probe is **off by default**.
- **Proactive failover** `_isNearQuota()` (`account-manager.js:213-233`) trips only on
  `unified5h ≥ threshold`, `unified7d ≥ threshold`, or the standard token/request limits.
  It does **not** consider any Opus bucket, and notably does **not** consult
  `unifiedStatus` (stored at `:359` but never read) — so an account Anthropic has flagged
  `rejected` is still treated as available while 5h/7d utilization is low.
- **Reactive path** (`server.js:299-326`) special-cases **HTTP 429 only**, and
  **cancels the response body** (`:308`) without inspecting it. It cannot distinguish a
  subscription/Opus usage-limit from a transient throttle, and if Anthropic delivers the
  Opus limit as anything other than a clean 429 (e.g. a mid-stream SSE `error` event inside
  a 200 stream — the common shape for subscription "usage limit reached"), teamclaude
  treats it as a normal success, updates quota from the (low) headers, and **streams the
  error straight through** with no failover and no log line.

**Net:** an account can be at its Opus weekly cap while its unified 5h/7d utilization is
low. teamclaude sees only the latter, considers the account healthy, never fails over, and
passes the limit through. The user's "two accounts, far from limits" intuition is correct
*about the unified buckets* and blind *to the Opus bucket* — exactly the gap.

### 1.3 Adjacent (out-of-scope) facts
The currently-observed outage is amplified because the second account is **operationally
dead** (access token expired, refresh token `invalid_grant` — the documented OAuth-grant
poisoning from sharing Claude Code's `client_id`), so there is effectively no failover
target. Fixing that is an **auth** problem, explicitly a non-goal here (§3). This design
makes failover *correct*; it does not resurrect dead accounts.

---

## 2. Prior art (upstream issues/PRs)
- **Issue #1** "Support Sonnet 7-day usage in the quota view" — maintainer states the
  **passive-only design philosophy**: "the proxy never calls the Anthropic API itself, it
  only learns quota from the traffic." Per-model buckets "aren't in the
  `anthropic-ratelimit-unified-*` headers … only in `/api/oauth/usage`." Establishes the
  Sonnet pattern but stops at Sonnet.
- **PR #36** "Opt-in background quota probe (+ Sonnet 7d bar, closes #1)" — the probe we
  extend; **Sonnet-only**, opt-in.
- **PR #2** "Add Sonnet 7-day usage bar" — earlier attempt, closed for *actively* polling
  (violated passive-only). We deliberately accept active polling.
- **Issue #5 / PR #25** — the "Server is temporarily limiting requests (not your usage
  limit)" 429 is **keyed on the proxy's outbound IP** → hits *all* accounts at once; the
  right response is back-off, not failover. This is the trap the reactive backstop (§6)
  must avoid.
- **PR #22** "strip fast mode …" — a sibling class of bug: `/fast` priority-tier 429s were
  misread as quota exhaustion and penalized all accounts. Same underlying weakness
  (misclassifying non-quota 429s).
- Full-text search of all issues+PRs for `opus` / `seven_day_opus` / `per-model`: **no
  results.** This is an unreported gap; we do not depend on any upstream work landing.

---

## 3. Goals / Non-goals
**Goal [decision]:** Track the per-model **Opus weekly** quota (`seven_day_opus`) and
perform **per-request, model-aware failover** across accounts, so Opus traffic rotates
before/when an account's Opus cap is hit instead of passing the limit through.

**Non-goals [decision — YAGNI]:**
- Graceful Opus→Sonnet degradation (we 429 instead, §7).
- General error-classification beyond the Opus backstop.
- Auth self-healing / auto-relogin for dead accounts.
- Metrics/alerting beyond surfacing Opus state in the existing status output.

(The generalized model in §4 *subsumes* Sonnet tracking for free; we add no Sonnet-specific
behavior.)

---

## 4. Architecture — generalized per-model quota (Approach A) [decision]
Make quota **model-class-aware**, implemented *additively* over upstream's field style so
the diff stays focused and upstreamable:

- Add `unified7dOpus` + `unified7dOpusReset` to `emptyQuota()` and `PERSISTED_QUOTA_FIELDS`
  (mirrors the existing `unified7dSonnet` pair).
- `modelClass(modelId)` helper: `/opus/i → "opus"`, `/sonnet/i → "sonnet"`, else `null`.
- `_isNearQuota(account, modelClass)` and `getActiveAccount(modelClass)` take the class.
  Near-quota for a class = `unified5h ≥ t` **OR** `unified7d ≥ t` **OR** (class-specific
  weekly `≥ t`). Opus/Sonnet are sub-limits *within* the unified weekly, so both gates apply.

Rejected alternatives: **B** (Opus special-case overlay — minimal diff but doesn't
generalize) and **C** (two-pass selection — more confusing control flow). A was chosen for
"proper design, best fit," treating per-model limits as first-class.

---

## 5. Components & data flow

### 5a. Background poller (always-on) [decision]
Extend the existing `prober`. Every `pollIntervalSec` (default **90s**), for each enabled,
non-dead account: refresh token if expiring, call `fetchUsage`, update all buckets.
`fetchUsage` (`oauth.js`) gains `sevenDayOpus: normalizeUsageBucket(data?.seven_day_opus)`.
**Idle accounts are polled too**, so a failover target's Opus state is known-good *before*
we switch to it. Poll volume (~2 accounts / 90s ≈ 1.3 req/min) is negligible vs. the
IP-throttle concern (§2, Issue #5). The existing free passive header reads on every
`/v1/messages` response are **retained** as a real-time complement to the poll.

### 5b. Per-request model-aware selection (`server.js`) [decision]
The request body is already buffered (`server.js:79`). Parse JSON → `model` → `modelClass`,
pass to `getActiveAccount(class)`. Pick the current account if available for that class;
else rotate to one that is; else → §7. Non-Opus requests keep using an Opus-exhausted
account (its unified/Sonnet capacity is preserved).

### 5c. Reactive Opus backstop [decision] — see §6.

### 5d. All-Opus-exhausted [decision]
`getActiveAccount("opus")` returns null → respond **429** with `retry-after` = soonest
`unified7dOpusReset` across accounts (extend `computeRetryAfter`). opencode's retry then
backs off until Opus actually frees up.

---

## 6. Reactive Opus backstop (highest-risk section)
Proactive polling has lag (poll interval + the sub-threshold window), so we also react to
upstream limit signals — but **only genuine per-account usage limits**, never the IP-keyed
"Server is temporarily limiting requests" throttle (the PR #22/#25 trap, which affects all
accounts and must *back off*, not fail over).

- **Pre-stream limit** (error status, or `anthropic-ratelimit-unified-status: rejected`,
  before any body bytes are forwarded): set the account's `unified7dOpus = 1` with reset
  from `anthropic-ratelimit-unified-7d-reset` (fallback: a sane default), then **re-dispatch
  to another account** — transparent retry, like the existing 429 re-dispatch.
- **Mid-stream limit** (an SSE `error` event carrying a usage-limit message *after* bytes
  already flowed): we cannot transparently retry (bytes are already sent to the client). So
  we **mark the bucket** via a lightweight scan of streamed error events and return as-is;
  opencode's `SessionRetry` re-dispatches, which now routes to a fresh account.

**Disambiguation rule:** only signals whose shape indicates a *per-account usage limit*
touch the Opus bucket. The IP-throttle "temporarily limiting requests" 429 must continue to
use the existing back-off-and-retry path and must **not** mark any Opus bucket.

**Why this is risky (reviewer, please attack):**
1. Reliable detection of a mid-stream usage-limit requires scanning the SSE byte stream the
   proxy currently relays verbatim — added parsing surface and a possible perf/correctness
   cost on the hot path.
2. The exact wire shape of an Opus-specific limit (status code, headers, body/`error.type`,
   whether `unified-status: rejected` is even emitted for the Opus sub-limit) is **not yet
   empirically confirmed**. **Mitigation:** before finalizing detection predicates, capture
   a real Opus-limit response with `teamclaude server --log-to <dir>` and pin the predicates
   to observed fields (same evidence-first method the maintainer asked for in Issue #1).

---

## 7. Terminal behavior [decision]
No graceful degradation. When all accounts' Opus is exhausted → **429 + Opus-aware
Retry-After** (§5d). Predictable; no surprise mid-stream errors for the caller beyond the
single one that opencode retries.

---

## 8. Config & defaults [decision]
All new keys optional:
- `pollIntervalSec` — default **90**.
- `usageProbe` — flips to **on by default** (was opt-in upstream).
- `switchThresholds` — optional per-class override map; default reuses the single
  `switchThreshold` (0.98) for all classes.
- **Unknown Opus data** (poll hasn't populated it yet) ⇒ treated as **available**; the §6
  backstop covers the gap. We never block on unknown.

---

## 9. Error handling / edge cases
- **Dead account** (invalid_grant on poll/refresh): mark `status:"error"`, skip in
  selection, log loudly once, back off (don't crash/spin). All-dead ⇒ clear error response.
- **Body parse failure / missing `model`:** fall back to unified-only selection.
- **Opus reset expiry:** extend the existing `_clearExpiredQuotas` pattern to the Opus pair.
- **IP-throttle vs usage-limit:** disambiguated by signal shape (§6); only usage-limits
  touch the Opus bucket.
- **Status surfacing:** add `unified7dOpus` to `/teamclaude/status` and the TUI bar (free,
  needed for debugging; not "observability" scope creep).

---

## 10. Testing (extend existing CI; Node 18–24)
Unit:
- `fetchUsage` normalizes `seven_day_opus`.
- `modelClass()` classification (opus/sonnet/other/missing).
- `_isNearQuota(acct, "opus")` trips on the Opus bucket while unified is low.
- `getActiveAccount("opus")`: fails over to an account with free Opus; returns null when all
  Opus-exhausted; a non-Opus request still uses an Opus-exhausted account.
- `computeRetryAfter` = soonest Opus reset.
- Backstop: a real Opus-limit signal marks Opus + fails over; an IP-throttle 429 does
  **not** mark Opus and uses back-off.
- Persistence round-trips the Opus fields.

Integration: mock upstream returning an Opus limit (pre-stream and mid-stream) → assert
failover / state-update respectively.

---

## 11. Deployment — GitHub fork + fetchFromGitHub [decision]
- Fork to `github.com/<you>/teamclaude` as focused commits atop upstream (upstreamable
  later).
- Repackage `pkgs/teamclaude/default.nix`: swap `fetchurl`(npm tarball) → `fetchFromGitHub
  (owner, repo, rev, hash)`, keeping the zero-dep vendoring (still no `node_modules`).
  Devbox already consumes this package.
- **Open question (reviewer/user):** unify cloudbox onto the same nix package (drop its
  ad-hoc `~/projects/teamclaude` checkout) for reproducibility, vs. keep cloudbox on a
  checkout synced to the fork. Note cloudbox currently runs from a checkout partly for the
  interactive `teamclaude login` flow.

---

## 12. Open questions for the reviewer
1. **§6 detection predicates** — is the mid-stream SSE scan worth the hot-path complexity,
   or should the backstop be pre-stream-only (accept that mid-stream limits only update
   state on the *next* request)? Need the captured-response evidence to decide.
2. **Wire shape** — does Anthropic emit `anthropic-ratelimit-unified-status: rejected` for
   the Opus sub-limit specifically, or only for the unified weekly? If the former, a cheap
   header check may replace most of the body scanning.
3. **Threshold for Opus** — is reusing 0.98 right given poll lag, or should Opus default to
   a more conservative margin (e.g. 0.95)?
4. **cloudbox deployment** — unify on nix package or keep checkout (§11)?
5. **Generalization scope** — is folding Sonnet into the same model-class machinery (vs.
   leaving upstream's Sonnet code as-is and only adding Opus) worth the extra refactor?
