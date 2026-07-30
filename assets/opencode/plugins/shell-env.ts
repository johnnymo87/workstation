import type { Plugin } from "@opencode-ai/plugin"
import * as os from "node:os"
import * as fs from "node:fs"
import * as path from "node:path"

/**
 * Read a sops-decrypted secret file, returning its trimmed contents or
 * undefined if the file is absent/unreadable. Host-safe: on machines without
 * /run/secrets/* (devbox/macOS) every call returns undefined.
 */
function readSecret(path: string): string | undefined {
  try {
    return fs.readFileSync(path, "utf8").trim()
  } catch {
    return undefined
  }
}

/**
 * Compute the sops-secret-derived env vars to inject into bash sessions.
 *
 * Mirrors the secret-reading block of users/dev/home.cloudbox.nix
 * `programs.bash.initExtra`. That block lives behind ~/.bashrc's interactive
 * guard (`[[ $- == *i* ]] || return`), so it never runs in opencode's
 * non-interactive bash tool sessions. Re-reading /run/secrets/* here closes
 * that gap.
 *
 * Host-safe: every secret is optional, so on devbox/macOS (no
 * /run/secrets/*) this returns an empty object. Inlined (not imported from a
 * sibling module) so the deployed single-file plugin has no relative-import
 * dependency; `read` is injected so the mapping is unit-testable.
 */
function loadSecretEnv(read: (path: string) => string | undefined): Record<string, string> {
  const env: Record<string, string> = {}

  // Simple 1:1 secret-file -> env-var mappings. Each entry is
  // [/run/secrets/<file>, ENV_VAR]. github_api_token intentionally maps to two
  // names (gh CLI uses GH_TOKEN; the ba CLI uses GITHUB_API_TOKEN).
  const simple: ReadonlyArray<readonly [string, string]> = [
    ["github_api_token", "GH_TOKEN"],
    ["github_api_token", "GITHUB_API_TOKEN"],
    ["cloudflare_api_token", "CLOUDFLARE_API_TOKEN"],
    ["dolthub_api_token", "DOLTHUB_API_TOKEN"],
    ["claude_personal_oauth_token", "CLAUDE_CODE_OAUTH_TOKEN"],
    ["gemini_api_key", "GOOGLE_GENERATIVE_AI_API_KEY"],
    ["atlassian_api_token", "ATLASSIAN_API_TOKEN"],
    ["atlassian_site", "ATLASSIAN_SITE"],
    ["atlassian_email", "ATLASSIAN_EMAIL"],
    ["atlassian_cloud_id", "ATLASSIAN_CLOUD_ID"],
    ["google_cloud_project", "GOOGLE_CLOUD_PROJECT"],
    ["ba_cli_repo", "BA_CLI_REPO"],
    ["jenkins_api_token", "JENKINS_API_TOKEN"],
    ["jenkins_user", "JENKINS_USER"],
    ["bundle_gem_fury_io", "BUNDLE_GEM__FURY__IO"],
    ["bundle_enterprise_contribsys_com", "BUNDLE_ENTERPRISE__CONTRIBSYS__COM"],
    ["bundle_gems_graphql_pro", "BUNDLE_GEMS__GRAPHQL__PRO"],
    ["dd_pat", "DD_PAT"],
    ["buildbuddy_host", "BUILDBUDDY_HOST"],
    ["buildbuddy_api_key", "BUILDBUDDY_API_KEY"],
  ]
  for (const [file, name] of simple) {
    const value = read(`/run/secrets/${file}`)
    if (value) env[name] = value
  }

  // Azure DevOps PAT: exported raw (SYSTEM_ACCESSTOKEN) and base64-encoded
  // (ADO_NPM_PAT_B64) for the private npm registry .npmrc.
  const adoPat = read("/run/secrets/azure_devops_pat")
  if (adoPat) {
    env.SYSTEM_ACCESSTOKEN = adoPat
    env.ADO_NPM_PAT_B64 = Buffer.from(adoPat).toString("base64")
  }

  // Bundler private gem source whose host is vendor-encoded. The Bundler env
  // var name is BUNDLE_<HOST upper-cased, dots -> "__">; compose it dynamically
  // so the vendor host never appears in source (mirrors the nix block).
  const bundleHost = read("/run/secrets/bundle_source_host")
  const bundleToken = read("/run/secrets/bundle_source_token")
  if (bundleHost && bundleToken) {
    const varName = "BUNDLE_" + bundleHost.toUpperCase().replace(/\./g, "__")
    env[varName] = bundleToken
  }

  return env
}

