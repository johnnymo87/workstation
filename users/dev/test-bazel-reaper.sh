#!/usr/bin/env bash
# Regression tests for bazel-reap, the daytime orphaned-output-base reaper.
# Run: bash users/dev/test-bazel-reaper.sh
#
# WHY THIS EXISTS. disk-cleanup's nightly bazel purge runs once at 03:00 and
# removes every output base unconditionally. Nothing reclaims a base that was
# orphaned at 10:00 by an agent running `git worktree remove` -- it sits for up
# to seventeen hours. Measured on cloudbox 2026-09-21: bases are 2967-3677 MB
# each, 17-20 are reaped per night, and the box sits at 89% on an ordinary
# afternoon. On 2026-09-16 it hit 99% (4.8G free) mid-afternoon and a human had
# to clear it by hand.
#
# WHAT MAKES THIS SCRIPT DANGEROUS ENOUGH TO PIN. It deletes multi-gigabyte
# trees on a 15-minute timer, on a box shared by ~15 concurrent agent sessions.
# The asymmetry that shapes every assertion below: a wrong "keep" costs one
# night of disk, which the nightly reclaims anyway; a wrong "reap" destroys a
# running build's state. So the tests are weighted towards proving the KEEP
# branches, and several of them exist only to pin a fail-safe that has no
# visible effect when it is working.
#
# THREE FACTS MEASURED ON CLOUDBOX 2026-09-21, which the fixtures reproduce and
# which the script's correctness depends on:
#
#   1. `rm -rf` alone cannot delete an output base. Bazel leaves external-repo
#      directories read-only (319 of them in the live base at the time) and rm
#      exits 1 with the tree partly intact. The fixtures below chmod a-w on a
#      nested directory for exactly this reason, and test_reaps_readonly_tree
#      fails if the script regresses to a bare rm.
#
#   2. That failed rm removes DO_NOT_BUILD_HERE and server/ BEFORE it reaches
#      the read-only tree, so a half-deleted base can never be classified
#      again. test_keeps_base_without_marker pins the conservative reading of
#      that state; without it, a future "optimisation" that treats a missing
#      marker as an orphan would delete a partially-reaped base's neighbours.
#
#   3. Bazel servers idle out after max_idle_secs, which home.base.nix sets to
#      300 on cloudbox (5 minutes), so a worktree that someone is actively working in has
#      NO server for most of its life. That is why the workspace-existence half
#      of the test carries the weight, and why
#      test_keeps_live_workspace_without_server is the single most important
#      assertion in this file. It is not hypothetical: the one live base on
#      cloudbox on 2026-09-21 had a present workspace and no server pid.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"

pids=()
cleanup() {
  for p in "${pids[@]:-}"; do
    [ -n "$p" ] || continue
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  chmod -R u+w "$tmpdir" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

pass_count=0
fail_count=0

pass() { printf '  PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; fail_count=$((fail_count + 1)); }

check() {
  local msg="$1" cond="$2"
  if [ "$cond" = "yes" ]; then pass "$msg"; else fail "$msg"; fi
}

# Seam: a flake check passes home-manager's OWN deployed store path for this
# file, so the suite never invokes nix (impossible in a build sandbox). Same
# arrangement as test-disk-cleanup-worktrees.sh; the seam passes .source rather
# than .text because reading .text through the CLI needs dynamic-derivations.
script="$tmpdir/bazel-reap"
if [ -n "${BAZEL_REAP_SRC:-}" ]; then
  cp "$BAZEL_REAP_SRC" "$script"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/bazel-reap\".text" \
    > "$script"
fi
[ -s "$script" ] || { echo "FAIL: empty bazel-reap source"; exit 1; }
chmod +x "$script"

# ---------------------------------------------------------------------------
# Fixture helpers.
# ---------------------------------------------------------------------------

# A fake output base. Reproduces the two structural features that matter: the
# DO_NOT_BUILD_HERE marker bazel writes at the top level, and a nested
# read-only directory standing in for external/. Deliberately NOT a real bazel
# base -- building one would need a bazel server and a workspace, and every
# property under test here is a property of the directory layout.
make_base() {
  local root="$1" name="$2" workspace="$3"
  local d="$root/$name"
  mkdir -p "$d/external/rules_python++/lib/tcl8.6" "$d/server"
  echo payload > "$d/external/rules_python++/lib/tcl8.6/tclIndex"
  echo payload > "$d/external/rules_python++/lib/README"
  if [ "$workspace" != "-" ]; then
    printf '%s\n' "$workspace" > "$d/DO_NOT_BUILD_HERE"
  fi
  # Read-only, innermost first -- the order a real base ends up in, and the
  # order that makes a bare `rm -rf` fail.
  chmod -R a-w "$d/external/rules_python++/lib/tcl8.6" 2>/dev/null
  chmod a-w "$d/external/rules_python++/lib" 2>/dev/null
  printf '%s' "$d"
}

# Each test gets a pristine tree; a shared one would let an earlier reap change
# what a later assertion is looking at.
new_root() {
  local r
  r="$(mktemp -d "$tmpdir/root.XXXXXX")"
  printf '%s' "$r"
}

run_reaper() {
  local root="$1"; shift
  env BAZEL_REAP_BASE="$root" BAZEL_REAP_USED_PCT="${BAZEL_REAP_USED_PCT-0}" "$@" "$script" 2>&1
}

# ---------------------------------------------------------------------------
# The KEEP branches. These are the ones that matter.
# ---------------------------------------------------------------------------

test_keeps_live_workspace_without_server() {
  echo "TEST: a base whose workspace exists is kept even with no bazel server"
  local root wt out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  make_base "$root" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$wt" >/dev/null
  # No server/server.pid.txt at all: this is the steady state of a worktree
  # somebody is working in, because bazel servers idle out after 5 minutes
  # (startup --max_idle_secs=300 on cloudbox, in home.base.nix). Observed on the real box.
  out="$(run_reaper "$root")"
  check "live workspace survives" \
    "$([ -d "$root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ] && echo yes || echo no)"
  check "and says why" \
    "$(grep -q 'keep aaaaaaaa.* (workspace live' <<<"$out" && echo yes || echo no)"
}

