#!/usr/bin/env bash
# Unit and integration tests for the `work` git-worktree helper.
#
# Run: bash test.sh
set -o errexit -o nounset -o pipefail

# ---- helpers under test (mirror of default.nix) -----------------------------

resolve_primary_root() {
  local dir
  dir="$(realpath "$1")"
  if [[ "$dir" =~ ^"${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
    printf '%s/projects/%s\n' "$HOME" "${BASH_REMATCH[1]}"
  else
    local common_dir
    if common_dir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"; then
      if [[ "$common_dir" != /* ]]; then
        common_dir="$dir/$common_dir"
      fi
      realpath "$(dirname "$common_dir")"
    else
      printf 'ERROR: not inside a git repository\n' >&2
      return 1
    fi
  fi
}

sanitize_branch() {
  local slug="$1"
  printf '%s\n' "$slug" | sed -E 's/[^A-Za-z0-9._/-]/-/g'
}

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
# Setup scratch temp directory
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Extract the script from default.nix for end-to-end testing
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
work_script="$tmpdir/work"

if [ -f "$default_nix" ]; then
  # Extract block inside text = '' and unescape Nix '' strings
  sed -n "/text = ''/,/^  '';/p" "$default_nix" | sed "1d;\$d" | sed "s/''//g" > "$work_script"
  chmod +x "$work_script"
else
  # Write a dummy placeholder that fails so we can watch it fail
  printf '#!/usr/bin/env bash\necho "Script not implemented yet"\nexit 1\n' > "$work_script"
  chmod +x "$work_script"
fi

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
# We expect success
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

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
