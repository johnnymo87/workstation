import type { Plugin } from "@opencode-ai/plugin"
import * as path from "node:path"
import * as os from "node:os"
import * as fs from "node:fs"
import { execFileSync } from "node:child_process"

// Opencode tool-id coupling; re-verify on upgrade — bead workstation-v03j.1.
// These must be sorted alphabetically.
export const GUARDED_TOOLS = ["apply_patch", "bash", "edit", "write"] as const

/**
 * Normalizes a path using fs.realpathSync when possible to resolve symlinks,
 * falling back to path.resolve if the path does not exist.
 */
export function normalizePath(p: string): string {
  try {
    return fs.realpathSync(p)
  } catch {
    return path.resolve(p)
  }
}

/**
 * Finds the nearest existing ancestor directory of the given target path.
 * Walk up the directory tree until we find a directory that exists.
 */
export function nearestExistingAncestorDir(targetPath: string): string {
  let current = path.resolve(targetPath)
  while (current) {
    try {
      const stat = fs.statSync(current)
      if (stat.isDirectory()) {
        return current
      }
      const parent = path.dirname(current)
      if (parent === current) break
      current = parent
    } catch {
      const parent = path.dirname(current)
      if (parent === current) break
      current = parent
    }
  }
  return current
}

/**
 * Real git toplevel lookup using child_process.execFileSync.
 * Returns undefined on error or if not in a git repo.
 */
export function getRealGitToplevel(dir: string): string | undefined {
  try {
    const out = execFileSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], {
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8"
    })
    return out.trim()
  } catch {
    return undefined
  }
}

/**
 * Parses target paths from standard apply_patch envelope lines:
 * *** Update File: <path>
 * *** Add File: <path>
 * *** Delete File: <path>
 * *** Move to: <path>
 */
export function parseApplyPatchPaths(patchText: string): string[] {
  if (typeof patchText !== "string") return []
  const paths: string[] = []
  const lines = patchText.split(/\r?\n/)
  const prefixes = [
    "*** Update File: ",
    "*** Add File: ",
    "*** Delete File: ",
    "*** Move to: "
  ]
  for (const line of lines) {
    const trimmed = line.trim()
    for (const prefix of prefixes) {
      if (trimmed.startsWith(prefix)) {
        const filePath = trimmed.substring(prefix.length).trim()
        if (filePath) {
          paths.push(filePath)
        }
      }
    }
  }
  return paths
}

/**
 * Parses git commit commands to extract target roots specified via the -C option.
 * Minimal bash handling of git commit commands.
 */
