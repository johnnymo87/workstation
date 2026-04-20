---
name: preparing-for-compaction
description: Use when the user wants to compact and continue, or when context is getting long and work needs to survive compaction - prepares durable context and a resumption prompt before compaction happens
---

# Preparing for Compaction

## Overview

The user wants to continue working but needs to compact. The automatic compaction summary is lossy -- it captures what happened but not necessarily what matters for continuing well. Your job is to deliberately select what context the next session needs and persist it somewhere durable before compaction wipes the slate.

**Core ethos:** Care about the continuity of the work, not about ticking boxes. What does the next instance of you actually need to pick up where you left off? That's what you persist.

## The Process

1. **Assess what matters.** Look at the conversation. What are you in the middle of? What decisions were made and why? What tricky context would be hard to reconstruct? What's the user's intent that might not be obvious from code alone?

2. **Persist to durable storage.** Choose the right vehicle:
   - **Beads** (`bd create`, `bd update --notes`): Good for discrete tasks, dependencies, and work-in-progress tracking. If beads are active in the project, prefer them.
   - **Plan file** (`docs/plans/YYYY-MM-DD-*.md`): Good for design context, architectural decisions, multi-step plans. Write or update one.
   - **Both**: Often the right answer. Beads for task state, plan file for the bigger picture.
   - **Git commit message**: If there's uncommitted work, a well-crafted commit message is itself durable context.

3. **Commit and push.** Persisted context that isn't pushed doesn't survive. Follow the session close protocol.

4. **Draft and apply a resumption prompt.** Draft a concise message for the post-compaction session. It should:
   - Reference the durable artifacts by name (bead IDs, plan file paths)
   - State what to do first (e.g., "run `bd ready`", "read the plan file at ...")
   - Be passed to the `self_compact_and_resume` tool as the `prompt` argument to automate the handoff.

   *Note: If the `self_compact_and_resume` tool is not available (e.g., older opencode version, plugin disabled), fall back to printing the prompt for the user to paste after `/compact`.*

## What to Persist

Think about what you'd want if you were starting fresh with no memory:

- **Current task state**: What's done, what's in progress, what's next
- **Key decisions and their rationale**: Especially non-obvious ones
- **Gotchas and dead ends**: Things you tried that didn't work and why
- **File locations**: Which files are relevant and what role they play
- **User preferences expressed in conversation**: Things they care about that aren't in config
- **Uncommitted or unstaged work**: Make sure it's committed or noted

Don't persist what's already obvious from the codebase, git history, or existing docs. Focus on conversational context that would be lost.

## Example Resumption Prompt

When calling the `self_compact_and_resume` tool, pass a string similar to this as the `prompt` argument:

```
We were working on [X]. Context is in:
- beads: `bd ready` shows open tasks
- plan: docs/plans/2026-03-29-feature-x-design.md

Start by reading the plan file, then check `bd ready` for next steps.
```

Tailor this to the actual session -- the above is just the shape.
