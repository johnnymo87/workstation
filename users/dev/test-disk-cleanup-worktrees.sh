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

# Seam: a check passes home-manager's OWN deployed store path for this file,
# so the suite never invokes nix (impossible in a build sandbox). Note the
# fallback needs dynamic-derivations to read .text via the CLI, which is why
# the seam passes .source -- the identical bytes, without the feature gate.
if [ -n "${DISK_CLEANUP_SRC:-}" ]; then
  cp "$DISK_CLEANUP_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-cleanup\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty disk-cleanup source"; exit 1; }

python3 - "$script_src" "$harness" "$(command -v bash)" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text()
for marker in ("# --- worktree removal guards ---\n",
               "remove_merged_worktree() {\n",
               "cleanup_worktrees() {\n"):
    start = src.find(marker)
    if start != -1:
        break
else:
    raise SystemExit("FAIL: no worktree-cleanup section found in disk-cleanup")
end = src.index("\n# --- 3. Bazel cache purge ---", start)
cleanup_worktrees = src[start:end]

# Read the age knobs out of the SHIPPED script rather than restating them.
# A copy here would let the suite keep asserting against 14/2 long after the
# script moved on, which is the failure mode where the tests stay green and
# stop testing anything.
knobs = "".join(
    m.group(0) + "\n"
    for m in re.finditer(r"^WORKTREE_(?:MIN|MAX)_AGE_DAYS=\d+", src, re.M)
)
if "WORKTREE_MAX_AGE_DAYS=" not in knobs or "WORKTREE_MIN_AGE_DAYS=" not in knobs:
    raise SystemExit(f"FAIL: could not read worktree age knobs; got: {knobs!r}")

