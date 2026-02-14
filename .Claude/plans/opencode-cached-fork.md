# OpenCode Cached Fork: Clone-and-Patch Pipeline

## TL;DR
> **Quick Summary**: Create a GitHub repo that automatically clones each new opencode release, applies prompt caching improvements from PR #5422, builds arm64 binaries, and publishes releases consumed by the workstation flake.
> **Deliverables**: GitHub repo with CI workflows, tested patch file, Nix integration in workstation flake
> **Estimated Effort**: Medium (3.5–5 hours initial, ~30 min 2-4x/month ongoing)
> **Parallel Execution**: YES - 2 waves
> **Critical Path**: Task 1 (patch) → Task 2 (repo+CI) → Task 4 (Nix integration) → Task 5 (end-to-end validation)

## Context

### Original Request
User is running opencode with Anthropic Claude Opus 4.6. Cost analysis showed cache writes are ~60% of spend ($408 over 9 active days, estimated ~$900/month in wasted cache writes). PR #5422 on anomalyco/opencode adds comprehensive caching improvements (44% reduction in cache writes, 73% effective cost reduction by 3rd prompt) but the maintainer won't merge it. No existing fork has applied the patch. The goal is to maintain a lightweight CI pipeline that applies the patch to each upstream release automatically.

### Interview Summary
- **Cost measurement**: ccusage-opencode daily analysis confirmed cache write dominance (~60% of cost)
- **Plugin approach ruled out**: Plugin hooks run before `applyCaching()` — can't modify cache breakpoints, tool sorting, or tool definition caching via plugin
- **Maintainer status**: thdxr's `llm-centralization` refactor merged Dec 15 2025. Zero caching work since. ~30 PRs in other areas. No response to community requests for timeline.
- **No existing forks with this patch**: Searched top 20 forks by stars, all recently active forks, PR commenters' forks, and code search for `ProviderCacheConfig`. Nobody has done this.
- **evil-opencode CI template**: `winmin/evil-opencode` (184⭐) demonstrates the clone-and-patch model — clones upstream at tag, applies patches via script, builds with Bun, releases. No fork branch maintenance.
- **Architecture decision**: Clone-and-patch (not fork-and-rebase) for zero-maintenance common case

### Research Findings
- **llm-agents.nix packages opencode as prebuilt binary** via `fetchurl` from GitHub releases — not a source build. Override must provide equivalent binary + wrapping.
- **evil-opencode CI**: `sync-upstream.yml` (cron 8h, detects new tags) → `build-release.yml` (clone upstream at tag, apply patches, `bun install && bun run script/build.ts` from within cloned repo, release via `softprops/action-gh-release`).
- **Build process**: Bun native compile via `packages/opencode/script/build.ts`. Fetches models.dev snapshot, generates types, cross-compiles per target. We need only `linux-arm64` and `darwin-arm64`.
- **Release velocity**: Multiple releases per day (v1.1.63–65 in 2 days). `transform.ts` touched 5 times in 5 days.
- **PR #5422 status**: CONFLICTING merge status. Touches 6 files (~2671 lines): 3 new (should apply cleanly), 3 modified (conflict risk in `packages/opencode/src/provider/transform.ts`, `packages/opencode/src/config/config.ts`, `packages/opencode/src/session/prompt.ts`).
- **Current opencode packaging in workstation**: `llmPkgs.opencode` on line 78 of `users/dev/home.base.nix`. Override point is replacing this with a custom package.

