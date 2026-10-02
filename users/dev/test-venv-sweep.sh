#!/usr/bin/env bash
# Regression tests for devbox's nightly venv-sweep.
# Run: bash users/dev/test-venv-sweep.sh
#
# WHY THIS SUITE EXISTS. venv-sweep runs `shutil.rmtree` inside git worktrees
# that agents work in. The thing it removes is cheap to rebuild (devenv recreates
# the venv on the next direnv entry), but the failure it must never have is
# removing one out from under a session that is using it, or -- worse -- ever
# touching anything else in the worktree. Every guard is one more place a
# deletion can wrongly happen, so every keep-assertion below was confirmed to
# FAIL under a mutation that disables the guard it covers (recorded in the
# commit message that introduced this file), and a guard that rots cannot stay
# green.
#
# THE SUITE NEVER TOUCHES THE REAL ~/projects, THE REAL /proc BEYOND THE
# VENV_SWEEP_PROC SEAM, OR THE REAL opencode.db. Every run points
# VENV_SWEEP_ROOTS at a fixture tree and VENV_SWEEP_SESSION_DB at a fixture (or
# nonexistent) database.
#
# Sizes are real bytes (dd, not truncate): the sweeper measures with st_blocks,
# and a sparse file reports ZERO, so the size floor would silently reject every
# fixture and the whole suite would pass by never selecting anything.

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$tmpdir"
}
trap cleanup EXIT

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
  if [ -e "$path" ] || [ -L "$path" ]; then
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
  # -e follows the link, so a link whose target was swept looks identical to a
  # link that was itself deleted. -L asks the real question.
  if [ -L "$path" ]; then
    pass "$msg"
  else
    fail "$msg" "expected the symlink itself to survive: $path"
  fi
}

assert_log() {
  local pattern="$1" msg="$2" file="$3"
  if grep -Eq -- "$pattern" "$file"; then
    pass "$msg"
  else
    fail "$msg" "log did not match: $pattern" "log: $(tr '\n' '|' < "$file")"
  fi
}

refute_log() {
  local pattern="$1" msg="$2" file="$3"
  if grep -Eq -- "$pattern" "$file"; then
    fail "$msg" "log matched when it should not: $pattern"
  else
    pass "$msg"
  fi
}

script_src="$tmpdir/venv-sweep"

# Same seam, and the same reason, as the tmp-scratch-sweep suite: a flake check
# hands over home-manager's OWN deployed store path, so the suite never invokes
# nix (impossible inside a build sandbox). The fallback is for running this by
# hand from a checkout.
if [ -n "${VENV_SWEEP_SRC:-}" ]; then
  cp "$VENV_SWEEP_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.dev.config.home.file.\".local/bin/venv-sweep\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty venv-sweep source"; exit 1; }
chmod +x "$script_src"

# --- fixture helpers ---------------------------------------------------------

old_stamp=202401010000            # far outside any plausible age window
g() { git -c user.email=t@t -c user.name=t "$@"; }

# A fixture tree is never allowed to see the developer's real session database.
no_db="$tmpdir/no-such-opencode.db"

# mkrepo <path> <ignore: yes|no>: a primary checkout with one commit. `yes`
# gitignores .devenv/ (as the real repos do); `no` is the repo that "lacks the
# ignore", where the venv is untracked-and-unignored and must therefore be kept.
mkrepo() {
  local path="$1" ignore="$2"
  mkdir -p "$path/src"
  git -C "$path" init --quiet --initial-branch=main
  echo tracked > "$path/src/app.txt"
  if [ "$ignore" = yes ]; then
    printf '.devenv/\n.worktrees/\n' > "$path/.gitignore"
  else
    printf '.worktrees/\n' > "$path/.gitignore"
  fi
  git -C "$path" add -A
  g -C "$path" commit --quiet -m init
}

# venv_into <dir>: <dir>/.devenv/state/venv with 3 real MB, plus a sibling file
# that must survive the sweep.
venv_into() {
  mkdir -p "$1/.devenv/state/venv"
  dd if=/dev/zero of="$1/.devenv/state/venv/payload" bs=1M count=3 status=none
  echo state > "$1/.devenv/state/other"
}

