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
oc-revive apply <session_id> --branch <branch> --path <path> --action add --expect-tip <sha>
```
