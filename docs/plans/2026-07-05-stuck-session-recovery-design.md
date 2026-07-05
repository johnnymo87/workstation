# Stuck-Session Recovery: sweeper honesty, pigeon delivery watchdog, question-tool hygiene

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make delivered-but-never-run swarm prompts self-recover within minutes (instead of hours), scope the phantom-busy sweeper to the dead-owner class it was designed for, and remove the footgun that let a headless task subagent block its whole session lineage forever on the `question` tool.

**Architecture:** Three interlocking pieces across two repos. (1) workstation: the phantom-busy sweeper only DB-finalizes rows whose owning serve is provably gone — SHIPPED 2026-07-05. (2) pigeon: a delivery watchdog verifies each handed-off swarm message actually started an assistant run, and owns the abort+redeliver+alert escalation because only pigeon has the demand signal. (3) workstation opencode config: deny `question` to subagents, restoring upstream's intended default that our global `"*": "allow"` accidentally overrides.

**Tech Stack:** Nix/home-manager (workstation), TypeScript + better-sqlite3 + vitest (pigeon daemon), opencode agent config (JSON + markdown frontmatter).

---

## 1. Motivating incident (2026-07-05, loot session)

Full forensics: swarm msgs `msg_mr7y4jt9` (report request) / `msg_mr7yb397` (findings). Summary:

1. 11:01:09Z parent (`ses_0d638d38cffe…`, serve :4097) starts a task turn; headless child (`ses_0ce0f20ab…`) blocks forever on the `question` tool at 11:03:52Z — nobody can answer. Parent's task tool awaits the child. Both fibers alive-but-blocked.
2. 11:35:05Z the phantom-busy sweeper DB-marks both rows aborted ("serve died mid-turn" — a hardcoded, wrong label; nothing died). The serve's **in-memory** runner still holds the fiber chain, so the session stays busy.
3. 15:02:31Z pigeon delivers a swarm message: `prompt_async` 2xx, user row appended, but the runner never starts a turn behind the live current turn. `handed_off` is terminal-success in pigeon today — nobody notices.
4. 15:22:47Z manual `POST /session/abort` kills the fibers; a re-send then works. Net: 4h stuck.

### Division of labor (the Q4 analysis — capture this; it drives the design)

