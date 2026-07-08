#!/usr/bin/env bash
# Unit/integration tests for the git worktree-guard pre-commit hook.
#
# Asserts:
# 1. Commits in the primary worktree are REJECTED with the proper message.
# 2. Commits in a linked worktree (added via `git worktree add`) SUCCEED.
# 3. Running the hook outside of a git repository (or unexpected state) fails OPEN (exits 0).
#
# Run: bash test-pre-commit.sh

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK_FILE="$SCRIPT_DIR/pre-commit"

# Ensure hook file exists and is executable
if [ ! -x "$HOOK_FILE" ]; then
  echo "FAIL: Hook file $HOOK_FILE does not exist or is not executable." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    echo "  expected: [$2]"
    echo "  actual:   [$3]"
    fail=1
  fi
}

echo "=== Running Worktree-Guard Hook Tests ==="

# -----------------------------------------------------------------------------
# Test 1: Reject commits in the primary worktree
# -----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/primary"
(
  cd "$TMP_DIR/primary"
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  
  # Hook is NOT active yet because core.hooksPath is unset. Initial commit must succeed.
  git commit -q --allow-empty -m "initial commit"
  
  # Configure core.hooksPath to point to the directory containing pre-commit
  git config core.hooksPath "$SCRIPT_DIR"
  
  # Attempting to commit now should fail
  set +e
  output="$(git commit -q --allow-empty -m "violating commit" 2>&1)"
  exit_code=$?
  set -e
  
  check "Primary worktree commit rejected exit code" "1" "$exit_code"
  
  # Verify error message contains worktree-guard refusal
  if [[ "$output" == *"worktree-guard: refusing to commit in the primary root"* ]]; then
    echo "ok: Primary worktree commit rejected with correct warning"
  else
    echo "FAIL: Primary worktree commit did not display expected refusal warning"
    echo "  output was: [$output]"
    fail=1
  fi
)

# -----------------------------------------------------------------------------
# Test 2: Allow commits in linked worktree
# -----------------------------------------------------------------------------
(
  cd "$TMP_DIR/primary"
  git worktree add -q "$TMP_DIR/child"
)
(
  cd "$TMP_DIR/child"
  # Linked worktrees inherit core.hooksPath from the repository config.
  # Commit in child worktree should succeed.
  set +e
  output="$(git commit -q --allow-empty -m "allowed commit" 2>&1)"
  exit_code=$?
  set -e
  
  check "Linked worktree commit succeeds exit code" "0" "$exit_code"
)

# -----------------------------------------------------------------------------
# Test 3: Fail-open outside of a git repository
# -----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/nongit"
(
  cd "$TMP_DIR/nongit"
  set +e
  "$HOOK_FILE"
  exit_code=$?
  set -e
  
  check "Non-git repository run fails OPEN (exits 0)" "0" "$exit_code"
)

if [ "$fail" -eq 0 ]; then
  echo "=== All tests PASSED ==="
  exit 0
else
  echo "=== Some tests FAILED ==="
  exit 1
fi