test_keeps_live_server_despite_missing_workspace() {
  echo "TEST: a live server pins the base even when the workspace is gone"
  local root out base pid
  root="$(new_root)"
  base="$(make_base "$root" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$root/vanished")"
  sleep 300 &
  pid=$!
  pids+=("$pid")
  echo "$pid" > "$base/server/server.pid.txt"
  out="$(run_reaper "$root")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  check "base with live server survives" "$([ -d "$base" ] && echo yes || echo no)"
  check "and names the pid" \
    "$(grep -q "server pid $pid alive" <<<"$out" && echo yes || echo no)"
}

test_keeps_base_without_marker() {
  echo "TEST: a base with NO marker is kept (this is the half-deleted state)"
  local root out
  root="$(new_root)"
  make_base "$root" cccccccccccccccccccccccccccccccc - >/dev/null
  out="$(run_reaper "$root")"
  check "unclassifiable base survives" \
    "$([ -d "$root/cccccccccccccccccccccccccccccccc" ] && echo yes || echo no)"
  check "and defers to the nightly explicitly" \
    "$(grep -q 'no workspace marker' <<<"$out" && echo yes || echo no)"
}

test_keeps_base_with_empty_marker() {
  echo "TEST: an empty marker is not treated as 'workspace is the empty string'"
  local root out base
  root="$(new_root)"
  base="$(make_base "$root" dddddddddddddddddddddddddddddddd -)"
  : > "$base/DO_NOT_BUILD_HERE"
  out="$(run_reaper "$root")"
  check "base with empty marker survives" "$([ -d "$base" ] && echo yes || echo no)"
}

test_skips_install_and_cache() {
  echo "TEST: install/ and cache/ are never candidates"
  local root out
  root="$(new_root)"
  mkdir -p "$root/install/somefile" "$root/cache/repo"
  out="$(run_reaper "$root")"
  check "install/ survives" "$([ -d "$root/install" ] && echo yes || echo no)"
  check "cache/ survives"   "$([ -d "$root/cache" ] && echo yes || echo no)"
}

# ---------------------------------------------------------------------------
# The REAP branch.
# ---------------------------------------------------------------------------

test_reaps_readonly_tree() {
  echo "TEST: an orphan is reaped COMPLETELY, read-only dirs and all"
  local root out base
  root="$(new_root)"
  base="$(make_base "$root" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "$root/gone")"
  out="$(run_reaper "$root")"
  check "orphan is gone" "$([ ! -e "$base" ] && echo yes || echo no)"
  # The point of the assertion: a bare `rm -rf` would leave the read-only
  # subtree behind, so an empty parent is not sufficient evidence.
  check "no residue anywhere under the root" \
    "$([ -z "$(find "$root" -name 'tclIndex' 2>/dev/null)" ] && echo yes || echo no)"
  check "no staging directory left behind" \
    "$([ -z "$(find "$root" -maxdepth 1 -name '_reaping-*' 2>/dev/null)" ] && echo yes || echo no)"
  check "reports the reap" "$(grep -q 'reaped eeeeeeee' <<<"$out" && echo yes || echo no)"
}

