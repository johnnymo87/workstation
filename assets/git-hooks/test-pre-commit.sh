#!/usr/bin/env bash
# Unit/integration tests for the git worktree-guard pre-commit hook.
#
# Asserts, against a throwaway repo (never against a real one):
# 1. Commits in the primary worktree are REJECTED, with a message that names
#    BOTH escape hatches (copy-the-diff-forward, and --no-verify).
# 2. Commits in a linked worktree SUCCEED.
# 3. Running outside a git repository fails OPEN (exits 0).
# 4. The measured bypass matrix (see the 2026-08-11 design doc, section 2.3) is
#    pinned as KNOWN, so it is not rediscovered as a surprise. cherry-pick,
#    merge and rebase all land commits on trunk without the hook firing. The
#    merge bypass is LOAD-BEARING -- `git pull` at a deploy root depends on it --
#    so test 7 fails if that bypass is ever accidentally closed.
#
# Run: bash test-pre-commit.sh

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# WORKTREE_GUARD_HOOK_DIR points at a directory containing `pre-commit`. It
# exists so this suite can run as a nix check, and it is a DIRECTORY rather than
# a file because git's core.hooksPath (set per-fixture below) takes one.
#
# Unset, the suite tests the asset sitting next to it, exactly as before. The
# check sets it to pkgs/worktree-guard-hook, which is the same artifact
# home-manager deploys to cloudbox -- so CI exercises the deployed hook rather
# than a copy adapted for the sandbox. That distinction matters here: the raw
# asset shebangs /bin/bash, which does not exist in a nix sandbox (nor,
# declaredly, anywhere in this repo), so a suite pointed at the asset cannot run
# as a check at all.
HOOK_DIR="${WORKTREE_GUARD_HOOK_DIR:-$SCRIPT_DIR}"
HOOK_FILE="$HOOK_DIR/pre-commit"

# Hermetic: ignore the invoking user's global/system git config. Without this a
# global core.hooksPath, commit.gpgsign or hook manager silently changes results.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com"

if [ ! -x "$HOOK_FILE" ]; then
  echo "FAIL: Hook file $HOOK_FILE does not exist or is not executable." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# NOTE: assertions must run in THIS shell, never inside a ( subshell ) -- a
# subshell's assignment to `fail` is discarded, which silently made every
# failure in this suite exit 0. Use `git -C` instead of `cd`.
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

contains() { # contains <desc> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    echo "  expected to contain: [$2]"
    echo "  actual:              [$3]"
    fail=1
  fi
}

# make_repo <name> -- a primary repo with the guard ACTIVE on main, plus a
# `side` branch and a `feature` branch built BEFORE the guard was switched on.
make_repo() {
  local r="$TMP_DIR/$1"
  mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" commit -q --allow-empty -m "initial commit"

  git -C "$r" checkout -q -b side
  echo side > "$r/side.txt"
  git -C "$r" add side.txt
  git -C "$r" commit -q -m "side commit"

  git -C "$r" checkout -q -b feature main
  echo feat > "$r/feat.txt"
  git -C "$r" add feat.txt
  git -C "$r" commit -q -m "feature commit"

  git -C "$r" checkout -q main
  # HEAD on main must be a NON-EMPTY commit. With an empty one, `git revert
  # HEAD` fails all by itself ("nothing to commit"), which made test 6 pass
  # even with the hook neutered -- a vacuous test of exactly the kind this
  # whole epic exists to avoid.
  echo main > "$r/main.txt"
  git -C "$r" add main.txt
  git -C "$r" commit -q -m "main advances"

  # Guard goes live only now, so the fixtures above are not themselves blocked.
  git -C "$r" config core.hooksPath "$HOOK_DIR"
  echo "$r"
}

count() { git -C "$1" rev-list --count HEAD; }

echo "=== Running Worktree-Guard Hook Tests ==="

# -----------------------------------------------------------------------------
# Test 1: Reject commits in the primary worktree
# -----------------------------------------------------------------------------
r="$(make_repo primary)"
before="$(count "$r")"
set +e
output="$(git -C "$r" commit -q --allow-empty -m "violating commit" 2>&1)"
exit_code=$?
set -e
check "Primary worktree commit rejected exit code" "1" "$exit_code"
check "Primary worktree commit did not land" "$before" "$(count "$r")"
contains "Refusal names the guard" "worktree-guard: refusing to commit in the primary root" "$output"

# -----------------------------------------------------------------------------
# Test 1b: The refusal must offer a real escape hatch (workstation-v03j.10).
# `work <slug>` alone is a dead end for someone who ALREADY has uncommitted work
# at the root -- which is the exact state of the incident that motivated this.
# An agent blocked without an obvious hatch invents a worse one.
# -----------------------------------------------------------------------------
contains "Refusal offers a fresh worktree" "work <slug>" "$output"
# `diff HEAD`, not bare `diff`: a bare `git diff` silently omits STAGED work,
# and the person hitting this hook has usually just run `git add`.
contains "Refusal offers copy-the-diff-forward including staged work" "diff HEAD" "$output"
contains "Refusal warns that untracked files are not in the diff" "Untracked files are NOT" "$output"
contains "Refusal names --no-verify as the supported hotfix hatch" "--no-verify" "$output"

