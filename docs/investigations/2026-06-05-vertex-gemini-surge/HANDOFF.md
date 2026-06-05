# Vertex gemini-3.5-flash cost surge — investigation HANDOFF

Durable record (the source /tmp copies get wiped by the 03:00 nightly cleanup).
Companion files in this dir: `query{1,2,3}.sql` (corrected dashboard queries),
`overnight-surge-forensics.md`, `opencode-ancillary-calls-report.md`, and (when
workers finish) `lgtm-retry-rootcause.md`.

## The core finding (what we're chasing)

The Vertex audit dashboard showed a jump in gemini-3.5-flash call count. Root of it:
an **automated overnight workload that amplifies SUCCESSFUL gemini calls ~35×** via
an application-level retry-rescheduler, risking a large recurring bill.

### Established facts (hard evidence)
- Host **cloudbox**, user jmohrbacher@wonder.com, egress IP 34.24.187.96, UA `opencode/1.15.13`.
- Overnight 2026-06-04 15:00 → 2026-06-05 07:00 UTC: **~72,500 deduped SUCCESSFUL**
  gemini-3.5-flash Vertex calls (status OK; only 7 RESOURCE_EXHAUSTED, 2 cancelled).
  DB recorded only **~2,033 gemini step-starts** in that window → **~35× amplification
  of successful calls** (NOT failed retries).
- opus reconciles **1:1** (DB messages ≈ Vertex calls) — different gateway/quota.
- Emitter: `opencode-serve.service` (systemd, Restart=always, **no XDG override → main
  DB** at ~/.local/share/opencode/opencode.db).
- Driver: `lgtm-run.service` (systemd timer, **every 10 min all night**, ~/projects/lgtm,
  `node tsx src/index.ts`). gather model = `google-vertex/gemini-3.5-flash` (gather.ts);
  review model = opus (dispatch.ts); opus reviews fan out gemini code-reviewer/spec-reviewer
  subagents. Plus subagent-driven-development sessions on the **global-default** gemini model.
- Surge ended 07:00 UTC **to the second** because `nightly-restart-background.service`
  (03:00 ET) restarts opencode-serve — it was killed, not finished.
- **Retry scheduler** (the amplifier): Telegram (pigeon) notification
  `"🤖 Retry: sb41-upgrade-plan / Retry #1: Resource exhausted ... 429 / Next attempt at
  10:50:13 PM / ses_16bfd483cffeGnLOEfjUCSXJ4R"`. On a 429 it reschedules/re-runs the
  session; reruns re-execute gemini steps that SUCCEED → amplification. Corroborated by the
  active `gemini-empty-parts.new.patch` (packages/llm/src/protocols/gemini.ts) — gemini
  response/request-handling bugs are a live issue.

### Dual mechanism for "DB ≠ Vertex" (two separate things, don't conflate)
1. **Counting artifact (proven):** auxiliary calls (session **title generation**, etc.) are
   made on small/default models and written only to the `title` session COLUMN — never a
   message/part, usage event discarded. So message-based accounting (oc-cost) is blind.
   Title model: `getSmallModel()` (provider.ts:1771) hardcodes haiku-first; opus sessions
   title on **haiku**, gemini-default sessions fall back to **gemini-3.5-flash**.
2. **Retry amplification (being root-caused):** the ~35× overnight gemini gap — successful
   calls from session re-runs that don't persist proportional steps.

### Corrections to earlier wrong theories (keep honest)
- "Ephemeral/cleaned separate data dir hid the calls" — WRONG. opencode-serve uses main DB.
- "opencode server is run manually / no systemd unit" — WRONG (it's a *system* service;
  earlier only `--user` units were listed).
- Forensics agent's "quota retry storm" — WRONG cause: 72,500 calls SUCCEEDED, only 7 were
  RESOURCE_EXHAUSTED. The 429s are rare and get *rescheduled*; the volume is successful reruns.
