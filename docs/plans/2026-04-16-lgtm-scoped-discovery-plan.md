# LGTM Scoped Discovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace LGTM's single-org discovery (`LGTM_ORG`) with a multi-org, per-repo allowlist with optional monorepo path filtering (`LGTM_SCOPE`).

**Architecture:** A new `LGTM_SCOPE` env var encodes an allowlist of `org/repo` entries with optional path prefixes. Discovery loops over unique orgs, filters PRs to allowlisted repos, checks changed files against path prefixes for monorepos, and logs skipped PRs. Falls back to `LGTM_ORG` when `LGTM_SCOPE` is unset.

**Tech Stack:** TypeScript (ESM, tsx runner), vitest, gh CLI

**Design doc:** `docs/plans/2026-04-16-lgtm-scoped-discovery-design.md` in the workstation repo.

---

### Task 1: Add ScopeEntry Type and Update LgtmConfig

**Files:**
- Modify: `src/types.ts`

**Step 1: Update types.ts**

Replace the entire `src/types.ts` with:

```typescript
/** A PR discovered via gh search */
export interface PrInfo {
  repo: string;      // "org/repo-name"
  number: number;
  title: string;
  author: string;    // GitHub username
}

/** Detailed PR info (metadata only -- diff is fetched by the agent itself) */
export interface PrDetail {
  additions: number;
  deletions: number;
  changedFiles: number;
  body: string;
  labels: string[];
  headRefName: string;
  files: string[];   // List of changed file paths
}

/** A repo in the review scope, with optional path filtering for monorepos */
export interface ScopeEntry {
  repo: string;                    // "org/repo"
  pathPrefixes: string[] | null;   // null = whole repo, array = only these path prefixes
}

/** Configuration from environment variables */
export interface LgtmConfig {
  scope: ScopeEntry[];
  projectsDir: string;
  stateDir: string;
  autoApproveAuthors: string[];
  sensitivePatterns: string[];
}

/** Review outcome record */
export interface OutcomeRecord {
  repo: string;
  prNumber: number;
  title: string;
  author: string;
  dispatchedAt: string;        // ISO timestamp
  contextPacketChars: number;
  // Filled in by outcome checker on subsequent runs:
  reviewPosted?: boolean;
  verdict?: string;            // approve | comment | request-changes
  commentCount?: number;
  prUpdatedAfterReview?: boolean;
  reviewDismissed?: boolean;
  checkedAt?: string;          // ISO timestamp
}
```

**Step 2: Run tests to see what breaks**

Run: `npm test`
Expected: FAIL -- config.test.ts and anything referencing `config.org` will break. That's expected; we fix them in subsequent tasks.

**Step 3: Commit**

```bash
git add src/types.ts
git commit -m "refactor: replace org with scope in LgtmConfig type

Add ScopeEntry for per-repo allowlist with optional path prefixes.
Intentionally breaks downstream code -- fixed in subsequent commits."
```

---

### Task 2: Update Config Parser with Scope Parsing

**Files:**
- Modify: `src/config.ts`
- Modify: `tests/config.test.ts`

**Step 1: Write the failing tests**

Replace `tests/config.test.ts` with:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadConfig, parseScope } from "../src/config.js";
import { join } from "node:path";

describe("parseScope", () => {
  it("parses a single whole-repo entry", () => {
    const result = parseScope("org/repo");
    expect(result).toEqual([{ repo: "org/repo", pathPrefixes: null }]);
  });

  it("parses a single repo with path prefixes", () => {
    const result = parseScope("org/mono:src/app,src/lib");
    expect(result).toEqual([
      { repo: "org/mono", pathPrefixes: ["src/app", "src/lib"] },
    ]);
  });

  it("parses multiple entries separated by semicolons", () => {
    const result = parseScope("org/mono:src/app;other/repo");
    expect(result).toEqual([
      { repo: "org/mono", pathPrefixes: ["src/app"] },
      { repo: "other/repo", pathPrefixes: null },
    ]);
  });

  it("trims whitespace from repos and paths", () => {
    const result = parseScope(" org/mono : src/app , src/lib ; other/repo ");
    expect(result).toEqual([
      { repo: "org/mono", pathPrefixes: ["src/app", "src/lib"] },
      { repo: "other/repo", pathPrefixes: null },
    ]);
  });

  it("ignores empty entries from trailing semicolons", () => {
    const result = parseScope("org/repo;");
    expect(result).toEqual([{ repo: "org/repo", pathPrefixes: null }]);
  });

  it("returns empty array for empty string", () => {
    expect(parseScope("")).toEqual([]);
  });
});

