# Patch Pipeline False Positive Design

## Goal

Reduce noisy or misleading patch-pipeline alerts across `opencode-cached`, `opencode-patched`, and `workstation` so drift warnings reflect real review needs and build failures reflect real release risk.

## Problem

The current patch pipeline mixes multiple concepts:

- upstream PR diff drift
- patch apply conflicts
- build failures
- release availability

That overlap caused a false positive in `opencode-patched`: `sync-vim-pr.yml` compared a filtered upstream diff against an unfiltered stored patch, so the workflow reported drift even though the patch stack was still healthy.

## Design

### 1. Use a two-signal model in patch repos

Patch repos should distinguish:

- `patch-drift`: upstream source changed relative to the stored patch file
- `patch-conflict`: the patch no longer applies cleanly to the intended base version

This keeps "review needed" separate from "pipeline broken".

### 2. Compare like-to-like artifacts only

For all locally stored PR-backed patches:

- store raw patch files in-repo
- compare raw upstream PR diffs to raw stored patch files
- do not compare filtered upstream diffs to unfiltered stored files

If filtering is ever required, both sides must be filtered by the same logic before comparison.

### 3. Keep release/build truth separate from drift truth

Release workflows remain the source of truth for whether a version can be published.

- drift workflow answers: "did upstream change?"
- build workflow answers: "can we publish this version?"

Drift should not imply breakage.

### 4. Standardize issue wording and labels

Across patch repos, use consistent labels and tone:

- `patch-drift`: calm review request
- `patch-conflict`: patch no longer applies cleanly
- `build-failure`: release blocked

Issue bodies should include:

- compared artifact names
- hash values where relevant
- changed-file summary if easy to provide
- exact manual recovery command

### 5. Mirror terminology into workstation

`workstation` should describe the pipeline using the same concepts:

- upstream drift does not necessarily block anything
- only published releases affect workstation updates
- patch conflicts/build failures are the true blockers

## Scope

### `opencode-patched`

- normalize `sync-vim-pr.yml` and `sync-tool-fix-pr.yml`
- optionally introduce a shared helper script if it reduces duplication cleanly
- update `README.md` maintenance language

### `opencode-cached`

- align failure/monitoring language with the same signal model
- keep build failure handling, but avoid conflating it with generic drift
- update `README.md` maintenance language

### `workstation`

- update relevant comments/docs so release consumers understand the difference between drift, conflict, and release availability

## Non-Goals

- automatic patch refresh commits
- auto-merging upstream PR changes without review
- changing the release cadence

## Verification

After implementation:

- workflow YAML parses cleanly
- PR-backed patch workflows compare raw-to-raw consistently
- issue wording distinguishes drift vs conflict vs build failure
- workstation docs reflect release-centric consumption
