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
**Model:** claude-sonnet-5-5
**Tools:** webfetch, websearch, codesearch, bash (for `gh`), read/glob/grep
**When to use:** Unfamiliar library, need API docs, want to find how an OSS project handles something.
**Workflow:** Discovery (Exa codesearch/websearch) -> Retrieval (webfetch) -> GitHub (gh CLI). Every claim cites a source.

Depends on `OPENCODE_ENABLE_EXA=1` (set in both home.devbox.nix and home.darwin.nix) to enable the built-in Exa AI-backed websearch/codesearch tools.

### oracle-opus (subagent)
**Purpose:** Read-only strategic technical advisor — architecture, debugging, high-stakes decisions.
**Model:** `claude-opus-5-5` at `variant: high`, pinned in the agent's own source (`assets/opencode/agents/oracle.md`). This is the **default** variant. The `variant: high` line matters: the provider-level default for opus-5-5 is `effort: medium` (`opencode.base.json`), which is right for the primary session and too shallow for an advisor.
**History:** was `oracle-fable` on `claude-fable-5-1` until 2026-09-26; moved to Opus at the user's request and the handle renamed with it, since a suffix naming the wrong model is worse than a rename.
**Second variant — `oracle-astra`:** same prompt body, pinned to `openai/gpt-6-astra`, generated at build time by `mkAstraVariant` from the same source file. On cloudbox it carries an opt-in `CAUTION` in its description, so reach for it **only when explicitly asked**; on devbox it is **the default oracle**. See "The astra twins" below.
**Why the source file has no suffix:** it is named for the agent, because it is the source of two pins.
**Model routing:** host-correct — the source pins `anthropic/claude-opus-5-5`, and on cloudbox and macOS `patchAgent`'s `afterOpus` branch rewrites it to `google-vertex-anthropic/claude-opus-5-5@default`, because neither has a usable first-party Anthropic provider. That rewrite captures the version rather than matching a literal. devbox keeps the direct `anthropic/` pin.
**Tools:** read, glob, grep, bash, webfetch, websearch, codesearch (no write/edit/task)
**When to use:** Stuck after 2+ attempts, architectural decision, need a second opinion. No CAUTION on the description — the orchestrator should reach for it directly.
**Key trait:** Cannot modify files. Gives a recommendation with effort estimate (Quick/Short/Medium/Large) and action plan. Pragmatic minimalism — biases toward simplest solution. Its prompt is written as ethos + judgment (terse, actionable) rather than a rigid rule-list.

### adversarial-reviewer-opus (subagent)
**Purpose:** Skeptical, adversarial review of a **design / plan / approach before it's built** — hunts flaws, wrong assumptions, missing cases, hazards, and better alternatives. Also runs in **pre-PR mode** on a finished diff, where it reviews the thinking behind the change (load-bearing assumptions, failure/rollback/migration cases) rather than its line-level correctness; that dispatch is a standing default, see `shepherding-pull-requests` §Pre-PR Checks step 3.
**Model:** `claude-opus-5-5` at `variant: high`, pinned in `assets/opencode/agents/adversarial-reviewer.md` (was `adversarial-reviewer-fable` / `claude-fable-5-1` until 2026-09-26 — same history as oracle above). The default variant **on cloudbox and macOS**. A second variant `adversarial-reviewer-astra` pins `openai/gpt-6-astra` from the same source; it carries an opt-in `CAUTION` on cloudbox but is the **default on devbox** — see "The astra twins" below.
**Model routing:** host-correct, same as oracle — source pins `anthropic/`, cloudbox gets the Vertex rewrite via `patchAgent`.
**A note on the pre-PR default — it is host-dependent.** `shepherding-pull-requests` dispatches `adversarial-reviewer-opus` on cloudbox and macOS, and `adversarial-reviewer-astra` on devbox. You do not have to work this out: the skill text is rendered per host at deploy time by `users/dev/opencode-skills.nix`, so the copy you load names the right one. What remains banned on every host is **substituting the other twin yourself** because you prefer it — treating a failed dispatch as the review having happened. On devbox, a failed or unavailable astra falls back to the opus twin, and the fallback is announced. On cloudbox and macOS, an unavailable opus means stop and report. The skill says both.
**Tools:** read, glob, grep, bash, webfetch, websearch, codesearch (no write/edit/task)
**When to use:** You have a design or plan and want it pressure-tested *before* writing code; you want the uncomfortable "this is solving the wrong problem" read. No CAUTION any more — reach for it directly.
**Key trait:** Grounds every claim in the actual code/artifact (`file:line`, never fabricates); distinguishes verified findings from suspicions; reports verdict → confirmed-sound → flaws-by-severity → missing cases → concrete recommendations.
**Complements:** oracle is the *advisor* ("what should we do?"); the adversarial reviewers are its skeptic ("here's how that goes wrong"). code-reviewer / spec-reviewer check a *finished implementation* against a spec; the adversarial reviewers check the *design itself* — earlier at plan time, and again pre-PR against the diff, where the question is whether merging would be a mistake rather than whether the code is clean. Their prompt is deliberately ethos-driven (care that the design is correct; judgment over checklist) per the Amanda Askell steer.

