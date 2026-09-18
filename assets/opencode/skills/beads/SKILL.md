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

## Claim Before You Start — And Check for a Branch

`bd ready` showing an item as unclaimed does **not** mean nobody is building it.
Two sessions on the same machine can hold the same bead in different checkouts,
and neither one's worktree is visible to the other.

This has already cost a full duplicate build. Two sessions independently
implemented the same bead (`pigeon-8cz`, 2026-08-03/04) — same three files, same
non-obvious design choices — because the first started without claiming and the
second checked only `bd ready`. One branch was merged; the other was deleted
whole.

Both halves are required, because each covers a different collision order:

```bash
# 1. Before starting, claim it — even for a "quick fix".
bd update <id> --claim
bd note <id> "claimed by session <ses_id>, worktree <abs path>"

# 2. Before starting, look for a branch someone else already has open.
git branch -a --sort=-committerdate | head -20
git branch -a | grep -i <keyword>     # e.g. the bead's subject
git worktree list                     # local checkouts on this machine
```

- **Claiming** stops `bd ready` advertising the item to a session that starts
  *after* you. It does nothing about work already in flight.
- **Checking branches** catches the reverse case — a peer already mid-flight,
  uncommitted, holding no claim. `bd` cannot see that; git can.
- **Put the worktree path in the claim.** The bead ID alone doesn't say which
  checkout holds it, and that is the fact a colliding session needs.

Skipping the claim because the fix is small is exactly how this happens: the
five-hour gap between "started" and "would have claimed on first commit" is the
window a peer picks the item up in.

## When to Use bd vs TodoWrite

| Use bd when | Use TodoWrite when |
|-------------|-------------------|
| Multi-session work | Single-session tasks |
| Complex dependencies | Linear step-by-step |
| Need to survive compaction | Immediate context only |
| Resume after weeks away | Simple checklist |

**Rule of thumb**: If resuming after 2 weeks would be hard without bd, use bd.

## Running a Whole Project on Beads

Worth the setup when tasks outnumber the sessions that will run them and the
dependencies are real — roughly eight or more, or any project handed to workers
who start cold. Below that, an epic with a few children and no ceremony is fine.

The failure this avoids: a plan document that says "do T3 after T6", which is
wrong the moment anything slips and which an appointed session cannot check.

```bash
bd create --title="<project>" --type=epic ...       # the epic
bd create --parent=<epic> --title="T1 ..." ...      # one child per task
bd dep add <child> <blocker>                        # the REAL dependencies
bd ready --parent=<epic>                            # the only entry point
```

### `bd ready` is the answer to "what's next" — don't write that answer anywhere else

Wire dependencies from the design, not from the order you wrote the tasks in.
Then `bd ready --parent=<epic>` lists what can start and `bd blocked --parent=<epic>`
says what is waiting on what, and neither can go stale.

Two rules keep it that way:

- **Want to start something `bd ready` omits? The graph is wrong.** Split the
  bead or drop the dependency — never launch around it. A bead covering two
  halves with different blockers is the usual cause: one cross-repo piece that
  could start cold, welded to a piece that could not.
- **"Do this one first" is a priority, not prose.** `bd ready` sorts by `-p`.
  A sentence in the runbook saying which ready task matters most is the same
  staleness you just designed out.

`bd ready` hides `in_progress`, so claimed work correctly disappears from it.

### Close at merge, not at PR-open

A code task is done when its PR **merges**. Closing when the PR opens releases
dependents whose worktrees then branch off a trunk that lacks the prerequisite —
and the breakage lands in the next task, not the one that caused it. Workers own
shepherding to merge, then `bd close --reason`.

### The runbook: where it goes, and how to revise it without wiping it

A project needs a page of prose a cold session reads first: how to launch a
worker, the standing rules, what is deliberately not tracked. Put it in the
epic's **`design`** field. `notes` is the append-only operational log (`bd note`,
or `bd update --append-notes`); design is authored content.

**Every `bd update` field flag REPLACES.** `--design` and `--description` carry
the same hazard as `--notes` (see "Never Write Notes With `bd update --notes`"
below), and the Quick Command Reference's `bd update <id> --design "..."` idiom
will silently wipe a runbook.

**The sharper rule: never put `$(...)` inside a replace-semantics flag.** If the
substitution fails it expands to empty and the flag cheerfully writes nothing,
with an ordinary success line. That is not hypothetical — it happened while
writing this section: a `bd update --description "$(...)"` whose subshell raised
a `KeyError` blanked a 1,025-character epic description. Recovered from
`bd history --json`, which carries the full prior object.

Use the file-taking form, from a file you have just read back:

```bash
bd update <id> --design-file runbook.md    # no substitution, no empty-write
```

