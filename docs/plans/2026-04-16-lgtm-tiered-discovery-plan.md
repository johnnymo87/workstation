# LGTM Tiered Discovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.
>
> **POST-COMPACTION RESUMPTION CONTEXT:**
> - Beads issue: `lgtm-89q` (P1)
> - Design doc: `workstation/docs/plans/2026-04-16-lgtm-tiered-discovery-design.md`
> - Previous superseded design: `workstation/docs/plans/2026-04-16-lgtm-scoped-discovery-design.md` (env-var based, already implemented and shipped)
> - The codebase ALREADY has: `ScopeEntry` type, `LGTM_SCOPE` env parsing, `parseScope`/`filterByScope`/`deriveOrgs` functions, repo+path filtering. This plan REPLACES the config layer (env var -> YAML) and EXTENDS discovery (single-tier -> two-tier).
> - User wants subagent-driven execution (in-session, fresh subagent per task, spec review after each)
> - Branch: `v2` in lgtm repo (johnnymo87/lgtm), `main` in workstation
> - LGTM is currently DISABLED in production (`enableLgtm = false` in cloudbox configuration.nix). Do NOT enable it as part of this work.
> - Key user decisions from brainstorming:
>   - Tier 1 = review-requested (always on, any author)
>   - Tier 2 authors: alice, bob, charlie, dave, erin, frank, grace, dependabot[bot]
>   - Tier 2 repos: see lgtm.yml in Task 1
>   - YAML over env vars (env var soup was getting unreadable)
>   - Skip drafts, skip self-authored, skip already-approved
> - Verification: `npm test` should show all tests passing after each task. Currently 42 tests pass at HEAD (commit `6329024` on lgtm v2).

**Goal:** Replace LGTM's env-var-based scope with a YAML config file and add tiered PR discovery (tier 1: review-requested, tier 2: author + repo/path allowlist with draft/self/approval filters).

**Architecture:** A `lgtm.yml` file in the repo root defines the author allowlist and repo scope. Discovery runs in two tiers: tier 1 finds PRs where the user is explicitly requested as reviewer, tier 2 finds all open PRs matching the author + repo/path allowlist. Both tiers merge results, deduplicate via dispatched markers, and filter drafts, self-authored, and already-approved PRs.

**Tech Stack:** TypeScript (ESM, tsx runner), vitest, js-yaml, gh CLI

**Design doc:** `docs/plans/2026-04-16-lgtm-tiered-discovery-design.md` in the workstation repo.

**Current state:** The codebase already has `ScopeEntry` type, `LGTM_SCOPE` env var parsing, repo allowlist + path filtering, and `deriveOrgs`/`filterByScope` functions. This plan replaces the config layer and extends the discovery layer.

---

### Task 1: Add js-yaml Dependency and Create lgtm.yml

**Files:**
- Modify: `package.json`
- Create: `lgtm.yml`

**Step 1: Install js-yaml**

Run:
```bash
npm install js-yaml
npm install -D @types/js-yaml
```

**Step 2: Create lgtm.yml**

Create `lgtm.yml` in the repo root:

```yaml
authors:
  - alice
  - bob
  - charlie
  - dave
  - erin
  - frank
  - grace
  - dependabot[bot]

repos:
  acme/mono:
    paths:
      - apps/catalog
      - apps/storefront
      - apps/data/streaming
      - apps/data/legacy-streaming
      - apps/data/wiki

  acme/protos:
    paths:
      - proto/services/supplychain
      - proto/services/catalog
      - proto/services/storefront

  acme/data_warehouse:
    paths:
      - dbt_warehouse/models/supply_catalog

  acme/wiki: {}

  globex/ops-server: {}
  globex/internal-ui: {}
  globex/chef: {}
```

**Step 3: Commit**

```bash
git add package.json package-lock.json lgtm.yml
git commit -m "chore: add js-yaml dependency and create lgtm.yml config

YAML config replaces LGTM_SCOPE/LGTM_ORG env vars.
Defines author allowlist and repo scope with path prefixes."
```

---

### Task 2: Update Types and Config for YAML Loading

**Files:**
- Modify: `src/types.ts`
- Modify: `src/config.ts`
- Modify: `tests/config.test.ts`

**Step 1: Update types.ts**

