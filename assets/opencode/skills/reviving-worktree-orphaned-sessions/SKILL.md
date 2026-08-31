---
name: reviving-worktree-orphaned-sessions
description: Use when an opencode session stops responding after its working directory (usually a git worktree) was deleted — symptoms are assistant turns that finish instantly with zero output, swarm messages that get delivered but never answered, or "prompt_async failed ... FileSystem.realPath ... ENOENT" in the serve log. Also use before deleting or pruning any worktree that a live session is sitting in.
---

# Reviving Worktree-Orphaned Sessions

A session whose `directory` is deleted becomes a zombie: it accepts prompts and produces nothing, forever. **Recreating the directory at the same path does not fix it.** The serve caches the failed path resolution; you must give the session a path it has never seen.

## Symptoms

All three appear together:

- Assistant messages exist in the DB with **zero parts** and near-zero tokens — turns "complete" in under a second with no text.
- The human sees silence. So does a swarm peer; `swarm_send` reports `queued`/delivered, the recipient never answers.
- The serve log has, per prompt:
  ```
  level=ERROR message="prompt_async failed" sessionID=ses_...
    cause="Cause([Die(PlatformError: NotFound: FileSystem.realPath (/path/to/worktree)
    (cause: Error: ENOENT: no such file or directory, lstat '/path/to/worktree'))])"
  ```

The serve returns **HTTP 204** for these prompts — it never validates the directory, so the failure is invisible to the sender. Pigeon documents the same measurement in `packages/daemon/src/swarm/arbiter.ts` (`pigeon-0ay7`) and preflights the directory before sending for exactly this reason.

## Diagnosis

`sqlite3` is not on PATH here; use `nix run nixpkgs#sqlite --`.

```bash
DB=~/.local/share/opencode/opencode.db
S=ses_xxxxxxxx

# 1. What directory does the session think it has, and is it there?
nix run nixpkgs#sqlite -- "$DB" "select directory from session where id='$S';"
ls -ld "$(nix run nixpkgs#sqlite -- "$DB" "select directory from session where id='$S';")"

# 2. Confirm the failure mode in the log (not just that it is quiet)
grep -a "$S" ~/.local/share/opencode/log/opencode.log | grep -a -E "ERROR|loop" | tail -5
```

Also recover the session's last real output, so you know what it was doing:

```bash
nix run nixpkgs#sqlite -- "$DB" "select datetime(m.time_created/1000,'unixepoch','localtime'), substr(p.data,1,300)
  from part p join message m on p.message_id=m.id
  where m.session_id='$S' order by m.time_created desc limit 6;"
```

## The trap

Recreating the worktree **at its original path leaves the session dead**, and nothing says so — you get the identical ENOENT for a path that now exists. Measured on cloudbox 2026-08-31: dir restored at 22:46:52, ENOENT for that exact path at 22:47:19 and again at 22:48:42.

The serve is not blind to the filesystem; it is holding a memoized failure. Confirm the process can see the restored dir before concluding anything about permissions or namespaces:

```bash
PID=$(pgrep -f "opencode serve --port $PORT")
ls -ld "/proc/$PID/root/$RESTORED_PATH"   # resolves fine — yet the turn still ENOENTs
```

## The fix: give it a path it has never seen

```bash
cd <repo>
git worktree add .worktrees/<slug> <branch>          # if the tree is gone entirely
git worktree move .worktrees/<slug> .worktrees/<slug>-r2

nix run nixpkgs#sqlite -- ~/.local/share/opencode/opencode.db \
  "update session set directory='<repo>/.worktrees/<slug>-r2' where id='$S';"
```

Then send one probe asking for `pwd` and `git log --oneline -1`, and confirm the serve log shows `message=loop session.id=... step=0` advancing past step 0. Empty turns mean it is still dead.

**Do not delete the new path afterwards** — it is the session's cwd, and deleting it re-arms the same bug.

## Restarting the serve is the wrong first move

It clears the cache, but a pool serve carries many unrelated sessions and kills their in-flight turns. Count them before you consider it:

```bash
nix run nixpkgs#sqlite -- ~/.local/share/opencode/opencode.db \
  "select s.id, s.title from session s join message m
     on m.id=(select id from message where session_id=s.id order by time_created desc limit 1)
   where m.data like '%\"port\":\"4098\"%'
     and m.time_created > (strftime('%s','now')-3600)*1000;"
```

The path swap costs one session nothing; the restart costs every co-tenant a turn.

## What survives, and what does not

Committed work is safe — the branch ref outlives the worktree, so `git worktree add <path> <branch>` restores it. **Uncommitted and untracked files are gone**, including scratch DBs. Tell the revived session to verify HEAD and report what is missing rather than reconstruct from memory; it cannot tell the difference between "I did that" and "that got committed".

## Prevention

Before `git worktree remove`/`prune` or any cleanup of `.worktrees/`, check whether a live session is sitting there:

```bash
nix run nixpkgs#sqlite -- ~/.local/share/opencode/opencode.db \
  "select id, title from session where directory like '%<slug>%';"
```

## Related

- `monitoring-serve-pool` (workstation repo-local) — wedged vs. frozen serves, canary recovery. A worktree orphan is neither; the serve is healthy and only this session is dead.
- `swarm-messaging` — a peer that has gone silent may be orphaned rather than busy. Silence plus `queued` deliveries is the tell.
