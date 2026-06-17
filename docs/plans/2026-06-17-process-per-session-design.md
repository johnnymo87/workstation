# Process-per-session vs. fix/upgrade serve — Design + measurement gate

> **For Claude:** DESIGN doc (the "what and why"), not a task-by-task plan.
> Captures the architecture + decision gate converged on in the 2026-06-17 design
> session (author opus `ses_128ece55b...`, reviewer gpt-5.5 `ses_1288c3050...`) so
> it survives compaction. Companion artifacts:
> `docs/plans/2026-06-17-lgtm-run-conversion-prompt.md` and
> `OPENCODE-SERVE-MULTICORE-INVESTIGATION.md`. Implementation plan comes next
> and goes back to the reviewer.

**Status:** Design reviewed (2 rounds). **Reviewer verdict: no-go on retiring
serve as written; go-with-changes for a staged, measurement-gated path.** Nothing
implemented. Serve stays until the Phase-0 gate (§3) resolves *and* the removal
gate (§12) is green.

**Goal (reframed after review):** decide — on *measured slope data*, not
assumption — whether to **patch**, **upgrade**, or **replace** `opencode-serve`,
and only build process-per-session if the data justifies it. Keep the single
shared `opencode.db`, the TUI, and inter-session pigeon throughout.

---

## 1. Why (problem statement) — with a version-skew correction

`opencode-serve` is a single Bun process on one JS event loop. On cloudbox
2026-06-17: 16 cores, 62 GB; load ~4–8/16 (**box NOT resource-bound**); but serve
is **core-bound** under a ~30-client reconnect burst (pegs 1–2 cores, RSS to
19–32 GB) while 14 cores idle. The box already runs **29 `opencode attach` clients
= 13.5 GB** (~477 MB each) — it *already* pays for ~29 separate processes plus
serve.

