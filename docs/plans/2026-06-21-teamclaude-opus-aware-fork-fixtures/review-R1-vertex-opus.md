# Review of OPUS-AWARE-DESIGN.md (Vertex Opus 5 reviewer pass)

Method: every code-level claim below was checked against the actual sources in
`src/`. Line refs in this review point at the real upstream code as it exists in
this workspace. Where a claim cannot be verified from the repo (Anthropic wire
shapes, upstream PR numbers, the nix `default.nix` which lives in another repo),
it is marked **UNVERIFIABLE FROM REPO** and treated as an assumption, not a fact.

---

## 1. Summary verdict

**The root-cause analysis (§1) is essentially correct** — the file:line refs are
accurate, and the central claim (no per-model Opus bucket exists anywhere;
`_isNearQuota` never consults `unifiedStatus` or any per-model bucket; the
reactive path special-cases 429 and cancels the body without inspecting it) all
check out against `account-manager.js`, `oauth.js`, and `server.js`. Credit where
due: this is a well-researched diagnosis.

**But the design is not ready to turn into a plan.** Three things must be resolved
first, and all three are things the design itself half-acknowledges but then
builds on as if settled:

1. **The whole design hinges on a `seven_day_opus` field that has zero evidence in
   the codebase** (the maintainer only ever normalized `seven_day_sonnet`). The
   design states "Anthropic's usage endpoint also returns a `seven_day_opus`
   bucket" (§1.2) as fact. It is an assumption. Verify it (you have the tooling:
   `teamclaude api /api/oauth/usage`) **before** writing the plan.
2. **§6's IP-throttle-vs-usage-limit disambiguation requires reading the 429 body
   that the current code deliberately discards** (`server.js:308`), and the
   discriminator is exactly the unverified wire shape. As written, §6 cannot be
   implemented without risking the precise misclassification (issue #5 / PR #22
   trap) it claims to avoid.
3. **There is a second, parallel relay the design never mentions: the
   MITM/forward-proxy path (`mitm.js`).** It does its own account selection, token
   refresh, quota observation, and 429 handling, and it picks the account **once
   per CONNECT tunnel**, before any request body exists. Per-request model-aware
   selection (§5b) and the Opus backstop (§6) are structurally impossible there
   and are not addressed.

The generalized per-model model (§4/§5b) is sound in the abstract but
under-specifies its collision with the existing **stateful** selection machinery
(single `currentIndex`, `probing`/`requalify`, priority preemption, switch
logging). And the design's §6 perf fear is actually **overstated** — the SSE
stream is already parsed event-by-event today, so mid-stream detection is nearly
free; the real cost is predicate correctness, which is gated on the same missing
evidence.

Recommendation: **approve the direction, reject the design as a basis for a plan
until B1–B3 are closed.** Capture real payloads first; then revise §6 and §5b to
match observed shapes and to cover (or explicitly exclude) the MITM path.

---

## 2. Findings by severity

### BLOCKER