export interface KubeFS {
  existsSync: (path: string) => boolean
  readFileSync: (path: string, encoding: "utf8") => string
  writeFileSync: (path: string, data: string) => void
  mkdirSync: (path: string, options?: { recursive?: boolean }) => void
  copyFileSync: (src: string, dest: string) => void
  getUid?: () => number | undefined
  homedir?: () => string
}

const defaultKubeFS: KubeFS = {
  existsSync: fs.existsSync,
  readFileSync: (p, e) => fs.readFileSync(p, e),
  writeFileSync: (p, d) => fs.writeFileSync(p, d, "utf8"),
  mkdirSync: (p, o) => {
    fs.mkdirSync(p, o)
  },
  copyFileSync: fs.copyFileSync,
  getUid: () => (process.getuid ? process.getuid() : undefined),
  homedir: os.homedir,
}

/**
 * Compute the per-session KUBECONFIG overlay env var (KUBECONFIG=<overlay>:<shared>).
 *
 * Prevents opencode sessions from accidentally mutating each other's active
 * Kubernetes context or namespace when running `kubectl config use-context` or
 * `kubectl config set-context --current --namespace=...`.
 *
 * Injected dependencies allow complete unit testing without touching disk.
 * Fail-open: returns undefined on any error or missing prerequisite.
 *
 * DO NOT `export` THIS (or any other function) AT MODULE SCOPE. opencode's
 * legacy plugin loader treats EVERY function export of an auto-discovered
 * plugin file as a plugin factory: it iterates `Object.values(mod)` and does
 * `hooks.push(await server(input, opts))` WITHOUT validating the result. A
 * named helper therefore gets invoked with the PluginInput object as its first
 * argument, and whatever it returns is pushed into the hooks array.
 *
 * When that return value is `undefined`, the hooks array is poisoned and every
 * later hook iteration dies on a property access:
 *   plugin config hook failed  -> undefined is not an object (evaluating 'N.config')
 *   GET /config/providers 500  -> undefined is not an object (evaluating 'n.provider')
 *   prompt_async failed        -> Die(undefined is not an object (evaluating 'z[W]'))
 * i.e. the whole serve loses its provider catalog and cannot run ANY prompt.
 *
 * This bit devbox on 2026-07-30: exporting this helper was harmless on hosts
 * with a ~/.kube/config (it returned a string) but fatal on hosts without one
 * (it returned undefined). Non-function exports are safe -- the loader skips
 * them -- which is why the unit-test surface below is an object, and why
 * `export interface KubeFS` is fine (types are erased at runtime).
 */
function loadKubeconfigEnv(
  sessionID: string | undefined,
  processEnv: Record<string, string | undefined> = process.env,
  sys: KubeFS = defaultKubeFS,
): string | undefined {
  try {
    if (!sessionID) return undefined

    let runtimeDir = processEnv.XDG_RUNTIME_DIR
    if (!runtimeDir) {
      const uid = sys.getUid ? sys.getUid() : undefined
      if (uid !== undefined) {
        runtimeDir = `/run/user/${uid}`
      }
    }
    if (!runtimeDir) return undefined

    const home = processEnv.HOME || (sys.homedir ? sys.homedir() : undefined)
    if (!home) return undefined

    const sharedConfig = path.join(home, ".kube", "config")
    if (!sys.existsSync(sharedConfig)) return undefined

    const kubeDir = path.join(runtimeDir, "opencode-kube")
    const overlayConfig = path.join(kubeDir, `${sessionID}.yaml`)

    let isValidOverlay = false
    if (sys.existsSync(overlayConfig)) {
      try {
        const content = sys.readFileSync(overlayConfig, "utf8")
        if (content.includes("apiVersion:") && content.includes("kind: Config")) {
          isValidOverlay = true
        }
      } catch {
        isValidOverlay = false
      }
    }

    if (!isValidOverlay) {
      sys.mkdirSync(kubeDir, { recursive: true })

      const readmePath = path.join(kubeDir, "README")
      if (!sys.existsSync(readmePath)) {
        try {
          const readmeText =
            "Per-session KUBECONFIG overlays for OpenCode.\n" +
            "Created by assets/opencode/plugins/shell-env.ts to prevent sessions from overwriting each other's active Kubernetes context or namespace.\n" +
            "Deleting an overlay resets that session to the shared config (~/.kube/config).\n"
          sys.writeFileSync(readmePath, readmeText)
        } catch {
          // best-effort ignore
        }
      }

      sys.copyFileSync(sharedConfig, overlayConfig)
    }

    return `${overlayConfig}:${sharedConfig}`
  } catch {
    return undefined
  }
}

