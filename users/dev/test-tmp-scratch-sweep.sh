#!/usr/bin/env bash
# Regression tests for devbox's standalone /tmp scratch sweeper.
# Run: bash users/dev/test-tmp-scratch-sweep.sh
#
# WHY THIS SUITE EXISTS AT ALL. The sweeper's job is `shutil.rmtree` on a
# directory nobody asked it about. Every guard in it was written because the
# guard next to it was once missing: cloudbox's worktree sweeper deleted a LIVE
# opencode session's working directory on 2026-09-01, and an earlier draft of
# the git guard conflated "git cannot read this" with "this has work in it".
# A regression here is not a wrong log line, it is somebody's unpushed branch.
#
# THE SUITE NEVER POINTS THE SWEEPER AT THE REAL /tmp. It drives it through the
# TMP_SCRATCH_ROOTS seam at a fixture tree. That seam exists FOR this: a suite
# that had to seed /tmp with plausible junk would, when run outside a build
# sandbox, be indistinguishable from running the sweeper for real on the
# developer's machine.

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

passes=0
failures=0

pass() { printf 'PASS  %s\n' "$1"; passes=$((passes + 1)); }
fail() {
  printf 'FAIL  %s\n' "$1"
  shift || true
  for line in "$@"; do printf '      %s\n' "$line"; done
  failures=$((failures + 1))
}

assert_gone() {
  local path="$1" msg="$2"
  if [ -e "$path" ]; then
    fail "$msg" "expected removed, still present: $path"
  else
    pass "$msg"
  fi
}

assert_kept() {
  local path="$1" msg="$2"
  if [ -e "$path" ]; then
    pass "$msg"
  else
    fail "$msg" "expected kept, was DELETED: $path"
  fi
}

assert_symlink_intact() {
  local path="$1" msg="$2"
  # -e follows the link, so a symlink whose target was (correctly) swept looks
  # identical to a symlink that was itself deleted. -L asks the real question.
  if [ -L "$path" ]; then
    pass "$msg"
  else
    fail "$msg" "expected the symlink itself to survive: $path"
  fi
}

refute_log() {
  local pattern="$1" msg="$2"
  if grep -Eq -- "$pattern" "$sweep_log"; then
    fail "$msg" "log matched when it should not: $pattern"
  else
    pass "$msg"
  fi
}

assert_log() {
  local pattern="$1" msg="$2" file="${3:-$sweep_log}"
  if grep -Eq -- "$pattern" "$file"; then
    pass "$msg"
  else
    fail "$msg" "log did not match: $pattern" "log: $(tr '\n' '|' < "$file")"
  fi
}

script_src="$tmpdir/tmp-scratch-sweep"

# Same seam, and the same reason, as disk-cleanup-worktree-tests: a flake check
# hands over home-manager's OWN deployed store path, so the suite never invokes
# nix (impossible inside a build sandbox). The fallback is for running this by
# hand from a checkout.
if [ -n "${TMP_SCRATCH_SWEEP_SRC:-}" ]; then
  cp "$TMP_SCRATCH_SWEEP_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.dev.config.home.file.\".local/bin/tmp-scratch-sweep\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty tmp-scratch-sweep source"; exit 1; }
chmod +x "$script_src"

# --- fixture -----------------------------------------------------------------
#
# Sizes are real bytes, not sparse. The sweeper measures with st_blocks, so a
# `truncate -s 4M` file reports ZERO and the size floor would silently reject
# every fixture -- making the whole suite pass by never selecting anything.

root="$tmpdir/faketmp"
nested_root="$root/opencode"
mkdir -p "$nested_root"

old_stamp=202401010000            # far outside any plausible age window
big() { mkdir -p "$1"; dd if=/dev/zero of="$1/payload" bs=1M count=3 status=none; }
age() { find "$1" -exec touch -t "$old_stamp" {} + ; }

