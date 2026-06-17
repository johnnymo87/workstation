# Phase-0 Serve Measurement Harness — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task. This plan implements **Phase 0 only** (the measurement
> gate, §3 of the design). It does NOT implement the broker, reconstitutor,
> oc-launch/oc-revive, or serve removal — those are gated on this gate's verdict.

> **Revision 2 (2026-06-17):** folded reviewer round-1 (gpt-5.5 `ses_1288c3050`,
> `msg_mqinc0k2`). All 10 findings accepted + verified against code (title small-LLM
> call, `run` in-process server, `run --format json` completed-parts-only, storage
> path resolution). Key hardening: correctness-gate ordering, Test-C phase
> accounting, semantic-scrubbed mock + calibration gate, exact V0 pinning + A/A,
> shim A/A + external-primary metrics, executable decision predicates, full
> HOME/XDG/config state isolation, V1 as a decoupled patch deliverable, title/
> small-model call control, M8 reap made read-only/split-out.
>
> **Revision 2 round-2 (`msg_mqinilbf`):** tool-profile materiality + verdict
> asymmetry. Tools may be declared out-of-scope ONLY after measuring their
> materiality in the real trace; if out-of-scope, Test C is a **streaming-only
> lower-bound** and the verdict engine is asymmetric — a streaming-only C may still
> justify `CONTINUE_REPLACE_DESIGN` (tools only add serve load) but may NOT emit a
> `STOP_REPLACE_*` from a "C acceptable" pass when the real trace is tool-heavy
> (new enum `WITHHOLD_TOOL_PROFILE_REQUIRED`).

**Goal:** Build a reproducible benchmark harness that runs `opencode-serve`
variants (V0/V1/V2-stock/V2-ported/V3) through three slope tests (A subscriber,
B reconnect/refresh, C active-work) with **OS/wall-clock-primary** instrumentation
(event-loop delay as a verified-clean diagnostic) and an automatic correctness
gate, then emit a **machine-checkable verdict enum** that selects **patch /
upgrade / replace / fix-the-DB** (or `WITHHOLD`) on measured slope data — not
assumption.

**Architecture:** A standalone Bun + TypeScript CLI (`serve-bench`) that (1) builds
each variant from an exactly-pinned opencode ref + a defined patch set, applying an
identical Tier-0 instrumentation shim to all serve variants and proving via A/A
that the shim/rebuild doesn't move the baseline; (2) drives load per test against a
fully-isolated per-run data/config/HOME surface (not just `opencode.db`); (3)
samples host + per-PID metrics from `/proc` (primary) plus an in-process
event-loop-delay histogram (diagnostic); (4) replays a **semantic-but-scrubbed**
calibrated streaming mock provider for Test C, validated against a real trace; (5)
runs a correctness gate on the *mutated* DB after every run, before recreate; (6)
orchestrates the randomized matrix (≥2 runs/variant) on a cloudbox-shape GCP ARM
host and computes slopes → a verdict enum with thresholds + tie-breakers.

**Tech Stack:** Bun, TypeScript, `bun:test`, `node:perf_hooks`
(`monitorEventLoopDelay`), Linux `/proc`, SQLite (`bun:sqlite`, online backup API
for snapshots; `sqlite3`/PRAGMAs for the correctness gate), an OpenAI-compatible
SSE mock (semantic chunk encoding adapted from opencode
`packages/opencode/test/lib/llm-server.ts`), opencode `run` / `serve` binaries
built from pinned refs.

---

## Scope & Non-Goals

**In scope (Phase 0):**
- The harness itself (builder + A/A, drivers, collector, semantic mock + calibration, correctness gate, orchestrator, verdict engine).
- The V1 "small serve fixes" patch set on the deployed v1.17.7 ref — authored as a **decoupled patch deliverable** (bead `workstation-qjk4`) with its OWN acceptance tests, then *consumed* as a built artifact by the matrix.
- A **minimal** V3 process-per-session prototype: N raw `opencode run` processes driven by the harness (Test C only), measured with explicit phase accounting. NOT the full lgtm conversion.
- Pre-flight memory characterization (**read-only**) feeding the §14 memory hard-gate.

