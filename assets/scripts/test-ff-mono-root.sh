#!/usr/bin/env bash
# Tests for ff-mono-root: the fast-forward-only auto-updater for the mono
# PRIMARY checkout.
#
# The script exists because ~/projects/mono rots: measured 84 commits behind
# origin/main on 2026-07-08, 175 on 07-27, 272 on 08-03. mono/.agents/skills
# lives in that tree, so a stale checkout serves stale agent skills -- which on
# 2026-08-03 produced a production finding that was 100x wrong.
#
# Every assertion below encodes a hazard that was measured or reasoned about,
# not a hypothetical:
#
#  1. up to date            -> no-op, exit 0
#  2. behind + clean        -> fast-forwards
#  3. behind + UNTRACKED    -> STILL fast-forwards. Regression test for the
#     cruft                    dirty-check trap: the sibling `pull-workstation`
#                              unit opens with `git status --porcelain` and
#                              skips if non-empty. The mono root is permanently
#                              non-empty (8 untracked entries measured
#                              2026-08-04), so copying that check yields a timer
#                              that NEVER runs while logging "not clean" -- a
#                              silent no-op that looks healthy.
#  4. behind + conflicting  -> skips, exit 0, and the local edit SURVIVES. Never
#     tracked edit             reset/stash/clean: the mono root is a SHARED
#                              worktree and peer agent sessions keep uncommitted
#                              data there.
#  5. untracked file that   -> skips, exit 0, untracked file survives. This is
#     collides with an         the forever-skip case; the staleness tripwire
#     incoming tracked path    (test 8) is what makes it visible.
#  6. ahead / diverged      -> skips, exit 0, local commit survives.
#  7. NOT on main           -> skips, exit 0, and the branch ref DOES NOT MOVE.
#                              Without this guard `merge --ff-only origin/main`
#                              while parked on a feature branch fast-forwards
#                              THAT branch onto main's tip whenever it is an
#                              ancestor -- silently relocating someone's branch.
#                              mono's own AGENTS.md says the root is frequently
#                              parked on a feature branch, so this is live.
#  8. stale beyond          -> exit NONZERO so systemd marks the unit failed.
#     threshold                Fail-open on known skips would otherwise let the
#                              root rot forever in silence; this converts a
#                              persistent skip into a visible failure.
#
# Run: bash test-ff-mono-root.sh

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$SCRIPT_DIR/ff-mono-root"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT does not exist or is not executable." >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

# Build an origin + a local clone of it, both with one commit on main.
# Echoes the local clone path. $1 = case name.
setup_case() {
  local name="$1"
  local d="$TMP_ROOT/$name"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/local" 2>/dev/null
  (
    cd "$d/local"
    git config user.email t@t.invalid; git config user.name t
    echo base > base.txt
    git add -A; git commit -qm base; git push -q origin HEAD:main
  )
  echo "$d/local"
}

# Add a commit on origin's main (via a throwaway clone), so the local clone
# falls behind. $1 = case name, $2 = file to write, $3 = contents.
advance_origin() {
  local name="$1" file="$2" body="$3" d="$TMP_ROOT/$1"
  rm -rf "$d/upstream"
  git clone -q "$d/origin.git" "$d/upstream" 2>/dev/null
  (
    cd "$d/upstream"
    git config user.email t@t.invalid; git config user.name t
    printf '%s\n' "$body" > "$file"
    git add -A; git commit -qm "advance: $file"; git push -q origin HEAD:main
  )
}

# Run the script against a repo. Echoes the exit code, and leaves the combined
# output in $OUT_FILE. (It cannot export a variable: callers invoke this inside
# a command substitution, which is a subshell.)
OUT_FILE=""
run_script() { # run_script <repo> [extra env assignments...]
  local repo="$1"; shift
  local rc=0
  OUT_FILE="$TMP_ROOT/last-output.txt"
  # Invoked via `bash "$SCRIPT"` rather than executed directly: this suite runs
  # inside the nix build sandbox, which has no /usr/bin/env for the shebang to
  # resolve. The shebang itself is asserted separately below.
  env MONO_ROOT="$repo" "$@" bash "$SCRIPT" > "$OUT_FILE" 2>&1 || rc=$?
  echo "$rc"
}
OUT_FILE="$TMP_ROOT/last-output.txt"

