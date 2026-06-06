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
- Host **cloudbox**, user user@company.com, egress IP REDACTED, UA `opencode/1.15.13`.
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
- bq dataset: `my-gcp-project.vertex_ai_audit_logs.cloudaudit_googleapis_com_data_access`
  (call-counts only, NO tokens → can't price from audit alone; pricing needs oc-cost + tokens).
- Looker dashboard: https://lookerstudio.google.com/reporting/REDACTED
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
- Spring Boot+PG+Redis proxy at mono `your-org/data/aigateway` (source on **origin/main**, NOT in
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

---

## POST-RESTART RESUME PLAN (read this if opencode-serve was just restarted)

The retry-cap deploy worker (`ses_166faf734ffen83FtybOn5O5Y0`) deploys Fix 1 and then
**restarts opencode-serve via a detached process**, which kills the orchestrator session
AND the aigateway worker. After the restart, do this:

1. **Verify the cure is live:**
   - `systemctl status opencode-serve` → active (running), started just now.
   - `curl -s localhost:8080/actuator/health` (aigateway) still UP.
   - Read `~/projects/workstation/docs/investigations/2026-06-05-vertex-gemini-surge/retry-cap-deploy.md`
     for the new nix store path; confirm the new opencode-patched build contains the cap
     (grep the built JS for the MAX_RETRIES constant / a `Schedule.recurs`). Old path (rollback):
     `/nix/store/k775j7vkyvnsrzshrysbfl906nwcl0yh-opencode-patched-1.15.13.2`.
   - `/tmp/retry-cap-deploy.log` shows the restart command output.
2. **Resume the aigateway worker** (`ses_1670df706ffeIwMdzaEcSoTaGA`): its git worktree off
   origin/main + edits persist on disk. Re-prompt it (opencode-send / prompt) to "continue
   where you left off — check your worktree git status first." Task: add `claude-opus-4-8` to
   PriceTable (fix opus NULL) + gemini support; deliver aigateway-cost-fix.md + mono PR.
3. **Remaining work:** Fix 2 config hardening (non-gemini compaction/default in workstation
   Nix); then the low-pri list (upstream title-cost issue, dashboard query sync to PR #3215,
   oc-cost push decision, rotate plaintext secrets).
4. **Watch the next overnight cycle** via the forward-capture log (~/.local/state/opencode-llm-audit/llm.log)
   and BQ to confirm the cap stopped the runaway (no session.id repeating abnormally; gemini
   calls/hr stay bounded).

Worker session IDs: w1 retry-rootcause `ses_1671e4e42ffeae5UKWFHuB1ZjR` (done) · w2 forward-capture
`ses_1671e01ccffeVwWgxKSj0y9wlq` (done) · w3 aigateway `ses_1670df706ffeIwMdzaEcSoTaGA` (resume) ·
w4 retry-cap deploy `ses_166faf734ffen83FtybOn5O5Y0` (in progress).

---

## UPDATE 2026-06-05 ~15:10 EDT — durable cure + gemini routing IN FLIGHT (compacting)

State: BOTH primary fixes are LIVE & verified. Now making the cure durable + enabling gemini routing.

### Verified done & live
- CURE live: opencode-serve runs capped `opencode-patched-1.15.13.3` (RETRY_JITTER_RATIO present in
  running binary; absent in old k775). MAX_RETRIES=8 + jitter.
- aigateway fix live: opus `claude-opus-4-8` now records tokens+dollars (264 rows/$43 last hr, was 0%);
  gemini parse+price works; unpriced models keep tokens. mono PR #3373 (food-truck/mono, OPEN).
- forward-capture live (~/.local/state/opencode-llm-audit/llm.log). RCA in this dir + /tmp.

### In flight (worker `ses_16663d5f5ffe2NUO3Ryz6vW6V0`, ~/projects/workstation)
- Pushed opencode-patched main (retry-cap 6fa9663). Triggered capped release **v1.16.2-patched.1**
  (build-release.yml run in ~/projects/opencode-patched, ~3min build).
- Worker tasks: (A) bump workstation off the local --impure 1.15.13.3 pin (commit 1af8073) to the
  published capped **v1.16.2-patched.1** so a PURE `home-manager switch` works + automation tracks
  capped; (B) enable gemini routing (provider.google-vertex.options.baseURL → localhost:8080
  /v1beta1/.../publishers/google, reversible, per aigateway-cost-fix.md §7); then ONE pure switch +
  detached opencode-serve restart; then push publishable workstation commits.
- DEADLINE context: workstation update-opencode-patched.yml cron ~18:00 EDT bumps to latest release —
  publishing capped v1.16.2-patched.1 before then makes automation track the CAPPED version.

### POST-RESTART VERIFICATION (do after the worker's detached restart)
1. `systemctl status opencode-serve` active; `readlink -f /proc/$(systemctl show opencode-serve -p MainPID --value)/exe`
   → should be a **v1.16.2-patched.1** store path (NOT k775 1.15.13.2, NOT the uncapped 1.16.2 path
   `nisvz7...`). Confirm cap: `rg -ac RETRY_JITTER_RATIO <storepath>/bin/.opencode-wrapped` ≥1.
2. Gemini routing live: make/await a gemini call, confirm a `gateway_request_log` row for a gemini model
   with tokens+dollars (`docker exec dev-postgres-1 psql -U aigateway -d aigateway -c "..."`), and the
   forward-capture log shows gemini providerID=google-vertex going via the gateway.
3. Pure build worked (no --impure): check worker report durable-cure-gemini-routing.md.
4. Read worker report: durable-cure-gemini-routing.md (changes, hashes, rollback, push/PR result).
5. Rollback if broken: generation 379 (capped 1.15.13.3) `<gen379>/activate && sudo systemctl restart opencode-serve`. NOT gen 378 (uncapped 1.16.2).

### Remaining after that (lower pri)
- Fix 2 config hardening (non-gemini compaction/default) — reduces gemini blast radius.
- Watch tonight's cycle via forward-capture + BQ to PROVE the cap holds (no session.id repeating; gemini calls/hr bounded).
- Low: upstream title-cost issue; sync dashboard queries to infra PR #3215; push oc-cost commit c3f2894; rotate plaintext secrets in opencode.json.

Worker IDs: w3 aigateway `ses_1670df706ffeIwMdzaEcSoTaGA` (DONE, PR #3373) · w5 durable-cure+gemini-routing `ses_16663d5f5ffe2NUO3Ryz6vW6V0` (in flight).

---

## ✅ RESOLVED 2026-06-06 ~13:50 EDT — durable cure + gemini routing VERIFIED LIVE

Post-restart verification (serve restarted, new PID on the durable binary) all PASS:
- **Running serve binary** = `/nix/store/fwmg3h82vk2dl34zrzkz93898njhd01c-opencode-patched-1.16.2.1/bin/.opencode-wrapped`
  (pure-built, durably pinned via published release — no more --impure). Cap markers in the
  RUNNING binary: RETRY_JITTER_RATIO=1, MAX_RETRIES=2, attempt-cap `attempt>na)return`=1, --version 1.16.2.
- **Gemini routes through the gateway with tokens+dollars**: gateway_request_log gemini-3.5-flash rows,
  http_status 200, input/output_tokens + total_dollars populated. Runtime opencode.json has both
  anthropic + gemini → localhost:8080; hash file = dc629052…
- **CAP HOLDS (runaway dead)**: 918 gemini calls today across **902 distinct input sizes**; max
  identical-call repeat = **3**; peak 475 calls/hr; $27/day total. vs runaway 72,517 calls/night
  (~35×), $1.5–2.5k. No single-session identical-stream re-issue pattern.
- **Git**: origin/main @ 3e8bbb2 — TASK A 39a8080 (capped v1.16.2-patched.1 bump) · TASK B 96c2cd6
  (gemini routing) · report 52538c9 · skills 3e8bbb2. HEAD publishable (no /home path); tree clean.
- **Deadline neutralized**: v1.16.2-patched.1 is releases/latest → update-opencode-patched.yml cron
  tracks the CAPPED version.

### Remaining (optional / low-pri, NOT blocking)
- Fix 2 config hardening (move default/compaction off gemini) — now LOWER value since gemini is capped
  + observable through the gateway; blast radius already mitigated.
- Low: upstream title-cost issue; sync dashboard queries to infra PR #3215; push oc-cost commit
  c3f2894; rotate plaintext secrets in opencode.json (Slack/Datadog/PagerDuty).
- mono PR #3373 (aigateway opus cost + gemini support) — open, shepherd to merge.

INCIDENT CLOSED: durable retry-cap cure + cost observability deployed and verified.
