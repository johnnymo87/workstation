# opencode-patched Repository Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a new `opencode-patched` GitHub repo that combines caching (from opencode-cached) and vim keybindings (from PR #12679) into a single binary, then update workstation to consume it.

**Architecture:** A patch-combiner repo modeled on opencode-cached. CI fetches `caching.patch` from opencode-cached at build time (never duplicated), stores `vim.patch` locally (curated from PR #12679). Tails opencode-cached releases every 8h offset +1h. Workstation's existing update workflow is cloned to point at the new repo.

**Signal model:** Three distinct signal classes exist in this pipeline:
- **Drift** (`patch-drift` label in opencode-patched): the upstream PR diff has changed relative to the committed patch. This is a *producer review signal* — it prompts a human to inspect and regenerate the patch. It does NOT automatically block workstation.
- **Build failure** (build-release failure issue in opencode-patched): patches failed to apply or the build broke. Until a new release is published, workstation cannot update. This IS a release-availability blocker.
- **Release availability** (new `v{VERSION}-patched` tag published): the only signal workstation tracks. The `update-opencode-patched.yml` workflow polls for new published releases and opens a PR when one appears.

**Tech Stack:** GitHub Actions, Bun (build), Nix (consumption in workstation), shell scripts

---

### Task 1: Initialize repo locally

**Files:**
- Create: `/home/dev/projects/opencode-patched/` (local working directory)

**Step 1:** Create local directory and initialize git repo

```bash
mkdir -p /home/dev/projects/opencode-patched
cd /home/dev/projects/opencode-patched
git init
```

**Step 2:** Commit

```bash
git commit --allow-empty -m "initial commit"
```

---

### Task 2: Generate and commit vim.patch

**Files:**
- Create: `patches/vim.patch`

**Step 1:** Generate vim.patch from PR #12679

```bash
gh pr diff 12679 --repo anomalyco/opencode > patches/vim.patch
```

Note: Exclude the `packages/web/` doc files from the patch since they're website docs, not source code. Filter with:

```bash
filterdiff -x '*/packages/web/*' patches/vim.patch > patches/vim-filtered.patch
mv patches/vim-filtered.patch patches/vim.patch
```

If `filterdiff` isn't available, use `awk` to strip those hunks.

**Step 2:** Commit

```bash
git add patches/vim.patch
git commit -m "feat: add vim keybindings patch from PR #12679"
```

---

### Task 3: Create apply.sh

**Files:**
- Create: `patches/apply.sh`

**Step 1:** Write apply.sh that:
1. Takes a source directory as argument
2. Fetches `caching.patch` from opencode-cached's main branch via raw GitHub URL
3. Applies caching.patch first, then local vim.patch
4. Uses `git apply --check` before actual apply (same pattern as opencode-cached)
5. Clear error messages distinguishing which patch failed

**Step 2:** Commit

```bash
chmod +x patches/apply.sh
git add patches/apply.sh
git commit -m "feat: add apply.sh for stacking caching + vim patches"
```

---

### Task 4: Create sync-cached.yml workflow

**Files:**
- Create: `.github/workflows/sync-cached.yml`

**Step 1:** Write workflow that:
- Cron: `0 1,9,17 * * *` (every 8h, offset +1h from opencode-cached's `0 */8 * * *`)
- Also: `workflow_dispatch` with optional `cached_tag` input
- Checks `johnnymo87/opencode-cached` for latest release
- Extracts version (strips `v` prefix and `-cached` suffix)
- Checks if matching `v{VERSION}-patched` release exists in this repo
- If not, triggers `build-release.yml`

Model directly on opencode-cached's `sync-upstream.yml`.

**Step 2:** Commit

```bash
git add .github/workflows/sync-cached.yml
git commit -m "ci: add sync-cached workflow (every 8h, offset +1h)"
```

---

### Task 5: Create build-release.yml workflow

**Files:**
- Create: `.github/workflows/build-release.yml`

**Step 1:** Write workflow that:
- Triggers: `workflow_dispatch` + `workflow_call` with `version` input
- Two parallel jobs: `build-linux` (ubuntu-latest) + `build-macos` (macos-latest)
- Each job:
  1. Checks out this repo
  2. Sets up Bun (latest)
  3. Clones upstream at `v{version}` tag
  4. Runs `patches/apply.sh .` from within the cloned dir (apply.sh fetches caching.patch and applies both)
  5. `bun install && bun run script/build.ts --all`
  6. Archives: linux=tar.gz, macos=zip
  7. Uploads artifacts
- Release job: downloads artifacts, generates checksums, publishes as `v{VERSION}-patched`
- Notify-on-failure job: creates GitHub issue (same pattern as opencode-cached)

Release body should mention both patches and link to PR #5422 and PR #12679.

Model directly on opencode-cached's `build-release.yml`.

**Step 2:** Commit

```bash
git add .github/workflows/build-release.yml
git commit -m "ci: add build-release workflow for combined patched binary"
```

---

### Task 6: Create sync-vim-pr.yml workflow

**Files:**
- Create: `.github/workflows/sync-vim-pr.yml`

**Step 1:** Write workflow that:
- Cron: `0 1,9,17 * * *` (same as sync-cached, parallel)
- Also: `workflow_dispatch`
- Fetches `gh pr diff 12679 --repo anomalyco/opencode`
- Computes sha256 of the fetched diff
- Computes sha256 of committed `patches/vim.patch`
- If different: creates/updates a GitHub issue (label: `patch-drift`) alerting that the PR has changed
- Include the PR URL and instructions to review and regenerate

Note: a `patch-drift` issue is a *producer review signal* only. It means the upstream PR has diverged from the committed patch and a human should inspect it. Drift alone does not block workstation — workstation only depends on published releases. A drift alert becomes consumer-impacting only if/when it causes a subsequent build-release failure (no new release published).

**Step 2:** Commit

```bash
git add .github/workflows/sync-vim-pr.yml
git commit -m "ci: add sync-vim-pr workflow to detect PR #12679 changes"
```

---

### Task 7: Create check-sunset.yml workflow

**Files:**
- Create: `.github/workflows/check-sunset.yml`

**Step 1:** Write workflow that:
- Cron: `0 0 1 * *` (monthly, 1st at midnight UTC)
- Also: `workflow_dispatch`
- Checks PR #12679 state (merged/closed/open) -- if merged, vim patch can be dropped
- Checks PR #5422 state -- if merged, caching patch can be dropped
- If BOTH merged: recommend sunsetting this repo entirely
- Creates/updates issue with label `sunset-check`

Model on opencode-cached's `check-upstream-caching.yml` but check both PRs.

**Step 2:** Commit

```bash
git add .github/workflows/check-sunset.yml
git commit -m "ci: add monthly sunset check for both upstream PRs"
```

---

### Task 8: Create README.md

**Files:**
- Create: `README.md`

**Step 1:** Write README covering:
- What this repo does (combines two patches)
- Links to both upstream PRs
- Installation instructions (4 platforms)
- How it works (timing chain diagram)
- Maintenance (what to do when patches break, sunset criteria)
- Credits (upstream, PR authors, opencode-cached)

**Step 2:** Commit

```bash
git add README.md
git commit -m "docs: add README"
```

---

### Task 9: Create GitHub repo and push

**Step 1:** Create repo on GitHub

```bash
gh repo create johnnymo87/opencode-patched --public --description "OpenCode with prompt caching + vim keybindings patches" --source . --push
```

**Step 2:** Verify

```bash
gh repo view johnnymo87/opencode-patched
```

---

### Task 10: Update workstation - create update-opencode-patched.yml

**Files:**
- Create: `/home/dev/projects/workstation/.github/workflows/update-opencode-patched.yml`

**Step 1:** Clone `update-opencode-cached.yml` with these changes:
- Name: "Update opencode-patched"
- Cron stays `0 2,10,18 * * *` (already 1h after patched repo's schedule)
- Check *published releases* from `johnnymo87/opencode-patched` instead of `opencode-cached`
  - Workstation only tracks release availability, not drift or build signals in the producer repo
  - A missing release (due to build failure) is the actual consumer-facing blocker; drift alone is not
- Strip `-patched` suffix instead of `-cached`
- Update `home.base.nix` the same way (version + 4 hashes)
- Branch: `auto/update-opencode-patched`
- PR title/body reference opencode-patched

**Step 2:** Delete or keep `update-opencode-cached.yml`?
- Keep it but disable (rename to `.yml.disabled`) -- in case user wants to revert
- Actually: just delete it. The opencode-patched releases will now be the source of truth.

**Step 3:** Commit

```bash
git add .github/workflows/update-opencode-patched.yml
git rm .github/workflows/update-opencode-cached.yml
git commit -m "ci: switch from opencode-cached to opencode-patched for updates"
```

---

### Task 11: Update workstation - modify home.base.nix

**Files:**
- Modify: `users/dev/home.base.nix` (lines 87-156)

**Step 1:** Update the opencode derivation:
- Change comments to reference opencode-patched
- Change `pname` from `"opencode-cached"` to `"opencode-patched"`
- Change release URL from `opencode-cached/.../v${version}-cached/` to `opencode-patched/.../v${version}-patched/`
- Change `description` and `homepage` to reference opencode-patched
- Version and hashes stay the same for now (first patched release hasn't been built yet -- the CI will produce it and the update workflow will bump it)

Actually: since no `-patched` release exists yet, we should trigger the first build manually after the repo is created. Or: keep the current `-cached` URL until the first `-patched` release is available, then switch. Safer to switch the URL pattern now and trigger a manual build.

**Step 2:** Commit

```bash
git add users/dev/home.base.nix
git commit -m "feat: switch opencode from -cached to -patched (caching + vim)"
```

---

### Task 12: Trigger first build and verify

**Step 1:** Trigger build manually

```bash
gh workflow run build-release.yml --repo johnnymo87/opencode-patched --field version=1.2.27
```

**Step 2:** Wait for build to complete, then verify release exists

```bash
gh release view v1.2.27-patched --repo johnnymo87/opencode-patched
```

**Step 3:** Update workstation hashes to the actual patched release hashes (from step 2's checksums)

---

### Task 13: Add to projects.nix

**Files:**
- Modify: `projects.nix`

**Step 1:** Add the new repo so it auto-clones on devbox

```nix
opencode-patched = { url = "git@github.com:johnnymo87/opencode-patched.git"; };
```

**Step 2:** Commit

```bash
git add projects.nix
git commit -m "chore: add opencode-patched to projects"
```
