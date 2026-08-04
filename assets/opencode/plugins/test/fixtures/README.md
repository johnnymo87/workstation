# Vendored loader sources

Reference material for `plugin-loader-contract.test.ts` and, more importantly,
for the guard `users/dev/test-loader-pin.sh`. They exist so that re-verifying
after an opencode bump is a mechanical diff rather than a re-reading exercise.

## Upstream, verbatim (at the version in `VERSION`)

| File | Upstream path | Why it is pinned |
|---|---|---|
| `plugin-index.ts` | `packages/opencode/src/plugin/index.ts` | The loader. `getLegacyPlugins` throw at :103, `applyPlugin` v1 early-return at :115. |
| `plugin-shared.ts` | `packages/opencode/src/plugin/shared.ts` | `readV1Plugin`, `readPluginId`, `resolvePluginId` file-source `id` throw at :315. |
| `loader.ts` | `packages/opencode/src/plugin/loader.ts` | Defines the retry/filter behaviour and is what triggers `report.missing` — the fifth, quietest failure stage. Invisible from `index.ts` alone. |
| `config-plugin.ts` | `packages/opencode/src/config/plugin.ts` | `Glob.scan` → `pathToFileURL(item).href` (:21-27) is where every deployed plugin's `file://` spec is **born**. The canary's per-file key needs that `file://`; without it all failures collapse to one `unknown` latch. |
| `logging.ts` | `packages/core/src/observability/logging.ts` | The **renderer**. Field order (`timestamp` first, `level` second), the quoting rule at :46 that leaves `path=file://...` *unquoted*, flat annotations, and the `opencode.log` filename — the canary parses all four, and none of them are visible at the `logError` call site. |

## Ours

| File | What it is |
|---|---|
| `plugin-loader-observability.patch` | Our fork patch (`johnnymo87/opencode-patched`). Upstream logs **nothing** at the four `report.error` stages or at `report.missing`; this patch is the only reason those failures are visible. Its `sha256` is recorded in the canary's `LOADER_PATCH_SHA256` marker. |
| `plugin-index.patched.ts` | **Generated**: `plugin-index.ts` + the patch above. This is the loader that actually runs in production, and the file the guard greps the canary's patterns against. |

`plugin-index.ts` stays **pristine upstream** so the `curl | diff` re-verification
recipe still comes back empty on a clean bump. The patched copy sits beside it
rather than replacing it, and the guard proves the relationship holds
(`composed == vendored`) rather than trusting it.

## Do not edit by hand

`plugin-index.patched.ts` especially — a hand-edited "patched" fixture is worse
than none, because the guard and the canary re-verification ritual both read it
as ground truth. The guard recomposes it from pristine + patch and byte-compares,
so hand edits fail; regenerate instead.

Refresh with the recipe printed by `users/dev/test-loader-pin.sh` on failure
(`refresh_recipe`), which stays in sync with this list. It fetches all five
upstream files, fetches our patch at the deployed fork tag, recomposes the
patched loader, and prints the `sha256` to paste into the canary marker.

*(The guard's recipe curls `sst/opencode`; `build-release.yml` uses
`anomalyco/opencode`. Both serve byte-identical content for `v1.17.13` — the
difference is cosmetic.)*

These are reference material: not compiled, not imported by the test suite.

**What the guard actually enforces**, as opposed to what vendoring merely makes
available to read: the patch's `sha256`; that `plugin-index.patched.ts` really is
`plugin-index.ts` + the patch; that the canary's message literal appears in the
helper emitting it; that every load-failure site carries `path`; and that the
call sites for all five stages plus the success line still exist. `logging.ts`
and `config-plugin.ts` are **not** content-checked — proving anything about them
offline would mean replicating the renderer. They are here so that the refresh
ritual puts them in front of you.
