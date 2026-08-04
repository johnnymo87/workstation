#!/usr/bin/env bash
# Runner-coverage guard for assets/opencode/plugins/test/.
#
# WHY THIS EXISTS. This directory is served by TWO different test runners, and
# which one owns a file is decided purely by its NAME:
#
#   *.test.ts  -> vitest, via the `include` in vitest.config.ts
#   *.spec.ts  -> bun test, because those files import bun:test / bun:sqlite
#                 and cannot run under vitest at all
#
# That split is invisible and load-bearing. It already failed once: for months
# `test/oc-session-list.spec.ts` (34 tests, 986 assertions) was run by nothing.
# vitest excluded it by pattern, `npm test` therefore reported green over a
# suite it never loaded, and naming the file explicitly on the vitest CLI still
# printed "No test files found" because the filter intersects with `include`.
# Nothing anywhere failed. A test file that no runner claims is not a test.
#
# So: assert every file under test/ is CLAIMED by a runner, and that the naming
# taxonomy the claim depends on is exhaustive. A new `foo.tests.ts` or
# `foo.checks.ts` is ownerless, and this guard fails rather than letting it sit
# unrun.
#
# Being claimed is necessary but not sufficient -- a file must also actually
# EXECUTE. That half is enforced where the evidence lives: the plugin-vitest
# check compares the file set vitest really ran against the *.test.ts files on
# disk, and the plugin-bun check globs *.spec.ts and asserts it matched
# something. This script is deliberately dependency-free (no node, no bun, no
# node_modules) so it stays an independent witness: it still fails when the
# deps stage or a runner is itself broken, which is exactly when the other two
# checks go dark.
#
# Run: bash assets/opencode/plugins/test-runner-coverage.sh
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TEST_DIR="test"
VITEST_CONFIG="vitest.config.ts"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -d "$TEST_DIR" ] || fail "$TEST_DIR/ not found (run from a checkout)"

# ---------------------------------------------------------------------------
# 1. Every file under test/ is claimed by exactly one runner.
#
# fixtures/ is excluded: it holds vendored copies of opencode's loader sources
# (see test/fixtures/README.md), which are data for the loader-contract test,
# not tests. Everything else must be claimed.
# ---------------------------------------------------------------------------
unowned=()
while IFS= read -r f; do
  case "$f" in
    *.test.ts|*.spec.ts) ;;
    *) unowned+=("$f") ;;
  esac
done < <(find "$TEST_DIR" -type f -not -path "$TEST_DIR/fixtures/*" | sort)

if [ ${#unowned[@]} -gt 0 ]; then
  echo "FAIL: file(s) under $TEST_DIR/ that NO test runner will ever execute:" >&2
  printf '  %s\n' "${unowned[@]}" >&2
  echo "" >&2
  echo "Name it *.test.ts (vitest) or *.spec.ts (bun test), or move it into" >&2
  echo "$TEST_DIR/fixtures/ if it is data rather than a test. An unclaimed file" >&2
  echo "is silently never run -- the exact defect this guard exists to prevent." >&2
  exit 1
fi
pass "every file under $TEST_DIR/ is claimed by a runner (*.test.ts or *.spec.ts)"

# ---------------------------------------------------------------------------
# 2. Both runners actually have something to claim.
#
# Without this, deleting the last *.spec.ts silently retires the bun check
# (its glob matches nothing) while every check stays green.
# ---------------------------------------------------------------------------
shopt -s nullglob
vitest_files=("$TEST_DIR"/*.test.ts)
bun_files=("$TEST_DIR"/*.spec.ts)
shopt -u nullglob

[ ${#vitest_files[@]} -gt 0 ] || fail "no *.test.ts files -- the plugin-vitest check would cover nothing"
[ ${#bun_files[@]} -gt 0 ] || fail "no *.spec.ts files -- the plugin-bun check would cover nothing"
pass "both runners have files to claim (${#vitest_files[@]} vitest, ${#bun_files[@]} bun)"

# ---------------------------------------------------------------------------
# 3. The vitest include pattern still matches the taxonomy asserted above.
#
# Step 1 assumes *.test.ts means "vitest runs it". That is only true while the
# config says so. If someone narrows `include` (say to test/unit/**), step 1
# keeps passing while the files it vouched for stop being run -- the original
# bug, wearing a different hat.
# ---------------------------------------------------------------------------
grep -qF 'include: ["test/**/*.test.ts"]' "$VITEST_CONFIG" || {
  echo "FAIL: $VITEST_CONFIG no longer contains the expected include pattern:" >&2
  echo '  include: ["test/**/*.test.ts"]' >&2
  echo "" >&2
  echo "This guard maps *.test.ts -> vitest on the strength of that literal." >&2
  echo "If the pattern legitimately changed, update this guard and the" >&2
  echo "plugin-vitest check's file-set assertion in flake.nix together." >&2
  exit 1
}
pass "$VITEST_CONFIG still includes test/**/*.test.ts"

echo "ALL PASS (plugin test runner coverage)"
