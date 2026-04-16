My take: start with Approach 1, but do not make it purely prompt-guided and open-ended. Make it a hybrid retrieval pipeline: a small deterministic context bundle prepared by lgtm before the OpenCode session starts, plus a constrained “go get more if needed” phase inside the agent. The current crop of production AI review tools that publicly describe their stack do not rely on raw long-term memory alone; they combine multiple context types on purpose: prior PR history, repo-wide structure or code graph, team rules, linked issues/docs, and tool outputs like linters/security checks. CodeRabbit describes semantic retrieval over code/tests/prior PRs plus team guidelines and tool signals; Qodo describes PR-history relevance and rule discovery from repo/PR history; Greptile describes a full code graph for related-file reasoning. 
docs.coderabbit.ai
+4
coderabbit.ai
+4
docs.coderabbit.ai
+4

1. Architecture

Yes, Approach 1 is a reasonable starting point. I would not jump straight to a memory server. The fundamental reason is that you have not yet established that retrieval is the main bottleneck rather than prompt structure, rule grounding, or evaluation. Graphite’s public materials emphasize acceptance/upvote/downvote and real workflow evaluation; CodeRabbit’s evaluation post also argues that real-world pilot behavior is more informative than abstract benchmarks. That matches your situation: you need to validate whether more context actually increases acceptance rate and trust on your repos. 
Braintrust
+1

But I would change the unit of design from “memory” to review context pipeline:

lgtm builds a context packet before launching OpenCode.

OpenCode reviews with that packet and may do targeted follow-up retrieval.

After review, a tiny summarizer updates repo-level review knowledge.

That is still basically Approach 1, but better than telling the agent “figure out what context you need.” OpenCode already supports plugins, custom tools, session lifecycle events, and compaction hooks, so you have room to add structure later without changing runtimes. 
OpenCode
+1

What I would precompute outside the model for every PR:

linked issue / PR description / labels

changed file clusters and touched subsystems

repo rules files (AGENTS.md, CLAUDE.md, custom review guides)

recent merged PRs touching the same paths

accepted vs dismissed review comments from similar paths or keywords

author’s recent merged PRs in the repo

a small oc-search hit set seeded by PR title, touched paths, subsystem names

That gives you a stable baseline and reduces exploration variance, latency, and token waste.

2. Prompt design for context-aware review

Use a rigid skeleton with optional exploration, not a fully open-ended instruction.

A good pattern is:

Phase A: Mandatory grounding

read PR description and linked issue

read repo review/rules files

inspect changed files and map touched subsystems

read a bounded set of similar merged PRs / prior review comments

summarize the discovered context in a short internal note

Phase B: Review

inspect diff and nearby code

run targeted checks/tests if warranted

produce only evidence-backed findings

Phase C: Restraint

do not comment on style unless it violates an explicit repo rule or repeated historical pattern

do not speculate about intent if linked issue/history is missing

cap comments to highest-signal issues

The best commercial systems that describe this publicly all push in this direction: team rules are first-class, prior PR history is used mainly to judge relevance, and tools are used as additional evidence rather than replacing reasoning. Qodo’s PR History is explicitly about estimating whether a finding matters in that repo, and its rules system is about codifying repeated reviewer behavior; CodeRabbit likewise uses learnings, code guidelines, past PR context, and tool outputs. 
docs.coderabbit.ai
+4
Qodo Documentation
+4
Qodo Documentation
+4

So I would not prompt:

“Investigate whatever context you think you need.”

I would prompt more like:

“Before reviewing, always gather these context sources. Then decide whether more retrieval is necessary. Only surface findings supported by the diff, surrounding code, tests/tool output, or repeated repo history.”

That constraint is important because LLMs are much better at using bounded context than at inventing an efficient search plan from scratch.

3. Memory granularity

The right abstraction is not full transcript in prompt. It is:

Durable memory

conventions and standards

architectural decisions / invariants

accepted reviewer patterns

dismissed reviewer patterns

subsystem summaries

recurring test patterns

known exceptions

Searchable source material

raw past PRs

raw review threads

raw session transcripts

ADRs / docs / issue discussions

Ephemeral per-PR context

current diff

linked issue

nearest similar changes

most relevant past discussions

In other words: remember abstractions, retrieve evidence.

That matches what the better memory tools are converging on. mnemory describes a two-tier design with fast searchable summaries plus detailed artifact storage, and opencode-mem describes a token-efficient “search → timeline → fetch” flow rather than dumping everything back into context. 
GitHub
+1

For review specifically, I would store these units:

“Rule”: “In service X, migrations are auto-generated; don’t flag missing migration files.”

“Decision”: “Handlers must not call DB directly; go through repository layer.”

“Pattern”: “New endpoint tests follow fixture style Y.”

“Exception”: “This package intentionally uses polling because webhook source is unreliable.”

“Review precedent”: “Comments about docstrings in internal scripts are usually dismissed.”