**Or keep the runbook in the repo** and have the epic point at it. That buys git
history, PR review and no one-command wipe, at the cost of a second place to
look. Prefer it when the project already has a plan document in the tree and the
runbook will rarely change; prefer `design` when the runbook is short and the
bead should be self-contained for a session that has not cloned anything.

### The runbook explains how to launch, never what is next

Anything ordering-shaped belongs to the graph. The runbook covers only what
beads cannot:

- **A decision procedure**, top-down, so an appointed session need not judge
  where to start: open PR with unresolved threads → belongs to its authoring
  session; ready task → launch one; ready empty but tasks open → something
  in flight is blocking, report rather than force.
- **How to launch a worker** — command, worktree convention, model, and what
  every prompt must carry given the worker starts cold.
- **Standing rules**: never merge, never work at a shared repo root, one live
  session per worktree, no destructive git outside your own worktree.
- **What is NOT a bead and cannot be** — cross-team dependencies no session can
  discharge alone, deliberately-unset dates, adjacent defects out of scope.
  Without that list a diligent session will try one of them.
- **A task graph for orientation only**, labelled as such, so a surprising
  `bd ready` answer can be sanity-checked rather than second-guessed.

### Each child must be launchable cold

The child is the worker's whole briefing. Title plus "see the plan" is not
enough — the worker cannot tell which parts of that section are load-bearing.
Include the spec path **and section**, where to read it from if it is not merged
yet, the two or three traps specific to that task, and a scope fence: *implement
only this; if you find work belonging to another task, file a bead and leave it.*

Tell workers that a discovered bead needs `--parent=<epic>` and its dependencies
wired. Filed loose, it is invisible to `bd ready --parent` and falls off the
board.

### Claiming, and the launcher/worker race

Claim per "Claim Before You Start" above, then `bd note` the session id so the
next appointed session can tell in-flight from unstarted. **Decide whether the
launcher or the worker claims — not both.** `--claim` is actor-keyed and a
second actor gets an error; it only looks idempotent when both resolve to the
same git identity.

**If the launch fails after the claim, unclaim it.** A claimed bead with no
session behind it blocks everything downstream and reads as progress.

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
bd note bd-a1b2 "DONE: X. NEXT: Y. BLOCKER: Z"   # APPENDS -- see below
bd update bd-a1b2 --design "Decided approach A because..."

# Close when done
bd close bd-a1b2 --reason "Completed: summary of what was done"

# Sync & Cloud Backup (Dolt native replication)
bd dolt push                # Push database changes to Dolt remote (cloud backup)
bd dolt pull                # Pull database changes from Dolt remote
```

**IDs use hash format** like `bd-a1b2`, not sequential numbers.

## Never Write Notes With `bd update --notes`

`bd update <id> --notes "text"` **replaces the entire notes field**. It does not
append. It prints an ordinary success line either way, with no diff, no size
warning, and no confirmation prompt — so the only tell is a byte count nobody
was looking at.

```bash
bd note <id> "text"          # APPENDS. Always use this.
bd update <id> --notes "..." # REPLACES everything. Effectively never correct.
```

This has destroyed accumulated notes twice: 80,290 characters on one epic
(2026-08-25) and 38,903 on another (2026-08-11). Both were multi-week spines
that several sessions had built up.

Three general traps showed up in the second incident, each worth avoiding on its
own:

- **Read-modify-write across two commands is not atomic.** The pattern
  `helper.py … && bd update --notes "$(cat combined.txt)"` wrote a *stale* file
  that still held a different bead's notes. Never let a file sit between the
  read and the write.
- **A pipeline's exit status is the last command's.** `helper.py … | tail -3 &&
  bd update …` ran the update even though the helper had bailed, because `tail`
  returned 0. Don't pipe a guard through `head`/`tail` before `&&`.
- **An idempotency check on a truncated prefix isn't a check.** The guard
  compared the first 60 characters of the addition; for a note starting with a
  `=====` banner that slice is just equals signs, present in every prior note,
  so it fired every time.

**If it happens anyway, notes are recoverable.** They're versioned in Dolt:

```bash
bd history <id> --limit 20 --json    # each revision carries the full Issue object
```

Pick the `CommitHash` from just before the clobber and lift the old `notes`
value straight out of the JSON. Use the `--json` output specifically — it
carries full 32-character hashes, and both `bd show --as-of` and `bd diff`
reject the short hashes that `bd history` prints in its human-readable output
(`branch not found`). Beads keeps roughly 250 revisions per issue, so this stays
available for a long time — but only if someone notices.

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

**Every tracker — personal AND work — uses a DoltHub private DB** under
`jmohrbacher/<repo>` (`https://doltremoteapi.dolthub.com/jmohrbacher/<repo>`,
e.g. `…/workstation`). **Never git+https or git+ssh**, regardless of whether
the code repo lives in a personal (`johnnymo87`) or a work GitHub org —
git-backed dolt pollutes the code repo's git (see anti-pattern below). All
trackers are also **stealth** (`.beads` gitignored, `no-git-ops: true`).
Private DBs need DoltHub Pro (~$0 under the 100 MB free tier for these small
DBs). Concrete facts learned wiring this up:

