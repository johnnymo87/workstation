Goose subagents: tool isolation, read-only reviewers, and migration from OpenCode

Research against goose upstream documentation, GitHub issues, and merged changes as of October 20, 2026.

Executive conclusion

Your instinct to use recipes is correct, but I would not use model-supplied delegate.extensions as your security boundary.

The clearest upstream direction is:

Custom agent .md files: reusable personas and model preferences.

Recipes/sub-recipes: reusable task definitions with settings, provider/model selection, and extension configuration.

available_tools: declarative tool-surface restriction, but only at the tool level.

PreToolUse hooks: interception and policy enforcement, with important failure-mode considerations.

OS-level isolation: the appropriate final boundary when a reviewer must be incapable of modifying a shared worktree.

This is supported by goose's own custom-agent documentation, which explicitly distinguishes roles from recipes and directs users to recipes when they need a specific extension set. The maintainer response in issue #12921 independently points toward hierarchical recipes for per-phase tool limits. 
GitHub
+1

I would implement your migration using this architecture:

Single source of agent definitions

Roles, prompts, provider twins, allowed capabilities

OpenCode

Markdown + permission blocks

goose

Named recipes + extension manifests

Reviewer / Oracle

Read-only tool set + restricted shell + read-only filesystem

Implementer

Writable tool set + explicit commit permissions

The most important distinction is between a tool restriction and a capability boundary. Removing write and edit does not produce a read-only agent if it still has an unrestricted shell. Similarly, filtering extension names is not a hard role boundary when the model itself decides which filter to pass.

Current status of the key upstream changes

Change

	

Verified status

	

Consequence




#12802

	

Merged October 13

	

Subagents inherit parent hooks, mode, and approval handling.




#12938

	

Merged October 16

	

Delegated recipes can use their declared extensions.




#12430

	

Still open when checked

	

Unmatched explicit extension filters are not yet protected by that proposed fail-closed change.




#12921

	

Open discussion

	

Maintainer suggests hierarchical recipes for scoped tool limits.

GitHub
+3

For your fork: backporting #12802 and #12938 would align with the current upstream direction. However, neither change alone makes your read-only reviewers safe to run an unrestricted shell against a shared writable repository.

1. What is the recommended way to define named, restricted subagents?
Recipes are the better match for your requirements

The official Subagents guide presents direct delegation for one-off tasks and recipes for reusable, structured agents. The Subrecipes guide emphasizes composability, parameters, and independent testing, although it still labels subrecipes experimental. 
GitHub
+1

Capability

	

Agent .md

	

Recipe / sub-recipe




Reusable name

	

Yes

	

Yes




Instructions/persona

	

Yes

	

Yes




Preferred model

	

Yes

	

Yes




Explicit provider

	

Not in documented frontmatter

	

settings.goose_provider




Extension selection

	

No

	

Yes




Per-extension tool allowlist

	

No

	

Yes




Parameters

	

No

	

Yes




Reusable task orchestration

	

Indirectly

	

sub_recipes




Shell-command permissions

	

No

	

Not natively




OS-level isolation

	

No

	

Requires external setup

Goose's documented agent frontmatter is indeed limited to name, description, and model; the docs explicitly say agent files don't define MCP server lists. 
GitHub
+1

This gives you a practical convention:

