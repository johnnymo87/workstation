# How does the goose community build read-only, role-specific subagents (reviewer/oracle/implementer) with structurally enforced tool limits?

**Keywords:** goose (block/goose, aaif-goose/goose), AI coding agent, subagents, `summon` extension, `delegate` tool, sub-recipes, `available_tools`, `.agents/agents/*.md`, Claude Code agents compatibility, PreToolUse hooks, goose_mode smart_approve, read-only reviewer agent, OpenCode agents migration

## The situation

We are moving our daily coding-agent workflow from OpenCode to goose. In OpenCode we rely heavily on **named subagents** that the main agent dispatches with a `task` tool. Each one is a markdown file with YAML frontmatter that pins a model and, importantly, **structurally restricts tools**:

| Agent | Model | Tools / permissions |
|---|---|---|
| oracle (strategic advisor) | strongest model | read/grep/glob/webfetch allowed; `bash: allow` BUT a denylist of destructive git (`git reset*`, `checkout*`, `restore*`, `stash*`, `clean*`, `switch*`, `commit*`, `push*`, `rebase*`, `merge*`, `cherry-pick*`, `revert*`, ...); `write`/`edit`/`task` denied |
| adversarial-reviewer (design + pre-PR diff review) | strongest model | same as oracle |
| code-reviewer, spec-reviewer | cheaper model | read-only + same git denylist |
| implementer (TDD one plan task, commit) | cheaper model | full tools |
| librarian (docs/OSS research) | cheaper model | read + bash + web |

Example OpenCode frontmatter:

```yaml
---
description: Read-only strategic technical advisor (opus model) — architecture, debugging, high-stakes decisions
mode: subagent
model: anthropic/claude-opus-5-5
permission:
  write: deny
  edit: deny
  task: deny
  bash:
    "*": allow
    "git reset*": deny
    "git checkout*": deny
    "git stash*": deny
    "git clean*": deny
    "git commit*": deny
    "git push*": deny
---
You are a read-only strategic technical advisor...
```

The enforcement is **structural on purpose**. Several agent sessions often share one git working tree. A "read-only" review subagent once ran `git stash` and `git checkout` to "clean up" and destroyed a peer session's uncommitted data. Since then our rule is that a read-only agent must be *unable* to mutate the tree, not merely told not to. Reviewers still need a shell, though, for `git diff`, `git log`, `rg`, running tests and so on.

We also have model "twins": the same prompt pinned to different models/providers (e.g. an OpenAI-family model behind a local OpenAI-compatible proxy vs. Anthropic-on-Vertex), with a fallback when one provider is down.

## Environment

- goose: we run a patched fork based on **v1.54.0**. Upstream latest release is **v1.55.0** and we track upstream `main`.
- goose runs as `goose serve` (ACP over HTTP+SSE). A custom TUI/relay talks to it over ACP. Sessions are interactive, and some are unattended recipes run with `goose run --recipe`.
- Provider: `gcp_vertex_ai` (Anthropic Claude models on Vertex). An OpenAI-compatible provider is available on some hosts.
- Global config enables the `developer`, `analyze` and `skills` platform extensions. **`summon` is currently disabled** because, in our v1.54.0 build, subagents bypassed all guardrails.
- Linux (NixOS). Agent/skill files are deployed declaratively, so generating per-host variants of a file is cheap.

## What we have verified (by reading source; we have not yet run end-to-end tests)

In goose **v1.54.0** (our fork):
- `summon`'s `delegate` tool can run an ad-hoc task, a recipe/sub-recipe, or an "agent" `.md` file found in `.goose/agents`, `.claude/agents`, `.agents/agents`, `~/.agents/agents`, `~/.claude/agents`, etc.
- Agent `.md` frontmatter parses only `name`, `description`, `model` (`struct AgentMetadata` in `summon.rs`). `tools:`, provider, permissions are ignored.
- Subagents inherit **all** parent extensions unless the *calling model* passes `extensions: [...]` in the delegate call (filter by extension name; `[]` = none).
- Subagents are hard-coded to `GooseMode::Auto` and constructed with an empty `HookManager`, so PreToolUse hooks/plugins never fire for them.

