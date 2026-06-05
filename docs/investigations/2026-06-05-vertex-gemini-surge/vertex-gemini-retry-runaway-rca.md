# RCA: Vertex gemini-3.5-flash cost runaway (uncapped OpenCode retry)

**Status:** Root cause confirmed; fix in deployment.
**Date of analysis:** 2026-06-05. **Host:** cloudbox. **Severity:** High (cost).
**Author:** opencode investigation session (with dispatched opus workers).

Durable copy + evidence: `~/projects/workstation/docs/investigations/2026-06-05-vertex-gemini-surge/`
(HANDOFF.md, lgtm-retry-rootcause.md, overnight-surge-forensics.md, opencode-ancillary-calls-report.md).

---

## 1. Summary

An automated overnight workload on cloudbox drove a **~35× amplification of SUCCESSFUL
gemini-3.5-flash Vertex API calls**. Over a single 16-hour window (2026-06-04 15:00 →
2026-06-05 07:00 UTC), Vertex logged **72,517 successful** gemini calls while OpenCode's
own database recorded only **2,061 steps** — a 35.2× gap. The amplification is caused by
**OpenCode core's per-step LLM retry policy, which has no attempt cap**: a step that hits a
retryable condition re-issues the entire model stream every ≤30 s indefinitely, and each
re-issue is a fresh (billable, status-OK) Vertex request.

The runaway is **gemini-specific** because gemini runs on a tight `google-vertex` quota
that frequently trips the retryable conditions; Anthropic/opus runs on a separate quota
(`google-vertex-anthropic`) and reconciles ~1:1.

## 2. Cost impact

| Metric (overnight window 06-04 15:00 → 06-05 07:00 UTC) | Value |
|---|---|
| Successful gemini-3.5-flash Vertex calls (deduped, status OK) | **72,517** |
| Hard 429s (RESOURCE_EXHAUSTED) in same window | 7 |
| gemini steps recorded in OpenCode DB | 2,061 |
| Amplification factor | **35.2×** |
| gemini cost OpenCode *recorded* (DB/oc-cost) | **$71.76** |
| gemini avg input tokens / step | 13,976 |
| **Estimated TRUE gemini Vertex spend (this window)** | **~$1,500–$2,500** |
| opus cost same window (legitimate, ~1:1, not amplified) | ~$503 |

Estimate basis: each retry re-sends the step's full input (~14k tokens) at $1.5/1M input;
scaling recorded cost by 35.2× yields ~$2,525 (upper bound), input-only re-send yields
~$1,520 (lower bound). **If unfixed and recurring on each unattended overnight cycle:
~$1.5–2.5k/night ≈ $45–75k/month of pure waste.**

The damage is **invisible to message-based cost tooling** (oc-cost, the OpenCode cost
display): only the ~2,061 recorded steps carry cost; the ~70k retry calls never become DB
rows. Only the Vertex audit log (call counts) reveals the volume.

## 3. Detection

Spotted via the Vertex AI audit-log dashboard (per-user call counts) showing a gemini
spike. Confirmed in BigQuery
(`my-gcp-project.vertex_ai_audit_logs.cloudaudit_googleapis_com_data_access`), deduping
streaming double-logging with `COUNT(DISTINCT IFNULL(operation.id, insertId))`. The storm
ended at 07:00 UTC to the second — the 03:00 EDT `nightly-restart-background.service`
restarting `opencode-serve` killed it (it was terminated, not self-resolved).

## 4. Root cause (technical)

**OpenCode core's per-step retry is unbounded.**

- `packages/opencode/src/session/retry.ts:175-198` (`policy()`) builds a schedule with **no
  `Schedule.recurs`/max-attempt ceiling**. It terminates *only* when `retryable()` returns
  `undefined` (the error stops classifying as retryable). For a persistently-retryable
  condition it loops forever.
- Backoff is exponential `2000·2^(n-1)` capped at `RETRY_MAX_DELAY_NO_HEADERS = 30_000` ms
  (`retry.ts:25-65`; test `retry.test.ts:35-39`) → a stuck step retries every 30 s
  indefinitely.
- Applied at `processor.ts:780-843` wrapping the **whole stream of a single step**. Each
  attempt calls `llm.stream(streamInput)` afresh (`processor.ts:790`) and discards partial
  output (`ctx.currentText = undefined`, `:787`) — a full new Vertex request, not a resume.
- One assistant message = one DB "step-start", created **once per step**
  (`prompt.ts:1347-1362`), before the retry loop. So `DB steps = #assistant messages`,
  while `Vertex calls = Σ(1 + retries)`. 72,517 / 2,061 ≈ 35.2× = avg Vertex requests/step.

**Why the amplified calls are status-OK (not 429).** `Effect.retry` fires whenever the
*client* sees a retryable failure even though Vertex logged the HTTP/gRPC call OK:
1. In-band mid-stream errors under HTTP 200 (Vertex streaming opens 200 then emits an
   error event mid-body: server_error / overloaded / streamed resource_exhausted).
   `retryable()` classifies these (`retry.ts:121,144`).
2. Connection drops / header timeouts (ECONNRESET, header-timeout) after the request
   started (`retry.test.ts:167-173,377-389`).
3. Post-stream finish-step throwing a retryable error (the reason the `tool-fix.patch`
   exists) — the underlying Vertex call *succeeded* but post-processing throws → full
   stream re-issued.

