# LGTM Rewrite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewrite lgtm as a thin PR discovery + OpenCode dispatch daemon for cloudbox, following the pigeon deployment pattern.

**Architecture:** Systemd timer triggers a oneshot service every 10 minutes. The service discovers PRs via `gh`, creates worktrees for context, dispatches reviews to OpenCode headless sessions via `opencode-launch`, and tracks dispatched PRs with flat marker files. Notifications come free via pigeon.

**Tech Stack:** TypeScript (ESM, tsx runner), Node.js, gh CLI, git, opencode-launch, vitest

**Reference code:** The original `food-truck/lgtm` repo is cloned at `~/projects/lgtm` -- use it as reference for `gh` query patterns and prompt engineering, but do not copy macOS-specific code.

---

### Task 1: Create GitHub Repo and Initialize TypeScript Project

**Step 1: Create the private GitHub repo**

Run:
```bash
gh repo create johnnymo87/lgtm --private --description "AI-powered PR review via OpenCode" --clone ~/projects/lgtm-new
```

**Step 2: Initialize package.json**

Create `package.json`:
```json
{
  "name": "lgtm",
  "version": "0.1.0",
  "type": "module",
  "private": true,
  "scripts": {
    "build": "tsc",
    "dev": "tsc --watch",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0"
  }
}
```

**Step 3: Initialize tsconfig.json**

Create `tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true
  },
  "include": ["src/**/*.ts"],
  "exclude": ["node_modules", "dist", "tests"]
}
```

**Step 4: Create .gitignore**

```
node_modules/
dist/
*.tsbuildinfo
```

**Step 5: Install dependencies**

Run:
```bash
cd ~/projects/lgtm-new && npm install
```

**Step 6: Commit**

```bash
git add -A && git commit -m "chore: initialize TypeScript project"
```

---

### Task 2: Types and Logging

**Files:**
- Create: `src/types.ts`
- Create: `src/log.ts`
- Test: `tests/log.test.ts`

**Step 1: Create types**

Create `src/types.ts`:
```typescript
/** A PR discovered via gh search */
export interface PrInfo {
  repo: string;     // "food-truck/repo-name"
  number: number;
  title: string;
  author: string;   // GitHub username
}

/** Detailed PR info including diff and branch */
export interface PrDetail {
  additions: number;
  deletions: number;
  changedFiles: number;
  diff: string;
  body: string;
  labels: string[];
  headRefName: string;
}

/** Configuration from environment variables */
export interface LgtmConfig {
  org: string;
  projectsDir: string;
  opencodeUrl: string;
  excludeRepos: string[];
  autoApproveAuthors: string[];
  sensitivePatterns: string[];
  customInstructions: string;
}
```

**Step 2: Create log module**

Create `src/log.ts` -- simplified from the original, writes to stderr and optionally a file:
```typescript
import { appendFileSync, mkdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const STATE_DIR = join(homedir(), ".local", "state", "lgtm");
const LOG_PATH = join(STATE_DIR, "lgtm.log");

export function log(message: string): void {
  const line = `[${new Date().toISOString()}] ${message}`;
  process.stderr.write(line + "\n");

  if (!existsSync(STATE_DIR)) {
    mkdirSync(STATE_DIR, { recursive: true });
  }
  appendFileSync(LOG_PATH, line + "\n");
}
```

**Step 3: Write a basic log test**

Create `tests/log.test.ts`:
```typescript
import { describe, it, expect } from "vitest";
// Log is side-effectful (writes to filesystem), so just verify it doesn't throw
import { log } from "../src/log.js";

describe("log", () => {
  it("does not throw", () => {
    expect(() => log("test message")).not.toThrow();
  });
});
```

**Step 4: Run test**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add types and logging"
```

---

### Task 3: State Management (Flat Files)

**Files:**
- Create: `src/state.ts`
- Test: `tests/state.test.ts`

**Step 1: Write the failing tests**

Create `tests/state.test.ts`:
```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { isDispatched, markDispatched } from "../src/state.js";