describe("loadConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("uses LGTM_SCOPE when set", () => {
    process.env.LGTM_SCOPE = "org/mono:src/app;other/repo";
    delete process.env.LGTM_ORG;
    const config = loadConfig();
    expect(config.scope).toEqual([
      { repo: "org/mono", pathPrefixes: ["src/app"] },
      { repo: "other/repo", pathPrefixes: null },
    ]);
  });

  it("falls back to LGTM_ORG when LGTM_SCOPE is unset", () => {
    delete process.env.LGTM_SCOPE;
    process.env.LGTM_ORG = "my-org";
    const config = loadConfig();
    // Fallback: single scope entry with just the org as owner, all repos
    expect(config.scope).toEqual([{ repo: "my-org/*", pathPrefixes: null }]);
  });

  it("defaults to acme/* when neither LGTM_SCOPE nor LGTM_ORG is set", () => {
    delete process.env.LGTM_SCOPE;
    delete process.env.LGTM_ORG;
    const config = loadConfig();
    expect(config.scope).toEqual([{ repo: "acme/*", pathPrefixes: null }]);
  });

  it("parses comma-separated auto approve authors", () => {
    process.env.LGTM_AUTO_APPROVE_AUTHORS = "dependabot[bot],renovate[bot]";
    const config = loadConfig();
    expect(config.autoApproveAuthors).toEqual(["dependabot[bot]", "renovate[bot]"]);
  });

  it("trims whitespace and ignores empty entries in comma-separated env lists", () => {
    process.env.LGTM_AUTO_APPROVE_AUTHORS = " dependabot[bot] , renovate[bot], ";
    const config = loadConfig();
    expect(config.autoApproveAuthors).toEqual(["dependabot[bot]", "renovate[bot]"]);
  });

  it("uses default sensitive patterns when env var is unset", () => {
    delete process.env.LGTM_SENSITIVE_PATTERNS;
    const config = loadConfig();
    expect(config.sensitivePatterns).toContain("*.env*");
  });

  it("reads projectsDir and stateDir defaults", () => {
    delete process.env.LGTM_PROJECTS_DIR;
    delete process.env.LGTM_STATE_DIR;
    const config = loadConfig();
    expect(config.projectsDir.endsWith(join("projects"))).toBe(true);
    expect(config.stateDir.endsWith(join(".local", "state", "lgtm"))).toBe(true);
  });
});
```

**Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL -- `parseScope` not exported, `config.org` removed.

**Step 3: Update config.ts**

Replace `src/config.ts` with:

```typescript
import { join } from "node:path";
import { homedir } from "node:os";
import type { LgtmConfig, ScopeEntry } from "./types.js";

/**
 * Load config from environment variables.
 * All config is injected via systemd Environment directives.
 */
export function loadConfig(): LgtmConfig {
  return {
    scope: loadScope(),
    projectsDir: process.env.LGTM_PROJECTS_DIR ?? join(homedir(), "projects"),
    stateDir: process.env.LGTM_STATE_DIR ?? join(homedir(), ".local", "state", "lgtm"),
    autoApproveAuthors: envList("LGTM_AUTO_APPROVE_AUTHORS"),
    sensitivePatterns: process.env.LGTM_SENSITIVE_PATTERNS
      ? envList("LGTM_SENSITIVE_PATTERNS")
      : ["*.env*", "*secret*", "*credential*", "*password*", "*.pem", "*.key", "*migration*"],
  };
}

/**
 * Load scope from LGTM_SCOPE, falling back to LGTM_ORG for backward compat.
 */
function loadScope(): ScopeEntry[] {
  const scopeStr = process.env.LGTM_SCOPE;
  if (scopeStr) return parseScope(scopeStr);

  // Fallback: LGTM_ORG means "all repos in this org"
  const org = process.env.LGTM_ORG ?? "acme";
  return [{ repo: `${org}/*`, pathPrefixes: null }];
}

