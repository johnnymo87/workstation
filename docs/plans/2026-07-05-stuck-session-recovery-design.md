# Stuck-Session Recovery: sweeper honesty, pigeon delivery watchdog, question-tool hygiene

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make delivered-but-never-run swarm prompts self-recover within minutes (instead of hours), scope the phantom-busy sweeper to the dead-owner class it was designed for, and remove the footgun that let a headless task subagent block its whole session lineage forever on the `question` tool.

**Architecture:** Three interlocking pieces across two repos. (1) workstation: the phantom-busy sweeper only DB-finalizes rows whose owning serve is provably gone — SHIPPED 2026-07-05. (2) pigeon: a delivery watchdog verifies each handed-off swarm message actually started an assistant run, and owns the escalation (alert → abort+redeliver → terminal fail) because only pigeon has the demand signal. (3) workstation opencode config: deny `question` at the user permission level and re-allow it only for attended primaries, restoring (and strengthening) upstream's intended default that our global `"*": "allow"` accidentally overrides.

**Tech Stack:** Nix/home-manager (workstation), TypeScript + better-sqlite3 + vitest (pigeon daemon), opencode agent config (JSON).

**Review status:** Adversarially reviewed 2026-07-05 by ses_0cce93a5effe8dWedN1rzv35XO (Fable 5), msg_mr80ig9g. All 3 Critical, 7 Important, 9 Minor findings folded in below (C1: lease-expiry inertness → any-healthy-serve reads + broadcast abort; C2: turn-age abort collateral → part-activity staleness, alert-first, 60min threshold; C3: migration backfill). Deviations from the operator's original spec are flagged inline with **[DEVIATION]**.

---

## 1. Motivating incident (2026-07-05, loot session)

Full forensics: swarm msgs `msg_mr7y4jt9` (report request) / `msg_mr7yb397` (findings). Summary:

1. 11:01:09Z parent (`ses_0d638d38cffe…`, serve :4097) starts a task turn; headless child (`ses_0ce0f20ab…`) blocks forever on the `question` tool at 11:03:52Z — nobody can answer. Parent's task tool awaits the child. Both fibers alive-but-blocked.
2. 11:35:05Z the phantom-busy sweeper DB-marks both rows aborted ("serve died mid-turn" — a hardcoded, wrong label; nothing died). The serve's **in-memory** runner still holds the fiber chain, so the session stays busy.
3. 15:02:31Z pigeon delivers a swarm message: `prompt_async` 2xx, user row appended, but the runner never starts a turn behind the live current turn. `handed_off` is terminal-success in pigeon today — nobody notices.
4. 15:22:47Z manual `POST /session/abort` kills the fibers; a re-send then works. Net: 4h stuck. (The abort also dropped the queued prompt — the re-send was required. This is why recovery = abort **+ redeliver**.)

### Division of labor (drives the design)

