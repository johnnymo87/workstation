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

# -----------------------------------------------------------------------------
# Identity check (workstation-e2xj).
#
# The fixtures above cannot exercise it: this suite exports GIT_AUTHOR_EMAIL and
# points GIT_CONFIG_GLOBAL at /dev/null, so every repo made by make_repo has NO
# file identity and the check fails open. That is a real behaviour worth pinning
# (test 9d), but it would also have left the check with ZERO coverage while all
# eight tests above stayed green -- so these fixtures build their own global
# config file and drop the environment identity.
# -----------------------------------------------------------------------------
ID_HOME="$TMP_DIR/idhome"
mkdir -p "$ID_HOME"
cat > "$ID_HOME/gitconfig" <<'EOF'
[user]
	email = real@example.com
	name = Real Person
EOF

# make_id_repo <name> -- like make_repo, but with a FILE identity (via
# GIT_CONFIG_GLOBAL) and no GIT_AUTHOR_* in the environment, and in a linked
# worktree so the primary-root check cannot mask the identity result.
make_id_repo() {
  local r="$TMP_DIR/$1"
  mkdir -p "$r"
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_GLOBAL="$ID_HOME/gitconfig" git -C "$r" init -q -b main
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_GLOBAL="$ID_HOME/gitconfig" git -C "$r" commit -q --allow-empty -m "initial commit"
  git -C "$r" config core.hooksPath "$HOOK_DIR"
  echo "$r"
}

# id_commit <repo> <extra git args...> -- commit with the file identity in
# scope and no environment identity, so only what the caller passes can vary.
id_commit() {
  local r="$1"; shift
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    GIT_CONFIG_GLOBAL="$ID_HOME/gitconfig" git -C "$r" "$@" 2>&1
}

# Test 9a: a plain commit under the file identity is ACCEPTED.
r="$(make_id_repo idplain)"
git -C "$r" worktree add -q "$TMP_DIR/idplain-wt" -b work >/dev/null 2>&1
before="$(count "$TMP_DIR/idplain-wt")"
set +e
output="$(id_commit "$TMP_DIR/idplain-wt" commit -q --allow-empty -m "honest commit")"
exit_code=$?
set -e
check "Identity: plain commit under file identity succeeds" "0" "$exit_code"
check "Identity: plain commit landed" "$((before + 1))" "$(count "$TMP_DIR/idplain-wt")"

# Test 9b: `-c user.email=` is REFUSED. This is the exact shape that put 21
# `dev@localhost` commits on this repo's main.
before="$(count "$TMP_DIR/idplain-wt")"
set +e
output="$(id_commit "$TMP_DIR/idplain-wt" -c user.email=dev@localhost -c user.name=dev \
  commit -q --allow-empty -m "synthetic identity")"
exit_code=$?
set -e
check "Identity: -c user.email commit rejected" "1" "$exit_code"
check "Identity: -c user.email commit did not land" "$before" "$(count "$TMP_DIR/idplain-wt")"
contains "Identity: refusal names the offending address" "refusing to commit as <dev@localhost>" "$output"
contains "Identity: refusal lists the configured identity" "real@example.com" "$output"
contains "Identity: refusal offers --amend --reset-author" "--amend --reset-author" "$output"
contains "Identity: refusal names --no-verify as the hatch" "--no-verify" "$output"

# Test 9c: the same injection through GIT_CONFIG_COUNT is also REFUSED.
# `-c` is not the only channel into `command` scope, and an agent that finds the
# flag blocked has an obvious next thing to try.
set +e
output="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=dev@localhost \
  id_commit "$TMP_DIR/idplain-wt" commit -q --allow-empty -m "env-injected identity")"
exit_code=$?
set -e
check "Identity: GIT_CONFIG_COUNT injection rejected" "1" "$exit_code"
# Exit 1 alone is near-vacuous here: a malformed GIT_CONFIG_* env makes git exit
# 128, which would pass the check above while proving nothing about this hook.
contains "Identity: GIT_CONFIG_COUNT refusal came from this check" \
  "refusing to commit as <dev@localhost>" "$output"

