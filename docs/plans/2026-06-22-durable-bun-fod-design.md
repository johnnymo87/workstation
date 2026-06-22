# Durable content-addressed node_modules for bun-based packages

> Design doc for workstation-g9fe (mn9r maintenance-hardening track).
> Supersedes the FOD mechanism of workstation-l0f6 for `self-compact-plugin`.

## Problem

`pkgs/self-compact-plugin` and `pkgs/ask-question` fetched their JS
dependencies through a **fixed-output derivation** that ran `bun install` and
hashed the **entire on-disk `node_modules` tree** with
`outputHashMode = "recursive"`. The recursive hash is taken over bun's on-disk
*layout/metadata*, not over package *content*. So a nixpkgs `bun` version bump
re-lays-out `node_modules` and the FOD hash drifts even though `bun.lock` pins
byte-identical package content. Every bun bump then breaks `home-manager switch`
AND the 4-hourly `pull-workstation.service` with a hash mismatch until a human
hand-refreshes the pin. This happened twice (commits 5ed4b36, 4ad02a0).

`l0f6` (commit 796da73) fixed a *different* axis for self-compact only — the
cross-architecture drift — by forcing all optional platform variants
(`bun install --cpu='*' --os='*'`) and keying `outputHash` per system. That did
NOT address the bun-version axis, which still needed a manual refresh.

## Decision

Replace the recursive-FOD `bun install` deps stage with
**`importNpmLock.buildNodeModules`** reading a **committed `package-lock.json`**,
in BOTH packages. Keep `bun` only for self-compact's stage-2 `bun build` bundle
and its `bun --no-install` smoke test.

### Why this is durable

`importNpmLock` parses the committed `package-lock.json` at eval time (pure
eval over a source file — **not** IFD) and fetches **each dependency via
`fetchurl` keyed by the lockfile's own SRI `integrity`** field. `buildNodeModules`
then runs `npm install` (via `npmConfigHook`) to assemble `node_modules` as a
**normal derivation** — there is **no `outputHash` at all**, and **no `bun`** in
the deps stage's build closure.

Consequences:

- A `bun` OR `node`/`npm` version bump can at most trigger a *normal rebuild* of
  the deps derivation; it can NEVER produce a fixed-output hash mismatch,
  because there is no fixed-output hash to mismatch.
- The only thing that legitimately moves a per-package fetch is a real
  dependency change (new version → new integrity in the lockfile).
- The l0f6 cross-architecture mechanism becomes unnecessary and is removed:
  there is no recursive-tree hash to keep byte-identical across arches, so the
  `--cpu='*' --os='*'` flags and the per-system `outputHash` map are deleted.
  (npm records every optional platform variant in the lockfile anyway, so the
  fetch set is already cross-platform-complete.)

### Alternatives considered

- **`fetchNpmDeps` + `npmConfigHook` (single `npmDepsHash`):** also kills the
  bun-layout drift (hash is over `prefetch-npm-deps`' tarball cache, stable
  across node/npm bumps). Rejected because it still has ONE FOD hash; a
  `package-lock.json` change that forgets to refresh `npmDepsHash` re-breaks the
  unattended service. `importNpmLock` removes that whole class (no hash).
- **Pin bun for the FOD:** stopgap only. Still hashes bun's on-disk layout, so
  the next deliberate bun bump still needs a manual refresh. Rejected.

(ChatGPT deep-research consultation agreed with this ranking; see
`ask-question` session 2026-06-22.)

### Lockfile source of truth

`package-lock.json` becomes the single committed lockfile; `bun.lock` is
gitignored. This avoids dual-lock drift (a new footgun this hardening track is
trying to eliminate). Developers can still use bun — `bun install` migrates from
`package-lock.json` — or `npm ci`; `bun build`/vitest are unaffected because
they resolve from a standard hoisted `node_modules` regardless of who created
it. `bunfig.toml` keeps `linker = "hoisted"` so any local bun install matches
npm's layout.

### Package specifics

- **self-compact-plugin:** stage 1 → `importNpmLock.buildNodeModules` with
  `npmInstallFlags = [ "--omit=dev" ]` (matches the old `--production`). Stage 2
  unchanged (`bun build` + `bun --no-install` checkPhase). `package-lock.json`
  committed in `assets/opencode/plugins/`.
- **ask-question:** the single `undici` dep gets a tiny committed deps manifest
  at `pkgs/ask-question/deps/{package.json,package-lock.json}` consumed by
  `importNpmLock.buildNodeModules`; the inline synthesized `package.json` + bun
  install are removed. Same pattern as self-compact for consistency and to stay
  correct if undici ever gains a transitive dependency.

## Tests (TDD)

A `test.sh` per package asserts the durability invariant directly:

1. The deps derivation has **no `bun`** in its direct build inputs (so a bun
   bump cannot move it).
2. The deps derivation has **no `outputHash`** (content-addressing is by the
   lockfile's per-package integrity, not a recursive tree hash).
3. The package builds reproducibly (instantiating twice yields the same
   derivation/output path).
4. (self-compact) the built bundle loads under `bun --no-install` with a
   function default export.

## Verification

- macOS (darwin): `nix build .#self-compact-plugin` builds + reproduces;
  `darwin-rebuild switch` deploys `self-compact.js`; deployed bundle loads under
  `bun --no-install`. ask-question is `meta.platforms = linux` (deploys only on
  devbox/cloudbox), so it is build-verified on darwin via direct callPackage and
  eval-verified for the linux target; its real linux build/deploy is identical
  by construction (content-addressed, platform-independent fetches).