| | phantom-busy sweeper | pigeon delivery watchdog |
|---|---|---|
| Signal available | row staleness only (DB) | **queued demand**: handed-off msg + user row + no assistant run |
| Can see serve in-memory state | no | indirectly (transcript via serve HTTP API) |
| Safe actions | DB-finalize rows **no live process can complete** | alert, then abort + redeliver — it KNOWS someone is waiting and the session isn't serving them |
| Must NOT | abort (would kill legit silent long turns; DB-marks at least self-heal — an abort doesn't) | DB-write opencode.db (stays on the HTTP API like all of pigeon) |

**Honest residual (review I4):** this net only catches stuck sessions that someone *messages*. A headless `build` primary (opencode-launch spawn) that question-blocks with no queued demand is caught by NEITHER component. Workstream 3 shrinks that class (launch-time tool denial); what remains is accepted and documented in §4.4.

---

## 2. Workstream 1 — sweeper fixes (workstation) — SHIPPED

Done in workstation commits `sweeper: only finalize rows that predate every live pool serve` + threshold/label work (2026-07-05). Current behavior (`users/dev/home.devbox.nix`, `opencode-phantom-busy-sweeper`):

- Finalizes only rows: assistant + `time.completed IS NULL` + no error + `time_updated` silent >30min + **`time.created` predates the boot of every currently-running `opencode-serve@*` unit** (max `ps etimes` across pool MainPIDs; no live serve ⇒ old staleness-only behavior).
- Honest label: `Aborted (phantom-busy sweeper: in-flight row predates all live serves, silent >30min)`.
- Documented caveat: rows executed by standalone (non-pool) `opencode` TUI processes predate no serve boot; the 30-min silence gate is the only protection there.

**Cross-host gap (review I7):** the sweeper is devbox-only; cloudbox runs the same pool+pigeon topology and has neither the sweeper nor these fixes. Filed as a follow-up (Task 7) — porting is a copy of the systemd unit into the cloudbox home config, NOT part of this plan's critical path.

---

## 3. Workstream 2 — pigeon delivery watchdog (pigeon repo)

### 3.1 Current pipeline facts (verified in code)

- `swarm_messages` (packages/daemon/src/storage/swarm-schema.ts:5-31): `state ∈ queued|handed_off|failed`, `attempts`, `next_retry_at`, `handed_off_at`. `markHandedOff` (swarm-repo.ts:118, bumps `handed_off_at` on every redelivery — so each redelivery restarts the verification window) fires right after `sendPrompt` = `POST /session/{id}/prompt_async` 2xx (opencode-client.ts:101). **handed_off means "serve accepted the async prompt", not "run started" — it is terminal-success today. That's the gap.**
- Primitives: `OpencodeClient.abortSession` (opencode-client.ts:126), `getSessionMessages` (:136), reaper-style loop with re-entrancy guard (`src/session-reaper.ts:55-77`), Telegram alerts via `notifier.sendPlainAlert` (OPTIONAL interface member, notification-service.ts:54; impls :492/:667), sender-facing failures via `notifySenderOfFailure` (swarm/arbiter.ts:163-188), envelope embeds `msg_id="<id>"` and renders `reply_to="<id>"` distinctly (swarm/envelope.ts:66-67).
- **Routing liveness (review C1 — the fact that reshapes this design):** `resolveRoute(sessionId, now)` (router.ts:59) requires a valid unexpired lease; `leaseTtlMs` = 30s (config.ts:75) and `router.touch` has no production caller. Five minutes after handoff there is essentially never a live lease, so a `resolveRoute`-gated watchdog would be **inert in both the happy path and the incident path**. Consequences adopted: transcript reads go to ANY healthy serve (pool serves share opencode.db — a message read is a DB read); aborts are BROADCAST (per-session no-ops on non-owners, and they kill zombie fibers on former owners after migration — which is why the incident's manual fix hit both serves).
- Channel sends: rows with `to_session IS NULL` never reach `handed_off` (arbiter's `listTargetsWithReady` filters them out), so the watchdog's filter excludes them naturally. (Side-bug — channel rows accumulate forever, `cleanupOlderThan` only deletes handed_off/failed: filed as a bead, out of scope.)
- Pigeon never reads opencode.db directly; transcript access is HTTP `getSessionMessages` (existing pattern: compact-ingest.ts:27, current-state-ingest.ts:58). The watchdog keeps that rule.

### 3.2 Design

**Schema additions** (swarm_messages; additive):
- `verified_at INTEGER` — assistant run confirmed; verified rows never re-checked.
- `requeue_count INTEGER NOT NULL DEFAULT 0` — watchdog-initiated redeliveries (distinct from delivery `attempts`).
- `aborted_at INTEGER` — set when the watchdog has fired its one abort for this msg (review I1: aborts tracked separately from benign requeues).

**Migration (review C3/M6):** follow the storage/schema.ts:102-121 try/catch-swallow ALTER pattern, but use `PRAGMA table_info(swarm_messages)` to detect whether `verified_at` is freshly added, and if so **backfill `verified_at = handed_off_at` for all existing handed_off rows** — the watchdog governs only post-deploy messages; without backfill the first cycle would mass-fetch and mass-redeliver up to 7 days of stale prompts.

**Client resolution (review C1a/C1d):** a `watchdogClientFor(sessionId)` helper:
1. If routing configured: prefer `resolveProspectiveRoute` target (read-only, router.ts:109) for locality; else ANY healthy serve from `serve_instance`.
2. If routing NOT configured (single-serve hosts — crostini): fall back to the plain `opencodeClient` used by the arbiter (index.ts:74 pattern).
3. No healthy serve at all: skip the row this cycle AND count consecutive skips; alert once per msg at >1h unverified (review C1c/M7 age alarm).

**New module** `packages/daemon/src/swarm/delivery-watchdog.ts`, loop patterned on session-reaper (interval + `processing` guard), started from index.ts. Config knobs (config.ts, env-overridable):
- `WATCHDOG_INTERVAL_MS` = 60_000
- `VERIFY_AFTER_MS` = 300_000 — operator's N=5min, used for **verification** timing only
- `STUCK_ALERT_MS` = 900_000 (15min) — Telegram alert when a stuck candidate persists **[DEVIATION** from operator spec "N=5min → abort": review C2 showed abort-at-5min-turn-age kills routine 20-60min task-subagent turns. Alert-first at 15min keeps the human in the loop at roughly the operator's timescale; the abort waits for the stronger signal below.**]**
- `STUCK_ABORT_SILENCE_MS` = 3_600_000 (60min) — abort only when the blocking in-flight turn's **last part activity** is silent this long (review C2: part timestamps are in the getSessionMessages payload — ToolStateRunning/Completed `time.start/end`, Text/ReasoningPart `time.start/end`; turn AGE is the wrong signal, activity staleness is the right one). Known caveat, owned explicitly: a parent whose `task` tool part shows no incremental activity while a healthy child works looks identical to a stuck parent — the 60min threshold plus alert-first is the mitigation; descendant-activity checks are deferred.
- `MAX_REQUEUES` = 3 — bounds ALL requeue paths (review I1: previously the lost-write and idle-never-ran loops were unbounded); distinct terminal reasons per path.
- One abort max per msg (`aborted_at`), independent of requeue count.

**Cycle**, for each row `state='handed_off' AND verified_at IS NULL AND to_session IS NOT NULL AND handed_off_at < now - VERIFY_AFTER_MS`, deduped to one transcript fetch AND at most one intervention per session per cycle (review M2):

1. **Fetch transcript** via `watchdogClientFor`. Error handling (review I6): HTTP 404 → session deleted → `markFailed` + alert (don't loop); 5xx/network → skip row this cycle, NO counter bump; abort failures below likewise don't consume the abort.
2. **Find our user row**: match the exact attribute string `msg_id="<id>"` (excludes `reply_to="<id>"` renders), take the LATEST occurrence (redelivery writes a second row with the same msg_id) (review I2).
   - **Not found** ⇒ the 2xx lied / write lost: if `requeue_count < MAX_REQUEUES`: requeue (state→queued, `next_retry_at = now + 5s`, `requeue_count++`); else terminal: `markFailed` + alert("delivery write repeatedly lost").
   - **Found** ⇒ continue.
3. **Verification**: any later assistant message (`time.created` > our user row's) with **`time.completed` set and no error** (review I5: errored/instantly-aborted rows — including our own abort's casualties — are non-evidence) ⇒ `verified_at = now`. Done.
4. **Stuck classification** (no qualifying assistant row):
   - **No in-flight turn** (no assistant row with `time.completed == null`) ⇒ session idle yet never ran our prompt (dropped in-memory queue entry): requeue without abort (bounded by MAX_REQUEUES as above). No abort — nothing to kill.
   - **In-flight turn exists**: compute `lastActivity` = max part timestamp on that message (fallback: its `time.created` if no part timestamps present).
     - `now - handed_off_at > STUCK_ALERT_MS` and not yet alerted (in-memory dedupe per msg_id; duplicate alert after daemon restart is acceptable) ⇒ `sendPlainAlert(warn)` with session, msg_id, blocking-turn age + silence.
     - `now - lastActivity > STUCK_ABORT_SILENCE_MS` and `aborted_at IS NULL` ⇒ **re-fetch the transcript immediately before acting** (review M2 TOCTOU: a fresh turn may have started); if still stuck: broadcast `abortSession(to_session)` to all healthy serves (review M1; single-client fallback on router-less hosts), set `aborted_at`, requeue with `next_retry_at = now + 5s`.
     - Else ⇒ wait; row re-checked next cycle.
5. **Terminal**: a stuck candidate that already has `aborted_at` set and (post-redelivery, since `markHandedOff` restarted the window) is stuck AGAIN ⇒ `markFailed` + `sendPlainAlert(error)` + `delivery.failed`-style swarm message to the sender (reuse/extract `notifySenderOfFailure`).

**Ordering note (review M3):** a requeued msg A can be delivered after a newer msg B to the same target (arbiter orders by created_at but A sat out its `next_retry_at`). Accepted: swarm semantics are at-least-once, order-best-effort.

**Observability:** structured log per action (`verified`, `requeued(reason)`, `alerted`, `aborted+requeued`, `terminal(reason)`, `skipped(reason)`); per-cycle counts; age alarm per §3.2 client resolution step 3.

### 3.3 Why abort is broadcast, not owner-only

Abort is per-SESSION-ID: `POST /session/{id}/abort` on a serve not running that session is a no-op — it cannot affect other sessions (review M1 corrected the draft's owner-only rationale). Broadcasting kills zombie fibers on former owners after migration; the incident's manual fix hit both serves for exactly this reason. By verification time the lease is expired anyway (C1), so "the owner" is not even knowable — broadcast is both safer and simpler.

---

## 4. Workstream 3 — question-tool hygiene (workstation)

### 4.1 Root cause (verified in v1.17.7 source; line refs to be re-checked against a clean checkout at implementation time — the /tmp worktree has partially scrambled identifiers)

- opencode's built-in defaults **already deny `question` to subagents** (`src/agent/agent.ts:124`; only `build`/`plan` overlay allow at :146/:161).
- Permission evaluation is **last-matching-rule-wins** (`Permission.evaluate` findLast, `src/permission/index.ts:39`); the user config ruleset merges after built-ins — so our deployed global `"permission": {"*": "allow"}` (assets/opencode/opencode.base.json:4-9) overrides `question: deny` for every subagent. **We broke upstream's safe default ourselves.**
- Per-agent config permission merges after the user ruleset (`agent.ts:291`) and strips denied tools from the LLM tool list entirely (`Permission.disabled` in `src/session/llm/request.ts:199`).

### 4.2 Mechanism: user-level deny + primary re-allow (review I3 — replaces the draft's per-agent-file enumeration)

Per-agent frontmatter enumeration cannot reach the whole agent set: `beads-task-agent` is plugin-registered (no markdown asset), `slack` lives only as a runtime opencode.json key, and project-level agents exist in other repos (e.g. eternal-machinery's headless svg pipeline). Instead, one complete, additive-merge-safe change in `assets/opencode/opencode.base.json`:

```json
"permission": { "*": "allow", "question": "deny", "external_directory": { "/tmp/*": "allow" } },
"agent": {
  "build": { "permission": { "question": "allow" } },
  "plan":  { "permission": { "question": "allow" } }
}
```

Why this wins everywhere (verified): built-in agents are `merge(defaults, overlay, USER)` — the user-level `question: deny` lands after build/plan's built-in allow; the config-level `agent.build.permission` re-allow merges after the user ruleset (agent.ts:291) and restores it for the attended primaries only. Every other agent — built-in subagents, plugin-registered, project-local, runtime-added, future — inherits the deny. No opencode-config.nix change needed (nix `lib.recursiveUpdate` at :233 and the jq deep-merge at :345 both merge nested attrsets — review M9).

Optional belt-and-suspenders (skipped as churn): per-agent frontmatter denies.

### 4.3 Headless primaries (review I4)

`build` keeps `question` because attended TUI sessions rely on it — but opencode-launch spawns headless build primaries constantly. Mitigation: **opencode-launch adds `"question": false` to the `tools` map** it already folds into the initial `prompt_async` body (same mechanism as `--mcp`), denying the tool for the launch prompt's whole agent loop. Residual, accepted and documented: a LATER prompt to the same headless session (e.g. swarm-injected) is not covered — if that turn question-blocks, the watchdog catches it iff someone messages the session (§1 residual). Fork-level question timeout remains deferred; revisit only if this residual bites in practice.

### 4.4 Interaction with workstream 2

Hygiene removes the known biggest indefinite-block; the watchdog is the generic demand-driven net; the sweeper handles dead owners. Uncovered by all three: a headless session that blocks (on anything) and is never messaged. Accepted for now; the M7-style age alarm gives partial visibility when there IS traffic.

---

## 5. Resolved design decisions (was: open questions; review verdicts folded)

1. Abort gate: part-activity silence ≥60min + alert-first at 15min (C2). Turn age rejected.
2. Verification: later assistant row with `completed` + no error (I5).
3. Transcript load: acceptable; dedupe per-session per-cycle; verified-row short-circuit + C3 backfill keep steady state near zero.
4. Channels: naturally excluded (never handed_off); accumulation side-bug → bead.
5. Migration: schema.ts ALTER pattern + PRAGMA table_info freshness check + verified_at backfill.
6. Races: TOCTOU refetch before abort; at-least-once duplicates accepted; abort-casualty rows are non-evidence (I5) so the watchdog can't verify against its own abort.

---

## 6. Implementation plan

### Task 0: pigeon baseline

1. `cd ~/projects/pigeon && git pull --rebase && npm install`.
2. `npm run --workspace @pigeon/daemon test` and `npm run typecheck` — record baseline (expect green). Work on main per repo convention (check AGENTS.md; use a worktree if it says so).

### Task 1: swarm_messages schema + repo methods (pigeon)

**Files:** Modify `packages/daemon/src/storage/swarm-schema.ts`, `packages/daemon/src/storage/swarm-repo.ts`; Test `packages/daemon/test/swarm-repo.test.ts`.

1. Failing tests: (a) fresh DB: `verified_at`/`requeue_count`/`aborted_at` columns exist; (b) **upgrade path: create the OLD schema, insert a handed_off row, run the new init — row gets `verified_at` backfilled = its `handed_off_at`**; (c) repo methods `markVerified(msgId, now)`, `requeueForRecovery(msgId, now, delayMs)` (state→queued, next_retry_at, requeue_count+1), `markAborted(msgId, now)`, `listUnverifiedHandedOff(now, verifyAfterMs)` (returns eligible rows; excludes verified, excludes to_session NULL, excludes fresher-than-window).
2. Run: `npm run --workspace @pigeon/daemon test -- swarm-repo` — expect FAIL.
3. Implement (PRAGMA table_info guard for the backfill-only-when-freshly-added).
4. Green + typecheck; commit `feat(daemon): swarm delivery verification columns + backfill`.

### Task 2: delivery-watchdog module (pigeon)

**Files:** Create `packages/daemon/src/swarm/delivery-watchdog.ts`; Test `packages/daemon/test/delivery-watchdog.test.ts`. Fixture: in-memory storage + mocked client factory à la `test/swarm-arbiter.test.ts` + injected `nowFn`.

Failing tests (write ALL first, then implement `processOnce`):
1. happy: user row (`msg_id="<id>"` attr) + later completed clean assistant → `verified_at` set.
2. `reply_to="<id>"` in another row does NOT count as our user row (I2).
3. redelivered duplicate: latest msg_id match anchors verification (I2).
4. later assistant row with error / no completed → NOT verification (I5); classified per stuck rules.
5. user row missing → requeue, no abort; 4th time (MAX_REQUEUES=3 exhausted) → terminal + alert.
6. idle-never-ran → requeue, no abort; bounded likewise.
7. in-flight turn, part activity fresh → untouched.
8. in-flight, handed_off age > STUCK_ALERT_MS → sendPlainAlert(warn) exactly once (in-memory dedupe).
9. in-flight, part silence > STUCK_ABORT_SILENCE_MS, no aborted_at → TOCTOU refetch happens; still stuck → abort broadcast to ALL healthy serves + `aborted_at` set + requeued.
10. TOCTOU: refetch shows fresh activity → no abort.
11. aborted_at set + stuck again post-redelivery → markFailed + sendPlainAlert(error) + sender delivery.failed message.
12. getSessionMessages 404 → markFailed + alert; 5xx → row skipped, no counter bump (I6).
13. abortSession throws → aborted_at NOT set, no requeue count burn (I6).
14. two stuck rows to one session, one cycle → one transcript fetch, ONE intervention (M2).
15. no healthy serve → skipped; unverified >1h → age alarm once (M7).
16. re-entrancy: overlapping `processOnce` coalesces.

Implement per §3.2; `notifySenderOfFailure` extracted from arbiter into a shared helper. Green + typecheck; commit `feat(daemon): swarm delivery watchdog (verify, alert, abort+redeliver)`.

### Task 3: wiring (pigeon)

**Files:** Modify `packages/daemon/src/index.ts`, `packages/daemon/src/config.ts`; Test config defaults per existing config test pattern.

Traps (review I6): construct the watchdog AFTER `notifier` (index.ts:330) — NOT in the ":314 reaper area"; guard `notifier?.sendPlainAlert?.(…)` (optional member, possibly undefined notifier); gate on arbiter/routing being configured, NOT `if (poller)`; router-less hosts get the single-`opencodeClient` fallback; `resolveProspectiveRoute(sessionId, now)` signature. Green + typecheck; commit `feat(daemon): start delivery watchdog`.

### Task 4: deploy pigeon + live verification (devbox first)

1. Deploy per repo cross-device-deployment skill (git pull + npm install + restart daemon).
2. Happy-path smoke: swarm-send to a throwaway session; confirm `verified_at` within ~6min; confirm backfill left historical rows verified.
3. Stuck drill: sandbox session with an artificial 90-min-silent in-flight turn (bash `sleep` tool call), swarm-send to it; watch alert at 15min (journal + Telegram), abort+redeliver at 60min silence, verification after. Time-compressible via env knobs (set STUCK_* low for the drill).
4. Watch the age alarm doesn't fire for normal traffic. Update design doc status; commit.

### Task 5: question hygiene (workstation)

**Files:** Modify `assets/opencode/opencode.base.json`; `pkgs/opencode-launch/default.nix` (+ its test.sh).

1. Base json: `permission.question = "deny"` + `agent.build/plan.permission.question = "allow"` (§4.2 exact shape).
2. opencode-launch: fold `"question": false` into the `tools` map of the initial prompt_async body (same plumbing as `--mcp`); extend `pkgs/opencode-launch/test.sh` source-grep guards.
3. `home-manager switch` on devbox; verify merged `~/.config/opencode/opencode.json` (additive merge is safe here — only adding keys).
4. Behavioral verification (review M8: deny STRIPS the tool from the request — verify by absence, not self-report): run a task subagent (explore) prompted to use the question tool; inspect its transcript for zero question parts AND check the session's request tool list if inspectable; also confirm an attended `build` TUI session still HAS question available.
5. Commit `opencode: deny question below attended primaries; launch-time deny for headless spawns`.

### Task 6: land + report

1. Push both repos; workstation landing protocol.
2. Beads (or morning-items doc while bd is migration-blocked): file the channel-row-accumulation bead (M5), the global-`*: allow` review bead (deferred §4.2 note), sweeper-parity-on-cloudbox (I7 / Task 7), headless-primary residual note (I4).
3. Report to coordinator ses_0ceec2678ffeGmMEJ5jwnsFJ5U at land, including the **[DEVIATION]** flag on abort timing for operator sign-off.

### Task 7 (follow-up, non-blocking): cloudbox sweeper parity

Port the phantom-busy sweeper unit (with the dead-owner gate) into the cloudbox home config; its serve units are system-level (hosts/cloudbox/configuration.nix) so the etimes probe needs the system unit names. Separate session/bead.