| | phantom-busy sweeper | pigeon delivery watchdog |
|---|---|---|
| Signal available | row staleness only (DB) | **queued demand**: handed-off msg + user row + no assistant run |
| Can see serve in-memory state | no | indirectly (transcript via owning serve's HTTP API) |
| Safe actions | DB-finalize rows **no live process can complete** | abort + redeliver, because it KNOWS someone is waiting and the session isn't serving them |
| Must NOT | abort (would kill legit silent long turns; DB-marks at least self-heal — an abort doesn't) | DB-write opencode.db (stays on the HTTP API like all of pigeon) |

The sweeper without the liveness gate actively **lied**: its DB marks told observers the turns were aborted while the serve still ran them, and the marks didn't free the session. The watchdog is the only component with a precise, low-collateral trigger.

---

## 2. Workstream 1 — sweeper fixes (workstation) — SHIPPED

Done in workstation commits `sweeper: only finalize rows that predate every live pool serve` + the earlier threshold/label work (2026-07-05). Current behavior (`users/dev/home.devbox.nix`, `opencode-phantom-busy-sweeper`):

- Finalizes only rows: assistant + `time.completed IS NULL` + no error + `time_updated` silent >30min + **`time.created` predates the boot of every currently-running `opencode-serve@*` unit** (max `ps etimes` across pool MainPIDs; no live serve ⇒ old staleness-only behavior).
- Honest label: `Aborted (phantom-busy sweeper: in-flight row predates all live serves, silent >30min)`.
- Documented caveat: rows executed by standalone (non-pool) `opencode` TUI processes predate no serve boot; the 30-min silence gate is the only protection there (same as the original design).

Remaining task in this plan: none (verified live: `finalized 0 … (cutoff=1783234807)` = exactly the 03:00 pool boot). Listed for completeness so the reviewer sees the whole system.

---

## 3. Workstream 2 — pigeon delivery watchdog (pigeon repo)

### 3.1 Current pipeline facts (from code recon)

- `swarm_messages` (packages/daemon/src/storage/swarm-schema.ts:5-31): `state ∈ queued|handed_off|failed`, `attempts`, `next_retry_at`, `handed_off_at`. `markHandedOff` (swarm-repo.ts:118) fires right after `sendPrompt` = `POST /session/{id}/prompt_async` 2xx (opencode-client.ts:101). **handed_off means "serve accepted the async prompt", not "run started" — it is terminal-success today. That's the gap.**
- Primitives already present: `OpencodeClient.abortSession` (opencode-client.ts:126), `getSessionMessages` (:136), read-only `IngressRouter.resolveRoute` (routing/router.ts:59), reaper-style interval loop with re-entrancy guard (`startSessionReaper`, worker/session-reaper.ts:55-77), Telegram alerts via `notifier.sendPlainAlert` (notification-service.ts:492/667), sender-facing failure messages via `notifySenderOfFailure` (swarm/arbiter.ts:163-188), envelope includes `msg_id` (swarm/envelope.ts).
- Redelivery = flip state back to `queued` (what `markRetry` does); arbiter re-sends within 500ms.
- Pigeon never reads opencode.db directly; transcript access is HTTP `getSessionMessages` (existing pattern in compact-ingest.ts:27, current-state-ingest.ts:58). The watchdog keeps that rule.

### 3.2 Design

**Schema additions** (swarm_messages; additive, no state-enum change):
- `verified_at INTEGER` — set when an assistant run is confirmed; verified rows are never re-checked.
- `recovery_attempts INTEGER NOT NULL DEFAULT 0` — count of watchdog interventions for this msg (distinct from delivery `attempts`).

**New module** `packages/daemon/src/swarm/delivery-watchdog.ts`, loop patterned on session-reaper (interval + `processing` guard), started from index.ts. Config knobs (config.ts, env-overridable):
- `WATCHDOG_INTERVAL_MS` = 60_000
- `VERIFY_AFTER_MS` = 300_000 (operator's N=5min)
- `STUCK_TURN_MS` = 900_000 (15min — see abort-safety below)
- `MAX_RECOVERIES` = 1 (one abort+redeliver; second failure ⇒ terminal)

**Cycle**, for each row `state='handed_off' AND verified_at IS NULL AND to_session IS NOT NULL AND handed_off_at < now - VERIFY_AFTER_MS`:

1. **Resolve owner read-only**: `resolveRoute(to_session)`; if no route/healthy serve, skip this cycle (rows stay eligible; serve-death recovery is the health-poller/router's job).
2. **Transcript check**: `getSessionMessages(to_session)`;
   - find the user message whose text contains this `msg_id` (the envelope embeds it);
   - **not found** ⇒ the 2xx lied / the write was lost: `requeue` (state→queued, `next_retry_at = now + 5s`) WITHOUT abort (nothing to kill), `recovery_attempts++`.
   - found, and **any assistant message with `time.created` > that user row's `time.created` exists** ⇒ `verified_at = now`. Done. (Limitation, documented: an instantly-aborted assistant row counts as "ran"; the sender still gets a `session.idle`-shaped outcome and human escalation handles semantic non-answers. YAGNI on deeper semantics.)
   - found, no later assistant message ⇒ **stuck candidate**, go to 3.
3. **Abort-safety gate** (the crucial part — do not kill legitimate work):
   - Inspect in-flight turns: any assistant message with `time.completed == null`?
   - **None in-flight** ⇒ session is idle yet never ran our prompt (dropped queue entry): `requeue` without abort, `recovery_attempts++`.
   - **In-flight and its `time.created` < now - STUCK_TURN_MS** ⇒ blocked long enough to presume stuck (incident case: 4h): if `recovery_attempts < MAX_RECOVERIES`: `abortSession(to_session)` on the resolved owner's client, then `requeue` with `next_retry_at = now + 5s` (let the abort settle), `recovery_attempts++`.
   - **In-flight but younger** ⇒ legitimately busy (long tool call, deep turn): do nothing; row re-checked next cycle.
4. **Terminal failure**: stuck candidate with `recovery_attempts >= MAX_RECOVERIES` (i.e. we already aborted+redelivered once and it's stuck again) ⇒ `markFailed`, `notifier.sendPlainAlert("swarm delivery watchdog: <msg_id> to <session> stuck after abort+redeliver", "error")`, and a `delivery.failed`-style swarm message to the sender (reuse/extract `notifySenderOfFailure`).

**Interaction with arbiter retries:** requeued rows re-enter the normal arbiter path (fresh `sendPrompt`, `markHandedOff` bumps `handed_off_at`, so the next verification window starts from the redelivery). Delivery `attempts` and `recovery_attempts` stay independent; `MAX_ATTEMPTS=10` still bounds transport-level failures.

**Observability:** structured log line per action (`verified`, `requeued`, `aborted+requeued`, `terminal`), counts per cycle; nothing on the happy path except `verified_at` writes.

### 3.3 Why abort goes to the owning serve only

`resolveRoute` names the serve whose in-memory runner holds the fiber; abort there is sufficient (the manual fix hit both pool serves only because ownership wasn't known). Idempotent anyway — but the watchdog should not spray aborts at serves that may own *other* live turns for unrelated instances of the session directory.

---

## 4. Workstream 3 — question-tool hygiene (workstation)

### 4.1 Root cause (from source recon, v1.17.7 tree)

- opencode's built-in defaults **already deny `question` to subagents** (`src/agent/agent.ts:124`; only `build`/`plan` overlay allow at :146/:161).
- Permission evaluation is **last-matching-rule-wins** (`Permission.evaluate` findLast, `src/permission/index.ts:39`), and the user config ruleset merges after built-ins — so our deployed global `"permission": {"*": "allow"}` (assets/opencode/opencode.base.json:4-9) appends a trailing `*: allow` that overrides `question: deny` for every subagent. **We broke upstream's safe default ourselves.**
- Per-agent config permission merges after the user ruleset (`agent.ts:291`) and also strips the tool from the LLM tool list (`Permission.disabled` in `src/session/llm/request.ts:198`), so an agent-level `question: deny` wins everywhere.
- There is no headless/TUI-attached signal in the permission system (`OPENCODE_CLIENT` is process-level and pool serves host both attended and unattended sessions), so **process- or session-level denial is the wrong knob**; agent-level is exactly right: `build` (primary, human-attended semantics) keeps `question`; task-spawned subagents lose it.

### 4.2 Changes

1. `assets/opencode/opencode.base.json`: add
   ```json
   "agent": {
     "general": { "permission": { "question": "deny" } },
     "explore": { "permission": { "question": "deny" } }
   }
   ```
   (merged with the existing `agent.compaction` overlay in opencode-config.nix — verify the nix overlay and base json merge cleanly).
2. Every custom subagent asset in `assets/opencode/agents/*.md` gains `question: deny` in its `permission:` frontmatter (implementer currently has NO permission block — add one; vision-qa already `*: deny`; audit the full set: code-reviewer, oracle, adversarial-reviewer, spec-reviewer, librarian, implementer, beads-task-agent, slack — enumerate at implementation time).
3. Deploy via home-manager; **note the additive-merge gotcha**: `mergeOpencode` never deletes keys, but we're only adding, so a plain switch suffices on each host (devbox now; cloudbox/macOS/crostini ride their next switch).
4. **Deferred (explicitly out of scope, note for a future bead):** replacing the global `"*": "allow"` with explicit allows — it also overrides `doom_loop: ask`, `plan_enter/exit: deny`, and `.env`-read asks; that's a behavior-review project of its own. Also deferred: fork-level question timeout for headless sessions (`question/index.ts:172` `Effect.timeout` wrap) — unnecessary once subagents can't ask and primaries are human-attended; revisit only if a primary headless session gets stuck on question in practice.

### 4.3 Interaction with workstream 2

Even with `question` denied to subagents, other indefinite-block shapes remain possible (permission asks in unattended sessions, future tools). The watchdog is the generic safety net; hygiene just removes the known biggest hole. Both are needed; neither substitutes for the other.

---

## 5. Risks / open questions (for adversarial review)

1. **Abort collateral**: is the in-flight-turn age gate (STUCK_TURN_MS=15min) sufficient to protect legitimately-long attended turns that happen to have a swarm message queued behind them? Alternative considered: also require the in-flight turn's last part activity to be silent (needs part timestamps from the HTTP payload — verify availability).
2. **Verification semantics**: "any later assistant row" is deliberately weak (see 3.2.2 limitation). Is that acceptable for v1?
3. **Transcript size**: `getSessionMessages` returns the full transcript (hundreds of KB for old sessions) once per unverified row per cycle. With VERIFY_AFTER_MS=5min and verified-row short-circuit, steady-state load is near zero; a burst of K stuck messages to one mega-session costs K fetches/cycle. Acceptable? (Could dedupe per-session per-cycle.)
4. **Channel sends**: rows with `to_session IS NULL` (channel fan-out) are out of scope v1 — confirm that's how channels are stored, or handle their per-target rows.
5. **Migration**: ALTER TABLE ADD COLUMN on daemon start (initSwarmSchema is CREATE IF NOT EXISTS + additive columns need a guard). Pattern for the existing schema evolution?
6. **Clock skew / restart races**: handed_off_at vs serve restart mid-verification — worst case is a wasted abort on an idle session (harmless) or a duplicate redelivery (dup user row; senders already tolerate at-least-once).

---

## 6. Implementation plan

### Task 0: pigeon worktree + baseline

**Step 1:** `cd ~/projects/pigeon && git pull --rebase && npm install`
**Step 2:** `npm run --workspace @pigeon/daemon test` and `npm run typecheck` — record baseline (expect green).
**Step 3:** No worktree needed if working directly on main is repo convention — check AGENTS.md; otherwise `git worktree add`.

### Task 1: swarm_messages schema additions (pigeon)

**Files:** Modify `packages/daemon/src/storage/swarm-schema.ts`, `packages/daemon/src/storage/swarm-repo.ts`; Test `packages/daemon/test/swarm-repo.test.ts`.

1. Failing test: after `initSwarmSchema`, inserting a row and calling new repo methods `markVerified(msgId, now)`, `bumpRecovery(msgId)`, `listUnverifiedHandedOff(now, verifyAfterMs)` behaves (returns row before verify, not after; recovery_attempts increments).
2. Run: `npm run --workspace @pigeon/daemon test -- swarm-repo` — expect FAIL (methods missing).
3. Implement: `ALTER TABLE`-guarded additive columns (`verified_at`, `recovery_attempts`) in initSwarmSchema (follow whatever additive-migration guard pattern exists; else `PRAGMA table_info` check); repo methods incl. requeue helper `requeueForRecovery(msgId, now, delayMs)` (state→queued, next_retry_at, recovery_attempts+1).
4. Tests green; typecheck; commit `feat(daemon): swarm delivery verification columns`.

### Task 2: delivery-watchdog module (pigeon)

**Files:** Create `packages/daemon/src/swarm/delivery-watchdog.ts`; Test `packages/daemon/test/delivery-watchdog.test.ts`.

1. Failing tests (in-memory storage + mocked client factory à la swarm-arbiter.test.ts; injected `nowFn`):
   - verifies a handed-off row when transcript shows user(msg_id)+later assistant → `verified_at` set, no client calls beyond getSessionMessages;
   - user row missing → requeued, no abort;
   - user row present, no assistant, no in-flight turn → requeued, no abort;
   - user row present, in-flight turn older than STUCK_TURN_MS → abortSession called on owner + requeued + recovery_attempts=1;
   - in-flight younger than STUCK_TURN_MS → untouched;
   - stuck again with recovery_attempts=1 → markFailed + sendPlainAlert + sender notification;
   - no route → row untouched;
   - re-entrancy guard: overlapping runs coalesce.
2. Run to fail. 3. Implement per §3.2 (single pass function `processOnce`, `start(intervalMs)` like session-reaper; extract `notifySenderOfFailure` from arbiter into a shared helper or accept a callback). 4. Green + typecheck. 5. Commit `feat(daemon): swarm delivery watchdog (abort+redeliver stuck handed-off messages)`.

### Task 3: wire into daemon (pigeon)

**Files:** Modify `packages/daemon/src/index.ts`, `packages/daemon/src/config.ts`.

1. Failing test: config defaults for the four knobs (config test file pattern — check existing config tests).
2. Implement: config knobs + env parsing; construct watchdog with `router.resolveRoute`-based read-only client lookup (NOT `ensureRouted` — no placement writes from the watchdog) + `storage.swarm` + `notifier`; `start()` alongside the reaper (index.ts:314 area).
3. Green + typecheck; commit `feat(daemon): start delivery watchdog`.

### Task 4: deploy pigeon + live verification (devbox)

1. Deploy per repo convention (git pull + npm install + restart pigeon service — see cross-device-deployment skill in repo).
2. Live smoke: send a swarm message to a throwaway session; confirm `verified_at` gets set within ~6min (happy path).
3. Stuck-path drill (controlled): create a session, wedge it artificially (start a long fake turn — e.g. a bash `sleep 1200` tool call via a prompt, or replay the incident shape with a question-blocked child in a sandbox session), swarm-send to it, watch the watchdog abort+redeliver at the deadline. Record journal lines.
4. Commit any doc updates; update the design doc status.

### Task 5: question-tool hygiene (workstation)

**Files:** Modify `assets/opencode/opencode.base.json`, `assets/opencode/agents/*.md` (all subagents lacking a deny; enumerate `ls assets/opencode/agents/`), possibly `users/dev/opencode-config.nix` if the `agent` key needs nix-side merging.

1. Add `agent.general/explore.permission.question = deny` to base json; add `question: deny` to each custom subagent's frontmatter permission block.
2. `home-manager switch` on devbox; verify merged `~/.config/opencode/opencode.json` contains the agent overlays and `~/.config/opencode/agents/*.md` carry the deny.
3. Behavioral verification: launch a task subagent (explore) prompted to "ask the user a question via the question tool"; confirm the tool is absent/denied (transcript shows no question part; agent reports inability).
4. Commit `opencode: deny question tool to subagents (restores upstream default overridden by global allow)`.

### Task 6: land + report

1. Push both repos; per workstation AGENTS.md landing protocol.
2. Update beads (or morning-items doc while bd migration-blocked): close/annotate; file the deferred global-`*: allow` review bead.
3. Report to coordinator ses_0ceec2678ffeGmMEJ5jwnsFJ5U at land.