I would not pin whole PR diffs or whole session transcripts as memory objects. Keep them searchable, but only distill them into memory when they imply a reusable rule, decision, exception, or pattern.

4. Upgrade path: when to move to Approach 2 or 3

Move to a context repo (Approach 2) when you see:

the same facts being rediscovered repeatedly

reviewers missing explicit conventions that could be written down once

humans want to inspect/edit the agent’s context

conflicting “tribal knowledge” needs auditability

oc-search is good enough to find sources, but prompts are too bloated

Move to a memory server (Approach 3) when you see:

substring search regularly misses relevant history

repo/session volume makes manual curation too expensive

you need semantic retrieval across many repos/sessions

you want automatic deduplication / contradiction handling

you can justify the ops surface and inference cost

mnemory is plausible later because it is self-hosted, supports OpenCode, offers semantic search, automatic recall/remember, and exposes both MCP and plugin paths. But its benchmark is LoCoMo, which is about conversational memory, not code review quality, so I would treat it as encouraging but not decisive evidence for your use case. It also expects an OpenAI-compatible API key and its fuller production setup adds Qdrant/S3-style infrastructure. 
GitHub
+2
GitHub
+2

5. Alternative framing

Yes: I think “memory” is only partly the right abstraction.

Your quality problem is probably a combination of four things:

insufficient context retrieval

missing repo-specific rules

weak review rubric / comment discipline

lack of evaluation loop

The public systems that seem strongest are not saying “we added memory and quality got good.” They are saying “we added repo graph, prior PRs, team rules, linked intent, and verification/tool signals.” Qodo even frames review as an independent verification layer separate from code generation, with specialized checks over full codebase context; CodeRabbit explicitly combines prior PR context, learnings, code guidelines, linked issues, web/MCP context, and linters/security tools. 
coderabbit.ai
+3
Qodo
+3
docs.coderabbit.ai
+3

So the simpler interventions that may have bigger impact first are:

stricter review rubric

better suppression of low-value comments

repo-rule injection

risk-based routing

real evaluation on your own PRs

A very practical local-first move here is to encode review rules explicitly. OpenCode’s plugin API is flexible, and opencode-rules already exists to discover and inject markdown rule files into prompts based on context. 
OpenCode
+1

6. Letta’s context repo pattern

Intellectually, I think it is good. Practically, for you, it is probably Phase 2, not Phase 1.

Letta’s context repositories are git-backed local filesystem memory with progressive disclosure, versioned updates, and multi-agent/worktree coordination. That is attractive for auditable, human-readable, local-first memory. But I did not find strong public evidence that this pattern is already proven specifically for automated PR review quality. What I found is that Letta positions it as a general memory architecture, and its GitHub Action for PRs/issues is explicitly experimental. 
Letta
+2
GitHub
+2

So I would call it not overkill in principle, but premature for your first validation loop.

7. Practical experience / production systems

There are clearly production-grade systems trying to do this, but public evidence is mostly vendor-reported rather than independent.

The most relevant examples I found:

CodeRabbit: semantic index over code/tests/prior PRs, team learnings, code guidelines, linked issues, web/MCP context, and tool signals; uses past PR context by default and supports learnings from prior interactions. 
coderabbit.ai
+2
docs.coderabbit.ai
+2

Qodo: uses PR history to estimate finding relevance, analyzes review discussions/handling patterns, and has a rules system that can suggest rules from code and PR history. 
Qodo
+3
Qodo Documentation
+3
Qodo
+3

Greptile: builds a full graph of the repo so reviews can reason about related code rather than isolated files. 
Greptile

Graphite/Diamond: public emphasis is less on architecture details and more on evaluation discipline, with acceptance rate as the key signal. 
Braintrust

That pattern is useful: history helps mostly by improving relevance and suppressing noise, while graph/rules/tooling help catch real issues.

What I would build in your shoes

I’d do this next:

Phase 1

keep lgtm

add a deterministic pre-review context packet

add a strict review rubric

store post-review outcomes

Phase 1.5

nightly job writes a small repo context repo:

review-charter.md

conventions/*.md

decisions/*.md

accepted-patterns.md

dismissed-patterns.md

recent-shifts.md

Only later

add semantic memory if oc-search recall becomes the limiting factor

The single most important metric: accepted-comment rate, not comment count. Secondary metrics: downvote/dismissal rate, duplicate rediscovery time, mean tokens/latency per review, and “human would have wanted this comment” on a replay set. That evaluation emphasis is consistent with how Graphite and CodeRabbit describe measuring tool quality in practice. 
Braintrust
+1

Net: Approach 1 is right, but tighten it into a deterministic context pipeline; don’t jump to a memory server yet; and think in terms of rules + retrieval + evaluation, not memory alone.

If helpful, I can turn this into a concrete lgtm review prompt plus a minimal repo-context file schema and command plan.