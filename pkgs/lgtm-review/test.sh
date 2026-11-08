#!/usr/bin/env bash
# Tests for the lgtm-review LAUNCHER (default.nix).
#
# The CLI logic lives in the private lgtm repo (scripts/lgtm-review and
# src/reviewCli.ts). What ships from here is only the launcher, so this checks
# only what the launcher promises:
#   1. it runs the script at the path it was built with, args verbatim,
#      stdin, stdout and exit code passed through;
#   2. it refuses, and runs nothing, when that script is absent.
#
# Usage: test.sh <launcher-with-fixture-script> <launcher-with-missing-script>
# flake.nix (lgtm-review-launcher-tests) passes them.
set -o errexit -o nounset -o pipefail

launcher="${1:?usage: test.sh <launcher> <launcher-missing>}"
launcher_missing="${2:?usage: test.sh <launcher> <launcher-missing>}"

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
assert_starts_with() {
  case "$1" in
    "$2"*) printf 'PASS  %s\n' "$3"; pass=$((pass + 1)) ;;
    *)     printf 'FAIL  %s\n        wanted prefix: %s\n        in:            %s\n' "$3" "$2" "$1"; fail=$((fail + 1)) ;;
  esac
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# 1. Args, stdin, stdout, exit code.
out="$(printf 'from-stdin' | FIXTURE_RC=7 "$launcher" status 'a b' --all "x y" 2>"$sandbox/err")" && rc=0 || rc=$?
assert_eq "7" "$rc" "exit code of the script is the launcher's"
assert_contains "$out" "ARGC=4" "argument count preserved"
assert_contains "$out" "ARG1=status|ARG2=a b|ARG3=--all|ARG4=x y" "arguments passed verbatim, spaces intact"
assert_contains "$out" "STDIN=from-stdin" "stdin reaches the script"

# 2. Missing script: refuse, name the path, run nothing.
out="$("$launcher_missing" status 'a b' 2>"$sandbox/err")" && rc=0 || rc=$?
err="$(cat "$sandbox/err")"
assert_eq "1" "$rc" "missing script -> exit 1"
assert_eq "" "$out" "missing script -> no stdout (fixture did not run)"
assert_starts_with "$err" "lgtm-review: not installed here (" "missing script stderr starts with expected prefix"
assert_contains "$err" "/nonexistent/lgtm/scripts/lgtm-review" "missing script stderr names the path"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-review launcher tests passed"
