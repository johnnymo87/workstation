# LGTM v2: Context-Aware AI PR Review

Automated PR review daemon with a deterministic context pipeline. Builds a pre-computed context packet of PR history, repo rules, author activity, and session history, then dispatches a grounded review to an OpenCode headless session.

## Problem

lgtm v1 worked mechanically but produced low-quality reviews because it reviewed each PR in isolation -- just the diff + surrounding code. A good reviewer brings broader context: recent codebase direction, author patterns, past review feedback, design decisions from prior discussions, and team conventions.

## Design Principles

Three insights from research (ChatGPT deep research, Letta/MemGPT, CodeRabbit, Qodo, mnemory ecosystem):

1. **Rules + retrieval + evaluation, not just memory.** The quality problem is likely a combination of insufficient context, missing repo-specific rules, weak comment discipline, and no evaluation loop. Memory alone isn't the bottleneck.

2. **Remember abstractions, retrieve evidence.** Durable knowledge (conventions, decisions, patterns) should be curated. Raw material (PR diffs, session transcripts, review threads) should be searchable but not dumped into context.

3. **LLMs are better at using bounded context than inventing search plans.** Pre-compute a deterministic context packet rather than asking the agent to figure out what to look up.

## Architecture

```
systemd timer (every 10 min)
     |
     v
lgtm-run (systemd oneshot)
     |
     +-- gh search prs --> discover PRs needing review
     |
     +-- check state dir --> skip already-dispatched
     |
     +-- for each new PR:
     |    +-- build context packet
     |    |    +-- PR metadata + linked issue
     |    |    +-- repo rules (AGENTS.md, review guides)
     |    |    +-- recent merged PRs touching same paths
     |    |    +-- author's recent merged PRs
     |    |    +-- past review comments on similar paths
     |    |    +-- oc-search hits seeded by PR title + paths
     |    |    +-- changed file clusters by subsystem
     |    |
     |    +-- write context packet to worktree as .lgtm-context.md
     |    +-- ensure repo cloned, create worktree
     |    +-- opencode-launch <worktree-dir> "<review prompt>"
     |    +-- touch dispatched marker
     |    +-- write initial outcome record
     |
     +-- check outcomes of previously-dispatched reviews
     +-- exit
```

### What changed from v1

| Component | v1 | v2 |
|-----------|----|----|
| Context packet | None | `.lgtm-context.md` with 7 sections |
| Review prompt | "Review this diff" | 3-phase grounded review with discipline rules |
| Outcome tracking | None | JSON outcome files with acceptance metrics |
| Everything else | Same | Same (gh discovery, flat markers, worktrees, opencode-launch, pigeon) |

## Context Packet

The context packet (`.lgtm-context.md`) is built deterministically by lgtm before dispatch. Capped at ~10K tokens.

### 1. PR Metadata
- Title, author, description, labels, linked issue
- Branch name, stats (+/- lines, files changed)
- Source: `gh pr view --json`

### 2. Repo Rules
- Contents of AGENTS.md (if present in worktree)
- Contents of any `.github/review-guide.md` or similar
- Source: file read from worktree

### 3. Recent Merged PRs Touching Same Paths
- Last 5-10 merged PRs that modified any of the same files
- Title, author, date, 1-line summary
- Source: `gh pr list --state merged` + `gh pr view --json files` for path filtering

### 4. Author's Recent Activity
- Last 5 merged PRs by this author in this repo
- Title, date, reviewer comments summary
- Source: `gh pr list --state merged --author <author>`

### 5. Past Review Comments on Similar Paths
- Review comments from recent PRs touching the same files
- What was flagged, was it accepted or dismissed
- Source: `gh api repos/{owner}/{repo}/pulls/{N}/reviews` + comments

### 6. Session History Hits
- `oc-search` results for the repo name and key touched paths/subsystems
- Truncated to most recent/relevant 5-10 hits with session date and snippet
- Source: `oc-search '<repo-name>'`, `oc-search '<key-path>'`

### 7. Changed File Clusters
- Changed files grouped by subsystem/directory
- Which subsystems are touched and their relationships
- Source: computed from `gh pr view --json files`

## Review Prompt

Three-phase prompt following the rigid-skeleton pattern:

