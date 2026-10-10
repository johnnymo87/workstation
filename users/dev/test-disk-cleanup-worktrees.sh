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
# Idle sessions (30 days) that OPENED A PR. The 7-day session window alone
# reaps all four; ownership of a still-open PR must keep the first two.
openpr_wt="$repo/.worktrees/openpr-merged"
subagent_openpr_wt="$repo/.worktrees/subagent-openpr-merged"
mergedpr_wt="$repo/.worktrees/mergedpr-merged"
ghfail_wt="$repo/.worktrees/ghfail-merged"
nopr_wt="$repo/.worktrees/nopr-merged"
norepo_wt="$repo/.worktrees/norepo-merged"
# THE INCIDENT'S OWN SHAPE: one session, several PRs, only one still open.
# The real session owned 8 and the open one sorted last. With one PR per
# session everywhere else, "stop at the first non-open answer" passed.
manypr_wt="$repo/.worktrees/manypr-merged"
dirty_wt="$repo/.worktrees/dirty-merged"
stale_dirty_wt="$repo/.worktrees/stale-dirty-merged"
stale_mixed_wt="$repo/.worktrees/stale-mixed-merged"
dirty_abandoned_wt="$repo/.worktrees/dirty-abandoned"
live_abandoned_wt="$repo/.worktrees/live-abandoned"
git -C "$repo" worktree add -b clean-merged "$clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b fresh-clean-merged "$fresh_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b live-clean-merged "$live_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b session-clean-merged "$session_clean_wt" origin/main >/dev/null
git -C "$repo" worktree add -b idle-session-merged "$idle_session_wt" origin/main >/dev/null
git -C "$repo" worktree add -b openpr-merged "$openpr_wt" origin/main >/dev/null
git -C "$repo" worktree add -b subagent-openpr-merged "$subagent_openpr_wt" origin/main >/dev/null
git -C "$repo" worktree add -b mergedpr-merged "$mergedpr_wt" origin/main >/dev/null
git -C "$repo" worktree add -b ghfail-merged "$ghfail_wt" origin/main >/dev/null
git -C "$repo" worktree add -b nopr-merged "$nopr_wt" origin/main >/dev/null
git -C "$repo" worktree add -b norepo-merged "$norepo_wt" origin/main >/dev/null
git -C "$repo" worktree add -b manypr-merged "$manypr_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-merged "$dirty_wt" origin/main >/dev/null
git -C "$repo" worktree add -b stale-dirty-merged "$stale_dirty_wt" origin/main >/dev/null
git -C "$repo" worktree add -b stale-mixed-merged "$stale_mixed_wt" origin/main >/dev/null
git -C "$repo" worktree add -b dirty-abandoned "$dirty_abandoned_wt" origin/main >/dev/null
git -C "$repo" worktree add -b live-abandoned "$live_abandoned_wt" origin/main >/dev/null
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
# The occupants' nested/ dirs are fresh, so re-age live_clean_wt: without this
# it would be kept by the minimum-age guard and prove nothing about liveness.
find "$live_clean_wt" -exec touch -d '20 days ago' {} +
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
for wt in "$openpr_wt" "$subagent_openpr_wt" "$mergedpr_wt" "$ghfail_wt" "$nopr_wt" "$norepo_wt" "$manypr_wt"; do
  find "$wt" -exec touch -d '20 days ago' {} +
done

session_db="$home/.local/share/opencode/opencode.db"
mkdir -p "$(dirname "$session_db")"
python3 - "$session_db" "$(cd "$session_clean_wt" && pwd -P)" "$(cd "$idle_session_wt" && pwd -P)" \
  "$(cd "$openpr_wt" && pwd -P)" "$(cd "$subagent_openpr_wt" && pwd -P)" \
  "$(cd "$mergedpr_wt" && pwd -P)" "$(cd "$ghfail_wt" && pwd -P)" \
  "$(cd "$nopr_wt" && pwd -P)" "$(cd "$norepo_wt" && pwd -P)" \
  "$(cd "$manypr_wt" && pwd -P)" <<'SESSION_DB_PY'
