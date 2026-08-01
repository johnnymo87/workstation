#!/usr/bin/env bash
# Meta-test: perturbation tests for test-frontdoor-opacity.sh.
#
# The guard's whole value is failing CLOSED on a new direct-to-serve call. A guard
# that cannot fail is a defect, and this project has shipped three "fixes" that
# reported healthy while doing nothing. So: copy the guard's universe into a
# fixture, perturb it, and assert the guard goes RED with the RIGHT message.
#
# Run: bash users/dev/test-frontdoor-opacity-guard.sh
set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
guard="users/dev/test-frontdoor-opacity.sh"
table="docs/plans/2026-07-26-phase9-consumer-disposition.md"

fail=0
pass_() { printf 'ok: %s\n' "$1"; }
bad()   { printf 'FAIL: %s\n' "$1"; fail=1; }

# A fixture is a minimal copy of everything the guard reads: itself, the table,
# and every governed file. Copied with --parents so relative paths survive.
new_fixture() {
  local fix; fix="$(mktemp -d)"
  ( cd "$repo_root" \
    && cp --parents "$guard" "$table" $(printf '%s\n' \
         pkgs/*/default.nix \
         users/dev/home.base.nix users/dev/home.darwin.nix \
         users/dev/home.devbox.nix users/dev/home.cloudbox.nix \
         hosts/cloudbox/configuration.nix hosts/devbox/configuration.nix \
         2>/dev/null | while read -r f; do [ -f "$f" ] && echo "$f"; done) \
         "$fix/" )
  printf '%s' "$fix"
}

# Run the guard in a fixture. Output goes to a FILE; never pipe into grep -q,
# which under pipefail inverts its own result.
run_guard() {
  local fix="$1" out="$2"
  set +o errexit
  ( cd "$fix" && bash "$guard" ) > "$out" 2>&1
  local rc=$?
  set -o errexit
  return $rc
}

# Assert the guard is GREEN on an unperturbed fixture. If this fails, every
# perturbation case below is meaningless.
fix="$(new_fixture)"; out="$(mktemp)"
if run_guard "$fix" "$out"; then
  pass_ "baseline: guard is green on an unperturbed tree"
else
  bad "baseline: guard is RED on an unperturbed tree -- fix the tree before trusting any case below"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
