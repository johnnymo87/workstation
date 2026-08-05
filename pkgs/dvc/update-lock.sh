#!/usr/bin/env bash
# Regenerate pkgs/dvc/{package.json,package-lock.json} for a given @devcycle/cli
# version, and print the two hashes ./default.nix needs.
#
#   Usage:  pkgs/dvc/update-lock.sh 6.3.2
#
# Why package.json lists the CLI's dependencies instead of the CLI itself:
#
#   @devcycle/cli publishes an npm-shrinkwrap.json (`"hasShrinkwrap": true`).
#   The obvious wrapper package — `{"dependencies": {"@devcycle/cli": "6.3.2"}}`
#   — cannot be built in the Nix sandbox because of it:
#
#     * npm splices that ~1100-package tree into our lock WITHOUT
#       `resolved`/`integrity` (upstream published it that way), so
#       prefetch-npm-deps has nothing to fetch and `npm ci` dies with
#         ENOTCACHED ... registry.npmjs.org/zod-to-json-schema ... only-if-cached
#     * backfilling `resolved`/`integrity` into OUR lock does not help: at
#       install time arborist reifies the dependency's own shrinkwrap, not our
#       lock's copy of it, so it goes back to the registry for a packument.
#     * the shrinkwrap also pins x64-only esbuild/workerd binaries with no
#       `optional` flag, which is a hard EBADPLATFORM on aarch64.
#
#   So we sidestep the shrinkwrap entirely: our package.json declares the CLI's
#   own `dependencies` (all exact-pinned upstream), npm resolves them normally
#   into a complete, fully-`resolved` 297-package lock, and default.nix drops
#   the CLI's published tarball into node_modules/@devcycle/cli itself (via
#   fetchurl, hash-pinned) with the shrinkwrap deleted. Node's resolution then
#   finds the deps by walking up to the sibling node_modules.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${1:?usage: update-lock.sh <@devcycle/cli version, e.g. 6.3.2>}"

VERSION="$VERSION" python3 - <<'PY'
import json
import os
import urllib.request

version = os.environ["VERSION"]
url = "https://registry.npmjs.org/@devcycle%2fcli"
with urllib.request.urlopen(url) as r:
    meta = json.load(r)["versions"][version]

with open("package.json", "w") as f:
    json.dump(
        {
            # Not the CLI itself — see the header comment.
            "name": "dvc-pin",
            "version": "1.0.0",
            "dependencies": meta["dependencies"],
        },
        f,
        indent=2,
    )
    f.write("\n")

print(f"cliHash for pkgs/dvc/default.nix: {meta['dist']['integrity']}")
PY

rm -f package-lock.json
npm install --package-lock-only

python3 - <<'PY'
import json

with open("package-lock.json") as f:
    pkgs = json.load(f)["packages"]

missing = [k for k, v in pkgs.items() if k and "resolved" not in v and not v.get("link")]
if missing:
    raise SystemExit(
        f"lock has {len(missing)} entries without `resolved` (e.g. {missing[0]}); "
        "the Nix build will fail with ENOTCACHED"
    )
print(f"lock OK: {len(pkgs)} entries, all resolved")
PY

echo "npmDepsHash for pkgs/dvc/default.nix:"
nix run nixpkgs#prefetch-npm-deps -- package-lock.json
