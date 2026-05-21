# opencode-patched hash-drift detection — design

**Date:** 2026-05-18
**bd issue:** workstation-djx
**Status:** approved, ready for implementation

## Problem

`.github/workflows/update-opencode-patched.yml` only opens a PR when the
upstream `johnnymo87/opencode-patched` release version changes. It compares
`current` (parsed from `users/dev/home.base.nix`) against `latest` (from the
GitHub API), and short-circuits with `up_to_date=true` when they match.

This misses the case where upstream re-uploads release assets in place under
the same tag — which actually happened on 2026-05-18:

- `v1.15.0-patched` was published 2026-05-15.
- All four platform artifacts (`opencode-{linux,darwin}-{arm64,x64}.{tar.gz,zip}`)
  were re-uploaded on 2026-05-18T01:19:30Z, changing every hash.
- Scheduled workflow runs after that point reported `success` but did nothing
  because `current == latest == 1.15.0`.
- `darwin-rebuild` started failing with:

  ```
  hash mismatch in fixed-output derivation 'opencode-darwin-arm64.zip.drv':
    specified: sha256-zmtt6OYklkOw2btRIYhGl3cQjcq2UXwdaHIM4OzOET0=
    got:       sha256-pZsQzRcPXQdRjziwp+DrUuAtolRnLIMCEx1s+MkeoYY=
  ```

The hashes were refreshed manually in commit `8b13676`. This design fixes the
workflow so the next in-place re-upload self-heals.

## Goal

The scheduled workflow must open a PR when **either** the version changes
**or** any of the four platform artifact hashes drift, even if the version
string is unchanged.

## Non-goals

- Detecting drift faster than the existing 8-hour cadence (the trigger
  frequency stays the same).
- Generalizing this fix to `update-bb.yml` or `update-gws.yml`. Those upstream
  projects don't re-upload artifacts under the same tag; only opencode-patched
  has this failure mode. If they ever start, port this fix individually.
- Smarter pre-checks (using `checksums.sha256` or per-asset `updated_at`
  timestamps from the GitHub API). They'd save ~170 MB of downloads per run
  but add state. Not worth the complexity on a GitHub-hosted runner.

## Approach

Drop the `up_to_date` short-circuit entirely. On every scheduled run:

1. Read current version from `users/dev/home.base.nix`.
2. Read latest version from the upstream GitHub API.
3. **Unconditionally** prefetch all four platform assets via
   `nix-prefetch-url` and compute their SRI hashes.
4. **Unconditionally** sed the version and all four hashes into
   `users/dev/home.base.nix`.
5. Check `git diff --quiet users/dev/home.base.nix`:
   - Clean → log "no drift" and exit success.
   - Dirty → run the existing PR-creation block (branch, force-push, PR,
     auto-merge).

The PR title and commit message stay `chore(deps): update opencode-patched
to ${version}` whether the change is a version bump or a hash refresh — the
PR diff itself shows which it was.

The branch stays `auto/update-opencode-patched` and continues to be
force-pushed. An open PR will reshape under itself if a hash-drift PR
gets superseded by a version-bump PR before merge; that's fine.

## Workflow changes

In `.github/workflows/update-opencode-patched.yml`:

- **`Check for new release` step:** drop the `up_to_date` output. Keep the
  current/latest comparison purely for log readability (`echo "Version
  unchanged; checking hashes…"` vs `echo "Version bump: $current ->
  $latest"`).
- **`Compute hashes` step:** drop the `if: steps.check.outputs.up_to_date ==
  'false'` guard. Always run.
- **`Update home.base.nix` step:** drop the same guard. Always run.
- **`Create PR` step:** drop the same guard. At the top of the step, gate on
  `git diff --quiet users/dev/home.base.nix` and exit 0 with a log message if
  there's no drift.

No other changes. The sed patterns, branch name, PR title, and merge logic
all stay the same.

## Cost

- ~170 MB of asset downloads per scheduled run (3× daily) on the GH-hosted
  runner. Effectively free for GitHub-hosted runners and negligible against
  upstream's bandwidth (the assets are served from GitHub's CDN).
- No new state files, no new repo-tracked metadata.

## Risks

- If the sed patterns regress (e.g. a future home.base.nix refactor renames
  the asset filenames), the diff check will keep finding drift on every run
  and we'll get repeated no-op PRs. Same risk exists today on version bumps;
  acceptable.
- If upstream re-uploads assets and `nix-prefetch-url` happens to race a
  partially-uploaded artifact, we'd briefly PR a wrong hash. Vanishingly
  unlikely; the upstream workflow publishes all artifacts atomically per
  release.

## Verification

After merging:

1. `actionlint` (or `yq eval` for basic YAML validity) on the changed
   workflow file before pushing.
2. `gh workflow run update-opencode-patched.yml` once, then `gh run watch`.
3. Expected outcome: workflow succeeds with "no drift" log and creates no
   PR (because hashes were manually refreshed in `8b13676`).
4. Close `workstation-djx` with a reference to the merged PR.

## Out-of-scope follow-ups

- If we ever want sub-8h detection latency, we could add a `repository_dispatch`
  trigger fired by an upstream-side webhook. Not worth doing speculatively.
- The other update-* workflows could grow the same diff-gating pattern for
  symmetry. Defer until one of them actually exhibits this failure mode.