import sqlite3, sys, time

db, live_dir, idle_dir = sys.argv[1], sys.argv[2], sys.argv[3]
openpr_dir, sub_dir, merged_dir, ghfail_dir, nopr_dir, norepo_dir, manypr_dir = sys.argv[4:11]
month_ms = 30 * 86400 * 1000
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
        # Idle for a month -- past the session window -- but each opened a PR.
        # Whether the tree is kept must depend on whether that PR is OPEN.
        ("ses_openpr", openpr_dir, now_ms - month_ms),
        ("ses_subagent", sub_dir, now_ms - month_ms),
        ("ses_mergedpr", merged_dir, now_ms - month_ms),
        ("ses_ghfail", ghfail_dir, now_ms - month_ms),
        ("ses_nopr", nopr_dir, now_ms - month_ms),
        ("ses_norepo", norepo_dir, now_ms - month_ms),
        ("ses_manypr", manypr_dir, now_ms - month_ms),
    ],
)
con.commit()
SESSION_DB_PY

# lgtm's shepherd attribution cache: PR -> the session that ran `gh pr create`.
# rootSessionId is the session lgtm-shepherd wakes, so it is the one that must
# count. originSessionId (a subagent, for some PRs) is honoured too, as
# belt-and-braces; the subagent case below pins that it still works.
attribution_cache="$home/.local/state/lgtm/shepherd/attribution-cache.json"
mkdir -p "$(dirname "$attribution_cache")"
cat > "$attribution_cache" <<'CACHE_JSON'
{"version": 1, "scannedThrough": 0, "entries": {
  "example/repo#101": {"repo": "example/repo", "prNumber": 101, "rootSessionId": "ses_openpr", "originSessionId": "ses_openpr", "parentage": "main", "createdAt": 0},
  "example/repo#104": {"repo": "example/repo", "prNumber": 104, "rootSessionId": "ses_someroot", "originSessionId": "ses_subagent", "parentage": "subagent", "createdAt": 0},
  "example/repo#102": {"repo": "example/repo", "prNumber": 102, "rootSessionId": "ses_mergedpr", "originSessionId": "ses_mergedpr", "parentage": "main", "createdAt": 0},
  "example/repo#103": {"repo": "example/repo", "prNumber": 103, "rootSessionId": "ses_ghfail", "originSessionId": "ses_ghfail", "parentage": "main", "createdAt": 0},
  "example/repo#105": {"repo": "example/repo", "prNumber": 105, "rootSessionId": "ses_nopr", "originSessionId": "ses_nopr", "parentage": "main", "createdAt": 0},
  "example/gone#1": {"repo": "example/gone", "prNumber": 1, "rootSessionId": "ses_norepo", "originSessionId": "ses_norepo", "parentage": "main", "createdAt": 0},
  "example/repo#111": {"repo": "example/repo", "prNumber": 111, "rootSessionId": "ses_manypr", "originSessionId": "ses_manypr", "parentage": "main", "createdAt": 0},
  "example/repo#112": {"repo": "example/repo", "prNumber": 112, "rootSessionId": "ses_manypr", "originSessionId": "ses_manypr", "parentage": "main", "createdAt": 0},
  "example/repo#113": {"repo": "example/repo", "prNumber": 113, "rootSessionId": "ses_manypr", "originSessionId": "ses_manypr", "parentage": "main", "createdAt": 0}
}}
CACHE_JSON
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

# GitHub stand-in: 101 and 104 are open, 102 merged, 103 unanswerable,
# 105 a PR number that does not exist, example/gone a repo GitHub will not
# resolve (deleted -- or invisible to this token, which looks the same).
# When called with -q, emits raw state (python caller); when called with
# --json state (bash caller), emits JSON.
printf '#!%s\n' "$(command -v bash)" > "$fakebin/gh"
cat >> "$fakebin/gh" <<'SH'
set -euo pipefail
[ "$1" = "pr" ] && [ "$2" = "view" ] || { echo "fake gh: unexpected $*" >&2; exit 2; }
for arg in "$@"; do
  if [ "$arg" = "example/gone" ]; then
    echo "GraphQL: Could not resolve to a Repository with the name 'example/gone'. (repository)" >&2; exit 1
  fi
