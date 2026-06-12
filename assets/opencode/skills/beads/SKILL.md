---
name: beads
description: Activate beads (bd) issue tracking for persistent task memory across sessions. Use when work spans multiple sessions, has complex dependencies, or needs to survive compaction. For simple single-session linear tasks, use TodoWrite instead.
allowed-tools: [Bash, Read]
---

# Beads Issue Tracking

Dolt-powered issue tracker for persistent memory across sessions. In Git-Free/Stealth mode, issue tracking is completely decoupled from Git, and issues are stored in a locally gitignored Dolt database. Sharing and backups are done via Dolt's native cloud/remote replication.

## Session Activation

At session start, check for ready work:

```bash
bd ready --json
```

Report to user: number of ready items, top priorities, any blockers worth noting.

## When to Use bd vs TodoWrite

| Use bd when | Use TodoWrite when |
|-------------|-------------------|
| Multi-session work | Single-session tasks |
| Complex dependencies | Linear step-by-step |
| Need to survive compaction | Immediate context only |
| Resume after weeks away | Simple checklist |

**Rule of thumb**: If resuming after 2 weeks would be hard without bd, use bd.

## Quick Command Reference

```bash
# Check work
bd ready                    # What's unblocked
bd blocked                  # What's stuck
bd show bd-a1b2             # Full issue details

# Create (write for handoff - future Claude has no conversation context!)
bd create "Specific actionable title" -d "Full context: what, why, where" -p 2
bd q "Quick capture"        # Returns only ID

# Update as you work
bd update bd-a1b2 --status in_progress
bd update bd-a1b2 --notes "DONE: X. NEXT: Y. BLOCKER: Z"
bd update bd-a1b2 --design "Decided approach A because..."

# Close when done
bd close bd-a1b2 --reason "Completed: summary of what was done"

# Sync & Cloud Backup (Dolt native replication)
bd dolt push                # Push database changes to Dolt remote (cloud backup)
bd dolt pull                # Pull database changes from Dolt remote
```

**IDs use hash format** like `bd-a1b2`, not sequential numbers.

## Write for Handoff

Every bead must be understandable by a future Claude with:
- No access to this conversation
- Only the bead's title, description, notes, design fields
- General codebase knowledge from exploration

**Anti-patterns**:
- "As discussed above..." (no "above" after compaction)
- Vague titles only making sense in context
- Assuming file paths or function names are remembered
- `in_progress` status without notes on current state

## Session End Checklist

Before ending or if context is long:
- [ ] All `in_progress` items have current notes
- [ ] Discovered work captured as new issues
- [ ] Blockers documented in issue notes
- [ ] Run `bd dolt push` if configured with a remote to sync database changes to the cloud

## Git Hook Policy (workstation-specific)

**Do not install bd's git hooks in this environment.** The `bd` binary on
devbox/cloudbox/macOS is wrapped (see `pkgs/beads/default.nix` in the
workstation flake) so that `bd init` always runs with `--skip-hooks` injected.
This is intentional. Reasons:

- Upstream's inline `pre-commit` hook has a worktree bug: it resolves the main
  repo's `.beads/` directory into a `BEADS_DIR` shell variable but never
  exports it, so `bd sync --flush-only` fails inside any worktree, blocking
  every commit unless you pass `git commit --no-verify`.
- The bd daemon already auto-flushes JSONL on a 30s debounce, and we run
  `bd sync` explicitly at session end (Landing the Plane). The pre-commit
  flush adds latency to every commit for negligible safety benefit.

**Implications for future-Claude:**

- Don't manually run `bd hooks install`, `bd doctor --fix` (when it offers to
  install hooks), or copy hooks from `examples/git-hooks/` in the bd source.
  The wrapper only intercepts `bd init`; those other commands will silently
  install hooks if invoked.
- If a `.git/hooks/pre-commit` or `.git/hooks/post-merge` whose content starts
  with `# bd (beads)` reappears in any repo, delete it. It got there because
  someone ran one of the explicit install commands above.
- `bd init` itself is safe — the wrapper handles it. New `.beads/` directories
  will be created without the offending hooks.

If you ever genuinely want hooks (e.g., on a non-workstation machine where
the wrapper isn't present), pass `--skip-hooks=false` explicitly to opt back
in.

## Git-Free & Dolt Cloud Sync Configuration

To decouple Beads issue tracking completely from your Git workspace and use Dolt-native cloud replication for backup/sync:

### 1. Initialize Beads in Git-Free / Stealth Mode
Initialize with `--stealth` or configure `no-git-ops` to disable automatic Git operations and pre-commit hook hooks:
```bash
bd config set no-git-ops true
```
This forces Beads to skip Git staging, auto-commits, and Git-hooks, running purely local database reads and writes.

### 2. Ignore JSONL exports from Git
To keep your Git repository clean and free of JSONL files (such as `issues.jsonl` and `interactions.jsonl`), ensure they are removed from Git tracking and gitignored in `.beads/.gitignore`:
```bash
git rm --cached .beads/issues.jsonl .beads/interactions.jsonl
```
And add to `.beads/.gitignore`:
```gitignore
*.jsonl
```

### 3. Add a Dolt Remote (Cloud Backup)
Point your Beads database to a shared remote (like a GitHub repo, DoltHub, S3, or GCS) using the wrapper command:
```bash
# GitHub (using Dolt's git-backed refs format under refs/dolt/data)
bd dolt remote add origin git+ssh://git@github.com/org/repo.git

# DoltHub
bd dolt remote add origin https://doltremoteapi.dolthub.com/org/beads

# S3 or GCS
bd dolt remote add origin aws://[bucket]/path/to/repo
```
Once added, you can synchronize with the cloud using native database replication:
```bash
bd dolt push
bd dolt pull
```

## Reference Files

| Topic | File |
|-------|------|
| bd vs TodoWrite decision criteria | [references/BOUNDARIES.md](references/BOUNDARIES.md) |
| Complete CLI with all flags | [references/CLI_REFERENCE.md](references/CLI_REFERENCE.md) |
| Dependency types and patterns | [references/DEPENDENCIES.md](references/DEPENDENCIES.md) |
| Workflow walkthroughs | [references/WORKFLOWS.md](references/WORKFLOWS.md) |
