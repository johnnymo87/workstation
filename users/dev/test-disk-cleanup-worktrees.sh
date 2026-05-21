#!/usr/bin/env bash
# Regression tests for disk-cleanup worktree pruning decisions.
# Run: bash users/dev/test-disk-cleanup-worktrees.sh

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
real_git="$(command -v git)"
tmpdir="$(mktemp -d /tmp/opencode/disk-cleanup-worktrees.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  shift || true
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
  exit 1
}

assert_remove_logged() {
  local wt_dir="$1" msg="$2"
  if grep -Fqx "$wt_dir" "$remove_log"; then
    pass "$msg"
  else
    fail "$msg" "expected removal log to contain: $wt_dir" "log: $(tr '\n' ' ' < "$remove_log")"
  fi
}

assert_remove_not_logged() {
  local wt_dir="$1" msg="$2"
  if grep -Fqx "$wt_dir" "$remove_log"; then
    fail "$msg" "dirty worktree was selected for removal: $wt_dir" "log: $(tr '\n' ' ' < "$remove_log")"
  else
    pass "$msg"
  fi
}

script_src="$tmpdir/disk-cleanup"
harness="$tmpdir/worktree-harness"

nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
  eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-cleanup\".text" \
  > "$script_src"

python3 - "$script_src" "$harness" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text()
start = src.find("remove_worktree_if_clean() {\n")
if start == -1:
    start = src.index("cleanup_worktrees() {\n")
end = src.index("\n# --- 3. Bazel cache purge ---", start)
cleanup_worktrees = src[start:end]

pathlib.Path(sys.argv[2]).write_text(
    "#!/usr/bin/env bash\n"
    "set -euo pipefail\n"
    "PROJECTS=\"$HOME/projects\"\n"
    "WORKTREE_MAX_AGE_DAYS=14\n"
    "log() { printf '[disk-cleanup-test] %s\\n' \"$*\" >&2; }\n"
    f"{cleanup_worktrees}\n"
    "cleanup_worktrees\n"
)
PY
chmod +x "$harness"

home="$tmpdir/home"
repo="$home/projects/example"
origin="$tmpdir/origin.git"
seed="$tmpdir/seed"
mkdir -p "$home/projects"

git init --bare "$origin" >/dev/null
git -C "$origin" symbolic-ref HEAD refs/heads/main

git init "$seed" >/dev/null
git -C "$seed" checkout -b main >/dev/null
git -C "$seed" config user.email test@example.com
git -C "$seed" config user.name 'Disk Cleanup Test'
printf 'baseline\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m 'initial commit' >/dev/null
git -C "$seed" remote add origin "$origin"
git -C "$seed" push -u origin main >/dev/null

git clone "$origin" "$repo" >/dev/null
mkdir -p "$repo/.worktrees"

clean_wt="$repo/.worktrees/clean-merged"
dirty_wt="$repo/.worktrees/dirty-merged"
dirty_abandoned_wt="$repo/.worktrees/dirty-abandoned"
git -C "$repo" worktree add -b clean-merged "$clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-merged "$dirty_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-abandoned "$dirty_abandoned_wt" origin/main >/dev/null
printf 'uncommitted plan\n' >> "$dirty_wt/README.md"
printf 'old abandoned branch\n' > "$dirty_abandoned_wt/abandoned.md"
git -C "$dirty_abandoned_wt" add abandoned.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$dirty_abandoned_wt" commit -m 'old abandoned commit' >/dev/null
printf 'uncommitted abandoned work\n' >> "$dirty_abandoned_wt/abandoned.md"

fakebin="$tmpdir/fakebin"
remove_log="$tmpdir/remove.log"
mkdir -p "$fakebin"
: > "$remove_log"

cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ge 5 ] && [ "$1" = "-C" ] && [ "$3" = "worktree" ] && [ "$4" = "remove" ]; then
  target="$5"
  if [ -d "$target" ]; then
    target="$(cd "$target" && pwd -P)"
  fi
  printf '%s\n' "$target" >> "$GIT_REMOVE_LOG"
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$fakebin/git"

set +e
HOME="$home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" "$harness" \
  > "$tmpdir/harness.out" 2> "$tmpdir/harness.err"
harness_rc=$?
set -e
if [ "$harness_rc" -ne 0 ]; then
  fail "cleanup_worktrees harness exited $harness_rc" \
    "stdout: $(tr '\n' ' ' < "$tmpdir/harness.out")" \
    "stderr: $(tr '\n' ' ' < "$tmpdir/harness.err")"
fi

assert_remove_logged "$clean_wt" "clean merged worktree is selected for removal"
assert_remove_not_logged "$dirty_wt" "dirty merged worktree is not selected for removal"
assert_remove_logged "$dirty_abandoned_wt" "dirty abandoned worktree is selected for removal"

printf 'all disk-cleanup worktree tests passed\n'