# age_tree <dir>: everything except the venv goes back to 2024. The venv is
# deliberately LEFT FRESH: its own mtimes must not count as worktree activity
# (devenv writes there on every entry), and leaving it fresh is what proves it.
age_tree() {
  find "$1" -path "$1/.devenv/state/venv" -prune -o -exec touch -h -t "$old_stamp" {} +
}

# mkwt <repo> <name>: a registered linked worktree at <repo>/.worktrees/<name>,
# idle, with a 3MB venv. Its ADMIN gitdir is aged too, because the sweeper
# treats a fresh commit/checkout as activity and a fresh `git worktree add`
# would otherwise make every fixture look busy.
mkwt() {
  local repo="$1" name="$2" wt="$1/.worktrees/$2"
  git -C "$repo" worktree add --quiet -b "$name" "$wt" > /dev/null 2>&1
  venv_into "$wt"
  age_tree "$wt"
  age_tree "$repo/.git/worktrees/$name"
}

# One process whose cwd is a given directory. /proc/<pid>/cwd is only correct
# once it is actually running there, so wait for the exec rather than race it.
sleeper_in() {
  ( cd "$1" && exec sleep 300 ) &
  local pid=$!
  pids+=("$pid")
  for _ in $(seq 1 50); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" = "$1" ] && break
    sleep 0.1
  done
}

# run_sweep <log> [VAR=value ...]: one sweep over $sweep_roots. MIN_MB is 1 so
# 3MB fixtures qualify; AGE_DAYS and SHELL_AGE_DAYS are deliberately NOT set so
# the suite exercises the shipped defaults (3 and 2).
run_sweep() {
  local log="$1"; shift
  env VENV_SWEEP_ROOTS="$sweep_roots" \
      VENV_SWEEP_MIN_MB=1 \
      VENV_SWEEP_SESSION_DB="$no_db" \
      "$@" \
      "$script_src" > "$log" 2>&1 || fail "sweeper exited non-zero ($log)" "log: $(cat "$log")"
}

# --- scenario 1: the main run ------------------------------------------------

root="$tmpdir/proj"
mkdir -p "$root"
mkrepo "$root/repo" yes
mkrepo "$root/repo-noignore" no