### Metis Review
- **Patch conflict is blocking**: PR #5422 confirmed CONFLICTING — must be manually resolved against current tag before anything else
- **Failure mode undefined**: Need explicit policy for when patch fails to apply in CI (recommendation: fail loudly, don't release unpatched binaries)
- **Nix wrapping complexity**: llm-agents uses `wrapBuddy` (Linux ELF patching), `versionCheckHook`, fzf/ripgrep PATH wrapping — custom package must replicate
- **Sunset strategy needed**: If upstream merges their own caching, patch becomes partially redundant — need detection mechanism
- **8h sync may be too aggressive**: If patch breaks require manual fixes, frequent syncs just generate noise. Consider matching llm-agents update cadence instead.

## Work Objectives

### Core Objective
Automatically produce patched opencode binaries with improved prompt caching on every upstream release, consumed by the workstation Nix flake, with zero-touch operation when patch applies cleanly and loud failure when it doesn't.

### Concrete Deliverables
- GitHub repo `opencode-cached` with:
  - `patches/caching.patch` — conflict-resolved PR #5422 diff
  - `patches/apply.sh` — patch application script with clear error reporting
  - `.github/workflows/sync-upstream.yml` — tag detection + build trigger
  - `.github/workflows/build-release.yml` — clone, patch, build, release
- Workstation flake changes:
  - Custom opencode-cached package definition (inline or in `pkgs/`)
  - `home.base.nix` wired to use patched opencode

### Definition of Done
- [ ] `gh workflow run build-release.yml` succeeds and produces a GitHub release with `opencode-linux-arm64.tar.gz` and `opencode-darwin-arm64.zip`
- [ ] Downloaded binary runs: `./opencode --version` prints version string
- [ ] `home-manager switch --flake .#dev` succeeds with patched opencode
- [ ] `opencode --version` on devbox runs the patched build
- [ ] Deliberately breaking the patch causes CI to fail with clear error naming the conflicting file(s)

### Must Have
- Patch applies PR #5422's caching improvements (tool sorting, additional cache breakpoints, tool definition caching, per-provider config)
- CI builds only linux-arm64 and darwin-arm64 (no x86, no Windows, no Tauri/Desktop)
- CI fails loudly when patch doesn't apply — never releases unpatched binaries
- Manual `workflow_dispatch` trigger for testing
- SHA256 checksums in release assets
- Nix package replicates llm-agents wrapping (fzf, ripgrep in PATH; ELF patching on Linux)

### Must NOT Have (Guardrails)
- No auto-rebase or auto-conflict-resolution — when patch breaks, fix manually
- No x86_64 targets — only arm64 for both platforms
- No Tauri/Desktop builds — CLI only
- No npm/AUR/Docker publishing — GitHub releases only
- No "smart" fallback to unpatched builds — binary is either patched or not released
- No modifications to the llm-agents flake input or its auto-update mechanism
- No ccusage-opencode rebuild — keep using it from llm-agents
- No patch auto-updater or LLM-assisted conflict resolution

## Verification Strategy
- **Test Infrastructure**: YES, **Strategy**: Tests-after (validate patch applies + binary runs), **Framework**: Bun test (upstream) + bash assertions
- **Agent-Executed QA**: MANDATORY for ALL tasks — all verification steps must be automated and produce evidence files

## Execution Strategy

```
Wave 1 (parallel):
  Task 1: Resolve patch conflicts & produce caching.patch
  Task 3: Study llm-agents package.nix for Nix wrapping requirements

Wave 2 (sequential, depends on Wave 1):
  Task 2: Create opencode-cached repo with CI workflows

Wave 3 (depends on Task 2):
  Task 4: Nix integration in workstation flake

Wave 4 (depends on Task 4):
  Task 5: End-to-end validation

Wave 5 (depends on Task 5):
  Task 6: Monitoring and sunset strategy
```

## TODOs

- [ ] 1. Resolve PR #5422 Conflicts and Produce Patch File
  **What to do**:
  1. Clone opencode at the latest release tag: `git clone --depth 1 --branch <latest-tag> https://github.com/anomalyco/opencode.git`
  2. Create a branch: `git checkout -b caching-patch`
  3. Fetch PR #5422's changes: `gh pr diff 5422 --repo anomalyco/opencode > pr-5422-raw.patch`
  4. Attempt to apply: `git apply --check pr-5422-raw.patch` — expect failures
  5. For the 3 new files (`packages/opencode/src/provider/config.ts`, `packages/opencode/test/provider/config.test.ts`, `packages/opencode/test/provider/transform.test.ts`) — these should apply cleanly
   6. For the 3 modified files (`packages/opencode/src/provider/transform.ts`, `packages/opencode/src/config/config.ts`, `packages/opencode/src/session/prompt.ts`) — manually resolve conflicts by understanding both the PR's intent (caching improvements) and upstream's changes since Dec 2025
  7. Run upstream tests: `bun test` in `packages/opencode/` to verify nothing breaks
  8. Run PR-specific tests: `bun test test/provider/config.test.ts test/provider/transform.test.ts`
  9. Generate clean patch: `git diff <latest-tag>..caching-patch > patches/caching.patch`
  10. Verify patch applies cleanly to a fresh clone: `git clone ... && git apply patches/caching.patch`
  **Must NOT do**: Auto-resolve conflicts. Skip tests. Include changes beyond PR #5422's scope.
  **Parallelization**: Wave 1 | Blocks: 2 | Blocked by: none
  **References**:
  - PR diff: `gh pr diff 5422 --repo anomalyco/opencode` — the raw changes to adapt
  - Current caching code: `packages/opencode/src/provider/transform.ts:applyCaching()` (lines ~171-209) — the function being modified
  - PR description: `gh pr view 5422 --repo anomalyco/opencode` — explains the caching strategy (explicit breakpoint, automatic prefix, implicit/content-based paradigms)
  - New provider config: PR adds `packages/opencode/src/provider/config.ts` (~874 lines) — per-provider caching defaults for 19+ providers
   - Config schema changes: PR adds `cache` and `promptOrder` fields to Agent config in `packages/opencode/src/config/config.ts`
  **Acceptance Criteria**:
  - [ ] `git apply --check patches/caching.patch` exits 0 on fresh clone at latest tag
  - [ ] `bun test` passes in `packages/opencode/` after applying patch
  - [ ] Patch file contains changes to exactly 6 files (3 new, 3 modified)
  - [ ] QA Scenarios:
    Scenario: Patch applies to fresh clone
      Tool: Bash
      Preconditions: Fresh `git clone --branch <latest-tag>` of anomalyco/opencode
      Steps: `git apply --check patches/caching.patch && git apply patches/caching.patch`
      Expected: Exit code 0, no errors, no `.rej` files
      Evidence: .Claude/evidence/task-1-patch-apply.txt
    Scenario: Tests pass after patching
      Tool: Bash
      Preconditions: Patch applied to fresh clone
      Steps: `cd packages/opencode && bun install && bun test`
      Expected: All tests pass including new `config.test.ts` and `transform.test.ts`
      Evidence: .Claude/evidence/task-1-test-results.txt
  **Commit**: `feat: resolve PR #5422 conflicts and produce caching patch` | Files: `patches/caching.patch` | Pre-commit: `git apply --check patches/caching.patch`

- [ ] 2. Create opencode-cached Repo with CI Workflows
  **What to do**:
  1. Create GitHub repo: `gh repo create opencode-cached --public --description "OpenCode with prompt caching improvements (PR #5422)"`
  2. Create `patches/apply.sh`:
     - Takes one arg: path to cloned opencode source
     - Applies `caching.patch` with `git apply`
     - On failure: prints which files failed, lists `.rej` files, exits non-zero
  3. Create `.github/workflows/sync-upstream.yml` (adapt from `winmin/evil-opencode`):
     - Cron: every 8 hours (`0 */8 * * *`)
     - Manual dispatch with optional `upstream_tag` input
     - Check latest upstream release tag via `gh api repos/anomalyco/opencode/releases/latest`
     - Compare against existing `-cached` tags in this repo
     - If new: trigger `build-release.yml` via `gh workflow run`
  4. Create `.github/workflows/build-release.yml` (adapt from `winmin/evil-opencode`):
     - Trigger: `workflow_dispatch` with `version` input + `workflow_call` from sync
     - Two parallel jobs: `build-linux` (ubuntu-latest) and `build-macos` (macos-latest)
     - Each job steps:
       a. Clone opencode at tag: `git clone --depth 1 --branch v{version} https://github.com/anomalyco/opencode.git opencode-src`
       b. Apply patch: `cd opencode-src && ../patches/apply.sh .`
       c. Install deps: `bun install`
       d. Build CLI: `cd packages/opencode && bun run script/build.ts` (builds for all targets by default)
       e. Extract only the needed artifact (`opencode-linux-arm64` or `opencode-darwin-arm64`) from `packages/opencode/dist/`
       f. Upload artifact
     - `release` job: download artifacts, generate `checksums.sha256`, create GitHub release tagged `v{version}-cached`
     - Linux job uploads `opencode-linux-arm64.tar.gz`; macOS job uploads `opencode-darwin-arm64.zip`
     - Set env: `OPENCODE_VERSION={version}`, `OPENCODE_CHANNEL=latest`
  5. Create `README.md` explaining the repo's purpose, link to PR #5422, and how to use
  6. Push all files, then trigger first build via `gh workflow run build-release.yml`
  **Must NOT do**: Build x86 targets. Build Tauri/Desktop. Publish to npm/AUR/Docker. Add auto-rebase logic. Release unpatched binaries on patch failure.
  **Parallelization**: Wave 2 | Blocks: 4 | Blocked by: 1
  **References**:
  - evil-opencode sync workflow: `gh api repos/winmin/evil-opencode/contents/.github/workflows/sync-upstream.yml` — template for tag detection logic
  - evil-opencode build workflow: `gh api repos/winmin/evil-opencode/contents/.github/workflows/build-release.yml` — template for clone+patch+build+release pipeline
  - Opencode build script: `packages/opencode/script/build.ts` — Bun native compile, target names (e.g., `bun-linux-arm64`), models.dev fetch
  - GitHub Actions release: `softprops/action-gh-release@v2` — used by evil-opencode for release creation
  - Bun version: Check evil-opencode's `.github/actions/setup-bun` or `package.json` engines field for required Bun version
  **Acceptance Criteria**:
  - [ ] `gh workflow run build-release.yml -f version=<latest>` triggers successfully
  - [ ] Build completes with release containing exactly: `opencode-linux-arm64.tar.gz`, `opencode-darwin-arm64.zip`, `checksums.sha256`
  - [ ] QA Scenarios:
    Scenario: Manual build trigger works
      Tool: Bash
      Preconditions: Repo created and workflows pushed
      Steps: `gh workflow run build-release.yml --repo <user>/opencode-cached -f version=$(gh api repos/anomalyco/opencode/releases/latest --jq .tag_name | sed 's/^v//')` then poll `gh run list --repo <user>/opencode-cached --limit 1 --json status,conclusion`
      Expected: Run completes with `conclusion: "success"` within 15 minutes
      Evidence: .Claude/evidence/task-2-build-run.txt
    Scenario: Release assets downloadable
      Tool: Bash
      Preconditions: Successful build run
      Steps: `gh release view --repo <user>/opencode-cached --json assets --jq '.assets[].name'`
      Expected: Output contains `opencode-linux-arm64.tar.gz`, `opencode-darwin-arm64.zip`, `checksums.sha256`
      Evidence: .Claude/evidence/task-2-release-assets.txt
    Scenario: Patch failure fails build loudly
      Tool: Bash
      Preconditions: Temporarily corrupt the patch file (add garbage to first hunk)
      Steps: Push corrupted patch, trigger build, check run logs
      Expected: Run fails with `conclusion: "failure"`, logs contain file name that failed to patch
      Evidence: .Claude/evidence/task-2-patch-failure.txt
    Scenario: Downloaded binary runs
      Tool: Bash
      Preconditions: Release exists
      Steps: `curl -sL https://github.com/<user>/opencode-cached/releases/latest/download/opencode-linux-arm64.tar.gz | tar xz && ./opencode --version`
      Expected: Prints version string matching the upstream tag
      Evidence: .Claude/evidence/task-2-binary-runs.txt
  **Commit**: `feat: add CI workflows for clone-patch-build pipeline` | Files: `.github/workflows/`, `patches/`, `README.md` | Pre-commit: `shellcheck patches/apply.sh`

- [ ] 3. Study llm-agents Nix Packaging for Replication
  **What to do**:
  1. Read the llm-agents opencode package: `gh api repos/numtide/llm-agents.nix/contents/packages/opencode/package.nix --jq .content | base64 -d`
  2. Read the hashes file: `gh api repos/numtide/llm-agents.nix/contents/packages/opencode/hashes.json --jq .content | base64 -d`
  3. Document: binary wrapping (fzf, ripgrep in PATH), ELF patching (`wrapBuddy`/`autoPatchelfHook`), `dontStrip`, linked libraries (`stdenv.cc.cc.lib`), install structure
  4. Determine minimum Nix derivation needed to replicate: `fetchurl` + `autoPatchelfHook` (Linux) + `makeWrapper` (both) + runtime deps
  5. Record findings for Task 4
  **Must NOT do**: Modify llm-agents.nix. Build anything yet — research only.
  **Parallelization**: Wave 1 | Blocks: 4 | Blocked by: none
  **References**:
  - llm-agents package.nix: `gh api repos/numtide/llm-agents.nix/contents/packages/opencode/package.nix` — the exact packaging to replicate
  - llm-agents hashes.json: `gh api repos/numtide/llm-agents.nix/contents/packages/opencode/hashes.json` — version + per-platform hashes format
  - Workstation flake.nix: `flake.nix` — how llm-agents is consumed (`llm-agents.packages.${system}`)
  - home.base.nix line 78: `llmPkgs.opencode` — the override point
  **Acceptance Criteria**:
  - [ ] Document produced listing: fetchurl URL pattern, hash format, `autoPatchelfHook` usage, `makeWrapper` args, runtime dependencies, install phase commands
  - [ ] QA Scenarios:
    Scenario: Package structure documented
      Tool: Bash
      Preconditions: llm-agents package.nix read
      Steps: Verify documentation covers all wrapping and patching steps by comparing against `nix show-derivation $(which opencode) 2>/dev/null | head -50` output
      Expected: All runtime dependencies and wrapper args accounted for
      Evidence: .Claude/evidence/task-3-package-analysis.txt

- [ ] 4. Nix Integration in Workstation Flake
  **What to do**:
  1. Add `opencode-cached` as a flake input (flake = false, just for accessing releases):
     ```nix
     opencode-cached = {
       url = "github:<user>/opencode-cached";
       flake = false;
     };
     ```
     Or alternatively, define the package inline using `fetchurl` pointing at the release URL (no flake input needed — simpler).
  2. Create the opencode-cached package definition. Based on Task 3's findings, likely:
     ```nix
     pkgs.stdenv.mkDerivation {
       pname = "opencode-cached";
       version = "<version>";
       src = fetchurl {
         url = "https://github.com/<user>/opencode-cached/releases/download/v${version}-cached/opencode-linux-arm64.tar.gz";
         sha256 = "<hash>";
       };
       # Replicate llm-agents wrapping from Task 3 findings
     };
     ```
  3. Wire into `home.base.nix`: replace `llmPkgs.opencode` with the custom package (or use `let`/`overlay` to make it switchable)
  4. Add a comment explaining why this override exists and link to PR #5422
  5. Build and activate: `home-manager switch --flake .#dev`
  **Must NOT do**: Modify `llm-agents` input. Break ccusage-opencode or other llm-agents packages. Create complex auto-switching logic. Hardcode paths.
  **Parallelization**: Wave 3 | Blocks: 5 | Blocked by: 1, 2, 3
  **References**:
  - Task 3 output: Nix packaging requirements (wrapping, ELF patching, runtime deps)
  - `flake.nix`: Current flake inputs and outputs structure
  - `users/dev/home.base.nix:78`: Override point (`llmPkgs.opencode`)
  - `users/dev/opencode-config.nix`: opencode config module — must continue working with patched binary
  - llm-agents package.nix: Exact wrapping to replicate (from Task 3)
  **Acceptance Criteria**:
  - [ ] `home-manager switch --flake .#dev` succeeds
  - [ ] `which opencode` points to nix store path containing the patched binary
  - [ ] `opencode --version` prints expected version
  - [ ] `ccusage-opencode --help` still works (llm-agents not broken)
  - [ ] QA Scenarios:
    Scenario: Patched opencode activates
      Tool: Bash
      Preconditions: `home-manager switch` completed
      Steps: `opencode --version && which opencode && nix path-info $(which opencode)`
      Expected: Version matches release tag, path is in nix store
      Evidence: .Claude/evidence/task-4-activation.txt
    Scenario: Other llm-agents packages unaffected
      Tool: Bash
      Preconditions: `home-manager switch` completed
      Steps: `ccusage-opencode --help && which ccusage-opencode`
      Expected: ccusage-opencode help text displays, binary exists
      Evidence: .Claude/evidence/task-4-other-packages.txt
    Scenario: Opencode config still works
      Tool: Bash
      Preconditions: Patched opencode installed
      Steps: `opencode --help` (basic smoke test that config loads)
      Expected: Help text displays without config errors
      Evidence: .Claude/evidence/task-4-config-works.txt
  **Commit**: `feat(opencode): use patched opencode-cached with prompt caching improvements` | Files: `flake.nix`, `users/dev/home.base.nix`, possibly `pkgs/opencode-cached/` | Pre-commit: `home-manager switch --flake .#dev`

- [ ] 5. End-to-End Validation
  **What to do**:
  1. Verify patched binary basic functionality: `opencode --version && opencode --help`
  2. Verify sync-upstream workflow exists and is enabled: `gh workflow list --repo johnnymo87/opencode-cached`
  3. Test `workflow_dispatch` manual trigger: `gh workflow run sync-upstream.yml --repo johnnymo87/opencode-cached`
  4. Run cost tracking analysis script to verify it works with the patched binary: `node .opencode/skills/tracking-cache-costs/analyze.mjs`
  5. Document that ongoing cache improvement validation will happen naturally over coming days as the user uses opencode in their normal workflow
  **Must NOT do**: Draw definitive conclusions from synthetic tests — cache improvements require real multi-session usage to validate. Modify the patch based on initial results.
  **Parallelization**: Wave 4 | Blocks: 6 | Blocked by: 4
  **References**:
  - tracking-cache-costs skill: `.opencode/skills/tracking-cache-costs/SKILL.md` — analysis workflow
  - analyze.mjs: `.opencode/skills/tracking-cache-costs/analyze.mjs` — cost analysis script
  - Pre-patch baseline: Feb 12-13 data showed 44-46% cache write ratio, ~60% of cost from cache writes
  **Acceptance Criteria**:
  - [ ] `opencode --version` and `opencode --help` succeed
  - [ ] `gh workflow list --repo johnnymo87/opencode-cached` shows sync-upstream.yml enabled
  - [ ] `node .opencode/skills/tracking-cache-costs/analyze.mjs` runs without error
  - [ ] QA Scenarios:
    Scenario: Patched binary smoke test
      Tool: Bash
      Preconditions: Patched opencode installed via home-manager
      Steps: `opencode --version && opencode --help | head -10`
      Expected: Version string prints, help text displays without errors
      Evidence: .Claude/evidence/task-5-smoke-test.txt
    Scenario: CI workflows are operational
      Tool: Bash
      Preconditions: opencode-cached repo created with workflows
      Steps: `gh workflow list --repo johnnymo87/opencode-cached --json name,state`
      Expected: sync-upstream.yml and build-release.yml both show state: "active"
      Evidence: .Claude/evidence/task-5-workflows.txt
    Scenario: Cost tracking analysis runs
      Tool: Bash
      Preconditions: ccusage-opencode data exists
      Steps: `node .opencode/skills/tracking-cache-costs/analyze.mjs 2>&1`
      Expected: Script completes, shows daily breakdown (even if patched session data not yet available)
      Evidence: .Claude/evidence/task-5-cost-analysis.txt

- [ ] 6. Monitoring and Sunset Strategy
  **What to do**:
  1. Set up GitHub Actions notification for build failures (email or create issue on failure):
     - Add `if: failure()` step in build-release.yml that creates an issue titled "Patch failed to apply on v{version}"
  2. Add a periodic check workflow (monthly) that checks upstream for caching improvements:
     - `gh search code "applyCaching" --repo anomalyco/opencode` to detect changes
     - Check if PR #5422 was closed/merged: `gh pr view 5422 --repo anomalyco/opencode --json state`
  3. Document the sunset criteria:
     - If upstream merges equivalent caching improvements, stop building patched releases
     - If PR #5422 is officially closed as "won't fix", consider contributing an improved version upstream
     - If patch breaks 3+ consecutive releases, re-evaluate the approach
  **Must NOT do**: Auto-sunset. Auto-rebase. Create complex monitoring infrastructure.
  **Parallelization**: Wave 5 | Blocks: none | Blocked by: 5
  **References**:
  - PR #5422: `gh pr view 5422 --repo anomalyco/opencode` — track state changes
  - Issue #5416: `gh issue view 5416 --repo anomalyco/opencode` — upstream feature request for caching improvements
  - evil-opencode issue creation pattern: Check if they auto-create issues on build failure
  **Acceptance Criteria**:
  - [ ] Build failure creates a GitHub issue in `opencode-cached` repo with the failing version and conflicting files
  - [ ] QA Scenarios:
    Scenario: Failure notification works
      Tool: Bash
      Preconditions: Deliberately broken patch pushed
      Steps: Trigger build, wait for failure, `gh issue list --repo <user>/opencode-cached --state open --json title`
      Expected: Issue exists with title containing the version number
      Evidence: .Claude/evidence/task-6-failure-notification.txt
  **Commit**: `feat: add failure notifications and sunset monitoring` | Files: `.github/workflows/build-release.yml`, `.github/workflows/check-upstream.yml`

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `feat: resolve PR #5422 conflicts and produce caching patch` | `patches/caching.patch` | `git apply --check` on fresh clone |
| 2 | `feat: add CI workflows for clone-patch-build pipeline` | `.github/workflows/`, `patches/apply.sh`, `README.md` | Manual workflow dispatch succeeds |
| 3 | (no commit — research only, findings feed Task 4) | — | — |
| 4 | `feat(opencode): use patched opencode-cached with prompt caching improvements` | `flake.nix`, `users/dev/home.base.nix` | `home-manager switch` succeeds |
| 5 | (no commit — validation only) | — | — |
| 6 | `feat: add failure notifications and sunset monitoring` | `.github/workflows/` | Failure issue creation test |

## Success Criteria

### Verification Commands
```bash
# Binary works
opencode --version  # → prints patched version

# Nix integration intact
home-manager switch --flake .#dev  # → succeeds
ccusage-opencode --help  # → works (llm-agents unbroken)

# CI pipeline works
gh workflow run build-release.yml --repo <user>/opencode-cached  # → succeeds
gh release list --repo <user>/opencode-cached --limit 1  # → shows latest release

# Cost improvement (ongoing, multi-session)
node .opencode/skills/tracking-cache-costs/analyze.mjs  # → cache write % trending down
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] Patch applies cleanly to latest upstream tag
- [ ] CI builds produce working arm64 binaries for both platforms
- [ ] Nix integration doesn't break other llm-agents packages
- [ ] Failure mode tested: broken patch → CI fails → issue created
- [ ] Sunset criteria documented
