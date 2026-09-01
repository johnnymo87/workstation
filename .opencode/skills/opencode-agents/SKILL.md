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
**Model:** claude-sonnet-5
**Tools:** webfetch, websearch, codesearch, bash (for `gh`), read/glob/grep
**When to use:** Unfamiliar library, need API docs, want to find how an OSS project handles something.
**Workflow:** Discovery (Exa codesearch/websearch) -> Retrieval (webfetch) -> GitHub (gh CLI). Every claim cites a source.

Depends on `OPENCODE_ENABLE_EXA=1` (set in both home.devbox.nix and home.darwin.nix) to enable the built-in Exa AI-backed websearch/codesearch tools.

### oracle-fable (subagent)
**Purpose:** Read-only strategic technical advisor — architecture, debugging, high-stakes decisions.
**Model:** `claude-fable-5-1`, pinned in the agent's own source (`assets/opencode/agents/oracle.md`). There is one variant, not three: the `-opus` and `-sol` twins were removed 2026-09-01 along with the `mkAgentVariant` machinery that generated them.
**Why the handle still says `-fable`:** it is a compat hook. Nothing needs disambiguating today, but keeping the suffix means re-introducing a second model later is purely additive instead of renaming a handle every call site already uses. The *source file* deliberately does not carry the suffix — it is named for the agent, not the model.
**Model routing:** host-correct — the source pins `anthropic/claude-fable-5-1`, and on cloudbox `patchAgent`'s `afterFable` branch rewrites it to `google-vertex-anthropic/claude-fable-5-1@default`, because cloudbox has no first-party Anthropic auth. That rewrite captures the version rather than matching a literal, so a future 5.2 pin does not silently produce `claude-fable-5@default-1`.
**Tools:** read, glob, grep, bash, webfetch, websearch, codesearch (no write/edit/task)
**When to use:** Stuck after 2+ attempts, architectural decision, need a second opinion. No CAUTION on the description any more — it is the only variant, so the orchestrator should reach for it directly.
**Cost note:** Fable 5.1 is 2× Opus 5 on input/output/cache-write (\$10/\$50 vs \$5/\$25 per MTok), and cheaper only on cache reads (\$0.25 vs \$0.50). Oracle calls are typically large-context single shots, so this is a real line item on the aigateway ledger.
**Key trait:** Cannot modify files. Gives a recommendation with effort estimate (Quick/Short/Medium/Large) and action plan. Pragmatic minimalism — biases toward simplest solution. Its prompt is written as ethos + judgment (terse, actionable) rather than a rigid rule-list.

### adversarial-reviewer-fable (subagent)
**Purpose:** Skeptical, adversarial review of a **design / plan / approach before it's built** — hunts flaws, wrong assumptions, missing cases, hazards, and better alternatives.
**Model:** `claude-fable-5-1`, pinned in `assets/opencode/agents/adversarial-reviewer.md`. Single variant; the `-opus` and `-sol` twins were removed 2026-09-01. Same `-fable`-suffix-as-compat-hook rationale as oracle above.
**Model routing:** host-correct, same as oracle — source pins `anthropic/`, cloudbox gets the Vertex rewrite via `patchAgent`.
**Tools:** read, glob, grep, bash, webfetch, websearch, codesearch (no write/edit/task)
**When to use:** You have a design or plan and want it pressure-tested *before* writing code; you want the uncomfortable "this is solving the wrong problem" read. No CAUTION any more — reach for it directly.
**Key trait:** Grounds every claim in the actual code/artifact (`file:line`, never fabricates); distinguishes verified findings from suspicions; reports verdict → confirmed-sound → flaws-by-severity → missing cases → concrete recommendations.
**Complements:** oracle is the *advisor* ("what should we do?"); the adversarial reviewers are its skeptic ("here's how that goes wrong"). code-reviewer / spec-reviewer check a *finished implementation* against a spec; the adversarial reviewers check the *design itself*, earlier. Their prompt is deliberately ethos-driven (care that the design is correct; judgment over checklist) per the Amanda Askell steer.

### vision-qa (subagent — devbox only)
**Purpose:** Visual QA analyst — analyzes screenshots and UI renders.
**Model:** `google/gemini-3.7-flash` + `variant: high` — direct Google Generative AI API, authed via `GOOGLE_GENERATIVE_AI_API_KEY` / `GEMINI_API_KEY` (sops `gemini_api_key`). **API-key-only by design: no Vertex.** The agent is therefore deployed only on devbox (the API-key host); macOS has no Gemini API key (Vertex ADC only) and cloudbox disables the direct `google` provider, so neither gets it. It bypasses `patchAgent` (bare `source`) so nothing rewrites the pin.
**Tools:** read only
**When to use:** Comparing screenshots, identifying visual regressions, analyzing canvas/WebGL output, triaging UI bugs. Also used for:
- **Comparative analysis** — current vs reference image, systematically comparing regions and element positions
- **Batch analysis** — screenshot sequences (e.g., exploration steps), checking consistency and flagging regressions between steps
- **Automated dispatch** — called programmatically by the main agent's QA workflow (e.g., the `e2e-manual-qa` skill's vision-qa integration protocol)

**Output:** Structured JSON with verdict (pass/fail/uncertain), confidence score, issues with severity and suggested next checks. Verdicts drive automated pass/fail decisions, so severity must be precise.

**History:** Briefly removed Jul 2026 (commit 690cf86, including its bespoke `patchVisionQa` Vertex rewrite for macOS/cloudbox), then reinstated as API-key-only on the two hosts that can auth it directly.

## Host-correct model routing (`patchAgent`)

