# Design: read-only `main` + enforced fresh-worktree work (mono v1)

Status: **APPROVED SCOPE (rev.3) — NOT implemented.**
Date: 2026-07-08
Author: design exploration session. Revised after adversarial review (verified
against live mono + opencode 1.17.13 source) and operator sign-off on the v1
scope.
Sibling: `2026-07-02-subagent-destructive-git-guard-plugin-design.md` (blocks
destructive git *verbs* for the 4 review subagents — a different axis; keep
separate).

## Problem

opencode agents (opus sessions) keep working **directly in `~/projects/mono`'s
primary `main` checkout** instead of creating a fresh git worktree. The rule
("always use a fresh worktree; anchor reads to `origin/main`; never edit the root
checkout") is documented in `mono/AGENTS.md` and bd memory
`anchor-current-behavior-reads-to-origin-main`, but **docs are advisory and
agents still violate them.**

Evidence (2026-07-08): the mono root is on `main`, **84 behind / 1 ahead** of
`origin/main`, with **26 dirty files** — a stray commit landed *on `main`* plus
cruft accumulated. Meanwhile ~117 worktrees under `.worktrees/*` prove the
convention works *when followed*; it's the primary root that rots.

**Failure modes:** (1) inertia of the start dir — every session's cwd is the
root, on `main`, so the first edit lands there; (2) advisory ≠ enforced; (3)
read/edit conflation — the read-rule sends agents to main, then editing is one
keystroke away; (4) no frictionless worktree alternative at the moment of
temptation; (5) subagents inherit the root cwd; (6) staleness compounds.

**Root cause:** a *writable, stale* working tree sits on `main` at the default
start dir. The fix attacks that from two sides — remove the *ergonomic* write
path into main, and remove the *reason* to be at main in the first place.

## Goal (v1, mono only)

Make it the path of least resistance to land in a fresh worktree, and block the
dominant accidental-edit path into the root:

- **Ergonomic:** default *writable* sessions to start in a fresh worktree; give a
  one-command `work` helper. Read-only/coordinator/monitor sessions still open at
  the root (they *want* the clean current trunk to read).
- **Enforcement:** block opencode edit-tool writes and commits that land on the
  mono root, at the opencode tool layer + a git `pre-commit` backstop.

## Explicitly out of scope for v1 (deferred)

- **ff-only auto-updater timer.** `work` already `fetch`es trunk before creating
  a worktree, so new worktrees are fresh regardless. The timer only serves
  "root is current to read," which it *can't reliably guarantee* (see "Honest
  limits") — poor value/complexity. Revisit later if reads off root prove stale
  often.
- **nix multi-repo enrollment list.** YAGNI for a one-repo problem. The
  generalization (a `worktreeGuard.repos` nix attrset driving plugin config +
  per-repo timers + hooks) is a clean *eventual* knob; add it once mono proves
  out over a few weeks.
- **Bare-repo relayout / filesystem read-only perms.** High blast radius / breaks
  builds. Rejected.

## What v1 builds

### 1. `pkgs/git-work/default.nix` — the `work` helper

`work <slug> [branch]`:
- derive the primary root from `$PWD` using the same collapse rule as
  `oc-auto-attach` (`~/projects/<P>/.worktrees/<W>` → `~/projects/<P>`, see
  `pkgs/oc-auto-attach/default.nix:365`).
- trunk = explicit config else `git symbolic-ref --short
  refs/remotes/origin/HEAD` (fall back to a loud error if unset — see M6).
- `git -C <root> fetch origin <trunk>` →
  `git -C <root> worktree add <root>/.worktrees/<slug> -b <branch> origin/<trunk>`
  → print the path (and `cd` when invoked as `eval "$(work --cd <slug>)"`).
- fail loudly on slug/branch collision; never `-B`.

This is what the guard's block message tells the agent to run, so a block is a
one-liner redirect, not a dead end.

### 2. `assets/opencode/plugins/worktree-guard.ts` (+ vitest) — enforcement

Config-driven (reads a small config; for v1 it can be a single hardcoded mono
root + trunk, or a minimal JSON — no nix generalization yet).

`tool.execute.before`, guarding the tool set **`{edit, write, apply_patch,
bash}`**:
- **`edit`/`write`:** `p = output.args.filePath`. **Resolve `p` against the
  session dir if relative** (the hook input has no cwd; use
  `PluginInput.directory`/`worktree`). Cheap-reject if `p` can't be under the
  root; else compute `git rev-parse --show-toplevel` of the nearest existing
  parent dir; if it **exactly equals** the mono root, apply `enforce`.
- **`apply_patch`:** args are `{ patchText }` — **no `filePath`**. Parse
  `patchText`; check the toplevel of **each** `hunk.path` (resolved against the
  session dir); block if any is the root.
- **`bash`:** detect `git commit`/redirection into the root (secondary; the git
  hook is the real commit backstop). Reuse the sibling plugin's segment splitter.
- `enforce: "warn"` ⇒ log + system note (rate-limited); `"block"` ⇒ throw an
  actionable error naming `work <slug>`.

**Correctness invariants (verified against live mono + 1.17.13 source):**
- **Discriminate on `git rev-parse --show-toplevel == root`, never a string
  prefix.** `.worktrees/*` lives physically under the root path but reports its
  *own* toplevel; `/tmp/opencode/*` and `~/projects/mono-*` worktrees report
  theirs too. Equality-on-toplevel allows all of them and blocks only the root.
- **The tool id is `apply_patch`, not `patch`.** It's the *only* file-write tool
  GPT-class models get (`usePatch = modelID.includes("gpt-")`), while Claude/opus
  get only `edit`+`write`. Missing it = a silent 100% bypass the day a
  cost-efficient GPT subagent runs. A **snapshot test of built-in tool ids + arg
  field names** must fail loudly if a future opencode renames/reshapes them.
- **Key on path, not agent.** The hook input carries no agent name — path keying
  is both simpler and the only cheap option.
- **Blast-radius discipline:** this hook runs on every matching tool call in
  every session. Early-return cheaply before any git call; wrap resolution in
  try/catch; **only ever throw on a positive match — never fail-closed on an
  error** (a bug degrades to "allow," never "break all edits"). A thrown hook is
  an Effect *defect* caught per-tool by the tool path's `catchCause` on 1.17.13;
  the Phase-0 spike must re-confirm this on the pinned version and on every
  opencode upgrade.

### 3. `pre-commit` backstop (mono, local)

Reject a commit when `git rev-parse --show-toplevel` == the mono root (same rule;
allows `.worktrees/*` commits). This is the **real** containment for
bash-written dirt (the plugin only covers the opencode edit tools).

Mono is shared corporate infra — **do not commit hooks into it.** Set a **local**
`core.hooksPath` for this clone only (via a home-manager activation-script
`git config`, since `~/projects/mono/.git/config` is mutable and outside the nix
store). Watch for a future husky/pre-commit adoption in mono (none today).

### 4. Default writable sessions into a worktree (attack root cause #1)

At the existing launch choke points (`opencode-launch`, `reset-workspace`,
`oc-auto-attach`), default a *writable* session to open in a fresh worktree
(pair with `work`); keep read-only/coordinator/monitor sessions at the root. This
turns the block into a rarely-hit backstop instead of a friction surface the
operator wants to disable — **enforcement + ergonomics beats enforcement alone.**

## Honest limits (do not oversell)

- The guard removes the *dominant, ergonomic* write path (the edit tools the
  model reaches for first) and makes commits impossible at the root. It does
  **not** make the root physically unwritable: bash `>`, `tee`, `sed -i`,
  `python -c` can still dirty it. Realistic containment ≈ 80–90% for good-faith
  agents; the `pre-commit` hook is what stops the residue from becoming a commit.
- Because the guard can't keep the root clean, an ff-only updater could **not**
  be assumed to always fast-forward (untracked collisions abort it). That's why
  the timer is deferred; if added later its only safe behavior is log+skip
  (never `reset`/`stash`/`clean` — honors the shared-worktree rule), which means
  the root can silently stall behind trunk.
- Nothing keeps the root *on* trunk (a bash `git switch` moves it, unguarded). If
  that becomes a problem, prefer a loud notification over silent handling.

## Interaction with existing machinery

- **reset-workspace / oc-auto-attach** reopen sessions in their original cwd; a
  read-only root is a fine cwd. The project-key collapse already agrees with the
  guard's root definition.
- **Swarm workers** `work <slug>` into their own `.worktrees/*` (own toplevel) ⇒
  never blocked. **Coordinators** read the root ⇒ what the read-rule wants.
- **Subagents** (`implementer`, reviewers) run in the same process ⇒ the guard
  covers them too (with the `apply_patch` fix, on any model).

## Open decisions

1. Is forcing a full worktree for a one-file `docs/*.md` commit at root
   acceptable? (Most likely trigger for the operator to flip `enforce` back to
   `warn`.) — leaning: yes, acceptable; `work` makes it cheap.
2. warn→block bake-in: measure both false-positive rate **and** that a blocked
   `implementer` recovers via the `work` hint (doesn't thrash).
3. Config shape for v1: hardcoded mono root vs. a minimal JSON now (to ease the
   later nix generalization). — leaning: minimal JSON, one entry.

## Rollback

Each piece is independently removable: delete the plugin `xdg.configFile` line;
drop `pkgs/git-work`; `git config --unset core.hooksPath`; revert the launch
choke-point default. No shared-repo content is mutated.
