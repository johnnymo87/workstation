#!/usr/bin/env bash
# Tests for trunk-drift-detector (bead workstation-v03j.9).
#
# This suite exists because the worktree-guard epic has repeatedly shipped
# controls that did not control: a plugin that never loaded on any process, a
# warning that false-positived on every repo, and a test suite that set fail=1
# inside subshells and therefore could never go red. Every assertion below is
# written to be MUTATION-CHECKABLE -- break the detector, the named test must
# fail -- and asserts the REASON the detector printed, not merely its exit code.
#
#   1. stranded commit on trunk               -> paged (ahead leg)
#   2. stranded commit, NO upstream           -> detected. Pins contract 3: the
#                                                obvious `@{u}..HEAD` form
#                                                returns 0 here, which is the
#                                                exact shape of the pigeon
#                                                incident. Mutate the detector
#                                                back to @{u} and this must go
#                                                red while test 1 still passes.
#   3. parked on a PUSHED feature branch      -> silent. `origin/<trunk>..HEAD`
#                                                would false-positive here.
#   4. on trunk, tracked file modified        -> reported (dirty leg)
#   5. on trunk, UNTRACKED files only         -> silent. The mono fixture: mono
#                                                is permanently dirty with
#                                                untracked droppings, and an
#                                                unfiltered count makes the
#                                                channel wallpaper. Mutate the
#                                                filter to count '??' -> red.
#   6. on trunk, submodule pointer moved only -> silent (mono's other permanent
#                                                dirt: a ` M` submodule entry).
#   7. feature branch + tracked dirt, nothing -> silent. Pins the dirty leg to
#      stranded                                  trunk only, deliberately.
#   8. linked worktree (.git is a FILE)       -> not scanned at all. Worktrees
#                                                are where work is SUPPOSED to
#                                                happen.
#   9. unborn HEAD / no remote-tracking refs  -> skipped with a named state, no
#                                                crash. The no-remote guard is
#                                                load-bearing: without it
#                                                `--not --remotes` excludes
#                                                nothing and every commit in
#                                                history reads as stranded.
#  10. detached HEAD with a stranded commit   -> reported.
#  11. alert fired per drifting repo, and NOT fired for a clean fleet
#  12. signature is stable across runs, and CHANGES when a new commit strands.
#      Dirt is a boolean in the signature: a live editing session must not mint
#      a new signature (and defeat the backoff) on every save.
#  13. zero primary roots scanned             -> exit 1 + vacuity alert. A
#                                                detector that scanned nothing
#                                                otherwise prints a perfectly
#                                                healthy report.
#  14. unreachable remote                     -> still reports, does not hang.
#                                                Pins contract 2 (no fetch).
#  15. TDD_IGNORE_REPOS                       -> honoured (escape hatch works).
#  16. READ-ONLY CONTRACT: every fixture's HEAD, porcelain status and .git/index
#      bytes are identical before and after a full run.
#  17. a repo whose git is unusable           -> reported as ERROR, never
#                                                silently counted clean.
#
# Run: bash test-trunk-drift-detector.sh

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="${TDD_TEST_TARGET:-$SCRIPT_DIR/trunk-drift-detector}"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT does not exist or is not executable." >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
: > "$GIT_CONFIG_GLOBAL"
git config --global init.defaultBranch main
git config --global protocol.file.allow always

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

# The alert stub. Records one line per call: <state-suffix-basename>\t<signature>\t<text>.
ALERT_STUB="$TMP_ROOT/alert-stub"
# The shebang is computed, not literal: `nix flake check` runs this in a sandbox
# with no /usr/bin/env, where a `#!/usr/bin/env bash` stub silently fails to
# exec and every alert assertion below reads as "no alert sent". Found by the
# flake check on the first run -- a stub that cannot run is the same class of
# bug as a control that cannot fire.
{
  printf '#!%s\n' "$(command -v bash)"
  cat <<'STUB'
{ printf '%s\t%s\t%s\n' "$(basename "$1")" "$2" "$(printf '%s' "$3" | tr '\n' ' ')"; } >> "$ALERT_LOG"
exit 0
STUB
} > "$ALERT_STUB"
chmod +x "$ALERT_STUB"

# --- fixture helpers ---------------------------------------------------------

new_projects_dir() { # new_projects_dir <case>  -> echoes the dir
  local d="$TMP_ROOT/$1/projects"
  mkdir -p "$d"
  printf '%s' "$d"
}

