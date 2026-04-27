# Plan 2 Task 3 — Handoff: build/install/verify NOT performed

**Date:** 2026-04-27
**Author:** Claude (post-compaction execution session)
**Status:** ✅ RESOLVED 2026-04-27 22:35Z. Prefill fix shipped on opencode-patched v1.14.28-patched, deployed to cloudbox via home-manager, and verified in production. See "RESOLVED" section directly below.

---

## RESOLVED 2026-04-27 22:35Z

The deferred build/install/verify chain (`.plans/2026-04-27-v1.14.28-stack-refresh.md`) ran end-to-end in the second execution session. Both forks now ship v1.14.28 binaries that include the prefill fix.

**Shipped artifacts:**
- `johnnymo87/opencode-cached@312013e` — caching patch refresh for v1.14.28 (3-way merge handled all 8 file targets cleanly; only minor inline conflicts in `agent.ts` import + `transform.ts` import path).
- `johnnymo87/opencode-cached` release `v1.14.28-cached` (assets used: caching.patch served from raw `main` per `opencode-patched/patches/apply.sh:25`, NOT from release assets — plan was wrong about this; release binaries are unused but published anyway).
- `johnnymo87/opencode-patched@c4f4027` — prefill-fix patch refreshed for v1.14.28 (done in prior execution session).
- `johnnymo87/opencode-patched` release [`v1.14.28-patched`](https://github.com/johnnymo87/opencode-patched/releases/tag/v1.14.28-patched) — release body edited inline to include 6th-patch (Prefill Race Fix) section + reference to design doc. Followup item: update `build-release.yml` template lines 209-215 so future v1.14.28+ rebuilds default to advertising 6 patches (currently still says 5).
- `johnnymo87/workstation` PR #141 → squash-merged as `383fcc3` "chore(deps): update opencode-patched to 1.14.28". Auto-update workflow keyed on the version-string change and bumped 4 platform hashes + the version literal in `users/dev/home.base.nix`.
- Cloudbox `opencode --version` = `1.14.28` post `nix run home-manager -- switch --flake .#cloudbox`.

**Production verification (prefill repro):**

| Metric | Before (v1.14.25 unpatched) | After (v1.14.28 + prefill-fix) |
|---|---|---|
| User rows | 4 | 4 |
| Assistant rows | 8 | 1 |
| Distinct cwds in assistants | 4 | 1 (matches session.directory) |
| Prefill 400 errors | 4 | 0 |
| Wrong-cwd assistants | 7 | 0 |

Captures at `/tmp/repro-before-fix.txt` and `/tmp/repro-after-fix.txt`. Serve log shows exactly ONE `creating instance directory=/tmp/repro-prefill` event and ONE `session.prompt step=0 / step=1 / exiting` cycle for the test session, confirming `withSessionInstance` collapsed all 4 racing requests into the same Instance and the busy guard held.

**One observation worth recording:** the original Plan 2 spec (lines 105-119) predicted "4 assistants per user, all in same cwd" as the success state. Reality is "1 assistant per user when 4 prompts race within the same session window" — because `prompt_async`'s busy guard rejects concurrent prompts rather than queueing them, which is the documented `prompt_async` semantic. The fix's CRITICAL invariants (zero prefill errors, single Instance, no DB corruption, fire-and-forget 204 preserved) all hold.

**Candidate follow-up (NOT shipping today, raised by user during execution):** consider whether `prompt_async` should QUEUE rather than DROP concurrent prompts. The current drop-on-busy behavior is fine for normal TUI usage (a user can't physically race themselves) but silently loses the 2nd/3rd/4th prompt if a programmatic caller batches multiple prompts to the same session within milliseconds. Implementation would belong in `SessionPrompt.Service.prompt(...)` (NOT the route layer or `withSessionInstance`), as a per-Instance FIFO drained by a worker as the runner slot frees. Open design questions: FIFO cap size, whether command/abort/init share the queue, how queued state surfaces to the caller (who already accepted 204). File as a follow-up issue if a real workflow needs it; the alternative is a separate synchronous `/prompt` route that 503s on busy and lets the caller retry.

**Ops findings during execution:**
- Disk filled to 100% mid-Task-1 because of accumulated lgtm `pr-N` worktrees. Implementer autonomously loaded `cleaning-disk` skill, recovered 51GB. Wrote (uncommitted, surfaced separately to user) an enhancement to `users/dev/disk-cleanup.nix` that auto-prunes lgtm `pr-N` worktrees whose corresponding GitHub PR is MERGED or CLOSED. The implementer left this as `stash@{0}` for user decision: ship as a separate commit, file as a follow-up issue, or discard.
- The plan's Task 3 assumption "caching.patch ships as a release asset on opencode-cached" is wrong — `opencode-patched/patches/apply.sh:25` fetches from `https://raw.githubusercontent.com/johnnymo87/opencode-cached/main/patches/caching.patch`, so what matters is `opencode-cached/main` HEAD, which we confirmed via `git ls-remote`.
- The killed serve auto-respawned: when Task 7 needed a fresh binary, killing the existing `opencode serve --port 4096` PID caused the TUI to silently relaunch a new serve on the same port using the now-current `~/.nix-profile/bin/opencode` (which had been swapped to v1.14.28 by home-manager). The session never lost its connection. Useful to know for future binary swaps.

---

## UPDATE 2026-04-27 (later same evening)

User chose Option C-NOW (target upstream v1.14.28, which had landed in the
hours since the original handoff was written). After investigation, the
caching patch in `johnnymo87/opencode-cached` was found to need substantial
refactoring against v1.14.28 (3 of 8 files have non-trivial drift; one is a
major upstream refactor of `agent.ts` from the `zod(...).transform(...)`
pattern to `Schema.decodeTo(...)` / `SchemaGetter.transform` patterns).

Decision: **SPLIT execution.**
- **Done now (this session):** refresh `prefill-fix.patch` to apply against
  v1.14.28 (single-line drift; one import path renamed from
  `@opencode-ai/shared/util/error` to `@opencode-ai/core/util/error`).
  Pushed as commit
  [`c4f402754b06c6b95e9c0a662667a62956a8d9ae`](https://github.com/johnnymo87/opencode-patched/commit/c4f4027)
  on opencode-patched. Verified by sequential dry-run application of the
  full opencode-patched stack (vim + tool-fix + mcp-reconnect +
  eager-input-streaming + prefill-fix) against a fresh v1.14.28 clone.
- **Deferred to a future session:** the caching-patch refresh on
  `opencode-cached`, the build dispatches on both forks, the workstation
  hash bump, the home-manager apply, and the post-fix prefill-repro
  verification. Captured in detail at
  `.plans/2026-04-27-v1.14.28-stack-refresh.md` (full plan with bite-sized
  tasks, written for an agent with zero prior context).

State summary right now:
- `opencode-patched@main` HEAD = `c4f4027` (prefill-fix patch refreshed for
  v1.14.28).
- `opencode-cached@main` HEAD = unchanged from this morning. Still ships
  `v1.14.25-cached`. Two failed `workflow_dispatch` runs in the morning
  confirmed `caching.patch` won't apply to v1.14.28 without a manual port.
- No new release has been cut on either fork.
- `users/dev/home.base.nix` still pins opencode v1.14.25 (the existing
  `v1.14.25-patched` release, NOT including the prefill fix).
- The prefill bug is still reproducible against the running binary.

To resume from here, follow `.plans/2026-04-27-v1.14.28-stack-refresh.md`
starting at Task 1 (caching patch refresh on opencode-cached). Tasks 2-7 of
that plan run unchanged from the SPLIT outcome.

The original handoff (below) is preserved verbatim for historical context
about why we ended up at this decision tree.

---

## Original handoff (2026-04-27, earlier in the same session)

## What's done

- `prefill-fix.patch` (489 lines, wraps 24 `/:sessionID/...` routes in opencode v1.14.25) is committed and pushed to `johnnymo87/opencode-patched` as commit
  [`0184e1e2adb8b255010d853de2d91e66da8a023a`](https://github.com/johnnymo87/opencode-patched/commit/0184e1e).
- `patches/apply.sh` updated to apply the new patch as the 6th in the stack.
- Smoke-tested by code reviewer: `apply.sh` against a fresh `v1.14.25`
  clone exits 0 with `✓ Prefill fix patch applied`.

## What's NOT done — and why I stopped

`build-release.yml` is `workflow_dispatch` only — the push of `0184e1e` did NOT
auto-trigger a build. To produce a binary that includes the prefill fix, you
need to dispatch the workflow:

```bash
gh -R johnnymo87/opencode-patched workflow run build-release.yml \
  --field version=1.14.25
```

But there are three real problems with doing this autonomously:

### Problem 1: Tag conflict

`v1.14.25-patched` already exists (released 2026-04-26 as the 5-patch
build). `softprops/action-gh-release@v2` defaults to **overwriting** the
existing release. That works mechanically, but:

- The release body still advertises 5 patches; the prefill fix would be
  silently bundled but undocumented.
- Lines 209–215 of `build-release.yml` need updating to mention the 6th
  patch before any new release should be cut.

### Problem 2: Workstation auto-update misses the bump

`.github/workflows/update-opencode-patched.yml:32-46` keys on the
`version` string parsed out of `home.base.nix` and compares it to the
latest GitHub release tag (stripping `-patched`). If we re-publish
`v1.14.25-patched` with new asset hashes, the workflow's check sees
`current=1.14.25` and `latest=1.14.25` → declares "up to date" → never
opens a PR. The new asset hashes would never land in `home.base.nix`
unless someone updates them by hand.

### Problem 3: User policy decision needed

Three reasonable paths:
- **A.** Re-dispatch with `version=1.14.25`, accept release overwrite,
  manually update workstation `home.base.nix` (auto-update will not
  fire).
- **B.** Change `build-release.yml` to use a sub-tag scheme like
  `v1.14.25-patched.2` for re-releases, AND adjust the workstation
  auto-update workflow to recognize the new pattern. More invasive.
- **C.** Wait for upstream `v1.14.26` to drop, then dispatch with the
  new version. Auto-update flow works cleanly. But may sit unfixed
  for days/weeks depending on upstream cadence.

The original Plan 2 (lines 374–453) assumed the build/install path
would just work after push. It didn't account for any of these. The
resumption prompt explicitly told me to stop here rather than expand
scope, so this is where I'm stopping.

## To resume

After deciding on A / B / C above:

1. (If A or B) Update `build-release.yml`'s release body to mention
   the 6th patch (prefill fix) and link to the workstation design
   doc.
2. Dispatch the workflow with the chosen version arg.
3. Verify the build succeeds and the new release publishes:
   ```bash
   gh -R johnnymo87/opencode-patched run watch
   gh -R johnnymo87/opencode-patched release view --json tagName,publishedAt
   ```
4. Update `users/dev/home.base.nix` hashes (manually for A, via
   adjusted auto-update for B, via existing auto-update for C).
5. Run `nix run home-manager -- switch --flake .#cloudbox`.
6. Restart `opencode serve` (find pid via `pgrep -fa "opencode serve"`,
   kill, let it respawn — or whatever the systemd unit expects).
7. Re-run the prefill repro from
   `.plans/2026-04-27-task2-prefill-fix.md` lines 56-79. Verify zero
   prefill errors and a single cwd in all assistant rows.

## Files to read

- `.plans/2026-04-27-task2-prefill-fix.md` — original Plan 2.
- `docs/plans/2026-04-21-opencode-prefill-fix-design.md` — full design
  rationale.
- `/tmp/repro-before-fix.txt` — captured repro output proving the bug
  reproduces against the current (unpatched) `v1.14.25` binary.