pathlib.Path(sys.argv[2]).write_text(
    f"#!{sys.argv[3]}\n"
    "set -euo pipefail\n"
    "PROJECTS=\"$HOME/projects\"\n"
    f"{knobs}"
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
fresh_clean_wt="$repo/.worktrees/fresh-clean-merged"
live_clean_wt="$repo/.worktrees/live-clean-merged"
session_clean_wt="$repo/.worktrees/session-clean-merged"
idle_session_wt="$repo/.worktrees/idle-session-merged"
goose_session_wt="$repo/.worktrees/goose-session-merged"
goose_idle_wt="$repo/.worktrees/goose-idle-merged"
goose_sub_wt="$repo/.worktrees/goose-sub-merged"
dirty_wt="$repo/.worktrees/dirty-merged"
stale_dirty_wt="$repo/.worktrees/stale-dirty-merged"
stale_mixed_wt="$repo/.worktrees/stale-mixed-merged"
dirty_abandoned_wt="$repo/.worktrees/dirty-abandoned"
live_abandoned_wt="$repo/.worktrees/live-abandoned"
fresh_abandoned_wt="$repo/.worktrees/fresh-abandoned"
aged_abandoned_wt="$repo/.worktrees/aged-abandoned"
git -C "$repo" worktree add -b clean-merged "$clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b fresh-clean-merged "$fresh_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b live-clean-merged "$live_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b session-clean-merged "$session_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b idle-session-merged "$idle_session_wt" origin/main >/dev/null
git -C "$repo" worktree add -b goose-session-merged "$goose_session_wt" origin/main >/dev/null
git -C "$repo" worktree add -b goose-idle-merged "$goose_idle_wt" origin/main >/dev/null
git -C "$repo" worktree add -b goose-sub-merged "$goose_sub_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-merged "$dirty_wt" origin/main >/dev/null
git -C "$repo" worktree add -b stale-dirty-merged "$stale_dirty_wt" origin/main >/dev/null
git -C "$repo" worktree add -b stale-mixed-merged "$stale_mixed_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-abandoned "$dirty_abandoned_wt" origin/main >/dev/null
git -C "$repo" worktree add -b live-abandoned "$live_abandoned_wt" origin/main >/dev/null
git -C "$repo" worktree add -b fresh-abandoned "$fresh_abandoned_wt" origin/main >/dev/null
git -C "$repo" worktree add -b aged-abandoned "$aged_abandoned_wt" origin/main >/dev/null
# Merged and spotless, and nothing in it touched for weeks: the sweep's actual
# job. Ageing it is what makes it eligible at all now -- before the minimum-age
# guard this case was created fresh and still reaped, which is exactly how a
# live session's eight-hour-old worktree was destroyed on 2026-09-01.
find "$clean_wt" -exec touch -d '20 days ago' {} +
# fresh_clean_wt is left as checked out: merged, spotless, minutes old.
printf 'uncommitted plan\n' >> "$dirty_wt/README.md"
# Merged, dirty, and NOTHING in the tree touched within the window: the
# age-out must reap it. Freshness is a full-tree mtime scan, so every path
# (files, dirs, the .git gitfile) must be aged, not just the dirty one.
printf 'stale uncommitted plan\n' >> "$stale_dirty_wt/README.md"
find "$stale_dirty_wt" -exec touch -d '20 days ago' {} +
# Regression for the porcelain-quoting hole (PR #426 adversarial review):
# stale unquoted dirt PLUS fresh dirt whose name porcelain quotes (a space).
# A stat-per-dirty-path check skips the quoted path and judges the tree by
# its stale dirt -> reaped with day-old work inside. The full-tree scan must
# keep it.
printf 'stale uncommitted plan\n' >> "$stale_mixed_wt/README.md"
find "$stale_mixed_wt" -exec touch -d '20 days ago' {} +
printf 'fresh notes\n' > "$stale_mixed_wt/My Notes.md"
printf 'old abandoned branch\n' > "$dirty_abandoned_wt/abandoned.md"
git -C "$dirty_abandoned_wt" add abandoned.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$dirty_abandoned_wt" commit -m 'old abandoned commit' >/dev/null
printf 'uncommitted abandoned work\n' >> "$dirty_abandoned_wt/abandoned.md"
find "$dirty_abandoned_wt" -exec touch -d '20 days ago' {} +

# Abandoned-shape tree (ancient commit, no remote branch), freshly checked out.
# Minimum-age floor on the abandoned path must keep it.
printf 'old abandoned branch\n' > "$fresh_abandoned_wt/abandoned.md"
git -C "$fresh_abandoned_wt" add abandoned.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$fresh_abandoned_wt" commit -m 'old abandoned commit' >/dev/null

# Same abandoned shape, aged past the floor: must be reaped.
printf 'old abandoned branch\n' > "$aged_abandoned_wt/abandoned.md"
git -C "$aged_abandoned_wt" add abandoned.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$aged_abandoned_wt" commit -m 'old abandoned commit' >/dev/null
find "$aged_abandoned_wt" -exec touch -d '20 days ago' {} +

# Same shape as dirty_abandoned (ancient commit, no remote branch) but with a
# live process sitting in it. "Last commit is old" says nothing about whether
# someone is working there right now -- a long investigation on an old base
# looks identical from the outside.
printf 'old abandoned branch\n' > "$live_abandoned_wt/abandoned.md"
git -C "$live_abandoned_wt" add abandoned.md
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$live_abandoned_wt" commit -m 'old abandoned commit' >/dev/null

# Stand-ins for an agent session whose cwd is the worktree. Nested one level
# deep on purpose: a session is rarely sitting in the top directory, and the
# guard has to match anything UNDER the tree, not just the tree itself.
live_pids=()
start_occupant() {
  local dir="$1/nested"
  mkdir -p "$dir"
  ( cd "$dir" && exec sleep 300 ) &
  live_pids+=("$!")
}
stop_occupants() {
  local pid
  for pid in "${live_pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap 'stop_occupants; rm -rf "$tmpdir"' EXIT

start_occupant "$live_clean_wt"
start_occupant "$live_abandoned_wt"
# The occupants' nested/ dirs are fresh, so re-age live_clean_wt and live_abandoned_wt:
# without this they would be kept by the minimum-age guard and prove nothing about liveness.
find "$live_clean_wt" -exec touch -d '20 days ago' {} +
find "$live_abandoned_wt" -exec touch -d '20 days ago' {} +
# Wait for both cwds to actually appear in /proc before probing anything.
for _ in $(seq 1 50); do
  ready=0
  for pid in "${live_pids[@]}"; do
    if [ -n "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" ]; then
      ready=$((ready + 1))
    fi
  done
  [ "$ready" -eq "${#live_pids[@]}" ] && break
  sleep 0.1
done
[ "$ready" -eq "${#live_pids[@]}" ] || fail "test occupants never took a cwd" \
  "only $ready of ${#live_pids[@]} processes had a readable /proc cwd"

# An opencode session's directory is a row in opencode.db, NOT any process's
# cwd -- the serve that owns it runs elsewhere and holds no handle inside the
# tree. So both of these are clean, merged, aged past the minimum-age floor
# and have NO live process inside: /proc says nothing about them, and only the
# session table can tell them apart. That is the exact shape of the worktree
# this script destroyed on 2026-09-01.
find "$session_clean_wt" -exec touch -d '20 days ago' {} +
find "$idle_session_wt" -exec touch -d '20 days ago' {} +
find "$goose_session_wt" -exec touch -d '20 days ago' {} +
find "$goose_idle_wt" -exec touch -d '20 days ago' {} +
find "$goose_sub_wt" -exec touch -d '20 days ago' {} +

session_db="$home/.local/share/opencode/opencode.db"
mkdir -p "$(dirname "$session_db")"
python3 - "$session_db" "$(cd "$session_clean_wt" && pwd -P)" "$(cd "$idle_session_wt" && pwd -P)" <<'SESSION_DB_PY'
import sqlite3, sys, time

db, live_dir, idle_dir = sys.argv[1], sys.argv[2], sys.argv[3]
now_ms = int(time.time() * 1000)
con = sqlite3.connect(db)
con.execute(
    "create table session (id text primary key, directory text not null, "
    "time_updated integer not null)"
)
con.executemany(
    "insert into session (id, directory, time_updated) values (?, ?, ?)",
    [
        # Alive but idle: parked on a scheduled wake, tree untouched for weeks.
        ("ses_live", live_dir, now_ms - 3 * 86400 * 1000),
        # Long gone. Must NOT protect: the real host carries 4456 stale rows,
        # and honouring them all would pin every worktree they ever named.
        ("ses_idle", idle_dir, now_ms - 30 * 86400 * 1000),
    ],
)
con.commit()
SESSION_DB_PY

# Goose sessions DB: a live session in goose_session_wt, one live in a
# directory UNDER goose_sub_wt, and an idle one in goose_idle_wt. Timestamp format is UTC '%Y-%m-%d %H:%M:%S'.
goose_db="$home/.local/share/goose/sessions/sessions.db"
mkdir -p "$(dirname "$goose_db")"
python3 - "$goose_db" "$(cd "$goose_session_wt" && pwd -P)" "$(cd "$goose_idle_wt" && pwd -P)" \
  "$(cd "$goose_sub_wt" && pwd -P)" <<'GOOSE_DB_PY'
import sqlite3, sys, time

db, live_dir, idle_dir, sub_dir = sys.argv[1:5]
now = time.time()
fmt = "%Y-%m-%d %H:%M:%S"
live_time = time.strftime(fmt, time.gmtime(now - 3 * 86400))
idle_time = time.strftime(fmt, time.gmtime(now - 30 * 86400))

con = sqlite3.connect(db)
con.execute(
    "create table sessions (id text primary key, working_dir text not null, "
    "updated_at timestamp)"
)
con.executemany(
    "insert into sessions (id, working_dir, updated_at) values (?, ?, ?)",
    [
        ("20261104_1", live_dir, live_time),
        ("20261001_9", idle_dir, idle_time),
        ("20261104_2", sub_dir + "/crates/x", live_time),
    ],
)
con.commit()
GOOSE_DB_PY

fakebin="$tmpdir/fakebin"
remove_log="$tmpdir/remove.log"
mkdir -p "$fakebin"
: > "$remove_log"

printf '#!%s\n' "$(command -v bash)" > "$fakebin/git"
cat >> "$fakebin/git" <<'SH'
set -euo pipefail
if [ -n "${FAKE_GITHUB_ORIGIN:-}" ] && [ "$#" -ge 5 ] && [ "$1" = "-C" ] && [ "$3" = "remote" ] && [ "$4" = "get-url" ] && [ "$5" = "origin" ]; then
  echo "$FAKE_GITHUB_ORIGIN"
  exit 0
fi
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

# GitHub stand-in for lgtm-pr-N tests. Emits OPEN for 202, MERGED for 201/203/204.
# When called with -q, emits raw state (python caller); when called with
# --json state (bash caller), emits JSON.
printf '#!%s\n' "$(command -v bash)" > "$fakebin/gh"
cat >> "$fakebin/gh" <<'SH'
set -euo pipefail
# `gh pr list --head <branch> --state all --json ...`: the canned answer in
# $FAKE_GH_DIR/list.<branch>, else no PR at all.
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  head=""; prev=""
  for arg in "$@"; do [ "$prev" = "--head" ] && head="$arg"; prev="$arg"; done
  if [ -n "${FAKE_GH_DIR:-}" ] && [ -f "$FAKE_GH_DIR/list.$head" ]; then cat "$FAKE_GH_DIR/list.$head"; else echo '[]'; fi
  exit 0
fi
[ "$1" = "pr" ] && [ "$2" = "view" ] || { echo "fake gh: unexpected $*" >&2; exit 2; }
has_q=false
for arg in "$@"; do
  if [ "$arg" = "-q" ]; then
    has_q=true
  fi
done
# A canned `pr view` answer (state and headRefOid) wins when one exists.
for arg in "$@"; do
  if [ -n "${FAKE_GH_DIR:-}" ] && [ -f "$FAKE_GH_DIR/view.$arg" ]; then cat "$FAKE_GH_DIR/view.$arg"; exit 0; fi
done
emit_state() {
  local state="$1"
  if [ "$has_q" = "true" ]; then
    echo "$state"
  else
    printf '{"state":"%s"}\n' "$state"
  fi
}
case "$3" in
  202) emit_state OPEN ;;
  201|203|204|301) emit_state MERGED ;;
  *)       echo "fake gh: HTTP 502" >&2; exit 1 ;;