- My probe claim "1 trivial session = 2 gemini + 1 haiku auxiliary" — mis-attributed; a
  session emits exactly ONE title call (haiku for opus sessions). The 2 gemini were other
  concurrent sessions' titles.

## Status of current burn
NOT storming now (~130–280 gemini calls/hr daytime = normal). Runaway is conditional
(unattended + 429s + rescheduler). It will recur on the next overnight cycle unless fixed.
No emergency mitigation taken; lgtm-run.timer still enabled.

## Work items / status
- [DONE] Corrected dashboard queries (dedup `COUNT(DISTINCT IFNULL(operation.id, insertId))`
  — streaming logs 2 rows/call; non-streaming has NULL operation.id so fall back to insertId).
  Files: query{1,2,3}.sql here. **TODO: sync these into the Looker dashboard + infra PR #3215.**
- [DONE] oc-cost `--vertex-reconcile` mode (commit `c3f2894` in workstation, NOT pushed).
  95 tests green (55→95), pure stdlib + `bq` subprocess, configurable table/project/principal.
- [IN PROGRESS] Worker `ses_1671e4e42ffeae5UKWFHuB1ZjR` (opus, ~/projects/lgtm): root-cause the
  retry amplification (lgtm + pigeon). → writes `lgtm-retry-rootcause.md` here.
- [IN PROGRESS] Worker `ses_1671e01ccffeVwWgxKSj0y9wlq` (opus, ~/projects/workstation): build +
  INSTALL durable LLM-audit log capture (service=llm + retry/error lines → ~/.local/state/...).