mk_repo() { # mk_repo <projects_dir> <name>  -- clone with one pushed commit on main
  local projects="$1" name="$2"
  local origin="$projects/../origins/$name.git"
  mkdir -p "$(dirname "$origin")"
  git init -q --bare -b main "$origin"
  git clone -q "$origin" "$projects/$name" 2>/dev/null
  (
    cd "$projects/$name"
    echo base > tracked.txt
    git add tracked.txt
    git commit -qm base
    git push -q origin main 2>/dev/null
    git remote set-head origin main >/dev/null 2>&1
  )
}

commit_local() { # commit_local <repo> <msg>  -- a commit that is never pushed
  ( cd "$1"; echo "$2" >> tracked.txt; git add tracked.txt; git commit -qm "$2" )
}

run_detector() { # run_detector <projects_dir> <state_dir> [env assignments...]
  local projects="$1" state="$2"; shift 2
  RUN_RC=0
  RUN_OUT="$(env ALERT_LOG="$state/alerts.log" \
    TDD_PROJECTS_DIR="$projects" \
    TDD_STATE_DIR="$state" \
    TDD_ALERT_CMD="$ALERT_STUB" \
    "$@" \
    bash "$SCRIPT" 2>&1)" || RUN_RC=$?
}

alerts_for() { # alerts_for <state_dir>  -- echoes the alert log (may be empty)
  cat "$1/alerts.log" 2>/dev/null || true
}

# `grep -c` with no match exits 1; wrap so errexit does not eat the assertion.
count_matching() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

# --- 1. stranded commit with an upstream ------------------------------------

p="$(new_projects_dir t1)"; s="$TMP_ROOT/t1/state"
mk_repo "$p" alpha
commit_local "$p/alpha" stranded
run_detector "$p" "$s"
check "1: exits 0 despite drift (drift is a report, not an error)" "0" "$RUN_RC"
check "1: names the drifting repo" "1" "$(count_matching "$RUN_OUT" '^trunk-drift: DRIFT alpha ')"
check "1: reason names the stranded commits" "1" "$(count_matching "$RUN_OUT" "exist on no remote")"

# --- 2. stranded commit on a branch with NO upstream ------------------------
# The bead's own prescribed check (`rev-list --count '@{u}..HEAD' || echo 0`)
# reports 0 here. That is the pigeon incident: a commit on a local branch that
# was never pushed. Mutating the detector back to the @{u} form must fail THIS
# test while test 1 keeps passing.

p="$(new_projects_dir t2)"; s="$TMP_ROOT/t2/state"
mk_repo "$p" beta
( cd "$p/beta"; git checkout -q -b orphan-work )   # no upstream at all
commit_local "$p/beta" stranded-no-upstream
run_detector "$p" "$s"
check "2: no-upstream branch with a local commit is DETECTED" \
  "1" "$(count_matching "$RUN_OUT" '^trunk-drift: WIP beta ')"
check "2: the branch has no upstream (fixture sanity)" "1" \
  "$( ( cd "$p/beta"; git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 ) && echo 0 || echo 1 )"

# --- 2b. named feature branch: detected, recorded, NOT paged ----------------
# Measured on the real fleet: 11 of 65 primary roots held unpushed commits on a
# named feature branch. Paging those makes the channel wallpaper on day one --
# the exact outcome this bead was written to avoid -- and they are the least
# invisible class, because the branch name is right there in `git branch`.

p="$(new_projects_dir t2b)"; s="$TMP_ROOT/t2b/state"
mk_repo "$p" wiprepo
( cd "$p/wiprepo"; git checkout -q -b feature; git push -q -u origin feature 2>/dev/null )
commit_local "$p/wiprepo" wip
run_detector "$p" "$s"
check "2b: feature-branch WIP is reported in the journal" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: WIP wiprepo ')"
check "2b: and named as unpushed work-in-progress" "1" \
  "$(count_matching "$RUN_OUT" 'unpushed work-in-progress, not paged')"
check "2b: but nothing is sent" "" "$(alerts_for "$s")"
check "2b: and it is still counted in the run summary" "1" \
  "$(count_matching "$RUN_OUT" '1 with unpushed WIP on a feature branch')"

# --- 3. parked on a pushed feature branch -----------------------------------

p="$(new_projects_dir t3)"; s="$TMP_ROOT/t3/state"
mk_repo "$p" gamma
( cd "$p/gamma"; git checkout -q -b feature; echo x >> tracked.txt; git commit -qam feat; git push -q -u origin feature 2>/dev/null )
run_detector "$p" "$s"
check "3: a pushed feature branch at the root is NOT drift" "0" "$(count_matching "$RUN_OUT" 'DRIFT gamma')"
check "3: it is reported OK" "1" "$(count_matching "$RUN_OUT" '^trunk-drift: OK gamma ')"