# 1. plain idle worktree -> its venv goes, nothing else does.
mkwt "$root/repo" idle
# 2. idle except ONE recently-touched file nested deep -> kept. A directory's
#    own mtime does not move when a nested file is written, which is why the
#    sweeper walks.
mkwt "$root/repo" nested-recent
mkdir -p "$root/repo/.worktrees/nested-recent/src/deep/deeper"
echo x > "$root/repo/.worktrees/nested-recent/src/deep/deeper/file"
age_tree "$root/repo/.worktrees/nested-recent"
touch "$root/repo/.worktrees/nested-recent/src/deep/deeper/file"
# 3. worktree files all old, but a fresh COMMIT -> kept. An empty commit
#    touches only the admin gitdir (logs/HEAD), never the working tree, so this
#    isolates the admin-gitdir half of the idle test.
mkwt "$root/repo" fresh-commit
g -C "$root/repo/.worktrees/fresh-commit" commit --quiet --allow-empty -m later
# 4. a live process whose cwd is in the worktree but NOT in the venv -> kept.
mkwt "$root/repo" inuse
sleeper_in "$root/repo/.worktrees/inuse/src"
# 5. venv below the size floor -> kept.
mkwt "$root/repo" tiny
rm -rf "$root/repo/.worktrees/tiny/.devenv/state/venv"
mkdir -p "$root/repo/.worktrees/tiny/.devenv/state/venv"
echo x > "$root/repo/.worktrees/tiny/.devenv/state/venv/f"
age_tree "$root/repo/.worktrees/tiny"       # recreating the venv bumped .devenv/state
# 6. a venv that is a SYMLINK to a big directory outside everything.
mkwt "$root/repo" linkvenv
mkdir -p "$tmpdir/outside-venv"
dd if=/dev/zero of="$tmpdir/outside-venv/payload" bs=1M count=3 status=none
rm -rf "$root/repo/.worktrees/linkvenv/.devenv/state/venv"
ln -s "$tmpdir/outside-venv" "$root/repo/.worktrees/linkvenv/.devenv/state/venv"
touch -h -t "$old_stamp" "$root/repo/.worktrees/linkvenv/.devenv/state/venv"
touch -t "$old_stamp" "$root/repo/.worktrees/linkvenv/.devenv/state"
# 7. a repo whose .gitignore lacks .devenv/ -> kept.
mkwt "$root/repo-noignore" noignore
# 8. a worktree whose admin gitdir has been deleted out from under it: the
#    sweeper cannot see its commit activity, so it must not guess.
mkwt "$root/repo" orphan-admin
rm -rf "$root/repo/.git/worktrees/orphan-admin"
# 9. a FULL CLONE living under .worktrees/ (a `.git` directory, not a file) is
#    not a registered linked worktree -> kept even though everything else about
#    it clears every guard (old, big, and gitignored by its own .gitignore).
mkdir -p "$root/repo/.worktrees/fullclone"
mkrepo "$root/repo/.worktrees/fullclone" yes
venv_into "$root/repo/.worktrees/fullclone"
age_tree "$root/repo/.worktrees/fullclone"
# 10. a PRIMARY checkout's own venv, old and big and ignored -> never touched.
#     A standalone repo with no worktrees under it, aged all the way down
#     including its .git, so nothing but "it is a primary checkout" can save it.
mkrepo "$root/solo" yes
venv_into "$root/solo"
age_tree "$root/solo"
# 11. old venv + old shell caches in the same worktree. The venv decision has
#     to be made BEFORE the shell prune: unlinking a file bumps its directory's
#     mtime, and `.devenv` is inside the worktree being judged.
mkwt "$root/repo" both
for n in a b c; do echo "# $n" > "$root/repo/.worktrees/both/.devenv/shell-$n.sh"; done
touch -t 202401010000 "$root/repo/.worktrees/both/.devenv/shell-a.sh"
touch -t 202401020000 "$root/repo/.worktrees/both/.devenv/shell-b.sh"
touch -t 202401030000 "$root/repo/.worktrees/both/.devenv/shell-c.sh"
age_tree "$root/repo/.worktrees/both"

# 12. `.devenv` itself is a symlink to a directory outside the worktree that
#     holds a big state/venv. lstat() of the venv path alone would follow it
#     straight out of the worktree; every component has to be checked.
mkwt "$root/repo" symdevenv
mkdir -p "$tmpdir/outside-devenv/state/venv"
dd if=/dev/zero of="$tmpdir/outside-devenv/state/venv/payload" bs=1M count=3 status=none
rm -rf "$root/repo/.worktrees/symdevenv/.devenv"
ln -s "$tmpdir/outside-devenv" "$root/repo/.worktrees/symdevenv/.devenv"
age_tree "$root/repo/.worktrees/symdevenv"

# A SECOND root that is itself a repo, so the `R/.worktrees/*` discovery shape
# (as opposed to `R/*/.worktrees/*`) is exercised.
selfroot="$tmpdir/selfrepo"
mkrepo "$selfroot" yes
mkwt "$selfroot" selfwt