esac
SH
chmod +x "$fakebin/gh"

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

assert_remove_logged "$clean_wt" "clean merged worktree untouched for weeks is selected for removal"
assert_remove_not_logged "$dirty_wt" "dirty merged worktree with fresh dirt is not selected for removal"
assert_remove_logged "$stale_dirty_wt" "dirty merged worktree with stale dirt is selected for removal"
assert_remove_not_logged "$stale_mixed_wt" "stale tree with fresh space-named dirt is not selected for removal"
assert_remove_logged "$dirty_abandoned_wt" "dirty abandoned worktree is selected for removal"
assert_remove_not_logged "$fresh_abandoned_wt" \
  "freshly created abandoned worktree is not selected for removal (minimum age floor)"
if grep -q "keeping abandoned worktree (tree touched within [0-9]*d): example/fresh-abandoned" "$tmpdir/harness.err"; then
  pass "freshly created abandoned worktree logs why it was kept"
else
  fail "freshly created abandoned worktree must log why it was kept" "stderr: $(cat "$tmpdir/harness.err")"
fi
assert_remove_logged "$aged_abandoned_wt" \
  "aged abandoned worktree is selected for removal"

# The two defects that destroyed a running session's working directory.
assert_remove_not_logged "$fresh_clean_wt" \
  "freshly created clean merged worktree is not selected for removal (minimum age)"
