import type { Plugin } from "@opencode-ai/plugin"
import * as os from "node:os"
import * as fs from "node:fs"

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

/**
 * Injects environment variables into every bash tool invocation via the
 * `shell.env` hook (see opencode/packages/opencode/src/tool/bash.ts).
 *
 * Four purposes:
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
  },
})

export default plugin