**Out of scope (gated on the verdict, or split into guarded runbooks):**
- Full lgtm → `run` conversion (bead `workstation-7eiv`; brief: `docs/plans/2026-06-17-lgtm-run-conversion-prompt.md`).
- V2-ported build (bead `workstation-rb77`) — built ONLY if V2-stock passes A/B.
- Broker/reconstitutor design + multi-process safety (beads `workstation-zao4`, `workstation-mn9r`).
- **Stale-session reaping** — moved OUT of this plan into a separate guarded runbook (see M8 note). Phase-0 only *characterizes*; it never reaps.

---

## Open Decisions (reviewer-answered; defaults locked unless user overrides)

1. **Harness home** — standalone repo `~/projects/serve-bench` (recommended; clean
   of the opencode fork + Nix flake). Alt: `~/projects/workstation/tools/serve-bench/`.
2. **Test host** — throwaway **cloudbox-shape GCP ARM** scratch VM (recommended).
   Alt: cloudbox in a maintenance window with live serve stopped + sessions
   quiesced. devbox (x86) is invalid; preflight refuses it.
3. **Event-loop-delay source** — keep in-process `monitorEventLoopDelay` (true
   event-loop delay is inherently in-process) BUT it is **diagnostic, not a hard
   predicate**: OS/PID CPU, wall-clock, and health latency are the primary verdict
   evidence. The shim is gated by an A/A (shim-on vs shim-off) + scrape-rate
   sensitivity check; if A/A is dirty, event-loop delay is demoted to confirmatory.
4. **Mock protocol** — OpenAI-compatible SSE with **semantic (scrubbed) JSON**, not
   byte filler; wired via a custom opencode provider `baseURL`. Verify v1.17.7 and
   the newer line accept the same provider config (parity).

---

## Repo Layout (target: `~/projects/serve-bench`)

```
serve-bench/
  package.json  tsconfig.json  .gitignore   # ignore results/, node_modules/
  src/
    host/preflight.ts          # assert host shape; refuse wrong/dirty host
    env/isolate.ts             # per-run HOME/XDG/config/OPENCODE_DB sandbox
    proc/cpu.ts  proc/mem.ts   # /proc parsers (cpu, VmRSS, smaps_rollup Pss)
    metrics/histogram.ts       # percentile rollup
    metrics/collector.ts       # PID-set + host sampler -> time series
    metrics/eventloop.ts       # shim source + /__bench/metrics poller (diagnostic)
    build/refs.ts              # EXACT pinned refs + patch sets + asset hashes
    build/build-variant.ts  build/instrument.ts
    build/aa.ts                # A/A: shim-on/off + faithful-rebuild comparisons
    build/patches/shim/        # uniform instrumentation shim (ref-keyed)
    mock/profiles/             # semantic-scrubbed turn fixtures (short, long-review)
    mock/extract.ts            # derive semantic shape from trace (scrub text only)
    mock/provider.ts           # OpenAI-compatible SSE; server-side send timestamps
    mock/calibrate.ts          # real-trace vs scrubbed-replay similarity gate
    db/snapshot.ts             # backup-API pristine copy; integrity-check pristine
    correctness/gate.ts        # integrity/fk/WAL/rowless/busy/dup-owner
    load/test-a.ts  load/test-b.ts  load/test-c.ts
    orchestrator/matrix.ts     # randomized variant x test; gate-before-recreate
    report/decision.ts         # slopes -> verdict ENUM w/ thresholds + tie-breaks
    cli.ts                     # preflight|build|aa|calibrate|run|report
  test/                        # bun:test specs mirror src/
  results/                     # gitignored: raw datasets + reports + archived DBs
```

---

## Validity Safeguards (reviewer-prioritized; apply throughout)

- **Correctness gate runs on the MUTATED run DB, BEFORE recreate** — never validate
  a freshly recreated pristine DB. Ordering is unit-tested (M7.1).