Only the rare *pre-stream* 429 is logged RESOURCE_EXHAUSTED — hence just 7 in the window.

**Confirmed in the deployed binary** `opencode-patched-1.15.13.2`: contains
`RETRY_MAX_DELAY_NO_HEADERS` + `fromStepWithMetadata`, **zero `Schedule.recurs`**. `git
log -S "Schedule.recurs"` shows no cap was ever present — this is an inherited upstream
design defect, not a fork regression. The `opencode-patched` stack does not touch retry.

## 5. Contributing factors

- **Gemini blast radius on one constrained quota.** gemini-3.5-flash is the OpenCode global
  default (`opencode.json:154`), the compaction model (`:8`), the lgtm gather model
  (`lgtm/src/gather.ts:10`), and both reviewer subagents (`code-reviewer.md`,
  `spec-reviewer.md`) — all on the single `google-vertex` quota. Quota pressure is what
  trips the retryable conditions.
- **lgtm cadence.** `lgtm-run.timer` fires every 10 min all night, continuously minting
  gemini work (gather sessions + reviewer subagents + compactions).
- **Leaky stop-gap.** lgtm's only safety net (`gather.ts:172-215`) DELETEs a stuck gather
  session on a 120 s timeout, but only when the launch output parsed an id
  (`:188-191`), is best-effort/error-swallowed, and does **not** cover the reviewer
  subagents — so stuck gemini steps can retry uncapped for hours.
- **Observability gaps (separately fixed):** (a) the aigateway ledger was failing to
  capture opus tokens/dollars (missing `claude-opus-4-8` in PriceTable → usage nulled);
  (b) gemini bypasses the aigateway entirely, so per-request gemini cost wasn't ledgered;
  (c) OpenCode does not log title/auxiliary small-model calls as messages.

## 6. What it is NOT (ruled out)

- **Not pigeon / lgtm re-running sessions.** The Telegram "🤖 Retry … Next attempt at …"
  is a pure *notifier* forwarding OpenCode's `session.status{type:"retry"}` event
  (`pigeon/packages/opencode-plugin/src/index.ts:604-633`). Pigeon's own retries are
  message-delivery only, capped at 10 (`arbiter.ts:14,102-127`).
- **Not a quota/429 storm.** 72,517 calls succeeded; only 7 were RESOURCE_EXHAUSTED.
- **Not whole-session reruns.** During the storm hours opus stayed at 63–466/hr while
  gemini hit 7,488/hr; whole-session reruns would have surged opus proportionally.

## 7. Resolution

| Fix | What | Where | Status |
|---|---|---|---|
| **Fix 1 (cure)** | Cap per-step retries (~5–8) + add jitter to backoff | new patch in `opencode-patched/patches/`, against retry.ts:180 / processor.ts:810 | **Deploying** (this session) |
| Fix 2 | Move compaction + global default off gemini; consider dedicated/raised gemini quota | workstation Nix `opencode-config.nix` (`opencode.json:8,154`) | Planned |
| Fix 3 | aigateway: add `claude-opus-4-8` pricing (fix opus NULL) + gemini support | mono `your-org/data/aigateway` | In progress (worker) |
| Fix 4 | Durable LLM-audit capture (service=llm + retry/error lines → ~/.local/state) | workstation `opencode-llm-audit.nix` | **Done, live** |
| Fix 5 | lgtm defense-in-depth: never launch unkillable session; bound subagent wall-clock; cost circuit-breaker | `~/projects/lgtm` | Planned |
| Fix 6 | pigeon: dedup the `session.status` retry notifier (stop Telegram flood) | pigeon opencode-plugin | Planned (cosmetic) |

## 8. Action items / prevention

1. **[P0] Land Fix 1** (retry cap + jitter) and redeploy opencode-serve — removes the
   unboundedness so no condition can run away.
2. **[P1] Fix 2** config hardening — removes the trigger (quota pressure) for the default
   + compaction surfaces.
3. **[P1] Fix 3** aigateway opus pricing + gemini routing — gives per-request gemini cost
   so the next anomaly is dollar-attributable in real time (currently only the Fix 4
   capture + BQ counts).
4. **[P2] Fix 5** lgtm lifecycle + a global gemini spend/rate circuit-breaker as
   defense-in-depth even if a new uncapped path appears.
5. **[P2]** Verify with the Fix 4 capture on the next overnight cycle that no session.id
   repeats abnormally; capture the exact triggering error payload.
6. **[Hygiene]** Rotate the plaintext Slack `xoxp-`, Datadog, and PagerDuty secrets in
   `~/.config/opencode/opencode.json`; move to sops/Keychain.

## 9. Evidence index

- Uncapped policy: `retry.ts:175-198` (no `Schedule.recurs`); backoff `retry.ts:25-65` +
  `retry.test.ts:35-39`. Retry wraps whole stream: `processor.ts:780-843,787,790`.
  One DB step/assistant message: `prompt.ts:1347-1362`.
- BQ overnight: 72,517 OK / 7 RESOURCE_EXHAUSTED / 2 cancelled (deduped).
- DB storm window: gemini 2,061 steps, $71.76, 28.8M input tok, avg 13,976 in/step;
  opus 2,774+459 steps, ~$503.
- Deployed binary uncapped: `/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2`.
