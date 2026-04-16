# How should an automated PR reviewer leverage session history and memory to produce better code reviews?

**Keywords:** AI code review, LLM agent memory, OpenCode, PR review automation, context engineering, session history, Letta, MemGPT, MCP memory server, mnemory, oc-search

## The situation

We built an automated PR review system called **lgtm** that runs on a NixOS cloudbox server. It's a thin discovery + dispatch layer:

1. A systemd timer runs every 10 minutes
2. It discovers PRs assigned for review via `gh search prs`
3. For each new PR, it creates a git worktree at the PR branch
4. It dispatches an OpenCode (an open-source Claude Code alternative) headless session with a review prompt
5. The OpenCode agent reviews the PR with full codebase access and posts the review via `gh pr review`

The system worked mechanically, but we removed it because the review quality wasn't good enough. The core problem: **the reviewer looked at each PR in isolation** -- just the diff + surrounding code. A good human reviewer brings broader context:

- What PRs were recently merged in this repo? What direction is the codebase heading?
- What has this PR author been working on recently? What patterns do they use?
- What review feedback has been given on past PRs in this repo?
- What design decisions were made in prior discussions that led to these changes?
- What conventions and standards does the team enforce?

## Environment

- **Agent runtime:** OpenCode (open-source, Claude Code alternative) running headless sessions via `opencode-launch`
- **Server:** NixOS (cloudbox) with systemd services
- **Session history:** All OpenCode sessions are stored in a SQLite DB at `~/.local/share/opencode/opencode.db`. We have a tool called `oc-search` that does substring search across session transcripts (tool calls, text, patches, reasoning). Schema: `project -> session -> message -> part`.
- **GitHub CLI:** `gh` is available for PR history, review comments, etc.
- **Notification:** Telegram via a separate daemon (pigeon)

## What we've researched

### OpenCode memory ecosystem

There are 20+ `opencode-memory` repos on GitHub. The most mature:

- **mnemory** (fpytloun, 90 stars) -- self-hosted MCP server with SQLite+vector store, LLM-powered fact extraction, deduplication, contradiction resolution. Has an OpenCode plugin that auto-injects/extracts memory on every turn via hooks (session.created, chat.message, session.idle, compaction). Scores 73.2% on the LoCoMo benchmark.
- **opencode-mem** (andy-zhangtao) -- persistent memory plugin capturing tool usage with AI compression and 3-layer search.
- **opencode-memory-plugin** (minzique) -- auto-capture and auto-injection via OpenCode hooks.

### Letta (formerly MemGPT)

Most architecturally distinctive. Three relevant ideas:

1. **Context Repositories** (Feb 2026) -- git-backed memory where the agent's context lives as files in a local filesystem. Every memory change is a git commit. Subagents can work in worktrees and merge context back. Progressive disclosure via file hierarchy + frontmatter.
2. **Three-tier memory** -- core memory (always in context), archival (searchable vector store), recall (conversation history). Agents actively manage what to promote/archive.
3. **Sleep-time compute** -- agents process and learn during idle time, rewriting their own context.
4. **Memory swarms** -- multiple subagents process memory concurrently in git worktrees, then merge results. Used for bootstrapping from Claude Code/Codex history.

### Our existing tools

- `oc-search` -- searches OpenCode session history via SQLite `instr()` substring matching. Can search tool calls, conversation text, patches, reasoning.
- `gh` CLI -- can query PR history, review comments, author activity, merged PRs.
- OpenCode headless sessions have full tool access (bash, file read/write, grep, etc.)

## The three approaches we identified

### Approach 1: Prompt-Guided Agent Discovery (our current lean)

Keep lgtm as the same thin dispatch layer, but rewrite the review prompt to include a **Phase 1: Context Gathering** where the agent uses `oc-search` and `gh` to build context before reviewing:

