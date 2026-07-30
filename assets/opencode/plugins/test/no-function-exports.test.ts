import { describe, it, expect } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"

/**
 * Regression guard for the 2026-07-30 devbox outage.
 *
 * opencode auto-discovers plugin files with the glob `{plugin,plugins}/*.{ts,js}`
 * (one level deep, files only) and its legacy loader treats EVERY function
 * export as a plugin factory: it iterates `Object.values(mod)` and does
 * `hooks.push(await server(input, opts))` without validating the result.
 *
 * So a named helper export gets called with the PluginInput object and its
 * return value is pushed into the hooks array. If it returns `undefined`, the
 * hooks array is poisoned and every subsequent hook iteration throws --
 * `GET /config/providers` 500s and NO prompt can run on that serve. That is
 * exactly what `export function loadKubeconfigEnv` did on devbox, which has no
 * ~/.kube/config (it returned undefined; cloudbox has one, so it returned a
 * harmless string and never tripped).
 *
 * Rule: a file DEPLOYED into ~/.config/opencode/plugins/ may export only its
 * default plugin. Helpers must be non-function exports (objects/types), which
 * the loader skips -- e.g. `export const internals = { myHelper }`.
 *
 * Scope note: this checks only files actually deployed by
 * users/dev/opencode-config.nix. Source-only modules that live in this
 * directory but are bundled into a deployed artifact rather than deployed
 * standalone (e.g. serve-auth.ts -> bundled into self-compact.js) are exempt,
 * because opencode never sees them as plugin files. If you ever add a
 * deployment line for such a module, this test starts covering it.
 */

const PLUGIN_DIR = path.join(__dirname, "..")
const NIX_CONFIG = path.join(PLUGIN_DIR, "../../../users/dev/opencode-config.nix")

/** Filenames referenced by an `xdg.configFile."opencode/plugins/<name>"` line. */
function deployedPluginFilenames(): string[] {
  const nix = fs.readFileSync(NIX_CONFIG, "utf8")
  const re = /xdg\.configFile\."opencode\/plugins\/([^"]+)"/g
  const names = new Set<string>()
  for (const m of nix.matchAll(re)) names.add(m[1])
  return [...names].filter((n) => /\.(ts|js)$/.test(n))
}

describe("deployed opencode plugin files", () => {
  // Some deployed plugins are built artifacts sourced from other nix packages
  // (self-compact.js, superpowers.js, opencode-pigeon.ts) and do not live in
  // this directory, so we can only check the ones whose source is here.
  const deployed = deployedPluginFilenames().filter((n) => fs.existsSync(path.join(PLUGIN_DIR, n)))

  it("discovers deployed plugin sources from opencode-config.nix", () => {
    expect(deployed.length).toBeGreaterThan(0)
    expect(deployed).toContain("shell-env.ts")
  })

  it.each(deployed)("%s exports no bare function besides default", async (name) => {
    const mod: Record<string, unknown> = await import(path.join(PLUGIN_DIR, name))
    const offenders = Object.entries(mod)
      .filter(([k]) => k !== "default")
      .filter(([, v]) => typeof v === "function")
      .map(([k]) => k)

    expect(
      offenders,
      `${name} has bare function export(s) [${offenders.join(", ")}]. opencode's ` +
        "plugin loader calls these as plugin factories and pushes their return " +
        "values into the hooks array; an undefined return breaks the entire serve " +
        "(no provider catalog, no prompts). Wrap helpers in a non-function export, " +
        "e.g. `export const internals = { myHelper }`.",
    ).toEqual([])
  })
})