# shell-*.sh fixtures -------------------------------------------------------
#
# D1, in the PRIMARY checkout: a (2024-01) < link < b (2024-06). b is the
# newest REGULAR file and is old, so it must survive only because it is the
# newest; a must go; the symlink (old, pointing at a file outside everything)
# must be neither deleted nor followed.
shell_d1="$root/repo/.devenv"
mkdir -p "$shell_d1"
echo a > "$shell_d1/shell-a.sh"; touch -t 202401010000 "$shell_d1/shell-a.sh"
echo b > "$shell_d1/shell-b.sh"; touch -t 202406010000 "$shell_d1/shell-b.sh"
echo precious > "$tmpdir/outside-shell.sh"; touch -t "$old_stamp" "$tmpdir/outside-shell.sh"
ln -s "$tmpdir/outside-shell.sh" "$shell_d1/shell-link.sh"
touch -h -t 202403010000 "$shell_d1/shell-link.sh"
echo other > "$shell_d1/not-a-shell-cache.sh"; touch -t "$old_stamp" "$shell_d1/not-a-shell-cache.sh"
# D2, in a WORKTREE: c is fresh (newest), d is 1 day old (inside the 2-day
# default window, so kept), e is old -> removed.
mkwt "$root/repo" shellwt
shell_d2="$root/repo/.worktrees/shellwt/.devenv"
echo c > "$shell_d2/shell-c.sh"
echo d > "$shell_d2/shell-d.sh"; touch -d '1 day ago' "$shell_d2/shell-d.sh"
echo e > "$shell_d2/shell-e.sh"; touch -t "$old_stamp" "$shell_d2/shell-e.sh"
# D3: only ONE shell file, and it is old -> kept (the newest always stays).
shell_d3="$selfroot/.devenv"
mkdir -p "$shell_d3"
echo only > "$shell_d3/shell-only.sh"; touch -t "$old_stamp" "$shell_d3/shell-only.sh"

sweep_roots="$root $selfroot"
main_log="$tmpdir/main.log"
run_sweep "$main_log"

wt() { echo "$root/repo/.worktrees/$1"; }

assert_gone "$(wt idle)/.devenv/state/venv"        "idle worktree: venv is removed"
assert_kept "$(wt idle)/.devenv/state/other"       "idle worktree: the rest of .devenv is intact"
assert_kept "$(wt idle)/src/app.txt"               "idle worktree: tracked files are intact"
assert_kept "$(wt idle)/.git"                      "idle worktree: its .git file is intact"
assert_log  'removed [0-9]+M .*/idle/\.devenv/state/venv' "idle worktree: the removal is logged" "$main_log"

assert_kept "$(wt nested-recent)/.devenv/state/venv" "recently-touched NESTED file keeps the venv"
assert_log  'keep .*nested-recent.* \(touched' "the nested-mtime keep says why" "$main_log"

assert_kept "$(wt fresh-commit)/.devenv/state/venv" "a fresh commit (admin gitdir only) keeps the venv"
assert_log  'keep .*fresh-commit.* \(git admin dir touched' "the admin-gitdir keep says why" "$main_log"

assert_kept "$(wt inuse)/.devenv/state/venv" "a live process in the worktree (not the venv) keeps the venv"
assert_log  'keep .*inuse.* \(live process' "the in-use keep says why" "$main_log"

assert_kept "$(wt tiny)/.devenv/state/venv" "a venv below the size floor is kept"
assert_log  'keep .*tiny.* \(below the size floor' "the size-floor keep says why" "$main_log"

assert_symlink_intact "$(wt linkvenv)/.devenv/state/venv" "a symlinked venv: the link itself survives"
assert_kept "$tmpdir/outside-venv/payload" "a symlinked venv: its target is untouched"
# rmtree refuses a symlink and the failure is swallowed, so dropping the islink
# test is NOT destructive -- the only symptom is the keep reason. Assert on it,
# or the guard has no test at all.
assert_log  'keep .*linkvenv.* \(.*symlink' "the symlinked-venv keep says why" "$main_log"

assert_kept "$root/repo-noignore/.worktrees/noignore/.devenv/state/venv" "a venv that is not gitignored is kept"
assert_log  'keep .*noignore.* \(not gitignored' "the not-ignored keep says why" "$main_log"

assert_kept "$(wt orphan-admin)/.devenv/state/venv" "a worktree whose admin gitdir is gone is kept"
assert_log  'keep .*orphan-admin.* \(admin gitdir missing' "the missing-admin keep says why" "$main_log"

