---
name: bd-issue-tracking
description: Track complex, multi-session work with dependency graphs using bd (beads) issue tracker. Git-backed JSONL files are the source of truth, with SQLite as local cache. Use when work spans multiple sessions, has complex dependencies, or requires persistent context across compaction cycles. For simple single-session linear tasks, TodoWrite remains appropriate.
---

# bd Issue Tracking (v0.42+)

## Overview

bd is a graph-based issue tracker for persistent memory across sessions. Use for multi-session work with complex dependencies; use TodoWrite for simple single-session tasks.

**Key concepts:**
- **Hash-based IDs**: Issues use IDs like `bd-a1b2` (not sequential numbers)
- **JSONL source of truth**: `.beads/issues.jsonl` is git-tracked; SQLite is local cache
- **Dependency-driven ready**: `bd ready` shows work with no open blockers
- **30-second sync debounce**: Batches operations before auto-export

## When to Use bd vs TodoWrite

### Use bd when:
- **Multi-session work** - Tasks spanning multiple compaction cycles or days
- **Complex dependencies** - Work with blockers, prerequisites, or hierarchical structure
- **Knowledge work** - Strategic documents, research, or tasks with fuzzy boundaries
- **Side quests** - Exploratory work that might pause the main task
- **Project memory** - Need to resume work after weeks away with full context

### Use TodoWrite when:
- **Single-session tasks** - Work that completes within current session
- **Linear execution** - Straightforward step-by-step tasks with no branching
- **Immediate context** - All information already in conversation
- **Simple tracking** - Just need a checklist to show progress

**Key insight**: If resuming work after 2 weeks would be difficult without bd, use bd. If the work can be picked up from a markdown skim, TodoWrite is sufficient.

**For detailed decision criteria and examples, read:** [references/BOUNDARIES.md](references/BOUNDARIES.md)

## Surviving Compaction Events

**Critical**: After compaction, bd state is your only persistent memory. Write notes as if explaining to a future agent with zero conversation context.

**Key insight**: TodoWrite disappears after compaction, but bead notes survive. Use notes to capture: COMPLETED work, IN PROGRESS status, BLOCKERS, and KEY DECISIONS.

