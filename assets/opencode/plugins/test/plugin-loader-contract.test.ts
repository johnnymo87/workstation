import { describe, it, expect } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"

/**
 * Regression guard for the 2026-07-30 devbox outage AND for the broken fix that
 * followed it.
 *
 * This test does NOT encode a hand-written rule about export shapes. The
 * previous version of it did ("no bare function exports"), and that rule was
 * WRONG in a way that mattered: it declared non-function exports safe because
 * "the loader skips them". The loader does not skip them -- it throws. The test
 * passed on a shell-env.ts that opencode was rejecting outright in production.
 *
 * So instead we REPLICATE the loader and run our plugins through it.
 *
 * Replica source (pinned -- see LOADER_VERSION): packages/opencode/src/plugin/
 * index.ts `applyPlugin`/`getLegacyPlugins` and packages/opencode/src/plugin/
 * shared.ts `readV1Plugin`/`readPluginId`/`resolvePluginId`.
 *
 *   applyPlugin(mod):
 *     v1 = readV1Plugin(mod)          // mod.default is a record with id/server/tui
 *     if (v1) { resolvePluginId(...); hooks.push(await v1.server(...)); return }
 *     for (const server of getLegacyPlugins(mod)) hooks.push(await server(...))
 *
 *   getLegacyPlugins(mod):
 *     for (const entry of Object.values(mod))
 *       if (!isFunction(entry) && !isFunction(entry?.server))
 *         throw new TypeError("Plugin export is not a function")   // index.ts:103
 *
 * The two ways a deployed plugin file can break, both observed for real:
 *
 *   1. LOUD (devbox, 2026-07-30). Legacy shape + `export function helper`. The
 *      loader calls the helper as a plugin factory and pushes its return value
 *      into the hooks array unvalidated. `undefined` in that array makes every
 *      later hook iteration throw: GET /config/providers 500s and no prompt can
 *      run on that serve.
 *   2. QUIET (cloudbox, same day, shipped as the "fix" for #1). Legacy shape +
 *      `export const internals = {...}` trips the throw above, so the ENTIRE
 *      FILE is rejected. The serve survives; the plugin is simply gone. For
 *      shell-env that means no OPENCODE_HOSTNAME, no sops secrets and no
 *      per-session KUBECONFIG isolation, announced only by one ERROR line in
 *      ~/.local/share/opencode/log/opencode.log.
 *
 * Note that a plugin using the v1 shape (`export default { id, server }`) is
 * immune to both, because applyPlugin returns before it ever looks at named
 * exports. That is why shell-env.ts uses it.
 *
 * Scope: only files actually deployed by users/dev/opencode-config.nix whose
 * source lives in this directory. Modules that are merely bundled into a
 * deployed artifact (e.g. serve-auth.ts -> self-compact.js) are exempt --
 * opencode never sees them as plugin files.
 */

/** opencode version whose loader this replica mirrors. Re-verify on bump. */
const LOADER_VERSION = "1.17.13"

const PLUGIN_DIR = path.join(__dirname, "..")
const NIX_CONFIG = path.join(PLUGIN_DIR, "../../../users/dev/opencode-config.nix")

const isFunction = (v: unknown): boolean => typeof v === "function"

/** Mirrors getServerPlugin() -- a plugin is a function, or an object with a function `server`. */
function getServerPlugin(value: unknown): unknown {
  if (isFunction(value)) return value
  if (!value || typeof value !== "object" || !("server" in value)) return undefined
  const server = (value as { server: unknown }).server
  return isFunction(server) ? server : undefined
}

/** Mirrors readV1Plugin(mod, spec, "server", "detect"). */
function readV1Plugin(mod: Record<string, unknown>): Record<string, unknown> | undefined {
  const value = mod.default
  const isRecord = !!value && typeof value === "object" && !Array.isArray(value)
  if (!isRecord) return undefined
  const rec = value as Record<string, unknown>
  if (!("id" in rec) && !("server" in rec) && !("tui" in rec)) return undefined
  return rec
}