# Assert the script REPORTED the path it claims to have taken.
#
# Without this, most cases below are vacuous: a stub script whose entire body is
# `exit 0` satisfies every "exits 0 and nothing moved" assertion, because doing
# nothing trivially moves nothing. Pinning the reason string is what makes these
# tests prove the intended branch actually executed.
says() { # says <desc> <extended-regex>
  check "$1" "yes" "$(grep -qiE "$2" "$OUT_FILE" && echo yes || echo no)"
}

echo "=== ff-mono-root tests ==="

# ---------------------------------------------------------------------------
# 0. Deployment shape: systemd runs the file directly, so the shebang and the
#    executable bit are load-bearing even though the cases below invoke it via
#    `bash` to stay sandbox-portable.
# ---------------------------------------------------------------------------
check "0. has a bash shebang" "#!/usr/bin/env bash" "$(head -1 "$SCRIPT")"

# ---------------------------------------------------------------------------
# 1. Already up to date -> no-op, exit 0
# ---------------------------------------------------------------------------
repo="$(setup_case uptodate)"
before="$(git -C "$repo" rev-parse HEAD)"
rc="$(run_script "$repo")"
check "1. up-to-date exits 0" "0" "$rc"
check "1. up-to-date leaves HEAD alone" "$before" "$(git -C "$repo" rev-parse HEAD)"
says  "1. up-to-date says so" "already up to date"

# ---------------------------------------------------------------------------
# 2. Behind + clean -> fast-forwards
# ---------------------------------------------------------------------------
repo="$(setup_case behind)"
advance_origin behind new.txt hello
rc="$(run_script "$repo")"
check "2. behind exits 0" "0" "$rc"
git -C "$repo" fetch -q origin main
check "2. behind fast-forwards to origin/main" \
  "$(git -C "$repo" rev-parse origin/main)" "$(git -C "$repo" rev-parse HEAD)"
check "2. incoming file present" "hello" "$(cat "$repo/new.txt" 2>/dev/null || echo MISSING)"
says  "2. reports the fast-forward" "fast-forwarded to origin/main"

# ---------------------------------------------------------------------------
# 3. Behind + untracked cruft -> STILL fast-forwards (the dirty-check trap)
# ---------------------------------------------------------------------------
repo="$(setup_case cruft)"
advance_origin cruft new.txt hello
mkdir -p "$repo/outputs" "$repo/.codex"
echo junk > "$repo/AGENTS.md"
echo junk > "$repo/outputs/run.log"
echo junk > "$repo/session-ses_06fd.md"
rc="$(run_script "$repo")"
check "3. untracked cruft exits 0" "0" "$rc"
git -C "$repo" fetch -q origin main
check "3. untracked cruft does NOT block the fast-forward" \
  "$(git -C "$repo" rev-parse origin/main)" "$(git -C "$repo" rev-parse HEAD)"
check "3. untracked cruft survives" "junk" "$(cat "$repo/AGENTS.md")"
says  "3. reports the fast-forward" "fast-forwarded to origin/main"

# ---------------------------------------------------------------------------
# 4. Behind + conflicting tracked edit -> skip, exit 0, edit survives
# ---------------------------------------------------------------------------
repo="$(setup_case conflict)"
advance_origin conflict base.txt upstream-version
before="$(git -C "$repo" rev-parse HEAD)"
echo my-uncommitted-work > "$repo/base.txt"
rc="$(run_script "$repo")"
check "4. conflicting edit exits 0 (fail-open)" "0" "$rc"
check "4. conflicting edit blocks the ff (HEAD unmoved)" \
  "$before" "$(git -C "$repo" rev-parse HEAD)"
check "4. peer's uncommitted work SURVIVES" \
  "my-uncommitted-work" "$(cat "$repo/base.txt")"
says  "4. names the refusal" "fast-forward refused"

# ---------------------------------------------------------------------------
# 5. Untracked file colliding with an incoming tracked path -> skip, survives
# ---------------------------------------------------------------------------
repo="$(setup_case collide)"
advance_origin collide notes.md from-upstream
before="$(git -C "$repo" rev-parse HEAD)"
echo local-untracked > "$repo/notes.md"
rc="$(run_script "$repo")"
check "5. untracked collision exits 0" "0" "$rc"
check "5. untracked collision blocks the ff (HEAD unmoved)" \
  "$before" "$(git -C "$repo" rev-parse HEAD)"