test_dry_run_deletes_nothing() {
  echo "TEST: rehearsal mode classifies but does not delete"
  local root out base
  root="$(new_root)"
  base="$(make_base "$root" ffffffffffffffffffffffffffffffff "$root/gone")"
  out="$(run_reaper "$root" BAZEL_REAP_DRY_RUN=1)"
  check "orphan still present after rehearsal" "$([ -d "$base" ] && echo yes || echo no)"
  check "says 'would reap'" "$(grep -q 'would reap ffffffff' <<<"$out" && echo yes || echo no)"
  check "does not claim to have reaped" \
    "$(grep -q '^\[bazel-reap\] reaped' <<<"$out" && echo no || echo yes)"
}

test_rate_limit() {
  echo "TEST: no more than MAX_PER_PASS bases are removed in one pass"
  local root out remaining
  root="$(new_root)"
  local i
  for i in 1 2 3 4 5; do
    make_base "$root" "$(printf '%032d' "$i")" "$root/gone-$i" >/dev/null
  done
  out="$(run_reaper "$root" BAZEL_REAP_MAX=2)"
  remaining="$(find "$root" -maxdepth 1 -type d -name '0*' | wc -l)"
  check "exactly 3 of 5 orphans remain after a limit-2 pass" \
    "$([ "$remaining" = 3 ] && echo yes || echo no)"
  check "and says it stopped on the limit" \
    "$(grep -q 'rate limit reached' <<<"$out" && echo yes || echo no)"
}

test_resumes_staged_leftover() {
  echo "TEST: a staged leftover from an interrupted pass is finished, not puzzled over"
  local root out staged
  root="$(new_root)"
  # Exactly what an interrupted pass leaves: a renamed tree with no marker and
  # no server dir, which the classifier would refuse to touch on its own.
  staged="$root/_reaping-99999999999999999999999999999999.4242"
  mkdir -p "$staged/external/lib"
  echo payload > "$staged/external/lib/thing"
  chmod a-w "$staged/external/lib"
  out="$(run_reaper "$root")"
  check "leftover is purged" "$([ ! -e "$staged" ] && echo yes || echo no)"
  check "and is reported" \
    "$(grep -q 'purged staged leftover' <<<"$out" && echo yes || echo no)"
}

test_missing_base_dir_is_not_an_error() {
  echo "TEST: absent bazel cache dir exits clean (a host that never ran bazel)"
  local rc
  env BAZEL_REAP_BASE="$tmpdir/definitely-not-here" "$script" >/dev/null 2>&1
  rc=$?
  check "exits 0" "$([ "$rc" = 0 ] && echo yes || echo no)"
}

test_never_exits_nonzero() {
  echo "TEST: the unit never lands in 'failed', even with an undeletable base"
  local root base rc
  root="$(new_root)"
  base="$(make_base "$root" 11111111111111111111111111111111 "$root/gone")"
  # Make the base itself unremovable by taking write permission off its PARENT,
  # so even the rename fails. The script must log and move on.
  chmod a-w "$root"
  env BAZEL_REAP_BASE="$root" "$script" >/dev/null 2>&1
  rc=$?
  chmod u+w "$root"
  check "exits 0 despite being unable to act" "$([ "$rc" = 0 ] && echo yes || echo no)"
  check "base untouched" "$([ -d "$base" ] && echo yes || echo no)"
}

# ---------------------------------------------------------------------------
# Pressure tier (idle bases with live workspaces under disk pressure).
# ---------------------------------------------------------------------------

test_live_workspace_idle_4h_low_pressure_kept() {
  echo "TEST: live workspace idle 4h is kept at low pressure"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000001 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "4 hours ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=50)"
  check "base survived at low pressure" "$([ -d "$base" ] && echo yes || echo no)"
  check "logged workspace live" \
    "$(grep -q 'keep 10000000.* (workspace live' <<<"$out" && echo yes || echo no)"
}

test_live_workspace_idle_4h_high_pressure_reaped() {
  echo "TEST: live workspace idle 4h is reaped at high pressure"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000002 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "4 hours ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  check "base reaped at high pressure" "$([ ! -d "$base" ] && echo yes || echo no)"
  check "workspace directory untouched" "$([ -d "$wt" ] && echo yes || echo no)"
  check "logged reap with idle and pressure" \
    "$(grep -q 'reaped 10000000.*under pressure 90%' <<<"$out" && echo yes || echo no)"
}

test_live_workspace_idle_1h_high_pressure_kept() {
  echo "TEST: live workspace idle 1h is kept at high pressure (under 3h threshold)"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000003 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "1 hour ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  check "base survived at high pressure" "$([ -d "$base" ] && echo yes || echo no)"
  check "logged keep with idle reason" \
    "$(grep -q 'keep 10000000.*under pressure 90%' <<<"$out" && echo yes || echo no)"
}

