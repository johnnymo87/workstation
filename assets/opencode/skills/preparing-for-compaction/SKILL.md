---
name: preparing-for-compaction
description: Use when the user wants to compact and continue, or when context is getting long and work needs to survive compaction - prepares durable context and a resumption prompt before compaction happens
---

# Preparing for Compaction

## Overview

The user wants to continue working but needs to compact. Compaction itself produces a structured retrospective summary of what happened — **your job is the prospective layer:** persist durable artifacts, then write a resumption prompt that points the next session at those artifacts and tells it what to do *next*.

**Core ethos:** Care about the continuity of the work, not about ticking boxes. What does the next instance of you actually need to *resume well*? That's what you persist, and that's what your resumption prompt should set up.

## How Compaction Actually Works (read this once)

Compaction has two parts, and understanding both keeps you from doing redundant work.

**The retrospective summary.** When compaction runs, opencode invokes the `compaction` agent against the entire pre-tail conversation. It produces a structured Markdown summary covering: Goal, Instructions (verbatim user directives), Discoveries, Accomplished (done/in-progress/remaining), and Relevant files. The summary is dense and captures gotchas, technical context, and file references. The next session sees it as the first assistant message.

**Your prospective resumption prompt.** The `self_compact_and_resume` tool queues a user message delivered *after* the summary. This is for narrowing scope, giving an explicit first action, referencing durable artifacts by name, and carrying forward user intent or process-discipline lessons that wouldn't be obvious from the log.

**Don't duplicate the retrospective summary.** opencode covers what happened. You write what to do next.

## The Process

1. **Assess what matters.** Look at the conversation. What are you in the middle of? What decisions were made and why? What tricky context would be hard to reconstruct? What's the user's intent (especially any *narrowing* of scope) that might not be obvious from the messages alone?

2. **Persist to durable storage.** Pick the vehicle that fits — often more than one:
   - **Beads** (`bd create`, `bd update --notes`): default for discrete tasks, dependencies, work-in-progress tracking. Prefer if beads are active in the project.
   - **Plan file** (`docs/plans/YYYY-MM-DD-*.md`): for design context, architectural decisions, multi-step plans.
   - **HANDOFF.md** (or similar) in the relevant project/output directory: for incident response, exploratory investigations, anything where a plan-style document doesn't fit.
   - **Git commit message**: a well-crafted commit message is itself durable context for uncommitted work.

3. **Commit and push.** Persisted context that isn't pushed doesn't survive. Follow the session close protocol.

4. **Draft and apply a resumption prompt.** Draft a concise message for the post-compaction session and pass it as the `prompt` argument to the `self_compact_and_resume` tool. See "Resumption Prompt Shape" below.

   **How the tool behaves:**
   - Returns INSTANTLY with a "Compaction queued" message — no waiting.
   - Compaction begins automatically after THIS turn closes (i.e., once you stop responding). Do NOT call other tools or generate more text trying to "wait for" or "verify" compaction — that just delays it.
   - The TUI streams the retrospective summary token-by-token once it starts.
   - When compaction completes, your resumption prompt arrives as the next user message — a fresh turn begins automatically.

   *Note: If the `self_compact_and_resume` tool is not available (e.g., older opencode version, plugin disabled), fall back to printing the prompt for the user to paste after `/compact`.*

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
- **Stay concise.** Aim for 200-400 words. opencode's summary is doing the heavy lifting on context — your job is direction.

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
