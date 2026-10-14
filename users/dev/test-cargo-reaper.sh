#!/usr/bin/env bash
# Regression tests for cargo-reap, the daytime idle cargo target reaper.
# Run: bash users/dev/test-cargo-reaper.sh
#
# WHY THIS EXISTS. On 2026-10-13 cloudbox's root disk reached 100%. About 97G
# was idle cargo target/ directories under ~/projects/{goose-patched*,honk*}
# that had not been built in hours. Nothing automatic cleans cargo target dirs.
# The nightly disk-cleanup does not touch them, and bazel-reap only handles
# Bazel output bases whose workspace is gone.
#
# WHAT MAKES THIS SCRIPT DANGEROUS ENOUGH TO PIN. It deletes multi-gigabyte
# trees on a 15-minute timer, on a box shared by ~15 concurrent agent sessions.
# Reaping an active build's target directory destroys compiler artifacts mid-flight
# or forces a full rebuild. The probe must never mistake an active target
# (cwd, open fd, or memory-mapped proc-macro dlopen) as idle.
#
# ASYMMETRY AND FAIL-SAFES:
#   1. A target in use by cwd, exe, open fd, or /proc/<pid>/maps (rust-analyzer)
#      must be kept.
#   2. If /proc cannot be inspected, fail safe: keep everything.
#   3. Stat errors during idle-age calculation count as fresh (keep).
#   4. Deletion stages via atomic rename to trash on the same filesystem
#      before rmtree, so partial deletes can be cleaned up without reclassification.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'chmod -R u+w "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"' EXIT

pass_count=0
fail_count=0

pass() { printf '  PASS: %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; fail_count=$((fail_count + 1)); }

check() {
  local msg="$1" cond="$2"
  if [ "$cond" = "yes" ]; then pass "$msg"; else fail "$msg"; fi
}

script="$tmpdir/cargo-reap"
if [ -n "${CARGO_REAP_SRC:-}" ]; then
  cp "$CARGO_REAP_SRC" "$script"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/cargo-reap\".text" \
    > "$script"
fi
[ -s "$script" ] || { echo "FAIL: empty cargo-reap source"; exit 1; }
chmod +x "$script"

# ---------------------------------------------------------------------------
# Fixture helpers.
# ---------------------------------------------------------------------------

new_root() {
  local r
  r="$(mktemp -d "$tmpdir/root.XXXXXX")"
  printf '%s' "$r"
}

make_target() {
  local target_dir="$1"
  local age_hours="${2:-0}"
  local tag_content="${3:-Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n}"

  mkdir -p "$target_dir/debug/deps"
  if [ "$tag_content" != "none" ]; then
    printf '%b' "$tag_content" > "$target_dir/CACHEDIR.TAG"
  fi
  echo '{"rustc_fingerprint": 12345}' > "$target_dir/.rustc_info.json"
  echo "payload" > "$target_dir/debug/deps/libfoo.rlib"

  if [ "$age_hours" -gt 0 ]; then
    find "$target_dir" -depth | while read -r p; do
      touch -d "$age_hours hours ago" "$p"
    done
  fi
}

run_reaper() {
  local roots="$1"; shift
  local trash="${CARGO_REAP_TRASH:-$tmpdir/trash}"
  mkdir -p "$trash"
  env CARGO_REAP_ROOTS="$roots" CARGO_REAP_TRASH="$trash" "$@" "$script" 2>&1
}

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

test_idle_49h_low_pressure_reaped() {
  echo "TEST: target idle 49h at low pressure is reaped (hygiene tier)"
  local root out target
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 49
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  check "target reaped when idle 49h at low pressure" \
    "$([ ! -d "$target" ] && echo yes || echo no)"
  check "reports reaped in log" \
    "$(grep -q 'reaped .*proj/target' <<<"$out" && echo yes || echo no)"
}

test_idle_4h_low_pressure_kept() {
  echo "TEST: target idle 4h at low pressure is kept"
  local root out target
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 4
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  check "target kept when idle 4h at low pressure" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "reports keep in log" \
    "$(grep -q 'keep .*proj/target' <<<"$out" && echo yes || echo no)"
}

test_idle_4h_high_pressure_reaped() {
  echo "TEST: target idle 4h at high pressure is reaped (pressure tier)"
  local root out target
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 4
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=85)"
  check "target reaped when idle 4h at high pressure" \
    "$([ ! -d "$target" ] && echo yes || echo no)"
  check "reports reaped in log" \
    "$(grep -q 'reaped .*proj/target' <<<"$out" && echo yes || echo no)"
}