/**
 * Parse LGTM_SCOPE env var into ScopeEntry array.
 *
 * Syntax: "org/repo:path1,path2;org/repo2"
 * - Semicolon separates repo entries
 * - Colon separates repo from path prefixes
 * - Comma separates path prefixes
 * - No colon = whole repo (pathPrefixes: null)
 *
 * Exported for testing.
 */
export function parseScope(raw: string): ScopeEntry[] {
  if (!raw.trim()) return [];

  return raw
    .split(";")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const colonIdx = entry.indexOf(":");
      if (colonIdx === -1) {
        return { repo: entry.trim(), pathPrefixes: null };
      }
      const repo = entry.slice(0, colonIdx).trim();
      const paths = entry
        .slice(colonIdx + 1)
        .split(",")
        .map((p) => p.trim())
        .filter(Boolean);
      return { repo, pathPrefixes: paths.length > 0 ? paths : null };
    });
}

function envList(key: string): string[] {
  const value = process.env[key];
  if (!value) return [];
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: config tests PASS, other tests still FAIL (discover, prompt reference `config.org`).

**Step 5: Commit**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat: add LGTM_SCOPE env var parsing with LGTM_ORG fallback

Syntax: org/repo:path1,path2;org/repo2
Falls back to LGTM_ORG (all repos in org) when LGTM_SCOPE is unset."
```

---

### Task 3: Update Discovery for Multi-Org + Scope Filtering

**Files:**
- Modify: `src/discover.ts`
- Modify: `tests/discover.test.ts`

**Step 1: Write the failing tests**

Replace `tests/discover.test.ts` with:

```typescript
import { describe, it, expect } from "vitest";
import {
  parsePrSearchResult,
  parsePrDetail,
  filterByScope,
  deriveOrgs,
} from "../src/discover.js";
import type { ScopeEntry, PrInfo } from "../src/types.js";

describe("parsePrSearchResult", () => {
  it("parses gh search JSON into PrInfo array", () => {
    const raw = [
      {
        repository: { nameWithOwner: "org/repo" },
        number: 42,
        title: "Fix the bug",
        author: { login: "alice" },
      },
    ];
    const result = parsePrSearchResult(raw);
    expect(result).toEqual([
      { repo: "org/repo", number: 42, title: "Fix the bug", author: "alice" },
    ]);
  });
});

describe("parsePrDetail", () => {
  it("parses gh pr view JSON into PrDetail (no diff)", () => {
    const meta = {
      additions: 10,
      deletions: 5,
      changedFiles: 2,
      body: "Fix description",
      labels: [{ name: "bug" }],
      headRefName: "fix-branch",
      files: [{ path: "src/auth.ts" }, { path: "tests/auth.test.ts" }],
    };
    const result = parsePrDetail(meta);
    expect(result.additions).toBe(10);
    expect(result.files).toEqual(["src/auth.ts", "tests/auth.test.ts"]);
    expect(result.headRefName).toBe("fix-branch");
    expect(result.body).toBe("Fix description");
    expect(result.labels).toEqual(["bug"]);
  });

  it("falls back to empty body when missing", () => {
    const result = parsePrDetail({
      additions: 1,
      deletions: 0,
      changedFiles: 1,
      headRefName: "x",
    });
    expect(result.body).toBe("");
    expect(result.labels).toEqual([]);
    expect(result.files).toEqual([]);
  });
});

describe("deriveOrgs", () => {
  it("extracts unique orgs from scope entries", () => {
    const scope: ScopeEntry[] = [
      { repo: "acme/mono", pathPrefixes: ["src"] },
      { repo: "acme/other", pathPrefixes: null },
      { repo: "globex/server", pathPrefixes: null },
    ];
    expect(deriveOrgs(scope)).toEqual(["acme", "globex"]);
  });

  it("handles wildcard entries from LGTM_ORG fallback", () => {
    const scope: ScopeEntry[] = [{ repo: "my-org/*", pathPrefixes: null }];
    expect(deriveOrgs(scope)).toEqual(["my-org"]);
  });
});

describe("filterByScope", () => {
  const scope: ScopeEntry[] = [
    { repo: "org/mono", pathPrefixes: ["wonder/app", "wonder/lib"] },
    { repo: "org/api", pathPrefixes: null },
  ];

  it("keeps PRs from whole-repo scope entries", () => {
    const pr: PrInfo = { repo: "org/api", number: 1, title: "X", author: "a" };
    const result = filterByScope([pr], scope, new Map());
    expect(result.included).toEqual([pr]);
    expect(result.excluded).toEqual([]);
  });

  it("keeps PRs from path-scoped repos when files match", () => {
    const pr: PrInfo = { repo: "org/mono", number: 2, title: "Y", author: "b" };
    const filesMap = new Map([["org/mono#2", ["wonder/app/index.ts", "README.md"]]]);
    const result = filterByScope([pr], scope, filesMap);
    expect(result.included).toEqual([pr]);
  });

  it("excludes PRs from path-scoped repos when no files match", () => {
    const pr: PrInfo = { repo: "org/mono", number: 3, title: "Z", author: "c" };
    const filesMap = new Map([["org/mono#3", [".gitmodules", "other/thing.ts"]]]);
    const result = filterByScope([pr], scope, filesMap);
    expect(result.excluded).toEqual([{ pr, reason: "no matching path filter" }]);
    expect(result.included).toEqual([]);
  });

  it("excludes PRs from repos not in scope", () => {
    const pr: PrInfo = { repo: "org/unknown", number: 4, title: "W", author: "d" };
    const result = filterByScope([pr], scope, new Map());
    expect(result.excluded).toEqual([{ pr, reason: "not in scope" }]);
  });

  it("handles wildcard scope (LGTM_ORG fallback)", () => {
    const wildcardScope: ScopeEntry[] = [{ repo: "org/*", pathPrefixes: null }];
    const pr: PrInfo = { repo: "org/anything", number: 5, title: "V", author: "e" };
    const result = filterByScope([pr], wildcardScope, new Map());
    expect(result.included).toEqual([pr]);
  });

  it("wildcard scope does not match other orgs", () => {
    const wildcardScope: ScopeEntry[] = [{ repo: "org/*", pathPrefixes: null }];
    const pr: PrInfo = { repo: "other/repo", number: 6, title: "U", author: "f" };
    const result = filterByScope([pr], wildcardScope, new Map());
    expect(result.excluded).toEqual([{ pr, reason: "not in scope" }]);
  });
});
```

**Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL -- `filterByScope` and `deriveOrgs` not exported.

**Step 3: Update discover.ts**

Replace `src/discover.ts` with:

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { log } from "./log.js";
import type { LgtmConfig, PrInfo, PrDetail, ScopeEntry } from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * Discover open PRs where the current user is requested as a reviewer,
 * filtered to the configured scope (repo allowlist + path prefixes).
 */
export async function discoverPrs(config: LgtmConfig): Promise<PrInfo[]> {
  const orgs = deriveOrgs(config.scope);
  const allPrs: PrInfo[] = [];

  for (const org of orgs) {
    log(`Searching ${org} for PRs requesting review...`);
    const { stdout } = await execFileAsync("gh", [
      "search", "prs",
      "user-review-requested:@me",
      "--owner", org,
      "--state", "open",
      "--json", "repository,number,title,author",
    ]);

    const raw = JSON.parse(stdout);
    allPrs.push(...parsePrSearchResult(raw));
  }

  // For path-scoped repos, fetch changed files to check path filters
  const pathScopedRepos = new Set(
    config.scope
      .filter((s) => s.pathPrefixes !== null)
      .map((s) => s.repo),
  );
  const filesMap = new Map<string, string[]>();

  for (const pr of allPrs) {
    if (pathScopedRepos.has(pr.repo)) {
      const key = `${pr.repo}#${pr.number}`;
      try {
        const { stdout } = await execFileAsync("gh", [
          "pr", "view", String(pr.number),
          "--repo", pr.repo,
          "--json", "files",
        ]);
        const parsed = JSON.parse(stdout);
        filesMap.set(key, (parsed.files ?? []).map((f: { path: string }) => f.path));
      } catch {
        // If we can't fetch files, include the PR (fail open for scope check)
        log(`  Warning: could not fetch files for ${key}, including in scope`);
      }
    }
  }

  // Apply scope filter
  const { included, excluded } = filterByScope(allPrs, config.scope, filesMap);

  for (const { pr, reason } of excluded) {
    log(`Skipping ${pr.repo}#${pr.number}: ${reason}`);
  }

  return included;
}