/** Filenames referenced by an `xdg.configFile."opencode/plugins/<name>"` line. */
function deployedPluginFilenames(): string[] {
  const nix = fs.readFileSync(NIX_CONFIG, "utf8")
  const re = /xdg\.configFile\."opencode\/plugins\/([^"]+)"/g
  const names = new Set<string>()
  for (const m of nix.matchAll(re)) names.add(m[1])
  return [...names].filter((n) => /\.(ts|js)$/.test(n))
}

describe(`deployed opencode plugin files load under the v${LOADER_VERSION} loader`, () => {
  const deployed = deployedPluginFilenames().filter((n) => fs.existsSync(path.join(PLUGIN_DIR, n)))

  it("discovers deployed plugin sources from opencode-config.nix", () => {
    expect(deployed.length).toBeGreaterThan(0)
    expect(deployed).toContain("shell-env.ts")
  })

  it.each(deployed)("%s is accepted by the loader replica", async (name) => {
    const mod: Record<string, unknown> = await import(path.join(PLUGIN_DIR, name))
    const v1 = readV1Plugin(mod)

    if (v1) {
      // v1 branch: named exports are unreachable, but `id` is mandatory for
      // file-sourced plugins -- resolvePluginId() throws without it.
      expect(typeof v1.id, `${name} uses the v1 shape but is missing a string \`id\`. ` + "resolvePluginId() throws `Path plugin ... must export id` for file-sourced plugins.").toBe(
        "string",
      )
      expect(String(v1.id).trim().length, `${name} has an empty \`id\`.`).toBeGreaterThan(0)
      expect(isFunction(v1.server) || isFunction(v1.tui), `${name} v1 default export has neither a \`server\` nor a \`tui\` function.`).toBe(true)
      return
    }

    // Legacy branch: EVERY export must be a function (or a { server } object),
    // or getLegacyPlugins() throws and the whole file is rejected.
    const offenders = Object.entries(mod)
      .filter(([, v]) => getServerPlugin(v) === undefined)
      .map(([k]) => k)

    expect(
      offenders,
      `${name} uses the legacy shape, so opencode iterates ALL its exports and ` +
        "throws `Plugin export is not a function` on the first one that is not a " +
        `function -- rejecting the entire file. Offending export(s): [${offenders.join(", ")}]. ` +
        "Fix by switching the file to the v1 shape (`export default { id: \"<name>\", server: plugin }`), " +
        "which makes the loader ignore named exports entirely. Do NOT 'fix' this by " +
        "wrapping helpers in an object export -- that is what caused this failure.",
    ).toEqual([])
  })

  it.each(deployed)("%s produces hook-shaped values, not undefined", async (name) => {
    const mod: Record<string, unknown> = await import(path.join(PLUGIN_DIR, name))
    const v1 = readV1Plugin(mod)
    const factories = v1 ? [v1.server].filter(isFunction) : Object.values(mod).map(getServerPlugin).filter(isFunction)

    const input = {
      client: {} as unknown,
      app: {} as unknown,
      $: undefined,
      directory: process.cwd(),
      worktree: process.cwd(),
      project: { id: "test" },
    }

    for (const factory of factories) {
      let result: unknown
      try {
        result = await (factory as (i: unknown, o: unknown) => unknown)(input, {})
      } catch {
        // A factory that THROWS is contained: applyPlugin runs inside
        // Effect.tryPromise, so the plugin is dropped and the serve survives.
        // Only a successful non-object return poisons the hooks array.
        continue
      }
      expect(
        result !== null && typeof result === "object",
        `${name}: a plugin factory resolved to \`${typeof result}\`, not a hooks object. ` +
          "opencode pushes this into the hooks array without validating it; a non-object " +
          "there makes every later hook iteration throw, which takes down the whole serve " +
          "(no provider catalog, no prompts). This is the 2026-07-30 devbox outage.",
      ).toBe(true)
    }
  })
})