### The astra twins (`oracle-astra`, `adversarial-reviewer-astra`)

**What they are:** byte-identical prompt bodies to their `-opus` counterparts, pinned to `openai/gpt-6-astra` instead (and with the source's `variant: high` line dropped — that names an Opus effort tier; astra carries its own `high` default at provider level). Generated at build time by `mkAgentVariant` / `mkAstraVariant` in `users/dev/opencode-config.nix` from the same source file, so the prompt has one source of truth and the twins cannot drift apart.

**What they are for:** a genuinely different model's read on the same question. Both agents exist to be a second opinion, and a second opinion from the same model family is worth less than one from outside it. Reach for the astra twin when the opus answer feels like it might be a house style rather than a conclusion.

**They are opt-in, deliberately — except on devbox.** The generated `description:` carries a `CAUTION` telling the orchestrator to default to the `-opus` handle. Do not auto-select them.

The exception: **on devbox, both astra twins are the defaults** — `adversarial-reviewer-astra` for every adversarial review (plan-time and pre-PR), `oracle-astra` for every oracle consult. `mkAgentVariant` takes a `caution` parameter (`users/dev/opencode-config.nix`, `devboxAdversarialCaution` / `devboxOracleCaution`) and devbox passes an inverted sentence for each. Cloudbox's twins keep the opt-in CAUTION. (The reviewer was inverted 2026-09-19; the oracle followed 2026-09-28 after a devbox session, told "oracle-opus", read oracle-astra's opt-in CAUTION and could not tell astra was intended.) **The `-opus` twin is the base default on every host, and devbox's astra preference falls back to it.** When astra is not listed, `astra-probe` says DOWN, or the dispatch errors or returns empty, the caller dispatches `-opus` (or `-fable` on a serve that predates the 2026-09-28 rename) and says so in one clause. A dead codex-lb therefore degrades devbox to opus rather than blocking it. Since 2026-10-01 that failure is loud, not a silent hang: the `subagent-failure` plugin refuses the dispatch when `astra-probe` says DOWN, turns a child's API error into a `<task_error>` naming the `-opus` twin, and `openai.options.headerTimeout` bounds a pre-header codex-lb stall. See `docs/plans/2026-10-01-reviewer-fail-fast-design.md`. There is no reverse fallback: cloudbox never falls back from opus to astra. The fallback was stop-and-report until 2026-09-28.

**Devbox and cloudbox only.** They are gated to the hosts where the codex-lb subscription model catalog is injected into opencode's `openai` provider — which is *not* the same as the hosts that run codex-lb. macOS runs codex-lb (launchd flavor in `home.darwin.nix`) and has its `openai` baseURL redirected to it, but never gets the catalog, so `gpt-6-astra` is not selectable there. Rather than ship a handle that always fails, the twins are simply absent on macOS.

**They can be present but dead.** Even where deployed, `openai/gpt-6-astra` is only reachable while `codex-lb.service` is up *and* codex-lb's upstream model-catalog refresh is healthy. astra has a `minimal_client_version` of 0.153.0 and codex-lb's hardcoded fallback Codex version is 0.144.0, so if codex-lb's GitHub/npm version lookup fails, astra silently disappears from its catalog. A dead astra fails at **request** time, not build time. Check with:

```bash
curl -s localhost:2455/v1/models | jq -r '.data[].id' | grep astra
```

**Cost:** the ChatGPT subscription is flat-rate, so an astra call costs nothing on the aigateway ledger — unlike an opus call, which is a real line item. It spends 5h/weekly subscription quota instead, visible on codex-lb's own dashboard at `127.0.0.1:2455`. That makes astra the *cheaper* second opinion in dollar terms; it is not the reason to prefer it, but it is a reason not to avoid it.