/**
 * Derive unique org names from scope entries. Exported for testing.
 */
export function deriveOrgs(scope: ScopeEntry[]): string[] {
  const orgs = new Set<string>();
  for (const entry of scope) {
    const org = entry.repo.split("/")[0];
    orgs.add(org);
  }
  return [...orgs];
}

/**
 * Filter PRs by scope rules. Exported for testing.
 *
 * @param prs - All discovered PRs
 * @param scope - Configured scope entries
 * @param filesMap - Map of "org/repo#N" -> changed file paths (for path-scoped repos)
 */
export function filterByScope(
  prs: PrInfo[],
  scope: ScopeEntry[],
  filesMap: Map<string, string[]>,
): { included: PrInfo[]; excluded: Array<{ pr: PrInfo; reason: string }> } {
  const included: PrInfo[] = [];
  const excluded: Array<{ pr: PrInfo; reason: string }> = [];

  for (const pr of prs) {
    const entry = findScopeEntry(pr.repo, scope);

    if (!entry) {
      excluded.push({ pr, reason: "not in scope" });
      continue;
    }

    // Whole-repo entry (no path filter)
    if (entry.pathPrefixes === null) {
      included.push(pr);
      continue;
    }

    // Path-scoped entry: check changed files
    const key = `${pr.repo}#${pr.number}`;
    const files = filesMap.get(key);

    if (!files) {
      // No file info available -- include to fail open
      included.push(pr);
      continue;
    }

    const hasMatch = files.some((file) =>
      entry.pathPrefixes!.some((prefix) => file.startsWith(prefix)),
    );

    if (hasMatch) {
      included.push(pr);
    } else {
      excluded.push({ pr, reason: "no matching path filter" });
    }
  }

  return { included, excluded };
}

