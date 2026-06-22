# `opencode attach` pool-aware self-resolve + reconnect (Approach C) — design

**Date:** 2026-06-22
**Bead:** workstation-7zr7 (mn9r M7)
**Status:** approved, implementing
**Predecessor:** `2026-06-21-oc-auto-attach-pool-route-design.md` (b4n5 launcher slice, Approach A)

## Problem

The K-serve pool (ports 4096+, sharing one `opencode.db`) places each session on
one serve via pigeon's HRW rendezvous router. opencode's streaming event bus is
in-memory **per process**, so a TUI's `/event` SSE stream only sees a session's
turns if it is attached to the serve that actually runs the session.

The b4n5 slice fixed this at *launch* time for `oc-auto-attach` only. Two gaps
remain (this bead):

1. **Hand-typed `opencode attach <url>` is not pool-aware** — the user must know
   the owning serve's URL.
2. **A TUI does not follow a session that migrates serves after attach.** HRW is
   deterministic in a healthy pool, but a pool health change / idle-migration
   reshuffle moves the session and the attached TUI is left on the old serve.

## Root cause (verified in upstream v1.17.7)

`packages/tui/src/context/sdk.tsx` `startSSE()` reconnect loop:

- Always reconnects to the fixed `props.url` — it cannot follow a migration.
- Only retries on a **graceful** stream-end. A thrown connection error
  (`packages/sdk/js/src/v2/gen/core/serverSentEvents.gen.ts:131`
  `throw new Error("SSE failed: <status>")` on any non-2xx — 409/410/421/503 —
  and `fetch` throwing on connection-refused) escapes the `while` loop and is
  swallowed by the IIFE's trailing `.catch(() => {})`, **permanently killing
  SSE** with no reconnect.

## Approach (C)

Patch `opencode attach` + the TUI SSE client so the TUI (a) self-resolves the
owning serve from a session id via pigeon `GET /route`, and (b) re-resolves +
reconnects whenever the SSE stream drops or errors — the mechanism by which it
follows idle-migration / pool-health reshuffle.

This is the deferred "Approach C" from the b4n5 design: a new
`~/projects/opencode-patched` patch (binary rebuild + upgrade maintenance),
kept minimal and rebase-friendly.

### Architecture facts (from pigeon `routing/README.md`)

`GET /route?session_id=<sid>` (pigeon at `PIGEON_DAEMON_URL`, default
`http://127.0.0.1:4731`) returns
`{ sessionId, serveId, instanceUuid, ownerGeneration, apiBase,
eventUrl: "<apiBase>/event?session_ids=<sid>", expiresAt }`, or `503`+`Retry-After`
when no healthy serve, `400` on bad id. Rediscover triggers
(`2026-06-19-pool-replace-design.md:172`): SSE disconnect; 409/410/421/503;
connection refused; instance/generation mismatch; TTL expiry. We treat **any
SSE drop/error** as a rediscover trigger (covers all of the above without
inspecting status codes).

We keep using `sdk.global.event()` (`/global/event`); we do **not** switch to the
per-session `/event?session_ids=` stream — that filtering is the x8wi/yl00
optimization. Correctness only needs the TUI attached to the owning serve.

## Scope boundary vs the concurrent yl00 session

7zr7 (this) = the attach **client**: `/route` self-resolve + reconnect.
yl00 = **serve-side** event emission/fan-out (`server/.../handlers/event.ts`).
No file overlap. All 7zr7 edits are client-side
(`packages/opencode/src/cli/cmd/attach.ts`, `packages/tui/src/...`).

## Implementation — new patch `attach-route-resolve.patch`

Target upstream **v1.17.7**; cut **`v1.17.7-patched.2`** (current pin `.1` ==
opencode-patched main HEAD `d8019e6`; hold `1.17.7`). Registered as patch #10 in
`patches/apply.sh` (touches files no other patch touches → order unconstrained).

