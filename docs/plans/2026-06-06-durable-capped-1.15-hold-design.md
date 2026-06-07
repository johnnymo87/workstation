# Durable capped 1.15 + 1.16 hold — design

**Date:** 2026-06-06
**Status:** Approved (design); implementation pending
**Continues:** `docs/investigations/2026-06-05-vertex-gemini-surge/` (retry-cap cure)

## Problem

We deployed opencode **v1.16.x** but had to roll back to **v1.15.13** because of a
**database-corruption** problem in the 1.16 line (suspect: the SQLite store at
`~/.local/share/opencode/opencode.db`; the v1/v2 namespace + schema/migration
changes landed in v1.16.0). We want to **stay on the 1.15 workstream** — running
the capped retry-fix build — until upstream `anomalyco/opencode` fixes the
corruption.

### Current state (rollback is LIVE but ephemeral)

- Running now (interactive + `opencode-serve`, which execs `~/.nix-profile/bin/opencode`
  per `hosts/cloudbox/configuration.nix:566`): `opencode-patched-1.15.13.3`, store
  `wmf3lc23…`. This is a **local `--impure`** build (a `/home` tarball pin); it
  breaks pure eval and the store path can be GC'd.
- Rollback mechanism: home-manager **generation 384** re-points to gen 380's
  closure (the 1.15.13.3 build); `opencode-serve` restarted onto it. **No source edit.**
- Committed `users/dev/home.base.nix` still pins **`v1.16.2-patched.1`**
  (`upstreamVersion="1.16.2"`, `patchedRevision="1"`). Next `home-manager switch`
  rebuilds 1.16.
- `update-opencode-patched.yml` (every 8h) tracks `releases/latest`
  (= `v1.16.2-patched.1`) and **auto-merges** a PR bumping `home.base.nix` back to
  it — actively drags us to 1.16.
- No pure capped 1.15 release exists: newest published 1.15 is
  `v1.15.13-patched.2` (commit `c122c58`), which **predates** the retry-cap. The
  patches on `opencode-patched@main` are 1.16-flavored (the v1/v2 migration
  rewrote 6 patch files), so they won't apply to v1.15.13.

## Goal

1. Publish a **pure, reproducible** capped release `v1.15.13-patched.3`.
2. Pin it on **all hosts** (shared `home.base.nix`).
3. Make `opencode-patched@main` the parked **1.16 line**; make a durable
   **`release/v1.15`** branch the active **1.15 workstream**.
4. Make the auto-bump cron **hold-aware** so it stays on the 1.15 line and never
   advances to 1.16 while held.

## Decisions (locked with user)

| Decision | Choice |
|---|---|
| Durable pin | Publish pure `v1.15.13-patched.3` (not re-pin the `--impure` tarball) |
| Cron | Make it pin-aware via a hold/ceiling marker |
| Scope | All hosts (shared `home.base.nix`) |
| Workstream | 1.15 is the active line; `main` (1.16) parked until upstream DB fix |
| Revision number | `.3` (pure incarnation of the same capped content) |
| Hold logic | Generic marker (`opencodePatchedHold`), not hardcoded |

## Design

### A. opencode-patched — durable 1.15 workstream + capped release

1. Cut a **durable** branch `release/v1.15` off `c122c58` (= `v1.15.13-patched.2`
   stack: proven 1.15.13 patch set, `apply.sh` targets v1.15.13, no caching.patch).
   This becomes the active 1.15 workstream; `main` stays the parked 1.16 line.
2. **Re-derive `retry-cap.patch` against v1.15.13** `retry.ts`. The cap logic is
   identical to `main`'s but the namespace differs:
   - v1.15.13 uses `MessageV2.APIError` (line 184: `if (!retry) return Cause.done(meta.attempt)`).
   - v1.16.2 uses `SessionV1.APIError` (imports `@opencode-ai/core/v1/session`).
   Add `MAX_RETRIES = 8`, `RETRY_JITTER_RATIO`, a `jitter()` helper, wrap the
   no-headers delay in `jitter(...)`, and change the guard to
   `if (!retry || meta.attempt > MAX_RETRIES) return Cause.done(meta.attempt)`.
   Port the matching `test/session/retry.test.ts` hunk (namespace-adjusted). Add a
   retry-cap block to that branch's `apply.sh`.