assert_kept "$root/repo/.worktrees/fullclone/.devenv/state/venv" "a full clone under .worktrees (.git directory) is kept"
assert_kept "$tmpdir/outside-devenv/state/venv/payload" "a symlinked .devenv is never followed out of the worktree"
assert_log  'keep .*symdevenv.* \(symlink in the path' "the symlinked-.devenv keep says why" "$main_log"
assert_kept "$root/solo/.devenv/state/venv" "the primary checkout's venv is never touched"

assert_gone "$(wt both)/.devenv/state/venv" "venv removed even though shell caches are also pruned in the same worktree"
assert_gone "$selfroot/.worktrees/selfwt/.devenv/state/venv" "worktrees directly under a repo root (R/.worktrees/*) are swept"

assert_log 'freed [1-9][0-9]* MB' "the run totals what it freed" "$main_log"

# shell-*.sh -------------------------------------------------------------------
assert_gone "$shell_d1/shell-a.sh"  "shell cache: old file is removed (primary checkout)"
assert_kept "$shell_d1/shell-b.sh"  "shell cache: the newest is kept even though it is old"
assert_symlink_intact "$shell_d1/shell-link.sh" "shell cache: a symlink named shell-*.sh is not removed"
assert_kept "$tmpdir/outside-shell.sh" "shell cache: a symlink's target is not touched"
assert_kept "$shell_d1/not-a-shell-cache.sh" "shell cache: a non-matching name is not touched"
assert_gone "$shell_d2/shell-e.sh"  "shell cache: old file is removed (worktree)"
assert_kept "$shell_d2/shell-d.sh"  "shell cache: a file inside the age window is kept"
assert_kept "$shell_d2/shell-c.sh"  "shell cache: the newest file is kept (worktree)"
assert_kept "$shell_d3/shell-only.sh" "shell cache: a lone old file is kept (newest always stays)"
assert_gone "$(wt both)/.devenv/shell-a.sh" "shell cache: pruned in a worktree whose venv was also swept"
assert_log  'shell cache.*removed [1-9][0-9]* files' "the shell prune logs a count summary" "$main_log"

# --- scenario 2: dry run -----------------------------------------------------
#
# Asserted on trees the real run above ALREADY proved it removes, so a dry run
# that silently stopped selecting anything cannot pass.
root2="$tmpdir/proj-dry"
mkdir -p "$root2"
mkrepo "$root2/repo" yes
mkwt "$root2/repo" rehearse
shell_dry="$root2/repo/.worktrees/rehearse/.devenv"
echo a > "$shell_dry/shell-a.sh"; echo b > "$shell_dry/shell-b.sh"
age_tree "$root2/repo/.worktrees/rehearse"      # AFTER creating them: new files bump .devenv's mtime
touch -t 202401010000 "$shell_dry/shell-a.sh"; touch -t 202401020000 "$shell_dry/shell-b.sh"
sweep_roots="$root2"
dry_log="$tmpdir/dry.log"
run_sweep "$dry_log" VENV_SWEEP_DRY_RUN=1
assert_kept "$root2/repo/.worktrees/rehearse/.devenv/state/venv" "dry run deletes no venv"
assert_kept "$shell_dry/shell-a.sh" "dry run deletes no shell cache"
assert_log  'would remove .*rehearse/\.devenv/state/venv' "dry run reports the venv it would remove" "$dry_log"
assert_log  'would free [1-9]' "dry run totals what it would free" "$dry_log"
refute_log  'removed [0-9]+M' "dry run never claims a removal" "$dry_log"

