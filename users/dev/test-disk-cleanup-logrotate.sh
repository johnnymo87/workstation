#!/usr/bin/env bash
# Regression tests for disk-cleanup's opencode.log rotation (section 6,
# workstation-o5s1.6). Run: bash users/dev/test-disk-cleanup-logrotate.sh
#
# WHAT IS WORTH PINNING. The rotation truncates a file that ~16 live
# processes hold open for writing. It is only safe because every writer opened
# it O_APPEND, so the next write reseeks to the new EOF. A future "tidier"
# rotation (mv + recreate, or rm) frees nothing while fds are open and silently
# diverts every serve's logging into an unlinked inode. So the suite pins:
#   - the inode survives rotation (no mv/rm of the live file);
#   - an O_APPEND writer that stays open writes at offset 0 afterwards (no hole),
#     with a CONTROL showing that a non-append writer would leave one -- that
#     control is what proves the hole assertion can fail;
#   - the tail is saved before truncating, and a failed save truncates nothing.

set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'chmod -R u+w "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"' EXIT

pass_count=0
fail_count=0
pass() { printf 'PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
fail() {
  printf 'FAIL  %s\n' "$1"
  shift || true
  for line in "$@"; do printf '      %s\n' "$line"; done
  fail_count=$((fail_count + 1))
}

# Seam: same arrangement as test-disk-cleanup-docker.sh -- a flake check hands
# us home-manager's own deployed bytes so the sandbox never runs nix.
script_src="$tmpdir/disk-cleanup"
harness="$tmpdir/logrotate-harness"
if [ -n "${DISK_CLEANUP_SRC:-}" ]; then
  cp "$DISK_CLEANUP_SRC" "$script_src"
else
  nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
    eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/disk-cleanup\".text" \
    > "$script_src"
fi
[ -s "$script_src" ] || { echo "FAIL: empty disk-cleanup source"; exit 1; }

python3 - "$script_src" "$harness" "$(command -v bash)" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
start = src.find("# --- 6. OpenCode log rotation")
if start == -1:
    raise SystemExit("FAIL: no '--- 6. OpenCode log rotation' section in disk-cleanup")
end = src.index("\n# --- Main ---", start)
section = src[start:end]
if "rotate_opencode_log() {" not in section:
    raise SystemExit("FAIL: extracted section 6 does not define rotate_opencode_log")
pathlib.Path(sys.argv[2]).write_text(
    f"#!{sys.argv[3]}\n"
    "set -euo pipefail\n"
    "log() { printf '[disk-cleanup-test] %s\\n' \"$*\"; }\n"
    f"{section}\n"
    "rotate_opencode_log\n"
)
PY
chmod +x "$harness"

MiB=$((1024 * 1024))
new_home() {
  home="$tmpdir/home-$1"
  logdir="$home/.local/share/opencode/log"
  log_f="$logdir/opencode.log"
  mkdir -p "$logdir"
}
# Never aborts the suite: a harness that dies is reported by the assertions
# (and in $tmpdir/out), not by errexit killing the tally line.
run() { HOME="$home" "$harness" > "$tmpdir/out" 2>&1 || echo "harness exited $?" >> "$tmpdir/out"; }
size() { stat -c %s "$1"; }

# 1. Missing file: nothing to do, exit 0.
new_home missing
run
if ! grep -q "harness exited" "$tmpdir/out" && [ ! -e "$log_f.1" ]; then pass "a missing opencode.log is a no-op"
else fail "a missing opencode.log is a no-op" "$(cat "$tmpdir/out")"; fi

# 2. Under the threshold: untouched.
new_home small
head -c $((5 * MiB)) /dev/zero | tr '\0' 'a' > "$log_f"
run
if [ "$(size "$log_f")" = $((5 * MiB)) ] && [ ! -e "$log_f.1" ]; then
  pass "a log under 512M is left alone"
else fail "a log under 512M is left alone" "$(cat "$tmpdir/out")"; fi

# 3. Over the threshold, with a live O_APPEND writer holding the file open.
new_home big
truncate -s $((600 * MiB - 4)) "$log_f"; printf 'TAIL' >> "$log_f"   # sparse: cheap in a sandbox
ino_before=$(stat -c %i "$log_f")
exec 7>>"$log_f"   # O_APPEND, like every serve
run
ino_after=$(stat -c %i "$log_f")
if [ "$ino_before" = "$ino_after" ]; then pass "rotation keeps the live inode (no mv/rm)"
else fail "rotation keeps the live inode (no mv/rm)" "$ino_before -> $ino_after"; fi
if [ "$(size "$log_f.1")" = $((64 * MiB)) ] && [ "$(tail -c 4 "$log_f.1")" = TAIL ]; then
  pass "the last 64M are kept in opencode.log.1"
else fail "the last 64M are kept in opencode.log.1" "size=$(size "$log_f.1" 2>/dev/null)"; fi
if [ "$(size "$log_f")" = 0 ]; then pass "the live file is truncated to 0"
else fail "the live file is truncated to 0" "size=$(size "$log_f")"; fi
printf 'after\n' >&7
exec 7>&-
if [ "$(size "$log_f")" = 6 ] && [ "$(cat "$log_f")" = after ]; then
  pass "an open O_APPEND writer lands at offset 0 afterwards (no sparse hole)"
else fail "an open O_APPEND writer lands at offset 0 afterwards (no sparse hole)" "size=$(size "$log_f")"; fi

# 3b. CONTROL for the hole assertion: a writer WITHOUT O_APPEND leaves a hole
# after the same truncate, so the assertion above can fail. If this ever
# passes as "no hole", the check above has stopped measuring anything.
ctl="$tmpdir/control.log"
head -c $((1 * MiB)) /dev/zero > "$ctl"
exec 8<>"$ctl"                         # read-write, NOT append
head -c $((1 * MiB)) /dev/zero >&8     # advance this fd's offset to 1M
truncate -s 0 "$ctl"
printf 'after\n' >&8
exec 8>&-
if [ "$(size "$ctl")" -gt 6 ]; then pass "control: a non-append writer DOES leave a hole"
else fail "control: a non-append writer DOES leave a hole" "size=$(size "$ctl")"; fi

# 4. If the tail cannot be saved, nothing is truncated.
new_home rofail
truncate -s $((600 * MiB)) "$log_f"
chmod 555 "$logdir"                    # opencode.log.1.tmp cannot be created
run
chmod 755 "$logdir"
if [ "$(size "$log_f")" = $((600 * MiB)) ] && grep -q 'not truncating' "$tmpdir/out"; then
  pass "a failed tail save truncates nothing"
else fail "a failed tail save truncates nothing" "size=$(size "$log_f")" "$(cat "$tmpdir/out")"; fi

printf '=== %d passed, %d failed ===\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ]
