#!/usr/bin/env bash
# Durability + reproducibility tests for the ask-question deps stage.
#
# workstation-g9fe: the node_modules deps stage must be content-addressed by the
# committed deps/package-lock.json (per-package fetchurl integrity), NOT a
# recursive fixed-output hash over a bun-produced on-disk tree (whose hash
# drifts on every nixpkgs bun bump and forces a manual refresh).
#
# ask-question is meta.platforms = linux (it deploys only on devbox/cloudbox),
# so it is filtered out of `packages.aarch64-darwin`. We therefore exercise the
# real default.nix via callPackage against the current system's nixpkgs, which
# works uniformly on darwin and linux and reads the working tree directly (so
# newly-added deps/ files are visible before they are committed).
#
# Run: bash pkgs/ask-question/test.sh
set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ask-question is meta.platforms = linux. On darwin (where the relay server, not
# the client, lives) evaluating the top-level package trips the platform
# assertion; allow it so we can cross-verify the (platform-independent) build
# here. No-op on the real linux targets where it is natively supported.
export NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Evaluate an attribute path on (callPackage ./pkgs/ask-question {}).
pkg_eval() { # <attr-suffix>
  nix eval --impure --raw --expr "
    let flake = builtins.getFlake (toString ${REPO_ROOT});
        pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
        pkg = pkgs.callPackage ${REPO_ROOT}/pkgs/ask-question { };
    in $1"
}

echo "== resolving deps derivation (passthru.nodeModules) =="
NMDRV="$(pkg_eval 'pkg.nodeModules.drvPath')" \
  || fail "could not eval ask-question.nodeModules.drvPath (deps stage not exposed via passthru)"
echo "  nodeModules drv: $NMDRV"
DRVJSON="$(nix derivation show "$NMDRV")"

echo "== invariant 1: no bun in the deps stage build inputs =="
if printf '%s' "$DRVJSON" | nix run nixpkgs#jq -- -e \
     '[.[].inputDrvs | keys[]] | map(select(test("-bun-[0-9]"))) | length > 0' >/dev/null; then
  fail "bun is a build input of the deps derivation (FOD-over-bun-tree regression)"
fi
pass "no bun in deps stage"

echo "== invariant 2: deps derivation is NOT a fixed-output (no outputHash) =="
if printf '%s' "$DRVJSON" | nix run nixpkgs#jq -- -e \
     '[.[].outputs.out | (has("hash") or has("hashAlgo"))] | any' >/dev/null; then
  fail "deps derivation has a fixed-output hash (recursive-FOD regression)"
fi
pass "deps derivation has no outputHash"

echo "== invariant 3: reproducible (two instantiations -> identical drv) =="
D1="$(pkg_eval 'pkg.drvPath')"
D2="$(pkg_eval 'pkg.drvPath')"
[ "$D1" = "$D2" ] || fail "drvPath not stable across evals: $D1 != $D2"
pass "ask-question drvPath stable: $D1"

echo "== invariant 4: built CLI vendors undici and is wrapped =="
OUT="$(nix build --no-link --print-out-paths --impure --expr "
  let flake = builtins.getFlake (toString ${REPO_ROOT});
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
  in pkgs.callPackage ${REPO_ROOT}/pkgs/ask-question { }")"
[ -x "$OUT/bin/ask-question" ] || fail "no executable bin/ask-question in $OUT"
[ -f "$OUT/libexec/ask-question/node_modules/undici/package.json" ] \
  || fail "undici not vendored next to cli in $OUT"
pass "CLI wrapped and undici vendored"

echo "ALL TESTS PASSED"