3. **Local sanity check** against `~/projects/opencode` @ `v1.15.13`: `apply.sh`
   applies clean; `bun install`; `bun run script/build.ts`; `bun test` retry test green.
4. **Build:** `gh workflow run build-release.yml --ref release/v1.15 -f version=1.15.13 -f revision=3`
   → `v1.15.13-patched.3` (4 platform assets). Do **not** flip GitHub "latest"
   (1.16.2.1 stays latest; the hold marker drives tracking).
5. **Verify** the linux-x64 asset: cap markers present (`RETRY_JITTER_RATIO`,
   `MAX_RETRIES`), `--version` 1.15.13.

### B. workstation — pin, hold the cron, deploy, document

6. **Pin** `users/dev/home.base.nix`: `upstreamVersion="1.15.13"`,
   `patchedRevision="3"`, replace the 4 platform `hash`es with the new release's
   SRI hashes (`nix-prefetch-url` + `nix hash convert --to sri`). Refresh the
   rationale comment (durable pure cure on 1.15.13-patched.3; rollback note;
   the 1.16 hold + reason).
7. **Hold marker:** add `opencodePatchedHold = "1.15.13";` near the version vars
   (`""` = track `releases/latest`, today's behavior).
8. **Make `update-opencode-patched.yml` hold-aware:** in "Check for new release",
   if `opencodePatchedHold` is non-empty, set the effective target to the highest
   `v<hold>-patched.N` release (via `gh api releases` list + filter + max-rev)
   instead of `releases/latest`; refuse to bump to a different upstreamVersion
   while held. Empty → unchanged. Hashes/PR steps flow from the chosen tag.
9. **Deploy (cloudbox now):** pure `home-manager switch` (must succeed with **no
   `--impure`**), then `sudo systemctl restart opencode-serve`. devbox/macOS adopt
   on their next switch (one shared pin).
10. **Docs:** supersede the stale `HANDOFF.md` "INCIDENT CLOSED on 1.16.2.1" with
    "held on capped `v1.15.13-patched.3`; 1.16 deferred pending upstream DB-corruption
    fix (research session `ses_15fe27082ffe8lANCIdYmfi7TT`)". Record the lift-hold
    procedure.

## Verification (evidence before "done")

- **opencode-patched:** clean apply on v1.15.13; retry test green; CI 4-platform
  build OK; cap markers in the published asset.
- **workstation:** pure `home-manager build` OK (no `--impure`); after switch,
  `opencode --version` = 1.15.13, store path = the new **pure** release path (not
  `wmf3lc23…`), cap markers in `/proc/$(systemctl show opencode-serve -p MainPID --value)/exe`.
- **cron:** dispatch the workflow once with the hold set → it selects
  `v1.15.13-patched.3` and opens **no** bump PR.

## Lift-hold (return to 1.16, later)

When upstream ships the DB-corruption fix (tracked by research session
`ses_15fe27082ffe8lANCIdYmfi7TT`): refresh `main` onto that 1.16.x, cut a capped
release, set `opencodePatchedHold = ""`, bump + `home-manager switch`. The cron
resumes tracking `releases/latest` automatically once the hold is cleared.

## Notes / trade-offs

- Version label `1.15.13.3` matches the old `--impure` build, but the **store path
  differs** (pure GitHub `fetchurl`). No tag collision — `v1.15.13-patched.3`
  doesn't exist yet (tags only go to `.2`).
- `c122c58` + retry-cap is complete: retry-cap is the only *new* patch between it
  and `main`; the rest were merely re-fitted to the 1.16 base. `eager-input-streaming.patch`
  (dropped on `main` for 1.16) remains valid on the 1.15 line.