- [TODO] Hardening (after worker 1): cap provider/app retries, exponential backoff, idempotent
  resume (don't re-run completed steps), set explicit non-gemini `compaction`/`small_model` in
  ~/.config/opencode/opencode.json, land gemini-empty-parts fix. Consider a cost circuit-breaker.
- [TODO] Open upstream anomalyco/opencode issue: title/auxiliary calls omitted from cost
  accounting (stored as session column, usage event dropped). file:line evidence in
  opencode-ancillary-calls-report.md §5.
- [TODO] Decide whether to push oc-cost commit `c3f2894`.

## Key references
- bq dataset: `wonder-sandbox.vertex_ai_audit_logs.cloudaudit_googleapis_com_data_access`
  (call-counts only, NO tokens → can't price from audit alone; pricing needs oc-cost + tokens).
- Looker dashboard: https://lookerstudio.google.com/reporting/e7e82a5b-80ce-463e-881f-cd1c39195bae
- Jira AGENT epic (Vertex AI Gateway): AGENT-2; Phase 1 dashboard = AGENT-1 (Done).
- oc-cost: ~/projects/workstation/pkgs/oc-cost/ (test: `cd pkgs/oc-cost && python3 -m unittest test_oc_cost -v`).

---

## UPDATE 2026-06-05 PM — ROOT CAUSE CONFIRMED + new findings (supersedes the "pigeon/lgtm rescheduler" theory)

### ROOT CAUSE (worker 1, see lgtm-retry-rootcause.md): uncapped per-step retry in OpenCode core
- The 35× is **OpenCode core's per-step LLM retry policy, which has NO attempt cap**.
  `packages/opencode/src/session/retry.ts:175-198` (`policy()`) — no `Schedule.recurs`/max —
  applied at `processor.ts:810-840`. A stuck step re-issues the ENTIRE Vertex stream every
  30s (backoff cap) **forever**, until the error stops classifying retryable.
- Each retry = a fresh Vertex call **logged status OK**; DB writes one assistant message per
  *step* (`prompt.ts:1347-1362`). 72,500 calls / 2,033 steps ≈ 35× = avg Vertex requests/step.
- Amplified calls are SUCCESSFUL (not 429) because the triggers are: in-band mid-stream errors
  under HTTP 200, ECONNRESET/header-timeouts, or post-stream finish-step throwing retryable
  (the `tool-fix.patch` reason). Only ~7 hard 429s logged all night.
- Gemini-specific only because gemini's tight `google-vertex` quota trips those conditions;
  opus (`google-vertex-anthropic`, separate quota) rarely fires → reconciles 1:1.
- **Pigeon/lgtm are NOT the amplifier.** The Telegram "🤖 Retry … Next attempt" is just a
  NOTIFIER forwarding OpenCode's `session.status{type:"retry"}` (pigeon opencode-plugin
  index.ts:604-633, no dedup → floods Telegram). Pigeon's own retries are delivery-only, capped
  at 10. lgtm is the work *source* (gather + reviewer subagents + compaction + default all on
  gemini, every 10 min) and its gather timeout→DELETE stop-gap leaks (gather.ts:188-191,199-210).
- **Discriminator that proved it (my BQ + gateway cross-check):** during the storm hours
  (03:00–06:00 UTC) opus was only 63–466/hr while gemini hit 7,488/hr. Whole-session reruns
  would have surged opus too; they didn't → amplification is gemini-quota-specific, matching
  the per-step retry firing on gemini's overloaded/exhausted conditions.

### THE CURE (worker 1 Fix 1) — not yet implemented
- Cap per-step retries: in `retry.ts:180` add `|| meta.attempt > MAX_RETRIES → Cause.done`,
  or compose `Schedule.recurs(N)` at `processor.ts:810`. Cap ~5–8. Add jitter to `delay()`.
- Ship as a NEW patch in `~/projects/opencode-patched/patches/` (deployed binary =
  `opencode-patched-1.15.13.2`; existing patches don't touch retry). **Deploy = rebuild
  opencode-patched + restart opencode-serve, which BOUNCES ALL SESSIONS — do deliberately.**
- Fix 2 (config hardening, complements): set non-gemini `compaction`/default model in the
  Nix-managed opencode.json (workstation users/dev/opencode-config.nix) to shrink blast radius.

### aigateway = newly-discovered cost data source (user tip)
- Spring Boot+PG+Redis proxy at mono `wonder/data/aigateway` (source on **origin/main**, NOT in
  the docs-branch working tree; built jars in dev/). Running docker-compose project "dev"
  (dev-gateway-1/dev-postgres-1/dev-redis-1, ports 8080/5432/6379). Ledger table
  `gateway_request_log` has tokens + DOLLARS (which BQ audit logs lack). Query:
  `docker exec dev-postgres-1 psql -U aigateway -d aigateway -c "..."`.
- **Only proxies google-vertex-anthropic (opus + haiku titles); gemini bypasses it.**
- **Bug found:** 10,790 opus rows have NULL tokens+dollars because `PriceTable.kt` lacks
  `claude-opus-4-8` (has 4-7/4-5) → compute() throws → ProxyController:182-195 nulls usage+cost.
  Haiku works (in table). → aigateway worker dispatched (see below).
- The haiku ledger rows are the "invisible-to-oc-cost" title calls — cross-confirms the title
  counting-artifact (mechanism #1).

### Worker status
- Worker 1 (lgtm/pigeon retry) — **DONE** → lgtm-retry-rootcause.md.
- Worker 2 (forward-capture) — **DONE + WORKING**: capturing `service=llm` attribution +
  retry lines to ~/.local/state/opencode-llm-audit/llm.log (verified live). home-manager change
  STAGED-not-committed in workstation. Next storm will be attributable by session.id/model/agent.
- Worker 3 aigateway (`ses_1670df706ffeIwMdzaEcSoTaGA`, opus, mono worktree off origin/main) —
  IN PROGRESS: add claude-opus-4-8 pricing (fix opus NULL) + gemini support (parse usageMetadata,
  price, proxy google publisher path). Gateway redeploy is safe; the opencode gemini-routing flip
  is GATED (gemini is the global default — broken route breaks everything). → aigateway-cost-fix.md.

### Security (worker 1 side-note, out of scope)
- opencode.json holds plaintext secrets: Slack `xoxp-` (line ~135/150), Datadog DD_API_KEY/
  DD_APPLICATION_KEY (~72-73), PagerDuty key (~88). Rotate + move to sops/Keychain.
