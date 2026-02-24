---
name: opencode-agents
description: Documents the OpenCode agent set — what each does, when to use it, and why the others were cut. Use when questioning agent choices or considering adding/removing agents.
---

# OpenCode Agents

Agents are deployed system-wide via `assets/opencode/agents/` -> `~/.config/opencode/agents/`.
Their nix wiring is in `users/dev/opencode-config.nix`.

## Current Agents

### librarian (subagent)
**Purpose:** Documentation and OSS research — finds official docs, examples, and best practices.
**Model:** claude-sonnet-4-6
**Tools:** webfetch, websearch, codesearch, bash (for `gh`), read/glob/grep
**When to use:** Unfamiliar library, need API docs, want to find how an OSS project handles something.
**Workflow:** Discovery (Exa codesearch/websearch) -> Retrieval (webfetch) -> GitHub (gh CLI). Every claim cites a source.

Depends on `OPENCODE_ENABLE_EXA=1` (set in both home.devbox.nix and home.darwin.nix) to enable the built-in Exa AI-backed websearch/codesearch tools.

### oracle (subagent)
**Purpose:** Read-only strategic technical advisor — architecture, debugging, high-stakes decisions.
**Model:** openai/gpt-5.3-codex (deliberately different from primary model for perspective diversity)
**Tools:** read, glob, grep, bash, webfetch, websearch, codesearch (no write/edit/task)
**When to use:** Stuck after 2+ attempts, architectural decision, need a second opinion from a different model.
**Key trait:** Cannot modify files. Gives a recommendation with effort estimate (Quick/Short/Medium/Large) and action plan. Pragmatic minimalism — biases toward simplest solution.

Uses OpenAI auth configured via sops-nix (`openai_api_key` secret on devbox).

### vision-qa (subagent)
**Purpose:** Visual QA analyst — analyzes screenshots and UI renders.
**Model:** claude-opus-4-6
**Tools:** read only
**When to use:** Comparing screenshots, identifying visual regressions, analyzing canvas/WebGL output, triaging UI bugs.
**Output:** Structured JSON with verdict (pass/fail/uncertain), confidence score, issues with severity and suggested next checks.

### slack (subagent)
**Purpose:** Slack research — searching and analyzing conversations.
**Model:** (inherits default)
**Tools:** Slack MCP tools only (no file access)
**When to use:** Finding discussions, decisions, or context from Slack.
**Note:** Requires Slack MCP to be configured and enabled. Currently Darwin-only (tokens from macOS Keychain).

## Agents We Removed (and Why)

In Feb 2025 we inherited 6 agents from "Oh My OpenCode" (OMO) and cut them all:

| Agent | Role | Lines | Why removed |
|-------|------|-------|-------------|
| prometheus | Planning interviewer -> work plan generator | 796 | Never used. Writes plans to `.opencode/plans/` for atlas to execute. The full pipeline (prometheus -> metis -> momus -> atlas) is heavyweight and was never adopted. |
| atlas | Plan executor (delegates to workers, verifies) | 661 | Only useful with prometheus plans. |
| metis | Pre-planning gap analysis | 85 | Only useful as prometheus subagent. |
| momus | Plan quality reviewer | 80 | Only useful as prometheus subagent. |
| sisyphus | General "senior engineer" orchestrator | 371 | Duplicates the default OpenCode agent. No unique capability. |
| hephaestus | Autonomous "deep worker" | 322 | Nearly identical to sisyphus but with "never ask" philosophy. Also duplicates default agent. |
| multimodal-looker | Media file interpreter (PDFs, images) | 49 | Redundant. OpenCode's Read tool natively handles PDFs and images. Any agent with `read: allow` can do what this did. vision-qa covers the structured-analysis-of-images case. |

**Total removed:** 2,364 lines of agent prompts.

## Design Principles

1. **Subagents over primaries.** We only keep subagent-mode agents (called by the main agent). Primary-mode agents (sisyphus, hephaestus, prometheus) that replace the default agent were never used.
2. **Unique capability required.** Each agent must do something the default agent can't or shouldn't (different model, specialized output format, restricted tool access).
3. **Models.dev for metadata.** Don't manually declare model limits/modalities — OpenCode auto-fetches from models.dev on startup.
4. **Exa for web search.** `OPENCODE_ENABLE_EXA=1` enables built-in websearch/codesearch with no API key. Free tier has unpublished rate limits; if hit, add `?exaApiKey=<key>` to the Exa MCP URL.

## Adding a New Agent

1. Create `assets/opencode/agents/<name>.md` with YAML frontmatter (description, mode, model, permission)
2. Add `xdg.configFile."opencode/agents/<name>.md".source = ...` to `users/dev/opencode-config.nix`
3. Apply: `nix run home-manager -- switch --flake .#dev` (devbox) or `darwin-rebuild switch` (macOS)
4. Update this skill with the agent's purpose and rationale