Add `authors` to `LgtmConfig`. Replace the file with:

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

/** Configuration loaded from lgtm.yml + environment variables */
export interface LgtmConfig {
  scope: ScopeEntry[];
  authors: string[];               // tier 2 author allowlist
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

**Step 2: Write the config tests**

Replace `tests/config.test.ts` with:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadConfig, loadScopeFile } from "../src/config.js";
import { join } from "node:path";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

describe("loadScopeFile", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "lgtm-config-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("parses a YAML config with authors and repos", () => {
    const yml = `
authors:
  - alice
  - bob

repos:
  org/mono:
    paths:
      - src/app
      - src/lib
  org/api: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    const result = loadScopeFile(configPath);
    expect(result.authors).toEqual(["alice", "bob"]);
    expect(result.scope).toEqual([
      { repo: "org/mono", pathPrefixes: ["src/app", "src/lib"] },
      { repo: "org/api", pathPrefixes: null },
    ]);
  });

  it("handles repos with no paths (null object)", () => {
    const yml = `
authors: []
repos:
  org/repo: null
  org/other: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    const result = loadScopeFile(configPath);
    expect(result.scope).toEqual([
      { repo: "org/repo", pathPrefixes: null },
      { repo: "org/other", pathPrefixes: null },
    ]);
  });

  it("handles empty authors list", () => {
    const yml = `
authors: []
repos:
  org/repo: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    const result = loadScopeFile(configPath);
    expect(result.authors).toEqual([]);
  });

  it("throws on missing file", () => {
    expect(() => loadScopeFile(join(tmpDir, "nonexistent.yml"))).toThrow();
  });
});

describe("loadConfig", () => {
  const originalEnv = process.env;
  let tmpDir: string;

  beforeEach(() => {
    process.env = { ...originalEnv };
    tmpDir = mkdtempSync(join(tmpdir(), "lgtm-config-test-"));
  });

  afterEach(() => {
    process.env = originalEnv;
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("loads scope from LGTM_CONFIG path", () => {
    const yml = `
authors:
  - alice
repos:
  org/repo: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    process.env.LGTM_CONFIG = configPath;
    const config = loadConfig();
    expect(config.authors).toEqual(["alice"]);
    expect(config.scope).toEqual([{ repo: "org/repo", pathPrefixes: null }]);
  });

  it("parses comma-separated auto approve authors", () => {
    const yml = `
authors: []
repos:
  org/repo: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    process.env.LGTM_CONFIG = configPath;
    process.env.LGTM_AUTO_APPROVE_AUTHORS = "dependabot[bot],renovate[bot]";
    const config = loadConfig();
    expect(config.autoApproveAuthors).toEqual(["dependabot[bot]", "renovate[bot]"]);
  });

  it("uses default sensitive patterns when env var is unset", () => {
    const yml = `
authors: []
repos:
  org/repo: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    process.env.LGTM_CONFIG = configPath;
    delete process.env.LGTM_SENSITIVE_PATTERNS;
    const config = loadConfig();
    expect(config.sensitivePatterns).toContain("*.env*");
  });

  it("reads projectsDir and stateDir from env or defaults", () => {
    const yml = `
authors: []
repos:
  org/repo: {}
`;
    const configPath = join(tmpDir, "lgtm.yml");
    writeFileSync(configPath, yml);
    process.env.LGTM_CONFIG = configPath;
    delete process.env.LGTM_PROJECTS_DIR;
    delete process.env.LGTM_STATE_DIR;
    const config = loadConfig();
    expect(config.projectsDir.endsWith(join("projects"))).toBe(true);
    expect(config.stateDir.endsWith(join(".local", "state", "lgtm"))).toBe(true);
  });
});
```

**Step 3: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL -- `loadScopeFile` not exported.

**Step 4: Rewrite config.ts**

Replace `src/config.ts` with:

```typescript
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { load as loadYaml } from "js-yaml";
import type { LgtmConfig, ScopeEntry } from "./types.js";

/**
 * Load config from lgtm.yml + environment variables.
 *
 * Scope (repos, paths, authors) comes from lgtm.yml.
 * Operational settings (projectsDir, stateDir, etc.) come from env vars.
 */
