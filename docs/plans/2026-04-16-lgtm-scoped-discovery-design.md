# LGTM Scoped Discovery Design

## Problem

LGTM v2 discovers PRs from a single GitHub org (`LGTM_ORG`) and dispatches
reviews for all of them. The user needs:

1. **Multi-org coverage** -- review requests come from both `acme` and
   `globex` orgs.
2. **Per-repo allowlisting** -- not every repo in those orgs should be reviewed.
3. **Monorepo path filtering** -- `acme/mono` is a monorepo; only PRs
   touching specific subtrees should be dispatched.

## Design

### Scope Model

Replace `LGTM_ORG` (single org, all repos) with `LGTM_SCOPE` (allowlist of
repos with optional path prefixes).

**Env var syntax:**
```
LGTM_SCOPE="org/repo:path1,path2;org/repo2"
```

- Semicolon separates repo entries
- Each entry: `org/repo` (whole repo) or `org/repo:path1,path2,...` (path-scoped)
- Path matching: a changed file matches if it starts with any listed prefix
- No colon = review all paths in that repo
- Orgs are derived from repo names (no separate org config)

**Production value:**
```
LGTM_SCOPE="acme/mono:apps/catalog,apps/storefront,apps/data/streaming,apps/data/legacy-streaming,apps/data/wiki;globex/ops-server"
```

**Backward compatibility:** If `LGTM_SCOPE` is unset, fall back to `LGTM_ORG`
behavior (all repos in that org, no path filtering).

### Discovery Flow

```
for each unique org derived from scope entries:
  gh search prs user-review-requested:@me --owner <org>
  -> filter to repos in allowlist
  -> for path-scoped repos: check changed files against path prefixes
  -> filter already-dispatched
  -> dispatch matching PRs
  -> log skipped PRs with reason to stderr
```

### Out-of-Scope PRs

Logged to stderr (captured by journald): `Skipping org/repo#N: not in scope`
or `Skipping org/repo#N: no matching path filter`. No Telegram notification,
no dispatch marker.

### Types

```typescript
interface ScopeEntry {
  repo: string;                    // "org/repo"
  pathPrefixes: string[] | null;   // null = whole repo
}

interface LgtmConfig {
  scope: ScopeEntry[];             // replaces `org: string`
  projectsDir: string;
  stateDir: string;
  autoApproveAuthors: string[];
  sensitivePatterns: string[];
}
```

### What Changes

| File | Change |
|------|--------|
| `src/types.ts` | Add `ScopeEntry`, replace `org` with `scope` in `LgtmConfig` |
| `src/config.ts` | Parse `LGTM_SCOPE`, fallback to `LGTM_ORG` |
| `src/discover.ts` | Multi-org discovery loop, repo + path filtering |
| `src/index.ts` | Use new config shape (scope log line) |
| `src/prompt.ts` | Remove `config.org` reference |
| `tests/config.test.ts` | Test scope parsing + fallback |
| `tests/discover.test.ts` | Test filtering logic |
| `AGENTS.md` | Update env var docs |
| `configuration.nix` | Replace `LGTM_ORG` with `LGTM_SCOPE` |

### What Stays the Same

Everything downstream of discovery: context building, prompt construction,
worktree management, dispatch, outcome tracking.