test_idle_1h_high_pressure_kept() {
  echo "TEST: target idle 1h at high pressure is kept"
  local root out target
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 1
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=85)"
  check "target kept when idle 1h at high pressure" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "reports keep in log" \
    "$(grep -q 'keep .*proj/target' <<<"$out" && echo yes || echo no)"
}

test_ignores_missing_or_non_cargo_tag() {
  echo "TEST: target without CACHEDIR.TAG or with non-cargo tag is ignored"
  local root out t1 t2
  root="$(new_root)"
  t1="$root/proj1/target"
  t2="$root/proj2/target"
  make_target "$t1" 49 "none"
  make_target "$t2" 49 "Signature: 8a477f597d28d172789f06886806bc55\n# Tag created by other_tool\n"
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  check "target without CACHEDIR.TAG is ignored" \
    "$([ -d "$t1" ] && echo yes || echo no)"
  check "target with non-cargo tag is ignored" \
    "$([ -d "$t2" ] && echo yes || echo no)"
}

test_ignores_symlink_target() {
  echo "TEST: symlinked target is ignored"
  local root out real_t sym_t
  root="$(new_root)"
  real_t="$root/real_target"
  make_target "$real_t" 49
  mkdir -p "$root/proj"
  sym_t="$root/proj/target"
  ln -s "$real_t" "$sym_t"
  out="$(run_reaper "$root/proj" CARGO_REAP_USED_PCT=50)"
  check "symlinked target is ignored" \
    "$([ -L "$sym_t" ] && echo yes || echo no)"
  check "real target behind symlink untouched" \
    "$([ -d "$real_t" ] && echo yes || echo no)"
}

test_keeps_target_in_use_by_cwd() {
  echo "TEST: target in use as process cwd is kept"
  local root out target sleeper_pid
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 49
  (cd "$target" && exec sleep 60) &
  sleeper_pid=$!
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  check "target in use by process cwd is kept" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "reports keep in use in log" \
    "$(grep -q 'keep .*proj/target.*in use' <<<"$out" && echo yes || echo no)"
}

test_keeps_target_in_use_by_mapped_file() {
  echo "TEST: target with file memory-mapped by process is kept (rust-analyzer guard)"
  local root out target mapped_file mapper_pid
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 49
  mapped_file="$target/debug/deps/libmacro.so"
  echo "elf-macro-binary" > "$mapped_file"
  find "$target" -depth | while read -r p; do touch -d "49 hours ago" "$p"; done

  python3 -c '
import mmap, sys, time
with open(sys.argv[1], "rb") as f:
    m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    time.sleep(60)
' "$mapped_file" &
  mapper_pid=$!
  sleep 0.1
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  kill "$mapper_pid" 2>/dev/null || true
  wait "$mapper_pid" 2>/dev/null || true
  check "target with file mapped by process is kept" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "reports keep in use in log" \
    "$(grep -q 'keep .*proj/target.*in use' <<<"$out" && echo yes || echo no)"
}

test_unreadable_proc_keeps_everything() {
  echo "TEST: unreadable /proc keeps everything (fail safe)"
  local root out target empty_proc
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 49
  empty_proc="$tmpdir/empty_proc"
  mkdir -p "$empty_proc"
  out="$(run_reaper "$root" CARGO_REAP_PROC="$empty_proc" CARGO_REAP_USED_PCT=50)"
  check "target kept when /proc is unreadable" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "reports error reading /proc in log" \
    "$(grep -q 'reading /proc' <<<"$out" && echo yes || echo no)"
}

test_rate_limit_and_oldest_first() {
  echo "TEST: rate limit holds and oldest candidates are reaped first"
  local root out t1 t2 t3 t4
  root="$(new_root)"
  t1="$root/p1/target"
  t2="$root/p2/target"
  t3="$root/p3/target"
  t4="$root/p4/target"
  make_target "$t1" 100
  make_target "$t2" 80
  make_target "$t3" 60
  make_target "$t4" 50
  out="$(run_reaper "$root" CARGO_REAP_MAX=2 CARGO_REAP_USED_PCT=50)"
  check "oldest target 1 reaped" \
    "$([ ! -d "$t1" ] && echo yes || echo no)"
  check "oldest target 2 reaped" \
    "$([ ! -d "$t2" ] && echo yes || echo no)"
  check "younger target 3 kept" \
    "$([ -d "$t3" ] && echo yes || echo no)"
  check "younger target 4 kept" \
    "$([ -d "$t4" ] && echo yes || echo no)"
  check "reports rate limit reached in log" \
    "$(grep -q 'rate limit reached' <<<"$out" && echo yes || echo no)"
}

