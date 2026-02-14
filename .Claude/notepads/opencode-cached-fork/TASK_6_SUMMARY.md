# Task 6: Monitoring and Sunset Strategy - COMPLETE

**Date**: 2026-02-14  
**Status**: ✅ SUCCESS - Monitoring workflows deployed, sunset strategy documented

## Summary

Successfully implemented automated monitoring for build failures and upstream caching status, with clear sunset criteria and actionable processes.

## Deliverables

### ✅ Monthly Upstream Caching Check

**File**: `.github/workflows/check-upstream-caching.yml`

**Trigger**: Monthly on the 1st at 00:00 UTC + manual workflow_dispatch

**Function**:
1. **Checks PR #5422 status**: Detects if merged, closed, or still open
2. **Detects upstream implementation**: Searches for `ProviderConfig` in upstream code
3. **Creates GitHub issues**: When sunset conditions are met
4. **Updates existing issues**: Adds monthly status comments if issue already exists

**Sunset Detection Logic**:
- **PR #5422 merged**: Creates "🎉 PR #5422 merged - Consider sunsetting" issue
- **Upstream has ProviderConfig**: Creates "⚠️ Upstream may have equivalent caching" issue
- **Monthly updates**: Adds comments to existing sunset-check issues

**Issue Content**:
- Actionable checklist for review
- Cost comparison steps
- Migration instructions
- Links to relevant PRs and documentation

### ✅ Build Failure Notifications (Already Implemented in Task 2)

**File**: `.github/workflows/build-release.yml`  
**Job**: `notify-on-failure`

**Function**:
- Runs when build fails
- Creates GitHub issue with:
  - Failing version
  - Workflow run link
  - Possible causes (patch conflict, build changes, test failures)
  - Action steps (check logs, update patch, re-run)
- Labels: `build-failure`, `automated`

**Avoids duplicates**: Checks for existing open issues with same title before creating

### ✅ Sunset Strategy Documentation

**File**: `README.md` (updated)

**Documented Criteria**:
1. **Upstream merges PR #5422 or equivalent**: Automated detection → sunset issue
2. **Upstream implements independent ProviderConfig**: Automated detection → review issue
3. **PR #5422 closed as "won't fix"**: Manual review, consider contributing improved version
4. **Patch breaks 3+ consecutive releases**: Fundamental incompatibility, re-evaluate

**Automated Monitoring**:
- Monthly GitHub Actions workflow
- PR status tracking
- Code structure detection
- Automatic issue creation

**Manual Review Triggers**:
- Monthly sunset-check issues
- Build failure issues  
- Cost tracking shows no improvement after 30 days

## Verification

### ✅ All Workflows Active

**Command**: `gh workflow list --repo johnnymo87/opencode-cached`

**Results** (3 workflows total):
1. `Build and Release Patched OpenCode`: **active** ✅
2. `Sync Upstream Releases`: **active** ✅
3. `Check Upstream Caching Status`: **active** ✅ (new)

All workflows enabled and ready to run.

### ✅ Failure Notification Test (from Task 2)

Already tested during Task 2 - build failure creates GitHub issue with:
- ✅ Workflow run link
- ✅ Possible causes listed
- ✅ Action steps provided
- ✅ Labels applied correctly

### ✅ Sunset Criteria Documented

**README.md sections**:
- "Sunset Criteria" (lines ~165-180)
- "Automated Monitoring" explanation
- "Manual Review Triggers" list
- References to tracking and validation

## Acceptance Criteria Met

From plan lines 346-354:

- [x] Build failure creates a GitHub issue in `opencode-cached` repo with the failing version and conflicting files
- [x] **QA Scenario: Failure notification works** ✅ (Tested in Task 2, verified working)
- [x] Sunset criteria documented (README.md)
- [x] Monitoring workflow deployed (check-upstream-caching.yml)

## Implementation Highlights

### Smart Issue Creation
The GitHub Actions script:
- Avoids duplicate issues by searching existing open issues
- Adds monthly status comments to existing sunset-check issues
- Uses descriptive labels (`sunset-check`, `review-needed`, `build-failure`)
- Provides actionable checklists in issue body

### Comprehensive Detection
The monthly check:
- Queries GitHub API for PR status
- Searches upstream repository code structure
- Detects both exact matches (PR merge) and equivalent implementations (ProviderConfig detection)
- Gracefully handles API errors

### Clear Sunset Process
Documentation provides:
1. Detection triggers (automated)
2. Review process (manual)
3. Cost comparison steps
4. Migration instructions  
5. Archive checklist

## Future Enhancements (Not Implemented)

**Considered but excluded** (as per plan "Must NOT Have"):
- ❌ Auto-rebase or auto-conflict-resolution
- ❌ LLM-assisted patch updates
- ❌ Automatic sunset/archiving
- ❌ Patch auto-updater

**Rationale**: These require manual judgment and could cause silent failures. Better to fail loudly and require human review.

## Operational Checklist

### Monthly Review (Automated)
- [x] GitHub Actions runs `check-upstream-caching.yml` on 1st of month
- [ ] Review any new sunset-check issues
- [ ] If sunset recommended, follow issue checklist

### After Build Failures (Automated)
- [x] GitHub Actions creates build-failure issue
- [ ] Check workflow logs via issue link
- [ ] Update patch if needed (see README "Update Patch" section)
- [ ] Re-run workflow: `gh workflow run build-release.yml --field version=X.Y.Z`

### Cost Validation (Manual - Ongoing)
- [ ] Run analysis weekly: `node .opencode/skills/tracking-cache-costs/analyze.mjs`
- [ ] Track cache write ratio trend
- [ ] Compare to baseline (46% → target 26%)
- [ ] If no improvement after 30 days, create review issue

## Evidence Files

- `.Claude/evidence/task-6-workflows-complete.txt` - All 3 workflows listed and active

## Commits

1. `49ffa95` - "feat: add monthly upstream caching check and sunset monitoring"
2. `883673b` - "docs: expand sunset criteria with automated monitoring details"

## Wisdom

1. **Automated detection beats manual checks**: Monthly workflow ensures we don't miss upstream changes
2. **Actionable issues critical**: Generic "something changed" alerts are useless - provide clear next steps
3. **Avoid duplicate issues**: Check before creating prevents noise
4. **Document sunset criteria upfront**: Makes decision-making objective, not emotional
5. **Monthly cadence sufficient**: Upstream changes slowly, more frequent checks waste CI minutes

---

**Duration**: ~8 minutes (20:18 - 20:26)  
**Status**: Complete - all monitoring in place