export function loadConfig(): LgtmConfig {
  const configPath = process.env.LGTM_CONFIG ?? join(process.cwd(), "lgtm.yml");
  const { scope, authors } = loadScopeFile(configPath);

  return {
    scope,
    authors,
    projectsDir: process.env.LGTM_PROJECTS_DIR ?? join(homedir(), "projects"),
    stateDir: process.env.LGTM_STATE_DIR ?? join(homedir(), ".local", "state", "lgtm"),
    autoApproveAuthors: envList("LGTM_AUTO_APPROVE_AUTHORS"),
    sensitivePatterns: process.env.LGTM_SENSITIVE_PATTERNS
      ? envList("LGTM_SENSITIVE_PATTERNS")
      : ["*.env*", "*secret*", "*credential*", "*password*", "*.pem", "*.key", "*migration*"],
  };
}

/**
 * Load scope and authors from a YAML config file.
 * Exported for testing.
 */
export function loadScopeFile(configPath: string): { scope: ScopeEntry[]; authors: string[] } {
  const raw = readFileSync(configPath, "utf-8");
  const doc = loadYaml(raw) as {
    authors?: string[];
    repos?: Record<string, { paths?: string[] } | null>;
  };

  const authors = doc.authors ?? [];
  const scope: ScopeEntry[] = [];

  if (doc.repos) {
    for (const [repo, config] of Object.entries(doc.repos)) {
      const paths = config?.paths ?? null;
      scope.push({
        repo,
        pathPrefixes: paths && paths.length > 0 ? paths : null,
      });
    }
  }

  return { scope, authors };
}

function envList(key: string): string[] {
  const value = process.env[key];
  if (!value) return [];
  return value.split(",").map((s) => s.trim()).filter(Boolean);
}
```

**Step 5: Run tests**

Run: `npm test`
Expected: config tests PASS. Discover tests should still pass (they don't use config directly).

**Step 6: Commit**

```bash
git add src/types.ts src/config.ts tests/config.test.ts
git commit -m "feat: replace LGTM_SCOPE env var with YAML config file