### The fable twins (`oracle-fable`, `adversarial-reviewer-fable`) — cloudbox only

Same prompt bodies, pinned to `claude-fable-5-1`: the model these agents ran on before the 2026-09-28 move to Opus. They are generated by `mkFableVariant` in `users/dev/opencode-config.nix` and rewritten to `google-vertex-anthropic/claude-fable-5-1@default` by `patchAgent`. That provider entry carries `effort: high`, so the source's dropped `variant: high` loses nothing. They are **opt-in on cloudbox**: the description carries the default CAUTION, so dispatch them only when the user asks for fable. Devbox and macOS don't deploy them.

**Name overlap with stale serves.** A serve started before the rename lists the *old default* `-fable` handles (no CAUTION) and no `-opus`. The rule in the user-level `AGENTS.md` is this: if `-opus` is listed, `-fable` is the opt-in twin; if `-opus` is absent, `-fable` is the default slot.

**If these twins are ever removed, delete `mkAgentVariant` with them.** The builder was deleted once before (2026-09-01) on the explicit reasoning that an unevaluated nix builder gets no build coverage and rots silently — which is how a literal `claude-fable-5` bug survived in the live rewrite path. That reasoning still holds; the builder is only safe to keep while something evaluates it.

### vision-qa (subagent — devbox only)
**Purpose:** Visual QA analyst — analyzes screenshots and UI renders.
**Model:** `google/gemini-3.8-flash` + `variant: high` — direct Google Generative AI API, authed via `GOOGLE_GENERATIVE_AI_API_KEY` / `GEMINI_API_KEY` (sops `gemini_api_key`). **API-key-only by design: no Vertex.** The agent is therefore deployed only on devbox (the API-key host); macOS has no Gemini API key (Vertex ADC only) and cloudbox disables the direct `google` provider, so neither gets it. It bypasses `patchAgent` (bare `source`) so nothing rewrites the pin.
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

- **sonnet-N → Gemini 3.8 Flash** on macOS + cloudbox (the cheap plan-execution
  / research subagents: implementer, spec-reviewer, code-reviewer, librarian).
- **opus-N → `google-vertex-anthropic/claude-opus-N@default`** on **cloudbox
  and macOS**. Cloudbox has no working first-party `anthropic/` auth (it routes
  Anthropic through Vertex/ADC), and macOS hides the `anthropic` provider now
  that cfp fronts Claude, so an opus agent left pinned to
  `anthropic/claude-opus-*` reaches an unusable provider and the model loop dies
  with an **empty response** — the silent failure that hit oracle.
  devbox keeps the direct pin (its working primary via TeamClaude). This is the
  branch that fires today (oracle-opus, adversarial-reviewer-opus).
- **fable-N → `google-vertex-anthropic/claude-fable-N@default`**, same hosts,
  same reason. Fires for cloudbox's opt-in `oracle-fable` /
  `adversarial-reviewer-fable` twins (below). Both branches **capture the version** rather than matching a
  literal — a literal `claude-fable-5` match against a `claude-fable-5-1` pin
  yields `claude-fable-5@default-1`, a model that does not exist and fails at
  *request* time, not build time.

No branch matches an `openai/` pin, and that is correct rather than an omission:
codex-lb serves the same model id on every host it runs on, so the
`-astra` twins pass through `patchAgent` unmodified.

Their build output is nevertheless **not** identical across the two hosts, for a
reason upstream of `patchAgent`: both devbox astra twins get an
inverted `caution` from `mkAgentVariant` (astra is the default there). If you
are diffing store paths to check a change, that one description line per twin
is the expected difference.

When adding an Anthropic-pinned agent, pin it to `anthropic/claude-<model>` in
the source file and let `patchAgent` handle cloudbox — do **not** hardcode the
Vertex id, or you regress devbox/macOS.

A sonnet-pinned agent lands on Gemini on macOS/cloudbox, so it also inherits the
MCP tool-schema hazard in the next section — copy the `tools:` denylist when you
add one.

## Gemini rejects some MCP tool schemas (silent empty subagents)

**Symptom.** A subagent on the Gemini tier (implementer, spec-reviewer,
code-reviewer, librarian, vision-qa) returns `state="completed"` with an **empty
`task_result`** and does no work, while `general` and the opus-pinned agents in
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
cd "$d" && opencode run --model google-vertex/gemini-3.8-flash "Reply with exactly the word: ALIVE"
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