assert_remove_not_logged "$live_clean_wt" \
  "clean merged worktree with a live process inside is not selected for removal"
assert_remove_not_logged "$live_abandoned_wt" \
  "abandoned worktree with a live process inside is not selected for removal"
assert_remove_not_logged "$session_clean_wt" \
  "aged clean worktree owned by a live opencode session is not selected for removal"
assert_remove_logged "$idle_session_wt" \
  "aged clean worktree whose session went idle weeks ago is still selected for removal"
assert_remove_not_logged "$goose_session_wt" \
  "aged clean worktree owned by a live goose session is not selected for removal"
assert_remove_logged "$goose_idle_wt" \
  "aged clean worktree whose goose session went idle weeks ago is still selected for removal"
assert_remove_not_logged "$goose_sub_wt" \
  "aged clean worktree with a live goose session in a SUBDIRECTORY is not selected for removal"

# Regression for GUARD 1c retirement: an idle (30-day) opencode session's
# merged, aged, clean tree is reaped even when an attribution cache naming its
# session with an OPEN PR exists.
attribution_cache="$home/.local/state/lgtm/shepherd/attribution-cache.json"
mkdir -p "$(dirname "$attribution_cache")"
cat > "$attribution_cache" <<'CACHE_JSON'
{"version": 1, "scannedThrough": 0, "entries": {
  "example/repo#202": {"repo": "example/repo", "prNumber": 202, "rootSessionId": "ses_idle", "originSessionId": "ses_idle", "parentage": "main", "createdAt": 0}
}}
CACHE_JSON
: > "$remove_log"
HOME="$home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" "$harness" \
  > "$tmpdir/harness-regression-1c.out" 2> "$tmpdir/harness-regression-1c.err"
