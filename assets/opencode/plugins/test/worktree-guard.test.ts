import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import { execFileSync } from "node:child_process"
import plugin, {
  GUARDED_TOOLS,
  parseApplyPatchPaths,
  parseGitCommitRoots,
  classify,
  normalizePath,
  nearestExistingAncestorDir
} from "../worktree-guard"

// Variables used in hoisted vi.mock factories must start with the "mock" prefix
let mockConfigContent: any = null

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs")>()
  return {
    ...actual,
    readFileSync: vi.fn().mockImplementation((p: any, ...args: any[]) => {
      if (typeof p === "string" && p.includes("worktree-guard.json") && mockConfigContent !== null) {
        return JSON.stringify(mockConfigContent)
      }
      return (actual.readFileSync as any)(p, ...args)
    })
  }
})

async function runHook(
  input: { tool: string; sessionID?: string },
  args: any,
  configContent: any
) {
  mockConfigContent = configContent
  const hooks = await plugin({} as never)
  const hook = hooks["tool.execute.before"]
  if (!hook) throw new Error("tool.execute.before hook not registered")

  const output = { args }
  const consoleErrors: string[] = []
  const originalConsoleError = console.error
  console.error = (...msg: any[]) => {
    consoleErrors.push(msg.join(" "))
  }

  try {
    await hook(input as never, output as never)
    return { thrown: null, logs: consoleErrors }
  } catch (err) {
    return { thrown: err as Error, logs: consoleErrors }
  } finally {
    console.error = originalConsoleError
    mockConfigContent = null
  }
}

describe("worktree-guard basic plugin invariants", () => {
  it("change-detector: GUARDED_TOOLS is sorted and matches the expected set", () => {
    expect([...GUARDED_TOOLS].sort()).toEqual(["apply_patch", "bash", "edit", "write"])
    expect(GUARDED_TOOLS).toEqual(["apply_patch", "bash", "edit", "write"])
  })

  it("parseApplyPatchPaths: extracts paths from standard apply_patch envelopes", () => {
    const patchText = `
*** Update File: src/main.ts
some patch diff content
*** Add File: src/utils.ts
more diff
*** Delete File: old.ts
*** Move to: renamed.ts
`
    expect(parseApplyPatchPaths(patchText)).toEqual([
      "src/main.ts",
      "src/utils.ts",
      "old.ts",
      "renamed.ts"
    ])
  })

  it("parseApplyPatchPaths: handles invalid or empty input gracefully", () => {
    expect(parseApplyPatchPaths("")).toEqual([])
    expect(parseApplyPatchPaths(null as any)).toEqual([])
  })

  it("parseGitCommitRoots: extracts root directory path from -C options", () => {
    expect(parseGitCommitRoots("git -C /home/dev/projects/mono commit -m 'feat'")).toEqual([
      "/home/dev/projects/mono"
    ])
    expect(parseGitCommitRoots("git -C /home/dev/projects/mono commit && git push")).toEqual([
      "/home/dev/projects/mono"
    ])
    expect(parseGitCommitRoots("git commit")).toEqual([])
  })

  it("nearestExistingAncestorDir: walks up correctly", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "worktree-guard-test-ancestor-"))
    try {
      const nestedNonexistent = path.join(tmp, "foo", "bar", "baz.txt")
      const resolved = nearestExistingAncestorDir(nestedNonexistent)
      expect(resolved).toBe(normalizePath(tmp))
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true })
    }
  })
})