- **Identical instrumentation, proven by A/A** — same shim on V0/V1/V2 at the same
  semantic route layer; shim-on/off + scrape-rate A/A must be clean or event-loop
  delay is demoted to diagnostic.
- **Full per-run isolation** — absolute `OPENCODE_DB`, `OPENCODE_DISABLE_CHANNEL_DB=1`,
  isolated `HOME`/`XDG_DATA_HOME`/`XDG_CONFIG_HOME`/config; not just the DB file.
- **Semantic mock, calibrated** — valid OpenAI SSE JSON envelopes + synthetic
  content of equal byte length + synthetic tool names/args of comparable
  size/depth/key-count (or tools explicitly out of scope); cadence validated from
  mock **server-side send timestamps**, and the whole mock validated against a real
  trace within tolerance before any C-slope is trusted.
- **Title/small-model calls controlled** — explicit non-default titles for every
  benchmark session AND request-matching so only the measured prompt gets the
  calibrated profile; assert expected provider-call counts per run.
- **Exact V0** — pinned to the `opencode-patched` release (source commit + upstream
  commit + 5-patch stack + platform asset hash + tag); A/A vs the deployed/unshimmed
  rebuild proves the baseline didn't move.
- **OS/wall-clock primary; slope-not-absolute; correctness as a hard fail.**
- **Discard warm-up; randomize order; ≥2 measured runs;** between-run cleanup
  verified (no stray opencode/pigeon/mock procs).
- **Content-free fixtures** — shape + synthetic content only; zero source text or
  repo/company identifiers. Run `scrubbing-company-references` before any commit.

---

## Milestone M0 — Project skeleton + host preflight

### Task M0.1: Scaffold the Bun project
- Create `package.json` (`"type":"module"`), `tsconfig.json`, `.gitignore` (ignore `results/`).
- `src/cli.ts` stub: subcommands `preflight|build|aa|calibrate|run|report`.
- Verify `bun test` (0 tests, exit 0) + `bun src/cli.ts --help`. Commit `chore: scaffold serve-bench`.

### Task M0.2: Host-shape preflight (refuse wrong/dirty host)
- `src/host/preflight.ts` + `test/host/preflight.test.ts`.
- `evaluateHost({arch,cores,totalMemGB,others})`: reject non-arm64, reject when stray `opencode*/pigeon*/serve-bench-mock` processes present, accept clean cloudbox-shape ARM.
- TDD (reject x86, reject dirty, accept clean) → implement (wrapper reads `process.arch`, `os.cpus()`, `os.totalmem()`, `/proc` scan) → commit `feat(preflight): refuse non-cloudbox-shape/dirty hosts`.

---

## Milestone M1 — Metrics primitives (TDD core; OS metrics are PRIMARY)

### Task M1.1: `/proc` CPU parsers
- `src/proc/cpu.ts`: `parseStatCpu(line)`, `parsePidCpu(stat)`.
- TDD with fixture strings; **the `comm` field can contain spaces/parens → split on the LAST `)`** (regression-test this). Commit `feat(proc): cpu parsers`.

### Task M1.2: `/proc` memory parsers (RSS + PSS)
- `src/proc/mem.ts`: `parseVmRss(status)`, `parsePss(smapsRollup)` (sum `Pss:`). TDD with fixtures. Commit `feat(proc): rss+pss parsers`.

### Task M1.3: Percentile/histogram rollup
- `src/metrics/histogram.ts`: `percentiles(samples,[50,95,99])`, `summarize(series)`. TDD. Commit.

### Task M1.4: Sampling collector over a PID-set
- `src/metrics/collector.ts`: samples injected `/proc` reader at `dt`, computes CPU% via jiffy deltas, RSS/PSS, child count → series + summary. TDD with scripted snapshots. Commit `feat(metrics): pid-set collector`.

---

## Milestone M1b — Per-run environment isolation (NEW; reviewer #7)