# -----------------------------------------------------------------------------
# Test 2: Allow commits in a linked worktree (core.hooksPath is inherited)
# -----------------------------------------------------------------------------
git -C "$r" worktree add -q "$TMP_DIR/child" side
set +e
output="$(git -C "$TMP_DIR/child" commit -q --allow-empty -m "allowed commit" 2>&1)"
exit_code=$?
set -e
check "Linked worktree commit succeeds exit code" "0" "$exit_code"

# -----------------------------------------------------------------------------
# Test 3: Fail-open outside of a git repository
# -----------------------------------------------------------------------------
mkdir -p "$TMP_DIR/nongit"
set +e
( cd "$TMP_DIR/nongit" && exec "$HOOK_FILE" ) >/dev/null 2>&1
exit_code=$?
set -e
check "Non-git repository run fails OPEN (exits 0)" "0" "$exit_code"

# -----------------------------------------------------------------------------
# Test 4: --no-verify bypasses. This is the INTENDED escape hatch, not a defect.
# -----------------------------------------------------------------------------
r="$(make_repo noverify)"
before="$(count "$r")"
set +e
git -C "$r" commit -q --no-verify --allow-empty -m "hotfix at root" >/dev/null 2>&1
exit_code=$?
set -e
check "--no-verify commit succeeds (intended hatch)" "0" "$exit_code"
check "--no-verify commit landed" "$((before + 1))" "$(count "$r")"

# -----------------------------------------------------------------------------
# Test 5: KNOWN BYPASS -- cherry-pick lands a commit on trunk, hook never fires.
# -----------------------------------------------------------------------------
r="$(make_repo cherrypick)"
before="$(count "$r")"
set +e
git -C "$r" cherry-pick side >/dev/null 2>&1
exit_code=$?
set -e
check "KNOWN BYPASS: cherry-pick at primary root succeeds" "0" "$exit_code"
check "KNOWN BYPASS: cherry-pick landed a commit on trunk" "$((before + 1))" "$(count "$r")"

# -----------------------------------------------------------------------------
# Test 6: KNOWN BYPASS -- `git revert` also lands a commit without the hook.
#
# CORRECTION: the 2026-08-11 design doc section 2.3 recorded revert as
# "blocked". That was a measurement artifact -- it was measured against an
# --allow-empty HEAD, where `git revert` fails on its own with "nothing to
# commit", which looks identical to a hook refusal from the outside. Against a
# NON-EMPTY HEAD the hook never fires at all (verified: 0 occurrences of
# "worktree-guard" in the output, and the commit lands). revert belongs with
# cherry-pick/merge/rebase, not with plain commit.
# -----------------------------------------------------------------------------
r="$(make_repo revert)"
before="$(count "$r")"
set +e
output="$(git -C "$r" revert --no-edit HEAD 2>&1)"
exit_code=$?
set -e
check "KNOWN BYPASS: revert at primary root succeeds" "0" "$exit_code"
check "KNOWN BYPASS: revert landed a commit on trunk" "$((before + 1))" "$(count "$r")"
if [[ "$output" == *"worktree-guard"* ]]; then
  echo "FAIL: hook unexpectedly fired during revert; the section 2.3 table needs updating again"
  fail=1
else
  echo "ok: KNOWN BYPASS: hook does not fire for revert"
fi

# -----------------------------------------------------------------------------
# Test 7: LOAD-BEARING BYPASS -- merge commits do not run pre-commit.
# `git pull` / `git merge --ff-only` at a deploy root depend on this. If this
# test ever fails, someone has closed the bypass and BROKEN DEPLOYS; that is
# why it is asserted rather than left undocumented. See design doc section 4
# (the pre-merge-commit hook was rejected for exactly this reason).
# -----------------------------------------------------------------------------
r="$(make_repo merge)"
before="$(count "$r")"
set +e
git -C "$r" merge --no-ff --no-edit side >/dev/null 2>&1
exit_code=$?
set -e
check "LOAD-BEARING BYPASS: merge at primary root succeeds" "0" "$exit_code"
if [ "$(count "$r")" -gt "$before" ]; then
  echo "ok: LOAD-BEARING BYPASS: merge landed a commit on trunk (git pull must keep working)"
else
  echo "FAIL: merge did not land a commit -- the deploy-critical merge path is broken"
  fail=1
fi

# -----------------------------------------------------------------------------
# Test 8: KNOWN BYPASS -- rebase replays commits onto trunk without pre-commit.
# -----------------------------------------------------------------------------
r="$(make_repo rebase)"
git -C "$r" checkout -q feature
set +e
git -C "$r" rebase main >/dev/null 2>&1
exit_code=$?
set -e
check "KNOWN BYPASS: rebase at primary root succeeds" "0" "$exit_code"

if [ "$fail" -eq 0 ]; then
  echo "=== All tests PASSED ==="
  exit 0
else
  echo "=== Some tests FAILED ==="
  exit 1
fi