describe("worktree-guard live git integration", () => {
  let tempDir: string
  let rootDir: string
  let childDir: string
  let outsideDir: string

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "worktree-guard-test-git-"))

    // 1. Create a primary root repo
    rootDir = path.join(tempDir, "primary-root")
    fs.mkdirSync(rootDir)
    execFileSync("git", ["init", "-b", "main"], { cwd: rootDir })
    execFileSync("git", ["config", "user.name", "Test User"], { cwd: rootDir })
    execFileSync("git", ["config", "user.email", "test@example.com"], { cwd: rootDir })

    fs.writeFileSync(path.join(rootDir, "README.md"), "hello")
    execFileSync("git", ["add", "README.md"], { cwd: rootDir })
    execFileSync("git", ["commit", "-m", "initial commit"], { cwd: rootDir })

    // 2. Create child worktree under .worktrees
    const worktreesDir = path.join(rootDir, ".worktrees")
    fs.mkdirSync(worktreesDir)
    childDir = path.join(worktreesDir, "child")
    execFileSync("git", ["worktree", "add", childDir, "-b", "child-branch"], { cwd: rootDir })

    // 3. Create an outside directory (not in a git repo)
    outsideDir = path.join(tempDir, "outside")
    fs.mkdirSync(outsideDir)
  })

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true })
  })

  it("edit tracked file AT root hits (warn: logs, block: throws)", async () => {
    const targetFile = path.join(rootDir, "README.md")

    // 1. Warn mode (default)
    const configWarn = [{ path: rootDir, enforce: "warn" as const }]
    const resWarn = await runHook({ tool: "edit" }, { filePath: targetFile }, configWarn)
    expect(resWarn.thrown).toBeNull()
    expect(resWarn.logs.length).toBe(1)
    expect(resWarn.logs[0]).toContain(`would write into the read-only primary root ${normalizePath(rootDir)}`)

    // 2. Block mode
    const configBlock = [{ path: rootDir, enforce: "block" as const }]
    const resBlock = await runHook({ tool: "edit" }, { filePath: targetFile }, configBlock)
    expect(resBlock.thrown).toBeInstanceOf(Error)
    expect(resBlock.thrown?.message).toContain(`would write into the read-only primary root ${normalizePath(rootDir)}`)
  })

  it("edit file under child worktree does not hit", async () => {
    const targetFile = path.join(childDir, "README.md")
    const config = [{ path: rootDir, enforce: "warn" as const }]
    const res = await runHook({ tool: "edit" }, { filePath: targetFile }, config)
    expect(res.thrown).toBeNull()
    expect(res.logs).toEqual([])
  })

  it("edit file outside any enrolled repo does not hit", async () => {
    const targetFile = path.join(outsideDir, "some-file.txt")
    const config = [{ path: rootDir, enforce: "warn" as const }]
    const res = await runHook({ tool: "edit" }, { filePath: targetFile }, config)
    expect(res.thrown).toBeNull()
    expect(res.logs).toEqual([])
  })

  it("apply_patch patchText targeting root hits, targeting child worktree does not", async () => {
    const patchTextRoot = `*** Update File: ${path.join(rootDir, "README.md")}\nhello`
    const patchTextChild = `*** Update File: ${path.join(childDir, "README.md")}\nhello`

    const config = [{ path: rootDir, enforce: "warn" as const }]

    // Root hit
    const resRoot = await runHook({ tool: "apply_patch" }, { patchText: patchTextRoot }, config)
    expect(resRoot.thrown).toBeNull()
    expect(resRoot.logs.length).toBe(1)

    // Child no hit
    const resChild = await runHook({ tool: "apply_patch" }, { patchText: patchTextChild }, config)
    expect(resChild.thrown).toBeNull()
    expect(resChild.logs).toEqual([])
  })

  it("relative filePath resolving into root hits", async () => {
    const config = [{ path: rootDir, enforce: "warn" as const }]
    const res = await runHook({ tool: "edit" }, { filePath: "README.md" }, config)
    expect(res.thrown).toBeNull()
    expect(res.logs.length).toBe(1)
  })

  it("resolution error / non-git path / tool not in set / empty config allows and does not throw", async () => {
    // Tool not in set
    const resTool = await runHook({ tool: "read" }, { filePath: path.join(rootDir, "README.md") }, [{ path: rootDir }])
    expect(resTool.thrown).toBeNull()
    expect(resTool.logs).toEqual([])

    // Empty config
    const resEmpty = await runHook({ tool: "edit" }, { filePath: path.join(rootDir, "README.md") }, [])
    expect(resEmpty.thrown).toBeNull()
    expect(resEmpty.logs).toEqual([])

    // Non-git path
    const resNonGit = await runHook({ tool: "edit" }, { filePath: "/nonexistent-path-abc/file.txt" }, [{ path: rootDir }])
    expect(resNonGit.thrown).toBeNull()
    expect(resNonGit.logs).toEqual([])
  })
})