### Task M1b.1: Isolated env sandbox
- `src/env/isolate.ts` + `test/env/isolate.test.ts`.
- `makeRunEnv(runDir)` returns an env map with **absolute** `OPENCODE_DB=<runDir>/opencode.db`, `OPENCODE_DISABLE_CHANNEL_DB=1`, `HOME=<runDir>/home`, `XDG_DATA_HOME=<runDir>/home/.local/share`, `XDG_CONFIG_HOME=<runDir>/home/.config`, and a pinned config path / `OPENCODE_CONFIG_CONTENT`.
- **Why:** opencode resolves a relative `OPENCODE_DB` under `Global.Path.data` (`storage/db.ts:38-43`) and writes non-DB storage under `Global.Path.data/storage` (`storage/storage.ts:228-231`). Pinning only `OPENCODE_DB` leaks config/storage/migrations/cache across variants.
- TDD: assert all paths absolute + under `runDir`, channel-DB disabled. Commit `feat(env): full per-run HOME/XDG/config isolation`.

---

## Milestone M2 — Variant builds + uniform instrumentation + A/A faithfulness

### Task M2.1: Exact ref/patch/asset registry (reviewer #4)
- `src/build/refs.ts` + test. Each variant → `{ ref, upstreamCommit, patchStack[], assetHash?, tag?, patches[] }`:
  - **V0** = the `opencode-patched` **release** the box runs: record source commit + upstream v1.17.7 commit + the **5-patch stack** (`users/dev/home.base.nix:237-239, 300-328`) + platform asset hash + release tag. Patches: `[shim]`.
  - **V1** = V0 ref + the V1 patch artifact (M3) + `[shim]`.
  - **V2-stock** = pinned newer-line commit (record exact SHA). Patches: `[shim]` only (NO fork patches).
  - **V2-ported** = newer ref + rebased fork stack + `[shim]` — placeholder, built later.
  - **V3** = V0 (or V1) used via `opencode run`; per-PID external sampling (no central serve route).
- Reject dirty/unpinned sources. Test asserts registry shape + that no two serve variants differ in shim. Commit `feat(build): exact variant ref/patch/asset registry`.

