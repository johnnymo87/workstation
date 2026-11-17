#!/usr/bin/env bash
# Tests for pkgs/goose-tool-shell (bead workstation-pp9r.4).
# Usage: SHELL_BIN=<pkg>/bin/bash bash test.sh
set -uo pipefail

: "${SHELL_BIN:?set SHELL_BIN to the wrapper bin/bash}"

pass=0
fail=0
ok() { echo "ok   - $1"; pass=$((pass + 1)); }
bad() { echo "FAIL - $1"; fail=$((fail + 1)); }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# The file NAME is what goose shows the model ("Commands run under `bash`").
check "binary is named bash" "bash" "$(basename "$SHELL_BIN")"

# The wrapper script behind the symlink, for the floor and for a test copy.
wrapper_script="$(readlink -f "$SHELL_BIN")"
floor_line=$(grep -m1 '^OOM_SCORE_ADJ_FLOOR=' "$wrapper_script" || true)
check "shipped floor is 500" 'OOM_SCORE_ADJ_FLOOR="500"' "$floor_line"

# Exactly how goose calls it: <shell> -c <line>.
out="$("$SHELL_BIN" -c 'echo "a b"; printf "%s|" "$@"' _ x 'y z')"
check "-c line runs and positional args pass through" "a b
x|y z|" "$out"

out="$("$SHELL_BIN" -c 'exit 7')"; rc=$?
check "exit status propagates" "7" "$rc"

out="$("$SHELL_BIN" -c 'echo "$0"')"
check "\$0 is plain bash, as before the wrapper" "bash" "$out"

heredoc_line=$'cat <<EOF\nhere $((1 + 1))\nEOF'
out="$("$SHELL_BIN" -c "$heredoc_line")"
check "heredoc and arithmetic (bash, not sh)" "here 2" "$out"

# exec, not fork: the command's pid is the pid goose spawned, so goose's
# process-group kill still reaches it.
out="$(bash -c 'echo $$; exec "$1" -c "echo \$\$"' _ "$SHELL_BIN")"
first="$(sed -n 1p <<<"$out")"; second="$(sed -n 2p <<<"$out")"
check "wrapper execs in place (same pid)" "$first" "$second"

err="$("$SHELL_BIN" -c 'true' 2>&1 >/dev/null)"
check "nothing on stderr" "" "$err"

# The floor. Asserting "reads 500" would pass vacuously wherever the caller
# already runs at 500, so substitute a floor one above the current value: the
# assertion then passes only if the wrapper actually wrote it.
cur_adj="$(cat /proc/self/oom_score_adj)"
if [ "$cur_adj" -ge 999 ]; then
  bad "cannot test the floor: this process already runs at $cur_adj"
else
  test_floor=$((cur_adj + 1))
  floor_wrapper="$tmp_dir/bash"
  sed -e "s|^OOM_SCORE_ADJ_FLOOR=.*|OOM_SCORE_ADJ_FLOOR=\"$test_floor\"|" \
    "$wrapper_script" > "$floor_wrapper"
  chmod +x "$floor_wrapper"

  out="$("$floor_wrapper" -c 'cat /proc/self/oom_score_adj' 2>"$tmp_dir/err")"
  check "command runs at the floor (caller $cur_adj -> $test_floor)" "$test_floor" "$out"
  check "raising writes nothing to stderr" "" "$(cat "$tmp_dir/err")"

  out="$("$floor_wrapper" -c 'sh -c "cat /proc/self/oom_score_adj"')"
  check "descendants inherit the floor" "$test_floor" "$out"

  check "caller's own value is untouched" "$cur_adj" "$(cat /proc/self/oom_score_adj)"

  above=$((test_floor + 1))
  out="$(bash -c 'echo "$1" > /proc/self/oom_score_adj; exec "$2" -c "cat /proc/self/oom_score_adj"' \
    _ "$above" "$floor_wrapper")"
  check "a caller above the floor is not lowered" "$above" "$out"
fi

if [ "$fail" -ne 0 ]; then
  echo "goose-tool-shell tests FAILED ($fail)" >&2
  exit 1
fi
echo "ALL PASS (goose-tool-shell, $pass assertions)"