# --- 4. on trunk with a tracked modification --------------------------------

p="$(new_projects_dir t4)"; s="$TMP_ROOT/t4/state"
mk_repo "$p" delta
( cd "$p/delta"; echo edited >> tracked.txt )
run_detector "$p" "$s"
check "4: tracked dirt on trunk is reported" "1" "$(count_matching "$RUN_OUT" '^trunk-drift: DRIFT delta ')"
check "4: reason names writable work in a shared root" "1" \
  "$(count_matching "$RUN_OUT" 'writable work in a shared root')"

# --- 5. on trunk with UNTRACKED dirt only (the mono fixture) ----------------

p="$(new_projects_dir t5)"; s="$TMP_ROOT/t5/state"
mk_repo "$p" mono
( cd "$p/mono"; touch dropping1.log dropping2.log; mkdir -p junk; touch junk/a )
run_detector "$p" "$s"
check "5: untracked-only dirt does NOT alert (mono stays silent)" "0" "$(count_matching "$RUN_OUT" 'DRIFT mono')"
check "5: but the untracked count is still RECORDED" "1" "$(count_matching "$RUN_OUT" 'untracked=3')"
check "5: nothing was sent" "" "$(alerts_for "$s")"

# --- 6. on trunk with only a moved submodule pointer ------------------------

p="$(new_projects_dir t6)"; s="$TMP_ROOT/t6/state"
mk_repo "$p" withsub
subsrc="$TMP_ROOT/t6/subsrc"
git init -q -b main "$subsrc"
( cd "$subsrc"; echo one > f; git add f; git commit -qm one )
(
  cd "$p/withsub"
  git submodule add -q "$subsrc" sub 2>/dev/null
  git commit -qm "add sub"
  git push -q origin main 2>/dev/null
)
( cd "$subsrc"; echo two > f; git commit -qam two )
( cd "$p/withsub/sub"; git fetch -q origin main 2>/dev/null; git checkout -q "$( cd "$subsrc" && git rev-parse HEAD )" 2>/dev/null || true )
run_detector "$p" "$s"
check "6: a moved submodule pointer alone is not reported" "0" "$(count_matching "$RUN_OUT" 'DRIFT withsub')"

# --- 7. feature branch + tracked dirt, nothing stranded ---------------------

p="$(new_projects_dir t7)"; s="$TMP_ROOT/t7/state"
mk_repo "$p" epsilon
( cd "$p/epsilon"; git checkout -q -b feature; git push -q -u origin feature 2>/dev/null; echo edited >> tracked.txt )
run_detector "$p" "$s"
check "7: dirty leg is trunk-only by design" "0" "$(count_matching "$RUN_OUT" 'DRIFT epsilon')"

# --- 8. linked worktrees are not scanned ------------------------------------

p="$(new_projects_dir t8)"; s="$TMP_ROOT/t8/state"
mk_repo "$p" zeta
# A linked worktree placed as a sibling under ~/projects (the shape that would
# be scanned if the .git-is-a-directory test were wrong), with drift in it.
( cd "$p/zeta"; git worktree add -q "$p/zeta-wt" -b wt-branch >/dev/null 2>&1 )
( cd "$p/zeta-wt"; echo w >> tracked.txt; git commit -qam "worktree work" )
run_detector "$p" "$s"
check "8: a linked worktree is never reported" "0" "$(count_matching "$RUN_OUT" 'zeta-wt')"
check "8: the primary root itself is still scanned" "1" "$(count_matching "$RUN_OUT" '^trunk-drift: OK zeta ')"

# --- 9. unborn HEAD and no-remote repos -------------------------------------

p="$(new_projects_dir t9)"; s="$TMP_ROOT/t9/state"
git init -q -b main "$p/unborn"
git init -q -b main "$p/localonly"
( cd "$p/localonly"; echo a > f; git add f; git commit -qm a; echo b > f; git commit -qam b )
run_detector "$p" "$s"
check "9: unborn HEAD is skipped, not crashed on" "1" "$(count_matching "$RUN_OUT" 'no commits yet')"
check "9: a repo with no remote-tracking refs is skipped" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: SKIP localonly: no remote-tracking refs')"
check "9: and therefore does NOT page for its whole history" "" "$(alerts_for "$s")"
check "9: exit 0" "0" "$RUN_RC"

