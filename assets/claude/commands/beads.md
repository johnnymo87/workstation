---
description: Activate beads-driven workflow for persistent task tracking across sessions
argument-hint: [path/to/database.db]
allowed-tools: [Bash, Read, Edit, Write, Glob, Grep]
---

Activate beads (bd) issue tracking for this session (v0.42+).

**Database path (optional):** $ARGUMENTS

## Setup

1. **Determine database:**
   - If path provided: Use `--db $ARGUMENTS` for all bd commands
   - If no path: bd auto-discovers `.beads/*.db` (i.e. in CWD). Do not use `~/.beads/default.db`

2. **Check current state:**
   ```bash
   bd ready --json  # (add --db flag if path provided)
   ```

3. **Report to user:**
   - Number of ready items
   - Brief summary of top priorities
   - Any blocked items worth noting

## Behavioral Rules: Write for Handoff

**Critical mindset:** Write every bead as if another Claude instance with only a vague idea of the project will pick it up and execute. That future instance has:
- No access to this conversation
- Only the bead's title, description, notes, and design fields
- General knowledge of the codebase (from exploration)

**This means:**
- **Titles** must be specific and actionable ("Add rate limiting to Bridge" not "Fix the thing we discussed")
- **Descriptions** must include full context (what, why, where in codebase)
- **Notes** must capture progress, decisions, and blockers with enough detail to resume
- **Design** field for implementation approach and key decisions

**Anti-patterns to avoid:**
- "As discussed above..." (there is no "above" after compaction)
- Vague titles that only make sense in context
- Assuming the next instance remembers file paths or function names
- Leaving status as in_progress without notes on current state

## Key Commands Reference

```bash
# Check work
bd ready                    # What's unblocked
bd blocked                  # What's stuck and why
bd show bd-a1b2             # Full details on one issue

# Create (with full context!)
bd create "Title" -d "Description with context" -p 1
bd create "Title" --design "Implementation approach"
bd q "Quick capture"        # Returns only the ID

# Update as you work
bd update bd-a1b2 --status in_progress
bd update bd-a1b2 --notes "Progress: did X, next: Y, blocker: Z"
bd update bd-a1b2 --design "Decided to use approach A because..."

# Close when done
bd close bd-a1b2 --reason "Completed: summary of what was done"
```

**Note:** IDs use hash format like `bd-a1b2`, not sequential numbers.

## During This Session

1. **Before starting work:** Mark the issue `in_progress`
2. **As you work:** Update notes with progress, decisions, blockers
3. **When blocked:** Create new issues for discovered work, link with dependencies
4. **When done:** Close with meaningful reason

## Handoff Checkpoint

Before ending session or if context is getting long:
- [ ] All in_progress items have current notes
- [ ] Any discovered work is captured as new issues
- [ ] Blockers are documented in the blocked issue's notes
- [ ] Recent decisions are in design fields
- [ ] Run `bd sync` to ensure JSONL is committed

**Remember:** The JSONL file is committed to git. Your notes become part of the project's history.
