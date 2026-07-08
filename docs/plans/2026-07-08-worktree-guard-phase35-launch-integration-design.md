# Design: Phase 3.5 — land writable sessions in a fresh worktree at launch

Status: **PROPOSAL — awaiting operator sign-off. NOT implemented.**
Date: 2026-07-08
Bead: workstation-v03j.5
Parent design: `2026-07-08-worktree-guard-readonly-main-design.md`
Depends on: Phase 1 `work` helper (shipped), Phase 2 guard plugin (shipped, warn), Phase 3 pre-commit hook (shipped).

## Problem this closes

Phases 1–3 make it *cheap* (`work`) and *noisy/blocked* (plugin warn + commit hook)
to work in the mono primary root. But they don't remove the **root cause named in
the parent design**: sessions *start* with cwd = the primary root and inertia keeps
them there. Enforcement alone is a friction surface; the durable fix is to make a
*writable* session **start in a fresh worktree by construction**, so the guard
becomes a rarely-hit backstop rather than a wall the agent keeps hitting.

## The hard question (why this is its own design)

"Default *writable* sessions into a worktree" assumes we can tell, at launch, whether
a session is **writable** (wants to edit → give it a worktree) or **read-only**
(coordinator / monitor / reviewer / "what does this code do?" → wants the clean
current root to read). **opencode has no such signal.** `opencode-launch` takes
`(directory, prompt)` and nothing else; `reset-workspace`/`oc-auto-attach` reopen a
session at its recorded cwd. Guessing wrong is costly both ways:
- Force a worktree on a read-only session → pointless worktree churn (~117 already),
  and coordinators/monitors that *want* the root get displaced.
- Leave a writable session at the root → the exact problem we're solving.

So "default = always worktree" is **wrong**, and "default = never" is the status quo.
The honest first step is an **explicit opt-in** that the callers who *know* the intent
can set, plus a path to smarter defaulting later.

## Proposal: opt-in `--worktree` on `opencode-launch` (v1)

Add a flag to `pkgs/opencode-launch/default.nix`:

```
opencode-launch [--worktree <slug>] [--model …] [--mcp …] [directory] <prompt>
```

Behavior: after `directory` is resolved (`pkgs/opencode-launch/default.nix:178-190`)
and **before** the session is created (`:256` `x-opencode-directory: $directory`):
- if `--worktree <slug>` is set, run the shipped `work <slug>` **in `$directory`**
  (which must be a git repo), capture the created worktree path, and **reassign
  `directory` to that path**. The session, its pool placement, MCP connects, and the
  auto-attached TUI then all target the worktree — no other code changes, because
  everything downstream keys off `$directory`.
- on `work` failure (not a repo, slug exists, `origin/HEAD` unset) → **fail the
  launch loudly** with `work`'s message; do not silently fall back to the root
  (silently launching at the root is the bug).
- `--worktree` with no slug → derive a slug from a sanitized prompt prefix + short
  timestamp, or require the slug (lean: require it; explicit > magic).

Why opt-in first: it's **zero-risk to the default path** (absent the flag, launch is
byte-for-byte unchanged), it **composes** the already-shipped `work` (no new
worktree logic), and it gives the callers who know intent a one-flag fix:
- swarm spin-up (`swarm-shaped-work`): each worker `--worktree <task-slug>`.
- the morning reset recommendation agent: reopen *writable* work in worktrees,
  leave coordinators/monitors at the root.
- any `opencode-launch` caller doing implementation work.

## Interaction with shipped pieces

- A session launched via `--worktree` has cwd = a linked worktree ⇒ its
  `git rev-parse --show-toplevel` ≠ the enrolled root ⇒ the **warn plugin never
  fires** and the **commit hook allows commits** there. Correct by construction.
- Read-only sessions launched *without* the flag stay at the root ⇒ they get the
  clean current trunk to read (what the "anchor to origin/main" rule wants) and only
  see a warn if they actually try to *edit*. Correct.
- No change to the pool/tmux/project-key path: `oc-auto-attach` already collapses
  `~/projects/<P>/.worktrees/<W>` → project `<P>` (`pkgs/oc-auto-attach/default.nix:365`),
  so a worktree session still routes to the right project's nvim/tmux window.

## Deliberately NOT in v1 (future "smart default")

Auto-defaulting writable→worktree needs a writable signal. Options to explore later,
each with cost:
- **Prompt-classification** (cheap heuristic: verbs like "implement/fix/refactor"
  vs "review/what/why") — brittle, false both ways.
- **A `--readonly` inverse** so the *default* becomes worktree and read-only is the
  opt-out — flips the blast radius; only safe once most callers are updated.
- **Agent/model signal** — reviewers/oracle are read-only by role; but the primary
  session's intent isn't known at launch.
Defer until the opt-in is adopted and we can measure how often writable launches
actually hit the warn guard at the root (that rate is the evidence for defaulting).

## Verification

- `opencode-launch --worktree smoke ~/projects/mono "noop"` → session cwd is
  `~/projects/mono/.worktrees/smoke` (check `x-opencode-directory` / the TUI cwd);
  remove the worktree after.