In upstream **main** (verified by reading commits):
- PR #12802 (in v1.55.0), "Bind subagents by their parent's hooks, mode and approvals": subagents run on the parent's Agent, inherit the parent's `goose_mode`, run the parent's hooks (PreToolUse etc.), and forward tool-confirmation requests to the parent client. This fixes issues #12650 and #11778.
- PR #12938 (merged, unreleased): when delegating to a **recipe** that declares `extensions:`, those extensions are used instead of inheriting the parent's.
- PR #12729 (v1.55.0) removed background/async subagents and the orchestrator extension.
- PR #12070: recipe `settings.goose_provider/goose_model` outrank `GOOSE_SUBAGENT_PROVIDER/MODEL` env and delegate params.
- Every extension config supports an `available_tools` allowlist. A `blocked_tools` denylist was declined (#7808).
- In issue #12921 a maintainer suggested "hierarchical recipes" for scoped tool limits.
- Agent `.md` files still parse only name/description/model upstream. We found no open PR adding Claude-Code-style `tools:`/`disallowedTools`.
- The `developer` extension's tools are `write`, `edit`, `shell`, `tree`, `read_image`. There is no separate read-file tool; reading happens via `shell`. So `available_tools` can remove write/edit but **cannot express "shell, but no destructive git"**.

## What we are uncertain about

- Whether the community converged on **recipes (sub-recipes) as the canonical "named subagent"** and agent `.md` files as a lightweight Claude-compat convenience, or whether richer agent frontmatter is planned.
- Whether there is a recommended pattern for a **read-only shell** (PreToolUse hook command filtering, a separate read-only MCP server, `analyze` extension only, container/sandbox per subagent, git worktree per subagent, etc.).
- Whether a PreToolUse hook can tell *which subagent/recipe* a tool call came from (so the policy can differ between the reviewer and the implementer), given that subagents now share the parent's hooks.
- How well the "approval forwarding to parent" works for ACP clients in practice. Does a custom ACP client see forwarded subagent permission requests as normal `session/request_permission` on the parent session?
- Whether people get per-agent model/provider "twins" with fallback, and how.

## Specific questions

1. What does the goose community (maintainers, docs, blog posts, Discord/GitHub discussions, popular recipe repos) recommend as **the** way to define reusable named subagents with restricted tools: sub-recipes with `extensions` + `available_tools` + `settings`, agent `.md` files, or something else? Please cite sources.
2. Concretely, how do people build a **read-only code reviewer** subagent in goose that can still run `git diff`/`rg`/tests but cannot write files or run destructive git? Is there a known hook script, a read-only shell MCP server, or a sandboxing approach in use?
3. Our current lean: rely on the `extensions` parameter the parent passes on each `delegate` call (e.g. tell the parent "for reviewers, pass `extensions: [\"analyze\"]`"). Is that considered a security/guardrail boundary in the goose community, or merely a context-size optimization? What failure modes are known (e.g. model omitting the param, unmatched filter silently falling back; see open PR #12430 "fail closed on unmatched extension filters")?
4. Can a PreToolUse hook distinguish the originating subagent/recipe (session id, recipe title, parent id, env var) after PR #12802? If so, how do people write per-role policies?
5. Is anyone already translating Claude Code / OpenCode agent definitions (with `tools:` / permission blocks) into goose recipes? Any converters, conventions, or pitfalls?
6. Any known issues with `delegate` + `smart_approve` / approval forwarding over ACP, or with subagent model/provider overrides (e.g. inheriting provider-specific request params, prompt caching)?

## Constraints

- Read-only roles must be **structurally** prevented from writing files and from destructive git. Prompt instructions alone are not acceptable for those roles.
- Reviewers must still be able to run read-only shell commands (git diff/log/show/blame, rg, test runners).
- We can patch our goose fork, but prefer approaches aligned with upstream direction so we can drop patches later.
- Agent definitions should be generated from a single source shared with OpenCode, so a translation step is fine.
