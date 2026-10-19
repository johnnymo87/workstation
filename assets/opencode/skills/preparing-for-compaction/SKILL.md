---
name: preparing-for-compaction
description: Use when the user wants to compact and continue, or when context is getting long and work needs to survive compaction (opencode or goose) - prepares durable context and a resumption prompt, then calls self_compact_and_resume
---

# Preparing for Compaction

## Overview

The user wants to continue working but needs to compact. Compaction itself produces a structured retrospective summary of what happened — **your job is the prospective layer:** persist durable artifacts, then write a resumption prompt that points the next session at those artifacts and tells it what to do *next*.

**Core ethos:** Care about the continuity of the work, not about ticking boxes. What does the next instance of you actually need to *resume well*? That's what you persist, and that's what your resumption prompt should set up.

## How Compaction Actually Works (read this once)

Compaction has two parts, and understanding both keeps you from doing redundant work. Both opencode and goose give you the same tool, `self_compact_and_resume(prompt)`; what differs is when it runs and what the summary looks like (see "Harness differences" below).

**The retrospective summary.** The harness summarizes the conversation so far. opencode runs its `compaction` agent and produces a structured Markdown summary (Goal, Instructions (verbatim user directives), Discoveries, Accomplished, Relevant files), which the next session sees as the first assistant message. goose runs a one-shot summarization of the visible history; the originals stay visible to the human but are hidden from you, and you see the summary plus a short note that you compacted yourself.

**Your prospective resumption prompt.** The `prompt` you pass is delivered *after* the summary as the next user message. This is for narrowing scope, giving an explicit first action, referencing durable artifacts by name, and carrying forward user intent or process-discipline lessons that wouldn't be obvious from the log.

**Don't duplicate the retrospective summary.** The summary covers what happened. You write what to do next.

## The Process

1. **Assess what matters.** Look at the conversation. What are you in the middle of? What decisions were made and why? What tricky context would be hard to reconstruct? What's the user's intent (especially any *narrowing* of scope) that might not be obvious from the messages alone?

2. **Persist to durable storage.** Pick the vehicle that fits — often more than one:
   - **Beads** (`bd create`, `bd update --notes`): default for discrete tasks, dependencies, work-in-progress tracking. Prefer if beads are active in the project.
   - **Plan file** (`docs/plans/YYYY-MM-DD-*.md`): for design context, architectural decisions, multi-step plans.
   - **HANDOFF.md** (or similar) in the relevant project/output directory: for incident response, exploratory investigations, anything where a plan-style document doesn't fit.
   - **Git commit message**: a well-crafted commit message is itself durable context for uncommitted work.

3. **Commit and push.** Persisted context that isn't pushed doesn't survive. Follow the session close protocol.

4. **Draft and apply a resumption prompt.** Draft a concise message for the post-compaction session and pass it as the `prompt` argument to the `self_compact_and_resume` tool. See "Resumption Prompt Shape" below. Call the tool **alone**, as the last thing you do in the step, and **read its result**.

   If the tool is not in your tool list, fall back to printing the prompt for the user to paste after `/compact` (see the harness notes for what `/compact` does there).

## Harness differences

**opencode** (`self_compact_and_resume` is a plugin tool):
- Returns almost instantly with "Compaction queued" — no waiting.
- If it says "Compaction NOT queued", nothing will happen when the turn ends, and the result says why. Don't tell the user you're compacting. Say it failed and give the reason, then either call the tool again (if the cause looks transient) or fall back to printing the prompt for them to paste after `/compact`. If it says the *replacement* was not queued, an earlier call's compaction is still armed with that earlier prompt.
- Compaction begins after THIS turn closes (once you stop responding). Do NOT call other tools or generate more text trying to "wait for" or "verify" compaction — that just delays it.
- The TUI streams the retrospective summary once it starts. When compaction completes, your resumption prompt arrives as the next user message and a fresh turn begins automatically.