# 1. plain abandoned scratch -> goes
big "$root/abandoned"
# 2. old top dir, but something NESTED is recent -> stays. This is the case a
#    naive os.lstat(dir).st_mtime check gets wrong, and it is the reason the
#    sweeper walks.
big "$root/nested-recent/deep/deeper"
# 3. old and abandoned but tiny -> stays (size floor). Stands in for the
#    /tmp/opencode-{frontdoor,serve}-canary state dirs on the real box: 4K
#    each, and deleting them re-arms alerts while reclaiming nothing.
mkdir -p "$root/tiny-canary"; echo state > "$root/tiny-canary/f"
# 4. scratch under the SECOND root -> goes (this is /tmp/opencode/advrev)
big "$nested_root/advrev"
# 5. a git repo with uncommitted work -> stays
big "$root/repo-dirty"
# 6. a git repo with commits that are not on any remote -> stays
big "$root/repo-unpushed"
# 7. a clean, fully-pushed git repo -> goes. Being tidy must not be what gets
#    your tree deleted; being STALE is.
big "$root/repo-clean"
# 8. a live process sitting inside it -> stays even though it is old and big
big "$root/inuse"
# 9. a symlink pointing OUT of the swept roots -> never followed. The target
#    has to live outside, or "we did not follow it" is unfalsifiable: an
#    in-root target is a legitimate candidate in its own right and gets swept
#    on its own merits, which looks exactly like following the link.
big "$tmpdir/outside-target"
ln -s "$tmpdir/outside-target" "$root/a-link"

git_init() {
  git -C "$1" init --quiet --initial-branch=main
  git -C "$1" -c user.email=t@t -c user.name=t add -A
  git -C "$1" -c user.email=t@t -c user.name=t commit --quiet -m init
}
for r in repo-dirty repo-unpushed repo-clean; do git_init "$root/$r"; done

# "pushed" without a network: an adjacent bare repo is a real remote, and
# `git log --branches --not --remotes` is exactly what the sweeper asks.
git init --quiet --bare "$tmpdir/origin.git"
git -C "$root/repo-clean" remote add origin "$tmpdir/origin.git"
git -C "$root/repo-clean" push --quiet origin main
git -C "$root/repo-unpushed" remote add origin "$tmpdir/origin.git"
git -C "$root/repo-unpushed" push --quiet origin main
echo more > "$root/repo-unpushed/later"
git -C "$root/repo-unpushed" -c user.email=t@t -c user.name=t add -A
git -C "$root/repo-unpushed" -c user.email=t@t -c user.name=t commit --quiet -m later
echo scribble > "$root/repo-dirty/uncommitted"

age "$root"
age "$tmpdir/outside-target"
# -h: age the LINK, not what it points at. Without this the symlink's own
# mtime stays `now`, the cheap mtime reject drops it before any guard runs,
# and the symlink assertions below are vacuously true.
touch -h -t "$old_stamp" "$root/a-link"
touch "$root/nested-recent/deep/deeper/payload"   # re-age ONLY the nested file

# Guard 2 needs a process whose cwd is inside the tree. A sleep started there
# is the cheapest honest one; a `cd` in this shell would not work, since the
# sweeper reads /proc/<pid>/cwd and this shell's cwd is the repo.
( cd "$root/inuse" && exec sleep 300 ) &
inuse_pid=$!
trap 'kill "$inuse_pid" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT
# Do not race the sweep against the child's exec: /proc/<pid>/cwd is only
# correct once it is actually running in that directory.
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$inuse_pid/cwd" 2>/dev/null || true)" = "$root/inuse" ] && break
  sleep 0.1
done

# --- run ---------------------------------------------------------------------

sweep_log="$tmpdir/sweep.log"
TMP_SCRATCH_ROOTS="$root $nested_root" \
TMP_SCRATCH_AGE_DAYS=7 \
TMP_SCRATCH_MIN_MB=1 \
  "$script_src" > "$sweep_log" 2>&1 || fail "sweeper exited non-zero" "log: $(cat "$sweep_log")"

# --- assertions --------------------------------------------------------------

assert_gone "$root/abandoned"        "plain abandoned scratch is removed"
assert_gone "$nested_root/advrev"    "scratch under a nested root is removed"
assert_gone "$root/repo-clean"       "clean, fully-pushed repo is removed"