Use recipes as your executable role definitions. Optionally generate .agents/agents/*.md as lightweight discovery and compatibility wrappers, but never rely on their frontmatter for permissions.

A reviewer recipe could look like this:

YAML

version: "1.0.0"
title: "Code Reviewer"

description: >
  Review the current implementation without modifying files.

settings:
  goose_provider: gcp_vertex_ai
  goose_model: YOUR_REVIEWER_MODEL
  max_turns: 20

extensions:
  - type: platform
    name: analyze

  - type: builtin
    name: developer
    available_tools:
      - tree
      - read_image

  # Custom, independently implemented MCP server.
  # This is not an upstream goose platform extension.
  - type: stdio
    name: review-shell
    cmd: /nix/store/EXAMPLE/bin/review-shell-mcp
    args: []
    available_tools:
      - git_diff
      - git_log
      - git_show
      - ripgrep
      - run_test_profile

instructions: |
  You are a read-only code reviewer.
  Identify correctness, security and maintainability
  problems. Never alter the repository.

prompt: |
  Review the requested changes and return findings
  with file references, severity and rationale.


This is an illustrative recipe design, not a tested drop-in configuration. The review-shell extension and its tools are components you would implement, and the model identifier must be replaced. Validate the built-in developer tool filter against your fork's exact extension naming and configuration schema.

The recipe deliberately omits summon, shell, write, and edit.

In contrast, your implementer recipe can explicitly select the developer tools it needs, including shell, write, edit, and tree.

Note that an available_tools list is an allowlist; leaving it empty is not the same as denying everything. The recipe reference says unspecified tools are all available, and issue #7808 explicitly documents the empty-list behavior. 
GitHub
+1

A noteworthy upstream experiment: a dedicated reader

I found something particularly relevant that goes beyond your initial research.

PR #7160 — Add reader platform extension for sandboxed delegates proposed exactly the capability-minimization design you are considering.

Its reader platform extension exposed a single tool for file reading and directory listing, with no shell, write, or network capabilities. The author explicitly described using it for delegated agents processing untrusted content, so prompt injection could not cause them to take actions.

The PR was closed without merging on March 26, 2026. 
GitHub
+1

This matters for two reasons.

First, it demonstrates that purpose-built restricted extensions have been seriously explored by goose contributors. Second, there is no reason to assume a standard reader platform extension exists in your version.

The proposed reader would not meet your full needs anyway: it provides file inspection but cannot run Git commands, ripgrep, or tests.

For your use case, a comparable read-only repository-tool extension would be more useful.

2. Building a reviewer that can inspect and test but never mutate the worktree

There are three distinguishable approaches.

A. Dedicated read-only MCP tools

Preferred capability design

Expose specific operations such as git_diff, git_log, rg, and vetted test profiles, rather than arbitrary shell access. Never expose write, edit, or unrestricted shell.

B. Read-only filesystem sandbox

Strongest worktree protection

Run reviewer subprocesses inside an OS-enforced environment where the shared repository is mounted read-only and writable paths are private or explicitly limited.

C. PreToolUse shell-policy hook

Defense in depth

Inspect shell commands and deny policy violations. Useful for accidents and simple cases, but not as strong as restricting the underlying execution capabilities.

I did not find an established, maintained goose community read-only shell MCP server or canonical Git-command blocking hook that could be recommended as a standard solution. The material I found documents primitives and proposals rather than an accepted full implementation.

The critical distinction: a Git denylist does not make a shell read-only

Consider your current OpenCode policy. Blocking git stash, git checkout, and git reset is valuable, but bash: "*": allow still permits many write mechanisms, such as:

Bash
echo changed > src/main.rs
python -c 'open("src/main.rs", "w").write("changed")'
sed -i 's/old/new/' src/main.rs
git -c alias.x='!some-command' x
make some-target

Even apparently read-only programs can invoke configurable helpers. Test runners and build tools routinely write caches, snapshots, generated artifacts, lockfiles, or test fixtures.

Therefore, a shell command blacklist cannot establish a general filesystem read-only guarantee.

If your rule is literally that reviewers must be unable to mutate a shared working tree, use kernel-enforced filesystem permissions or isolation. An MCP command allowlist is valuable, but must not be the sole protection if arbitrary test code can execute.

My suggested NixOS pattern

Use a small launcher built around Bubblewrap, systemd sandboxing, or an equivalent mount-namespace mechanism. The important property is not which sandbox program you choose, but the resulting access controls.

For example, your trusted launcher can establish:

Plain text
/shared/repo             read-only bind mount
/sandbox/home            private, writable
/sandbox/tmp             private, writable
/sandbox/cache           private, writable
/network                 disabled except when required
/credentials             not mounted by default

For tests that generate build artifacts, give them a private scratch area or overlay whose writes cannot reach the shared repository.

One nuance is important for pre-PR reviewers: do not blindly use a clean git worktree if you need to inspect uncommitted changes. A conventional extra worktree tracks a committed checkout and does not automatically include another session's uncommitted state.

A read-only bind mount or a carefully constructed overlay lets the reviewer observe those changes while preventing writes to the underlying working tree.

You must also protect against:

Git commands writing to .git or a common Git directory outside the mounted worktree.

git -c, environment-controlled Git helpers, aliases, pager execution, hooks, and configured external diff drivers.

Build processes that use host-accessible paths outside the repository.

Filesystem access through sockets, external MCP tools, or writable mount points that reach the host.

Other shared mutable resources, including caches and user configuration.

If a command must run in the sandbox, execute the actual command there—not merely a shell that eventually launches an unrestricted host process.

A different Unix UID with no write permission on the repository can be sufficient for a narrower threat model, but only if it has no route back to the owner's credentials or writable resources.

A test runner requires special treatment

For your constraint set I would define separate capability classes:

Capability

	

Allowed mechanism




git diff, log, show, blame

	

Purpose-built tools or sandboxed commands




rg, grep, file reads

	

Purpose-built tools or sandboxed commands




Tests that write temporary files

	

Sandbox with private scratch




Tests that expect in-tree writes

	

Private overlay/snapshot




Arbitrary host shell

	

Not allowed for reviewer




Git mutation of the shared tree

	

OS boundary denies

This is more robust than trying to enumerate every unsafe Git subcommand.

3. Is delegate.extensions a security boundary?

Not when the calling model controls it. I would treat it as a tool-selection mechanism that can participate in enforcement, not as an authorization decision.

The official docs say extension selection can restrict capabilities for security, focus, or performance. That establishes its intended use, but does not guarantee that a model-driven selection implements a fixed role policy. 
GitHub

Your suggested instruction:

Plain text
For reviewers, always call delegate with:
extensions: ["analyze"]

has several failure modes.

Failure

	

Result / risk




Model omits extensions

	

Parent extensions are inherited




Model supplies a wider set

	

Reviewer receives more tools




Model names the wrong extension

	

Selection may behave unexpectedly




Agent .md lacks tool policy

	

No intrinsic role-specific restriction




Recipe invocation behaves differently

	

Different tool inventory from the expected one




Parent can enable other extensions

	

Tool scope can expand through another path

The open PR #12430 specifically addresses unmatched filters, supporting your concern that this has not been a universally fail-closed operation. Its proposed semantics are:

Omitted filter: inherit.

Empty filter: expose no extensions.

Explicit unknown extension: return an error.

Mixed valid/invalid filters: return an error rather than partially applying them.

The PR was still open on October 20. 
GitHub

Why #12938 is significant

Before #12938, a delegated recipe could declare extensions but still inherit the parent's extension set. The merged change makes the recipe's declarations effective, while preserving inheritance when the recipe does not declare its own list. It also honors explicit delegation filters. 
GitHub

That is a major improvement, but I would still distinguish two things:

A recipe specifies the desired capabilities.

A trusted execution layer determines the maximum permitted capabilities.

For a role-specific boundary, the second layer should take precedence over any model-supplied request.

The policy should be:

𝑇
e
f
f
e
c
t
i
v
e
=
𝑇
r
e
q
u
e
s
t
e
d
∩
𝑇
r
o
l
e
∩
𝑇
e
n
v
i
r
o
n
m
e
n
t
T
effective
	​

=T
requested
	​

∩T
role
	​

∩T
environment
	​


Where 
𝑇
T denotes the set of accessible tools or capabilities.

A reviewer may request fewer tools, but never more than its policy allows.

If you patch your fork, I would add a fixed role-policy lookup during delegation:

Plain text
delegate receives recipe/agent selection
          |
          v
resolve trusted role identifier
          |
          v
load role policy from deployed configuration
          |
          v
validate model/provider/tool selection
          |
          v
reject unauthorized extensions/tools
          |
          v
create restricted subagent session

In particular, do not allow the model to assert its own trusted role using an unverified argument. Resolve the role through a trusted recipe registration or trusted dispatch wrapper.

This is the patch I would prioritize beyond #12802 and #12938. It would be relatively small in concept and align with goose's increasingly recipe-oriented configuration model.

An important subtlety about dynamic extensions

Goose also supports extension-management capabilities that can enable or disable extensions at runtime. Those mechanisms need to respect the same role ceilings. Otherwise an agent can start restricted and later acquire additional tools.

The Extension Manager documentation describes the dynamic management interface. 
GitHub

For restricted roles, I would not expose a general extension-management tool, and would enforce the cap in the extension manager itself if dynamic activation is possible through other paths.

4. Can PreToolUse hooks distinguish the originating subagent?
Session identity: yes. Role identity: not directly documented.

The current hooks reference defines a session_id in hook payloads, as well as tool_name, tool_input, and working_dir.

Example:

JSON
{
  "event": "PreToolUse",
  "session_id": "abc-123",
  "matcher_context": "shell",
  "tool_name": "shell",
  "tool_input": {
    "command": "git diff --stat"
  },
  "working_dir": "/path/to/project"
}

It does not document fields such as:

Plain text
role
agent_name
recipe_name
recipe_path
parent_session_id
is_subagent

as standard PreToolUse payload fields. The docs also specifically state that SubagentStart and SubagentStop events are not currently emitted. 
GitHub
+1

PR #12802 means those hooks now run for subagents, but sharing the parent's Agent and its hook configuration is not equivalent to exposing the child's role to each hook.

Recommended patch: expose trusted identity metadata

Given that you control your fork, I would extend hook events to include immutable, goose-generated metadata:

JSON
{
  "event": "PreToolUse",
  "session_id": "child-456",
  "parent_session_id": "parent-123",
  "subagent": {
    "role_id": "code-reviewer",
    "recipe_id": "reviewer-vertex",
    "policy_id": "read-only-v1"
  },
  "tool_name": "shell",
  "tool_input": {
    "command": "git diff --stat"
  }
}

This is a proposed schema extension, not an upstream payload.

The role and policy identifiers should come from the trusted delegation setup rather than prompts or model-generated labels.

You could alternatively maintain a session-to-role map in the relay or a trusted server-side registry, but the mapping must exist before the first subagent tool call. Inferring it from a prompt, working directory, or session naming convention would be unreliable.

For a security-sensitive hook, unknown sessions should receive the restrictive policy, not an implementer's privileges.

Hooks now have a useful fail-closed option

There is also an important detail in the current upstream hook documentation worth highlighting.

PreToolUse command hooks support:

JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "^(shell|write|edit)$",
        "hooks": [
          {
            "type": "command",
            "command": "${PLUGIN_ROOT}/scripts/check-policy.sh",
            "on_failure": "block"
          }
        ]
      }
    ]
  }
}

With on_failure: "block", a matching tool call is denied if the hook cannot execute, times out, or otherwise fails to produce a usable decision. By default, hook failures allow the call to proceed.

This option is documented upstream, but you must confirm that your v1.54.0 fork supports it before relying on it. 
GitHub

For your implementation, I would write a hook that:

Resolves trusted role identity from the session.

Blocks write and edit for review roles.

Blocks unrestricted shell for review roles unless it is routed through an approved sandbox mechanism.

Defaults to denial on unknown role or malformed input.

Emits an explicit policy-denial result and an audit record.

Be careful with hook matchers: the current documentation states that developer tools such as shell, write, and edit use their bare names, not developer__shell. Also, only PreToolUse and Stop can actually block; BeforeShellExecution is observation-only. 
GitHub

Even a correct hook will not turn unsandboxed test execution into a safe operation. It is an authorization layer, not a filesystem boundary.

5. Migrating Claude Code / OpenCode agent definitions

I did not find a recognized or actively maintained OpenCode-to-goose role-permission converter in the upstream docs, GitHub issues, or publicly indexed examples searched. I also did not find evidence of an active upstream effort to support full Claude Code tools: or disallowedTools semantics directly in agent Markdown frontmatter.

That is a limitation of the public evidence, not proof that no community converter exists.

For your setup, I would generate both formats from a small intermediate representation (IR), rather than treating OpenCode YAML as the canonical schema.

Suggested intermediate representation
YAML

id: adversarial-reviewer
description: Adversarial design and diff reviewer
prompt_file: prompts/adversarial-reviewer.md

capabilities:
  filesystem: read_only
  shell: restricted
  tests: sandboxed
  delegation: false
  network: documentation_only
  git_mutation: false

models:
  preferred:
    provider: gcp_vertex_ai
    model: YOUR_STRONG_MODEL
  fallback:
    provider: YOUR_OPENAI_COMPAT_PROVIDER
    model: YOUR_FALLBACK_MODEL

limits:
  max_turns: 25


Generate:

Output

	

Purpose




.opencode/agents/*.md

	

OpenCode model and permissions




Goose recipes/*.yaml

	

Provider, model, instructions, extensions




.agents/agents/*.md

	

Optional discovery/compatibility personas




Goose role-policy manifest

	

Trusted capability ceiling




Sandbox profile

	

Filesystem and process restrictions




Policy tests

	

Verify denied and permitted operations

I would deliberately avoid converting bash: "*": allow into goose's unrestricted shell tool for read-only agents. That would preserve the syntactic permission but not the security invariant you care about.

The compiler should instead translate the intended capability into restricted shell tools plus a sandbox.

It should also reject permissions that cannot be represented safely, rather than silently dropping them.

Provider and model twins

Goose supports model/provider selection in recipe settings. The documented precedence is:

recipe settings
>
subagent environment defaults
recipe settings>subagent environment defaults

The recipe docs explicitly state that goose_provider and goose_model take precedence over GOOSE_SUBAGENT_PROVIDER and GOOSE_SUBAGENT_MODEL. 
GitHub

I would generate twin recipe files:

Plain text
recipes/
  oracle-vertex.yaml
  oracle-openai.yaml
  reviewer-vertex.yaml
  reviewer-openai.yaml
  implementer-vertex.yaml
  implementer-openai.yaml

Both twins should reference the same prompt and share a policy identifier, with only the provider and model differing.

For failover, I recommend putting the decision in your relay or a trusted dispatcher:

Plain text
requested role: oracle
    |
    +-- Vertex available? --> oracle-vertex
    |
    +-- otherwise ---------> oracle-openai

I found no documented, atomic, built-in fallback chain for a recipe's goose_provider and goose_model. The recipe format documents a selected provider/model, not an ordered list of providers.

I would therefore implement fallback in your existing relay, where you can preserve the role's security policy while switching provider configurations.

One caution: only retry automatically before any side-effecting tool execution has occurred, or after explicitly determining that retries are safe. Restarting an implementer halfway through a failed run could repeat edits or commits.

6. ACP approval forwarding, smart_approve, and provider overrides
What #12802 actually guarantees

The PR description is quite specific:

Subagents use the parent's Agent.

They start in the parent's goose mode.

Their confirmation requests are forwarded into the parent's turn.

MCP elicitations are forwarded.

Answers submitted on the parent session are delivered to the waiting child.

Goose checks the child's recorded parent_session_id when routing an answer.

In Approve mode, even a subagent's final output can require approval. 
GitHub

This is a substantial security improvement over the behavior you observed in v1.54.0.

However, approval forwarding is not the same as demonstrating correct behavior in every ACP transport and client implementation.

I did not find a conclusive end-to-end test for your precise configuration:

Plain text
custom ACP-over-HTTP/SSE client
    -> goose serve
       -> summon.delegate
          -> child tool permission request
             -> parent ACP session/request_permission
                -> custom relay response
                   -> child resumes

My expectation, based on the merged PR, is that the request reaches the parent's normal permission-handling path. But I would not state that your client is guaranteed to receive exactly the expected session/request_permission sequence without testing it.

Tests I would run before enabling summon

Suggested acceptance checklist

0/10 verified

Child hook enforcement

Delegate a reviewer that attempts write, edit and shell mutation. Verify policy denial before execution.

Approval request forwarding

Delegate a tool call requiring confirmation. Verify the parent ACP session receives it.

Approval denial

Deny a child tool call in the relay. Verify that the child cannot execute it.

Concurrent requests

Start two delegated approvals simultaneously and check response routing.

Client disconnection

Disconnect the relay while approval is pending. Verify no unattended execution.

smart_approve behavior

Exercise safe and risky shell commands with a delegated child.

Recipe tool scoping

Attempt delegation with omitted, empty, unknown and widened extension filters.

Subagent cancellation

Cancel an active child and verify extension, provider and pending-approval cleanup.

Provider fallback

Make the primary provider fail and verify policy remains unchanged on retry.

Shared-tree immutability

Run reviewer tests that deliberately attempt writes, git mutation and symlink escapes.

An additional reason to test concurrency is that review comments on #12802 identified a potential ambiguity in using provider-generated tool-call IDs to route concurrent confirmations. Later cleanup concerns were also raised and addressed during review. The final merged implementation should be evaluated rather than assuming those earlier observations still describe current defects. 
GitHub

smart_approve is not a read-only policy

GOOSE_MODE supports auto, approve, chat, and smart_approve, as documented in the configuration guide. 
GitHub

Do not use smart_approve as the reviewer restriction. Approval decisions are intended to control execution, not establish immutable filesystem permissions.

A dedicated reviewer tool could operate safely in auto mode if it genuinely has no capability to mutate the protected resources. Conversely, smart_approve does not make an unrestricted shell intrinsically safe.

For unattended recipes, policy decisions should be deterministic. If execution requires interactive approval and no client can answer, fail the operation rather than trying to turn approval into automatic authorization.

Provider-specific request parameters and caching

I found evidence of configurable provider-specific request behavior, but not enough to establish that every setting propagates correctly through subagent provider overrides.

The upstream provider documentation discusses prompt caching and provider-specific request parameters. It also documents automatic Anthropic prompt caching for certain provider integrations, but its listed providers do not establish the same behavior for gcp_vertex_ai. 
GitHub
+1

For your Vertex/OpenAI-compatible twins, verify the following separately:

Concern

	

What to verify




Provider selection

	

Child actually uses recipe provider




Model selection

	

Child sends configured model identifier




Thinking/reasoning

	

Correct provider-specific request parameters




Prompt caching

	

Actual cache markers and usage accounting




Credentials

	

Child uses appropriate provider configuration




Fallback

	

No loss of role-specific tool restrictions




Request limits

	

Correct max tokens, timeout, and context handling

I would instrument provider request construction in your fork rather than rely only on the model identifier displayed in the TUI.

There is also a relevant unattended-recipe issue, #11408, reporting that stdio MCP tools were not exposed correctly in certain scheduled/background recipe runs. That is not proof of a problem with your goose run --recipe workflow, but it reinforces the need to test MCP tool availability separately in interactive and unattended modes. 
GitHub

7. Recommended implementation for your fork

Given your declarative NixOS deployment and willingness to maintain a small patch, I would divide the work into two stages.

Stage 1: get a safe, usable migration

Backport #12802 to restore hooks, modes, and approvals in subagents.

Backport #12938 to make recipe-declared extension lists effective during delegation.

Adopt recipes as the primary named-role artifacts and generate them alongside OpenCode agents.

Implement review-shell as a minimal MCP server exposing only vetted read commands and sandboxed test execution.

Deny reviewer access to unrestricted developer shell, write, and edit.

Run reviewer subprocesses with read-only access to the shared worktree, including protection of Git metadata.

Test both interactive ACP delegation and unattended recipes.

This gets you structurally restricted reviewers without requiring goose to understand OpenCode permission syntax.

Stage 2: make role security first-class

I would then maintain a focused fork patch adding:

Rust
// Illustrative design, not existing goose API.

struct RolePolicy {
    role_id: String,
    allowed_extensions: Vec<String>,
    allowed_tools: Vec<String>,
    sandbox_profile: String,
    allow_delegation: bool,
}

At delegation time:

Rust
// Illustrative pseudocode.

let role = resolve_trusted_role(&delegation)?;
let policy = policy_store.get(&role)?;

let requested = resolve_requested_tools(&delegation)?;
let effective = intersect(requested, policy.allowed_tools);

ensure_no_unauthorized_capabilities(&requested, &policy)?;

create_subagent_session(
    delegation,
    effective,
    policy.sandbox_profile,
)?;

The key implementation details are:

The caller must not be allowed to supply an arbitrary trusted role_id.

Omitted extension filters must never widen an explicitly restricted role.

Extension activation after creation must respect the role policy.

The cap must be enforced during tool dispatch, not only during tool-schema generation.

A child must not be able to delegate to a more privileged role unless trusted policy allows that transition.

Hook metadata should include the resolved role and policy.

Policy violations should be logged and returned as actionable errors.

These features are not all present upstream; they are the changes I would make rather than attempting to expand agent Markdown frontmatter immediately.

What should be shared with OpenCode?

Share role intent, capability definitions, prompts, and tests. Generate the platform-specific authorization format.

You may eventually discover that goose offers a better security boundary than your current OpenCode setup, because OS-enforced reviewer isolation is stronger than a Git-command denylist.

8. What the community evidence actually establishes

There is a difference between a documented feature, a maintainer recommendation, and a community-wide standard.

Claim

	

Evidence strength




Recipes are intended for reusable tool-scoped tasks

	

Strong: official documentation




Custom agent Markdown is a lightweight role/persona format

	

Strong: official documentation




Maintainers favor hierarchical recipes for scoped phases

	

Moderate: explicit maintainer reply




Tool-restricted reader delegates have been explored

	

Strong: closed PR #7160




Hooks now run within subagents

	

Strong: merged PR #12802




Recipe-declared extensions now apply on delegation

	

Strong: merged PR #12938




Standard goose read-only shell with safe Git commands exists

	

Not established




Community has a canonical OpenCode permissions converter

	

Not established




Hooks expose recipe/role identifiers directly

	

Not established




ACP forwarding works correctly with your custom client

	

Requires E2E validation




Built-in ordered provider fallback for named recipes exists

	

Not established

The evidence is primarily official documentation and maintainer GitHub activity. I did not find sufficient Discord or popular third-party recipe-repository evidence to claim a broader community consensus than that.

Bottom line

For your exact requirements, I would not recreate OpenCode's task-tool permission model solely with summon.delegate arguments.

The architecture I would choose is:

Named sub-recipes for role configuration, an enforced role-policy cap for authorization, and a read-only execution sandbox for repository safety.

Keep .agents/agents/*.md for interoperability, not security. Use available_tools to minimize exposed capabilities. Use hooks as defense in depth and for auditability. Retain provider twins through generated recipes, with failover controlled by your relay.

The smallest durable upstream-oriented change worth proposing is probably trusted policy identity and capability ceilings on delegated recipe sessions, rather than another Markdown permission syntax. It addresses the missing primitive beneath several of your questions: goose currently has ways to request narrower tools, but not a documented immutable reviewer role boundary.

That distinction is the core architectural issue in your migration.