test_lgtm_workspace_idle_45m_high_pressure_reaped() {
  echo "TEST: lgtm-pr-* workspace idle 45min is reaped at high pressure (>= 30m threshold)"
  local root wt base out
  root="$(new_root)"
  wt="$root/lgtm-pr-1234"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000004 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "45 minutes ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  check "lgtm base reaped at high pressure" "$([ ! -d "$base" ] && echo yes || echo no)"
  check "lgtm workspace untouched" "$([ -d "$wt" ] && echo yes || echo no)"
  check "logged lgtm reap under pressure" \
    "$(grep -q 'reaped 10000000.*under pressure 90%' <<<"$out" && echo yes || echo no)"
}

test_non_lgtm_workspace_idle_45m_high_pressure_kept() {
  echo "TEST: non-lgtm workspace idle 45min is kept at high pressure (< 180m threshold)"
  local root wt base out
  root="$(new_root)"
  wt="$root/feature-branch"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000005 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "45 minutes ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  check "non-lgtm base survived at high pressure" "$([ -d "$base" ] && echo yes || echo no)"
  check "logged keep with idle reason" \
    "$(grep -q 'keep 10000000.*under pressure 90%' <<<"$out" && echo yes || echo no)"
}

test_live_server_high_pressure_kept() {
  echo "TEST: live server pins base even under high pressure and idle 4h"
  local root wt base out pid
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000006 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "4 hours ago" "$base/command.log"
  sleep 300 &
  pid=$!
  pids+=("$pid")
  echo "$pid" > "$base/server/server.pid.txt"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  check "base with live server survives under pressure" "$([ -d "$base" ] && echo yes || echo no)"
  check "names the live server pid" \
    "$(grep -q "server pid $pid alive" <<<"$out" && echo yes || echo no)"
}

test_missing_command_log_high_pressure_kept() {
  echo "TEST: missing command.log keeps base even under high pressure"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000007 "$wt")"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=90)"
  check "base survives without command.log" "$([ -d "$base" ] && echo yes || echo no)"
  check "logs reason for missing command.log" \
    "$(grep -q 'keep 10000000.*missing command\.log' <<<"$out" && echo yes || echo no)"
}

test_non_numeric_used_pct_treated_as_no_pressure() {
  echo "TEST: non-numeric BAZEL_REAP_USED_PCT is treated as no pressure"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000008 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "4 hours ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_USED_PCT=notanumber)"
  check "base survives when used_pct is non-numeric" "$([ -d "$base" ] && echo yes || echo no)"
  check "logs workspace live (no pressure)" \
    "$(grep -q 'keep 10000000.* (workspace live' <<<"$out" && echo yes || echo no)"
}

test_dry_run_under_pressure() {
  echo "TEST: rehearsal mode under pressure classifies but does not delete"
  local root wt base out
  root="$(new_root)"
  wt="$root/live-worktree"
  mkdir -p "$wt"
  base="$(make_base "$root" 10000000000000000000000000000009 "$wt")"
  echo "log" > "$base/command.log"
  touch -d "4 hours ago" "$base/command.log"
  out="$(run_reaper "$root" BAZEL_REAP_DRY_RUN=1 BAZEL_REAP_USED_PCT=90)"
  check "base still present after rehearsal under pressure" "$([ -d "$base" ] && echo yes || echo no)"
  check "says 'would reap' with under pressure" \
    "$(grep -q 'would reap 10000000.*under pressure 90%' <<<"$out" && echo yes || echo no)"
  check "does not claim to have reaped" \
    "$(! grep -q '^\[bazel-reap\] reaped' <<<"$out" && echo yes || echo no)"
}

# ---------------------------------------------------------------------------

echo "=== bazel-reap regression tests ==="
test_keeps_live_workspace_without_server
test_keeps_live_server_despite_missing_workspace
test_keeps_base_without_marker
test_keeps_base_with_empty_marker
test_skips_install_and_cache
test_reaps_readonly_tree
test_dry_run_deletes_nothing
test_rate_limit
test_resumes_staged_leftover
test_missing_base_dir_is_not_an_error
test_never_exits_nonzero
test_live_workspace_idle_4h_low_pressure_kept
test_live_workspace_idle_4h_high_pressure_reaped
test_live_workspace_idle_1h_high_pressure_kept
test_lgtm_workspace_idle_45m_high_pressure_reaped
test_non_lgtm_workspace_idle_45m_high_pressure_kept
test_live_server_high_pressure_kept
test_missing_command_log_high_pressure_kept
test_non_numeric_used_pct_treated_as_no_pressure
test_dry_run_under_pressure

echo
echo "=== $pass_count passed, $fail_count failed ==="
[ "$fail_count" -eq 0 ]
