#!/usr/bin/env bash
# Tests for the lgtm-gh LAUNCHER (default.nix).
#
# The wrapper's logic lives in the private lgtm repo
# (scripts/lgtm-gh/lgtm-gh.sh, with its own suites). What ships from here is
# only the launcher, so this checks only what the launcher promises:
#   1. it runs the script at the path it was built with, args verbatim,
#      stdin, stdout and exit code passed through;
#   2. the script sees the pinned coreutils, gh, jq and node first on PATH
#      (dispatched sessions can run under a restricted systemd PATH, and the
#      approval gate runs node under `env -i` with only node's directory);
#   3. it refuses, and runs nothing, when that script is absent.
#
# Usage: test.sh <launcher-with-fixture-script> <launcher-with-missing-script> <stub-gh>
# flake.nix (lgtm-gh-launcher-tests) builds all three.
set -o errexit -o nounset -o pipefail

launcher="${1:?usage: test.sh <launcher> <launcher-missing> <stub-gh>}"
launcher_missing="${2:?usage: test.sh <launcher> <launcher-missing> <stub-gh>}"
stub_gh="${3:?usage: test.sh <launcher> <launcher-missing> <stub-gh>}"

pass=0
fail=0
assert_eq() {
  if [ "$1" = "$2" ]; then printf 'PASS  %s\n' "$3"; pass=$((pass + 1))
  else printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$3" "$1" "$2"; fail=$((fail + 1)); fi
}
assert_contains() {
  if grep -qF -- "$2" <<<"$1"; then printf 'PASS  %s\n' "$3"; pass=$((pass + 1))
  else printf 'FAIL  %s\n        wanted substring: %s\n        in:               %s\n' "$3" "$2" "$1"; fail=$((fail + 1)); fi
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# A decoy gh first on the inherited PATH: the pinned one must still win.
mkdir -p "$sandbox/decoy"
printf '#!/bin/sh\necho decoy\n' > "$sandbox/decoy/gh"
chmod +x "$sandbox/decoy/gh"
export PATH="$sandbox/decoy:$PATH"

# 1. Args, stdin, stdout, exit code.
out="$(printf 'from-stdin' | FIXTURE_RC=7 "$launcher" pr view 'a b' --json "x y" 2>"$sandbox/err")" && rc=0 || rc=$?
assert_eq "7" "$rc" "exit code of the script is the launcher's"
assert_contains "$out" "ARGC=5" "argument count preserved"
assert_contains "$out" "ARG1=pr|ARG2=view|ARG3=a b|ARG4=--json|ARG5=x y" "arguments passed verbatim, spaces intact"
assert_contains "$out" "STDIN=from-stdin" "stdin reaches the script"

# 2. Pinned tools first on PATH.
assert_eq "$stub_gh/bin/gh" "$(sed -n 's/^GH=//p' <<<"$out")" "gh is the pinned one, not the decoy earlier on PATH"
for tool in jq node tr timeout; do
  where="$(sed -n "s/^$tool=//p" <<<"$out")"
  assert_contains "$where" "/nix/store/" "$tool resolves to a pinned store path"
done
assert_contains "$(sed -n 's/^PATH=//p' <<<"$out")" "$sandbox/decoy" "inherited PATH is kept after the pinned entries"

# 3. Missing script: refuse, name the path, run nothing.
err="$("$launcher_missing" pr merge 1 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "missing script -> exit 1"
assert_contains "$err" "lgtm-gh: /nonexistent/lgtm/scripts/lgtm-gh/lgtm-gh.sh not found" "missing script names the path"
assert_contains "$err" "lgtm checkout" "missing script says where the wrapper is expected to come from"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh launcher tests passed"
