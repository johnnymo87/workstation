# CLI Reference

Complete command reference for bd (beads) CLI tool v0.42+. All commands support `--json` flag for structured output.

## Contents

- [Quick Reference](#quick-reference)
- [Global Flags](#global-flags)
- [Core Commands](#core-commands)
  - [bd ready](#bd-ready) - Find unblocked work
  - [bd create](#bd-create) - Create new issues
  - [bd update](#bd-update) - Update issue fields
  - [bd close](#bd-close) - Close completed work
  - [bd show](#bd-show) - Show issue details
  - [bd list](#bd-list) - List issues with filters
- [Dependency Commands](#dependency-commands)
  - [bd dep add](#bd-dep-add) - Create dependencies
  - [bd dep tree](#bd-dep-tree) - Visualize dependency trees
  - [bd dep cycles](#bd-dep-cycles) - Detect circular dependencies
  - [bd relate](#bd-relate) - Bidirectional soft link
- [Monitoring Commands](#monitoring-commands)
  - [bd status](#bd-status) - Database overview and statistics
  - [bd blocked](#bd-blocked) - Find blocked work
- [Lifecycle Commands](#lifecycle-commands)
  - [bd reopen](#bd-reopen) - Reopen closed issues
  - [bd delete](#bd-delete) - Soft delete (tombstone)
  - [bd defer / bd undefer](#bd-defer) - Defer work for later
- [Sync Commands](#sync-commands)
  - [bd sync](#bd-sync) - Full sync cycle
  - [bd export / bd import](#bd-export) - Manual JSONL operations
- [Daemon Commands](#daemon-commands)
  - [bd daemon](#bd-daemon) - Background daemon management
  - [bd daemons](#bd-daemons) - Multi-project daemon status
- [Setup Commands](#setup-commands)
  - [bd init](#bd-init) - Initialize database
  - [bd doctor](#bd-doctor) - Health checks and repair
  - [bd quickstart](#bd-quickstart) - Show quick start guide
- [Advanced Commands](#advanced-commands)
- [Common Workflows](#common-workflows)
- [JSON Output](#json-output)
- [Database Auto-Discovery](#database-auto-discovery)
- [Git Integration](#git-integration)
- [Tips](#tips)

## Quick Reference

### Core Commands (Daily Use)

| Command | Purpose | Key Flags |
|---------|---------|-----------|
| `bd ready` | Find unblocked work | `--priority`, `--assignee`, `--limit`, `--claim` |
| `bd list` | List issues with filters | `--status`, `--priority`, `--type`, `--assignee` |
| `bd show <id>` | Show issue details | `--json` |
| `bd create "Title"` | Create new issue | `-t`, `-p`, `-d`, `--design`, `--acceptance` |
| `bd update <id>` | Update existing issue | `--status`, `--priority`, `--notes`, `--design` |
| `bd close <id>` | Close completed issue | `--reason` |

### Standard Commands

| Command | Purpose | Key Flags |
|---------|---------|-----------|
| `bd dep add <from> <to>` | Add dependency | `--type` (blocks, related, parent-child, discovered-from) |
| `bd dep tree <id>` | Visualize dependency tree | `--reverse`, `--format mermaid` |
| `bd relate <id1> <id2>` | Bidirectional relates-to link | |
| `bd blocked` | Find blocked issues | `--json` |
| `bd reopen <id>` | Reopen closed issue | |
| `bd sync` | Full sync cycle | `--dry-run`, `--merge`, `--status` |
| `bd daemon` | Manage background daemon | `--start`, `--stop`, `--status`, `--health` |
| `bd status` | Database overview + stats | `--json` |

### Setup & Maintenance

| Command | Purpose | Key Flags |
|---------|---------|-----------|
| `bd init` | Initialize bd in directory | `--prefix`, `--branch`, `--stealth` |
| `bd doctor` | Health checks and auto-repair | `--fix` |
| `bd quickstart` | Show quick start guide | |

**Note:** Issue IDs use hash format like `bd-a1b2` or hierarchical `bd-a1b2.1` for subtasks.

## Global Flags

Available for all commands:

```bash
--json                 # Output in JSON format (structured, parseable)
--db /path/to/db       # Specify database path (default: auto-discover)
--actor "name"         # Actor name for audit trail
--no-auto-flush        # Disable automatic JSONL export
--no-auto-import       # Disable automatic JSONL import
```

**Tip:** Always use `--json` when parsing output programmatically.

## Core Commands

### bd ready

Find tasks with no blockers - ready to be worked on.

```bash
bd ready                      # All ready work
bd ready --json               # JSON format
bd ready --priority 0         # Only priority 0 (critical)
bd ready --assignee alice     # Only assigned to alice
bd ready --limit 5            # Limit to 5 results
bd ready --claim              # Atomically claim next work item
```

**Use at session start** to see available work.

**Sort behavior:** By default uses "hybrid" policy (recent work by priority, older work by age). Can also set to `priority` or `oldest`.

---

### bd create

Create a new issue with optional metadata.

```bash
bd create "Title"
bd create "Title" -t bug -p 0
bd create "Title" -d "Description"
bd create "Title" --design "Design notes"
bd create "Title" --acceptance "Definition of done"
bd create "Title" --assignee alice
```

**Flags**:
- `-t, --type`: task (default), bug, feature, epic, chore
- `-p, --priority`: 0-4 (0=critical, 1=high, 2=normal, 3=low, 4=backlog; default: 2)
- `-d, --description`: Issue description
- `--design`: Design notes / implementation approach
- `--acceptance`: Acceptance criteria / definition of done
- `--assignee`: Who should work on this

**Quick capture:** Use `bd q "Title"` to create and return only the ID (useful for scripting).

---

### bd update

Update an existing issue's fields.

```bash
bd update bd-a1b2 --status in_progress
bd update bd-a1b2 --priority 0
bd update bd-a1b2 --notes "Progress: completed X, next: Y"
bd update bd-a1b2 --design "Decided to use Redis"
bd update bd-a1b2 --acceptance "Tests passing"
```

**Status values**: `open`, `in_progress`, `blocked`, `deferred`, `closed`

**Tip:** Use `--notes` to capture progress that survives compaction.

---

### bd close

Close (complete) an issue.

```bash
bd close bd-a1b2
bd close bd-a1b2 --reason "Implemented in PR #42"
bd close bd-a1 bd-a2 bd-a3 --reason "Bulk close"
```

**Note**: Closed issues remain in database for history. Use `bd reopen` to reopen.

---

### bd show

Show detailed information about a specific issue.

```bash
bd show bd-a1b2
bd show bd-a1b2 --json
```

Shows: all fields, dependencies, dependents, audit history.

---

### bd list

List issues with optional filters.

```bash
bd list                          # Non-closed issues (default limit: 50)
bd list --status open            # Only open
bd list --status closed          # Only closed
bd list --priority 0             # Critical only
bd list --type bug               # Only bugs
bd list --assignee alice         # By assignee
bd list --limit 100              # Override default limit
```

**Note:** Default excludes closed issues and limits to 50 results.

---

## Dependency Commands

### bd dep add

Add a dependency between issues.

```bash
bd dep add bd-a1 bd-b2                       # blocks (default)
bd dep add bd-a1 bd-b2 --type blocks         # explicit blocks
bd dep add bd-a1 bd-b2 --type related        # soft link
bd dep add bd-epic bd-task --type parent-child
bd dep add bd-main bd-found --type discovered-from
```

**Core dependency types** (4 main types for most workflows):
1. **blocks**: from-issue blocks to-issue (affects `bd ready`)
2. **related**: Soft link (informational only)
3. **parent-child**: Epic/subtask hierarchy
4. **discovered-from**: Tracks origin of discovery

**Additional types** (for advanced workflows): `waits-for`, `conditional-blocks`, `replies-to`, `duplicates`, `supersedes`, `tracks`, `validates`. See [DEPENDENCIES.md](DEPENDENCIES.md) for details.

---

### bd dep tree

Visualize full dependency tree for an issue.

```bash
bd dep tree bd-a1b2
bd dep tree bd-a1b2 --reverse          # Show what this blocks
bd dep tree bd-a1b2 --format mermaid   # Output as Mermaid diagram
bd dep tree bd-a1b2 --max-depth 10     # Limit depth
```

Shows all dependencies and dependents in tree format.

---

### bd dep cycles

Detect circular dependencies.

```bash
bd dep cycles
```

Finds dependency cycles that would prevent work from being ready.

---

### bd relate

Create bidirectional `relates-to` link between issues.

```bash
bd relate bd-a1 bd-b2
```

Shorthand for creating a symmetric relationship. Both issues will show each other as related.

---

## Monitoring Commands

### bd status

Get database overview and statistics.

```bash
bd status
bd status --json
```

Returns: total issues, open, in_progress, closed, blocked, ready counts, and project metadata.

---

### bd blocked

Get blocked issues with blocker information.

```bash
bd blocked
bd blocked --json
```

Use to identify bottlenecks when ready list is empty.

---

## Lifecycle Commands

### bd reopen

Reopen a closed issue.

```bash
bd reopen bd-a1b2
```

Sets status back to `open`.

---

### bd delete

Soft delete an issue (sets status to `tombstone`).

```bash
bd delete bd-a1b2
```

Tombstoned issues are automatically cleaned up after TTL (default 30 days). Use `bd cleanup` to manually purge.

---

### bd defer

Defer work for later.

```bash
bd defer bd-a1b2            # Set status to deferred
bd undefer bd-a1b2          # Restore to open
```

Deferred issues won't appear in `bd ready` but remain visible in `bd list`.

---

## Sync Commands

### bd sync

Full sync cycle: export → commit → pull → import → push.

```bash
bd sync                       # Full sync cycle
bd sync --status              # Show diff between sync branch and main
bd sync --dry-run             # Preview what would happen
bd sync --merge               # Merge sync branch to main (protected branch workflow)
bd sync --flush-only          # Export + commit without git pull/push
bd sync --import-only         # Import from JSONL without git operations
```

**Timing:** bd uses 30-second debounce for batch operations before auto-export.

**Recommended workflow:**
```bash
# At session end
git pull --rebase
bd sync
git push
```

---

### bd export

Export all issues to JSONL format.

```bash
bd export > issues.jsonl
bd export -i custom.jsonl     # Export to specific file
```

**Note**: bd auto-exports to `.beads/issues.jsonl` after operations (30s debounce). Manual export rarely needed.

---

### bd import

Import issues from JSONL format.

```bash
bd import < issues.jsonl
bd import -i custom.jsonl
bd import --resolve-collisions < issues.jsonl
```

**Flags:**
- `--resolve-collisions` - Automatically remap conflicting issue IDs

**Use cases for --resolve-collisions:**
- Reimporting after manual JSONL edits
- Merging databases with overlapping IDs
- Restoring from backup when state has diverged

---

## Daemon Commands

### bd daemon

Manage background daemon for a project.

```bash
bd daemon --start                        # Start daemon
bd daemon --start --auto-commit          # Auto-commit after changes
bd daemon --start --auto-commit --auto-push  # Also push to remote
bd daemon --stop                         # Stop daemon
bd daemon --status                       # Check if running
bd daemon --health                       # Show uptime, cache stats, metrics
```

**Architecture:** Per-project daemon at `.beads/bd.sock`. Provides connection pooling and performance optimization.

---

### bd daemons

Manage daemons across multiple projects.

```bash
bd daemons list                 # List all running daemons
bd daemons health               # Health status of all daemons
```

---

## Setup Commands

### bd init

Initialize bd in current directory.

```bash
bd init                        # Interactive setup
bd init --quiet                # Non-interactive (for agents)
bd init --prefix api           # Custom prefix for IDs
bd init --branch beads-sync    # Use separate sync branch (protected main)
bd init --stealth              # Local-only, doesn't commit to repo
bd init --from-jsonl file.jsonl  # Bootstrap from existing JSONL
```

Creates `.beads/` directory with database and metadata.

---

### bd doctor

Health checks and auto-repair.

```bash
bd doctor                      # Check installation health
bd doctor --fix                # Auto-repair issues found
```

Checks: database integrity, git hooks, daemon status, JSONL sync state.

---

### bd quickstart

Show comprehensive quick start guide.

```bash
bd quickstart
```

Displays built-in reference for command syntax and workflows.

---

## Advanced Commands

These commands are for specialized workflows. See `bd <command> --help` for details.

| Command | Purpose |
|---------|---------|
| `bd compact` | Semantic summarization of old closed issues (memory decay) |
| `bd cleanup` | Delete closed issues, prune tombstones |
| `bd validate` | Comprehensive database health checks |
| `bd repair-deps` | Fix orphaned dependencies |
| `bd migrate` | Data migration (hash-ids, tombstones) |
| `bd prime` | AI-optimized workflow context (~1-2k tokens) |
| `bd onboard` | Minimal snippet for AGENTS.md |
| `bd preflight` | PR readiness checks (test/lint/version) |
| `bd duplicate <id> --of <other>` | Mark issue as duplicate |
| `bd supersede <id> --by <other>` | Mark issue as superseded |

---

## Common Workflows

### Session Start

```bash
bd ready --json
bd show bd-a1b2
bd update bd-a1b2 --status in_progress
```

### Discovery During Work

```bash
bd create "Found: bug in auth" -t bug
bd dep add bd-current bd-new --type discovered-from
```

### Completing Work

```bash
bd close bd-a1b2 --reason "Implemented with tests passing"
bd ready  # See what unblocked
```

### Planning Epic

```bash
bd create "OAuth Integration" -t epic
bd create "Set up credentials" -t task
bd create "Implement flow" -t task

bd dep add bd-epic bd-creds --type parent-child
bd dep add bd-epic bd-flow --type parent-child
bd dep add bd-creds bd-flow  # creds blocks flow

bd dep tree bd-epic
```

### End of Session

```bash
git pull --rebase
bd sync
git push
git status   # Verify "up to date with origin/main"
```

---

## JSON Output

All commands support `--json` for structured output:

```bash
bd ready --json
bd show bd-a1b2 --json
bd list --status open --json
bd status --json
```

Use when parsing programmatically or extracting specific fields.

---

## Database Auto-Discovery

bd finds database in this order:

1. `--db` flag: `bd ready --db /path/to/db.db`
2. `$BEADS_DIR` environment variable (points to `.beads/` directory)
3. `.beads/*.db` in current directory or ancestors (nearest wins)
4. `~/.beads/default.db` as fallback

**Project-local** (`.beads/`): Project-specific work, git-tracked

**Global fallback** (`~/.beads/`): Cross-project tracking, personal tasks

### Monorepo / Nested Directory Handling

bd uses **nearest-first discovery** - it walks from cwd upward and returns the first `.beads/` found. This means subdirectories can have their own databases:

```
~/Code/monorepo/           # has .beads/ (parent project)
~/Code/monorepo/service-a/ # can have its own .beads/ (takes precedence when working here)
```

**Option 1: Init in the subdirectory** (permanent)
```bash
cd ~/Code/monorepo/service-a
bd init --prefix svc-a
```
From `service-a/`, bd will now find `service-a/.beads/` first.

**Option 2: Use `BEADS_DIR` environment variable** (session-based)
```bash
export BEADS_DIR=~/Code/monorepo/service-a/.beads
```
Useful when you want to temporarily target a specific database without permanent init.

**Git root boundary:** bd stops searching at the git root. If the subdirectory is a separate git repo (submodule, worktree), it won't see the parent's `.beads/` at all.

**Redirect (opposite case):** If you want multiple directories to share ONE database, create a `.beads/redirect` file containing the path to the shared `.beads/` directory.

---

## Git Integration

bd automatically syncs with git:

- **After operations**: Exports to JSONL (30-second debounce for batching)
- **After git pull**: Imports from JSONL if newer than DB

**Files**:
- `.beads/issues.jsonl` - Source of truth (git-tracked)
- `.beads/*.db` - Local cache (gitignored)
- `.beads/metadata.json` - Repository metadata (git-tracked)

### Git Integration Troubleshooting

**Problem: `.gitignore` ignores entire `.beads/` directory**

**Symptom**: JSONL file not tracked in git, can't commit beads

**Cause**: Incorrect `.gitignore` pattern blocks everything

**Fix**:
```bash
# Check .gitignore
cat .gitignore | grep beads

# ❌ WRONG (ignores everything including JSONL):
.beads/

# ✅ CORRECT (ignores only SQLite cache):
.beads/*.db
.beads/*.db-*
```

**After fixing**: Remove the `.beads/` line and add the specific patterns. Then `git add .beads/issues.jsonl`.

---

### Permission Troubleshooting

**Problem: bd commands prompt for permission despite whitelist**

**Symptom**: `bd` commands ask for confirmation even with `Bash(bd:*)` in settings.local.json

**Root Cause**: Wildcard patterns in settings.local.json don't actually work - not for bd, not for git, not for any Bash commands. This is a general Claude Code limitation, not bd-specific.

**How It Actually Works**:
- Individual command approvals (like `Bash(bd ready)`) DO persist across sessions
- These are stored server-side by Claude Code, not in local config files
- Commands like `git status` work without prompting because they've been individually approved many times, creating the illusion of a working wildcard pattern

**Permanent Solution**:
1. Trigger each bd subcommand you use frequently (see command list below)
2. When prompted, click "Yes, and don't ask again" (NOT "Allow this time")
3. That specific command will be permanently approved across all future sessions

**Common bd Commands to Approve**:
```bash
bd ready
bd list
bd status
bd blocked
bd sync
bd version
bd quickstart
bd doctor
bd dep cycles
bd --help
bd [command] --help  # For any subcommand help
```

**Note**: Dynamic commands with arguments (like `bd show <issue-id>`, `bd create "title"`) must be approved per-use since arguments vary. Only static commands can be permanently whitelisted.

---

## Tips

**Use JSON for parsing**:
```bash
bd ready --json | jq '.[0].id'
```

**Bulk operations**:
```bash
bd close bd-a1 bd-a2 bd-a3 --reason "Sprint complete"
```

**Quick filtering**:
```bash
bd list --status open --priority 0 --type bug
```

**Quick capture (returns ID only)**:
```bash
bd q "Fix the auth bug"
```

**Built-in help**:
```bash
bd quickstart       # Comprehensive guide
bd create --help    # Command-specific help
bd doctor           # Check installation health
```
