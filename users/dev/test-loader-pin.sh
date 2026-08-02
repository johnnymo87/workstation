#!/usr/bin/env bash
# Loader-replica pin guard.
#
# assets/opencode/plugins/test/plugin-loader-contract.test.ts replicates
# opencode's plugin loader. A replica is only as good as its pin: if the
# deployed opencode moves and the replica does not, the test keeps passing while
# asserting a contract that no longer exists. That is exactly how the guard it
# replaced (no-function-exports.test.ts) failed -- confidently green about a
# loader it no longer matched, on a file opencode was rejecting in production.
#
# WHY BASH AND NOT JUST THE VITEST CASE: CI runs `nix flake check` only. It does
# not run vitest -- there is no plugin-test derivation. The equivalent assertion
# living solely in the test suite would fire only when a human happened to run
# `npx vitest` locally, which is after the bump has already deployed. Same
# failure the frontdoor-opacity guard hit: "a guard nothing runs is
# documentation with a shebang." So the pin is enforced here, in the checked
# path, and duplicated in the test suite for fast local feedback.
#
# Three constants must agree:
#   1. upstreamVersion      users/dev/home.base.nix          (what we deploy)
#   2. LOADER_VERSION       plugin-loader-contract.test.ts   (what we replicate)
#   3. fixtures/VERSION     test/fixtures/                   (what we vendored)
#
# (3) exists because the lazy path out of a red (1)!=(2) is to bump
# LOADER_VERSION and skip refreshing the fixtures, leaving the "mechanical diff"
# recipe pointing at sources that describe a different version.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

nix_file="$repo_root/users/dev/home.base.nix"
test_file="$repo_root/assets/opencode/plugins/test/plugin-loader-contract.test.ts"
fixture_version_file="$repo_root/assets/opencode/plugins/test/fixtures/VERSION"

fail() {
  echo "FAIL: loader-replica pin guard" >&2
  echo >&2
  printf '%s\n' "$@" >&2
  exit 1
}

for f in "$nix_file" "$test_file" "$fixture_version_file"; do
  [ -f "$f" ] || fail "missing required file: $f" \
    "" \
    "If this file was moved or renamed, this guard is silently dead." \
    "Repoint it -- do not delete it."
done

deployed="$(sed -nE 's/^[[:space:]]*upstreamVersion[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$nix_file" | head -1)"
replica="$(sed -nE 's/^const LOADER_VERSION = "([^"]+)".*/\1/p' "$test_file" | head -1)"
fixtures="$(tr -d '[:space:]' < "$fixture_version_file")"

[ -n "$deployed" ] || fail "could not parse \`upstreamVersion\` from $nix_file"
[ -n "$replica" ] || fail "could not parse \`LOADER_VERSION\` from $test_file"
[ -n "$fixtures" ] || fail "$fixture_version_file is empty"

refresh_recipe() {
  cat <<EOF
  V=$deployed
  for f in index shared; do
    curl -sL "https://raw.githubusercontent.com/sst/opencode/v\$V/packages/opencode/src/plugin/\$f.ts" \\
      -o "assets/opencode/plugins/test/fixtures/plugin-\$f.ts"
  done
  echo "\$V" > assets/opencode/plugins/test/fixtures/VERSION
EOF
}

if [ "$replica" != "$deployed" ]; then
  fail \
    "  deployed opencode (home.base.nix upstreamVersion): $deployed" \
    "  loader replica pin (LOADER_VERSION):               $replica" \
    "" \
    "plugin-loader-contract.test.ts replicates opencode's plugin loader and is" \
    "pinned to a version we no longer deploy. Until this is resolved that test" \
    "is asserting a contract that may not exist, and will keep passing." \
    "" \
    "Re-verify the loader semantics against the vendored fixtures:" \
    "  curl -sL https://raw.githubusercontent.com/sst/opencode/v$deployed/packages/opencode/src/plugin/index.ts | diff - assets/opencode/plugins/test/fixtures/plugin-index.ts" \
    "  curl -sL https://raw.githubusercontent.com/sst/opencode/v$deployed/packages/opencode/src/plugin/shared.ts | diff - assets/opencode/plugins/test/fixtures/plugin-shared.ts" \
    "" \
    "If the diffs are empty, the semantics are unchanged: refresh the fixtures" \
    "and bump LOADER_VERSION." \
    "If they are NOT empty, update the replica FIRST, then the pin." \
    "" \
    "$(refresh_recipe)"
fi

if [ "$fixtures" != "$replica" ]; then
  fail \
    "  loader replica pin (LOADER_VERSION): $replica" \
    "  vendored fixtures (fixtures/VERSION): $fixtures" \
    "" \
    "The pin was bumped without refreshing the vendored upstream sources, so the" \
    "'mechanical diff' recipe now points at sources describing a different" \
    "version. This is the lazy path out of a red pin, and it makes the next" \
    "person's re-verification actively misleading." \
    "" \
    "$(refresh_recipe)"
fi

echo "OK: loader pin consistent (deployed=$deployed replica=$replica fixtures=$fixtures)"