assert_remove_logged "$idle_session_wt" \
  "idle session worktree is reaped even when an attribution cache names an open PR"
rm -f "$attribution_cache"

# Fail-closed goose DB: an unreadable goose DB must keep every tree (fail-closed).
cp "$goose_db" "$goose_db.bak"
printf 'not a database' > "$goose_db"
: > "$remove_log"
set +e
HOME="$home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" \
  DISK_CLEANUP_GH_TIMEOUT=1 "$harness" > "$tmpdir/harness-goose-broken.out" 2> "$tmpdir/harness-goose-broken.err"
harness_broken_rc=$?
set -e
[ "$harness_broken_rc" -eq 0 ] || fail "cleanup_worktrees harness (broken goose db) exited $harness_broken_rc" \
  "stdout: $(tr '\n' ' ' < "$tmpdir/harness-goose-broken.out")"
assert_remove_not_logged "$goose_session_wt" \
  "an unreadable goose DB keeps the goose session worktree (fail-closed)"
assert_remove_not_logged "$clean_wt" \
  "an unreadable goose DB keeps every worktree probed (fail-closed)"
cp "$goose_db.bak" "$goose_db"
rm -f "$goose_db.bak"

# No opencode DB: a host with goose only (or missing opencode DB) still consults goose.
# Without this, [ -f "$SESSION_DB" ] || return 1 short-circuits before goose is asked.
mv "$session_db" "$session_db.bak"
: > "$remove_log"
set +e
HOME="$home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" \
  DISK_CLEANUP_GH_TIMEOUT=1 "$harness" > "$tmpdir/harness-no-opencode.out" 2> "$tmpdir/harness-no-opencode.err"
harness_no_oc_rc=$?
set -e
[ "$harness_no_oc_rc" -eq 0 ] || fail "cleanup_worktrees harness (no opencode db) exited $harness_no_oc_rc" \
  "stdout: $(tr '\n' ' ' < "$tmpdir/harness-no-opencode.out")"
assert_remove_not_logged "$goose_session_wt" \
  "a host without opencode DB still keeps worktrees of live goose sessions"
assert_remove_logged "$goose_idle_wt" \
  "a host without opencode DB still selects idle goose worktrees for removal"
mv "$session_db.bak" "$session_db"

# --- PR worktrees: lgtm-pr-<N> (lgtm) and pr-<N> (maven-renovate lane) ---
lgtm_home="$tmpdir/lgtm_home"
lgtm_repo="$lgtm_home/projects/lgtmrepo"
mkdir -p "$lgtm_home/projects"

git clone "$origin" "$lgtm_repo" >/dev/null
git -C "$lgtm_repo" config user.email test@example.com
git -C "$lgtm_repo" config user.name 'Disk Cleanup Test'
mkdir -p "$lgtm_repo/.worktrees"

lgtm_pr_201_wt="$lgtm_repo/.worktrees/lgtm-pr-201"
lgtm_pr_202_wt="$lgtm_repo/.worktrees/lgtm-pr-202"
lane_pr_203_wt="$lgtm_repo/.worktrees/pr-203"
dirty_lgtm_pr_wt="$lgtm_repo/.worktrees/lgtm-pr-204"

for wt in "$lgtm_pr_201_wt" "$lgtm_pr_202_wt" "$lane_pr_203_wt" "$dirty_lgtm_pr_wt"; do
  git -C "$lgtm_repo" worktree add --detach "$wt" origin/main >/dev/null
  echo "pr commit" > "$wt/pr.txt"
  git -C "$wt" add pr.txt
  git -C "$wt" commit -m "pr commit" >/dev/null
  find "$wt" -exec touch -d '20 days ago' {} +
done

# Fresh uncommitted changes on dirty_lgtm_pr_wt to trigger the dirty guard
printf 'uncommitted changes\n' >> "$dirty_lgtm_pr_wt/pr.txt"

