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

# A SCOPED build (workstation-6w7i.7) degrades with a warning wherever there is
# no user manager, a build sandbox included. Run the generic assertions below
# on a copy with scoping off; the scoped path has its own section further down.
shipped_script="$wrapper_script"
if ! grep -qx 'SLICE_NAME=""' "$shipped_script"; then
  mkdir -p "$tmp_dir/plain"
  sed -e 's|^SLICE_NAME=.*|SLICE_NAME=""|' "$shipped_script" > "$tmp_dir/plain/bash"
  chmod +x "$tmp_dir/plain/bash"
  SHELL_BIN="$tmp_dir/plain/bash"
  wrapper_script="$SHELL_BIN"
fi

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

# ---- Per-command scopes (workstation-6w7i.7) --------------------------------
# SHELL_BIN may be the unscoped build (SLICE_NAME="") or a scoped one. Either
# way, exercise the scoped code path through a copy with a fake systemd-run,
# since a build sandbox has no user manager.
slice_line=$(grep -m1 '^SLICE_NAME=' "$shipped_script" || true)
check "wrapper has a SLICE_NAME line" "1" "$([ -n "$slice_line" ] && echo 1 || echo 0)"
if [ -n "${EXPECT_SLICE+x}" ]; then
  check "shipped slice is the expected one" "SLICE_NAME=\"$EXPECT_SLICE\"" "$slice_line"
fi
if [ "$slice_line" = 'SLICE_NAME=""' ]; then
  err="$("$SHELL_BIN" -c 'true' 2>&1 >/dev/null)"
  check "unscoped build never mentions scopes" "" "$err"
fi

fake_dir="$tmp_dir/fake"
mkdir -p "$fake_dir"
# Shebang from PATH: a build sandbox has no /usr/bin/env.
echo "#!$(command -v bash)" > "$fake_dir/systemd-run"
cat >> "$fake_dir/systemd-run" <<'EOF'
printf '%s\n' "$*" >> "$FAKE_LOG"
for a in "$@"; do
  case "$a" in --unit=goose-agent-probe-*) exit "${FAKE_PROBE_RC:-0}" ;; esac
done
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOF
chmod +x "$fake_dir/systemd-run"

scoped_wrapper="$tmp_dir/scoped/bash"
mkdir -p "$tmp_dir/scoped"
sed -e "s|^SYSTEMD_RUN=.*|SYSTEMD_RUN=\"$fake_dir/systemd-run\"|" \
    -e 's|^SLICE_NAME=.*|SLICE_NAME="test-agent"|' \
    "$wrapper_script" > "$scoped_wrapper"
chmod +x "$scoped_wrapper"
export FAKE_LOG="$tmp_dir/fake.log"

: > "$FAKE_LOG"
out="$(env -u XDG_RUNTIME_DIR FAKE_PROBE_RC=0 "$scoped_wrapper" -c 'echo "$0|$XDG_RUNTIME_DIR"; printf "%s|" "$@"' _ x 'y z' 2>"$tmp_dir/err")"
check "scoped: command runs once, args intact, XDG_RUNTIME_DIR defaulted" "_|/run/user/$(id -u)
x|y z|" "$out"
check "scoped: nothing on stderr" "" "$(cat "$tmp_dir/err")"
check "scoped: probe + one real systemd-run" "2" "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
real_args="$(sed -n 2p "$FAKE_LOG")"
for want in "--user" "--scope" "--collect" "--slice=test-agent" "--expand-environment=no" \
            "-p OOMPolicy=continue" "-p MemoryMax=" "-p MemorySwapMax=" "-p TimeoutStopSec=30" \
            "--unit=goose-agent-"; do
  case "$real_args" in
    *"$want"*) ok "scoped: systemd-run gets $want" ;;
    *) bad "scoped: systemd-run lacks $want ($real_args)" ;;
  esac
done
probe_args="$(sed -n 1p "$FAKE_LOG")"
case "$probe_args" in
  *"--slice=test-agent"*) ok "probe targets the real slice (fails when the real call would)" ;;
  *) bad "probe lacks --slice ($probe_args)" ;;
esac

: > "$FAKE_LOG"
out="$(GOOSE_TOOL_SHELL_NO_SCOPE=1 FAKE_PROBE_RC=0 "$scoped_wrapper" -c 'echo optout' 2>"$tmp_dir/err")"
check "opt-out: command runs" "optout" "$out"
check "opt-out: systemd-run never called" "0" "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
check "opt-out: silent" "" "$(cat "$tmp_dir/err")"

out="$(FAKE_PROBE_RC=0 "$scoped_wrapper" -c 'echo "$0"')"
check "scoped: \$0 is plain bash" "bash" "$out"
out="$(FAKE_PROBE_RC=0 "$scoped_wrapper" -c 'exit 9')"; rc=$?
check "scoped: exit status propagates" "9" "$rc"

out="$(FAKE_PROBE_RC=0 "$scoped_wrapper" -c 'sh -c "cat /proc/self/oom_score_adj"')"
cur_adj="$(cat /proc/self/oom_score_adj)"
want_adj=$(( cur_adj > 500 ? cur_adj : 500 ))
check "scoped: command still runs at the floor" "$want_adj" "$out"

out="$(bash -c 'echo $$; exec "$1" -c "echo \$\$"' _ "$scoped_wrapper")"
first="$(sed -n 1p <<<"$out")"; second="$(sed -n 2p <<<"$out")"
check "scoped: same pid as goose spawned (exec chain)" "$first" "$second"

: > "$FAKE_LOG"
out="$(FAKE_PROBE_RC=1 "$scoped_wrapper" -c 'echo ran; exit 4' 2>"$tmp_dir/err")"; rc=$?
check "degrade: command runs exactly once" "ran" "$out"
check "degrade: exit status propagates" "4" "$rc"
check "degrade: only the probe was attempted" "1" "$(wc -l < "$FAKE_LOG" | tr -d ' ')"
check "degrade: one warning line" "1" "$(wc -l < "$tmp_dir/err" | tr -d ' ')"
case "$(cat "$tmp_dir/err")" in
  *"running UNSCOPED"*) ok "degrade: warning says UNSCOPED" ;;
  *) bad "degrade: warning text ($(cat "$tmp_dir/err"))" ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "goose-tool-shell tests FAILED ($fail)" >&2
  exit 1
fi
echo "ALL PASS (goose-tool-shell, $pass assertions)"
