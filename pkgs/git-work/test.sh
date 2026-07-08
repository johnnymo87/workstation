#!/usr/bin/env bash
# Unit and integration tests for the `work` git-worktree helper.
#
# Run: bash test.sh
set -o errexit -o nounset -o pipefail

# Find the project root and build the latest package
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/../.." && pwd)"

echo "Building package to test the real, built binary..."
(cd "$project_root" && nix build .#git-work)

work_script="$project_root/result/bin/work"
if [ ! -f "$work_script" ]; then
  echo "FAIL: Built script not found at $work_script"
  exit 1
fi

# Source the real production script to load helper functions without executing main()
source "$work_script"

# ---- test infrastructure ----------------------------------------------------

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'PASS: %s\n' "$1"
  else
    printf 'FAIL: %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# ---- Unit Tests: sanitize_branch --------------------------------------------
check "sanitize: pure alphanumeric" "my-branch" "$(sanitize_branch "my-branch")"
check "sanitize: spaces to hyphens" "my-cool-feature" "$(sanitize_branch "my cool feature")"
check "sanitize: special chars" "feat/abc-123_test" "$(sanitize_branch "feat/abc#123_test")"
check "sanitize: mixed special chars" "a-b-c-d.e_f" "$(sanitize_branch "a!b@c#d.e_f")"

# ---- Unit Tests: resolve_primary_root ---------------------------------------
# Stub out HOME so it's deterministic for our projects match test
ORIG_HOME="$HOME"
export HOME="/home/dev"

check "resolve_primary_root: project root" \
  "/home/dev/projects/workstation" \
  "$(resolve_primary_root "/home/dev/projects/workstation")"

check "resolve_primary_root: project worktree subdir" \
  "/home/dev/projects/workstation" \
  "$(resolve_primary_root "/home/dev/projects/workstation/.worktrees/worktree-guard/pkgs")"

export HOME="$ORIG_HOME"

# ---- Integration/End-to-End Tests -------------------------------------------
# Setup scratch temp directory under /tmp (which is pre-approved for temp work)
tmpdir="$(mktemp -d "/tmp/git-work-test-XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

# Set up fake remote (bare repo) and clone it
bare_repo="$tmpdir/origin.git"
git init --bare "$bare_repo"

clone_dir="$tmpdir/my-repo"
git clone "$bare_repo" "$clone_dir"

# Commit to origin so there's a HEAD and refs
cd "$clone_dir"
git config user.name "Test User"
git config user.email "test@example.com"
touch README.md
git add README.md
git commit -m "initial commit"
git push origin main

# Configure origin/HEAD
git remote set-head origin -a

# Test 1: Happy path - create a new worktree
cd "$clone_dir"
set +e
output_stdout="$(mktemp)"
output_stderr="$(mktemp)"
"$work_script" "feature1" >"$output_stdout" 2>"$output_stderr"
rc=$?
set -e

stdout_content="$(cat "$output_stdout")"
stderr_content="$(cat "$output_stderr")"
rm -f "$output_stdout" "$output_stderr"

check "Happy path exit code is 0" "0" "$rc"
check "Happy path printed new worktree absolute path" "$clone_dir/.worktrees/feature1" "$stdout_content"
if [[ "$stderr_content" == *"[work] Fetching latest origin/main"* ]] && [[ "$stderr_content" == *"[work] Adding worktree for branch 'feature1'"* ]]; then
  echo "PASS: Happy path printed correct logs to stderr"
else
  echo "FAIL: Happy path missing correct logs on stderr. Got: [$stderr_content]"
  fail=1
fi

# Verify the worktree actually exists and is on the correct branch
check "Worktree directory exists" "1" "$([ -d "$clone_dir/.worktrees/feature1" ] && echo 1 || echo 0)"
branch_in_wt="$(git -C "$clone_dir/.worktrees/feature1" branch --show-current)"
check "Worktree is on the correct branch" "feature1" "$branch_in_wt"

# Test 2: Creating from INSIDE an existing worktree
cd "$clone_dir/.worktrees/feature1"
set +e
output_stdout="$(mktemp)"
"$work_script" "feature2" >"$output_stdout" 2>/dev/null
rc=$?
set -e
stdout_content="$(cat "$output_stdout")"
rm -f "$output_stdout"

check "Worktree from within worktree exit code is 0" "0" "$rc"
check "Worktree from within worktree path is under primary root" "$clone_dir/.worktrees/feature2" "$stdout_content"
check "Feature2 directory exists" "1" "$([ -d "$clone_dir/.worktrees/feature2" ] && echo 1 || echo 0)"

# Test 2.5: Test 'worktree prune' robust fallback
# If we manually delete the directory for feature2 using rm -rf, git worktree still lists feature2 as a registered worktree.
# Running worktree add with slug feature2 would normally fail because git thinks the worktree is still there.
# However, the 'git worktree prune' command inside 'work' cleans this up automatically!
# Note that we must also delete the local branch 'feature2' because the script prevents duplicate branch names.
# We must prune the worktree in git first so git knows the branch is no longer checked out anywhere, allowing us to delete it.
rm -rf "$clone_dir/.worktrees/feature2"
git -C "$clone_dir" worktree prune
git -C "$clone_dir" branch -D feature2 >/dev/null 2>&1 || true
cd "$clone_dir"
set +e
output_stdout="$(mktemp)"
# This should succeed because of the 'git worktree prune' call before the collision check
"$work_script" "feature2" >"$output_stdout" 2>/dev/null
rc=$?
set -e
stdout_content="$(cat "$output_stdout")"
rm -f "$output_stdout"

check "Pruned worktree recreation exit code is 0" "0" "$rc"
check "Pruned worktree path is correct" "$clone_dir/.worktrees/feature2" "$stdout_content"
check "Feature2 directory was recreated" "1" "$([ -d "$clone_dir/.worktrees/feature2" ] && echo 1 || echo 0)"

# Test 3: Existing slug/worktree folder fails
cd "$clone_dir"
set +e
output_stderr="$(mktemp)"
"$work_script" "feature1" 2>"$output_stderr" >/dev/null
rc=$?
set -e
stderr_content="$(cat "$output_stderr")"
rm -f "$output_stderr"

if [ "$rc" -ne 0 ]; then
  echo "PASS: Duplicate slug failed with non-zero exit code"
else
  echo "FAIL: Duplicate slug did not fail"
  fail=1
fi
if [[ "$stderr_content" == *"Worktree directory already exists"* ]]; then
  echo "PASS: Duplicate slug error message is clear and loud"
else
  echo "FAIL: Duplicate slug error message not found. Got: [$stderr_content]"
  fail=1
fi

# Test 4: Existing branch fails
# Delete the worktree folder feature2, but keep its branch 'feature2' in git
git worktree remove --force "$clone_dir/.worktrees/feature2" || true
# Now try to create a worktree with slug "feature2" again. It should fail because branch "feature2" already exists.
set +e
output_stderr="$(mktemp)"
"$work_script" "feature2" 2>"$output_stderr" >/dev/null
rc=$?
set -e
stderr_content="$(cat "$output_stderr")"
rm -f "$output_stderr"

if [ "$rc" -ne 0 ]; then
  echo "PASS: Duplicate branch failed with non-zero exit code"
else
  echo "FAIL: Duplicate branch did not fail"
  fail=1
fi
if [[ "$stderr_content" == *"Branch 'feature2' already exists"* ]]; then
  echo "PASS: Duplicate branch error message is clear and loud"
else
  echo "FAIL: Duplicate branch error message not found. Got: [$stderr_content]"
  fail=1
fi

# Test 5: --cd contract
cd "$clone_dir"
set +e
output_stdout="$(mktemp)"
output_stderr="$(mktemp)"
"$work_script" --cd "feature3" >"$output_stdout" 2>"$output_stderr"
rc=$?
set -e
stdout_content="$(cat "$output_stdout")"
stderr_content="$(cat "$output_stderr")"
rm -f "$output_stdout" "$output_stderr"

check "--cd exit code is 0" "0" "$rc"
# It should print exactly 'cd /path/to/feature3'
if [[ "$stdout_content" == cd\ *"/feature3"* ]]; then
  echo "PASS: --cd printed cd command"
else
  echo "FAIL: --cd output incorrect. Got: [$stdout_content]"
  fail=1
fi

# Test 6: Unset origin/HEAD exits with loud actionable error
# Remove refs/remotes/origin/HEAD
git symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
set +e
output_stderr="$(mktemp)"
"$work_script" "feature4" 2>"$output_stderr" >/dev/null
rc=$?
set -e
stderr_content="$(cat "$output_stderr")"
rm -f "$output_stderr"

if [ "$rc" -ne 0 ]; then
  echo "PASS: Unset origin/HEAD failed"
else
  echo "FAIL: Unset origin/HEAD did not fail"
  fail=1
fi
if [[ "$stderr_content" == *"Could not determine the trunk branch from origin/HEAD"* ]] && [[ "$stderr_content" == *"git -C"* ]]; then
  echo "PASS: Unset origin/HEAD error is loud and actionable"
else
  echo "FAIL: Unset origin/HEAD error message incorrect. Got: [$stderr_content]"
  fail=1
fi

# ---- Phase 3.5 additions: --no-fetch, best-effort fetch, --prune-merged ------
# These use a FRESH bare+clone so they don't inherit the mutated state above
# (origin/HEAD was deleted by Test 6).
fresh_bare="$tmpdir/origin2.git"
git init --bare "$fresh_bare"
fresh_clone="$tmpdir/repo2"
git clone "$fresh_bare" "$fresh_clone"
cd "$fresh_clone"
git config user.name "Test User"
git config user.email "test@example.com"
touch README.md
git add README.md
git commit -m "initial commit"
git push origin main
git remote set-head origin -a

# Test 7: --no-fetch skips the network fetch but still creates the worktree
cd "$fresh_clone"
set +e
output_stderr="$(mktemp)"
output_stdout="$(mktemp)"
"$work_script" --no-fetch nf1 >"$output_stdout" 2>"$output_stderr"
rc=$?
set -e
stderr_content="$(cat "$output_stderr")"
stdout_content="$(cat "$output_stdout")"
rm -f "$output_stderr" "$output_stdout"
check "--no-fetch exit code is 0" "0" "$rc"
check "--no-fetch created the worktree" "1" "$([ -d "$fresh_clone/.worktrees/nf1" ] && echo 1 || echo 0)"
if [[ "$stderr_content" == *"Skipping fetch"* ]] && [[ "$stderr_content" != *"Fetching latest"* ]]; then
  echo "PASS: --no-fetch skipped the fetch (no 'Fetching latest')"
else
  echo "FAIL: --no-fetch did not skip fetch. Got: [$stderr_content]"
  fail=1
fi

# Test 8: default fetch is BEST-EFFORT -- a broken remote must NOT fail the
# command (M2: degrade, never fail; worktree still built off local origin/main).
cd "$fresh_clone"
git remote set-url origin /nonexistent/path/to/nowhere.git
set +e
output_stderr="$(mktemp)"
output_stdout="$(mktemp)"
"$work_script" besteffort1 >"$output_stdout" 2>"$output_stderr"
rc=$?
set -e
stderr_content="$(cat "$output_stderr")"
stdout_content="$(cat "$output_stdout")"
rm -f "$output_stderr" "$output_stdout"
check "best-effort fetch: exit code still 0 despite broken remote" "0" "$rc"
check "best-effort fetch: worktree still created off local origin/main" "1" "$([ -d "$fresh_clone/.worktrees/besteffort1" ] && echo 1 || echo 0)"
if [[ "$stderr_content" == *"WARNING"* ]] && [[ "$stderr_content" == *"fetch"* ]]; then
  echo "PASS: best-effort fetch warned but proceeded"
else
  echo "FAIL: best-effort fetch missing warning. Got: [$stderr_content]"
  fail=1
fi
# restore a working remote for the prune tests
git remote set-url origin "$fresh_bare"

# Test 9: --prune-merged removes merged+clean launch worktrees, keeps unmerged
# and dirty ones (the safety contract).
cd "$fresh_clone"
# A: fresh worktree, no commits -> tip == origin/main -> merged+clean -> REMOVE
"$work_script" --no-fetch prune-merged-a >/dev/null 2>&1
# B: worktree with an unpushed commit -> unmerged -> KEEP
"$work_script" --no-fetch prune-unmerged-b >/dev/null 2>&1
( cd "$fresh_clone/.worktrees/prune-unmerged-b" && echo x > extra.txt && git add extra.txt && git commit -m "wip" >/dev/null 2>&1 )
# C: fresh worktree with an uncommitted change -> dirty -> KEEP
"$work_script" --no-fetch prune-dirty-c >/dev/null 2>&1
echo "dirty" > "$fresh_clone/.worktrees/prune-dirty-c/uncommitted.txt"

set +e
output_stderr="$(mktemp)"
"$work_script" --prune-merged >"$output_stderr" 2>&1
rc=$?
set -e
prune_out="$(cat "$output_stderr")"
rm -f "$output_stderr"
check "--prune-merged exit code is 0" "0" "$rc"
check "--prune-merged REMOVED merged+clean worktree A" "0" "$([ -d "$fresh_clone/.worktrees/prune-merged-a" ] && echo 1 || echo 0)"
check "--prune-merged KEPT unmerged worktree B" "1" "$([ -d "$fresh_clone/.worktrees/prune-unmerged-b" ] && echo 1 || echo 0)"
check "--prune-merged KEPT dirty worktree C" "1" "$([ -d "$fresh_clone/.worktrees/prune-dirty-c" ] && echo 1 || echo 0)"
# The removed branch should also be gone
check "--prune-merged deleted branch for A" "0" "$(git -C "$fresh_clone" rev-parse --verify refs/heads/prune-merged-a >/dev/null 2>&1 && echo 1 || echo 0)"
check "--prune-merged kept branch for B" "1" "$(git -C "$fresh_clone" rev-parse --verify refs/heads/prune-unmerged-b >/dev/null 2>&1 && echo 1 || echo 0)"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