test_dry_run_deletes_nothing() {
  echo "TEST: rehearsal mode classifies but deletes nothing"
  local root out target
  root="$(new_root)"
  target="$root/proj/target"
  make_target "$target" 49
  out="$(run_reaper "$root" CARGO_REAP_DRY_RUN=1 CARGO_REAP_USED_PCT=50)"
  check "dry run leaves target intact" \
    "$([ -d "$target" ] && echo yes || echo no)"
  check "dry run says would reap" \
    "$(grep -q 'would reap .*proj/target' <<<"$out" && echo yes || echo no)"
  check "dry run does not claim reaped" \
    "$(grep -q '^\[cargo-reap\] reaped ' <<<"$out" && echo no || echo yes)"
}

test_leftover_trash_purged() {
  echo "TEST: leftovers in trash directory are purged on startup"
  local trash out staged
  trash="$tmpdir/custom_trash"
  mkdir -p "$trash/staged-proj-target.9999"
  echo "leftover garbage" > "$trash/staged-proj-target.9999/file"
  out="$(CARGO_REAP_TRASH="$trash" run_reaper "$tmpdir/empty_root")"
  check "trash leftover is purged" \
    "$([ ! -e "$trash/staged-proj-target.9999" ] && echo yes || echo no)"
  check "reports purged leftover in log" \
    "$(grep -q 'purged leftover staged-proj-target.9999' <<<"$out" && echo yes || echo no)"
}

test_skips_git_and_node_modules() {
  echo "TEST: .git and node_modules are not descended into"
  local root out t_real t_git t_node
  root="$(new_root)"
  t_real="$root/proj/target"
  t_git="$root/proj/.git/target"
  t_node="$root/proj/node_modules/target"
  make_target "$t_real" 49
  make_target "$t_git" 49
  make_target "$t_node" 49
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  check "repo target reaped" \
    "$([ ! -d "$t_real" ] && echo yes || echo no)"
  check ".git target untouched" \
    "$([ -d "$t_git" ] && echo yes || echo no)"
  check "node_modules target untouched" \
    "$([ -d "$t_node" ] && echo yes || echo no)"
}

test_finds_target_under_worktrees() {
  echo "TEST: target under .worktrees/Y/ is discovered and reaped"
  local root out wt_target
  root="$(new_root)"
  wt_target="$root/proj/.worktrees/feature/target"
  make_target "$wt_target" 49
  out="$(run_reaper "$root" CARGO_REAP_USED_PCT=50)"
  check "worktree target reaped" \
    "$([ ! -d "$wt_target" ] && echo yes || echo no)"
  check "reports reaped in log" \
    "$(grep -q 'reaped .*proj/.worktrees/feature/target' <<<"$out" && echo yes || echo no)"
}

test_missing_root_does_not_crash() {
  echo "TEST: absent root dir exits 0 cleanly"
  local rc
  "$script" >/dev/null 2>&1
  rc=$?
  # Also test explicitly with a non-existent path in CARGO_REAP_ROOTS
  env CARGO_REAP_ROOTS="$tmpdir/definitely-not-here" "$script" >/dev/null 2>&1
  local rc2=$?
  check "missing root exits 0" \
    "$([ "$rc" = 0 ] && [ "$rc2" = 0 ] && echo yes || echo no)"
}

# ---------------------------------------------------------------------------

echo "=== cargo-reap regression tests ==="
test_idle_49h_low_pressure_reaped
test_idle_4h_low_pressure_kept
test_idle_4h_high_pressure_reaped
test_idle_1h_high_pressure_kept
test_ignores_missing_or_non_cargo_tag
test_ignores_symlink_target
test_keeps_target_in_use_by_cwd
test_keeps_target_in_use_by_mapped_file
test_unreadable_proc_keeps_everything
test_rate_limit_and_oldest_first
test_dry_run_deletes_nothing
test_leftover_trash_purged
test_skips_git_and_node_modules
test_finds_target_under_worktrees
test_missing_root_does_not_crash

echo
echo "=== $pass_count passed, $fail_count failed ==="
[ "$fail_count" -eq 0 ]