Load scope (repos, paths) and author allowlist from lgtm.yml.
Env vars remain for operational settings (projectsDir, stateDir, etc.).
Removes parseScope and LGTM_SCOPE/LGTM_ORG support."
```

---

### Task 3: Tiered Discovery with Author/Draft/Self/Approval Filters

This is the core task. Discovery becomes two-pass: tier 1 (review-requested) and tier 2 (broad + filters).

**Files:**
- Modify: `src/discover.ts`
- Modify: `tests/discover.test.ts`

**Step 1: Write the new tests**

Replace `tests/discover.test.ts` with:

```typescript
import { describe, it, expect } from "vitest";
import {
  parsePrSearchResult,
  parsePrDetail,
  filterByScope,
  filterByAuthors,
  filterDraftsAndSelf,
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
  });

  it("falls back to empty body when missing", () => {
    const result = parsePrDetail({
      additions: 1, deletions: 0, changedFiles: 1, headRefName: "x",
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

  it("handles wildcard entries", () => {
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
  });

  it("excludes PRs from repos not in scope", () => {
    const pr: PrInfo = { repo: "org/unknown", number: 4, title: "W", author: "d" };
    const result = filterByScope([pr], scope, new Map());
    expect(result.excluded).toEqual([{ pr, reason: "not in scope" }]);
  });

  it("handles wildcard scope", () => {
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

describe("filterDraftsAndSelf", () => {
  it("excludes draft PRs", () => {
    const prs: PrInfo[] = [
      { repo: "org/repo", number: 1, title: "Draft", author: "alice" },
    ];
    const drafts = new Set([1]);
    const result = filterDraftsAndSelf(prs, drafts, "bob");
    expect(result.excluded).toEqual([{ pr: prs[0], reason: "draft" }]);
  });

  it("excludes self-authored PRs", () => {
    const prs: PrInfo[] = [
      { repo: "org/repo", number: 2, title: "My PR", author: "bob" },
    ];
    const result = filterDraftsAndSelf(prs, new Set(), "bob");
    expect(result.excluded).toEqual([{ pr: prs[0], reason: "self-authored" }]);
  });

  it("keeps non-draft, non-self PRs", () => {
    const pr: PrInfo = { repo: "org/repo", number: 3, title: "Good", author: "alice" };
    const result = filterDraftsAndSelf([pr], new Set(), "bob");
    expect(result.included).toEqual([pr]);
  });
});

describe("filterByAuthors", () => {
  const authors = ["alice", "bob", "dependabot[bot]"];

  it("keeps PRs from allowlisted authors", () => {
    const pr: PrInfo = { repo: "org/repo", number: 1, title: "X", author: "alice" };
    const result = filterByAuthors([pr], authors);
    expect(result.included).toEqual([pr]);
  });

  it("excludes PRs from non-allowlisted authors", () => {
    const pr: PrInfo = { repo: "org/repo", number: 2, title: "Y", author: "charlie" };
    const result = filterByAuthors([pr], authors);
    expect(result.excluded).toEqual([{ pr, reason: "author not in allowlist" }]);
  });

  it("handles bot authors with brackets", () => {
    const pr: PrInfo = { repo: "org/repo", number: 3, title: "Z", author: "dependabot[bot]" };
    const result = filterByAuthors([pr], authors);
    expect(result.included).toEqual([pr]);
  });

  it("skips author filtering when authors list is empty", () => {
    const pr: PrInfo = { repo: "org/repo", number: 4, title: "W", author: "anyone" };
    const result = filterByAuthors([pr], []);
    expect(result.included).toEqual([pr]);
  });
});
```

**Step 2: Run tests to verify they fail**

Run: `npm test`
Expected: FAIL -- `filterByAuthors`, `filterDraftsAndSelf` not exported.

**Step 3: Rewrite discover.ts**

Replace `src/discover.ts` with:

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { log } from "./log.js";
import type { LgtmConfig, PrInfo, PrDetail, ScopeEntry } from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * Discover PRs to review using tiered discovery.
 *
 * Tier 1: PRs where user-review-requested:@me (any author, any repo in scoped orgs)
 * Tier 2: All open PRs filtered by author allowlist, repo/path scope,
 *         excluding drafts, self-authored, and already-approved PRs
 *
 * Results are merged and deduplicated by repo#number.
 */
export async function discoverPrs(config: LgtmConfig): Promise<PrInfo[]> {
  const orgs = deriveOrgs(config.scope);
  const currentUser = await getCurrentUser();
  const seen = new Map<string, PrInfo>();

  // --- Tier 1: review-requested ---
  for (const org of orgs) {
    log(`Tier 1: searching ${org} for review-requested PRs...`);
    try {
      const { stdout } = await execFileAsync("gh", [
        "search", "prs",
        "user-review-requested:@me",
        "--owner", org,
        "--state", "open",
        "--json", "repository,number,title,author",
      ]);
      const raw = JSON.parse(stdout);
      for (const pr of parsePrSearchResult(raw)) {
        seen.set(`${pr.repo}#${pr.number}`, pr);
      }
    } catch {
      log(`  Warning: tier 1 search failed for ${org}`);
    }
  }
  const tier1Count = seen.size;
  log(`Tier 1: ${tier1Count} PRs from review requests`);

  // --- Tier 2: broad discovery with filters ---
  for (const org of orgs) {
    log(`Tier 2: searching ${org} for all open PRs...`);
    try {
      const { stdout } = await execFileAsync("gh", [
        "search", "prs",
        "--owner", org,
        "--state", "open",
        "--json", "repository,number,title,author,isDraft",
      ]);

      const rawResults = JSON.parse(stdout) as Array<{
        repository: { nameWithOwner: string };
        number: number;
        title: string;
        author: { login: string };
        isDraft: boolean;
      }>;

      // Collect draft status before parsing
      const draftNumbers = new Set<number>();
      for (const r of rawResults) {
        if (r.isDraft) draftNumbers.add(r.number);
      }

      const prs = parsePrSearchResult(rawResults);

      // Filter: drafts and self-authored
      const { included: afterDraftSelf, excluded: draftSelfExcluded } =
        filterDraftsAndSelf(prs, draftNumbers, currentUser);
      for (const { pr, reason } of draftSelfExcluded) {
        log(`Skipping ${pr.repo}#${pr.number}: ${reason}`);
      }

      // Filter: repo allowlist + path prefixes
      const filesMap = await fetchFilesForPathScoped(afterDraftSelf, config.scope);
      const { included: afterScope, excluded: scopeExcluded } =
        filterByScope(afterDraftSelf, config.scope, filesMap);
      for (const { pr, reason } of scopeExcluded) {
        log(`Skipping ${pr.repo}#${pr.number}: ${reason}`);
      }

      // Filter: author allowlist
      const { included: afterAuthors, excluded: authorExcluded } =
        filterByAuthors(afterScope, config.authors);
      for (const { pr, reason } of authorExcluded) {
        log(`Skipping ${pr.repo}#${pr.number}: ${reason}`);
      }

      // Filter: already-approved
      const afterApproval = await filterApproved(afterAuthors);

      // Add to seen (dedup with tier 1)
      for (const pr of afterApproval) {
        const key = `${pr.repo}#${pr.number}`;
        if (!seen.has(key)) {
          seen.set(key, pr);
        }
      }
    } catch {
      log(`  Warning: tier 2 search failed for ${org}`);
    }
  }

  const tier2Count = seen.size - tier1Count;
  log(`Tier 2: ${tier2Count} additional PRs from broad discovery`);
  log(`Total: ${seen.size} PRs to consider`);

  return [...seen.values()];
}

/**
 * Get the current GitHub user's login. Used to filter self-authored PRs.
 */
async function getCurrentUser(): Promise<string> {
  try {
    const { stdout } = await execFileAsync("gh", [
      "api", "user", "--jq", ".login",
    ]);
    return stdout.trim();
  } catch {
    log("Warning: could not determine current user, self-authored filter disabled");
    return "";
  }
}

/**
 * Fetch changed files for PRs in path-scoped repos.
 */
async function fetchFilesForPathScoped(
  prs: PrInfo[],
  scope: ScopeEntry[],
): Promise<Map<string, string[]>> {
  const pathScopedRepos = new Set(
    scope.filter((s) => s.pathPrefixes !== null).map((s) => s.repo),
  );
  const filesMap = new Map<string, string[]>();

  for (const pr of prs) {
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
        log(`  Warning: could not fetch files for ${key}, including in scope`);
      }
    }
  }

  return filesMap;
}