# --- scenario 3: the opencode session table ---------------------------------
#
# An opencode session's working directory is a ROW, not a process handle, so
# /proc cannot see it. Trees identical to every other guard -- old, big, clean,
# unheld -- separated only by what the database says.
root3="$tmpdir/proj-sess"
mkdir -p "$root3"
mkrepo "$root3/repo" yes
for n in sess-live sess-sub sess-stale sess-none; do mkwt "$root3/repo" "$n"; done
session_db="$tmpdir/opencode.db"
python3 - "$session_db" "$root3/repo/.worktrees" <<'PYEOF'
import sqlite3, sys, time
db, base = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
con.execute("create table session (id text, directory text, time_updated integer)")
now = int(time.time() * 1000)
con.executemany("insert into session values (?, ?, ?)", [
    ("live", base + "/sess-live", now),
    # A session sitting in a SUBDIRECTORY of the worktree (`cd src`). An
    # exact-match query misses it and deletes the tree out from under it.
    ("sub", base + "/sess-sub/src", now),
    ("stale", base + "/sess-stale", now - 30 * 86400 * 1000),
])
con.commit()
PYEOF
sweep_roots="$root3"
sess_log="$tmpdir/sess.log"
run_sweep "$sess_log" VENV_SWEEP_SESSION_DB="$session_db"
assert_kept "$root3/repo/.worktrees/sess-live/.devenv/state/venv" "worktree named by a RECENT opencode session keeps its venv"
assert_kept "$root3/repo/.worktrees/sess-sub/.devenv/state/venv"  "worktree CONTAINING a recent session's directory keeps its venv"
assert_gone "$root3/repo/.worktrees/sess-stale/.devenv/state/venv" "worktree named only by a long-idle session loses its venv"
assert_gone "$root3/repo/.worktrees/sess-none/.devenv/state/venv"  "worktree no session names loses its venv (the DB read works)"
assert_log  'keep .*sess-live.* \(recent opencode session' "the session keep says why" "$sess_log"

# An unreadable database is not the same as "no sessions". Fail safe.
corrupt_db="$tmpdir/corrupt.db"
echo 'this is not a database' > "$corrupt_db"
root4="$tmpdir/proj-corrupt"
mkdir -p "$root4"
mkrepo "$root4/repo" yes
mkwt "$root4/repo" db-bad
sweep_roots="$root4"
corrupt_log="$tmpdir/corrupt.log"
run_sweep "$corrupt_log" VENV_SWEEP_SESSION_DB="$corrupt_db"
assert_kept "$root4/repo/.worktrees/db-bad/.devenv/state/venv" "an unreadable session database keeps the venv"
assert_log  'keep .*db-bad.* \(session probe failed' "the failed session probe says so" "$corrupt_log"

# --- scenario 4: /proc cannot be read ----------------------------------------
#
# /proc is an input the sweeper cannot do without: an empty result from a probe
# that never ran is indistinguishable from "nothing is using any of these", and
# acting on that difference is what deletes live work.
root5="$tmpdir/proj-proc"
mkdir -p "$root5"
mkrepo "$root5/repo" yes
mkwt "$root5/repo" blind
shell_blind="$root5/repo/.worktrees/blind/.devenv"
echo a > "$shell_blind/shell-a.sh"; echo b > "$shell_blind/shell-b.sh"
age_tree "$root5/repo/.worktrees/blind"
touch -t 202401010000 "$shell_blind/shell-a.sh"; touch -t 202401020000 "$shell_blind/shell-b.sh"
sweep_roots="$root5"
proc_log="$tmpdir/proc.log"
run_sweep "$proc_log" VENV_SWEEP_PROC="$tmpdir/no-such-proc"
assert_kept "$root5/repo/.worktrees/blind/.devenv/state/venv" "unreadable /proc keeps every venv (fail safe)"
assert_log  'WARN: cannot read .*keeping every venv' "the unreadable /proc is reported, not swallowed" "$proc_log"
# The shell caches are pure caches with no liveness question, so a blind /proc
# must not cost the run its other half.
assert_gone "$shell_blind/shell-a.sh" "unreadable /proc does not stop the shell-cache prune"

# NOT COVERED, deliberately: the os.path.ismount() / st_dev and st_uid guards.
# Creating a mount point or a foreign-owned tree needs privileges the build
# sandbox does not have, so those are reasoned, not tested. Said out loud rather
# than left as an apparent oversight.

# --- tally -------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ] || exit 1
echo "all venv-sweep tests passed"