/**
 * Find the scope entry that matches a given repo.
 * Supports wildcard entries like "org/*" (from LGTM_ORG fallback).
 */
function findScopeEntry(repo: string, scope: ScopeEntry[]): ScopeEntry | null {
  // Exact match first
  for (const entry of scope) {
    if (entry.repo === repo) return entry;
  }

  // Wildcard match (org/*)
  const org = repo.split("/")[0];
  for (const entry of scope) {
    if (entry.repo === `${org}/*`) return entry;
  }

  return null;
}

/**
 * Parse gh search output into PrInfo array. Exported for testing.
 */
export function parsePrSearchResult(
  raw: Array<{ repository: { nameWithOwner: string }; number: number; title: string; author: { login: string } }>,
): PrInfo[] {
  return raw.map((pr) => ({
    repo: pr.repository.nameWithOwner,
    number: pr.number,
    title: pr.title,
    author: pr.author.login,
  }));
}

/**
 * Get detailed PR info (metadata only -- the agent fetches the diff itself).
 */
export async function getPrDetail(pr: PrInfo): Promise<PrDetail> {
  const { stdout } = await execFileAsync("gh", [
    "pr", "view", String(pr.number),
    "--repo", pr.repo,
    "--json", "additions,deletions,changedFiles,body,labels,headRefName,files",
  ]);

  const meta = JSON.parse(stdout);
  return parsePrDetail(meta);
}

/**
 * Parse gh pr view JSON into PrDetail. Exported for testing.
 */
export function parsePrDetail(
  meta: {
    additions: number;
    deletions: number;
    changedFiles: number;
    body?: string;
    labels?: Array<{ name: string }>;
    headRefName: string;
    files?: Array<{ path: string }>;
  },
): PrDetail {
  return {
    additions: meta.additions,
    deletions: meta.deletions,
    changedFiles: meta.changedFiles,
    body: meta.body ?? "",
    labels: (meta.labels ?? []).map((l) => l.name),
    headRefName: meta.headRefName,
    files: (meta.files ?? []).map((f) => f.path),
  };
}
```

**Step 4: Run tests**

Run: `npm test`
Expected: config + discover tests PASS. Other tests may still fail if they reference `config.org`.

**Step 5: Commit**

```bash
git add src/discover.ts tests/discover.test.ts
git commit -m "feat: multi-org discovery with repo allowlist and path filtering