describe("state", () => {
  let stateDir: string;

  beforeEach(() => {
    stateDir = mkdtempSync(join(tmpdir(), "lgtm-test-"));
  });

  afterEach(() => {
    rmSync(stateDir, { recursive: true, force: true });
  });

  it("returns false for a PR that has not been dispatched", () => {
    expect(isDispatched(stateDir, "food-truck/my-repo", 42)).toBe(false);
  });

  it("returns true after marking a PR as dispatched", () => {
    markDispatched(stateDir, "food-truck/my-repo", 42);
    expect(isDispatched(stateDir, "food-truck/my-repo", 42)).toBe(true);
  });

  it("handles different PRs independently", () => {
    markDispatched(stateDir, "food-truck/my-repo", 42);
    expect(isDispatched(stateDir, "food-truck/my-repo", 43)).toBe(false);
    expect(isDispatched(stateDir, "food-truck/other-repo", 42)).toBe(false);
  });

  it("handles repos with slashes in the name", () => {
    markDispatched(stateDir, "food-truck/my-repo", 1);
    expect(isDispatched(stateDir, "food-truck/my-repo", 1)).toBe(true);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL with import error (module doesn't exist yet)

**Step 3: Write implementation**

Create `src/state.ts`:
```typescript
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Check if a PR has already been dispatched for review.
 * State is stored as empty marker files: <stateDir>/dispatched/<org>/<repo>/<pr-number>
 */
export function isDispatched(stateDir: string, repoFullName: string, prNumber: number): boolean {
  const markerPath = getMarkerPath(stateDir, repoFullName, prNumber);
  return existsSync(markerPath);
}

/**
 * Mark a PR as dispatched by creating a marker file.
 */
export function markDispatched(stateDir: string, repoFullName: string, prNumber: number): void {
  const markerPath = getMarkerPath(stateDir, repoFullName, prNumber);
  const dir = join(markerPath, "..");
  mkdirSync(dir, { recursive: true });
  writeFileSync(markerPath, "");
}

function getMarkerPath(stateDir: string, repoFullName: string, prNumber: number): string {
  // repoFullName is "org/repo", which naturally creates the right directory structure
  return join(stateDir, "dispatched", repoFullName, String(prNumber));
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add flat-file state management"
```

---

### Task 4: PR Discovery

**Files:**
- Create: `src/discover.ts`
- Test: `tests/discover.test.ts`

**Step 1: Write failing tests**

Create `tests/discover.test.ts`:
```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { LgtmConfig } from "../src/types.js";

// Mock child_process before importing the module
const mockExecFile = vi.fn();
vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));
vi.mock("node:util", () => ({
  promisify: (fn: Function) => (...args: any[]) =>
    new Promise((resolve, reject) => {
      fn(...args, (err: Error | null, result: any) => {
        if (err) reject(err);
        else resolve(result);
      });
    }),
}));

// Import after mocking
const { discoverPrs, getPrDetail } = await import("../src/discover.js");

const baseConfig: LgtmConfig = {
  org: "food-truck",
  projectsDir: "/home/dev/projects",
  opencodeUrl: "http://127.0.0.1:4096",
  excludeRepos: [],
  autoApproveAuthors: [],
  sensitivePatterns: [],
  customInstructions: "",
};

describe("discoverPrs", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("parses gh search output into PrInfo array", async () => {
    mockExecFile.mockImplementation((_cmd: string, _args: string[], cb: Function) => {
      cb(null, {
        stdout: JSON.stringify([
          {
            repository: { nameWithOwner: "food-truck/my-repo" },
            number: 42,
            title: "Fix the bug",
            author: { login: "alice" },
          },
        ]),
      });
    });

    const prs = await discoverPrs(baseConfig);
    expect(prs).toEqual([
      { repo: "food-truck/my-repo", number: 42, title: "Fix the bug", author: "alice" },
    ]);
  });

  it("filters out excluded repos", async () => {
    mockExecFile.mockImplementation((_cmd: string, _args: string[], cb: Function) => {
      cb(null, {
        stdout: JSON.stringify([
          {
            repository: { nameWithOwner: "food-truck/excluded" },
            number: 1,
            title: "PR in excluded repo",
            author: { login: "bob" },
          },
          {
            repository: { nameWithOwner: "food-truck/included" },
            number: 2,
            title: "PR in included repo",
            author: { login: "bob" },
          },
        ]),
      });
    });

    const config = { ...baseConfig, excludeRepos: ["food-truck/excluded"] };
    const prs = await discoverPrs(config);
    expect(prs).toHaveLength(1);
    expect(prs[0].repo).toBe("food-truck/included");
  });
});
```

**Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL (module doesn't exist)

**Step 3: Write implementation**

Create `src/discover.ts` -- adapted from the original `github.ts`:
```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { LgtmConfig, PrInfo, PrDetail } from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * Discover open PRs where the current user is requested as a reviewer.
 * Uses `gh search prs` with JSON output.
 */
export async function discoverPrs(config: LgtmConfig): Promise<PrInfo[]> {
  const { stdout } = await execFileAsync("gh", [
    "search",
    "prs",
    "user-review-requested:@me",
    "--owner",
    config.org,
    "--state",
    "open",
    "--json",
    "repository,number,title,author",
  ]);

  const raw = JSON.parse(stdout) as Array<{
    repository: { nameWithOwner: string };
    number: number;
    title: string;
    author: { login: string };
  }>;

  return raw
    .filter((pr) => !config.excludeRepos.includes(pr.repository.nameWithOwner))
    .map((pr) => ({
      repo: pr.repository.nameWithOwner,
      number: pr.number,
      title: pr.title,
      author: pr.author.login,
    }));
}

/**
 * Get detailed PR info including diff.
 * Runs `gh pr view` and `gh pr diff` in parallel.
 */
export async function getPrDetail(pr: PrInfo): Promise<PrDetail> {
  const [metaResult, diffResult] = await Promise.all([
    execFileAsync("gh", [
      "pr", "view", String(pr.number),
      "--repo", pr.repo,
      "--json", "additions,deletions,changedFiles,body,labels,headRefName",
    ]),
    execFileAsync("gh", [
      "pr", "diff", String(pr.number),
      "--repo", pr.repo,
    ]),
  ]);

  const meta = JSON.parse(metaResult.stdout);

  return {
    additions: meta.additions,
    deletions: meta.deletions,
    changedFiles: meta.changedFiles,
    diff: diffResult.stdout,
    body: meta.body ?? "",
    labels: (meta.labels ?? []).map((l: { name: string }) => l.name),
    headRefName: meta.headRefName,
  };
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add PR discovery via gh CLI"
```

---

### Task 5: Worktree Management

**Files:**
- Create: `src/worktree.ts`
- Test: `tests/worktree.test.ts`

**Step 1: Write the failing tests**

Create `tests/worktree.test.ts`:
```typescript
import { describe, it, expect } from "vitest";
import { resolveRepoPath } from "../src/worktree.js";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

describe("resolveRepoPath", () => {
  let projectsDir: string;

  beforeEach(() => {
    projectsDir = mkdtempSync(join(tmpdir(), "lgtm-worktree-test-"));
  });

  afterEach(() => {
    rmSync(projectsDir, { recursive: true, force: true });
  });

  it("finds a repo by short name", () => {
    const repoDir = join(projectsDir, "my-repo");
    mkdirSync(join(repoDir, ".git"), { recursive: true });

    expect(resolveRepoPath(projectsDir, "food-truck/my-repo")).toBe(repoDir);
  });

  it("returns null when repo is not found", () => {
    expect(resolveRepoPath(projectsDir, "food-truck/nonexistent")).toBeNull();
  });
});
```

**Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL

**Step 3: Write implementation**

Create `src/worktree.ts` -- adapted from the original, worktrees now go inside `<repo>/.worktrees/`:
```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";
import { log } from "./log.js";

const execFileAsync = promisify(execFile);

/**
 * Find the local clone path for a repo in the projects directory.
 * Checks ~/projects/<repo-name> (the cloudbox convention).
 */
export function resolveRepoPath(projectsDir: string, repoFullName: string): string | null {
  const repoName = repoFullName.split("/").pop()!;
  const candidate = join(projectsDir, repoName);

  if (existsSync(join(candidate, ".git"))) {
    return candidate;
  }

  return null;
}

/**
 * Clone a repo if it doesn't exist locally.
 */
export async function ensureRepo(
  projectsDir: string,
  repoFullName: string
): Promise<string> {
  const existing = resolveRepoPath(projectsDir, repoFullName);
  if (existing) return existing;

  const repoName = repoFullName.split("/").pop()!;
  const targetPath = join(projectsDir, repoName);

  log(`Cloning ${repoFullName} to ${targetPath}`);
  await execFileAsync("git", [
    "clone",
    `git@github.com:${repoFullName}.git`,
    targetPath,
  ], { timeout: 120_000 });

  return targetPath;
}

/**
 * Create a git worktree for a PR branch inside the repo's .worktrees/ directory.
 * Returns the worktree path, or null if setup fails.
 */
export async function createWorktree(
  repoPath: string,
  prNumber: number,
  headRefName: string
): Promise<string | null> {
  const worktreeDir = join(repoPath, ".worktrees");
  if (!existsSync(worktreeDir)) {
    mkdirSync(worktreeDir, { recursive: true });
  }
  const worktreePath = join(worktreeDir, `pr-${prNumber}`);

  try {
    // Fetch latest refs
    await execFileAsync("git", ["fetch", "origin"], {
      cwd: repoPath,
      timeout: 60_000,
    });

    // Remove stale worktree if it exists
    if (existsSync(worktreePath)) {
      await execFileAsync("git", ["worktree", "remove", worktreePath, "--force"], {
        cwd: repoPath,
        timeout: 15_000,
      }).catch(() => {});
    }

    // Create worktree detached at the PR's head
    await execFileAsync("git", [
      "worktree", "add", worktreePath,
      `origin/${headRefName}`, "--detach",
    ], {
      cwd: repoPath,
      timeout: 30_000,
    });

    log(`Created worktree at ${worktreePath} for branch ${headRefName}`);
    return worktreePath;
  } catch (err) {
    log(`Failed to create worktree for PR #${prNumber}: ${err}`);
    return null;
  }
}

/**
 * Remove a worktree.
 */
export async function removeWorktree(repoPath: string, worktreePath: string): Promise<void> {
  try {
    await execFileAsync("git", ["worktree", "remove", worktreePath, "--force"], {
      cwd: repoPath,
      timeout: 15_000,
    });
    log(`Removed worktree at ${worktreePath}`);
  } catch (err) {
    log(`Failed to remove worktree at ${worktreePath}: ${err}`);
  }
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add worktree management"
```

---

### Task 6: Prompt Construction

**Files:**
- Create: `src/prompt.ts`
- Test: `tests/prompt.test.ts`

**Step 1: Write the failing tests**

Create `tests/prompt.test.ts`:
```typescript
import { describe, it, expect } from "vitest";
import { buildPrompt } from "../src/prompt.js";
import type { PrInfo, PrDetail, LgtmConfig } from "./types.js";

const pr: PrInfo = {
  repo: "food-truck/my-repo",
  number: 42,
  title: "Fix the login bug",
  author: "alice",
};

const detail: PrDetail = {
  additions: 10,
  deletions: 5,
  changedFiles: 2,
  diff: "--- a/src/auth.ts\n+++ b/src/auth.ts\n@@ -1 +1 @@\n-old\n+new",
  body: "Fixes the login timeout issue",
  labels: ["bug"],
  headRefName: "fix-login",
};

const config: LgtmConfig = {
  org: "food-truck",
  projectsDir: "/home/dev/projects",
  opencodeUrl: "http://127.0.0.1:4096",
  excludeRepos: [],
  autoApproveAuthors: ["dependabot[bot]"],
  sensitivePatterns: ["*.env*", "*secret*"],
  customInstructions: "",
};

describe("buildPrompt", () => {
  it("includes PR metadata", () => {
    const prompt = buildPrompt(pr, detail, config);
    expect(prompt).toContain("food-truck/my-repo");
    expect(prompt).toContain("#42");
    expect(prompt).toContain("Fix the login bug");
    expect(prompt).toContain("alice");
  });

  it("includes the diff", () => {
    const prompt = buildPrompt(pr, detail, config);
    expect(prompt).toContain("--- a/src/auth.ts");
  });

  it("includes auto-approve authors when configured", () => {
    const prompt = buildPrompt(pr, detail, config);
    expect(prompt).toContain("dependabot[bot]");
  });

  it("includes sensitive patterns", () => {
    const prompt = buildPrompt(pr, detail, config);
    expect(prompt).toContain("*.env*");
  });

  it("instructs OpenCode to submit via gh pr review", () => {
    const prompt = buildPrompt(pr, detail, config);
    expect(prompt).toContain("gh pr review");
  });

  it("truncates very large diffs", () => {
    const largeDiff = "x".repeat(200_000);
    const largeDetail = { ...detail, diff: largeDiff };
    const prompt = buildPrompt(pr, largeDetail, config);
    expect(prompt.length).toBeLessThan(150_000);
    expect(prompt).toContain("truncated");
  });
});
```

**Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL

**Step 3: Write implementation**

Create `src/prompt.ts` -- the review prompt tells OpenCode to do the full review and submit via gh:
```typescript
import type { PrInfo, PrDetail, LgtmConfig } from "./types.js";

const MAX_DIFF_CHARS = 100_000;

/**
 * Build the review prompt for an OpenCode headless session.
 *
 * Unlike the original lgtm which asked for a JSON verdict,
 * this prompt tells OpenCode to do the full review and submit it.
 */
export function buildPrompt(pr: PrInfo, detail: PrDetail, config: LgtmConfig): string {
  const diff = detail.diff.length > MAX_DIFF_CHARS
    ? detail.diff.slice(0, MAX_DIFF_CHARS) + "\n\n... [diff truncated, too large for full display] ..."
    : detail.diff;

  const sensitiveNote = config.sensitivePatterns.length
    ? `\n**Sensitive file patterns** (never auto-approve changes to these): ${config.sensitivePatterns.join(", ")}`
    : "";

  const autoApproveNote = config.autoApproveAuthors.length > 0
    ? `\n**Auto-approve eligible authors:** ${config.autoApproveAuthors.join(", ")}. This PR's author is "${pr.author}".`
    : "\n**Auto-approve:** No authors are whitelisted for auto-approve.";

  const customNote = config.customInstructions
    ? `\n**Additional team instructions:** ${config.customInstructions}`
    : "";

  return `You are reviewing a pull request. You have access to the full repository checked out at the PR branch.

**Repository:** ${pr.repo}
**PR #${pr.number}:** ${pr.title}
**Author:** ${pr.author}
**Description:** ${detail.body || "(no description)"}
**Labels:** ${detail.labels.join(", ") || "(none)"}
**Branch:** ${detail.headRefName}
**Stats:** +${detail.additions} -${detail.deletions} across ${detail.changedFiles} files
${autoApproveNote}${sensitiveNote}${customNote}

All our codebases are in ~/projects/. If you need to reference another repo, check there first or clone it there.

## Your Task

1. Read the diff below carefully.
2. Explore the surrounding code in this repo for context as needed -- navigate the codebase, check related files, understand types and interfaces.
3. Form your review judgment.
4. Submit your review using \`gh pr review ${pr.number} --repo ${pr.repo}\`.

## Review Guidelines

- If changes are **trivial and safe** (docs, dependency bumps, typo fixes, formatting, config tweaks) AND the author is eligible for auto-approve, use \`--approve\` with a brief comment.
- If changes are **reasonable but non-trivial**, use \`--comment\` with a thorough review noting any concerns, suggestions, or questions. Reference specific files and lines.
- If there are **clear bugs, security issues, or significant problems**, use \`--request-changes\` with specific actionable feedback.
- NEVER auto-approve changes to authentication, authorization, encryption, data handling, or files matching sensitive patterns.

## Diff

\`\`\`diff
${diff}
\`\`\`

Review this PR thoroughly, then submit your review via \`gh pr review\`.`;
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add prompt construction"
```

---

### Task 7: OpenCode Dispatch

**Files:**
- Create: `src/dispatch.ts`
- Test: `tests/dispatch.test.ts`

**Step 1: Write the failing tests**

Create `tests/dispatch.test.ts`:
```typescript
import { describe, it, expect, vi, beforeEach } from "vitest";

const mockExecFile = vi.fn();
vi.mock("node:child_process", () => ({
  execFile: mockExecFile,
}));
vi.mock("node:util", () => ({
  promisify: (fn: Function) => (...args: any[]) =>
    new Promise((resolve, reject) => {
      fn(...args, (err: Error | null, result: any) => {
        if (err) reject(err);
        else resolve(result);
      });
    }),
}));

const { dispatch } = await import("../src/dispatch.js");

describe("dispatch", () => {
  beforeEach(() => {
    mockExecFile.mockReset();
  });

  it("calls opencode-launch with the worktree dir and prompt", async () => {
    mockExecFile.mockImplementation((_cmd: string, _args: string[], _opts: any, cb: Function) => {
      cb(null, { stdout: "Session launched: abc-123\n" });
    });

    await dispatch("/home/dev/projects/my-repo/.worktrees/pr-42", "Review this PR");

    expect(mockExecFile).toHaveBeenCalledWith(
      "opencode-launch",
      ["/home/dev/projects/my-repo/.worktrees/pr-42", "Review this PR"],
      expect.any(Object),
      expect.any(Function),
    );
  });

  it("throws on opencode-launch failure", async () => {
    mockExecFile.mockImplementation((_cmd: string, _args: string[], _opts: any, cb: Function) => {
      cb(new Error("opencode serve is not reachable"));
    });

    await expect(dispatch("/tmp/dir", "prompt")).rejects.toThrow("not reachable");
  });
});
```

**Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL

**Step 3: Write implementation**

Create `src/dispatch.ts`:
```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { log } from "./log.js";

const execFileAsync = promisify(execFile);

/**
 * Dispatch a review to OpenCode via opencode-launch.
 *
 * opencode-launch handles:
 * - Health checking opencode-serve
 * - Creating a session in the given directory
 * - Sending the prompt
 * - Pigeon integration for Telegram notifications
 */
export async function dispatch(worktreeDir: string, prompt: string): Promise<void> {
  log(`Dispatching review to OpenCode in ${worktreeDir}`);

  const { stdout } = await execFileAsync("opencode-launch", [worktreeDir, prompt], {
    timeout: 30_000,
  });

  log(`OpenCode dispatch result: ${stdout.trim()}`);
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add OpenCode dispatch via opencode-launch"
```

---

### Task 8: Main Entry Point (Orchestration)

**Files:**
- Create: `src/index.ts`
- Create: `src/config.ts`

**Step 1: Create config loader**

Create `src/config.ts` -- reads from environment variables, not a JSON file:
```typescript
import { join } from "node:path";
import { homedir } from "node:os";
import type { LgtmConfig } from "./types.js";

export const STATE_DIR = join(homedir(), ".local", "state", "lgtm");

/**
 * Load config from environment variables.
 * All config is injected via systemd Environment directives.
 */
export function loadConfig(): LgtmConfig {
  return {
    org: process.env.LGTM_ORG ?? "food-truck",
    projectsDir: process.env.LGTM_PROJECTS_DIR ?? join(homedir(), "projects"),
    opencodeUrl: process.env.OPENCODE_URL ?? "http://127.0.0.1:4096",
    excludeRepos: envList("LGTM_EXCLUDE_REPOS"),
    autoApproveAuthors: envList("LGTM_AUTO_APPROVE_AUTHORS"),
    sensitivePatterns: process.env.LGTM_SENSITIVE_PATTERNS
      ? envList("LGTM_SENSITIVE_PATTERNS")
      : ["*.env*", "*secret*", "*credential*", "*password*", "*.pem", "*.key", "*migration*"],
    customInstructions: process.env.LGTM_CUSTOM_INSTRUCTIONS ?? "",
  };
}

function envList(key: string): string[] {
  const value = process.env[key];
  if (!value) return [];
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}
```

**Step 2: Create main entry point**

Create `src/index.ts`:
```typescript
import { loadConfig, STATE_DIR } from "./config.js";
import { discoverPrs, getPrDetail } from "./discover.js";
import { isDispatched, markDispatched } from "./state.js";
import { ensureRepo, createWorktree } from "./worktree.js";
import { buildPrompt } from "./prompt.js";
import { dispatch } from "./dispatch.js";
import { log } from "./log.js";

async function main(): Promise<void> {
  const config = loadConfig();
  log(`Starting review cycle (org: ${config.org})`);

  // 1. Discover PRs
  let prs;
  try {
    prs = await discoverPrs(config);
  } catch (err) {
    log(`Failed to discover PRs: ${err}`);
    process.exitCode = 1;
    return;
  }

  log(`Found ${prs.length} open PRs requesting review`);

  // 2. Filter already-dispatched
  const newPrs = prs.filter((pr) => !isDispatched(STATE_DIR, pr.repo, pr.number));
  log(`${newPrs.length} PRs need review (${prs.length - newPrs.length} already dispatched)`);

  if (newPrs.length === 0) {
    log("Nothing to review. Done.");
    return;
  }

  // 3. Process each PR
  let dispatched = 0;
  let failed = 0;

  for (const pr of newPrs) {
    log(`Processing ${pr.repo}#${pr.number}: ${pr.title} (author: ${pr.author})`);

    try {
      // Get PR details
      const detail = await getPrDetail(pr);
      log(`  ${detail.additions + detail.deletions} lines changed across ${detail.changedFiles} files`);

      // Ensure repo is cloned
      const repoPath = await ensureRepo(config.projectsDir, pr.repo);

      // Create worktree
      const worktreePath = await createWorktree(repoPath, pr.number, detail.headRefName);
      if (!worktreePath) {
        log(`  Skipping ${pr.repo}#${pr.number}: could not create worktree`);
        failed++;
        continue;
      }

      // Build prompt and dispatch
      const prompt = buildPrompt(pr, detail, config);
      await dispatch(worktreePath, prompt);

      // Mark as dispatched
      markDispatched(STATE_DIR, pr.repo, pr.number);
      dispatched++;
      log(`  Dispatched ${pr.repo}#${pr.number} to OpenCode`);
    } catch (err) {
      log(`  Failed to process ${pr.repo}#${pr.number}: ${err}`);
      failed++;
    }
  }

  log(`Review cycle complete. Dispatched: ${dispatched}, Failed: ${failed}`);
}

main().catch((err) => {
  log(`Fatal error: ${err}`);
  process.exitCode = 1;
});
```

**Step 3: Verify it compiles**

Run: `npx tsc --noEmit`
Expected: No errors

**Step 4: Commit**

```bash
git add -A && git commit -m "feat: add main entry point and config"
```

---

### Task 9: AGENTS.md and Final Polish

**Files:**
- Create: `AGENTS.md`

**Step 1: Create AGENTS.md**

Create `AGENTS.md`:
```markdown
# LGTM

AI-powered PR review daemon. Discovers PRs via `gh`, dispatches reviews to OpenCode headless sessions.

## Quick Start

```bash
npm install
npm test
```

## Running

```bash
# Set required env vars
export LGTM_ORG=food-truck
export OPENCODE_URL=http://127.0.0.1:4096

# Run a single review cycle
npx tsx src/index.ts
```

On cloudbox, this runs as a systemd timer (configured in workstation repo).

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LGTM_ORG` | `food-truck` | GitHub org to search for PRs |
| `LGTM_PROJECTS_DIR` | `~/projects` | Where repos are cloned |
| `OPENCODE_URL` | `http://127.0.0.1:4096` | OpenCode serve endpoint |
| `LGTM_EXCLUDE_REPOS` | (none) | Comma-separated repos to skip |
| `LGTM_AUTO_APPROVE_AUTHORS` | (none) | Authors eligible for auto-approve |
| `LGTM_SENSITIVE_PATTERNS` | `*.env*,*secret*,...` | File patterns that block auto-approve |
| `LGTM_CUSTOM_INSTRUCTIONS` | (none) | Extra review instructions for the AI |

## Architecture

1. `gh search prs` discovers PRs needing review
2. Flat marker files in `~/.local/state/lgtm/dispatched/` prevent re-dispatch
3. Git worktrees at `<repo>/.worktrees/pr-<N>` give OpenCode full codebase context
4. `opencode-launch` creates a headless session that reviews and submits via `gh pr review`
5. Pigeon sends Telegram notification when the session completes
```

**Step 2: Commit**

```bash
git add -A && git commit -m "docs: add AGENTS.md"
```

---

### Task 10: Workstation Integration

**Context:** These changes are in the workstation repo at `~/projects/workstation`, not in the lgtm repo.

**Files:**
- Modify: `projects.nix`
- Modify: `hosts/cloudbox/configuration.nix`

**Step 1: Add lgtm to projects.nix**

Add to `projects.nix`:
```nix
lgtm = {
  url = "git@github.com:johnnymo87/lgtm.git";
  platforms = [ "cloudbox" ];
};
```

**Step 2: Add systemd service and timer to cloudbox config**

Add to `hosts/cloudbox/configuration.nix`:
```nix
# LGTM - AI-powered PR review
systemd.services.lgtm-run = {
  description = "LGTM PR review cycle";
  wants = [ "network-online.target" ];
  after = [ "network-online.target" "opencode-serve.service" ];
  path = [ pkgs.nodejs pkgs.git pkgs.gh pkgs.jq pkgs.coreutils pkgs.bash ];
  serviceConfig = {
    Type = "oneshot";
    User = "dev";
    Group = "dev";
    WorkingDirectory = "/home/dev/projects/lgtm";
    Environment = [
      "HOME=/home/dev"
      "LGTM_ORG=food-truck"
      "OPENCODE_URL=http://127.0.0.1:4096"
      "LGTM_PROJECTS_DIR=/home/dev/projects"
    ];
    ExecStart = "${pkgs.writeShellScript "lgtm-run" ''
      set -euo pipefail
      if [ ! -d /home/dev/projects/lgtm/node_modules ]; then
        cd /home/dev/projects/lgtm
        ${pkgs.nodejs}/bin/npm install
      fi
      exec ${pkgs.nodejs}/bin/node \
        /home/dev/projects/lgtm/node_modules/tsx/dist/cli.mjs \
        /home/dev/projects/lgtm/src/index.ts
    ''}";
  };
};

systemd.timers.lgtm-run = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "*:0/10";
    Persistent = true;
  };
};
```

**Step 3: Verify nix evaluation**

Run from workstation repo:
```bash
nix eval .#nixosConfigurations.cloudbox.config.systemd.services.lgtm-run.description
```
Expected: `"LGTM PR review cycle"`

**Step 4: Commit workstation changes**

```bash
git add projects.nix hosts/cloudbox/configuration.nix
git commit -m "feat: add lgtm systemd service and timer for cloudbox"
```

---

### Task 11: Push and Verify

**Step 1: Push lgtm repo**

```bash
cd ~/projects/lgtm-new
git push -u origin main
```

**Step 2: Push workstation changes**

```bash
cd ~/projects/workstation
git push
```

**Step 3: Apply workstation config on cloudbox**

```bash
sudo nixos-rebuild switch --flake ~/projects/workstation#cloudbox
```

**Step 4: Verify timer is active**

```bash
systemctl status lgtm-run.timer
systemctl list-timers | grep lgtm
```

**Step 5: Run manually to test**

```bash
sudo systemctl start lgtm-run.service
journalctl -u lgtm-run.service -f
```
