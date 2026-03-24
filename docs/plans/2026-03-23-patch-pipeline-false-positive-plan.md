# Patch Pipeline False Positive Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce false-positive patch-pipeline alerts by standardizing drift/build signaling across `opencode-cached`, `opencode-patched`, and `workstation`.

**Architecture:** Keep raw patch files as the canonical stored artifacts, compare raw upstream diffs against raw stored patches, and separate upstream drift from patch conflicts and build failures. Update repo documentation so the producer repos and the consuming workstation repo use the same terminology.

**Tech Stack:** GitHub Actions YAML, shell scripting, Markdown docs, GitHub issue conventions.

---

### Task 1: Audit and normalize PR-backed drift workflows in `opencode-patched`

**Files:**
- Modify: `opencode-patched/.github/workflows/sync-vim-pr.yml`
- Modify: `opencode-patched/.github/workflows/sync-tool-fix-pr.yml`

**Step 1: Write the failing expectation checklist**

Document the expected invariant in the task notes:

- both workflows compare raw upstream PR diffs to raw stored patch files
- drift wording says review is needed, not that the build is broken

**Step 2: Inspect both workflows and identify comparison asymmetries**

Run:

```bash
git diff -- opencode-patched/.github/workflows/sync-vim-pr.yml opencode-patched/.github/workflows/sync-tool-fix-pr.yml
```

Expected: see whether either workflow filters one side of the comparison or uses different issue wording.

**Step 3: Apply the minimal workflow edits**

Make both workflows:

- fetch the raw PR diff
- hash the raw fetched diff
- hash the raw committed patch file
- report `patch-drift` in neutral wording

**Step 4: Run YAML verification**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file("/home/dev/projects/opencode-patched/.github/workflows/sync-vim-pr.yml"); YAML.load_file("/home/dev/projects/opencode-patched/.github/workflows/sync-tool-fix-pr.yml"); puts "ok"'
```

Expected: `ok`

**Step 5: Commit**

```bash
git -C /home/dev/projects/opencode-patched add .github/workflows/sync-vim-pr.yml .github/workflows/sync-tool-fix-pr.yml
git -C /home/dev/projects/opencode-patched commit -m "fix: standardize patch drift detection"
```

### Task 2: Align issue language and maintenance docs in `opencode-patched`

**Files:**
- Modify: `opencode-patched/README.md`

**Step 1: Write the failing documentation checklist**

Checklist:

- README distinguishes drift from breakage
- maintenance text says drift is review-only unless apply/build fails
- terminology matches workflow labels

**Step 2: Update the README minimally**

Adjust maintenance sections so they describe:

- drift workflow as early warning
- build workflow as publication truth
- patch breakage as a separate condition

**Step 3: Verify the wording by reading the updated section**

Run:

```bash
grep -n "When the Vim PR Updates\|When the Tool Fix PR Updates\|When the Vim Patch Breaks\|When the Tool Fix Patch Breaks" /home/dev/projects/opencode-patched/README.md
```

Expected: wording clearly separates review drift from breakage.

**Step 4: Commit**

```bash
git -C /home/dev/projects/opencode-patched add README.md
git -C /home/dev/projects/opencode-patched commit -m "docs: clarify patch drift versus breakage"
```

### Task 3: Align `opencode-cached` monitoring language with the same signal model

**Files:**
- Modify: `opencode-cached/README.md`
- Modify: `opencode-cached/.github/workflows/build-release.yml`
- Inspect: `opencode-cached/.github/workflows/check-upstream-caching.yml`

**Step 1: Write the failing expectation checklist**

Checklist:

- `opencode-cached` docs describe build failure as release-blocking
- monitoring docs do not overstate upstream changes as guaranteed breakage
- issue wording uses consistent terms with `opencode-patched`

**Step 2: Inspect the current failure and monitoring wording**

Run:

```bash
grep -n "build-failure\|Patch Breaks\|Automated Monitoring\|sunset" /home/dev/projects/opencode-cached/README.md /home/dev/projects/opencode-cached/.github/workflows/build-release.yml /home/dev/projects/opencode-cached/.github/workflows/check-upstream-caching.yml
```

Expected: identify wording changes needed without changing release logic.

**Step 3: Apply minimal wording updates**

Update docs/messages to say:

- build failure blocks release
- upstream status checks are review signals
- equivalent-upstream detection is not itself a failed build

**Step 4: Verify workflow YAML parses**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file("/home/dev/projects/opencode-cached/.github/workflows/build-release.yml"); YAML.load_file("/home/dev/projects/opencode-cached/.github/workflows/check-upstream-caching.yml"); puts "ok"'
```

Expected: `ok`

**Step 5: Commit**

```bash
git -C /home/dev/projects/opencode-cached add README.md .github/workflows/build-release.yml .github/workflows/check-upstream-caching.yml
git -C /home/dev/projects/opencode-cached commit -m "docs: separate patch monitoring from release failures"
```

### Task 4: Update `workstation` pipeline language for consumers

**Files:**
- Modify: `workstation/docs/plans/2026-03-20-opencode-patched-repo.md`
- Modify: any relevant `workstation` docs/comments that currently imply upstream drift equals broken consumption

**Step 1: Write the failing documentation checklist**

Checklist:

- workstation docs say published releases are what matter to consumers
- docs explain drift vs conflict vs release availability
- language matches patch repos

**Step 2: Search for pipeline wording that conflates signals**

Run:

```bash
grep -Rni "opencode-patched\|drift\|build failure\|release" /home/dev/projects/workstation/docs /home/dev/projects/workstation/users /home/dev/projects/workstation/.github
```

Expected: identify docs/comments worth aligning.

**Step 3: Apply minimal doc/comment updates**

Keep the behavior unchanged; only fix terminology and expectations.

**Step 4: Verify the updated references**

Run:

```bash
grep -Rni "drift\|conflict\|release availability" /home/dev/projects/workstation/docs /home/dev/projects/workstation/users /home/dev/projects/workstation/.github
```

Expected: at least one clear consumer-facing explanation exists.

**Step 5: Commit**

```bash
git -C /home/dev/projects/workstation add docs users .github
git -C /home/dev/projects/workstation commit -m "docs: clarify patch pipeline signals"
```

### Task 5: End-to-end verification

**Files:**
- Verify only

**Step 1: Check diffs in all three repos**

Run:

```bash
git -C /home/dev/projects/opencode-patched status --short
git -C /home/dev/projects/opencode-cached status --short
git -C /home/dev/projects/workstation status --short
```

Expected: only intended files are modified.

**Step 2: Parse all changed workflow YAML files**

Run:

```bash
ruby -e 'require "yaml"; %w[
/home/dev/projects/opencode-patched/.github/workflows/sync-vim-pr.yml
/home/dev/projects/opencode-patched/.github/workflows/sync-tool-fix-pr.yml
/home/dev/projects/opencode-cached/.github/workflows/build-release.yml
/home/dev/projects/opencode-cached/.github/workflows/check-upstream-caching.yml
].each { |p| YAML.load_file(p) }; puts "ok"'
```

Expected: `ok`

**Step 3: Spot-check issue wording and docs**

Read the updated issue body text and maintenance sections to confirm:

- drift = review
- conflict/build failure = blocked
- workstation tracks published releases, not upstream drift directly

**Step 4: Commit final remaining docs/workflow edits if needed**

```bash
git add -A
git commit -m "chore: align patch pipeline alert semantics"
```