**goose** (`self_compact_and_resume` is built into the agent loop):
- Returns "Compaction runs right after this step; your prompt will be the next user message." Compaction then runs **within the same turn**: the summary replaces your context, the human sees "Context self-compacted.", and your prompt arrives as the next user message. Keep working from it; there is no new turn to wait for, and nothing for the human to do.
- **Restate the original request in the prompt.** Self-requested compaction does not carry the user's last message forward verbatim; if the prompt does not say what you were asked to do, you will not know.
- **At most once per turn.** A second call in the same turn returns "Already self-compacted in this turn" — carry on from the resume prompt. Never answer a resume prompt by compacting again.
- **Failures are visible, not silent, and they end the turn.** If the tool result is an error, nothing was armed. If compaction fails or is skipped, goose ends the turn with a notice ("Self-compaction failed: <reason>. Context unchanged; the resume prompt was not delivered:" or "Self-compaction skipped: the turn limit was reached…") followed by your prompt. You see it on your next turn: your context is intact and you never resumed, so act on the human's new message. You may call the tool again then; the once-per-turn limit resets.
- **Not routine.** goose already compacts on its own at about 80% of the context window and on overflow. Self-compact only when the user asks, or at a real breakpoint where your resume prompt adds direction — never as a precaution because "tokens remaining" looks low.
- **Not offered** in recipe sessions (response schema / `final_output`, or retry), in subagents, with providers that manage their own context, or when the server sets `GOOSE_SELF_COMPACT=false` (a call there returns "self_compact_and_resume is not available in this session"). In subagents and recipe sessions there is no human to type `/compact`, so don't print a paste-prompt — just continue; automatic compaction still covers overflow. In an interactive session the human's `/compact` (in honk chat, the `/compact` command) compacts without resuming: the next message comes from them.

## What to Persist (durable storage, step 2)

Think about what you'd want if you were starting fresh with no memory and only had access to git, beads, and the project's docs:

- **Current task state**: What's done, what's in progress, what's next
- **Key decisions and their rationale**: Especially non-obvious ones
- **Gotchas and dead ends**: Things you tried that didn't work and why (including data-source quirks, ETL lag, table gotchas, API surprises)
- **File locations**: Which files are relevant and what role they play
- **User preferences expressed in conversation**: Things they care about that aren't in config
- **Uncommitted or unstaged work**: Make sure it's committed or noted
- **Active sibling sessions / coordination state**: If running in a swarm, who else is alive, what they're doing, and how to reach them

Don't persist what's already obvious from the codebase, git history, or existing docs. Focus on conversational context that would be lost.

## Resumption Prompt Shape (step 4)

The resumption prompt is *not* a summary. It is a launch instruction for the next instance of you. Good resumption prompts share these features:

- **Open with intent + narrowing.** What is the next session FOR? Equally important: what is it NOT for? ("Focus EXCLUSIVELY on X. Y has been released. Don't contact Z again.")
- **Give the FIRST action explicitly.** Not "continue working" — concrete first command or first file to read.
- **Reference durable artifacts BY NAME.** Bead IDs (`bd-123`), full file paths (`/home/dev/projects/foo/HANDOFF.md`), session IDs, plan file paths. The next agent shouldn't have to guess where to look.
- **Carry forward process discipline.** If you learned the hard way that "claim X needs verification by both Y and Z before saying anything," restate that.
- **Stay concise.** Aim for 200-400 words. The harness's summary is doing the heavy lifting on context — your job is direction.

If you find yourself writing more than ~400 words, you're probably duplicating the retrospective summary. Link to plan files and HANDOFF docs by path rather than restating their content.

### Example Resumption Prompt

```
You are resuming the [project] work post-compaction. Focus is now EXCLUSIVELY on
[narrowed scope] — the [other-phase] phase is closed.

READ THIS FIRST:
  /home/dev/projects/[project]/docs/plans/2026-04-21-feature-x-plan.md

It contains: [one-line description of what's in the file].

[Optional: list of any active sibling sessions or beads]
- Sibling A (ses_abc...): doing X, ETA Y
- bd-123: in_progress, blocked on Z

Immediate first action:
1. [Concrete first command or file to read]
2. If [condition], then [next step]; otherwise [alternative]

User intent: [one sentence stating what the user actually wants from this next
phase, including any explicit narrowing or "do not" directives]. Apply the
process discipline lessons ([brief list of any hard-won protocols, e.g. "verify
candidate lists with spot-checks before claiming divergences"]).
```

Tailor this to the actual session — the above is just the shape. The point is: narrow intent up front, concrete first action, reference durable artifacts by name, carry forward process discipline.
