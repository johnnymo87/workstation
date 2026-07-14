import { describe, it, expect, vi, beforeEach } from "vitest"
import * as fs from "node:fs"
import plugin from "../shell-env"

// shell-env.ts reads sops secrets via fs.readFileSync(/run/secrets/<name>).
// Mock that boundary so the secret-injection path is deterministic and
// independent of the host the test runs on.
vi.mock("node:fs", () => ({ readFileSync: vi.fn() }))

// Make fs.readFileSync resolve the given map (keyed by full /run/secrets path)
// and throw (file absent) for anything else — mirroring a real missing file.
function withSecrets(files: Record<string, string>) {
  vi.mocked(fs.readFileSync).mockImplementation(((path: unknown) => {
    const key = String(path)
    if (Object.prototype.hasOwnProperty.call(files, key)) return files[key]
    throw new Error(`ENOENT: ${key}`)
  }) as typeof fs.readFileSync)
}

// Resolve the shell.env hook the plugin registers.
async function getShellEnvHook() {
  const hooks = await plugin({} as never)
  const hook = hooks["shell.env"]
  if (!hook) throw new Error("plugin did not register a shell.env hook")
  return hook
}

async function runHook(
  input: Record<string, unknown>,
): Promise<Record<string, string>> {
  const hook = await getShellEnvHook()
  const output = { env: {} as Record<string, string> }
  await hook(input as never, output)
  return output.env
}

beforeEach(() => {
  vi.mocked(fs.readFileSync).mockReset()
})

describe("shell-env plugin: non-interactive + self-awareness", () => {
  it("forces non-interactive editor/pager defaults", async () => {
    withSecrets({})
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.GIT_EDITOR).toBe(":")
    expect(env.EDITOR).toBe(":")
    expect(env.GIT_SEQUENCE_EDITOR).toBe(":")
    expect(env.GIT_PAGER).toBe("cat")
  })

  it("exposes session + host self-awareness vars", async () => {
    withSecrets({})
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.OPENCODE_SESSION_ID).toBe("ses_abc")
    expect(typeof env.OPENCODE_HOSTNAME).toBe("string")
    expect(env.OPENCODE_HOSTNAME.length).toBeGreaterThan(0)
  })

  it("omits OPENCODE_SESSION_ID when there is no sessionID", async () => {
    withSecrets({})
    const env = await runHook({})
    expect(env).not.toHaveProperty("OPENCODE_SESSION_ID")
  })

  it("preserves env keys set by other plugins", async () => {
    withSecrets({})
    const hook = await getShellEnvHook()
    const output = { env: { PRESET: "keep-me" } as Record<string, string> }
    await hook({ sessionID: "ses_abc" } as never, output)
    expect(output.env.PRESET).toBe("keep-me")
  })
})

describe("shell-env plugin: sops secret injection", () => {
  it("injects the work-tool secrets named in the bead acceptance criteria", async () => {
    withSecrets({
      "/run/secrets/github_api_token": "gh-token",
      "/run/secrets/jenkins_api_token": "jenkins-token",
      "/run/secrets/jenkins_user": "jenkins-user",
      "/run/secrets/dd_pat": "dd-pat",
      "/run/secrets/buildbuddy_host": "bb-host",
      "/run/secrets/buildbuddy_api_key": "bb-key",
      "/run/secrets/bundle_gem_fury_io": "fury",
      "/run/secrets/bundle_enterprise_contribsys_com": "contribsys",
      "/run/secrets/bundle_gems_graphql_pro": "graphql",
      "/run/secrets/ba_cli_repo": "ba-repo",
      "/run/secrets/google_cloud_project": "gcp-proj",
    })
    const env = await runHook({ sessionID: "ses_abc" })

    expect(env.JENKINS_API_TOKEN).toBe("jenkins-token")
    expect(env.JENKINS_USER).toBe("jenkins-user")
    expect(env.DD_PAT).toBe("dd-pat")
    expect(env.BUILDBUDDY_HOST).toBe("bb-host")
    expect(env.BUILDBUDDY_API_KEY).toBe("bb-key")
    expect(env.BUNDLE_GEM__FURY__IO).toBe("fury")
    expect(env.BUNDLE_ENTERPRISE__CONTRIBSYS__COM).toBe("contribsys")
    expect(env.BUNDLE_GEMS__GRAPHQL__PRO).toBe("graphql")
    expect(env.BA_CLI_REPO).toBe("ba-repo")
    expect(env.GOOGLE_CLOUD_PROJECT).toBe("gcp-proj")
  })

  it("exports the github token under both GH_TOKEN and GITHUB_API_TOKEN", async () => {
    withSecrets({ "/run/secrets/github_api_token": "gh-token" })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.GH_TOKEN).toBe("gh-token")
    expect(env.GITHUB_API_TOKEN).toBe("gh-token")
  })

  it("trims trailing whitespace/newlines from secret file contents", async () => {
    withSecrets({ "/run/secrets/jenkins_api_token": "  jenkins-token\n" })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.JENKINS_API_TOKEN).toBe("jenkins-token")
  })

  it("derives the base64 ADO npm PAT from the azure devops PAT", async () => {
    withSecrets({ "/run/secrets/azure_devops_pat": "ado-pat" })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.SYSTEM_ACCESSTOKEN).toBe("ado-pat")
    expect(env.ADO_NPM_PAT_B64).toBe(Buffer.from("ado-pat").toString("base64"))
  })

  it("composes the BUNDLE_<HOST> var name dynamically from the source host", async () => {
    withSecrets({
      "/run/secrets/bundle_source_host": "vendor.example.com",
      "/run/secrets/bundle_source_token": "vendor-tok",
    })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.BUNDLE_VENDOR__EXAMPLE__COM).toBe("vendor-tok")
  })

  it("skips the dynamic bundle source when only one of host/token is present", async () => {
    withSecrets({ "/run/secrets/bundle_source_host": "vendor.example.com" })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env).not.toHaveProperty("BUNDLE_VENDOR__EXAMPLE__COM")
  })

  it("is host-safe: injects no secret vars when /run/secrets/* is absent", async () => {
    // Every read throws (no files) -> only the non-secret vars are set.
    withSecrets({})
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env).not.toHaveProperty("JENKINS_API_TOKEN")
    expect(env).not.toHaveProperty("GH_TOKEN")
    expect(env).not.toHaveProperty("DD_PAT")
    // The non-secret invariants still hold.
    expect(env.GIT_EDITOR).toBe(":")
    expect(env.OPENCODE_SESSION_ID).toBe("ses_abc")
  })

  it("skips a missing secret while still injecting present ones", async () => {
    withSecrets({ "/run/secrets/jenkins_api_token": "jenkins-token" })
    const env = await runHook({ sessionID: "ses_abc" })
    expect(env.JENKINS_API_TOKEN).toBe("jenkins-token")
    expect(env).not.toHaveProperty("JENKINS_USER")
    expect(env).not.toHaveProperty("GH_TOKEN")
  })
})
