# Self-Compact Plugin Deployment v3: Nix-Built Bundle Design

> **Status:** Design complete, awaiting plan + implementation. Successor to the
> deployment scheme described in v1 (`2026-04-20-self-compact-plugin-design.md`)
> and v2 (`2026-04-21-self-compact-idle-trigger-plan.md`).
>
> The v2 work fixed the runtime architecture (idle-triggered summarize, no
> deadlock). This v3 work fixes the *deployment* architecture so the plugin
> works on a fresh machine with zero manual steps.

## Problem

The self-compact opencode plugin lives at
`assets/opencode/plugins/self-compact.ts` and imports
`@opencode-ai/plugin` as a runtime value (`import { tool } from
"@opencode-ai/plugin"`). The plugin is currently deployed via
`mkOutOfStoreSymlink` (in `users/dev/opencode-config.nix`) so that the
deployed file `~/.config/opencode/plugins/self-compact.ts` resolves to the
working tree. That works because Bun's module resolution walks upward from
the plugin file looking for `node_modules/@opencode-ai/plugin/`, and the
working tree co-locates a `node_modules/` populated by `bun install`.

**The catch:** `node_modules/` is gitignored. On a fresh checkout (as
happened on devbox today), `home-manager switch` deploys the symlink
correctly but no `bun install` was ever run, so the plugin silently fails
to load. The opencode log shows:

```
ERROR ... service=plugin path=file:///home/dev/.config/opencode/plugins/self-compact.ts
  error=Cannot find module '@opencode-ai/plugin' from
  '/home/dev/projects/workstation/assets/opencode/plugins/self-compact.ts'
  failed to load plugin
```

…and the agent reports "the `self_compact_and_resume` tool isn't available."

We confirmed empirically that `bun --no-install` (which is how opencode
runs Bun internally) reproduces the failure exactly, while bare `bun`
succeeds because Bun's auto-install fetches the package on-demand. opencode
does not auto-install; it relies on whatever `node_modules` is reachable
from the realpath of the plugin file.

The current per-machine workaround is to manually run `bun install` in
`assets/opencode/plugins/`. That works but it's a footgun: nothing tells
the operator they need to do it, and a fresh provision silently lacks the
plugin.

## Goal

Eliminate the per-machine manual step. After this change, any fresh
machine that runs `home-manager switch` against this flake will have a
fully working `self_compact_and_resume` tool, with no `bun install`
required, no network access during activation, and no mutable state in
the working tree.

## Approach

Build the plugin as a self-contained JavaScript bundle in a Nix derivation
using `Bun.build`. Deploy the bundled `.js` from the nix store via a
regular `xdg.configFile.<...>.source = "${derivation}/self-compact.js"`
registration. The bundle inlines `@opencode-ai/plugin` (and zod), so the
deployed file has no external imports and Bun has nothing to resolve at
runtime.

The build is two-stage:

1. **`nodeModules`** — a fixed-output derivation (FOD) that runs
   `bun install --frozen-lockfile` and outputs the resulting
   `node_modules/` directory. FOD-only because Nix sandboxes deny network
   access to non-FOD derivations and `bun install` needs network. The
   `outputHash` only changes when `package.json` or `bun.lock` changes —
   the bundle source can churn freely without re-fetching deps.
2. **`bundle`** — a regular derivation that copies sources +
   `${nodeModules}/node_modules/`, runs `bun build self-compact.ts` with
   `--target=bun --format=esm`, runs a `checkPhase` that loads the built
   artifact under `bun --no-install`, and outputs `$out/self-compact.js`.

The two stages mirror the canonical pattern in `nixpkgs/pkgs/by-name/op/opencode`
and several other Bun-based packages.

This approach was selected after consulting ChatGPT (research file:
`/tmp/research-opencode-plugin-deps-question.md`,
`/tmp/research-opencode-plugin-deps-answer.md`). ChatGPT considered four
options (activation-time `bun install`; pre-built node_modules derivation;
bundled artifact; npm-published package) and recommended the bundle as
the best long-term answer because it eliminates the runtime-resolution
class of problems entirely: "You no longer care where Bun starts its
upward node_modules walk, whether the plugin path is a realpath in
/nix/store, whether someone remembered to run bun install, or whether
Bun's auto-install is disabled. The deployment artifact becomes one file
plus optional sourcemap, which is exactly what Nix is good at shipping."

## Architecture