### Phase 1: Ground Yourself (mandatory)
1. Read `.lgtm-context.md` thoroughly
2. Read the PR description and any linked issue
3. Read repo rules (AGENTS.md, review guide)
4. Inspect changed files and understand touched subsystems
5. Optionally run `gh pr view` for more detail on referenced prior PRs
6. Optionally run `oc-search '<term>'` for targeted session history lookups
7. Write a brief internal summary: purpose of change, how it fits recent work, relevant conventions/decisions

### Phase 2: Review
1. Read the diff carefully
2. Explore surrounding code for context
3. Check test coverage and appropriateness
4. Judge on: correctness, design fit, safety, continuity with codebase direction

### Phase 3: Submit with Discipline
Submit via `gh pr review <N> --repo <repo>`.

Rules:
- Do NOT comment on style unless it violates an explicit repo rule or repeated historical pattern
- Do NOT speculate about intent if linked issue/history is missing -- ask the author
- Cap comments to highest-signal findings (3-5 substantive > 15 nitpicks)
- Trivial + safe + auto-approve-eligible author -> `--approve`
- Reasonable but non-trivial -> `--comment` with specific, actionable feedback
- Clear bugs or security issues -> `--request-changes` with specific fixes
- NEVER auto-approve changes to auth, encryption, data handling, or sensitive file patterns

## Evaluation

### Metrics

**Primary:** Accepted-comment rate -- did the human act on the review comment?

**Secondary:**
- Dismissal/rejection rate
- Comment count per review (fewer is better if signal is high)
- Tokens + latency per review
- Context packet size vs. review quality correlation

### Outcome Tracking

```
~/.local/state/lgtm/
  dispatched/           # PR dispatch markers (existing)
  outcomes/             # review outcome tracking (new)
    <org>/
      <repo>/
        <N>.json        # review metadata + outcome
```

Each outcome file records:
- Timestamp of review posting
- Comment count and verdict (approve/comment/request-changes)
- Context packet size (tokens)
- Session duration and cost (if available)
- Follow-up check: PR updated after review? Comments resolved? Review dismissed?

Outcome checking happens on subsequent lgtm runs -- check previously-dispatched PRs for resolution status.

## Upgrade Path

### Phase 1.5: Nightly Context Repo (Letta-inspired)

When to trigger: same conventions rediscovered repeatedly, context packet hitting size cap, humans wanting to inspect/edit agent knowledge.

Add a nightly job that writes a small context repo per codebase:
- `review-charter.md` -- how this repo should be reviewed
- `conventions/*.md` -- coding conventions
- `decisions/*.md` -- architectural decisions
- `accepted-patterns.md` -- review comments that were accepted
- `dismissed-patterns.md` -- review comments that were dismissed
- `recent-shifts.md` -- recent direction changes

### Phase 2: Semantic Memory (mnemory-style)

When to trigger: substring search regularly misses relevant history, repo/session volume makes curation too expensive, need semantic retrieval across many repos.

Deploy mnemory or similar as a service. Auto-capture from all sessions. Reviewer queries via MCP.

## Deployment

Same as v1: cloudbox only, systemd timer + oneshot, gated behind `enableLgtm` flag in `hosts/cloudbox/configuration.nix`.

### Workstation integration

- `projects.nix`: lgtm entry with `platforms = [ "cloudbox" ]`
- `hosts/cloudbox/configuration.nix`: systemd service + timer
- Auto-cloned by `ensure-projects`

## Source Code

`johnnymo87/lgtm` repo (private). TypeScript, tsx runner, vitest.

### New/modified files (vs. v1)

- `src/context.ts` -- builds the context packet (gh, oc-search, file reads)
- `src/prompt.ts` -- updated 3-phase review prompt
- `src/outcomes.ts` -- writes and checks review outcome files
- `src/index.ts` -- updated orchestration with context pipeline

## Research Sources

- **ChatGPT deep research** (April 2026): recommended hybrid retrieval pipeline, rigid prompt skeleton, rules + retrieval + evaluation framing. Referenced CodeRabbit, Qodo, Greptile, Graphite production patterns.
- **Letta/MemGPT**: context repositories (git-backed memory), three-tier memory, progressive disclosure. Inspirational for Phase 1.5 upgrade path.
- **mnemory** (fpytloun, 90 stars): self-hosted MCP memory server with OpenCode plugin. 73.2% on LoCoMo. Candidate for Phase 2.
- **lgtm v1** (git history): validated that the discovery + dispatch + worktree architecture works; review quality was the only problem.
