#!/usr/bin/env bash
# Durability + reproducibility tests for a bundled opencode plugin, shared by
# every caller of pkgs/opencode-plugin-bundle.
#
# workstation-g9fe: the node_modules deps stage must be content-addressed by the
# committed package-lock.json (per-package fetchurl integrity), NOT a recursive
# fixed-output hash over a bun-produced on-disk tree. The invariants below fail
# loudly if anyone reintroduces the bun-install FOD (whose hash drifts on every
# nixpkgs bun bump and forced manual refreshes — see commits 5ed4b36, 4ad02a0,
# 796da73).
#
# Usage: bash pkgs/opencode-plugin-bundle/test.sh <flake-attr> <bundle-basename>
#   e.g. bash pkgs/opencode-plugin-bundle/test.sh session-state-plugin session-state
# Prefer the per-plugin wrappers: bash pkgs/<name>/test.sh
set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ATTR="${1:?usage: test.sh <flake-attr> <bundle-basename>}"
ENTRY="${2:?usage: test.sh <flake-attr> <bundle-basename>}"
PKG=".#${ATTR}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

echo "== testing ${PKG} (bundle: ${ENTRY}.js) =="

echo "== resolving deps derivation (passthru.nodeModules) =="
NMDRV="$(nix eval --raw "${PKG}.nodeModules.drvPath")" \
  || fail "could not eval ${PKG}.nodeModules.drvPath (deps stage not exposed via passthru)"
echo "  nodeModules drv: $NMDRV"
DRVJSON="$(nix derivation show "$NMDRV")"

echo "== invariant 1: no bun in the deps stage build inputs =="
# A bun version bump must be unable to move the deps derivation. If bun is a
# build input, its layout/version can change the result -> the exact fragility
# this bead eliminates.
if printf '%s' "$DRVJSON" | nix run nixpkgs#jq -- -e \
     '[.[].inputDrvs | keys[]] | map(select(test("-bun-[0-9]"))) | length > 0' >/dev/null; then
  fail "bun is a build input of the deps derivation (FOD-over-bun-tree regression)"
fi
pass "no bun in deps stage"

echo "== invariant 2: deps derivation is NOT a fixed-output (no outputHash) =="
# Content-addressing must come from the lockfile's per-package integrity, not a
# recursive output hash over node_modules. A normal derivation has no out.hash.
if printf '%s' "$DRVJSON" | nix run nixpkgs#jq -- -e \
     '[.[].outputs.out | (has("hash") or has("hashAlgo"))] | any' >/dev/null; then
  fail "deps derivation has a fixed-output hash (recursive-FOD regression)"
fi
pass "deps derivation has no outputHash"

echo "== invariant 3: reproducible (two instantiations -> identical drv) =="
D1="$(nix eval --raw "${PKG}.drvPath")"
D2="$(nix eval --raw "${PKG}.drvPath")"
[ "$D1" = "$D2" ] || fail "drvPath not stable across evals: $D1 != $D2"
pass "bundle drvPath stable: $D1"

echo "== invariant 4: built bundle loads under bun --no-install =="
OUT="$(nix build --no-link --print-out-paths "${PKG}")"
[ -f "$OUT/${ENTRY}.js" ] || fail "no ${ENTRY}.js in $OUT"
bun --no-install -e "
  const m = await import('$OUT/${ENTRY}.js');
  if (typeof m.default !== 'function') { console.error('bad default export:', typeof m.default); process.exit(1); }
" || fail "deployed bundle did not load under bun --no-install"
pass "bundle loads; default export is a function"

echo "== invariant 5: bundle is self-contained (no relative specifiers) =="
# The reason this package exists: a relative specifier surviving into the
# artifact would be resolved against the /nix/store path at runtime and throw,
# and opencode swallows that error entirely (empty log, plugin still listed).
# Anchored pattern = externalised static imports (how bun emits them);
# unanchored pattern = the dynamic import()/require() forms, which would
# otherwise fail only once that code path ran.
if grep -nE "^[[:space:]]*(import|export)[^\"']*[\"']\.\.?/" "$OUT/${ENTRY}.js" \
   || grep -nE "(import|require)\([[:space:]]*[\"']\.\.?/" "$OUT/${ENTRY}.js"; then
  fail "bundle contains a relative specifier; sibling would not resolve in the store"
fi
pass "no relative specifiers in bundle"

echo "== invariant 6: sourcemap is present (it is deployed unconditionally) =="
# opencode-config.nix references ${ENTRY}.js.map with no existence check, so a
# missing map is a dangling symlink at activation time.
[ -f "$OUT/${ENTRY}.js.map" ] || fail "no ${ENTRY}.js.map in $OUT"
pass "sourcemap present"

echo "ALL PASS (${PKG})"