export function parseGitCommitRoots(command: string): string[] {
  if (typeof command !== "string") return []
  const roots: string[] = []
  // Split command on &&, ||, ;, |, newline
  const segments = command.split(/&&|\|\||;|\||\n/)
  for (let segment of segments) {
    segment = segment.trim()
    if (!segment) continue
    // Tokenize by whitespace
    const tokens = segment.split(/\s+/)
    let i = 0
    // Skip "git" if it's the first token
    if (tokens[i] === "git") {
      i++
    } else {
      continue
    }
    let gitCommitPath: string | undefined = undefined
    let isCommit = false
    while (i < tokens.length) {
      const token = tokens[i]
      if (token === "-C") {
        gitCommitPath = tokens[i + 1]
        i += 2
      } else if (token === "-c") {
        i += 2
      } else if (token.startsWith("--git-dir=")) {
        i++
      } else if (token.startsWith("--work-tree=")) {
        i++
      } else if (token.startsWith("--namespace=")) {
        i++
      } else if (token.startsWith("-")) {
        i++
      } else {
        if (token === "commit") {
          isCommit = true
        }
        break
      }
    }
    if (isCommit && gitCommitPath) {
      const cleaned = gitCommitPath.replace(/^['"]|['"]$/g, "")
      roots.push(cleaned)
    }
  }
  return roots
}

/**
 * Classifies whether a target path is located in an enrolled primary root.
 */
export function classify(
  targetPath: string,
  enrolledRoots: Map<string, { enforce: "warn" | "block"; trunk?: string; worktreesDir?: string }>,
  gitToplevel: (dir: string) => string | undefined
): { hit: boolean; root?: string; enforce?: "warn" | "block" } {
  const isAbs = path.isAbsolute(targetPath)
  if (isAbs) {
    const ancestor = nearestExistingAncestorDir(targetPath)
    const toplevel = gitToplevel(ancestor)
    if (toplevel) {
      const normToplevel = normalizePath(toplevel)
      if (enrolledRoots.has(normToplevel)) {
        return { hit: true, root: normToplevel, enforce: enrolledRoots.get(normToplevel)!.enforce }
      }
    }
  } else {
    // Relative path (cwd unknown)
    // Defends the root regardless of real cwd by trying each enrolled root as a base.
    // Rare worktree false-positives acceptable in warn.
    for (const [root, meta] of enrolledRoots.entries()) {
      const fullPath = path.join(root, targetPath)
      const ancestor = nearestExistingAncestorDir(fullPath)
      const toplevel = gitToplevel(ancestor)
      if (toplevel) {
        const normToplevel = normalizePath(toplevel)
        if (normToplevel === root) {
          return { hit: true, root, enforce: meta.enforce }
        }
      }
    }
  }
  return { hit: false }
}

const warnedSessions = new Set<string>()

const plugin: Plugin = async () => {
  // Config: read ~/.config/opencode/worktree-guard.json
  const configPath = path.join(os.homedir(), ".config", "opencode", "worktree-guard.json")
  let config: Array<{ path: string; trunk?: string; enforce?: "warn" | "block"; worktreesDir?: string }> = []
  try {
    const raw = fs.readFileSync(configPath, "utf8")
    config = JSON.parse(raw)
  } catch {
    config = []
  }

  // Build Map of enrolled roots
  const enrolledRoots = new Map<string, { enforce: "warn" | "block"; trunk?: string; worktreesDir?: string }>()
  for (const entry of config) {
    if (entry && typeof entry.path === "string") {
      const norm = normalizePath(entry.path)
      enrolledRoots.set(norm, {
        enforce: entry.enforce === "block" ? "block" : "warn",
        trunk: entry.trunk,
        worktreesDir: entry.worktreesDir
      })
    }
  }

  return {
    "tool.execute.before": async (input, output) => {
      // WRAP THE WHOLE BODY in try/catch that returns=ALLOW on ANY error — never fail-closed
      try {
        if (enrolledRoots.size === 0) return

        if (!GUARDED_TOOLS.includes(input.tool as any)) return

        const targets: string[] = []
        if (input.tool === "edit" || input.tool === "write") {
          const filePath = output.args?.filePath
          if (typeof filePath === "string") {
            targets.push(filePath)
          }
        } else if (input.tool === "apply_patch") {
          const patchText = output.args?.patchText
          if (typeof patchText === "string") {
            targets.push(...parseApplyPatchPaths(patchText))
          }
        } else if (input.tool === "bash") {
          const command = output.args?.command
          if (typeof command === "string") {
            targets.push(...parseGitCommitRoots(command))
          }
        }

        for (const target of targets) {
          const classification = classify(target, enrolledRoots, getRealGitToplevel)
          if (classification.hit && classification.root) {
            const root = classification.root
            const enforce = classification.enforce
            const msg = `[worktree-guard] ${input.tool} would write into the read-only primary root ${root} (${target}). Create a fresh worktree instead: run 'work <slug>'.`
            if (enforce === "block") {
              throw new Error(msg)
            } else {
              // warn mode (logs, no throw)
              const warnKey = `${input.sessionID || ""}:${root}:${target}`
              if (!warnedSessions.has(warnKey)) {
                if (warnedSessions.size > 1000) {
                  warnedSessions.clear()
                }
                warnedSessions.add(warnKey)
                console.error(msg)
              }
            }
          }
        }
      } catch (err) {
        // If it's the Block Error, we must bubble it up (throw)
        if (err instanceof Error && err.message.includes("[worktree-guard]")) {
          throw err
        }
        // Otherwise, ignore/allow
      }
    }
  }
}

export default plugin