: > "$remove_log"
set +e
HOME="$lgtm_home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" \
  FAKE_GITHUB_ORIGIN="https://github.com/example/lgtmrepo.git" "$harness" \
  > "$tmpdir/harness-lgtm.out" 2> "$tmpdir/harness-lgtm.err"
harness_lgtm_rc=$?
set -e
if [ "$harness_lgtm_rc" -ne 0 ]; then
  fail "cleanup_worktrees harness (lgtm) exited $harness_lgtm_rc" \
    "stdout: $(tr '\n' ' ' < "$tmpdir/harness-lgtm.out")" \
    "stderr: $(tr '\n' ' ' < "$tmpdir/harness-lgtm.err")"
fi

assert_remove_logged "$lgtm_pr_201_wt" \
  "lgtm-pr worktree whose PR is MERGED is selected for removal"
assert_remove_not_logged "$lgtm_pr_202_wt" \
  "lgtm-pr worktree whose PR is OPEN is not selected for removal"
assert_remove_logged "$lane_pr_203_wt" \
  "lane pr-N worktree whose PR is MERGED is still selected for removal (unchanged)"
assert_remove_not_logged "$dirty_lgtm_pr_wt" \
  "dirty lgtm-pr worktree whose PR is MERGED is not selected for removal"

# --- Squash-merged PRs whose branch is kept, default branches other than
# main, and the dependency lane's own clones ---
#
# Measured on cloudbox 2026-11-09: one repo squash-merges and keeps its
# branches, so a merged worktree's HEAD is never an ancestor of main AND its
# remote branch still exists -- neither rule above fires, and 30 merged
# worktrees there were never going to be reaped. Two others default to
# master, so the ancestor test against a hard-coded origin/main could never
# fire there either (a merged, 208-day-old worktree was still on disk). And
# the lane's clones under ~/.local/state/lane-clones were not scanned at all.
sq_home="$tmpdir/sq_home"
sq_repo="$sq_home/projects/sqrepo"
fake_gh_dir="$tmpdir/fake-gh"
mkdir -p "$sq_home/projects" "$fake_gh_dir"
git clone "$origin" "$sq_repo" >/dev/null
git -C "$sq_repo" config user.email test@example.com
git -C "$sq_repo" config user.name 'Disk Cleanup Test'
mkdir -p "$sq_repo/.worktrees"

# make_pushed_branch <name>: a worktree on branch <name> with one commit that
# is pushed (the remote branch is KEPT, as after a squash merge here).
make_pushed_branch() {
  local name="$1" wt="$sq_repo/.worktrees/$1"
  git -C "$sq_repo" worktree add -b "$name" "$wt" origin/main >/dev/null
  echo "$name" > "$wt/$name.txt"
  git -C "$wt" add "$name.txt"
  git -C "$wt" commit -m "$name" >/dev/null
  git -C "$wt" push -q origin "$name" >/dev/null 2>&1
}
pr_list() {  # pr_list <branch> <state> <sha>
  printf '[{"number":7,"state":"%s","headRefOid":"%s"}]\n' "$2" "$3" > "$fake_gh_dir/list.$1"
}
for b in sq-merged sq-closed sq-closed-recent sq-open sq-ahead sq-fresh sq-nopr sq-mixed develop; do make_pushed_branch "$b"; done
for b in sq-merged sq-closed sq-ahead sq-fresh; do
  pr_list "$b" MERGED "$(git -C "$sq_repo/.worktrees/$b" rev-parse HEAD)"
done
pr_list sq-closed CLOSED "$(git -C "$sq_repo/.worktrees/sq-closed" rev-parse HEAD)"
pr_list sq-closed-recent CLOSED "$(git -C "$sq_repo/.worktrees/sq-closed-recent" rev-parse HEAD)"
# A long-lived branch name: a release PR from it merged, HEAD inside it.
pr_list develop MERGED "$(git -C "$sq_repo/.worktrees/develop" rev-parse HEAD)"
pr_list sq-open OPEN "$(git -C "$sq_repo/.worktrees/sq-open" rev-parse HEAD)"
# A later PR from the same branch is still open: not done.
printf '[{"number":7,"state":"MERGED","headRefOid":"%s"},{"number":9,"state":"OPEN","headRefOid":"%s"}]\n' \
  "$(git -C "$sq_repo/.worktrees/sq-mixed" rev-parse HEAD)" "$(git -C "$sq_repo/.worktrees/sq-mixed" rev-parse HEAD)" \
  > "$fake_gh_dir/list.sq-mixed"
