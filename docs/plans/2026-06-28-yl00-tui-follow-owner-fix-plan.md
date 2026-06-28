# yl00 fix plan: TUI event stream must follow the session's owning serve

Status: Root cause CONFIRMED + corrected (cloudbox, 2026-06-28). Fix NOT yet started.
Bead: workstation-yl00 (P1 bug, in_progress). Chosen approach: **option 1** (client-side,
TUI follows owner). Overlaps workstation-7zr7 (attach client /route + reconnect) and
serve-lease (the migration source).

Companion docs/memories (READ THESE FIRST):
- `docs/plans/2026-06-22-yl00-attach-live-delivery-rootcause.md` — the ORIGINAL (now-corrected)
  diagnosis. Its `/event` cold-start race fix (`event-cold-start-directory.patch`) is REAL but
  targets the WRONG endpoint; keep it (harmless) but it does not fix the TUI.
- bd memory `yl00-reframe-tui-uses-global-event-firehose`
- bd memory `yl00-confirmed-session-migration-smoking-gun`

## Confirmed root cause (one paragraph)

The opencode TUI subscribes to its live event stream via `sdk.global.event()` =>
**`GET /global/event`** (`packages/tui/src/context/sdk.tsx`), an UNFILTERED **per-process**
firehose off `GlobalBus` (4 serve processes = 4 independent buses; no cross-serve bridge,
`OPENCODE_EXPERIMENTAL_WORKSPACES` off). A session MIGRATES between serve processes mid-life
(serve-lease idle-migration / reshuffle). The TUI attaches to the `/route` owner *at attach
time* and pins its firehose there; the SSE connection does NOT drop on migration, and the
`attach-route-resolve` patch only re-resolves `/route` at the START of a new SSE attempt
(which only begins on a drop). So after migration the TUI is silently listening to the wrong
process and misses every subsequent turn until re-attach (which re-resolves `/route` + reloads
history from SQLite). Direct proof: Y=`ses_0f0b48747ffe` logged 112 turn-lines on `run=acb03c59`
(serve-0/4096) then 443 on `run=52b57ad4` (serve-1/4097) — migrated mid-session; its TUI,
attached to serve-0 at launch, missed all serve-1 turns. (run=->serve map via POST /session
per port + read the `created` run=.)

## The fix (option 1): active owner-drift detection -> reconnect

In `packages/tui/src/context/sdk.tsx` (already modified by `attach-route-resolve.patch`):
the `startSSE` loop uses `runSseAttempt`, whose `open(signal)` re-resolves `resolveServeUrl`
and rebuilds the client if the owner moved — but `open()` runs ONCE per attempt and the
`/global/event` attempt never ends (10s heartbeats keep it alive). Add a **lightweight `/route`
poller** that runs concurrently with the live attempt:

- Every N seconds (start ~5s; tune), call `resolveServeUrl({ sessionID, fallback: currentUrl, signal })`.
- If the result is a DIFFERENT url than `currentUrl` (a confirmed owner change to another
  healthy serve), abort the current attempt's signal so the loop re-runs `open()` ->
  rebuild client -> reopen `/global/event` on the NEW owner.
- Degrade hard: a `/route` failure/timeout/flap must NEVER trigger a reconnect (pigeon
  `/route` is observed-flaky/slow). Only reconnect on a confirmed, stable change. Consider
  requiring the same new owner twice in a row before acting.

Why not the cheaper alternatives:
- "Cap each SSE attempt at 30-60s then loop" forces a reconnect for EVERY TUI continuously
  -> reintroduces the y69t bootstrap/conn-storm risk. Reject.
- Server-side migration signal (old serve emits `session.moved`) needs a server patch and the
  old process must know the new owner — more moving parts. Keep option 1 client-only first.

Risk/edge cases:
- Brief race: a turn that starts on the new serve before the poller reconnects is missed live,
  but the reconnect reloads from DB so it still appears (just not token-streamed). Acceptable.
- Reconnect thrash if `/route` flaps -> the "confirm twice / only-on-change" guard above.
- Reconnect cost = a client bootstrap reload; keep it strictly on-change, not periodic.

## Implementation mechanics (opencode-patched)

- Repo: `~/projects/opencode-patched` (patches) applied to `~/projects/opencode` at tag
  `v1.17.7`. `OPENCODE_PATCHED` is ACTIVELY edited by other sessions — `git pull --rebase`
  before touching, add a NEW patch file (do NOT edit `attach-route-resolve.patch`), rebase
  before push, stage only your files.
- New patch e.g. `patches/tui-follow-owner.patch`; register in `patches/apply.sh` AFTER
  `attach-route-resolve.patch` (it builds on `resolveServeUrl`/`runSseAttempt`/`util/sse.ts`).
- Read the patched source first: `git -C ~/projects/opencode worktree add /tmp/oc-yl00 v1.17.7`,
  run `~/projects/opencode-patched/patches/apply.sh` against it, then read the resulting
  `packages/tui/src/context/sdk.tsx` + `packages/tui/src/util/route.ts` + `util/sse.ts`.
- TDD: factor the drift decision into a pure helper (given currentUrl + sequence of /route
  results -> reconnect? ) and unit-test it (mirror the route.test.ts pattern from
  attach-route-resolve.patch). bun may need >=1.3.14 for the suite.
- Build/deploy: `gh workflow run build-release.yml -f version=1.17.7 -f revision=9` (next rev),
  then bump `users/dev/home.base.nix` patchedRevision 8->9 + the 4 platform hashes,
  `home-manager switch .#cloudbox`, restart pooled serves (opencode-serve@4096..4099).
  CAUTION: cutting a release bundles the WHOLE apply.sh — coordinate rev numbering with any
  in-flight opencode-patched work (7zr7 etc.).

## Verification

- Repro a migration live: launch a session, note its serve (run=->serve), force/await a
  migration to another serve, and confirm a `/global/event` subscriber that started on the
  old serve STOPS getting turns (pre-fix) vs the patched TUI reconnecting to the new serve.
  (Per-process firehose mapping method is in the memories; run=->serve via POST /session per
  port + `created` run=.)
- Acceptance: pigeon-inject into a session that has migrated since attach; the turn appears
  live in the still-open TUI without manual re-attach.

## Out of scope / leave alone

- `event-cold-start-directory.patch` (/event) — keep, harmless, but irrelevant to the TUI.
- The opencode-launch bare-model fix (workstation-ov5s) is DONE/deployed (commit df1e823).