assert_kept "$root/nested-recent"    "tree with a recently-touched NESTED file is kept"
assert_kept "$root/tiny-canary"      "tree below the size floor is kept"
assert_kept "$root/repo-dirty"       "repo with uncommitted work is kept"
assert_kept "$root/repo-unpushed"    "repo with unpushed commits is kept"
assert_kept "$root/inuse"            "tree a live process sits in is kept"
assert_kept "$tmpdir/outside-target" "a tree outside the roots is not reached through a symlink"
assert_symlink_intact "$root/a-link" "the symlink itself is not removed"
# Dropping the islink() test happens to be non-destructive -- rmtree refuses a
# symlink and ignore_errors swallows it -- so the only visible symptom is a log
# line claiming a removal that did not happen. Assert on that, or the guard has
# no test at all.
refute_log 'removed .*a-link' "a symlink is never even a candidate"

assert_log 'keep .*nested-recent .*nested'   "the nested-mtime keep says why"
assert_log 'keep .*inuse .*live process'     "the in-use keep says why"
assert_log 'keep .*repo-dirty .*dirty'       "the dirty keep says why"
assert_log 'keep .*repo-unpushed .*unpushed' "the unpushed keep says why"

# An opencode session's working directory is a ROW, not a process handle: the
# serve holds nothing inside the tree, so /proc cannot see it and the sweeper
# has to ask opencode.db. Two trees, identical to every other guard -- old,
# big, clean, unheld -- separated only by what the database says.
session_db="$tmpdir/opencode.db"
big "$root/session-live"
big "$root/session-live-sub/clone"
big "$root/session-stale"
age "$root/session-live" ; age "$root/session-live-sub" ; age "$root/session-stale"
python3 - "$session_db" "$root" <<'PYEOF'
import sqlite3, sys, time
db, root = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("create table session (id text, directory text, time_updated integer)")
now = int(time.time() * 1000)
con.executemany("insert into session values (?, ?, ?)", [
    ("live", root + "/session-live", now),
    # A session sitting in a SUBDIRECTORY of the candidate. An exact-match
    # query misses this one and deletes the parent out from under it.
    ("live-sub", root + "/session-live-sub/clone", now),
    ("stale", root + "/session-stale", now - 30 * 86400 * 1000),
])
con.commit()
PYEOF

session_log="$tmpdir/session.log"
TMP_SCRATCH_ROOTS="$root" \
TMP_SCRATCH_AGE_DAYS=7 \
TMP_SCRATCH_MIN_MB=1 \
TMP_SCRATCH_SESSION_DB="$session_db" \
  "$script_src" > "$session_log" 2>&1 || fail "session-aware sweep exited non-zero"
assert_kept "$root/session-live"     "tree named by a RECENT opencode session is kept"
assert_kept "$root/session-live-sub" "tree CONTAINING a recent session's directory is kept"
assert_gone "$root/session-stale"    "tree named only by a long-idle session is removed"

# An unreadable database is not the same as "no sessions". Fail safe.
corrupt_db="$tmpdir/corrupt.db"
echo 'this is not a database' > "$corrupt_db"
big "$root/db-unreadable"; age "$root/db-unreadable"
corrupt_log="$tmpdir/corrupt.log"
TMP_SCRATCH_ROOTS="$root" \
TMP_SCRATCH_AGE_DAYS=7 \
TMP_SCRATCH_MIN_MB=1 \
TMP_SCRATCH_SESSION_DB="$corrupt_db" \
  "$script_src" > "$corrupt_log" 2>&1 || fail "corrupt-db sweep exited non-zero"
assert_kept "$root/db-unreadable" "an unreadable session database keeps everything"
assert_log 'session probe failed' "the failed session probe says so" "$corrupt_log"