# Test 9c2: the refusal must name the PRESERVE case and forbid "fixing" it.
# An author email that is not in the config file is not necessarily synthetic --
# amend/reword/cherry-pick carry the ORIGINAL author, so a colleague's address
# trips this guard while being entirely correct. An agent told only about
# --reset-author would rewrite their authorship onto the human, which is this
# guard's own failure mode in reverse and worse (it is a live person's credit).
contains "Identity: refusal names the preserved-author case" "belongs to SOMEONE ELSE" "$output"
contains "Identity: refusal warns against --reset-author there" "would steal" "$output"

# Test 9d: FAIL-OPEN when the repo has no file identity at all. A throwaway
# `git init` fixture is exactly where an inline identity is the RIGHT answer,
# and this is also why the eight tests above still pass unchanged.
r="$(make_repo idnofile)"
git -C "$r" worktree add -q "$TMP_DIR/idnofile-wt" -b work >/dev/null 2>&1
before="$(count "$TMP_DIR/idnofile-wt")"
set +e
env -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL=/dev/null \
  git -C "$TMP_DIR/idnofile-wt" -c user.email=throwaway@example.com -c user.name=Throwaway \
  commit -q --allow-empty -m "fixture commit" >/dev/null 2>&1
exit_code=$?
set -e
check "Identity: fail-open with no file identity (throwaway repo)" "0" "$exit_code"
check "Identity: throwaway commit landed" "$((before + 1))" "$(count "$TMP_DIR/idnofile-wt")"

# Test 9e: a LOCAL file identity is accepted even when it differs from the
# global one. mono commits as a work address while global is the personal one;
# an allow-set of "global only" would have blocked every commit there.
r="$(make_id_repo idlocal)"
git -C "$r" config user.email local@example.com
git -C "$r" worktree add -q "$TMP_DIR/idlocal-wt" -b work >/dev/null 2>&1
before="$(count "$TMP_DIR/idlocal-wt")"
set +e
id_commit "$TMP_DIR/idlocal-wt" commit -q --allow-empty -m "local identity" >/dev/null
exit_code=$?
set -e
check "Identity: local-scope identity accepted" "0" "$exit_code"
check "Identity: local-scope commit landed" "$((before + 1))" "$(count "$TMP_DIR/idlocal-wt")"

# Test 9g: KNOWN FALSE POSITIVE -- amending a commit authored by someone else
# is REFUSED, because `git commit --amend` PRESERVES the original author and the
# hook cannot tell a preserved colleague from an invented address. Pinned rather
# than fixed: `--no-verify` is the hatch, and the refusal message is what has to
# carry the distinction (asserted in 9c2). Narrowing the check to skip
# "author == HEAD author" would also skip a second synthetic commit stacked on a
# first one, which is the case this guard exists for.
r="$(make_id_repo idforeign)"
git -C "$r" worktree add -q "$TMP_DIR/idforeign-wt" -b work >/dev/null 2>&1
id_commit "$TMP_DIR/idforeign-wt" commit -q --allow-empty --no-verify \
  --author="Peer <peer@example.org>" -m "colleague's commit" >/dev/null
check "Identity: fixture commit is authored by the colleague" "peer@example.org" \
  "$(git -C "$TMP_DIR/idforeign-wt" log -1 --format='%ae')"
set +e
output="$(id_commit "$TMP_DIR/idforeign-wt" commit --amend --no-edit)"
exit_code=$?
set -e
check "KNOWN FALSE POSITIVE: amending a colleague's commit is refused" "1" "$exit_code"
contains "KNOWN FALSE POSITIVE: refusal names the colleague's address" \
  "refusing to commit as <peer@example.org>" "$output"

# Test 9f: KNOWN BYPASS -- `-c core.hooksPath=` disables the hook entirely, for
# the identity check exactly as for the root check. Pinned so it is not
# rediscovered as a surprise.
before="$(count "$TMP_DIR/idplain-wt")"
set +e
id_commit "$TMP_DIR/idplain-wt" -c core.hooksPath=/dev/null \
  -c user.email=dev@localhost -c user.name=dev commit -q --allow-empty -m "bypass" >/dev/null
exit_code=$?
set -e
check "KNOWN BYPASS: -c core.hooksPath disables the identity check" "0" "$exit_code"
check "KNOWN BYPASS: hooksPath-bypassed commit landed" "$((before + 1))" "$(count "$TMP_DIR/idplain-wt")"

if [ "$fail" -eq 0 ]; then
  echo "=== All tests PASSED ==="
  exit 0
else
  echo "=== Some tests FAILED ==="
  exit 1
fi