check "5. colliding untracked file is NOT overwritten" \
  "local-untracked" "$(cat "$repo/notes.md")"
says  "5. names the refusal" "fast-forward refused"

# ---------------------------------------------------------------------------
# 6. Ahead / diverged -> skip, exit 0, local commit survives
# ---------------------------------------------------------------------------
repo="$(setup_case diverged)"
advance_origin diverged new.txt hello
(
  cd "$repo"
  echo local > local.txt
  git add -A; git commit -qm "local only"
)
before="$(git -C "$repo" rev-parse HEAD)"
rc="$(run_script "$repo")"
check "6. diverged exits 0" "0" "$rc"
check "6. diverged leaves HEAD alone" "$before" "$(git -C "$repo" rev-parse HEAD)"
check "6. local commit survives" "local" "$(cat "$repo/local.txt")"
says  "6. names the divergence" "local commits present"

# ---------------------------------------------------------------------------
# 7. Parked on a feature branch -> skip, and the branch ref MUST NOT MOVE
# ---------------------------------------------------------------------------
repo="$(setup_case featurebranch)"
advance_origin featurebranch new.txt hello
(cd "$repo" && git checkout -q -b feature-x)
before="$(git -C "$repo" rev-parse feature-x)"
rc="$(run_script "$repo")"
check "7. feature branch exits 0" "0" "$rc"
check "7. feature branch ref is NOT fast-forwarded onto main" \
  "$before" "$(git -C "$repo" rev-parse feature-x)"
check "7. still on the feature branch" \
  "feature-x" "$(git -C "$repo" symbolic-ref --short HEAD)"
says  "7. names the branch guard" "not on main"

# Detached HEAD is the same class of hazard.
repo="$(setup_case detached)"
advance_origin detached new.txt hello
(cd "$repo" && git checkout -q --detach HEAD)
before="$(git -C "$repo" rev-parse HEAD)"
rc="$(run_script "$repo")"
check "7. detached HEAD exits 0" "0" "$rc"
check "7. detached HEAD unmoved" "$before" "$(git -C "$repo" rev-parse HEAD)"
says  "7. names detached HEAD" "detached HEAD"

# ---------------------------------------------------------------------------
# 8. Staleness tripwire: a persistent skip must become a VISIBLE failure
# ---------------------------------------------------------------------------
repo="$(setup_case tripwire)"
advance_origin tripwire a.txt one
advance_origin tripwire b.txt two
# The third upstream commit touches base.txt, which is also edited locally
# below -- that is what makes the fast-forward refuse and the repo stay behind.
advance_origin tripwire base.txt upstream-version
# Conflicting edit keeps the ff from landing, so the repo stays behind.
echo my-work > "$repo/base.txt"
rc="$(run_script "$repo" FF_STALE_THRESHOLD=2)"
check "8. stale beyond threshold exits NONZERO (systemd marks unit failed)" "1" "$rc"
# Must match ALERT, not merely "behind": the healthy fail-open line also
# contains "(behind by N)", so grepping "behind" would pass even if the
# tripwire had silently stopped firing.
says  "8. tripwire raises an ALERT" "ALERT"
says  "8. tripwire refuses to self-repair destructively" "do NOT reset"
check "8. tripwire still did not touch the peer's work" \
  "my-work" "$(cat "$repo/base.txt")"

# A healthy repo must NOT trip the wire even with a tiny threshold.
repo="$(setup_case tripwire_ok)"
advance_origin tripwire_ok new.txt hello
rc="$(run_script "$repo" FF_STALE_THRESHOLD=0)"
check "8. successful ff does not trip the wire" "0" "$rc"

# ---------------------------------------------------------------------------
# 9. Missing repo -> fail open, exit 0 (never wedge the timer chain)
# ---------------------------------------------------------------------------
rc="$(run_script "$TMP_ROOT/does-not-exist")"
check "9. missing repo exits 0" "0" "$rc"
says  "9. missing repo says so" "no git repo"