# --- 10. detached HEAD with a stranded commit -------------------------------

p="$(new_projects_dir t10)"; s="$TMP_ROOT/t10/state"
mk_repo "$p" eta
( cd "$p/eta"; git checkout -q --detach; echo d >> tracked.txt; git commit -qam "detached work" )
run_detector "$p" "$s"
check "10: a stranded commit on a detached HEAD is reported" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: DRIFT eta ')"
check "10: the branch renders as (detached)" "1" "$(count_matching "$RUN_OUT" "branch '(detached)'")"

# --- 11. alerting: per repo on drift, silence when clean --------------------

p="$(new_projects_dir t11)"; s="$TMP_ROOT/t11/state"
mk_repo "$p" one; mk_repo "$p" two; mk_repo "$p" three
commit_local "$p/one" stranded
commit_local "$p/two" stranded
run_detector "$p" "$s"
check "11: one alert per drifting repo" "2" "$(count_matching "$(alerts_for "$s")" '^alert\.')"
check "11: state files are per-repo" "1" "$(count_matching "$(alerts_for "$s")" '^alert\.one\.state')"
check "11: the clean repo is not alerted" "0" "$(count_matching "$(alerts_for "$s")" 'three')"

p="$(new_projects_dir t11b)"; s="$TMP_ROOT/t11b/state"
mk_repo "$p" clean1; mk_repo "$p" clean2
run_detector "$p" "$s"
check "11: a clean fleet sends nothing at all" "" "$(alerts_for "$s")"
check "11: and says how many roots it scanned (not a silent no-op)" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: scanned 2 primary root')"

# --- 12. signature stability and change -------------------------------------

p="$(new_projects_dir t12)"; s="$TMP_ROOT/t12/state"
mk_repo "$p" theta
commit_local "$p/theta" stranded
run_detector "$p" "$s"
sig1="$(alerts_for "$s" | head -1 | cut -f2)"
run_detector "$p" "$s"
sig2="$(alerts_for "$s" | tail -1 | cut -f2)"
check "12: same drift -> identical signature (backoff can hold)" "$sig1" "$sig2"

# A save in a live editing session must not mint a new signature.
( cd "$p/theta"; echo more >> tracked.txt )
run_detector "$p" "$s"
sig3="$(alerts_for "$s" | tail -1 | cut -f2)"
( cd "$p/theta"; echo evenmore >> tracked.txt; echo other > tracked2.txt; git add tracked2.txt )
run_detector "$p" "$s"
sig4="$(alerts_for "$s" | tail -1 | cut -f2)"
check "12: dirt is a boolean in the signature, not a count" "$sig3" "$sig4"

commit_local "$p/theta" second-stranded
run_detector "$p" "$s"
sig5="$(alerts_for "$s" | tail -1 | cut -f2)"
check "12: a NEW stranded commit changes the signature (pages immediately)" \
  "differs" "$( [ "$sig5" != "$sig3" ] && echo differs || echo same )"

# --- 13. vacuity tripwire ----------------------------------------------------

p="$(new_projects_dir t13)"; s="$TMP_ROOT/t13/state"
run_detector "$p" "$s"
check "13: scanning zero primary roots exits NONZERO" "1" "$RUN_RC"
check "13: and says the detector is blind, not the fleet clean" "1" \
  "$(count_matching "$RUN_OUT" 'the detector is blind')"
check "13: and pages" "1" "$(count_matching "$(alerts_for "$s")" '^alert\.__vacuous\.state')"

# --- 14. no fetch: an unreachable remote changes nothing --------------------

p="$(new_projects_dir t14)"; s="$TMP_ROOT/t14/state"
mk_repo "$p" iota
commit_local "$p/iota" stranded
( cd "$p/iota"; git remote set-url origin "$TMP_ROOT/does-not-exist.git" )
start="$(date +%s)"
run_detector "$p" "$s"
elapsed=$(( $(date +%s) - start ))
check "14: still reported with an unreachable remote (no fetch)" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: DRIFT iota ')"
check "14: and did not stall on the network" "fast" \
  "$( [ "$elapsed" -lt 10 ] && echo fast || echo "slow:$elapsed" )"

# --- 15. the ignore escape hatch --------------------------------------------