/**
 * Injects environment variables into every bash tool invocation via the
 * `shell.env` hook (see opencode/packages/opencode/src/tool/bash.ts).
 *
 * Five purposes:
 * 1. Force non-interactive defaults so commands never wait on a TTY.
 * 2. Expose session metadata (OPENCODE_SESSION_ID) so an agent can discover
 *    its own session ID — needed for opencode-to-opencode handoffs via
 *    `opencode-send <id> "msg"`.
 * 3. Expose the host's hostname (OPENCODE_HOSTNAME) so an agent can
 *    disambiguate which machine it is on (devbox / cloudbox / macOS)
 *    without spawning a `hostname` subprocess. See the "Host
 *    Identification" section in the repo-level AGENTS.md.
 * 4. Inject sops secrets (cloudbox) so work tokens (JENKINS_API_TOKEN,
 *    GITHUB_API_TOKEN, BUNDLE_*, DD_*, BUILDBUDDY_*, etc.) are available in
 *    non-interactive bash sessions. ~/.bashrc's interactive guard
 *    short-circuits programs.bash.initExtra, so those exports never run here;
 *    re-reading /run/secrets/* directly closes that gap. See loadSecretEnv.
 * 5. Inject per-session KUBECONFIG overlay (KUBECONFIG=<overlay>:<shared>) to
 *    isolate active context and namespace changes to individual opencode sessions.
 */
const plugin: Plugin = async () => ({
  "shell.env": async (input, output) => {
    // Non-interactive defaults
    output.env.GIT_EDITOR = ":"
    output.env.EDITOR = ":"
    output.env.GIT_SEQUENCE_EDITOR = ":"
    output.env.GIT_PAGER = "cat"

    // Session self-awareness: lets agents tell peers their own session ID.
    if (input.sessionID) output.env.OPENCODE_SESSION_ID = input.sessionID

    // Host self-awareness: kills the "agent thinks it's on devbox when it's
    // on cloudbox" failure mode. Cheap (sync, no IO).
    output.env.OPENCODE_HOSTNAME = os.hostname()

    // sops secrets: make work tokens available in non-interactive bash
    // sessions. Sync reads of small files at bash-invocation time; host-safe
    // (no-op where /run/secrets/* is absent).
    Object.assign(output.env, loadSecretEnv(readSecret))

    // Per-session KUBECONFIG isolation: inject KUBECONFIG=<overlay>:<shared>
    // to isolate active context and namespace changes to this session.
    try {
      const kubeconfig = loadKubeconfigEnv(input.sessionID)
      if (kubeconfig) output.env.KUBECONFIG = kubeconfig
    } catch {
      // Fail open: never let kubeconfig isolation error disrupt bash env hook
    }
  },
})

export default plugin

/**
 * Unit-test surface. Deliberately an OBJECT, not a function export: opencode's
 * legacy plugin loader invokes every *function* export as a plugin factory (see
 * the warning on loadKubeconfigEnv above) but skips non-functions. Keep it that
 * way -- never promote these back to bare `export function`.
 */
export const internals = { loadKubeconfigEnv }