# Committed after the PR's last head, never pushed: that commit is work.
echo more > "$sq_repo/.worktrees/sq-ahead/more.txt"
git -C "$sq_repo/.worktrees/sq-ahead" add more.txt
git -C "$sq_repo/.worktrees/sq-ahead" commit -m "unpushed follow-up" >/dev/null
for b in sq-merged sq-closed sq-open sq-ahead sq-nopr sq-mixed develop; do
  find "$sq_repo/.worktrees/$b" -exec touch -d '20 days ago' {} +
done
# Closed unmerged and idle 5 days: past the 2-day floor, inside the 14-day
# window a PR that may be reopened gets.
find "$sq_repo/.worktrees/sq-closed-recent" -exec touch -d '5 days ago' {} +
# sq-fresh stays fresh: merged per GitHub, but the minimum-age floor applies.

# A repo whose default branch is master, with a worktree fast-forward merged
# into it (its HEAD IS an ancestor of origin/master).
origin_master="$tmpdir/origin-master.git"
git clone -q --bare "$origin" "$origin_master"
git -C "$origin_master" branch -m main master
git -C "$origin_master" symbolic-ref HEAD refs/heads/master
ms_repo="$sq_home/projects/msrepo"
git clone -q "$origin_master" "$ms_repo"
git -C "$ms_repo" config user.email test@example.com
git -C "$ms_repo" config user.name 'Disk Cleanup Test'
mkdir -p "$ms_repo/.worktrees"
git -C "$ms_repo" worktree add -b ms-merged "$ms_repo/.worktrees/ms-merged" origin/master >/dev/null
echo x > "$ms_repo/.worktrees/ms-merged/x.txt"
git -C "$ms_repo/.worktrees/ms-merged" add x.txt
git -C "$ms_repo/.worktrees/ms-merged" commit -m x >/dev/null
git -C "$ms_repo/.worktrees/ms-merged" push -q origin HEAD:master >/dev/null 2>&1
find "$ms_repo/.worktrees/ms-merged" -exec touch -d '20 days ago' {} +

# The lane's own clone of a repo, with a pr-N worktree whose PR merged.
lc_repo="$sq_home/.local/state/lane-clones/example__lanerepo"
mkdir -p "$(dirname "$lc_repo")"
git clone -q "$origin" "$lc_repo"
mkdir -p "$lc_repo/.worktrees"
git -C "$lc_repo" config user.email test@example.com
git -C "$lc_repo" config user.name 'Disk Cleanup Test'
git -C "$lc_repo" worktree add --detach "$lc_repo/.worktrees/pr-301" origin/main >/dev/null
printf '{"state":"MERGED","headRefOid":"%s"}\n' "$(git -C "$lc_repo/.worktrees/pr-301" rev-parse HEAD)" > "$fake_gh_dir/view.301"
# Merged, but the lane committed past the PR's head and never pushed it.
git -C "$lc_repo" worktree add --detach "$lc_repo/.worktrees/pr-303" origin/main >/dev/null
printf '{"state":"MERGED","headRefOid":"%s"}\n' "$(git -C "$lc_repo/.worktrees/pr-303" rev-parse HEAD)" > "$fake_gh_dir/view.303"
echo repin > "$lc_repo/.worktrees/pr-303/repin.txt"
git -C "$lc_repo/.worktrees/pr-303" add repin.txt
git -C "$lc_repo/.worktrees/pr-303" commit -m "repin nobody pushed" >/dev/null
# OPEN, with an ancient head and an idle tree: the abandoned shape, which
# must never apply in a lane clone.
git -C "$lc_repo" worktree add --detach "$lc_repo/.worktrees/pr-302" origin/main >/dev/null
printf '{"state":"OPEN","headRefOid":"0000000000000000000000000000000000000000"}\n' > "$fake_gh_dir/view.302"
echo half > "$lc_repo/.worktrees/pr-302/half.txt"
git -C "$lc_repo/.worktrees/pr-302" add half.txt
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$lc_repo/.worktrees/pr-302" commit -m "old renovate head" >/dev/null
for n in 301 302 303; do find "$lc_repo/.worktrees/pr-$n" -exec touch -d '20 days ago' {} +; done