# ---------------------------------------------------------------------------
# 10. Tripwire on the NOT-ON-MAIN path.
#
# Parked-on-a-feature-branch is the most likely real rot mode (mono's AGENTS.md
# says the root is frequently left on one), so the branch guard must not become
# a way to skip quietly forever. `HEAD..origin/main` still measures exactly what
# we care about there -- commits on main absent from the checked-out tree.
# ---------------------------------------------------------------------------
repo="$(setup_case branchtripwire)"
advance_origin branchtripwire new.txt hello
(cd "$repo" && git checkout -q -b feature-y)
rc="$(run_script "$repo" FF_STALE_THRESHOLD=0)"
check "10. stale on a feature branch exits NONZERO" "1" "$rc"
says  "10. alerts rather than skipping quietly" "ALERT"

# ---------------------------------------------------------------------------
# 11. Fetch failure is fatal and visible (not a quiet skip).
#
# The likeliest real cause is credential loss: mono's origin is a PRIVATE https
# remote, gh stores no token on this host, and a systemd user unit inherits no
# login-shell exports -- so a missing GH_TOKEN makes every fetch fail. That must
# surface as a failed unit, never as a healthy-looking no-op.
# ---------------------------------------------------------------------------
repo="$(setup_case fetchfail)"
git -C "$repo" remote set-url origin "$TMP_ROOT/no-such-origin.git"
rc="$(run_script "$repo")"
check "11. unreachable origin exits NONZERO" "1" "$rc"
says  "11. names the fetch failure" "fetch failed"

# ---------------------------------------------------------------------------
# 12. A dirty SUBMODULE POINTER must not block the fast-forward, and the
#     submodule's own checkout must be left alone.
#
# This pins the load-bearing claim behind the decision NOT to run
# `git submodule update` (which can detach or discard work inside a submodule).
# The mono root permanently carries a modified submodule pointer, so if this
# claim were wrong the timer would refuse forever. Previously verified only in a
# throwaway sandbox; encoded here so a change in git's behaviour is caught.
# ---------------------------------------------------------------------------
sub_case="$TMP_ROOT/submodule"
mkdir -p "$sub_case"
git init -q --bare -b main "$sub_case/sub.git"
git clone -q "$sub_case/sub.git" "$sub_case/subwork" 2>/dev/null
(
  cd "$sub_case/subwork"
  git config user.email t@t.invalid; git config user.name t
  echo v1 > f; git add -A; git commit -qm v1
  echo v2 > f; git add -A; git commit -qm v2
  git push -q origin HEAD:main
)
SUB_OLD="$(git -C "$sub_case/subwork" rev-parse HEAD~1)"
SUB_NEW="$(git -C "$sub_case/subwork" rev-parse HEAD)"

repo="$(setup_case submodule_super)"
super_dir="$TMP_ROOT/submodule_super"
(
  cd "$repo"
  git -c protocol.file.allow=always submodule add -q "$sub_case/sub.git" sub 2>/dev/null
  git -C sub checkout -q "$SUB_OLD"
  git add -A; git commit -qm "sub pinned old"; git push -q origin HEAD:main
)
# Origin advances the recorded submodule pointer...
rm -rf "$super_dir/upstream"
git clone -q "$super_dir/origin.git" "$super_dir/upstream" 2>/dev/null
(
  cd "$super_dir/upstream"
  git config user.email t@t.invalid; git config user.name t
  git -c protocol.file.allow=always submodule update -q --init
  git -C sub checkout -q "$SUB_NEW"
  git add -A; git commit -qm "bump sub"; git push -q origin HEAD:main
)
# ...while the local checkout's pointer is dirty, and the submodule working copy
# holds uncommitted work that must survive.
git -C "$repo/sub" checkout -q "$SUB_NEW"
echo peer-work-in-submodule > "$repo/sub/uncommitted.txt"
rc="$(run_script "$repo")"
check "12. dirty submodule pointer exits 0" "0" "$rc"
git -C "$repo" fetch -q origin main
check "12. dirty submodule pointer does NOT block the fast-forward" \
  "$(git -C "$repo" rev-parse origin/main)" "$(git -C "$repo" rev-parse HEAD)"
check "12. submodule's uncommitted work is untouched" \
  "peer-work-in-submodule" "$(cat "$repo/sub/uncommitted.txt" 2>/dev/null || echo MISSING)"

echo
if [ "$fail" -eq 0 ]; then
  echo "All ff-mono-root tests passed."
else
  echo "Some ff-mono-root tests FAILED." >&2
fi
exit "$fail"