Discovery now loops over orgs derived from LGTM_SCOPE, filters PRs to
allowlisted repos, and checks changed files against path prefixes for
monorepos. Skipped PRs are logged to stderr."
```

---

### Task 4: Update Index and Prompt for New Config Shape

**Files:**
- Modify: `src/index.ts`
- Modify: `src/prompt.ts`

**Step 1: Update prompt.ts**

In `src/prompt.ts`, the function `buildReviewPrompt` takes `config: LgtmConfig` but only uses `config.autoApproveAuthors` and `config.sensitivePatterns` -- it never references `config.org`. Verify this by reading the file. If it does reference `config.org`, remove that reference.

The current `prompt.ts` does NOT reference `config.org`, so no change is needed to prompt.ts.

**Step 2: Update index.ts**

In `src/index.ts`, the log line at line 15 says `log(\`Starting review cycle (org: ${config.org})\`)`. Update this to reference scope:

Replace line 15:
```typescript
  log(`Starting review cycle (org: ${config.org})`);
```
with:
```typescript
  const scopeSummary = config.scope.map((s) => s.repo).join(", ");
  log(`Starting review cycle (scope: ${scopeSummary})`);
```

**Step 3: Run tests**

Run: `npm test`
Expected: All tests PASS. (index.ts has no unit tests; it's the orchestrator.)

**Step 4: Verify TypeScript compiles**

Run: `npx tsc --noEmit`
Expected: No errors.

**Step 5: Commit**

```bash
git add src/index.ts src/prompt.ts
git commit -m "refactor: update orchestrator for scope-based config

Replace config.org log line with scope summary."
```

---

### Task 5: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

**Step 1: Update environment variable docs**

In `AGENTS.md`, replace the environment variables table. Change:

```markdown
| `LGTM_ORG` | `acme` | GitHub org to search for PRs |
```

to:

```markdown
| `LGTM_SCOPE` | (none) | Repo allowlist: `org/repo:path1,path2;org/repo2` |
| `LGTM_ORG` | `acme` | Fallback: single org, all repos (deprecated) |
```

Also update the "Running" example from:
```bash
export LGTM_ORG=acme
```
to:
```bash
export LGTM_SCOPE="acme/mono:wonder/app;globex/server"
```

**Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md for LGTM_SCOPE env var"
```

---

### Task 6: Update Systemd Configuration

This task is in the **workstation** repo, not the lgtm repo.

**Files:**
- Modify: `/home/dev/projects/workstation/hosts/cloudbox/configuration.nix` (line 319)

**Step 1: Replace LGTM_ORG with LGTM_SCOPE**

In `configuration.nix`, in the lgtm-run service Environment block (around line 317-322), replace:

```nix
        "LGTM_ORG=acme"
```

with:

```nix
        "LGTM_SCOPE=acme/mono:apps/catalog,apps/storefront,apps/data/streaming,apps/data/legacy-streaming,apps/data/wiki;globex/ops-server"
```

**Step 2: Verify nix evaluation**

Run from workstation repo:
```bash
nix eval .#nixosConfigurations.cloudbox.config.system.stateVersion
```
Expected: No evaluation errors (lgtm is gated behind `enableLgtm = false`).

**Step 3: Commit (workstation repo)**

```bash
cd ~/projects/workstation
git add hosts/cloudbox/configuration.nix
git commit -m "feat: configure LGTM_SCOPE for scoped PR discovery

Replace LGTM_ORG=acme with LGTM_SCOPE covering:
- acme/mono (5 path prefixes)
- globex/ops-server (whole repo)"
```

---

### Task 7: Push and Verify

**Step 1: Run all tests in lgtm repo**

```bash
cd ~/projects/lgtm
npm test
```
Expected: All tests pass.

**Step 2: Verify TypeScript compiles**

```bash
npx tsc --noEmit
```
Expected: No errors.

**Step 3: Push lgtm changes**

```bash
cd ~/projects/lgtm
git push
```

**Step 4: Push workstation changes**

```bash
cd ~/projects/workstation
git push
```

**Step 5: Verify both repos are clean**

```bash
cd ~/projects/lgtm && git status
cd ~/projects/workstation && git status
```
Expected: Both show clean working trees, up to date with origin.