**Critical caveat (review Critical #1, verified):** the evidence base is
version-skewed. Three codebases exist:
- **Deployed:** `1.17.7-patched` (upstream v1.17.7, old line). The orphan
  investigation (4ed4f749) confirmed BOTH hot paths here: GlobalBus broadcast
  fan-out + `project copy refresh`.
- **origin/dev `10b6672be`** (newer rewrite): what
  `OPENCODE-SERVE-MULTICORE-INVESTIGATION.md` actually analyzed — neither deployed
  nor the patch target. (That doc needs a correction note saying so.)
- **local HEAD `0b7038baa`** (wip): event.ts refactored to `Bus.subscribeAll`,
  `project/copy.ts` **absent**, `location-layer.ts` has no ProjectCopy.

So the newer line may have **already removed 2 of the 3 bottlenecks**. That is why
the premise is now three-way, not "replace."

## 2. The decision is three-way

| Option | What | Cost |
|---|---|---|
| **(1) Patch** v1.17.7 | filter-before-queue, bounded/singleflight refresh, `setMaxListeners` | small, low-risk |
| **(2) Upgrade** off v1.17 line | newer line already removed ProjectCopy + refactored fan-out | big fork-rebase (bead `workstation-4j9`: ~966 commits, version-scheme reset) + breaks the deliberate hold at 1.17.7 |
| **(3) Replace** with process-per-session | §4–§11 | multi-month re-architecture; pigeon becomes control plane |

**Replace (3) must beat BOTH (1) and (2) on measured data.** Current load
(4–8/16) says "one event loop is blocked or doing waste work," NOT "the workload
needs 16 cores." Process-per-session only wins if, after removing waste work,
remaining *useful* work still saturates one event loop and demonstrably benefits
from OS-level parallelism.

## 3. Phase-0 measurement gate (REQUIRED before the implementation plan)

A single "realistic load test" is too confounded (provider latency, DB locks,
reconnect churn). Instead, a matrix that **independently varies three axes**;
**the discriminator is the slope, not the absolute number.**

**Variants** (same harness each): **V0** deployed v1.17.7-patched baseline · **V1**
v1.17.7 + the small serve fixes · **V2-stock** newer-line opencode, NO fork
patches · **V2-ported** newer line + rebased patch stack (only if V2-stock passes)
· **V3** process-per-session prototype (lgtm-`run` first, not full interactive
replacement).

**Harness hygiene:** isolated/copied DB + data dir, **pin `OPENCODE_DB`** (no
channel-DB skew). cloudbox is **GCP ARM**; devbox is Hetzner x86 — a devbox
harness will NOT predict cloudbox, so run on a scratch cloudbox-shape VM or on
cloudbox in a maintenance window with the live serve stopped. **Randomize variant
order; ≥2 consistent runs** for any conclusion; between runs stop the process
tree, recreate the copied DB, verify no leftover opencode/pigeon/mock processes.

**Three tests:**
- **A — subscriber slope** (active work fixed small): vary `/event` subscribers
  0/1/10/30/60, no reconnects. *Fan-out-bound signature:* serve-PID CPU +
  event-loop delay scale with subscriber count while host CPU stays low; V1/V2
  flatten the slope.
- **B — reconnect/refresh slope** (active work ~0): vary simultaneous reconnects
  1/10/30/60 with realistic worktree distribution; measure time-to-all-healthy,
  p99 health latency, RSS peak, ProjectCopy/git-subprocess counters. *Refresh-bound
  signature:* spike only on reconnect, correlated with ProjectCopy; bounded/
  singleflight or the newer line removes most of it.
- **C — active-work slope** (subscribers 0–1, no reconnect burst): vary active
  sessions 1/5/15/30 doing representative work via a **calibrated streaming mock**
  (below). *True-aggregate-CPU signature:* after V1/V2 remove fan-out/refresh,
  serve still pins one core, event-loop delay rises with active count, wall-clock
  degrades, and V3 spreads CPU across cores with lower wall-clock at equal
  success-output rate. *Not-replacement signature:* after V1/V2, serve CPU/lag no
  longer grows badly, or the bottleneck shifts to provider latency / SQLite busy.

**Calibrated streaming mock (Test C must not be a provider-latency artifact):** a
fake/instant provider removes the realistic token-streaming/parse/SSE-encode CPU
that dominates a turn. The mock must emit a **representative chunked stream**
(chunk count, chunk sizes, inter-chunk cadence, total output, event mix), sourced
from real opencode turns via `packages/http-recorder` or the aigateway ledger —
**metadata/shape ONLY, no prompt/response text** (portable, content-free fixture).
Use ≥2 profiles: "short normal turn" and "long review-ish turn." Check if
`packages/opencode/test/fake/provider.ts` / `test/lib/llm-server.ts` is wireable
into a standalone serve harness; else a tiny local OpenAI-compatible mock.

**Instrumentation tiers:** **Tier 0 (required, all variants):** host+PID CPU
(user/sys), RSS/PSS, child count, health latency, wall-clock, **event-loop delay
p50/95/99** (`monitorEventLoopDelay`). **Tier 1 (if cheap):** lightweight
event-loop logging. **Tier 2 (confirmatory only):** internal event/ProjectCopy/
SQLite counters — do NOT make Tier 2 a prerequisite if adding it changes the hot
path; the slope tests stand on Tier 0 alone.

**Correctness gate (runs automatically after EVERY variant/run, not just on bad
perf):** `PRAGMA integrity_check`, `PRAGMA foreign_key_check`, WAL-size delta +
checkpoint behavior, live-but-rowless invariant query, zero SQLite busy surfaced
to callers, zero duplicate session owners (if V3 has an ownership prototype). A
correctness failure fails the run **regardless of perf** (faster-but-corrupting
loses).

**Bounds (preserve verbatim):** *V2-stock is architecture evidence only, not a
production-readiness claim* (don't fail the upgrade option for missing fork-only
patches unless the harness workload needs them). *V3 only earns permission to
DESIGN/BUILD the bigger architecture — it does not prove the full interactive
replacement, broker, revive, reset, or audit story.*

**Decision table → exit ramp:**
- A/B slopes collapse under V1 or V2-stock **and** C acceptable → **fix/upgrade,
  do NOT replace.**
- A/B collapse but C still pins one event loop **and** V3 materially improves
  wall-clock without correctness/DB-busy regressions → **replace has a real case.**
- C shows low CPU but high DB-busy/WAL/checkpoint latency → **fix the DB/write
  path; replacement doesn't solve it.**
- V2-stock removes A/B and C acceptable → **upgrade beats replace** (despite
  rebase pain).
- V1 fixes A/B but V2 blocked by rebase → **patch v1.17.7 near-term;** replace only
  if C later fails.

The rest of this doc (§4–§13) is the design for option (3) **if and only if** the
gate selects it. lgtm-`run` (§10) proceeds regardless, *if it independently pays.*

---

## 4. Process-per-session model (the "replace" design)

- **Interactive/dev** → long-lived `opencode -s <id>` in a tmux pane (optionally
  nvim-hosted). The runtime *is* the pane; tmux holds it alive across SSH drops.
- **Batch (lgtm)** → `opencode run` / `run -s <id>`: one-shot, exits (self-reaping).
- **Single shared `opencode.db` kept** — no per-session DBs.

**Multi-writer is a version-skew problem, not a multi-writer problem.** Many
processes on one local WAL is safe *at one binary version*; the June loss was a
binary cutover (mixed versions) + restarts with clients attached. Rule: **atomic
cutover** (stop ALL opencode processes, swap, start) — matters *more* here (more
writers to quiesce). See also §8.

## 5. What serve actually is (three bundled roles)

| Role | What | New home |
|---|---|---|
| **(a) Host live sessions** | agent loops — the core-pegging part | per-session processes (§4); pigeon spawns/wakes (§7) |
| **(b) Command live sessions** | kill/interrupt/model/mcp/compact/abort/summarize/prompt | pigeon broker → owning process (§6) |
| **(c) Query** | list/resolve/messages | pigeon broker → shared DB (§6) |
| **(c′) Live config/runtime ops** | provider list, MCP connect/status, model — **NOT DB reads** | pigeon broker → forward to owning runtime / parse config (§6, M6) |

(b)/(c)/(c′) are cheap relative to (a) — centralizable in a broker without
recreating the bottleneck (no agent loops, no SSE fan-out there).

## 6. pigeon as control plane (broker)

Extend the existing pigeon daemon (**`:4731`**, pigeon's own API) with command +
query routes; no new process (it already has the registry, direct-channel
delivery, revive-spawn, HTTP server). Consumers migrate off serve's `:4096` to
`:4731`. Commands look up the session's direct-channel endpoint and forward (or
signal the process for kill/interrupt); queries read the shared DB + registry.

**Security (review M4 — was omitted):** pigeon becomes a powerful control plane,
and today its daemon routes are unauthenticated and `server.listen(port)` doesn't
pin the bind host. Before pigeon holds control authority: **bind 127.0.0.1 or a
unix socket**, require a **daemon auth token on mutating routes**, and **validate
registration pid/session ownership before accepting a backendEndpoint overwrite**.

**Not serve-2:** the broker is pure I/O; agent execution + SSE fan-out live in the
distributed processes. External SSE fan-out is *eliminated* (TUI self-hosts; lgtm
self-supervises; Telegram notifications are pushed outbound by the plugin) — verify
nothing external needs a session's live event stream.

**SPOF (review m9 — narrowed):** running sessions keep going without pigeon, but
**messaging, questions, notifications, swarm-inbox, and revive-on-message are
dead-or-lossy** (plugin `notifyStop` has no durable outbox). Document exact
degraded modes; add a durable plugin outbox where needed; require a pigeon
restart/replay test before removal.

## 7. pigeon as reconstitutor ("wake on pigeon")

Today `reviveAndDeliver` delegates to serve (`getSession`+`sendPrompt`) to
reconstitute a dormant session from SQLite — **serve's one irreplaceable
capability.** In process-per-session, pigeon takes it over: on a message for a
session with no live runtime, pigeon **spawns** `opencode -s <id>` (via §11), waits
for direct-channel registration, then delivers. pigeon already spawns processes
(`spawnAutoAttach`). This is the **one genuinely new component** — and per review
C3 it gets its **own design doc** (§9), not a hand-wave here.

## 8. Multi-process safety (review Critical #2)

"Shared WAL at one version" is necessary but not sufficient at 45+ writers. Add:
- **DB-backed session-ownership lease** (CAS + TTL/heartbeat) acquired before any
  runtime loop starts — prevents two runtimes accepting work for one session
  (SQLite serializes rows, not agent ownership).
- **A real maintenance fence** honored by ALL launchers (pigeon, oc-launch,
  oc-revive, lgtm, timers, user shells); verify zero opencode DB FDs before a swap.
- **`createNext` read-back:** verify the durable row before registering/starting
  (mirror core `V2Session.create`), so no live-but-rowless sessions. Already
  tracked: bead `workstation-p196`.
- **Pin `OPENCODE_DB`** (or `OPENCODE_DISABLE_CHANNEL_DB=1`) everywhere — service
  envs do NOT pin it today (`hosts/cloudbox/configuration.nix`,
  `users/dev/home.devbox.nix`), a latent channel-DB split-brain.

## 9. Broker + reconstitutor = its own design (deferred, gated)

Per review C3, do NOT design this in-line — it's the load-bearing new component and
only built if §3 selects replace. Its own doc must define: a **protocol surface**
for prompt/abort/kill/delete/compact/summarize/model/mcp/current-state/provider +
query routes (current direct-channel only does execute + question-reply);
`ensureRuntime(sessionId)` with a **durable per-session spawn lock**,
wait-for-registration, **endpoint generation/CAS** to drop stale ephemeral ports;
and explicit failure behavior for stale auth, port reuse, spawn failure, duplicate
messages, cold-start latency.

## 10. lgtm → `opencode run` (independent track)

lgtm self-orchestrates (`dispatch`+`watchdog`) → needs neither serve nor pigeon.
**Model (A) headless `run`** (auto-reap, auto-spread); `opencode -s <id>` is the
on-demand watch escape hatch (never two runtimes on one session at once).

**Verified gaps to solve (review M5):**
- `run` resolves dir from **PWD unless `--dir`** (`run.ts:135`); lgtm runs from
  `/home/dev/projects/lgtm` under systemd → **must pass `--dir`/cwd=worktree** on
  BOTH fresh and `-s` paths.
- `run` has **no `--mcp`** (options end at `run.ts:241`; only `--agent`); gather's
  `--mcp slack-ro` has no equivalent → eval `--agent` as the scoping path, else
  keep gather on the old path behind the flag.
- `run` can **exit 0 on mid-stream LLM error** (run-process.test) → classify error
  events / DB `info.error` as failure; never trust exit code alone.
- **session-id capture** from a fresh `run` (parse `--format json` stream),
  **concurrency cap** (30 simultaneous opus `run`s = its own thundering herd).
- **Watchdog shrinks:** liveness/death → child-process supervision; **survives:**
  result-validity check (empty-turn) + dispatch bookkeeping (`markDispatched`,
  `shouldReadmitDispatched`, `MAX_DISPATCH_ATTEMPTS`).
- Full brief: `docs/plans/2026-06-17-lgtm-run-conversion-prompt.md`.

## 11. Shared placement helper: `oc-launch` + `oc-revive`

Two entry points over a shared runtime-level core (`ensureRuntime` — "ensure a
runtime for session X in the right tmux/nvim pane"):
- **`oc-launch`** `(dir, model, prompt, mcp…)` → mint **new** session + first
  prompt → `ensureRuntime(newId)`.
- **`oc-revive`** `(session-id [, prompt])` → `ensureRuntime(existingId)` (+
  deliver). Callers: pigeon wake (§7), nightly restore, "open session X".

`oc-auto-attach`'s real value (worktree-path collapse → find-or-create project
tmux window) moves into `ensureRuntime`; serve/SSE assumptions dropped. Names
`oc-launch`/`oc-revive` working; "revive" connotes "was dead" — `oc-resume`/
`oc-open` alternatives for the everyday-open case. Decide at implementation.

## 12. Serve-removal gate (do NOT remove serve until all green)

- [ ] **opencode-launch** → `oc-launch`, not `POST /session`.
- [ ] **opencode-send** (`--direct` prompt_async; `--list` `/experimental/session`) → pigeon command + query routes.
- [ ] **lgtm-sessions** (`GET /session`) → pigeon query route.
- [ ] **oc-auto-attach** (`GET /session/:id`, `opencode attach`) → `oc-revive`.
- [ ] **pigeon daemon** — port 9 worker ingests + `opencode-client.ts` (13 methods) + `registry.resolve` off serve. **Split DB-query (list/resolve/messages) from live config/runtime ops (provider/MCP/model)** — the latter forward to a runtime / parse config, NOT SQLite reads (review M6).
- [ ] **lgtm** (dispatch/gather/watchdog/killSession) → `run` (§10).
- [ ] **reset-workspace** (`/session`, `/global/health`, serve restart) → kill/respawn panes, no central serve.
- [ ] **opencode-llm-audit.nix** — follows serve's **log fd**; process-per-session scatters logs → likely switch the audit source to the **aigateway ledger**.
- [ ] **fp-digest** (devbox `configuration.nix:363-367` → `127.0.0.1:4096`) — review M6 catch; **+ my-podcasts if same shape.**
- [ ] **nightly reset** (cloudbox + devbox) — manifest capture + serve restart → respawn per-session processes.
- [ ] **aigateway URL-change auto-restart** (`opencode-config.nix`) → N/A / retarget.
- [ ] **systemd/launchd `opencode-serve` units** (cloudbox, devbox, crostini, darwin) → remove.

**Not affected (in-process plugins, zero conversion):** `self-compact`,
`context-usage`, pigeon `opencode-plugin` (`index.ts`, `swarm-tool.ts`,
`execute-dedup.ts`) — use `ctx.serverUrl` (in-process), not `:4096`.

## 13. Operational acceptance gates (review M7 — executable, not prose)

Each must have a passing test before serve removal: reset captures/reopens
process-per-session runtimes without `:4096`; audit captures all per-session LLM
calls (or switches to the gateway ledger); plugin-cache + aigateway changes
quiesce and atomically restart all relevant runtimes; nightly reset produces a
valid manifest + recommendation with serve off.

## 14. Open questions / measured gates

- **Memory (review m8 — now a measured HARD gate):** RSS/PSS for serve+N-attach vs
  N standalone `-s` vs N `run`, with real plugins/MCP/context; concurrency caps
  derived from measured PSS, not optimism.
- **Naming:** `oc-launch`/`oc-revive` vs `oc-resume`/`oc-open`.
- **SSE:** confirm nothing external needs a session's live event stream.

## 15. Phasing

0. **Phase 0 — measurement gate (§3).** Reap stale sessions + characterize the
   13.5 GB; build harness; run A/B/C × variants. **Exit ramp:** if V1 or V2-stock
   passes A/B and C is acceptable → stop at fix/upgrade; keep lgtm-`run` only if it
   independently pays. Everything below is gated on this selecting "replace."
1. **lgtm → `run`** behind a flag (§10) — proceeds if it independently pays.
2. **pigeon broker + reconstitutor** own design (§9) + auth (§6).
3. **`oc-launch`/`oc-revive`** + migrate interactive/restore/oc-auto-attach (§11).
4. **Operational rework** (reset, llm-audit→ledger, nightly reset) with §13 tests.
5. **Remove serve** once §12 + §13 green.

## References

- `OPENCODE-SERVE-MULTICORE-INVESTIGATION.md` (NOTE: analyzed `10b6672be`, not
  deployed v1.17.7 — needs correction).
- `docs/investigations/2026-06-17-opencode-1.17.7-orphan-session-wedge.md`.
- `docs/plans/2026-06-17-lgtm-run-conversion-prompt.md`.
- opencode `run`: `~/projects/opencode/packages/opencode/src/cli/cmd/run.ts`.
- pigeon: `~/projects/pigeon/packages/daemon/src` (`opencode-client.ts`,
  `swarm/registry.ts`, `worker/*-ingest.ts`, `worker/revive-and-deliver.ts`,
  `server.ts`, `app.ts`), `.../opencode-plugin/src` (`index.ts`,
  `direct-channel.ts`, `daemon-client.ts`).
- Review thread: opus `ses_128ece55b...` ↔ gpt-5.5 `ses_1288c3050...`
  (msgs `msg_mqil78zs...` → `msg_mqim3asb...`).