: > "$remove_log"
set +e
HOME="$sq_home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" \
  FAKE_GITHUB_ORIGIN="https://github.com/example/sqrepo.git" FAKE_GH_DIR="$fake_gh_dir" "$harness" \
  > "$tmpdir/harness-sq.out" 2> "$tmpdir/harness-sq.err"
harness_sq_rc=$?
set -e
[ "$harness_sq_rc" -eq 0 ] || fail "cleanup_worktrees harness (squash) exited $harness_sq_rc" \
  "stderr: $(tr '\n' ' ' < "$tmpdir/harness-sq.err")"
sqwt() { (cd "$sq_repo/.worktrees/$1" && pwd -P); }
assert_remove_logged "$(sqwt sq-merged)" \
  "squash-merged worktree whose branch is kept on origin is selected for removal"
assert_remove_logged "$(sqwt sq-closed)" \
  "worktree whose only PR was closed unmerged, HEAD at the PR head, is selected for removal"
assert_remove_not_logged "$(sqwt sq-open)" "worktree whose PR is OPEN is not selected for removal"
assert_remove_not_logged "$(sqwt sq-mixed)" \
  "worktree whose branch has a merged PR AND an open one is not selected for removal"
assert_remove_not_logged "$(sqwt sq-ahead)" \
  "merged-PR worktree with a local commit past the PR head is not selected for removal"
assert_remove_not_logged "$(sqwt sq-fresh)" \
  "merged-PR worktree touched within the floor is not selected for removal"
assert_remove_not_logged "$(sqwt sq-nopr)" \
  "pushed branch with no PR and a remote branch is not selected for removal"
assert_remove_logged "$(cd "$ms_repo/.worktrees/ms-merged" && pwd -P)" \
  "worktree merged into a master default branch is selected for removal"
assert_remove_logged "$(cd "$lc_repo/.worktrees/pr-301" && pwd -P)" \
  "the lane clone's pr-N worktree whose PR merged is selected for removal"
assert_remove_not_logged "$(cd "$lc_repo/.worktrees/pr-303" && pwd -P)" \
  "a lane clone's merged pr-N worktree with a commit past the PR head is not selected for removal"
assert_remove_not_logged "$(cd "$lc_repo/.worktrees/pr-302" && pwd -P)" \
  "a lane clone's open-PR worktree with an ancient head is not selected (no abandoned rule there)"
assert_remove_not_logged "$(sqwt sq-closed-recent)" \
  "closed-unmerged PR worktree idle 5 days is not selected for removal (14-day window)"
assert_remove_not_logged "$(sqwt develop)" \
  "a worktree on a long-lived branch name is never matched by the PR rule"
grep -q "PR-merged worktree (#7 MERGED)" "$tmpdir/harness-sq.err" \
  && pass "a PR-merged removal names the PR and its state" \
  || fail "a PR-merged removal must name the PR" "stderr: $(cat "$tmpdir/harness-sq.err")"

# Fail-safe: when the liveness probe cannot run at all, NOTHING is removed.
# An empty answer from a probe that never ran is indistinguishable from
# "nobody is using it", and only one of those is recoverable.
broken_bin="$tmpdir/brokenbin"
mkdir -p "$broken_bin"
printf '#!%s\nexit 127\n' "$(command -v bash)" > "$broken_bin/python3"
chmod +x "$broken_bin/python3"
: > "$remove_log"

set +e
HOME="$home" PATH="$broken_bin:$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" "$harness" \
  > "$tmpdir/harness2.out" 2> "$tmpdir/harness2.err"
harness2_rc=$?
set -e
if [ "$harness2_rc" -ne 0 ]; then
  fail "cleanup_worktrees harness (broken probe) exited $harness2_rc" \
    "stdout: $(tr '\n' ' ' < "$tmpdir/harness2.out")" \
    "stderr: $(tr '\n' ' ' < "$tmpdir/harness2.err")"
fi
if [ -s "$remove_log" ]; then
  fail "unusable liveness probe must block every removal" \
    "removals attempted anyway: $(tr '\n' ' ' < "$remove_log")"
fi
pass "unusable liveness probe blocks every worktree removal"

printf 'all disk-cleanup worktree tests passed\n'