Agent files are checked in with `anthropic/` model pins, but not every host can
reach the first-party `anthropic/` provider. `patchAgent` in
`users/dev/opencode-config.nix` rewrites the pin at deploy time so each host
lands on a model it can actually call:

- **sonnet-5 → Gemini 3.7 Flash** on macOS + cloudbox (the cheap plan-execution
  / research subagents: implementer, spec-reviewer, code-reviewer, librarian).
- **opus-4-N → `google-vertex-anthropic/claude-opus-4-N@default`** on **cloudbox
  only**. Cloudbox has no working first-party `anthropic/` auth (it routes
  Anthropic through Vertex/ADC), so an opus agent left pinned to
  `anthropic/claude-opus-*` reaches an unusable provider and the model loop dies
  with an **empty response** — the silent failure that hit oracle.
  devbox keeps the direct pin (its working primary via TeamClaude);
  macOS is left as-is.
- **fable-N → `google-vertex-anthropic/claude-fable-N@default`** on **cloudbox
  only**, for the same auth reason. This is the branch that actually fires today
  (oracle-fable, adversarial-reviewer-fable); the opus branch above is currently
  dormant since no shipped agent pins opus. Both **capture the version** rather
  than matching a literal — a literal `claude-fable-5` match against a
  `claude-fable-5-1` pin yields `claude-fable-5@default-1`, a model that does not
  exist and fails at *request* time, not build time.

When adding an Anthropic-pinned agent, pin it to `anthropic/claude-<model>` in
the source file and let `patchAgent` handle cloudbox — do **not** hardcode the
Vertex id, or you regress devbox/macOS.

A sonnet-pinned agent lands on Gemini on macOS/cloudbox, so it also inherits the
MCP tool-schema hazard in the next section — copy the `tools:` denylist when you
add one.

## Gemini rejects some MCP tool schemas (silent empty subagents)

**Symptom.** A subagent on the Gemini tier (implementer, spec-reviewer,
code-reviewer, librarian, vision-qa) returns `state="completed"` with an **empty
`task_result`** and does no work, while `general` and the fable-pinned agents in
the same session work fine. Diagnosed 2026-08-19 as `mono-2l1rq`.

**Cause.** Vertex Gemini validates every `functionDeclaration` and rejects the
**entire request** with HTTP 400 if any tool's JSON schema is non-conforming.
Two shipped MCP servers fail that validation:

| Server | Offending tool | Vertex complaint |
|---|---|---|
| `datadog` | `datadog_analyze_cloud_network_monitoring` | `parameters.queries` sets other fields alongside `any_of` |
| `pagerduty` | `pagerduty_get_incident` | `parameters.query_model` has no `type` |

Anthropic-on-Vertex and OpenAI accept both, which is why only the Gemini tier
dies. Both servers ship `enabled: false`, so this only bites once a session
connects one (`opencode-launch --mcp datadog`, `oc-mcp-enable <ses> pagerduty`)
— and then it bites *every* Gemini turn in that directory, subagent or primary.

**Why it is silent.** opencode stores the provider error on the subagent's
assistant message (`message.info.error`, verifiable in `opencode.db`), but
`TaskTool`'s `runTask` returns
`result.parts.findLast((item) => item.type === "text")?.text ?? ""`
(`packages/opencode/src/tool/task.ts`) and only fails the tool when the
*background job* status is `error` — an assistant-message-level error is not
that. So a hard 400 renders as a successful, empty task. Worth an upstream
issue; nothing in this repo can fix it.

**Our fix.** The Gemini-tier agents deny both tool families in frontmatter
(`assets/opencode/agents/{implementer,spec-reviewer,code-reviewer,librarian,vision-qa}.md`):

```yaml
tools:
  datadog*: false
  pagerduty*: false
```

A `permission:` deny is **not** a substitute — the breakage is in the tool
*declaration* sent to the model, which happens before any permission check.
This is deliberately a denylist of the two known-bad servers, not a blanket MCP
ban: atlassian, slack, notion, rollbar, devcycle, playwright and chrome-devtools
were all tested against Gemini and pass.

**Caching caveat.** Agent definitions are memoized per **directory** in
opencode's `InstanceState` (`packages/opencode/src/agent/agent.ts`), so a
home-manager switch does **not** un-break a directory a running serve has
already served. A fresh directory picks the fix up immediately; an existing one
needs the serve pool restarted (the nightly `reset-workspace` does this).

**Testing a new MCP server against Gemini** (one command, no session needed):

```bash
d=$(mktemp -d); jq --arg m "<server>" '{mcp: {($m): (.mcp[$m] + {enabled: true})}}' \
  ~/.config/opencode/opencode.json > "$d/opencode.json"
cd "$d" && opencode run --model google-vertex/gemini-3.7-flash "Reply with exactly the word: ALIVE"
```

`ALIVE` = compatible. An `Unable to submit request because ...
functionDeclaration ...` error = add that server to the denylist above.

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

1. Create `assets/opencode/agents/<name>.md` with YAML frontmatter (description, mode, model, permission). For Anthropic-pinned agents, pin `anthropic/claude-<model>` and let `patchAgent` route it (see "Host-correct model routing").
2. Add `xdg.configFile."opencode/agents/<name>.md".source = patchAgent "<name>" "${assetsPath}/opencode/agents/<name>.md";` to `users/dev/opencode-config.nix` (route it through `patchAgent`, not a bare `source`, so host model rewriting applies)
3. Apply: `nix run home-manager -- switch --flake .#dev` (devbox), `nix run home-manager -- switch --flake .#cloudbox` (cloudbox), or `darwin-rebuild switch` (macOS)
4. Update this skill with the agent's purpose and rationale