- Absent `--worktree`, launch is unchanged (diff the created-session directory).
- `work` failure (bad repo / existing slug) → launch exits non-zero with the reason,
  creates no session.
- A `--worktree` session editing a file ⇒ NO warn (toplevel ≠ root); a root session
  editing ⇒ warn. (Ties back to Phase 2 behavior.)
- Swarm smoke: spin up 2 workers with `--worktree`; confirm each lands in its own
  worktree and routes to the right tmux window; coordinator stays at root.

## Rollback

Single flag in one package; removing the `--worktree` branch reverts it. No state,
no migration, no effect on existing launches.

## Open questions

1. Slug required vs. auto-derived? (lean: required — avoids swarm slug races.)
2. Thread `--trunk` through, or scope `--worktree` to repos with `origin/HEAD`
   set (mono has it) for v1?
3. Interactive TUI convenience for a human in a root session — defer (CLI only).

---

## Review outcome (2026-07-08 adversarial review) — supersedes the opt-in framing

Verdict: **the mechanism is sound (verified: reassigning `$directory` to a
`work`-created worktree rides the existing plumbing, and the guard-bypass-by-
construction holds), but shipping it as a bare opt-in flag is the wrong stopping
point.** Build the mechanism WITH the lifecycle + one automated caller below.

### Must-fix before build

- **M1 (BLOCKER) — worktree+branch leak / no pruning owner.** `work` creates the
  worktree+branch *before* the session; every post-creation failure path in
  `opencode-launch` (health `:208`, model resolve `:232`, session create `:256`,
  MCP connect `:299`, prompt send `:330`) then orphans it, and even the happy path
  leaves a permanent worktree+branch nobody removes — manufacturing the exact churn
  the design warns about. **Fix:** (a) call `work` *just before* session create
  (after health+model checks) to shrink the window; (b) add an `EXIT`/`ERR` trap
  that removes the just-created worktree+branch if launch exits before success;
  (c) **name a pruning owner** — add `work --prune-merged` (removes launch-created
  worktrees whose branch is merged/gone) and have `reset-workspace` sweep it. No
  pruning story ⇒ do not ship.
- **M2 — unbounded network `fetch` breaks the launcher's "degrade, never fail"
  invariant.** `work`'s `git fetch` has no timeout (`git-work/default.nix:173`),
  but the launcher's critical path is all localhost-curl with `--max-time` +
  documented fallbacks. **Fix:** bound the fetch (`--max-time`/`timeout`), and make
  it **best-effort** — a worktree off the *local* `origin/<trunk>` is already far
  fresher than the rotted root, so a failed/slow fetch should still produce the
  worktree, not kill the launch. (Keeps the freshness win without a hard network
  dep.) `work` needs a `--no-fetch`/best-effort mode to support this.
- **M3 — ship the flag WITH ≥1 defaulting caller, not as a follow-up.** A flag the
  caller must remember is the same "remember to make a worktree" failure moved up a
  level; it only escapes that for *programmatic* callers you update once. Land
  `--worktree` **and** wire swarm spin-up (each worker `--worktree <task-slug>`)
  and/or the `reset-workspace` recommendation prompt (writable reopens →
  `--worktree`) in the same change. Reserve the raw flag for humans/ad-hoc use.
- **M4 — graduation metric is wrong.** "warn-hit-rate at root" conflates
  forgot-worktree with genuine-readonly-did-one-edit (the guard keys on path, not
  intent) and *decreases* as adoption succeeds (circular). **Use adoption rate**:
  fraction of task `opencode-launch` invocations passing `--worktree`; if it trends
  ~100% for task launches, flip default-on + add `--readonly`.

### Also fix

- **`work` invocation contract:** `work` takes no dir arg and derives root from
  `$PWD`; implement as `(cd "$directory" && work <slug>)`. Thread `--trunk` or
  document v1 as mono-only (repos without `origin/HEAD` fail every `--worktree`).
- **Reset-reopen lifecycle hole (was Hunt #4):** a writable session recorded in a
  worktree that's later pruned/merged → on reopen its `directory` points at a
  deleted path. `oc-auto-attach` opens the tmux pane at the *collapsed root*
  (survives), but the opencode session's `directory` is stale. **Add:** on reopen,
  if the recorded worktree dir is gone, fall back to the project root (and/or don't
  prune worktrees with a live session).
- **Rollback/verification honesty:** reverting the code does NOT remove
  already-created worktrees/branches (depends on M1's prune). Two swarm workers in
  the same repo share one tmux window/nvim (collapse to project_key) as tabs — state
  the expected behavior so the verifier isn't misled.

### Reconsider (post-M1)

Once the prune lifecycle exists, the cost of an "unwanted worktree" drops to
near-zero, which tilts the trade toward **default-worktree-for-controlled-callers +
`--readonly` escape** rather than opt-in. That — mechanism + owned lifecycle +
automated-caller default — is what makes writable sessions land in a worktree *by
construction* (the parent design's goal). Re-decide default-vs-opt-in after M1
lands rather than asserting opt-in now.