1. **NEW `packages/tui/src/util/route.ts`** — degrade-never-worse resolver,
   mirroring the bash `parse_serve_url` in `pkgs/oc-auto-attach/default.nix`:
   - `parseServeUrl(body, fallback)` — pure: parse JSON, return a non-empty
     string `apiBase`, else `fallback`. Never throws.
   - `resolveServeUrl({ sessionID, fallback, fetch?, signal? })` — reads
     `PIGEON_DAEMON_URL` (default `:4731`), `GET /route?session_id=<sid>` with a
     ~3s `AbortSignal.timeout`, delegates to `parseServeUrl`. Any failure → `fallback`.
     Never throws.

2. **`packages/opencode/src/cli/cmd/attach.ts`** — `command: "attach <url>"` →
   `"attach [url]"` (optional positional). Resolution chain when `--session` is set:
   `resolveServeUrl({ sessionID, fallback: args.url })`. Effective url =
   `resolved ?? args.url`. If still undefined → **hard error** (no silent `:4096`
   / `OPENCODE_URL` default — a pre-pool default is exactly the staleness bug).
   Use the resolved url for `validateSession` + `run({ url })`; `sessionID` already
   flows via `args`.

3. **`packages/tui/src/app.tsx`** — pass `sessionID={input.args.sessionID}` into
   `<SDKProvider>`.

4. **`packages/tui/src/context/sdk.tsx`** — add optional `sessionID?: string`
   prop; replace the fixed `props.url` capture with a mutable `currentUrl`
   (init `props.url`); `createSDK()` uses `currentUrl`. In `startSSE()`:
   - Wrap the `sdk.global.event()` connect **and** the `for await` consume in a
     `try/catch` inside the `while` loop, so non-2xx / connection-refused
     continue the backoff loop instead of escaping and killing SSE.
   - Before each (re)connect, when `sessionID` is set,
     `currentUrl = await resolveServeUrl({ sessionID, fallback: currentUrl })`;
     if it changed, **rebuild the whole `sdk`** (`sdk = createSDK()`) so REST /
     control submits follow the migration too (a non-owner serve can reject the
     prompt under serve-lease enforcement). Keep the existing exponential backoff.
   - `url` getter returns `currentUrl`.

## Testing (TDD)

- **Unit (bun test) `packages/tui/test/.../route.test.ts`** for `parseServeUrl`,
  mirroring the bash mirror's cases: valid JSON → apiBase; empty body → fallback;
  non-JSON garbage → fallback; JSON without apiBase → fallback; `apiBase: null` →
  fallback; `apiBase: ""` → fallback. Red→green before implementing.
- `bun --cwd packages/opencode typecheck` clean on the fully-patched tree.
- `apply.sh` applies cleanly on a fresh v1.17.7 worktree (full stack).
- Live smoke on cloudbox after deploy: attach `-s ses_X` with no url, confirm it
  resolves; kill/restart the owning serve and confirm the TUI re-resolves +
  reconnects.

## Release / pin

1. Commit the patch + `apply.sh` to opencode-patched (rebase before push).
2. Dispatch `build-release.yml -f version=1.17.7 -f revision=2`.
3. Update `workstation/users/dev/home.base.nix`: `patchedRevision = "2"` + the 4
   `opencode-platforms.*.hash` values (own platform via `nix build`; others via
   `nix store prefetch-file` of the release assets).
4. Rebuild cloudbox (home + system). Binary swap must stop all opencode procs
   from a plain shell (multi-writer on the shared db).

## Deferred (separate beads)

- Genuine upstream bump (1.17.8+): the mirror only has upstream ≤ v1.17.7, and the
  `v1.17.8/9-patched` tags point at 1.17.7-line commits. A real bump = rebase all
  9 patches incl. the 74KB `serve-lease` — not low-risk, collides with yl00. File
  separately.
- Switching the TUI to the per-session `/event?session_ids=` stream (x8wi/yl00).
