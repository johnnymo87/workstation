# LGTM Tiered Discovery Design

Supersedes: `2026-04-16-lgtm-scoped-discovery-design.md` (env-var-based scope).

## Problem

LGTM v2's `LGTM_SCOPE` env var is hard to read and maintain at scale, and the
discovery model (`user-review-requested:@me`) misses PRs from teammates who
didn't explicitly request review.

## Design

### Tiered Discovery

**Tier 1: Review-requested (unchanged)**
Any PR where `user-review-requested:@me`, regardless of author or repo.
If someone asks for your review, LGTM dispatches it.

**Tier 2: Author + repo/path allowlist**
All open PRs in scoped orgs, filtered by:
1. Exclude drafts (`isDraft`)
2. Exclude self-authored (current user via `gh api user`)
3. Repo allowlist + path prefix filtering (same logic as before)
4. Author allowlist (only dispatch if PR author is in the configured list)
5. Exclude already-approved (`reviewDecision === "APPROVED"`)
6. Exclude already-dispatched (existing marker check)

Deduplication: dispatched markers prevent a PR found by both tiers from
being dispatched twice.

### YAML Config File

Replace `LGTM_SCOPE` and `LGTM_ORG` env vars with a `lgtm.yml` checked into
the lgtm repo. Env var `LGTM_CONFIG` optionally overrides the path (defaults
to `./lgtm.yml`).

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

### Types

```typescript
interface ScopeEntry {
  repo: string;
  pathPrefixes: string[] | null;
}

interface LgtmConfig {
  scope: ScopeEntry[];
  authors: string[];              // tier 2 author allowlist
  projectsDir: string;
  stateDir: string;
  autoApproveAuthors: string[];
  sensitivePatterns: string[];
}
```

### Discovery Flow

```
// Tier 1: review-requested (any author, any repo in scoped orgs)
for each unique org in scope:
  gh search prs user-review-requested:@me --owner <org> --state open
  -> deduplicate with tier 2 results later via dispatched markers

// Tier 2: broad discovery with filters
for each unique org in scope:
  gh search prs --owner <org> --state open --json ...,isDraft
  -> exclude drafts
  -> exclude self-authored (resolve current user once)
  -> repo allowlist + path filtering
  -> author allowlist
  -> fetch reviewDecision, exclude APPROVED
  -> merge with tier 1 results, deduplicate

-> exclude already-dispatched
-> dispatch
```

### Files Changed

| File | Change |
|------|--------|
| `package.json` | Add `js-yaml` dependency |
| `lgtm.yml` | Create config file |
| `src/types.ts` | Add `authors` to `LgtmConfig` |
| `src/config.ts` | Rewrite to load YAML, remove `parseScope`/`LGTM_SCOPE`/`LGTM_ORG` |
| `src/discover.ts` | Tiered discovery, draft/self/author/approval filters |
| `src/index.ts` | Minor log line update |
| `tests/config.test.ts` | Rewrite for YAML loading |
| `tests/discover.test.ts` | Add tiered discovery + filter tests |
| `AGENTS.md` | Update config docs |
| `configuration.nix` | Replace `LGTM_SCOPE` with `LGTM_CONFIG` (or remove if default works) |
