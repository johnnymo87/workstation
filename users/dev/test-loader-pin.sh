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
#   4. LOADER_SEMANTICS_PIN pkgs/opencode-plugin-bundle/     (what the bundle
#                                                            checkPhase asserts)
#
# (3) exists because the lazy path out of a red (1)!=(2) is to bump
# LOADER_VERSION and skip refreshing the fixtures, leaving the "mechanical diff"
# recipe pointing at sources that describe a different version.
#
# (4) is the THIRD in-repo copy of loader semantics: the bundle checkPhase
# asserts the v1 plugin shape against the built artifact, mirroring
# readV1Plugin/readPluginId. It was added uncoupled, with only a comment saying
# "when the pin moves, update this too; nothing will tell you" -- which is the
# same rot (2) and (3) are here to prevent, restated as a hope. Step 3 of
# docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md WILL move the pin, so
# it is coupled now rather than after it silently drifts.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

nix_file="$repo_root/users/dev/home.base.nix"
test_file="$repo_root/assets/opencode/plugins/test/plugin-loader-contract.test.ts"
fixture_version_file="$repo_root/assets/opencode/plugins/test/fixtures/VERSION"
bundle_file="$repo_root/pkgs/opencode-plugin-bundle/default.nix"

fail() {
  echo "FAIL: loader-replica pin guard" >&2
  echo >&2
  printf '%s\n' "$@" >&2
  exit 1
}

for f in "$nix_file" "$test_file" "$fixture_version_file" "$bundle_file"; do
  [ -f "$f" ] || fail "missing required file: $f" \
    "" \
    "If this file was moved or renamed, this guard is silently dead." \
    "Repoint it -- do not delete it."
done

deployed="$(sed -nE 's/^[[:space:]]*upstreamVersion[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$nix_file" | head -1)"
replica="$(sed -nE 's/^const LOADER_VERSION = "([^"]+)".*/\1/p' "$test_file" | head -1)"
fixtures="$(tr -d '[:space:]' < "$fixture_version_file")"
bundle="$(sed -nE 's/^[[:space:]]*#[[:space:]]*LOADER_SEMANTICS_PIN:[[:space:]]*([0-9][^[:space:]]*).*/\1/p' "$bundle_file" | head -1)"

[ -n "$deployed" ] || fail "could not parse \`upstreamVersion\` from $nix_file"
[ -n "$replica" ] || fail "could not parse \`LOADER_VERSION\` from $test_file"
[ -n "$fixtures" ] || fail "$fixture_version_file is empty"
[ -n "$bundle" ] || fail "could not find a \`# LOADER_SEMANTICS_PIN: <version>\` marker in $bundle_file" \
  "" \
  "That marker couples the bundle checkPhase's v1-shape assertions to the loader" \
  "version they mirror. If the marker was deleted or reworded, this arm of the" \
  "guard is silently dead -- restore it rather than dropping the check."

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

if [ "$bundle" != "$replica" ]; then
  fail \
    "  loader replica pin (LOADER_VERSION):            $replica" \
    "  bundle checkPhase (LOADER_SEMANTICS_PIN):       $bundle" \
    "" \
    "pkgs/opencode-plugin-bundle/default.nix asserts the v1 plugin shape against" \
    "the BUILT artifact -- a third copy of loader semantics, and the only cover" \
    "the bundled plugins have until step 4 of the plugin-loader hardening" \
    "roadmap runs CI against deployed artifacts." \
    "" \
    "Re-read readV1Plugin and readPluginId in the refreshed fixtures and confirm" \
    "the checkPhase still mirrors them (id trimming, the server/tui rules), then" \
    "move its LOADER_SEMANTICS_PIN marker to $replica." \
    "" \
    "Note the checkPhase is deliberately STRICTER than the loader in one place:" \
    "it rejects a bare-function default, which the loader still accepts. That is" \
    "a policy ratchet against reverting to the legacy shape, not a mirror, and" \
    "it should survive a pin bump untouched."
fi

echo "OK: loader pin consistent (deployed=$deployed replica=$replica fixtures=$fixtures bundle=$bundle)"