```
                                    ┌──────────────────────────────────┐
                                    │ assets/opencode/plugins/         │
                                    │   self-compact.ts        (src)   │
                                    │   self-compact-impl.ts   (src)   │
                                    │   package.json           (input) │
                                    │   bun.lock               (input) │
                                    └─────────────┬────────────────────┘
                                                  │
                  ┌───────────────────────────────▼────────────────────────┐
                  │ pkgs/self-compact-plugin/default.nix                   │
                  │                                                        │
                  │  ┌────────────────────────────────────────────────┐    │
                  │  │ Stage 1: nodeModules (FOD)                     │    │
                  │  │   src = filter to {package.json, bun.lock}     │    │
                  │  │   build: bun install --frozen-lockfile         │    │
                  │  │          --production --linker hoisted         │    │
                  │  │          --ignore-scripts                      │    │
                  │  │   output: $out/node_modules/                   │    │
                  │  │   outputHash = "sha256-..." (network step)     │    │
                  │  └────────────────┬───────────────────────────────┘    │
                  │                   │                                    │
                  │  ┌────────────────▼───────────────────────────────┐    │
                  │  │ Stage 2: bundle (regular derivation)           │    │
                  │  │   src = full plugins dir                       │    │
                  │  │   inputs: nodeModules                          │    │
                  │  │   build: cp -r ${nodeModules}/node_modules .   │    │
                  │  │          bun build self-compact.ts             │    │
                  │  │            --target=bun --format=esm           │    │
                  │  │            --outfile=$out/self-compact.js      │    │
                  │  │   check:  bun --no-install -e                  │    │
                  │  │            "import('$out/self-compact.js')..." │    │
                  │  │   output: $out/self-compact.js                 │    │
                  │  └────────────────┬───────────────────────────────┘    │
                  └───────────────────┼────────────────────────────────────┘
                                      │
                  ┌───────────────────▼────────────────────────────────────┐
                  │ users/dev/opencode-config.nix                          │
                  │                                                        │
                  │   xdg.configFile."opencode/plugins/self-compact.js"    │
                  │     .source = "${localPkgs.self-compact-plugin}/       │
                  │                  self-compact.js"                      │
                  │                                                        │
                  │  (Old `.ts` mkOutOfStoreSymlink registration removed)  │
                  └───────────────────┬────────────────────────────────────┘
                                      │
                  ┌───────────────────▼────────────────────────────────────┐
                  │ ~/.config/opencode/plugins/self-compact.js             │
                  │   → /nix/store/<hash>-self-compact-plugin/             │
                  │      self-compact.js                                   │
                  │                                                        │
                  │ opencode loads via `await import(file:// ... .js)`     │
                  │ Bundle is fully self-contained; no node_modules needed │
                  └────────────────────────────────────────────────────────┘
```

### Key properties

- **Hermetic.** No network during `home-manager switch`. Network only
  happens when the FOD's hash changes, i.e., when `bun.lock` is updated.
- **Reproducible.** Same `bun.lock` + same source = same bundle on every
  machine.
- **Cross-platform.** Same derivation builds on aarch64-linux
  (devbox/cloudbox/Crostini) and aarch64-darwin (macOS). The bundle
  output is platform-agnostic JavaScript. The `nodeModules` FOD's
  `outputHash` *should* be identical across platforms for our pure-JS
  deps; we'll verify and document.
- **No runtime deps.** The deployed `.js` has zero external imports.
  `@opencode-ai/plugin` and `zod` are inlined.
- **Smoke-test gated.** Build fails if the bundle can't be loaded under
  `bun --no-install`. A broken deployment cannot reach a user.
- **Source-first iteration unchanged.** Developers still
  `cd assets/opencode/plugins && vitest` to run unit tests, no
  `bun build` required for normal development. The Nix build is a
  deployment concern only.

## File changes

| File | Change |
|------|--------|
| `assets/opencode/plugins/package.json` | Move `@opencode-ai/plugin` from `devDependencies` to `dependencies`, exact-pin (no `^`). Keep `@opencode-ai/sdk` in devDeps (type-only). Keep `vitest`, `typescript`, `@types/node` in devDeps. |
| `assets/opencode/plugins/bun.lock` | New file. Generated by `bun install` once, committed to git. Bun 1.2+ default text lockfile (NOT the binary `bun.lockb`). |
| `assets/opencode/plugins/.gitignore` | Remove `package-lock.json` (no longer relevant — we use Bun). Keep `node_modules/`. Add `dist/` if developers locally run `bun build`. |
| `assets/opencode/plugins/bunfig.toml` | New file. Sets `[install] linker = "hoisted"` to force the resolution mode our deployment relies on. |
| `pkgs/self-compact-plugin/default.nix` | **New file.** Contains both stages of the derivation. |
| `flake.nix` | Add `self-compact-plugin = p.callPackage ./pkgs/self-compact-plugin { };` to `localPkgsFor`. |
| `users/dev/opencode-config.nix` | Replace the existing `xdg.configFile."opencode/plugins/self-compact.ts"` block (currently `mkOutOfStoreSymlink`) with `xdg.configFile."opencode/plugins/self-compact.js".source = "${localPkgs.self-compact-plugin}/self-compact.js";`. Update the surrounding comment. |
| `assets/opencode/skills/preparing-for-compaction/SKILL.md` | No changes — skill doesn't reference deployment internals. |
| `docs/plans/2026-04-20-self-compact-plugin-design.md` | Append a brief addendum noting v3 supersedes the v1 deferred-refactor note. |

## Trade-offs accepted

- **Bundle is unreadable on disk.** Stack traces from runtime errors will
  point at minified-ish bundled JS instead of the original TS. Mitigated
  by emitting an external sourcemap (`--sourcemap=external`) alongside
  `self-compact.js`. Bun honors sourcemaps.
- **Adds a Nix build step.** First-time `nix build` of the plugin takes a
  few seconds. Subsequent builds are cached in the Nix store.
- **Lockfile maintenance.** `bun.lock` must be regenerated whenever
  `package.json` deps change, AND the `nodeModules` FOD's `outputHash`
  must be updated to match. Documented in the plan + new repo doc.
- **One-time hash bootstrap.** First time we build, we'll set
  `outputHash` to `lib.fakeHash` and let Nix fail with the expected hash,
  then paste it in. Standard FOD workflow but worth flagging.

## Trade-offs rejected

- **Activation hook running `bun install`** (Option 1): Imperative,
  network-required at activation, mutable working tree state. Chosen
  against per ChatGPT recommendation.
- **Single-stage FOD doing install + build**: outputHash becomes fragile
  to source changes. Chosen against — two-stage isolates the
  network-required hash to deps only.
- **`bun2nix` third-party tool**: Adds a dep on a less-mature tool, more
  moving parts, no clear win for one plugin.
- **Publishing self-compact as a private npm package**: Maintaining a
  publish/release loop for one private plugin is more ceremony than value.
- **Restructuring all plugins under `pkgs/opencode-plugins/`**: YAGNI.
  Only self-compact needs runtime deps today. Revisit if/when more plugins
  hit this.

## Smoke test details

The Nix derivation's `checkPhase` will run something equivalent to:

```bash
${pkgs.bun}/bin/bun --no-install -e "
  const m = await import('$out/self-compact.js');
  if (typeof m.default !== 'function') {
    console.error('Expected default export to be a function (plugin factory), got:', typeof m.default);
    process.exit(1);
  }
  console.log('Bundle loads cleanly under --no-install. Default export OK.');
"
```

This catches:
- `@opencode-ai/plugin` not bundled (would fail with `Cannot find module`)
- Plugin factory not exported as `default` (would fail the type check)
- Any syntax error or import-time exception in the bundle
- Regression to the old loading mechanism

This is exactly the test that, if it had existed in CI on April 20,
would have caught the regression we hit today before it reached a user.

## Open questions

1. Do we need a sourcemap deployed alongside the bundle? If yes, register
   `.js.map` with a second `xdg.configFile` entry. Decision: **yes**,
   include sourcemap, costs almost nothing and helps debugging.
2. Should we also smoke-test in CI (GitHub Actions) on top of the Nix
   `checkPhase`? The `checkPhase` runs at every `home-manager switch` and
   on any local `nix build`, so it's already very hard to merge a broken
   bundle without noticing. Decision: **no**, Nix `checkPhase` is
   sufficient for now. Add CI later if PRs start landing without local
   builds.
3. Does the `nodeModules` FOD hash differ between aarch64-linux and
   aarch64-darwin? Decision: **verify during implementation**, document
   either way. If different, use `system`-conditional `outputHash`.

## Related work

- v1 design: `docs/plans/2026-04-20-self-compact-plugin-design.md`
- v1 plan: `docs/plans/2026-04-20-self-compact-plugin-plan.md` (SUPERSEDED)
- v2 plan: `docs/plans/2026-04-21-self-compact-idle-trigger-plan.md`
  (COMPLETED 2026-04-21)
- ChatGPT research:
  `/tmp/research-opencode-plugin-deps-question.md`,
  `/tmp/research-opencode-plugin-deps-answer.md`
- Reference: `nixpkgs/pkgs/by-name/op/opencode` for the canonical
  two-stage Bun build pattern.
