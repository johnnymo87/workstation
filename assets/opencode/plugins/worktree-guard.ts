import type { Plugin } from "@opencode-ai/plugin"
import * as path from "node:path"
import * as os from "node:os"
import * as fs from "node:fs"
import { execFileSync } from "node:child_process"

// Opencode tool-id coupling; re-verify on upgrade — bead workstation-v03j.1.
// These must be sorted alphabetically.
export const GUARDED_TOOLS = ["apply_patch", "bash", "edit", "write"] as const

export class WorktreeGuardBlockError extends Error {
  constructor(m: string) {
    super(m)
    this.name = "WorktreeGuardBlockError"
  }
}

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
 * Includes a 1s timeout to fail open on hung NFS/processes.
 */
export function getRealGitToplevel(dir: string): string | undefined {
  try {
    const out = execFileSync("git", ["-C", dir, "rev-parse", "--show-toplevel"], {
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
      timeout: 1000
    })
    return out.trim()
  } catch {
    return undefined
  }
}

export const _internal = {
  getRealGitToplevel
}

/**
 * Parses target paths from standard apply_patch envelope lines.
 * Must match only lines starting with standard envelope headers at column 0.
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
    for (const prefix of prefixes) {
      if (line.startsWith(prefix)) {
        const filePath = line.substring(prefix.length).trim()
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
      } else if (token.startsWith("-C")) {
        gitCommitPath = token.substring(2)
        i += 1
      } else if (token === "-c") {
        i += 2
      } else if (token === "--git-dir" || token === "--work-tree" || token === "--namespace") {
        i += 2
      } else if (token.startsWith("--git-dir=") || token.startsWith("--work-tree=") || token.startsWith("--namespace=")) {
        i += 1
      } else if (token.startsWith("-")) {
        i += 1
      } else {
        if (token === "commit") {
          isCommit = true
        }
        break
      }
    }
    if (isCommit && gitCommitPath) {
      // Quoted paths containing spaces may remain a known limitation;
      // the pre-commit hook is the real commit backstop.
      const cleaned = gitCommitPath.replace(/^['"]|['"]$/g, "")
      roots.push(cleaned)
    }
  }
  return roots
}

/**
 * Checks if command contains a git commit subcommand with NO -C option.
 */
export function hasGitCommitWithoutC(command: string): boolean {
  if (typeof command !== "string") return false
  const segments = command.split(/&&|\|\||;|\||\n/)
  for (let segment of segments) {
    segment = segment.trim()
    if (!segment) continue
    const tokens = segment.split(/\s+/)
    let i = 0
    if (tokens[i] === "git") {
      i++
    } else {
      continue
    }
    let hasC = false
    let isCommit = false
    while (i < tokens.length) {
      const token = tokens[i]
      if (token === "-C") {
        hasC = true
        i += 2
      } else if (token.startsWith("-C")) {
        hasC = true
        i += 1
      } else if (token === "-c") {
        i += 2
      } else if (token === "--git-dir" || token === "--work-tree" || token === "--namespace") {
        i += 2
      } else if (token.startsWith("--git-dir=") || token.startsWith("--work-tree=") || token.startsWith("--namespace=")) {
        i += 1
      } else if (token.startsWith("-")) {
        i += 1
      } else {
        if (token === "commit") {
          isCommit = true
        }
        break
      }
    }
    if (isCommit && !hasC) {
      return true
    }
  }
  return false
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

  const isCandidate = (ancestor: string): boolean => {
    const norm = normalizePath(ancestor)
    for (const root of enrolledRoots.keys()) {
      if (norm === root || norm.startsWith(root + path.sep)) {
        return true
      }
    }
    return false
  }

  if (isAbs) {
    const ancestor = nearestExistingAncestorDir(targetPath)
    if (!isCandidate(ancestor)) {
      return { hit: false }
    }
    const toplevel = gitToplevel(ancestor)
    if (toplevel) {
      const normToplevel = normalizePath(toplevel)
      if (enrolledRoots.has(normToplevel)) {
        return { hit: true, root: normToplevel, enforce: enrolledRoots.get(normToplevel)!.enforce }
      }
    }
  } else {
    // Relative path (cwd unknown)
    // Comment regarding Phase-0 spike (bead workstation-v03j.1):
    // In opencode's pooled serve model, process.cwd() is the directory of the server process,
    // not the active session's cwd. Thus, resolving relative paths against process.cwd() is
    // highly unreliable and would result in incorrect checks. We must instead use our heuristic:
    // try to resolve the relative path against each enrolled root, apply the cheap pre-filter to
    // each joined target, and only query git toplevel for candidate matches.
    for (const [root, meta] of enrolledRoots.entries()) {
      const fullPath = path.join(root, targetPath)
      const ancestor = nearestExistingAncestorDir(fullPath)
      if (!isCandidate(ancestor)) {
        continue
      }
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
            const commitRoots = parseGitCommitRoots(command)
            if (commitRoots.length > 0) {
              targets.push(...commitRoots)
            } else {
              // Handle command with commit but no -C and workdir is set
              const workdir = output.args?.workdir
              if (typeof workdir === "string" && hasGitCommitWithoutC(command)) {
                targets.push(workdir)
              }
            }
          }
        }

        // Per-hook-invocation cache of directory to git toplevel mapping
        const dirToToplevelCache = new Map<string, string | undefined>()
        const cachedGitToplevel = (dir: string): string | undefined => {
          if (dirToToplevelCache.has(dir)) {
            return dirToToplevelCache.get(dir)
          }
          const tl = _internal.getRealGitToplevel(dir)
          dirToToplevelCache.set(dir, tl)
          return tl
        }

        for (const target of targets) {
          const classification = classify(target, enrolledRoots, cachedGitToplevel)
          if (classification.hit && classification.root) {
            const root = classification.root
            const enforce = classification.enforce
            const msg = `[worktree-guard] ${input.tool} would write into the read-only primary root ${root} (${target}). Create a fresh worktree instead: run 'work <slug>'.`
            if (enforce === "block") {
              throw new WorktreeGuardBlockError(msg)
            } else {
              // warn mode (logs once per session+root, no throw)
              const warnKey = `${input.sessionID || ""}:${root}`
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
        if (err instanceof WorktreeGuardBlockError) {
          throw err
        }
        // Otherwise, fail-open (never fail-closed)
      }
    }
  }
}

export default plugin
