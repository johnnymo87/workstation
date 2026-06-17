# Task: Switch lgtm from opencode-serve dispatch to process-per-session (`opencode run`)

You are working in `~/projects/lgtm` (TypeScript) on **cloudbox**. This is a
substantial change to a production PR-review system, so the shape is
**investigate → design → confirm → implement behind a flag → measure**, NOT a
blind rewrite. Do not break active reviews.

## Goal

Today lgtm dispatches reviews **headless through `opencode-serve`** (a single
long-lived Bun process on `:4096`): create a session, `prompt_async`, then poll
the serve HTTP API. Serve is single-threaded, so ~30 concurrent lgtm reviews pile
onto 1–2 cores of a 16-core box and balloon serve's RSS.

Switch lgtm to **process-per-session via `opencode run`**, so each review is its
own OS process the kernel spreads across cores, and **reaps itself by exiting**.

- New review → `opencode run -m <model> "<prompt>"` (creates a fresh session,
  runs to idle, exits).
- Re-review of an existing PR → `opencode run -s <SESSION_ID> "<prompt>"`
  (VERIFIED to exist: `packages/opencode/src/cli/cmd/run.ts:153-156`,
  `--session`/`-s` = "session id to continue"; default mode "exits when the
  session goes idle", `run.ts:4-5`).
- Context-gathering is already pure one-shot → also `opencode run` (new session).

lgtm is **its own orchestrator** (`src/dispatch.ts` decides when to review,
`src/watchdog.ts` checks health), so its sessions need **neither serve nor
pigeon** — `run`/`run -s` reconstitute from the shared `opencode.db` themselves.

## Step 1 — Map every place lgtm depends on serve (read-only first)

Trace and document each serve touchpoint and its replacement. Known surface
(verify + expand):

- `src/dispatch.ts` — how it launches today (does it shell `opencode-launch`, or
  call serve directly? what model/agent/tools does it pass?). This is the core
  swap to `opencode run`.
- `src/gather.ts` — context-gathering launch (`GATHER_MODEL_ID`). One-shot → `run`.
- `src/watchdog.ts` — `inspectSessionHealth` polls serve `GET /session/:id/message`.
  With `run`, health comes from the **process exit code + streamed output**, not a
  serve poll. Redesign health detection accordingly (and/or read messages straight
  from `opencode.db` since they're persisted).
- `killSession` (`src/dispatch.ts`) — today `DELETE`/abort via serve. With `run`,
  a finished review has already exited; "kill" becomes "signal the child process".
- `src/index.ts`, `scripts/smoke-test-prs.ts`, `tests/dispatch.test.ts` — update.

## Step 2 — Solve the three real design problems (call these out explicitly)

1. **Session-id capture.** `opencode run` (no `-s`) creates a *new* session; lgtm
   must learn that id to (a) record it in its state markers and (b) target later
   re-reviews with `-s`. Determine how: parse `--format json` event stream for the
   session id, vs. read it back, vs. pre-mint. Pick the robust one and prove it.
2. **Concurrency cap.** ~30 reviews as 30 simultaneous `opencode run` opus
   processes is its own thundering herd (CPU + RAM + provider rate limits). lgtm
   must bound concurrency (a worker pool / semaphore) and queue the rest. Choose a
   sane default, make it configurable, justify it against the box (16 cores,
   62 GB; each run ≈ a few hundred MB + model context).
3. **Health/lifecycle without serve.** Define done/failed/stuck from the process
   (exit code, timeout, empty-output detection — preserve the existing
   `inspectSessionHealth` failure classes: `info.error`, silent empty turn, etc.,
   but sourced from process result + DB messages instead of serve polling).

### Verified `opencode run` gaps (from design review — do NOT miss these)

4. **Working directory.** `opencode run` resolves its dir from **PWD unless
   `--dir`** (`packages/opencode/src/cli/cmd/run.ts:135`). lgtm runs from
   `/home/dev/projects/lgtm` under systemd, so without action a review/re-review
   would execute in the wrong directory. **Always spawn with `--dir <worktree>`
   (or cwd=worktree) on BOTH the fresh and `-s` paths.** Today's launch passes the
   PR worktree explicitly (`src/dispatch.ts:60-65`) — preserve that.
5. **No `--mcp` on `run`.** `opencode run`'s options end at `run.ts:241` and do
   **not** include `--mcp` (only `--agent`). Gather currently depends on
   `--mcp slack-ro` (`src/gather.ts:105-121`), which has no `run` equivalent.
   Resolve: evaluate `--agent` as the tool-scoping path for gather, OR keep gather
   on the old serve path behind the flag until parity exists. Do not silently drop
   Slack-read tools.
6. **Exit code 0 is NOT success.** `run` can exit 0 on a mid-stream LLM error
   (locked in by `test/cli/run/run-process.test.ts:44-57`). Classify failure from
   **error events in the `--format json` stream and/or DB `info.error`**, never
   from exit code alone — otherwise the watchdog misses failed reviews.

## Step 3 — Constraints & safety

- **Same opencode binary version everywhere.** `run` processes write the shared
  `opencode.db`; concurrent multi-process WAL is safe **only at one version**
  (the 2026-06-17 data loss was version-skew during a cutover, not steady-state
  multi-writer). Don't introduce a path that runs a different opencode build.
- **Behind a flag / config.** Roll out so you can A/B old-serve-dispatch vs
  new-run-dispatch and fall back instantly. Don't flip everything at once.
- **Don't disrupt in-flight reviews** during deploy.
- **Coexistence:** serve may still run for the user's dev sessions during the
  transition — that's fine (same DB, same version).

## Step 4 — Measure

Before/after, capture: per-review CPU spread across cores, peak RSS, wall-clock,
and whether reviews still complete + post to GitHub correctly. The whole point is
load-spreading + self-reaping; prove it.

## Deliverables

1. Step-1 dependency map (short doc or PR description section).
2. Phased implementation behind a flag, with tests (run lgtm's suite; cite the
   command). Preserve watchdog failure-classification behavior.
3. A beads issue for the work. Note for future context: this is the first
   concrete "convert a serve use-case to process-per-session" track in the larger
   move toward possibly removing opencode-serve entirely (see
   `~/projects/workstation/OPENCODE-SERVE-MULTICORE-INVESTIGATION.md` and the
   process-per-session discussion). Keep lgtm's conversion self-contained.

## References

- `opencode run` flags: `~/projects/opencode/packages/opencode/src/cli/cmd/run.ts`
  (`--session`/`-s` :153, `--continue`/`-c` :148, `--model`/`-m` :166,
  `--format`, `--fork`).
- Resource/architecture context:
  `~/projects/workstation/OPENCODE-SERVE-MULTICORE-INVESTIGATION.md`
- Multi-writer / version-skew lesson:
  `~/projects/workstation/docs/investigations/2026-06-17-opencode-1.17.7-orphan-session-wedge.md`

Work read-only through Steps 1–2, confirm the session-id-capture and health
approaches actually work with a throwaway `opencode run --format json` probe,
THEN implement behind a flag.