# Commits on a DETACHED HEAD are on no branch, so `git log --branches` cannot
# see them -- and AGENTS.md's own throwaway-worktree recipe is
# `git worktree add --detach "$(mktemp -d)"`, i.e. detached, in /tmp. Removing
# such a tree takes its reflog with it, so the commits are not merely orphaned,
# they are unreachable.
big "$root/repo-detached"
git_init "$root/repo-detached"
git init --quiet --bare "$tmpdir/detached-origin.git"
git -C "$root/repo-detached" remote add origin "$tmpdir/detached-origin.git"
git -C "$root/repo-detached" push --quiet origin main
git -C "$root/repo-detached" checkout --quiet --detach HEAD
echo work > "$root/repo-detached/only-on-detached-head"
git -C "$root/repo-detached" -c user.email=t@t -c user.name=t add -A
git -C "$root/repo-detached" -c user.email=t@t -c user.name=t commit --quiet -m detached
age "$root/repo-detached"

detached_log="$tmpdir/detached.log"
TMP_SCRATCH_ROOTS="$root" TMP_SCRATCH_AGE_DAYS=7 TMP_SCRATCH_MIN_MB=1 \
  "$script_src" > "$detached_log" 2>&1 || fail "detached-head sweep exited non-zero"
assert_kept "$root/repo-detached" "repo whose only unpushed commit is on a detached HEAD is kept"

# The /proc probe must prove it can READ, not merely that the directory lists.
# hidepid=2, ProtectProc= and container namespaces all leave the listing intact
# while every readlink fails EACCES -- and the per-link error handler swallows
# those one at a time, yielding an empty "nothing is in use" from a probe that
# saw nothing at all. A fake /proc that lists a pid but has no readable self is
# that situation without needing privileges to create it.
mkdir -p "$tmpdir/blind-proc/123"
big "$root/blind"; age "$root/blind"
blind_log="$tmpdir/blind.log"
TMP_SCRATCH_ROOTS="$root" TMP_SCRATCH_AGE_DAYS=7 TMP_SCRATCH_MIN_MB=1 \
TMP_SCRATCH_PROC="$tmpdir/blind-proc" \
  "$script_src" > "$blind_log" 2>&1 || true
assert_kept "$root/blind" "a /proc that lists but cannot be read keeps everything"

# NOT COVERED, deliberately: os.path.ismount(). Creating a mount point needs
# privileges the build sandbox does not have, so the one-line guard against
# rmtree walking into a bind or FUSE mount under /tmp is reasoned, not tested.
# Said out loud rather than left as an apparent oversight.

# Rehearsal mode decides the same way and deletes nothing. Asserted on a tree
# the real sweep ALREADY proved it removes, so a dry run that silently stopped
# selecting anything cannot pass this.
big "$root/rehearse"
age "$root/rehearse"
rehearse_log="$tmpdir/rehearse.log"
TMP_SCRATCH_ROOTS="$root" \
TMP_SCRATCH_AGE_DAYS=7 \
TMP_SCRATCH_MIN_MB=1 \
TMP_SCRATCH_DRY_RUN=1 \
  "$script_src" > "$rehearse_log" 2>&1 || fail "dry run exited non-zero"
assert_kept "$root/rehearse" "dry run deletes nothing"
assert_log 'would remove .*rehearse' "dry run reports what it would remove" "$rehearse_log"
assert_log 'would free [1-9]' "dry run totals what it would free" "$rehearse_log"

# A probe that cannot run must FAIL SAFE. /proc is the one input the sweeper
# cannot do without: an empty result from a probe that never ran is
# indistinguishable from "nothing is using any of these", and acting on that
# difference is what deletes live work. Simulated by making python's os.listdir
# of /proc fail -- cheaper and more faithful than unmounting anything.
big "$root/failsafe"
age "$root/failsafe"
failsafe_log="$tmpdir/failsafe.log"
TMP_SCRATCH_ROOTS="$root" \
TMP_SCRATCH_AGE_DAYS=7 \
TMP_SCRATCH_MIN_MB=1 \
TMP_SCRATCH_PROC="$tmpdir/no-such-proc" \
  "$script_src" > "$failsafe_log" 2>&1 || true
assert_kept "$root/failsafe" "unreadable /proc keeps everything (fail safe)"
# ... and says so. A sweep that kept everything because it crashed before
# selecting anything would pass the line above while testing nothing.
assert_log 'WARN: scratch sweep failed' "the failed sweep is reported, not swallowed" "$failsafe_log"

# --- tally -------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ] || exit 1
echo "all tmp-scratch-sweep tests passed"