#### B1 — `seven_day_opus` is unverified; the entire design rests on it
**Where:** §1.2 ("Anthropic's usage endpoint also returns a **`seven_day_opus`**
bucket on Max plans"), §4, §5a, §10.

`oauth.js:201-206` (`fetchUsage`) normalizes exactly `five_hour`, `seven_day`,
`seven_day_sonnet`. A full grep of `src/` for `opus` returns **zero** hits — the
only `opus` strings in the tree are in the design doc itself. So the codebase
provides **no evidence whatsoever** that `/api/oauth/usage` returns a field named
`seven_day_opus`. The maintainer added `seven_day_sonnet` because that's what they
empirically observed (Issue #1's evidence-first method); the absence of an Opus
field may mean the maintainer never saw one, or that it is named/shaped
differently.

This is not a nitpick: §4 (`unified7dOpus` buckets), §5a (`sevenDayOpus:
normalizeUsageBucket(data?.seven_day_opus)`), §5b/§5d (model-aware selection on
the Opus bucket), and the entire proactive half of the design are dead code if the
field name is wrong — and they fail **silently**: `data?.seven_day_opus` →
`undefined` → `normalizeUsageBucket` → `null` → §8 "treated as available" → no
proactive failover ever. You'd ship, observe nothing, and still pass the limit
through (now relying entirely on the also-unverified §6 backstop).

**Suggested change:** Before writing the plan, run
`teamclaude api /api/oauth/usage --account <max-acct>` (this command already
exists — `index.js:633`, it hits `USAGE_URL` with the `oauth-2025-04-20` beta) and
**pin the field name to the observed payload.** Record the real JSON as a test
fixture (see B-note in §10 review). If the bucket is nested (e.g. under a
`models`/`model_usage` array) rather than a flat `seven_day_opus`, the §4/§5a
field-add approach has to change shape entirely.

#### B2 — §6's 429 disambiguation needs the body the code throws away, and the discriminator is unverified
**Where:** §6 ("Disambiguation rule"), open questions 1 & 2.

Today every 429 is handled identically and the body is **cancelled unread**:

```
server.js:299   if (upstreamRes.status === 429) {
server.js:308     await upstreamRes.body?.cancel();   // discarded without inspection
```

The design wants to distinguish (a) a per-account Opus *usage limit* (→ mark
`unified7dOpus=1`, re-dispatch) from (b) the IP-keyed "Server is temporarily
limiting requests" throttle (issue #5 — same outbound IP, hits *all* accounts, must
back off, never fail over). But:

- If the Opus usage-limit arrives **as a 429**, the only way to tell it from the
  IP-throttle 429 is to read the 429 **body** (`error.type` / message) — the exact
  bytes `server.js:308` currently discards. So the design's "pre-stream … before
  any body bytes are forwarded" hook has to *buffer and parse the upstream 429
  body*, which is a concrete change the design never states.
- The discriminator (`error.type`? a verbatim message string? `unified-status:
  rejected`?) is **UNVERIFIABLE FROM REPO**. Keying on the message string
  "The usage limit has been reached" (the §1.1 symptom) is fragile (wording /
  localization can change).
- Getting this wrong reproduces precisely the issue #5 / PR #22 failure mode the
  section exists to prevent: an IP-throttle 429 misread as Opus exhaustion would
  mark `unified7dOpus=1` on every account in turn and burn the rotation.

**Suggested change:** Make evidence capture a hard prerequisite of §6.
`teamclaude server --log-to <dir>` during a real Opus-limit event, capture the
actual status code, headers (`anthropic-ratelimit-*`, `retry-after`), and body
(`error.type`). Then specify §6 as: buffer the 429 body (replacing the blind
`cancel()` for the *non-retry* terminal case only), match a **structured**
`error.type`/code observed in the capture, and treat anything that does not match
as the existing back-off path. Do **not** ship message-string matching as the
primary predicate.

#### B3 — The MITM / forward-proxy relay (`mitm.js`) is a second code path the design ignores
**Where:** entire design assumes `server.js`/`forwardRequest` is the only relay.

There are two relays:

- **Base-URL path** (`ANTHROPIC_BASE_URL`, the default in `index.js:452`) →
  `requestHandler` → `forwardRequest` (`server.js:203`). This is what opencode on
  devbox uses, so §5b's per-request body parsing works here.
- **Forward-proxy / MITM path** (`teamclaude run --mitm`, `HTTPS_PROXY`) →
  `createConnectHandler` → `intercept` (`mitm.js:134`). This relay:
  - selects the account **once per CONNECT**, at tunnel setup, *before any request
    body exists* (`mitm.js:151` `getActiveAccount()`), then pins every request on
    that tunnel (esp. h2-multiplexed) to that one account;
  - observes quota via `makeQuotaObserver` (`mitm.js:335-349`) which only calls
    `updateQuota` + `markRateLimited` on a 429 — **no body/SSE inspection at all**;
  - has no re-dispatch and no streaming-error scan.

Consequences: per-request model-aware selection (§5b) is **structurally
impossible** on this path (no body at selection time; h2 frames aren't buffered
to read `model`), and the Opus backstop (§6) is entirely absent. Any traffic that
uses `--mitm` (or `HTTPS_PROXY`) silently bypasses every new behavior.

**Suggested change:** Decide explicitly. Either (a) scope the MITM path **out** in
§3 with a one-line caveat ("Opus-awareness applies to the base-URL relay only;
`--mitm` traffic gets unified-only failover"), which is defensible since
devbox/opencode uses the base-URL path — or (b) design a per-tunnel-with-reselect
approach for `mitm.js`. Given the cloudbox `run --mitm` mention in §11, silence is
not an option.

### MAJOR

#### M1 — Per-request, per-class selection vs. the stateful single `currentIndex`
**Where:** §4 ("`getActiveAccount(modelClass)` take the class"), §5b.

`getActiveAccount()` is **not** a pure query — it mutates rotation state:
`refreshExpiredQuotas()`, the `requalify` re-eval (`account-manager.js:75-79`),
priority preemption (`:85-87`), `_selectNext` → `currentIndex = best.index` and
`best.probing = …` and a "Switched to account" log (`:294-301`). There is exactly
**one** `currentIndex`.

Overlaying *per-request* class-aware selection on this single mutable pointer is
not "just pass the class." On a mixed Opus/Sonnet workload (the normal case), an
Opus request that rotates to B mutates `currentIndex`, and the next Sonnet request
now starts from B; alternating requests can **flip `currentIndex` back and forth**,
each flip emitting a "Switched to account" log line and toggling
`probing`/`requalify`. That's log spam and selection thrash.

**Suggested change:** Introduce a **stateless** `bestAccountFor(modelClass)` that
returns the pick without mutating `currentIndex`/`probing`/logs, and only commit
rotation state when actually switching the *primary* account. Or make `currentIndex`
per-class. Either way the design must say which — and §4 must enumerate the full
ripple: `_isAvailable`, `_pickBestAvailable`, `_selectNext`, `_switchOnSessionReset`,
`selectActiveAccount` all currently assume class-free selection.

#### M2 — `computeRetryAfter` is already broken for Max accounts; §5d must generalize, not just add Opus
**Where:** §5d, §9.

`computeRetryAfter` (`server.js:486-495`) only looks at
`acct.rateLimitedUntil || acct.quota.resetsAt`. `resetsAt` is populated **only for
API-key accounts** (`account-manager.js:374-375`); for Claude Max accounts it's
`null`, and the unified resets (`unified5hReset`, `unified7dReset`) are **never
consulted**. So the existing all-exhausted 429 already returns the default 60s for
Max accounts regardless of when the weekly window actually resets.

§5d says "extend `computeRetryAfter`" to use soonest `unified7dOpusReset`. Fine,
but if you only add Opus you'll have a function that knows about Opus resets and
API-key resets but still ignores the plain 5h/7d unified resets — incoherent.

**Suggested change:** Rewrite `computeRetryAfter` to take the soonest of *all*
known reset fields (`rateLimitedUntil`, `unified5hReset`, `unified7dReset`,
`unified7dSonnetReset`, `unified7dOpusReset`, `resetsAt`). Note this also touches
the `_selectNext` all-unavailable fallback (`server.js`/`account-manager.js:309-319`),
which already does consult `unified5hReset`/`unified7dReset` — so the two "soonest
reset" computations should be unified to avoid divergence.

#### M3 — Invented config keys collide with the existing `quotaProbeSeconds`
**Where:** §8 (`pollIntervalSec` default 90, `usageProbe` boolean), §5a.

The probe is already configured by a single key: **`quotaProbeSeconds`** (number;
`0` = off; minimum enforced at 30s in `index.js:726`; documented in
`README.md:232` and `config.example.json:8`; wired in `index.js:170-189,273`,
`prober.js`). The design invents *two new* keys (`pollIntervalSec`, `usageProbe`)
that duplicate and contradict it. Shipping both means two settings fighting over
one prober.

**Suggested change:** Reuse `quotaProbeSeconds`. If "on by default" is desired,
change its default to 90 (and update README/example/`probe` command) — don't add
parallel keys. If you truly need an Opus-specific cadence, name it as a clear
sub-option, but the default path should be the one existing key. (Also: the 30s
floor in `probeCommand` already guards the usage endpoint; reuse it.)

#### M4 — "On by default" probe is a behavior + upstreamability problem, and a hidden hard dependency
**Where:** §5a, §8 ("`usageProbe` flips to on by default"), §11 ("upstreamable later").

Two issues:

1. **Hard dependency, stated softly.** Passive headers carry no per-model data
   (correct, per §1.2 / `account-manager.js:340-367`). So **proactive** Opus
   failover *only* works when the probe is on. If a user sets `quotaProbeSeconds 0`,
   Opus tracking silently degrades to reactive-only (§6). §8 hand-waves this as
   "unknown ⇒ available; the backstop covers the gap." Make the dependency
   **explicit**: "proactive Opus failover requires the probe; with it off, Opus is
   handled reactively only."
2. **Upstreamability.** The maintainer's stated philosophy (Issue #1, PR #2 closed
   for active polling) is passive-by-default. Turning the probe on by default
   directly violates that. The design says this work is "upstreamable later"
   (§11) — the on-by-default flip is the part that **won't** be. Either keep the
   default off upstream and on only in the fork's deployment config, or accept this
   piece is fork-only and drop the "upstreamable" framing for it.

#### M5 — Generalizing `_isNearQuota` silently changes Sonnet behavior
**Where:** §3 ("we add no Sonnet-specific behavior"), §4 ("subsumes Sonnet
tracking for free").

Today `_isNearQuota` checks **only** `unified5h` and `unified7d`
(`account-manager.js:218-219`). It does **not** check `unified7dSonnet` — Sonnet is
tracked and *displayed* (TUI `tui.js:552`, status `index.js:501`) but **never
gates selection**. §4's generalization ("Near-quota for a class = … class-specific
weekly ≥ t") makes the class weekly bucket gate selection, which for Sonnet is a
**new behavior**: Sonnet requests would start failing over on the Sonnet 7d bucket
where they previously did not. That's a regression risk, not "free," and it
contradicts §3's "no Sonnet-specific behavior."

**Suggested change:** Acknowledge it. Either intentionally adopt Sonnet
selection-gating (and say so, and test it), or explicitly exclude Sonnet from the
gate in v1. This feeds open question 5 (see below — I'd actually keep Sonnet
display-only for the first cut).

### MINOR

#### m1 — §6's mid-stream perf risk is overstated
**Where:** §6 "Why this is risky" #1.

The claim that mid-stream detection adds parsing surface "on the hot path the
proxy currently relays verbatim" is only half-true. `streamResponse` **already**
reassembles SSE events across chunks and parses each one
(`server.js:430-434` → `parseSSEUsage`, `:459`). It JSON-parses every `data:` line
today for usage. Adding `else if (data.type === 'error') { … }` is a handful of
lines with ~zero marginal cost. Reframe the risk: it's **predicate correctness**
(what does an Opus-limit error event actually look like — unverified), not
hot-path perf. Don't write a separate SSE scanner; extend `parseSSEUsage`.

Caveat to note: `res.write(value)` (`server.js:421`) forwards the raw chunk
*before* `parseSSEUsage` runs, so mid-stream marking is inherently post-hoc (the
error reaches the client) — which the design already accepts. Also `parseSSEUsage`
matches only the **first** `data: ` line per event (`.find`, `:460`); fine for
Anthropic today but worth a note.

#### m2 — Using `unified-7d-reset` as the Opus reset is approximate
**Where:** §6 pre-stream ("reset from `anthropic-ratelimit-unified-7d-reset`").

That header is the **unified** weekly reset, not necessarily the Opus sub-limit's
reset. Pinning `unified7dOpusReset` to it may clear the Opus bucket too early or
hold it too long. The authoritative source is the probe's
`seven_day_opus.resets_at` (if B1 confirms it exists). Use the header only as a
fallback and document the approximation.

#### m3 — §9 status surfacing misses the `teamclaude status` CLI printer
**Where:** §9 ("add `unified7dOpus` to `/teamclaude/status` and the TUI bar").

`/teamclaude/status` is free — `getStatus()` does `quota: { ...a.quota }`
(`account-manager.js:608`), so new fields appear automatically. The TUI bar
(`tui.js:548-554`) needs an explicit Opus bar. But the design omits the
human-readable **`teamclaude status`** printer (`index.js:497-507`), which
hand-formats Session/Weekly/Sonnet7d and would not show Opus without an edit.
Add it there too.

#### m4 — Only a *weekly* Opus bucket is modeled; confirm there's no shorter Opus window
**Where:** §1, §4.

The symptom (§1.1) was observed at 3% of the 5h window and 10% of unified weekly.
The design infers the Opus **weekly** cap. Plausible — but confirm during evidence
capture that the limiting bucket is the 7-day Opus and not, say, a 5-hour Opus
sub-limit (i.e. check whether the usage payload also has a `five_hour_opus`-style
field). If a shorter Opus window exists and was the real culprit, modeling only
`seven_day_opus` won't fix the reported outage.

#### m5 — Root cause is plausible but not proven
**Where:** §1.

The verbatim "The usage limit has been reached" does usefully **rule out** the
issue #5 IP-throttle (whose message is "Server is temporarily limiting requests
(not your usage limit)") — good. But it does not, by itself, prove the bucket is
Opus *weekly* vs. some other per-model window. Treat §1 as a strong hypothesis to
be confirmed by the B1/B2 capture, not as established fact, before committing the
fork.

#### m6 — Hardcoded `data?.seven_day_opus` fails silently on a name mismatch
**Where:** §5a.

`normalizeUsageBucket` is tolerant of *intra-bucket* field variants but
`fetchUsage` hardcodes the *top-level key*. If Anthropic names it differently, you
get `null` → "available" → no-op, with no signal. Add a one-time log/assert on
first probe if the expected Opus key is absent while `seven_day_sonnet` is
present, so a wire-shape drift is visible instead of silent.

#### m7 — Confirm the on-wire `model` value and guard the parse
**Where:** §5b, §4 (`modelClass`).

`/opus/i`-on-`model` is fine **if** the wire value is the bare `claude-opus-4-*`.
Note the §1.1 example `anthropic/claude-opus-5` is opencode's *provider-prefixed*
id; the value actually sent to `/v1/messages` should be the provider-stripped
`claude-opus-4-...`. `/opus/i` matches either, so the regex is robust — but
confirm with a captured request body. The design correctly plans a try/catch
fallback to unified-only on parse failure / missing `model` (§9); keep that. Full
`JSON.parse` of every (potentially ~1MB) request body just to read `model` is
acceptable but a cheap guarded pre-scan is a reasonable optimization.

### NIT

#### n1 — Minor line-ref imprecision (claims still substantively correct)
- §5b "request body is already buffered (`server.js:79`)": the buffering loop is
  `server.js:80-84`; `:79` is the comment. 
- §1.2 "Passive headers (`account-manager.js:340-367`)": accurate for the unified
  block + status, though the standard tokens/requests parsing actually runs to
  `:372`.
- §1.2 "`unifiedStatus` … never read": correct in the decision sense. Pedantically
  it *is* serialized via `PERSISTED_QUOTA_FIELDS` (`:9`) and cleared (`:137`), but
  it is never consulted by any selection/availability logic. The point stands.

#### n2 — Upstream issue/PR numbers are UNVERIFIABLE FROM REPO
§2 cites Issue #1, PR #36, PR #2, Issue #5 / **PR #25**, **PR #22**. None can be
checked from the source tree. Not blocking, but flag them as external claims; note
§2 references both "PR #25" and "PR #22" — double-check those are the intended,
distinct PRs.

#### n3 — `fetchFromGitHub` packaging caveats (default.nix UNVERIFIABLE FROM REPO)
The npm tarball ships `src/` only (`package.json` `files`); `fetchFromGitHub`
pulls the whole repo (`test/`, `.github/`, etc.). Harmless given the zero-dep
vendoring (`bin` → `src/index.js`), but: every fork commit changes the
`fetchFromGitHub` `hash`, so expect per-commit churn. The `pkgs/teamclaude/
default.nix` is not in this repo, so the swap itself can't be validated here.

---

## 3. Answers to the 5 open questions (§12)

**Q1 — Is the mid-stream SSE scan worth the hot-path complexity, or pre-stream-only?**
**Keep mid-stream — it is both cheap and necessary.** Cheap: the SSE stream is
already parsed per-event (`server.js:430-434`/`parseSSEUsage`), so detection is a
few lines in an existing function, not a new scanner (see m1; the design's perf
fear is overstated). Necessary: §1.2 itself states the subscription "usage limit
reached" commonly arrives as a *mid-stream SSE error inside a 200* — pre-stream-only
would miss the **primary** shape and only update state on the *next* request.
Condition: gate the predicate on the B1/B2 capture; if (and only if) evidence shows
the Opus limit always arrives as a clean 429 or a pre-body header, drop mid-stream.

**Q2 — Does Anthropic emit `unified-status: rejected` for the Opus sub-limit, or
only for the unified weekly?** **UNVERIFIABLE FROM REPO — and the prior is "only
for the unified weekly."** `anthropic-ratelimit-unified-status` is, by name and by
how `updateQuota` treats it (`account-manager.js:358-359`), a property of the
*unified* state, not a per-model sub-limit. So do **not** plan on a cheap header
check replacing body inspection; assume you need structured-`error.type` body
inspection of the limit response, and verify with the capture. If the capture
surprises you and the header *is* Opus-correlated, great — make it a fast-path
hint, never the sole signal.

**Q3 — Reuse 0.98 for Opus, or be more conservative?** **Be more conservative:
default Opus to ~0.90 (configurable via `switchThresholds`).** Rationale: a single
Opus agentic request can move utilization by several points, and the poll has up to
`pollIntervalSec` (90s) of lag plus the sub-threshold window — at 0.98 there is
effectively no margin to rotate *before* the cap. 0.90 trades a little Opus
headroom for actually rotating early, which is the entire point. Caveat: the
threshold is a coarse early-rotate; the real safety net is the §6 backstop, so
don't over-tune it. (If you want symmetry, leave 5h/7d/Sonnet at 0.98 and special-
case Opus.)

**Q4 — cloudbox: unify on the nix package, or keep the checkout?** **Unify on the
nix package (`fetchFromGitHub`).** The stated reason to keep a checkout — the
interactive `teamclaude login` flow — is not a real blocker: `login` is the same
`bin` (`oauth.js:loginOAuth`, browser + stdin-paste race in `raceWithStdinCode`)
and runs identically from the packaged binary; it needs a browser/stdin, not a
source checkout. Reproducibility and "devbox already consumes this package" (§11)
win. Keep a checkout **only** if you actively hack on teamclaude source on cloudbox;
otherwise drop it. (Unverifiable here: that `default.nix` builds the packaged
`bin` correctly from `fetchFromGitHub` — validate that during the deploy step.)

**Q5 — Fold Sonnet into the model-class machinery (A), or Opus-only overlay (B)?**
**I disagree with the design's choice of A; prefer B for v1.** The design picked A
for "proper design," but for a *focused, verifiable, upstreamable* fork, B (Opus
overlay) is the lower-risk first cut: smaller diff, and — critically — it avoids the
M5 regression where generalizing `_isNearQuota` turns Sonnet from display-only
(`account-manager.js:218-219` checks neither Sonnet nor Opus today) into a
selection gate. Whether Sonnet *should* gate selection is itself an unsettled
product question the maintainer deferred in Issue #1; don't answer it as a
side-effect of the Opus work. Ship B (Opus-specific bucket + gate), keep Sonnet
display-only, and revisit the A generalization once `seven_day_opus` is confirmed
and you have a reason to change Sonnet behavior deliberately.

---

## 4. What's missing

1. **The MITM/`mitm.js` relay** (B3) — biggest omission. A whole code path with its
   own selection + quota + 429 handling, picked per-CONNECT, that cannot honor §5b
   or §6. Must be scoped out in writing or designed for.
2. **Evidence before design** — `seven_day_opus` existence (B1), the limit's wire
   shape / `error.type` (B2), whether a shorter Opus window exists (m4). The design
   defers these to "during implementation," but they determine whether §4/§5/§6 are
   even buildable. They belong **before** the plan. You already have the tools:
   `teamclaude api /api/oauth/usage` for field names, `teamclaude server --log-to`
   for the limit response.
3. **A real-payload test fixture.** §10's unit/integration tests would otherwise
   validate the implementation against *hand-authored guesses* of the wire shape.
   Capture one real `/api/oauth/usage` body and one real limit response, commit them
   as fixtures, and assert against those — that's the difference between "tests
   pass" and "tests prove."
4. **Interaction of per-request class selection with rotation state** (M1) — the
   stateless-query vs. mutate-`currentIndex` decision, thrash/log-spam avoidance.
   Not specified.
5. **`computeRetryAfter` generalization** (M2) — it ignores unified resets today;
   §5d must fix that, not just append Opus.
6. **Config story** (M3/M4) — reconcile with the existing `quotaProbeSeconds`; state
   the hard dependency (proactive Opus needs the probe on); reconcile "on by
   default" with the passive-only upstream philosophy and the "upstreamable" claim.
7. **Concurrency window.** Several Opus requests can be in flight to the same
   account before headers/poll/backstop update its bucket; the first batch can pass
   the limit through before `unified7dOpus` is marked. Acceptable, but the design
   should state the bound (≈ in-flight count) rather than imply single-request
   tightness.
8. **Operational signal on the streamed-through error.** §1.2 says "no log line";
   accurate for console/TUI (the SSE error is only captured in the `--log-to` file
   if enabled). The design adds Opus *state* surfacing (§9) but no
   **event**/log when the backstop fires — add at least one `console.log` when an
   Opus limit is detected (pre- or mid-stream), or it'll be as invisible to debug
   as the current bug.
9. **`teamclaude status` CLI printer** (m3) — listed under "missing" because §9 only
   names the TUI bar and `/status`.
