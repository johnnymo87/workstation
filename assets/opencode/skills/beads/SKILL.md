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

- We run beads **git-free** (`no-git-ops: true`, JSONL gitignored), so bd must
  never stage, commit, or run git hooks against the repo. Backups go to DoltHub
  via `bd dolt push`, not git.
- `bd sync` — the old export→commit→push cycle those hooks invoked — was
  removed upstream in v0.56.0 and is gone from the 1.0 binary entirely
  (`bd sync` now errors with `unknown command`).
- Upstream's historical inline `pre-commit` hook also had a worktree bug (it
  resolved the main repo's `.beads/` into `BEADS_DIR` but never exported it,
  breaking commits inside worktrees), which is the original reason the wrapper
  injects `--skip-hooks`.

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
Initialize with `--stealth` or configure `no-git-ops` to disable automatic Git operations and pre-commit hooks:
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

### Workstation setup (DoltHub) — how this is actually wired

The workstation repos use **DoltHub private DBs**, one per project:
`https://doltremoteapi.dolthub.com/jmohrbacher/<repo>` (e.g. `…/workstation`).
Private DBs need DoltHub Pro (~$0 under the 100 MB free tier for these small
DBs). Concrete facts learned wiring this up:

- **Shared credential, deployed via sops.** A single Ed25519 dolt cred (keyid
  `6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve`), associated with the DoltHub
  account, is reused by every project and every host. It's stored as the
  `dolthub_jwk` sops secret and materialized to `~/.dolt/creds/<keyid>.jwk` +
  `config_global.json` by `home.activation.deployDoltCreds` (NixOS hosts read
  `/run/secrets`; crostini symlinks the HM-sops secret; macOS reads Keychain
  item `dolthub-jwk`). A new project needs **no** new cred — just create the
  DoltHub DB, `bd dolt remote add`, and push.
- **Embedded push handles every remote type — no `dolt` binary needed.**
  `bd dolt push`/`pull` works via bd's in-process engine for DoltHub
  (remotesapi), **git+https**, AND **git+ssh** remotes alike. Verified
  2026-06-12: workstation→DoltHub; lgtm + pigeon→git+ssh `johnnymo87`;
  culops/mono/protos/internal-frontends→git+https work orgs. The standalone
  `dolt` CLI is only needed to *generate* creds (`nix run nixpkgs#dolt -- creds
  new`) or to *clone for verification* — and standalone `dolt clone` of a
  **git+ssh** remote is what needs dolt **1.88.1+** (nixpkgs has only 1.59.10).
  That version gap does NOT block `bd dolt push/pull` over git+ssh; it only
  means you can't verify a git+ssh backup with `dolt clone` (use
  `git ls-remote <url> refs/dolt/data` instead).
- **GOTCHA — `bd dolt remote add` commits to git even under `no-git-ops`.**
  Adding a remote / changing `sync.remote` writes `.beads/config.yaml` and
  makes a `bd: update sync.remote` commit on the host repo despite stealth
  mode. Expect it and push it (or revert if unwanted).
- **Verify a backup.** DoltHub/git+https remotes: clone and count —
  `nix run nixpkgs#dolt -- clone jmohrbacher/<repo> /tmp/x && cd /tmp/x && nix run nixpkgs#dolt -- sql -q 'select count(*) from issues'`
  and compare to `bd stats`. git+ssh remotes (can't `dolt clone` with nixpkgs
  1.59.10): confirm the ref landed with
  `git ls-remote <url> refs/dolt/data` (a non-empty hash = push succeeded).

### Per-repo git-backed dolt (alternative to DoltHub)

Most non-workstation trackers store dolt data **inside their own GitHub repo**
under `refs/dolt/data` instead of DoltHub — governance-friendly (work issues
stay in the work repo) and needs no DoltHub DB or shared cred, just existing
git auth. Set it up exactly like DoltHub but with a git URL:
`bd dolt remote add origin git+https://github.com/<org>/<repo>.git` (or
`git+ssh://git@github.com/<org>/<repo>.git`), then `bd dolt push`.

**Migrating a legacy sqlite tracker (`metadata.json` = `{"database":"beads.db"}`):**
bd ≥0.58 removed the sqlite backend, so current `bd` can't read old `beads.db`.
If a populated `.beads/embeddeddolt` already exists, that dolt data is the real
current state — just flip `metadata.json` to dolt mode and add a remote (do NOT
re-import a stale `issues.jsonl`; check the embeddeddolt issue count first). If
there's only sqlite, reconstruct a JSONL straight from the `.db` via SQL
(`json_object`/`json_group_array` over issues+dependencies+labels) and
`bd init --from-jsonl --prefix <p>`. Old `bd` binaries don't help: 0.57 forces
a dolt-server, 0.55 is schema-incompatible.

## Reference Files

| Topic | File |
|-------|------|
| bd vs TodoWrite decision criteria | [references/BOUNDARIES.md](references/BOUNDARIES.md) |
| Complete CLI with all flags | [references/CLI_REFERENCE.md](references/CLI_REFERENCE.md) |
| Dependency types and patterns | [references/DEPENDENCIES.md](references/DEPENDENCIES.md) |
| Workflow walkthroughs | [references/WORKFLOWS.md](references/WORKFLOWS.md) |