> **Re-verify hot paths on the DEPLOYED ref first** (design Critical #1): confirm
> the GlobalBus fan-out + `project copy refresh` paths exist at the pinned deployed
> v1.17.7 ref (absent on the newer line). Record exact file:line in `refs.ts`.

### Task M2.2: Uniform Tier-0 instrumentation shim (at a stable semantic layer)
- `src/build/patches/shim/` (ref-keyed) + `src/metrics/eventloop.ts` + test.
- Shim adds a **minimal raw route** `GET /__bench/metrics` (placed OUTSIDE instance/workspace/auth routing, same semantic layer in every variant) returning `{eventLoopDelay: p50/95/99 ms, rss, cpuUsage}` from `monitorEventLoopDelay({resolution:10})` started at boot.
- TDD the histogram→summary converter. Commit `feat(build): uniform event-loop shim (raw route)`.

### Task M2.3: `build-variant` + smoke gate
- `src/build/build-variant.ts`, `src/build/instrument.ts` + test.
- `buildVariant(id)` → checkout pinned ref, apply patch set, build, return binary path. Unit-test patch-application + arg assembly with injected git/build runner.
- **Smoke (operational):** V0 + V2-stock build, boot serve against an isolated env, `curl /__bench/metrics` → 200 + histogram; `curl /global/health` → healthy. Commit `feat(build): build-variant + shim smoke`.

### Task M2.4: A/A faithfulness checks (NEW; reviewer #4, #5)
- `src/build/aa.ts` + test.
- **Rebuild A/A:** deployed artifact (or unshimmed faithful rebuild) vs V0+shim on a tiny fixed workload → assert CPU/wall-clock/health-latency within tolerance (baseline unmoved by shim/rebuild).
- **Shim A/A:** shim-on vs shim-off on one variant + scrape-rate sensitivity (e.g. 1/2/5 Hz) → if event-loop delay or other metrics move beyond tolerance, mark event-loop delay **diagnostic-only** in the run manifest (the verdict engine then refuses to use it as a predicate).
- TDD the tolerance comparison + the "demote to diagnostic" flag emission. Commit `feat(build): A/A faithfulness + shim sensitivity gate`.

---

## Milestone M3 — V1 "small serve fixes" (DECOUPLED patch deliverable; reviewer #8)

> The matrix CONSUMES a built V1 artifact. These patches have their OWN acceptance
> tests so "patch loses" can't be confused with "bad patch." Authored against the
> exact deployed v1.17.7 ref with file:line paths. Bead `workstation-qjk4`.

### Task M3.1: Filter `/event` before SSE enqueue
- `build/patches/v1/01-filter-before-queue.patch`. Filter each event against the subscriber's interest set *before* enqueue (kill O(N×M) fan-out).
- **Acceptance test (own):** with M subscribers + an irrelevant event burst, per-subscriber wakeups/CPU stay flat vs subscriber count. Commit `feat(v1): filter events before SSE enqueue`.

### Task M3.2: Bounded / singleflight project-copy refresh
- `build/patches/v1/02-bounded-refresh.patch`. Coalesce concurrent refresh into one in-flight op + a bound (define backpressure semantics explicitly).
- **Acceptance test:** N concurrent reconnects trigger ≤1 in-flight refresh; queued callers get the coalesced result. Commit `feat(v1): singleflight+bounded refresh`.

### Task M3.3: `GlobalBus.setMaxListeners`
- `build/patches/v1/03-set-max-listeners.patch`. Explicit bound + rationale (document why N); removes the warning + its leak-mask.
- **Acceptance test:** no `MaxListenersExceededWarning` under target subscriber count; listener count bounded. Commit `feat(v1): set GlobalBus max listeners`.

---

## Milestone M4 — Calibrated SEMANTIC streaming mock (reviewer #3, #9)

### Task M4.1: Semantic (scrubbed) shape extraction + tool-materiality classification
- `src/mock/extract.ts` + `mock/profiles/{short,long-review}.json` + test.
- From `packages/http-recorder` captures / aigateway ledger, derive per turn the **full semantic envelope sequence**: role/content deltas, reasoning, tool-start (name), tool-args (JSON), finish, usage — with per-chunk byte length, inter-chunk delay, and event mix. **Scrub TEXT ONLY:** replace content with synthetic strings of equal byte length; replace tool names with synthetic valid identifiers and tool args with synthetic JSON of comparable size/depth/key-count.
- **Tool materiality classification (REQUIRED before any out-of-scope decision; reviewer round-2):** compute from the real selected trace the tool fraction — `tool_call` chunk share, tool-arg byte share, and tool-call-turn share. Decision fork:
  - **negligible** (below a stated threshold) → text/reason/usage-only profile is faithful; record `profileLimitations: { tools: "out_of_scope", reason: "negligible_in_trace" }`.
  - **material** → either (a) implement semantic-scrubbed tool args at fidelity, OR (b) record `profileLimitations: { tools: "out_of_scope", reason: "material_but_excluded" }` and mark the profile **streaming-only / invalid for a STOP_REPLACE conclusion** (never silently drop tools and still label it "long-review-ish").
  - **Never** ship low-fidelity tool args — honest omission beats fake fidelity (it prevents false confidence).
- TDD: emitted profile preserves chunk count/cadence/event-mix/JSON structure; contains zero source text/identifiers; the materiality classifier returns the right fork + `profileLimitations` flag for negligible vs material fixtures. ≥2 fixtures. Commit `feat(mock): semantic scrubbed fixtures + tool-materiality`.

### Task M4.2: Cadence-replay OpenAI-compatible mock + server-side timing
- `src/mock/provider.ts` + test. `node:http` SSE server (semantic chunk encoding adapted from `llm-server.ts`) replaying a profile; record **server-side send timestamps** per chunk.
- **Request matching:** the measured-prompt request gets the calibrated profile; **title/small-model requests** (`small:true`, the "Generate a title…" call in `session/prompt.ts:241-284`) get a deterministic tiny response. Expose a per-run provider-call counter.
- TDD: observed chunk count + server-side cadence match the profile (±tol); title request gets the tiny path; call counts assertable.
- **Wiring verification (operational):** custom opencode provider `baseURL`→mock; `opencode run -m <mock> "x" --format json` completes; confirm BOTH lines accept the config. Commit `feat(mock): cadence-replay provider + request matching`.

### Task M4.3: Calibration gate (NEW; reviewer #3)
- `src/mock/calibrate.ts` + test. On ONE serve variant, compare **real recorded-profile replay** vs **semantic-scrubbed replay** for: PID CPU, event-loop delay, wall-clock, emitted opencode event count, success-output rate. Pass only within stated tolerance.
- **Gate rule:** C-slopes are not trusted (verdict engine emits `WITHHOLD_INSTRUMENTATION_INVALID`) unless calibration passed. Note: cadence is validated from mock server-side timestamps, NOT `run --format json` (which emits only completed parts, `run.ts:688-690`). TDD the comparator + the WITHHOLD trigger. Commit `feat(mock): real-vs-scrubbed calibration gate`.

---

## Milestone M5 — Isolated DB snapshot + correctness gate

### Task M5.1: Pristine snapshot (backup API) + recreate
- `src/db/snapshot.ts` + test. `snapshot(srcDb)` via the **SQLite online backup API** (or a stopped/checkpointed source) → pristine copy; **integrity-check the pristine snapshot before use**; `recreate(pristine)` → fresh per-run copy (DB+`-wal`+`-shm`) under the isolated env. TDD against a temp SQLite. Commit `feat(db): backup-API snapshot + verified recreate`.

### Task M5.2: Correctness gate
- `src/correctness/gate.ts` + test. Returns `{ok, failures[]}`: `PRAGMA integrity_check`==ok; `PRAGMA foreign_key_check` empty; WAL-delta within bound + checkpoint succeeds; **live-but-rowless invariant** (every registered/started session has a durable row); zero `SQLITE_BUSY` surfaced; zero duplicate session owners (if V3 ownership prototype present).
- TDD: corrupted copy → FAIL; clean → PASS; a correctness failure overrides any perf verdict. Commit `feat(correctness): post-run integrity gate`.

---

## Milestone M6 — Load drivers (the three tests)

### Task M6.1: Test A — subscriber slope
- `src/load/test-a.ts` + test. Boot variant; active work fixed-small; N `/event` SSE subscribers ∈ {0,1,10,30,60}; fixed window; no reconnects; collect serve-PID CPU + event-loop delay (diagnostic) + host CPU. Unit-test subscriber bookkeeping + result assembly. Commit `feat(load): test A`.

### Task M6.2: Test B — reconnect/refresh slope
- `src/load/test-b.ts` + test. Active work ~0; N simultaneous reconnects ∈ {1,10,30,60} with a parameterized realistic worktree distribution; measure time-to-all-healthy, p99 health latency, RSS peak, (Tier-2 confirmatory) ProjectCopy/git-subprocess counters. Unit-test the all-healthy detector + distribution generator. Commit `feat(load): test B`.

### Task M6.3: Test C — active-work slope, PHASE-ACCOUNTED (reviewer #2)
- `src/load/test-c.ts` + test. Subscribers 0–1, no reconnect burst; active sessions N ∈ {1,5,15,30}, one representative turn each via the semantic mock.
  - **Serve variants:** drive N concurrent prompts against booted serve.
  - **V3:** spawn N `opencode run --dir <worktree> -m <mock>` processes (each boots an in-process server, `run.ts:869-878` — real startup cost).
  - **Equalize session setup across variants:** pre-create titled sessions consistently for all variants (or include equivalent create/title cost for serve too) so V3 startup isn't an unfair tax/credit.
  - **Phase accounting** (record per phase): spawn/import→session-ready; prompt-accepted→first-provider-request; first-byte→final-byte; final-byte→idle/exit.
  - **Two reported views:** (a) **one-shot lgtm cost** (incl. startup) and (b) **active streaming/work cost** (excl. startup). The replace-gate "useful work needs N cores?" question uses view (b); lgtm economics uses (a). Use the **long-review** profile / non-trivial cadence so startup can't dominate.
  - **Success-output rate:** exit 0 ≠ success — classify from error events / DB `info.error` (lgtm brief §6).
- Unit-test phase-timer bookkeeping + success classification + both-view assembly. Commit `feat(load): test C phase-accounted + V3`.

---

## Milestone M7 — Orchestrator + verdict engine

### Task M7.1: Matrix orchestrator — gate BEFORE recreate (reviewer #1)
- `src/orchestrator/matrix.ts` + test. Applicable (variant×test) set (A/B serve-only; C incl. V3), randomized order, ≥2 measured runs + 1 discarded warm-up.
- **Strict per-run sequence (unit-tested for order):** start runtime(s) → drive load → **stop process tree → run correctness gate on the MUTATED run DB + logs → archive DB/WAL/logs to `results/`** → recreate isolated env/DB for next run → assert no leftover opencode/pigeon/mock procs.
- **Step-1 failing test:** assert the call order; FAIL if the gate is invoked after recreate. Also test abort-on-correctness-failure + warm-up discard. Commit `feat(orchestrator): randomized runner, gate-before-recreate`.

### Task M7.2: Verdict engine — executable predicates + enums (reviewer #6)
- `src/report/decision.ts` + test. Define numeric **thresholds** (e.g. slope ratio V1/V0 ≤ X to count as "collapsed"; "C acceptable" = active-work CPU-slope < Y AND PSS within §14 budget AND DB-busy==0), **confidence/variance** rules (run-to-run agreement; overlapping CIs → withhold), and **ordered predicates** that resolve the §3 overlaps deterministically.
- **Emit an action ENUM** (no prose verdict):
  `STOP_REPLACE_PATCH_V1` · `STOP_REPLACE_UPGRADE_INVESTIGATION` ·
  `CONTINUE_REPLACE_DESIGN` · `FIX_DB_WRITE_PATH` · `WITHHOLD_RERUN`
  (variance/conflict) · `WITHHOLD_INSTRUMENTATION_INVALID` (A/A or calibration
  failed) · `WITHHOLD_CORRECTNESS_FAILURE` · `WITHHOLD_TOOL_PROFILE_REQUIRED`
  (round-2: a STOP_REPLACE would rest on a streaming-only "C acceptable" pass while
  the real trace is tool-heavy).
- **Tool-profile asymmetry (reviewer round-2):** read `profileLimitations.tools`
  from the run manifest. When tools are out-of-scope AND classified **material** in
  the real trace, Test C is a streaming-only **lower bound**:
  - `CONTINUE_REPLACE_DESIGN` MAY still fire (tools only add serve load — a
    streaming-only replace case holds a fortiori).
  - any `STOP_REPLACE_*` branch that relies on a "C acceptable" pass MUST instead
    emit `WITHHOLD_TOOL_PROFILE_REQUIRED`. (If tools were classified negligible, no
    constraint — streaming-only C is faithful.)
- **Ordered resolution** (first match wins): correctness fail → WITHHOLD_CORRECTNESS_FAILURE; instrumentation/calibration invalid → WITHHOLD_INSTRUMENTATION_INVALID; insufficient agreement → WITHHOLD_RERUN; C low-CPU + high DB-busy/WAL → FIX_DB_WRITE_PATH; A/B collapsed but C still single-loop-bound + V3 improves view-(b) wall-clock w/o correctness/PSS/DB-busy regression → CONTINUE_REPLACE_DESIGN; **[tool-asymmetry guard]** if the remaining STOP_REPLACE branches would rest on a "C acceptable" pass and tools are material-but-excluded → WITHHOLD_TOOL_PROFILE_REQUIRED; V2-stock collapses A/B + C acceptable → STOP_REPLACE_UPGRADE_INVESTIGATION; V1 collapses A/B + V2 blocked + C acceptable → STOP_REPLACE_PATCH_V1.
- **Step-1 failing tests:** synthetic datasets for EACH enum **plus conflict/ambiguous/variance cases** (V1 helps A not B; V2 fixes A/B but C PSS-regresses; V3 faster but PSS over budget; one run disagrees; CIs overlap) **plus the asymmetry pair** (material-tools-excluded + C-acceptable → WITHHOLD_TOOL_PROFILE_REQUIRED; same dataset but V3 wins view-(b) → CONTINUE_REPLACE_DESIGN still fires). Assert the emitted enum + cited evidence. TDD → implement → commit `feat(report): executable verdict engine + tool asymmetry`.

### Task M7.3: Report artifact
- `cli.ts report results/<run>` → Markdown: per-variant slope tables (OS-primary; event-loop delay marked diagnostic), phase-accounted Test-C views, the verdict enum + supporting evidence + any WITHHOLD reason. Verify on a synthetic dataset. Commit `feat(cli): report artifact`.

---

## Milestone M8 — Pre-flight memory characterization (READ-ONLY; reviewer #10)

> **Reaping removed from this plan.** Phase 0 only characterizes. Any reap is a
> SEPARATE guarded runbook/tool: dry-run-first, exact session IDs, explicit user
> confirmation, and cross-checks against ALL tmux sessions, pigeon registry +
> direct channels, process cwd/fds, DB last-activity, and benchmark run state.
> (Respects the user's "don't disrupt active sessions" constraint.)

### Task M8.1: Memory characterization (read-only)
- `src/ops/characterize.ts` + test. Inventory all `opencode` processes (serve/attach/run), classify by role, measure real **PSS** (M1 parsers), attribute shared vs private pages. Output a table: serve+N-attach vs N standalone `-s` vs N `run` → feeds the §14 memory hard-gate + concurrency caps. TDD classification + PSS rollup with fixtures; live scan is a verify step. Commit `feat(ops): read-only memory characterization`.

---

## Execution order & dependencies

```
M0 ─ M1 ─ M1b ─┬─ M4 ─ M4.3(calib) ─┐
               ├─ M5 ───────────────┼─ M6 ─ M7
               └─ M2 ─ M2.4(A/A) ───┘
M3 (decoupled patch; feeds V1 build) ─┘   M8 (independent, read-only)
```
- M1b (isolation) + M2/M2.4 (builds+A/A) + M5 (db/correctness) gate M6.
- M4.3 calibration must pass before any C-slope is trusted.
- De-risk the harness end-to-end on V0 before V1/V2 exist.
- The matrix run (M7.1) runs on the scratch ARM VM, ≥2 randomized runs.

## What "done" means for Phase 0

A committed `serve-bench` that, on a cloudbox-shape ARM host, produces a
reproducible **verdict enum** (with slope evidence, phase-accounted Test-C views, a
green correctness gate every run, clean A/A, and passed mock calibration) selecting
patch / upgrade / replace / fix-DB — or an explicit WITHHOLD — plus the read-only
memory characterization. That verdict unblocks `workstation-zao4`/`workstation-mn9r`
(only on CONTINUE_REPLACE_DESIGN), or routes to `workstation-qjk4` (patch) /
`workstation-rb77` (upgrade). lgtm-`run` (`workstation-7eiv`) proceeds in parallel
only if it independently pays.

## Process discipline (carry into execution)

- Replace must beat BOTH patch AND upgrade on measured slope data; box load 4–8/16
  leans fix/upgrade — do not assume replace.
- Re-verify hot paths on the **deployed** v1.17.7 ref before any V0/V1 claim.
- Public repo: `scrubbing-company-references` before every commit; fixtures carry
  shape + synthetic content only.
- Conservative on commits/pushes: the user controls commit/compact cadence.
