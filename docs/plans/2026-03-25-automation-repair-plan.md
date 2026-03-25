# Multi-Repo Automation Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restore green automation across the user's patch/update repos and harden the workflows against the current upstream changes.

**Architecture:** Fix each failing automation at its actual break point rather than adding retries. `opencode-cached` needs its patch/application flow updated for current upstream OpenCode, while `workstation` needs update workflows aligned with upstream release artifact naming and current Go toolchain constraints.

**Tech Stack:** GitHub Actions, Nix flakes, Nix derivations, Bun, Bash, git, gh

---

### Task 1: Repair `opencode-cached` patch application for current upstream releases

**Files:**
- Modify: `/home/dev/projects/opencode-cached/patches/caching.patch`
- Modify: `/home/dev/projects/opencode-cached/patches/apply.sh`
- Verify: `/home/dev/projects/opencode-cached/.github/workflows/build-release.yml`

**Step 1: Reproduce patch failure locally**

Run: `git clone --depth 1 --branch v1.3.2 https://github.com/anomalyco/opencode.git /tmp/opencode-1.3.2 && /home/dev/projects/opencode-cached/patches/apply.sh /tmp/opencode-1.3.2`

Expected: patch failure in `packages/opencode/src/provider/transform.ts`.

**Step 2: Refresh the patch against current upstream code**

Update the patch so the caching changes apply cleanly to current upstream while preserving the existing provider-config behavior.

**Step 3: Re-run local patch application**

Run: `/home/dev/projects/opencode-cached/patches/apply.sh /tmp/opencode-1.3.2`

Expected: patch applies with no errors.

**Step 4: Smoke-test build assumptions**

Run a targeted build/install command far enough to prove the patched tree is structurally valid.

### Task 2: Repair `workstation` `Update gws` workflow for current release assets

**Files:**
- Modify: `/home/dev/projects/workstation/.github/workflows/update-gws.yml`
- Modify: `/home/dev/projects/workstation/pkgs/gws/default.nix`

**Step 1: Confirm release asset naming drift**

Verify that upstream `googleworkspace/cli` renamed assets from `gws-*` to `google-workspace-cli-*` and now publishes a newer latest release.

**Step 2: Update the workflow hash-computation logic**

Make the workflow fetch hashes for the current asset names used by the upstream release.

**Step 3: Update the package derivation to match upstream assets**

Replace hardcoded old asset names with the new names so future updates and local builds stay aligned.

**Step 4: Verify hash computation locally**

Run the equivalent prefetch commands locally and confirm the URLs resolve.

### Task 3: Repair `workstation` `beads` update path

**Files:**
- Modify: `/home/dev/projects/workstation/.github/workflows/update-packages.yml`
- Modify: `/home/dev/projects/workstation/pkgs/beads/default.nix` only if required by the root cause

**Step 1: Confirm the failure mechanism**

Validate that `nix-update --flake beads` fails because the latest upstream `beads` requires a newer Go toolchain than the current workflow environment can satisfy.

**Step 2: Choose a durable mitigation**

Either pin the updater to a supported version range, override the build toolchain appropriately, or skip auto-updating `beads` until the toolchain catches up.

**Step 3: Implement the smallest durable fix**

Prefer a workflow/package change that makes the automation deterministic instead of repeatedly failing.

**Step 4: Verify the chosen path locally**

Run the relevant `nix-update` or `nix build` command to prove the workflow change is justified.

### Task 4: Verify targeted repair outcomes

**Files:**
- Verify only

**Step 1: Verify `opencode-cached` patch apply succeeds locally**

**Step 2: Verify `workstation` `gws` package/build inputs are consistent**

**Step 3: Verify `workstation` `beads` update workflow no longer takes the broken path**

**Step 4: Summarize remaining non-owned issues**

Document that `opencode-vim` sync conflicts remain an upstream fork-maintenance problem unless explicitly requested.