- **Shared credential, deployed via sops.** A single Ed25519 dolt cred (keyid
  `6fnahnt9ls5iud8ac4eulmqf535p13co1jcjrluch86ve`), associated with the DoltHub
  account, is reused by every project and every host. It's stored as the
  `dolthub_jwk` sops secret and materialized to `~/.dolt/creds/<keyid>.jwk` +
  `config_global.json` by `home.activation.deployDoltCreds` (NixOS hosts read
  `/run/secrets`; macOS reads Keychain
  item `dolthub-jwk`). A new project needs **no** new push cred.
- **Creating the DB needs a *different* token.** DoltHub does NOT auto-create a
  DB on push (pushing to a nonexistent DB fails with `permission denied`). The
  `dolthub_jwk` push cred can't create DBs — that's the **remotesapi** (gRPC).
  DB creation goes through the **v1alpha1 REST API**, authed with a separate
  DoltHub API token (`dolthub.com/settings/tokens`), stored as the
  `dolthub_api_token` sops secret (exported `DOLTHUB_API_TOKEN`). Create + wire:
  ```
  curl -s -X POST https://www.dolthub.com/api/v1alpha1/database \
    -H "authorization: token $DOLTHUB_API_TOKEN" -H 'content-type: application/json' \
    -d '{"ownerName":"jmohrbacher","repoName":"<repo>","visibility":"private"}'
  bd dolt remote add origin https://doltremoteapi.dolthub.com/jmohrbacher/<repo>
  bd dolt push
  ```
- **Embedded push needs no `dolt` binary.** `bd dolt push`/`pull` to a DoltHub
  (remotesapi) remote works via bd's in-process engine. (bd *can* also push
  over git+https/git+ssh, but we deliberately do NOT — see the anti-pattern
  below.) The standalone `dolt` CLI is only needed to *generate* creds
  (`nix run nixpkgs#dolt -- creds new`) or to *clone a DoltHub DB for
  verification/backup* (`nix run nixpkgs#dolt -- clone jmohrbacher/<repo>
  /tmp/x`). Confirmed across both personal and work trackers — workstation,
  pigeon, chatgpt-relay, mono, internal-frontends, protos — all on DoltHub.
- **GOTCHA — `bd dolt remote add` commits to git even under `no-git-ops`.**
  Adding a remote / changing `sync.remote` writes `.beads/config.yaml` and
  makes a `bd: update sync.remote` commit on the host repo despite stealth
  mode. Expect it and push it (or revert if unwanted).
- **Verify a backup.** Count issues straight off DoltHub via the REST API and
  compare to `bd stats`:
  ```
  curl -s -G https://www.dolthub.com/api/v1alpha1/jmohrbacher/<repo>/main \
    -H "authorization: token $DOLTHUB_API_TOKEN" \
    --data-urlencode 'q=select count(*) from issues'
  ```
- **Deleting a DoltHub DB is UI-only.** The v1alpha1 API has create/fork but
  **no delete endpoint**, so a database can only be removed from its DoltHub
  settings page (`https://www.dolthub.com/repositories/jmohrbacher/<repo>/settings`,
  Danger Zone → Delete). Always `nix run nixpkgs#dolt -- clone jmohrbacher/<repo>
  /tmp/<repo>-backup` first.

### Do NOT use git-backed dolt for these repos (anti-pattern)

`bd dolt remote add origin git+ssh://…/<repo>.git` (git-backed dolt) *works* —
bd's embedded engine pushes/pulls over git+ssh and git+https fine — **but it
writes the tracker into the code repo's git** as `refs/dolt/data` AND a
`refs/heads/__dolt_remote_info__` **branch**, polluting the repo (the branch
shows in GitHub's branch list, PR base pickers, etc.). We tried git-backed for
mono/protos/internal-frontends/pigeon/culops/lgtm on 2026-06-12 and reverted —
all six now use **DoltHub private DBs** (above). If you find these refs on a
code remote, delete them:
`git push <url> :refs/dolt/data :refs/heads/__dolt_remote_info__`.
(The dolt 1.88.1+ requirement only affects standalone `dolt clone` of a git+ssh
remote, never `bd dolt push/pull` — but that's moot now since we use DoltHub.)

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