done
has_q=false
for arg in "$@"; do
  if [ "$arg" = "-q" ]; then
    has_q=true
  fi
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
  101|104|111|202) emit_state OPEN ;;
  112|113|102|201|203|204) emit_state MERGED ;;
  # Hangs past the harness's DISK_CLEANUP_GH_TIMEOUT: the exception path.
  106)     sleep 10; emit_state OPEN ;;
  105)     echo "GraphQL: Could not resolve to a PullRequest with the number of 105. (repository.pullRequest)" >&2; exit 1 ;;
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

# An idle session that opened a still-OPEN PR still owes that PR its review
# replies. Removed on 2026-09-27: internal-frontends/cops-6764-fe-plan, whose
# PR #1573 then got CHANGES_REQUESTED and could not be routed to its author.
assert_remove_not_logged "$openpr_wt" \
  "aged worktree whose idle session opened a still-OPEN PR is not selected for removal"
assert_remove_not_logged "$subagent_openpr_wt" \
  "same, when the only session in the tree is the originating SUBAGENT"
assert_remove_logged "$mergedpr_wt" \
  "aged worktree whose idle session's PR is MERGED is still selected for removal"
assert_remove_not_logged "$ghfail_wt" \
  "PR state unknowable (gh failed) keeps the tree, never reads as not-open"
assert_remove_logged "$nopr_wt" \
  "a PR number GitHub says does not exist is not open, so it does not pin the tree"
assert_remove_not_logged "$norepo_wt" \
  "an unresolvable REPOSITORY keeps the tree: no-access looks identical to deleted"
assert_remove_not_logged "$manypr_wt" \
  "a session with several PRs is kept when only its OLDEST is open (the 2026-09-27 shape)"

# Re-run the harness with the attribution cache replaced, for the failure
# modes a single cache cannot express. Only the open-PR tree is asserted on:
# the rest of the fixture was already judged above.
run_with_cache() {
  local body="$1" tag="$2"
  printf '%s' "$body" > "$attribution_cache"
  : > "$remove_log"
  set +e
  HOME="$home" PATH="$fakebin:$PATH" REAL_GIT="$real_git" GIT_REMOVE_LOG="$remove_log" \
    DISK_CLEANUP_GH_TIMEOUT=1 "$harness" > "$tmpdir/harness-$tag.out" 2> "$tmpdir/harness-$tag.err"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "cleanup_worktrees harness ($tag) exited $rc" \
    "stdout: $(tr '\n' ' ' < "$tmpdir/harness-$tag.out")"
}

run_with_cache '{"version": 1, "entries": {' corrupt
assert_remove_not_logged "$openpr_wt" \
  "an attribution cache that will not parse keeps the tree (fail-closed)"

run_with_cache '{"version": 1, "scannedThrough": 0, "entries": {"example/repo#106": {"repo": "example/repo", "prNumber": 106, "rootSessionId": "ses_openpr", "originSessionId": "ses_openpr"}}}' ghhang
assert_remove_not_logged "$openpr_wt" \
  "a gh call that times out keeps the tree (fail-closed, not skipped)"

run_with_cache '{"version": 2, "entries": {"example/repo#101": {"repo": "example/repo", "prNumber": 101, "rootSessionId": "ses_openpr", "originSessionId": "ses_openpr"}}}' v2
assert_remove_logged "$openpr_wt" \
  "an UNRECOGNISED cache format falls back to pre-guard behaviour instead of pinning every idle tree"
# The harness's log() writes to stderr (the real script's writes to stdout).
if cat "$tmpdir/harness-v2.out" "$tmpdir/harness-v2.err" | grep -q "unrecognised format"; then
  pass "an unrecognised cache format is announced, so the guard cannot go quietly inert"
else
  fail "an unrecognised cache format must log a WARN" "stderr: $(tr '\n' ' ' < "$tmpdir/harness-v2.err")"
fi

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