/**
 * Filter out already-approved PRs by checking reviewDecision.
 */
async function filterApproved(prs: PrInfo[]): Promise<PrInfo[]> {
  const result: PrInfo[] = [];

  for (const pr of prs) {
    try {
      const { stdout } = await execFileAsync("gh", [
        "pr", "view", String(pr.number),
        "--repo", pr.repo,
        "--json", "reviewDecision",
      ]);
      const parsed = JSON.parse(stdout);
      if (parsed.reviewDecision === "APPROVED") {
        log(`Skipping ${pr.repo}#${pr.number}: already approved`);
        continue;
      }
    } catch {
      // If we can't check, include (fail open)
    }
    result.push(pr);
  }

  return result;
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
 * Filter out draft and self-authored PRs. Exported for testing.
 */
export function filterDraftsAndSelf(
  prs: PrInfo[],
  draftNumbers: Set<number>,
  currentUser: string,
): { included: PrInfo[]; excluded: Array<{ pr: PrInfo; reason: string }> } {
  const included: PrInfo[] = [];
  const excluded: Array<{ pr: PrInfo; reason: string }> = [];

  for (const pr of prs) {
    if (draftNumbers.has(pr.number)) {
      excluded.push({ pr, reason: "draft" });
    } else if (currentUser && pr.author === currentUser) {
      excluded.push({ pr, reason: "self-authored" });
    } else {
      included.push(pr);
    }
  }

  return { included, excluded };
}

/**
 * Filter PRs by author allowlist. Exported for testing.
 * If authors list is empty, all PRs pass (no author filtering).
 */
export function filterByAuthors(
  prs: PrInfo[],
  authors: string[],
): { included: PrInfo[]; excluded: Array<{ pr: PrInfo; reason: string }> } {
  if (authors.length === 0) {
    return { included: [...prs], excluded: [] };
  }

  const authorSet = new Set(authors);
  const included: PrInfo[] = [];
  const excluded: Array<{ pr: PrInfo; reason: string }> = [];

  for (const pr of prs) {
    if (authorSet.has(pr.author)) {
      included.push(pr);
    } else {
      excluded.push({ pr, reason: "author not in allowlist" });
    }
  }

  return { included, excluded };
}

/**
 * Filter PRs by scope rules. Exported for testing.
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

    if (entry.pathPrefixes === null) {
      included.push(pr);
      continue;
    }

    const key = `${pr.repo}#${pr.number}`;
    const files = filesMap.get(key);

    if (!files) {
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

function findScopeEntry(repo: string, scope: ScopeEntry[]): ScopeEntry | null {
  for (const entry of scope) {
    if (entry.repo === repo) return entry;
  }
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
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add src/discover.ts tests/discover.test.ts
git commit -m "feat: tiered discovery with author/draft/self/approval filters

Tier 1: PRs where user-review-requested:@me (any author)
Tier 2: All open PRs filtered by author allowlist, repo/path scope,
excluding drafts, self-authored, and already-approved PRs.
Results merged and deduplicated."
```

---

### Task 4: Update Index and AGENTS.md

**Files:**
- Modify: `src/index.ts`
- Modify: `AGENTS.md`

**Step 1: Update index.ts log line**

In `src/index.ts`, update the log line at the top of `main()` to also show authors:

Replace:
```typescript
  const scopeSummary = config.scope.map((s) => s.repo).join(", ");
  log(`Starting review cycle (scope: ${scopeSummary})`);
```

with:
```typescript
  const scopeSummary = config.scope.map((s) => s.repo).join(", ");
  log(`Starting review cycle (scope: ${scopeSummary}, authors: ${config.authors.length})`);
```

**Step 2: Update AGENTS.md**

In `AGENTS.md`, update the "Running" section and environment variables table.

Replace the Running section:
```bash
export LGTM_SCOPE="acme/mono:wonder/app;globex/server"
npx tsx src/index.ts
```
with:
```bash
export LGTM_SCOPE="acme/mono:wonder/app;globex/server"
npx tsx src/index.ts
```

Actually, replace the entire Running section with:
```bash
npx tsx src/index.ts
```

And replace the environment variables table with:

```markdown
| Variable | Default | Description |
|----------|---------|-------------|
| `LGTM_CONFIG` | `./lgtm.yml` | Path to YAML config (scope + authors) |
| `LGTM_PROJECTS_DIR` | `~/projects` | Where repos are cloned |
| `LGTM_STATE_DIR` | `~/.local/state/lgtm` | State and outcome storage |
| `LGTM_AUTO_APPROVE_AUTHORS` | (none) | Comma-separated auto-approve authors |
| `LGTM_SENSITIVE_PATTERNS` | `*.env*,...` | File patterns blocking auto-approve |
```

Remove the `LGTM_SCOPE` and `LGTM_ORG` rows.

**Step 3: Verify TypeScript compiles**

Run: `npx tsc --noEmit`
Expected: No errors.

**Step 4: Run all tests**

Run: `npm test`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add src/index.ts AGENTS.md
git commit -m "docs: update AGENTS.md for YAML config and tiered discovery"
```

---

### Task 5: Update Systemd Configuration

Work in the **workstation** repo (`~/projects/workstation`).

**Files:**
- Modify: `hosts/cloudbox/configuration.nix`

**Step 1: Replace LGTM_SCOPE with nothing (or LGTM_CONFIG if needed)**

In `configuration.nix`, in the lgtm-run service Environment block (around line 317-322), remove the `LGTM_SCOPE=...` line. The default `./lgtm.yml` path works because `WorkingDirectory` is already set to `/home/dev/projects/lgtm`.

Remove the line:
```nix
        "LGTM_SCOPE=acme/mono:apps/catalog,apps/storefront,apps/data/streaming,apps/data/legacy-streaming,apps/data/wiki;globex/ops-server"
```

The remaining Environment block should be:
```nix
      Environment = [
        "HOME=/home/dev"
        "OPENCODE_URL=http://127.0.0.1:4096"
        "LGTM_PROJECTS_DIR=/home/dev/projects"
      ];
```

**Step 2: Commit (workstation repo)**

```bash
cd ~/projects/workstation
git add hosts/cloudbox/configuration.nix
git commit -m "refactor: remove LGTM_SCOPE from systemd config

Scope is now defined in lgtm.yml in the lgtm repo.
WorkingDirectory is /home/dev/projects/lgtm so ./lgtm.yml is found automatically."
```

---

### Task 6: Push and Verify

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
bd sync
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
