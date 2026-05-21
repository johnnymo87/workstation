# opencode-patched hash-drift detection — implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modify `.github/workflows/update-opencode-patched.yml` so it opens a PR when either the upstream release version changes OR any of the four platform asset hashes drift (e.g. upstream re-uploaded assets in place under the same tag).

**Architecture:** Drop the `up_to_date` short-circuit. Every scheduled run unconditionally prefetches all four platform assets, computes SRI hashes, seds them into `users/dev/home.base.nix`, then gates PR creation on `git diff --quiet`. Clean diff → exit success silently. Dirty diff → existing branch/force-push/PR/auto-merge logic runs.

**Tech Stack:** GitHub Actions YAML, bash, `gh` CLI, `nix-prefetch-url`, `nix hash convert`, `sed`. No new dependencies.

**Design doc:** `docs/plans/2026-05-18-opencode-patched-hash-drift-design.md`

**bd issue:** `workstation-djx`

---

## Pre-flight context for the executing engineer

If you're picking this up cold:

- `OPENCODE_HOSTNAME` will tell you which machine you're on. This work can be done on any host that can run `git` and `gh`. No `nix-prefetch-url` needed locally — that runs on the GitHub Actions runner, not your machine.
- The repo is the [workstation](https://github.com/johnnymo87/workstation) monorepo. The workflow under edit is the one that auto-bumps the OpenCode binary nix derivation.
- The full failure mode is documented in the design doc. TL;DR: upstream re-uploaded `v1.15.0-patched` assets in place 3 days after first publication, hashes drifted, `darwin-rebuild` broke, workflow's `current==latest` check made it a silent no-op.
- Before this plan was written, the immediate `home.base.nix` hashes were already manually refreshed in commit `8b13676`. This plan only fixes the workflow so the next in-place re-upload self-heals.
- `nix` is installed under `/nix/var/nix/profiles/default/bin/` on macOS — but you don't need it for this plan. The verification at the end is `gh workflow run` against the live workflow, not a local nix command.

---

## Task 1: Edit `Check for new release` step — replace short-circuit with informational logging

**Files:**
- Modify: `.github/workflows/update-opencode-patched.yml:26-46`

**Step 1: Identify the exact block to replace**

Open `.github/workflows/update-opencode-patched.yml` and locate the `Check for new release` step. Its current body (lines 30-46) ends with:

```yaml
          if [ "$current" = "$latest" ]; then
            echo "up_to_date=true" >> "$GITHUB_OUTPUT"
            echo "Already on $current"
          else
            echo "up_to_date=false" >> "$GITHUB_OUTPUT"
            echo "Update available: $current -> $latest"
          fi
```

**Step 2: Replace the if-branch with logging only**

Replace the seven-line `if/else/fi` block above with:

```yaml
          if [ "$current" = "$latest" ]; then
            echo "Version unchanged ($current); will check for hash drift."
          else
            echo "Version bump: $current -> $latest"
          fi
```

Note: the `up_to_date` output is gone entirely. We do not need it; subsequent steps will run unconditionally.

**Step 3: Verify the YAML still parses**

Run from the repo root:

```bash
nix-shell -p actionlint --run 'actionlint .github/workflows/update-opencode-patched.yml'
```

Expected: no output, exit 0. If actionlint is unavailable on your platform, fall back to:

```bash
nix-shell -p yq-go --run 'yq eval . .github/workflows/update-opencode-patched.yml > /dev/null'
```

Expected: no output, exit 0. (This only validates YAML well-formedness, not Actions semantics. Acceptable for a step-level change.)

**Step 4: Do NOT commit yet**

This task only edits one step. Tasks 2-4 modify the other three steps. We commit once at the end of Task 5 as a single coherent change.

---

## Task 2: Drop the `up_to_date` guard from `Compute hashes` step

**Files:**
- Modify: `.github/workflows/update-opencode-patched.yml:48-62`

**Step 1: Locate the guard line**

The `Compute hashes` step currently begins:

```yaml
      - name: Compute hashes
        if: steps.check.outputs.up_to_date == 'false'
        id: hashes
        run: |
```

**Step 2: Delete the `if:` line**

Remove the line `        if: steps.check.outputs.up_to_date == 'false'` entirely. The step header should now read:

```yaml
      - name: Compute hashes
        id: hashes
        run: |
```

**Step 3: Verify YAML still parses**

Run the same actionlint / yq check as in Task 1, Step 3.

---

## Task 3: Drop the `up_to_date` guard from `Update home.base.nix` step

**Files:**
- Modify: `.github/workflows/update-opencode-patched.yml:64-80`

**Step 1: Locate the guard line**

The `Update home.base.nix` step currently begins:

```yaml
      - name: Update home.base.nix
        if: steps.check.outputs.up_to_date == 'false'
        run: |
```

**Step 2: Delete the `if:` line**

Remove the line `        if: steps.check.outputs.up_to_date == 'false'` entirely. The step header should now read:

```yaml
      - name: Update home.base.nix
        run: |
```

**Step 3: Verify YAML still parses**

Run the same actionlint / yq check as in Task 1, Step 3.

---

## Task 4: Move the gating logic into the `Create PR` step

**Files:**
- Modify: `.github/workflows/update-opencode-patched.yml:82-109`

**Step 1: Locate the step header and the start of its `run:` body**

The `Create PR` step currently begins:

```yaml
      - name: Create PR
        if: steps.check.outputs.up_to_date == 'false'
        env:
          GH_TOKEN: ${{ secrets.UPDATE_TOKEN }}
        run: |
          version="${{ steps.check.outputs.latest }}"
          branch="auto/update-opencode-patched"

          git checkout -B "$branch"
          git add -A
```

**Step 2: Delete the `if:` line AND insert a diff-gate at the top of `run:`**

Two edits to this step in one pass:

a. Remove the line `        if: steps.check.outputs.up_to_date == 'false'`.

b. At the top of the `run: |` body — immediately after the `run: |` line and before `version=...` — insert a diff gate. The final step header + opening of the body should look like:

```yaml
      - name: Create PR
        env:
          GH_TOKEN: ${{ secrets.UPDATE_TOKEN }}
        run: |
          file="users/dev/home.base.nix"
          if git diff --quiet "$file"; then
            echo "No drift in $file; nothing to PR."
            exit 0
          fi

          version="${{ steps.check.outputs.latest }}"
          branch="auto/update-opencode-patched"

          git checkout -B "$branch"
          git add -A
```

The rest of the step body (the git commit, push, and `gh pr create` / `gh pr merge` logic) stays exactly as it is.

**Step 3: Verify YAML still parses**

Run the same actionlint / yq check as in Task 1, Step 3.

---

## Task 5: Inspect the full diff, commit, and push

**Files:**
- Modified: `.github/workflows/update-opencode-patched.yml`

**Step 1: Review the consolidated diff**

```bash
cd /Users/jonathan.mohrbacher/Code/workstation
git diff .github/workflows/update-opencode-patched.yml
```

Expected diff shape (approximate):

- The 7-line `if/else/fi` in `Check for new release` becomes a 5-line if/else that only echoes.
- Three `if: steps.check.outputs.up_to_date == 'false'` lines removed (one each from `Compute hashes`, `Update home.base.nix`, `Create PR`).
- A new 5-line `file=...; if git diff --quiet "$file"; then echo "..."; exit 0; fi` block inserted at the top of the `Create PR` step's `run:` body.

Eyeball: no other lines changed. The sed patterns, branch name, PR title, force-push behavior, and auto-merge logic are untouched.

**Step 2: Run a final YAML sanity check on the whole file**

```bash
nix-shell -p actionlint --run 'actionlint .github/workflows/update-opencode-patched.yml'
```

Expected: exit 0, no output. (Fall back to `yq eval . <file> > /dev/null` if actionlint is unavailable.)

**Step 3: Check git status is clean otherwise**

```bash
git status --short
```

Expected: the workflow file shows as modified. The pre-existing unrelated drift (`users/dev/home.darwin.nix`, `.beads/*`) noted in the previous handoff may still be present. **Do NOT stage those.** Only stage the workflow file.

**Step 4: Stage and commit**

```bash
git add .github/workflows/update-opencode-patched.yml
git commit -m "fix(ci): catch in-place asset re-uploads in update-opencode-patched

Drop the up_to_date version short-circuit. Always prefetch all four
platform asset hashes and sed them into home.base.nix on every
scheduled run; gate PR creation on whether the file actually changed.

This closes the silent-no-op gap that bit us on 2026-05-18 when
upstream re-uploaded v1.15.0-patched assets without bumping the tag,
leaving us with stale FOD hashes and a broken darwin-rebuild.

Cost: ~170 MB of asset downloads per scheduled run on the
GH-hosted runner. Negligible.

Refs workstation-djx."
```

**Step 5: Push to main**

```bash
git pull --rebase
git push
git status
```

Expected: `git status` reports `up to date with 'origin/main'`.

---

## Task 6: Verify on the live workflow

**Files:** none modified.

**Step 1: Trigger the workflow manually**

```bash
gh workflow run update-opencode-patched.yml
```

**Step 2: Watch it run**

```bash
sleep 5
gh run list --workflow=update-opencode-patched.yml --limit 1
# grab the run id from the output, then:
gh run watch <run-id>
```

**Step 3: Inspect the logs of the Create PR step**

The hashes in `home.base.nix` were manually refreshed in commit `8b13676` and match the current upstream artifacts. So the expected log message in the `Create PR` step is:

```
No drift in users/dev/home.base.nix; nothing to PR.
```

And the overall run should complete successfully without opening a PR.

```bash
gh run view <run-id> --log | grep -A2 "Create PR"
```

Expected: see the "No drift" message and no `gh pr create` invocation.

**Step 4: Sanity-check no spurious PR appeared**

```bash
gh pr list --head auto/update-opencode-patched --state open
```

Expected: no PRs returned (or only any pre-existing ones unrelated to this change).

---

## Task 7: Close the bd issue

**Step 1: Close `workstation-djx` with a reference to the merged commit**

```bash
bd close workstation-djx \
  --message="Fixed in commit <sha-from-step-5> on main. Workflow now unconditionally prefetches hashes and PRs only when home.base.nix actually changes; live workflow_dispatch verified clean in run <run-id>."
```

(Substitute the actual commit sha from Task 5 and run id from Task 6.)

**Step 2: Confirm the issue is closed**

```bash
bd show workstation-djx | head
```

Expected: `status: closed`.

---

## Done criteria

- `.github/workflows/update-opencode-patched.yml` no longer references the `up_to_date` output anywhere.
- A `workflow_dispatch` run completes successfully, logs `No drift in users/dev/home.base.nix; nothing to PR.`, and creates no PR.
- `git status` shows the working tree synced to `origin/main`.
- `workstation-djx` is closed with a reference to the merged commit.
