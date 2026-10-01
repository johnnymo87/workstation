# oc-revive

Revive OpenCode sessions whose git worktree directory was deleted.

## Problem

A session whose git worktree was deleted is permanently read-only: the serve memoizes the failed path lookup (`LayerMap` with idle TTL), so recreating the directory at the original path does **not** revive it — prompts return 204 and every turn completes empty forever (a zombie session).

The only repair is to:
1. Create a fresh git worktree at a path no serve has ever resolved (`.worktrees/<slug>-r<epoch>`).
2. Move the session onto that path via the front door (`POST /session/<sid>/move`).
3. Send a synthetic `noReply` notice to inform the agent of the new path.

## Usage

```bash
# Plan revival (JSON output)
oc-revive plan <session_id>

# Interactive revival (prompts y/N, default No)
oc-revive <session_id>

# Machine apply interface (called by interactive mode)
oc-revive apply <session_id> --branch <branch> --path <path> --action add --expect-tip <sha> --expect-old-dir <dead_dir>

# Resume an in-flight revival without creating a worktree
oc-revive apply <session_id> --resume --branch <branch> --path <path> --expect-tip <sha> --expect-old-dir <dead_dir>
# or
oc-revive resume <session_id> --branch <branch> --path <path> --expect-tip <sha> --expect-old-dir <dead_dir>
```

When `plan` reports `blocked_by_worktree` (a prior revive created the worktree but never
finished), its JSON carries a structured `resume` object (`branch`, `path`, `expect_tip`,
`expect_old_dir`) alongside the prose command. Machine consumers should use the object. The key
is absent, never `null`, whenever there is nothing to resume (for example, the worktree is held by
another session).

## Failing post-checkout hooks

`git worktree add` returns a failing post-checkout hook's exit status even though the worktree
was created. Overcommit, for example, exits 127 when `ruby` is not on PATH outside the repo's dev
shell. `apply` then checks `git worktree list`. If the new path is on the requested branch at
`--expect-tip`, unlocked, and git exited with a positive status (not a signal), it prints a
warning with the hook's output and continues. Otherwise it removes the worktree it just created and
stops before recording or moving anything.