- `gh pr list --repo X --state merged --limit 10` for recent merged PRs
- `gh pr list --state merged --author <PR-author>` for author's recent work
- `oc-search '<repo-name>'` for prior discussions about this codebase
- `gh api repos/X/pulls/<N>/reviews` for past review comments
- Read AGENTS.md, check test patterns, understand conventions

Pros: Zero new infrastructure, uses existing tools, easy to iterate on prompt.
Cons: Re-discovers context from scratch each review, substring search may miss relevant sessions, longer sessions = more API cost.

### Approach 2: Curated Context Repository (Letta-inspired)

Maintain a git-backed "memory repo" per codebase with structured markdown files (architecture.md, recent-changes.md, review-patterns.md, conventions.md). A background process periodically processes session history and PR data into these files. The reviewer reads relevant files before reviewing.

Pros: Persistent knowledge, human-readable, auditable, amortizes context gathering.
Cons: Needs a "context builder" process, knowledge can go stale, risk of wrong context persisting.

### Approach 3: MCP Memory Server (mnemory-style)

Deploy mnemory as a service. Auto-capture memories from all OpenCode sessions via the plugin. The reviewer queries it via MCP tools for relevant context.

Pros: Semantic search, auto-capture, benefits all sessions not just reviews, deduplication built in.
Cons: New infrastructure (Python service, vector DB, OpenAI API), per-query costs, black-box memory, maintenance risk.

## What we know vs. what we're uncertain about

**Verified:**
- The original lgtm worked mechanically -- PR discovery, worktree creation, OpenCode dispatch, review posting all functioned correctly
- Review quality was the problem, specifically lack of broader context
- oc-search works for finding sessions by keyword but uses substring matching, not semantic search
- OpenCode headless sessions have full bash/tool access, so the reviewer can run any CLI command
- All our coding work happens in OpenCode sessions, so session history is a rich source of context

**Uncertain:**
- Whether an LLM agent can reliably figure out WHAT context to gather (vs. being told explicitly)
- Whether oc-search's substring matching is good enough for finding relevant sessions, or whether we'd quickly hit cases where semantic search is needed
- Whether the additional context-gathering phase would make reviews too slow/expensive
- Whether a phased approach (gather then review) works better than injecting pre-computed context
- How much of a quality difference memory/context actually makes for code review -- is this the real bottleneck, or is it something else (e.g., the review prompt itself, the model's code review capabilities)?

## Specific questions

1. **Architecture:** Given that we already have oc-search and gh, is Approach 1 (prompt-guided discovery) a reasonable starting point? Or are there fundamental reasons to jump straight to a memory server or context repo?

2. **Prompt design for context-aware review:** What are best practices for prompting an LLM agent to gather context before performing a code review? Should it be a rigid checklist ("always run these 5 commands") or more open-ended ("investigate the context you need")?

3. **Memory granularity:** What should be remembered? Full PR diffs? Summaries? Just decisions and patterns? Review comments? Session transcripts? What's the right level of abstraction for review context?

4. **Upgrade path:** If we start with Approach 1, what signals should tell us it's time to move to Approach 2 or 3? What would we look for?

5. **Alternative framing:** Are we thinking about this wrong? Is "memory" even the right abstraction for improving automated code review? Could there be simpler interventions (e.g., better review prompts, specialized review models, structured review rubrics) that would have more impact?

6. **Letta's context repo pattern:** The git-backed memory with progressive disclosure is intellectually appealing but seems complex. Has anyone successfully used this pattern specifically for code review context? Is it overkill for this use case?

7. **Practical experience:** Are there any production-quality automated code review systems (beyond basic linting/SAST) that successfully incorporate historical context? What do they do?

## Constraints

- Must run on our existing NixOS cloudbox infrastructure
- Must use OpenCode as the agent runtime (not switching to Letta Code or another agent)
- Should not require external cloud services beyond what we already use (GitHub, Telegram). Local-first preferred.
- Prefer incremental approach -- we want to validate that context improves reviews before building complex infrastructure
- The reviewer agent runs as an OpenCode headless session with full bash/tool access