p="$(new_projects_dir t15)"; s="$TMP_ROOT/t15/state"
mk_repo "$p" kappa
commit_local "$p/kappa" stranded
run_detector "$p" "$s" TDD_IGNORE_REPOS=kappa
check "15: TDD_IGNORE_REPOS suppresses a repo" "0" "$(count_matching "$RUN_OUT" 'DRIFT kappa')"
check "15: and says so out loud" "1" "$(count_matching "$RUN_OUT" 'SKIP kappa: in TDD_IGNORE_REPOS')"
check "15: an ignored repo does not count toward the vacuity floor" "1" "$RUN_RC"

# --- 16. read-only contract --------------------------------------------------
# Walking ~40 shared trees is only acceptable if the walk cannot perturb them.
# This checks HEAD, porcelain output AND .git/index bytes -- `git status` will
# opportunistically rewrite the index stat cache without --no-optional-locks.

p="$(new_projects_dir t16)"; s="$TMP_ROOT/t16/state"
mk_repo "$p" ro1; mk_repo "$p" ro2
commit_local "$p/ro1" stranded
( cd "$p/ro2"; echo edited >> tracked.txt; touch untracked.txt )

# Deliberately STALE the stat cache in every fixture (same content, new mtime).
# Without this the index leg below is vacuous: a `git status` that has nothing
# to refresh writes nothing either way, so the missing --no-optional-locks
# survives the test. This is the "fixture that makes the operation fail anyway"
# trap the epic already paid for once, inverted. The sleep is load-bearing too:
# a file whose mtime is not strictly older than the index's is "racily clean",
# and git declines to rewrite the index for it -- which also makes the leg
# vacuous. Verified by mutation: without the sleep, dropping --no-optional-locks
# survives this test.
sleep 1.1
for r in "$p"/*; do
  [ -d "$r/.git" ] || continue
  find "$r" -path "$r/.git" -prune -o -type f -print0 | xargs -0 touch
done
# Pure file reads -- no git command, which would itself refresh the index.
snapshot_index() {
  local out="" r
  for r in "$p"/*; do
    [ -d "$r/.git" ] || continue
    out="$out$r:$(md5sum < "$r/.git/index" 2>/dev/null || echo noindex)"$'\n'
  done
  printf '%s' "$out"
}
idx_before="$(snapshot_index)"
run_detector "$p" "$s"
idx_after="$(snapshot_index)"
check "16: the walk does not rewrite a peer's index (--no-optional-locks)" \
  "$idx_before" "$idx_after"

snapshot_content() {
  local out="" r
  for r in "$p"/*; do
    [ -d "$r/.git" ] || continue
    out="$out$(git -C "$r" rev-parse HEAD)|$(git -C "$r" status --porcelain | sort | tr '\n' ';')"$'\n'
  done
  printf '%s' "$out"
}
before="$(snapshot_content)"
run_detector "$p" "$s"
after="$(snapshot_content)"
check "16: HEAD and working-tree state are unchanged by a full run" "$before" "$after"

# --- 17. a broken repo is an ERROR, never a silent pass ---------------------

p="$(new_projects_dir t17)"; s="$TMP_ROOT/t17/state"
mk_repo "$p" healthy
mkdir -p "$p/broken/.git"          # looks like a primary root, is not a repo
run_detector "$p" "$s"
check "17: an unusable repo is reported as an error" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: ERROR broken: not a usable git repo')"
check "17: errors get their own page" "1" \
  "$(count_matching "$(alerts_for "$s")" '^alert\.__errors\.state')"
check "17: the alert says UNKNOWN, not clean" "1" \
  "$(count_matching "$(alerts_for "$s")" 'UNKNOWN, not clean')"
check "17: the healthy repo is still scanned in the same run" "1" \
  "$(count_matching "$RUN_OUT" '^trunk-drift: OK healthy ')"

# --- status.json + history --------------------------------------------------

p="$(new_projects_dir t18)"; s="$TMP_ROOT/t18/state"
mk_repo "$p" lambda
commit_local "$p/lambda" stranded
run_detector "$p" "$s"
run_detector "$p" "$s"
check "18: status.json records the drift count" "1" \
  "$(count_matching "$(cat "$s/status.json")" '"drift_count": 1')"
check "18: history is append-only, one line per repo per run" "2" \
  "$(wc -l < "$s/history.ndjson" | tr -d ' ')"
check "18: history carries the untracked count for the .11 churn baseline" "2" \
  "$(count_matching "$(cat "$s/history.ndjson")" '"untracked":')"

if [ "$fail" -ne 0 ]; then
  echo "trunk-drift-detector: FAILURES"
  exit 1
fi

echo "trunk-drift-detector: ALL PASS"
