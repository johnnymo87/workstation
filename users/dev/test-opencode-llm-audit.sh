#!/usr/bin/env bash
# Tests for the opencode-llm-audit follower's pool fan-out (workstation-ofma).
#
# WHY: under the mn9r M5 serve pool (cloudbox K=4) the follower must capture the
# `service=llm ...` attribution lines of EVERY serve, not just the first one it
# pgreps. opencode-patched 1.17.x writes every process to a single shared
# `opencode.log` (all serves -> one inode), so a naive one-tail-per-pid fan-out
# would attach K tails to the SAME inode and duplicate every line. The fix fans
# out one follower per DISTINCT log inode (dedupe by inode): exactly one follower
# today, K followers if opencode ever reverts to per-process logs.
#
# This extracts the REAL helper functions from the deployed script text (via
# `nix eval` of the cloudbox home config) and exercises them against real
# fixture processes + temp dirs -- mirroring users/dev/test-disk-cleanup-worktrees.sh.
#
# Run: bash users/dev/test-opencode-llm-audit.sh
set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nix_file="$repo_root/users/dev/opencode-llm-audit.nix"
tmpdir="$(mktemp -d /tmp/opencode/llm-audit-test.XXXXXX)"
holders=()
followers=()
cleanup() {
  local p
  for p in "${followers[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  for p in "${holders[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fail=1; fi
}
want_grep() { # want_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  not found in $3: $2"; fail=1; fi
}
deny_grep() { # deny_grep <desc> <fixed-string> <file>
  if grep -qF -- "$2" "$3"; then
    echo "FAIL: $1"; echo "  unexpectedly present in $3: $2"; fail=1; else
    echo "ok: $1"; fi
}

# ---- extract the REAL follower script + its testable helpers ----------------
script_src="$tmpdir/opencode-llm-audit"
nix --extra-experimental-features 'nix-command flakes dynamic-derivations' \
  eval --raw "git+file:$repo_root#homeConfigurations.cloudbox.config.home.file.\".local/bin/opencode-llm-audit\".text" \
  > "$script_src" 2>"$tmpdir/nix.err" || {
    echo "FAIL: could not nix-eval the opencode-llm-audit script text"
    cat "$tmpdir/nix.err" >&2
    exit 1
  }

# Slice the sentinel-delimited helper block and source it, so we test the actual
# deployed code rather than a copy.
helpers="$tmpdir/helpers.sh"
python3 - "$script_src" "$helpers" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
b = "# === BEGIN TESTABLE HELPERS ==="
e = "# === END TESTABLE HELPERS ==="
i, j = src.find(b), src.find(e)
if i == -1 or j == -1:
    sys.stderr.write("sentinel helper block not found in script\n")
    sys.exit(2)
block = src[i + len(b):j]
pathlib.Path(sys.argv[2]).write_text(
    "#!/usr/bin/env bash\nset -uo pipefail\n" + block + "\n"
)
PY

# shellcheck disable=SC1090
. "$helpers"

for fn in find_log_fd dedupe_by_inode discover_serve_log_fds capture_filter; do
  if ! declare -F "$fn" >/dev/null; then
    echo "FAIL: helper '$fn' not defined in deployed script"; fail=1
  fi
done
if [ "$fail" -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi

# ---- dedupe_by_inode (pure) -------------------------------------------------
out="$(printf '100 5 /proc/5/fd/3\n200 7 /proc/7/fd/4\n' | dedupe_by_inode)"
check "distinct inodes pass through" $'100 5 /proc/5/fd/3\n200 7 /proc/7/fd/4' "$out"

out="$(printf '100 5 /proc/5/fd/3\n100 6 /proc/6/fd/7\n100 8 /proc/8/fd/9\n' | dedupe_by_inode)"
check "duplicate inode collapses to first occurrence" "100 5 /proc/5/fd/3" "$out"

out="$(printf '100 5 a\n200 6 b\n100 7 c\n200 8 d\n300 9 e\n' | dedupe_by_inode)"
check "interleaved dupes -> one line per inode, order preserved" $'100 5 a\n200 6 b\n300 9 e' "$out"

out="$(printf '' | dedupe_by_inode)"
check "empty input -> empty output" "" "$out"

# ---- capture_filter (new opencode 1.17.x log format) ------------------------
# opencode-patched 1.17.x logs `message=stream ...` (success attribution) and
# `message="stream error" ...` (error/quota), NOT the old `service=llm`. The
# 100k+ `message=evaluated permission` lines echo arbitrary command text and
# must be dropped BEFORE matching so trigger words inside a command can't create
# false positives.
ok_line='timestamp=T level=INFO message=stream providerID=google-vertex-anthropic modelID=claude-opus-4-8@default session.id=ses_AAA small=false agent=build mode=primary'
err_line='timestamp=T level=ERROR message="stream error" providerID=openai modelID=gpt-5.5 session.id=ses_ERR small=false agent=oracle mode=subagent error.error="AI_APICallError: RESOURCE_EXHAUSTED"'
perm_line='timestamp=T level=INFO message=evaluated permission pattern="grep service=llm RESOURCE_EXHAUSTED status=429" action.action=allow'
loop_line='timestamp=T level=INFO message=loop session.id=ses_AAA step=57'
hash_line='timestamp=T level=INFO message=tracking hash=deadbeef'

check "captures the success attribution line (message=stream)" "$ok_line" "$(printf '%s\n' "$ok_line" | capture_filter)"
check "captures the stream-error line (message=\"stream error\")" "$err_line" "$(printf '%s\n' "$err_line" | capture_filter)"
check "drops permission-eval noise even with trigger words in cmd" "" "$(printf '%s\n' "$perm_line" | capture_filter)"
check "drops benign message=loop lines" "" "$(printf '%s\n' "$loop_line" | capture_filter)"
check "drops benign message=tracking lines" "" "$(printf '%s\n' "$hash_line" | capture_filter)"
mixed="$(printf '%s\n%s\n%s\n%s\n%s\n' "$ok_line" "$perm_line" "$err_line" "$loop_line" "$hash_line" | capture_filter | grep -c .)"
check "mixed stream: keeps exactly the 2 real attribution/error lines" "2" "$mixed"

# ---- find_log_fd + discover_serve_log_fds (real /proc fixtures) -------------
LOGDIR="$tmpdir/logdir"; mkdir -p "$LOGDIR"
a="$LOGDIR/a.log"; b="$LOGDIR/b.log"; : > "$a"; : > "$b"
export LOGDIR

# Two holder processes, each holding a DISTINCT log file open (simulating two
# serves writing to per-process logs).
sleep 120 9>>"$a" & ha=$!; holders+=("$ha")
sleep 120 9>>"$b" & hb=$!; holders+=("$hb")

fd_a="$(find_log_fd "$ha" || true)"
check "find_log_fd locates the held log fd" "/proc/$ha/fd/9" "$fd_a"

# A process holding no log fd -> find_log_fd fails (non-zero, no output).
sleep 120 & hn=$!; holders+=("$hn")
if find_log_fd "$hn" >/dev/null 2>&1; then
  echo "FAIL: find_log_fd should fail for a process with no log fd"; fail=1
else
  echo "ok: find_log_fd fails for a process holding no log fd"
fi

ino_a="$(stat -L -c '%i' "$a")"
ino_b="$(stat -L -c '%i' "$b")"

# discover over both holders -> two distinct inodes.
disc="$(printf '%s\n%s\n' "$ha" "$hb" | discover_serve_log_fds | dedupe_by_inode)"
nlines="$(printf '%s\n' "$disc" | grep -c . || true)"
check "discover+dedupe over 2 distinct logs -> 2 followers" "2" "$nlines"
printf '%s\n' "$disc" | grep -q "^$ino_a " && echo "ok: inode A discovered" || { echo "FAIL: inode A not discovered"; fail=1; }
printf '%s\n' "$disc" | grep -q "^$ino_b " && echo "ok: inode B discovered" || { echo "FAIL: inode B not discovered"; fail=1; }

# Two holders on the SAME file (shared inode, the cloudbox 1.17.x reality):
# discover+dedupe must collapse to ONE follower so lines are not duplicated.
sleep 120 9>>"$a" & ha2=$!; holders+=("$ha2")
disc2="$(printf '%s\n%s\n' "$ha" "$ha2" | discover_serve_log_fds | dedupe_by_inode)"
n2="$(printf '%s\n' "$disc2" | grep -c . || true)"
check "two holders, shared inode -> exactly ONE follower (no dupes)" "1" "$n2"

# ---- integration: fan-out + real capture_filter captures ALL distinct logs --
# Use the REAL discover+dedupe to compute the attach set and the REAL
# capture_filter, then assert message=stream lines from BOTH logs land in OUT
# while the permission-eval noise (with trigger words) is dropped.
OUT="$tmpdir/llm.log"; : > "$OUT"
while read -r ino spid fd; do
  [ -n "$ino" ] || continue
  stdbuf -oL tail -n 0 --pid="$spid" --follow=descriptor "$fd" 2>/dev/null \
    | capture_filter >> "$OUT" &
  followers+=("$!")
done < <(printf '%s\n%s\n' "$ha" "$hb" | discover_serve_log_fds | dedupe_by_inode)

sleep 0.5
printf 'timestamp=T level=INFO message=stream providerID=p modelID=m session.id=ses_AAA small=false agent=build mode=primary\n' >> "$a"
printf 'timestamp=T level=INFO message=stream providerID=p modelID=m session.id=ses_BBB small=false agent=plan mode=primary\n' >> "$b"
printf 'timestamp=T level=INFO message=evaluated permission pattern="grep service=llm RESOURCE_EXHAUSTED"\n' >> "$a"
# poll briefly for the lines to flush through tail|capture_filter
for _ in $(seq 1 20); do
  grep -q ses_AAA "$OUT" && grep -q ses_BBB "$OUT" && break
  sleep 0.25
done
grep -q 'ses_AAA' "$OUT" && echo "ok: captured serve A (ses_AAA)" || { echo "FAIL: missed serve A"; fail=1; }
grep -q 'ses_BBB' "$OUT" && echo "ok: captured serve B (ses_BBB)" || { echo "FAIL: missed serve B"; fail=1; }
check "permission-eval noise filtered out (no false positives)" "0" "$(grep -c 'evaluated permission' "$OUT" || true)"

# ---- source guards (opencode-llm-audit.nix) --------------------------------
want_grep "helper sentinel block present"          '# === BEGIN TESTABLE HELPERS ===' "$nix_file"
want_grep "dedupe_by_inode defined"                'dedupe_by_inode() {'              "$nix_file"
want_grep "discover_serve_log_fds defined"         'discover_serve_log_fds() {'       "$nix_file"
want_grep "capture_filter defined"                 'capture_filter() {'               "$nix_file"
want_grep "per-inode follower map (associative)"   'declare -A'                       "$nix_file"
want_grep "loop feeds discover|dedupe into attach" 'discover_serve_log_fds'           "$nix_file"
want_grep "loop pipes through capture_filter"      '| capture_filter'                 "$nix_file"
want_grep "matches new message=stream attribution" 'message="?stream'                "$nix_file"
want_grep "excludes permission-eval noise"         'message=evaluated permission'     "$nix_file"
deny_grep "no first-match break in discovery"      'Picks the first matching one.'    "$nix_file"
# The obsolete PATTERN anchored its include regex on `service=llm|RESOURCE...`;
# assert that exact anchor is gone (prose may still mention the old token).
deny_grep "drops the obsolete service=llm PATTERN" 'service=llm|RESOURCE_EXHAUSTED'   "$nix_file"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