**For complete compaction recovery workflow and note-taking patterns, read:** [references/WORKFLOWS.md](references/WORKFLOWS.md#compaction-survival)

## Git Sync Architecture

bd uses **JSONL as the source of truth**, with SQLite as a local cache:

| File | Purpose | Committed to Git? |
|------|---------|-------------------|
| `.beads/*.db` | SQLite cache (fast queries) | **No** (gitignored) |
| `.beads/issues.jsonl` | Source of truth | **Yes** |
| `.beads/metadata.json` | Repository metadata | **Yes** |

**Auto-sync behavior:**
- **Export**: After CRUD operations, bd exports to JSONL (30-second debounce for batching)
- **Import**: After `git pull`, first bd command auto-imports if JSONL is newer than DB

### Manual Sync

For explicit control over sync:

```bash
bd sync                       # Full cycle: export→commit→pull→import→push
bd sync --status              # Show what would sync
bd sync --dry-run             # Preview without executing
bd sync --flush-only          # Export + commit only
```

### Daemon for Auto-Commit

For hands-off JSONL commits, run the daemon:

```bash
bd daemon --start --auto-commit           # Auto-commit after changes
bd daemon --start --auto-commit --auto-push  # Also push to remote
bd daemon --status                        # Check daemon status
bd daemon --health                        # Show uptime, cache stats
bd daemon --stop                          # Stop daemon
```

**Recommendation**: Use `--auto-commit` for most workflows. Add `--auto-push` only if you want fully automated sync without review.

### Protected Branch Workflow

When `main` requires pull requests:

```bash
# Initialize with a sync branch (commits go here, not main)
bd init --branch beads-sync

# Start daemon (commits to beads-sync automatically)
bd daemon --start --auto-commit

# Check what's changed
bd sync --status

# Merge to main (creates PR or direct merge)
bd sync --merge

# Or merge with dry-run first
bd sync --merge --dry-run
```

### Configuration

```bash
bd config set sync.branch beads-sync   # Set sync branch
bd config get sync.branch              # Check current setting
bd config set sync.branch ""           # Unset (commit to current branch)
```

### Initialization Options

```bash
bd init                    # Interactive setup
bd init --quiet            # Non-interactive (for agents)
bd init --branch beads-sync  # Use separate sync branch
bd init --stealth          # Local-only, doesn't commit to repo
```

**Stealth mode**: Use `--stealth` for personal tracking on shared repos where you don't want to commit `.beads/` files.

## Session Start Protocol

**bd is available when:**
- Project has a `.beads/` directory (project-local database), OR
- `~/.beads/` exists (global fallback database for any directory)

**At session start, always check for bd availability and run ready check:**

1. **Always check ready work automatically** at session start
2. **Report status** to establish shared context

### Quick Start Pattern

```bash
# At session start, run:
bd ready --json

# Report to user:
"I can see X items ready to work on: [brief summary]"

# If using global ~/.beads, note this in report
```

This gives immediate shared context about available work without requiring user prompting.

### Editor Integration

For AI-optimized context injection:

```bash
bd prime           # ~1-2k tokens of workflow context
bd onboard         # Minimal snippet for AGENTS.md
```

**Note**: bd auto-discovers the database:
- Uses `.beads/*.db` in current project if exists
- Falls back to `~/.beads/default.db` otherwise
- No configuration needed

### When No Work is Ready

If `bd ready` returns empty but issues exist:

```bash
bd blocked --json
```

Report blockers and suggest next steps.

### Database Selection

bd automatically selects the appropriate database:
- **Project-local** (`.beads/` in project): Used for project-specific work
- **Global fallback** (`~/.beads/`): Used when no project-local database exists

**Use case for global database**: Cross-project tracking, personal task management, knowledge work that doesn't belong to a specific project.

**Database discovery**: bd looks for `.beads/*.db` in current directory, falls back to `~/.beads/default.db`. Use `--db` flag for explicit database selection.

**For complete session start workflows, read:** [references/WORKFLOWS.md](references/WORKFLOWS.md#session-start)

## Core Operations

All bd commands support `--json` flag for structured output when needed for programmatic parsing.

### Essential Operations

**Check ready work:**
```bash
bd ready
bd ready --json              # For structured output
bd ready --priority 0        # Filter by priority
bd ready --assignee alice    # Filter by assignee
bd ready --claim             # Atomically claim next work item
```

**Create new issue:**
```bash
bd create "Fix login bug"
bd create "Add OAuth" -p 0 -t feature
bd create "Write tests" -d "Unit tests for auth module" --assignee alice
bd create "Research caching" --design "Evaluate Redis vs Memcached"
bd q "Quick capture"         # Returns only the ID
```

**Update issue:**
```bash
bd update bd-a1b2 --status in_progress
bd update bd-a1b2 --priority 0
bd update bd-a1b2 --notes "Progress: completed X, next: Y"
bd update bd-a1b2 --design "Decided to use Redis for persistence support"
```

**Close completed work:**
```bash
bd close bd-a1b2
bd close bd-a1b2 --reason "Implemented in PR #42"
bd close bd-a1 bd-a2 bd-a3 --reason "Bulk close related work"
```

**Show issue details:**
```bash
bd show bd-a1b2
bd show bd-a1b2 --json
```

**List issues:**
```bash
bd list                      # Non-closed, limit 50
bd list --status open
bd list --status closed
bd list --priority 0
bd list --type bug
```

**Other lifecycle:**
```bash
bd reopen bd-a1b2            # Reopen closed issue
bd defer bd-a1b2             # Defer for later
bd undefer bd-a1b2           # Restore deferred
```

**For complete CLI reference with all flags and examples, read:** [references/CLI_REFERENCE.md](references/CLI_REFERENCE.md)

## Issue Lifecycle Workflow

### 1. Discovery Phase (Proactive Issue Creation)

**During exploration or implementation, proactively file issues for:**
- Bugs or problems discovered
- Potential improvements noticed
- Follow-up work identified
- Technical debt encountered
- Questions requiring research

**Pattern:**
```bash
# When encountering new work during a task:
bd create "Found: auth doesn't handle profile permissions"
bd dep add bd-current bd-new --type discovered-from

# Continue with original task - issue persists for later
```

**Key benefit**: Capture context immediately instead of losing it when conversation ends.

### 2. Execution Phase (Status Maintenance)

**Mark issues in_progress when starting work:**
```bash
bd update bd-a1b2 --status in_progress
```

**Update throughout work:**
```bash
# Add progress notes (survives compaction)
bd update bd-a1b2 --notes "COMPLETED: auth endpoint. IN PROGRESS: token refresh"

# Add design notes as implementation progresses
bd update bd-a1b2 --design "Using JWT with RS256 algorithm"

# Update acceptance criteria if requirements clarify
bd update bd-a1b2 --acceptance "- JWT validation works\n- Tests pass\n- Error handling returns 401"
```

**Close when complete:**
```bash
bd close bd-a1b2 --reason "Implemented JWT validation with tests passing"
```

**Important**: Closed issues remain in database - they're not deleted, just marked complete for project history. Use `bd reopen` to restore if needed.

### 3. Planning Phase (Dependency Graphs)

For complex multi-step work, structure issues with dependencies before starting:

**Create parent epic:**
```bash
bd create "Implement user authentication" -t epic -d "OAuth integration with JWT tokens"
```

**Create subtasks:**
```bash
bd create "Set up OAuth credentials" -t task
bd create "Implement authorization flow" -t task
bd create "Add token refresh" -t task
```

**Link with dependencies:**
```bash
# parent-child for epic structure
bd dep add bd-epic bd-setup --type parent-child
bd dep add bd-epic bd-flow --type parent-child

# blocks for ordering
bd dep add bd-setup bd-flow
```

**For detailed dependency patterns and types, read:** [references/DEPENDENCIES.md](references/DEPENDENCIES.md)

## Dependency Types Reference

bd supports four core dependency types (plus advanced types for specialized workflows):

**Core types (use these for most workflows):**
1. **blocks** - Hard blocker (issue A blocks issue B from starting) - affects `bd ready`
2. **related** - Soft link (issues are related but not blocking)
3. **parent-child** - Hierarchical (epic/subtask relationship)
4. **discovered-from** - Provenance (issue B discovered while working on A)

**Advanced types** (for specialized workflows): `waits-for`, `conditional-blocks`, `duplicates`, `supersedes`, `validates`, `tracks`. See CLI reference for details.

**For complete guide on when to use each type with examples and patterns, read:** [references/DEPENDENCIES.md](references/DEPENDENCIES.md)

## Integration with TodoWrite

**Both tools complement each other at different timescales:**
- **TodoWrite** - Short-term working memory (this hour), disappears after session
- **Beads** - Long-term episodic memory (this week/month), survives compaction

**The Handoff Pattern**: Read bead → Create TodoWrite items → Work → Update bead notes with outcomes → TodoWrite disappears, bead survives.

**For complete temporal layering pattern, examples, and integration workflows, read:** [references/BOUNDARIES.md](references/BOUNDARIES.md#integration-patterns)

## Common Patterns

### Pattern 1: Knowledge Work Session

User asks for strategic document development:
1. Check if bd available: `bd ready`
2. If related epic exists, show current status
3. Create new issues for discovered research needs
4. Use discovered-from to track where ideas came from
5. Update design notes as research progresses

### Pattern 2: Side Quest Handling

During main task, discover a problem:
1. Create issue: `bd create "Found: inventory system needs refactoring"`
2. Link using discovered-from: `bd dep add bd-main bd-new --type discovered-from`
3. Assess: blocker or can defer?
4. If blocker: `bd update bd-main --status blocked`, work on new issue
5. If deferrable: note in issue, continue main task

### Pattern 3: Multi-Session Project Resume

Starting work after time away:
1. Run `bd ready` to see available work
2. Run `bd blocked` to understand what's stuck
3. Run `bd list --status closed --limit 10` to see recent completions
4. Run `bd show bd-a1b2` on issue to work on
5. Update status and begin work

**For complete workflow walkthroughs with checklists, read:** [references/WORKFLOWS.md](references/WORKFLOWS.md)

## Use Pattern Variations

bd is designed for work tracking but can serve other purposes with appropriate adaptations:

### Work Tracking (Primary Use Case)
- Issues flow through states (open → in_progress → closed)
- Priorities and dependencies matter
- Status tracking is essential
- IDs are sufficient for referencing

### Reference Databases / Glossaries (Alternative Use)
- Entities are mostly static (typically always open)
- No real workflow or state transitions
- Names/titles more important than IDs
- Minimal or no dependencies
- Consider dual format: maintain markdown version alongside database for name-based lookup
- Use separate database (not mixed with work tracking) to avoid confusion

**Example**: A terminology database could use both `terms.db` (queryable) and `GLOSSARY.md` (browsable by name).

**Key difference**: Work items have lifecycle; reference entities are stable knowledge.

## Issue Creation Guidelines

### When to Ask First vs Create Directly

**Ask the user before creating when:**
- Knowledge work with fuzzy boundaries
- Task scope is unclear
- Multiple valid approaches exist
- User's intent needs clarification

**Create directly when:**
- Clear bug discovered during implementation
- Obvious follow-up work identified
- Technical debt with clear scope
- Dependency or blocker found

**Why ask first for knowledge work?** Task boundaries in strategic/research work are often unclear until discussed, whereas technical implementation tasks are usually well-defined. Discussion helps structure the work properly before creating issues, preventing poorly-scoped issues that need immediate revision.

### Issue Quality

Use clear, specific titles and include sufficient context in descriptions to resume work later.

**Use --design flag for:**
- Implementation approach decisions, architecture notes, trade-offs considered

**Use --acceptance flag for:**
- Definition of done, testing requirements, success metrics

## Statistics and Monitoring

**Check project health:**
```bash
bd status
bd status --json
```

Returns: total issues, open, in_progress, closed, blocked, ready counts, and project metadata.

**Find blocked work:**
```bash
bd blocked
bd blocked --json
```

**Health checks:**
```bash
bd doctor              # Check installation health
bd doctor --fix        # Auto-repair issues found
```

Use status to:
- Report progress to user
- Identify bottlenecks
- Understand project state

## Advanced Features

### Issue Types

```bash
bd create "Title" -t task        # Standard work item (default)
bd create "Title" -t bug         # Defect or problem
bd create "Title" -t feature     # New functionality
bd create "Title" -t epic        # Large work with subtasks
bd create "Title" -t chore       # Maintenance or cleanup
```

### Priority Levels

```bash
bd create "Title" -p 0    # Critical (highest)
bd create "Title" -p 1    # High priority
bd create "Title" -p 2    # Normal priority (default)
bd create "Title" -p 3    # Low priority
bd create "Title" -p 4    # Backlog (lowest)
```

### Bulk Operations

```bash
# Close multiple issues at once
bd close bd-a1 bd-a2 bd-a3 --reason "Completed in sprint 5"
```

### Dependency Visualization

```bash
# Show full dependency tree for an issue
bd dep tree bd-a1b2
bd dep tree bd-a1b2 --format mermaid   # Output as diagram

# Check for circular dependencies
bd dep cycles
```

### Built-in Help

```bash
# Quick start guide (comprehensive built-in reference)
bd quickstart

# Command-specific help
bd create --help
bd dep --help
```

## JSON Output

All bd commands support `--json` flag for structured output:

```bash
bd ready --json
bd show bd-a1b2 --json
bd list --status open --json
bd status --json
```

Use JSON output when you need to parse results programmatically or extract specific fields.

## Troubleshooting

**If bd command not found:**
- Check installation: `bd version`
- Verify PATH includes bd binary location

**If issues seem lost:**
- Use `bd list` to see all issues
- Filter by status: `bd list --status closed`
- Closed issues remain in database permanently

**If bd show can't find issue by name:**
- `bd show` requires issue IDs (like `bd-a1b2`), not issue titles
- Workaround: `bd list | grep -i "search term"` to find ID first
- Then: `bd show bd-a1b2` with the discovered ID
- For glossaries/reference databases where names matter more than IDs, consider using markdown format alongside the database

**If dependencies seem wrong:**
- Use `bd show bd-a1b2` to see full dependency tree
- Use `bd dep tree bd-a1b2` for visualization
- Dependencies are directional: `bd dep add from-id to-id` means from-id blocks to-id
- See [references/DEPENDENCIES.md](references/DEPENDENCIES.md#common-mistakes)

**If database seems out of sync:**
- bd auto-syncs JSONL after each operation (30s debounce)
- bd auto-imports JSONL when newer than DB (after git pull)
- Manual sync: `bd sync`
- Manual operations: `bd export`, `bd import`

**If daemon won't start or sync isn't working:**
```bash
bd daemon --status              # Check if running
tail -f ~/.beads/daemon.log     # View daemon logs
bd daemon --stop && bd daemon --start  # Restart daemon
```

**If worktree is corrupted (protected branch mode):**
```bash
rm -rf .git/beads-worktrees/beads-sync  # Remove worktree
git worktree prune                       # Clean stale entries
bd daemon --stop && bd daemon --start    # Recreates worktree
```

## Reference Files

Detailed information organized by topic:

| Reference | Read When |
|-----------|-----------|
| [references/BOUNDARIES.md](references/BOUNDARIES.md) | Need detailed decision criteria for bd vs TodoWrite, or integration patterns |
| [references/CLI_REFERENCE.md](references/CLI_REFERENCE.md) | Need complete command reference, flag details, or examples |
| [references/WORKFLOWS.md](references/WORKFLOWS.md) | Need step-by-step workflows with checklists for common scenarios |
| [references/DEPENDENCIES.md](references/DEPENDENCIES.md) | Need deep understanding of dependency types or relationship patterns |
