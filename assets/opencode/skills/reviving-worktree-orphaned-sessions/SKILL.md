---
name: reviving-worktree-orphaned-sessions
description: Diagnoses and revives an opencode session whose working directory was deleted. Use when a session stops answering swarm messages or shepherd wakes, when lgtm-shepherd logs "(human: worktree-gone)" or "dir_exists=no" for a PR, when pigeon logs "TargetUnavailableError ... working directory missing", when assistant turns finish instantly with zero output, or when the serve log shows "prompt_async failed ... FileSystem.realPath ... ENOENT". Also use before deleting or pruning any worktree that a live session may be sitting in.
---

# Reviving Worktree-Orphaned Sessions

A session whose `directory` no longer exists breaks in one of two ways. The fix is the same for both: point `session.directory` at a path that exists and that the serve has never failed to resolve.

| Mode | What you see | Seen |
|---|---|---|
| **Zombie** | Every turn finishes in under a second with zero parts. Human and swarm prompts alike get silence. Serve log: `prompt_async failed ... realPath ... ENOENT`. | cloudbox 2026-08-31 |
| **Half-alive** | A human typing in Telegram or the TUI gets normal answers. Every *automated* route refuses it: pigeon's swarm arbiter will not send (`working directory missing`), and lgtm-shepherd sends the session's PR alerts (`ci_red`, `conflicted`, `needs_reply`) to the human instead (`human: worktree-gone`). | devbox 2026-11-02 |

Half-alive is the more dangerous one: the session answers when you ask it something, so it looks healthy, but it has stopped receiving swarm messages and shepherd wakes. "It replied to me" is not evidence the session is fine.

## Workflow

```
- [ ] 1. Confirm the directory is gone (Diagnosis)
- [ ] 2. Pick the new path (Choosing the path)
- [ ] 3. Update session.directory
- [ ] 4. Wait out pigeon's cache, then probe
- [ ] 5. Find messages that failed during the outage and tell their senders
```

## Diagnosis

`sqlite3` is not on PATH; use `nix run nixpkgs#sqlite --`.

```bash
S=ses_xxxxxxxx
DB=~/.local/share/opencode/opencode.db

# The directory the session has, and whether it exists
D=$(curl -s http://127.0.0.1:4096/session/$S | jq -r .directory); echo "$D"; ls -ld "$D"

# Automated routes refusing it (either is enough to act on)
journalctl --namespace=pigeon --since -1d --no-pager | grep "$S" | grep -E "working directory missing|max attempts" | tail -5
journalctl -u lgtm-shepherd.service --since -1d --no-pager | grep "$S" | grep "dir_exists=no" | tail -5

# Zombie mode only: the serve-side failure
grep -ahs "$S" ~/.local/share/opencode/log/opencode.log{.1,} | grep -a ERROR | tail -5
```

Pigeon logs to its own journal namespace; plain `journalctl -u pigeon-daemon` shows nothing.

Record what the session was last doing, so you can brief it:

```bash
nix run nixpkgs#sqlite -- "$DB" "select datetime(m.time_created/1000,'unixepoch','localtime'), substr(p.data,1,300)
  from part p join message m on p.message_id=m.id
  where m.session_id='$S' order by m.time_created desc limit 6;"
```

## Choosing the path

A path is safe if it exists and the serve has never failed to resolve it. **Recreating the deleted path is NOT safe**: the serve has memoized the failure, and the session keeps getting ENOENT for a directory that now exists (cloudbox 2026-08-31: restored at 22:46:52, ENOENT for that exact path at 22:47:19 and 22:48:42).

Use the first that applies:

1. **The session's branch is already checked out in another worktree** (`git worktree list | grep <branch>`). Use that path. You cannot `git worktree add` a branch that is checked out elsewhere anyway. First check that no other *main* session is sitting there (subagent children of this session are fine):
   ```bash
   nix run nixpkgs#sqlite -- "$DB" "select id, title from session where directory = '<path>' and parent_id is null;"
   ```
2. **The branch is not checked out anywhere:** `git worktree add .worktrees/<slug>-r2 <branch>`.
3. **You already restored the old path:** `git worktree move .worktrees/<slug> .worktrees/<slug>-r2`.

## Updating the directory

Do this between turns (the session's last message is a finished assistant turn):

```bash
nix run nixpkgs#sqlite -- "$DB" "update session set directory='<new-path>' where id='$S';"
curl -s http://127.0.0.1:4096/session/$S | jq -r .directory   # serves read the change immediately
```

**Pigeon caches each session's directory for up to 5 minutes** (`packages/daemon/src/swarm/registry.ts`, `ttlMs` in `routing/directory-resolver.ts`). Until the cached entry expires, swarm sends keep failing with the *old* path in the error. Wait 5 minutes before probing, or send the probe anyway; it is retried once a minute, 10 attempts in total.

Probe with one swarm message asking for `pwd` and `git log --oneline -1` *without* a workdir override. The reply, arriving via the swarm, proves both that the path resolves and that automated delivery works again. The next shepherd sweep (every 10 min) should then log `dir_exists=yes would_route=yes` for its PRs.

**Do not delete the new path afterwards.** It is the session's cwd now.

## Messages lost during the outage

Pigeon gives up after 10 attempts, and nothing redelivers the message after that. List what was dropped and tell each sender (the `from` of the original message) to resend:

```bash
journalctl --namespace=pigeon --since -1d --no-pager | grep "failed (max attempts)" | grep "$S"
```

Shepherd alerts that went to the human (`human: worktree-gone`) are not re-sent to the session either; brief the revived session on any PR signal it missed.

## Restarting the serve is the wrong first move

It clears the memoized failure, but a pool serve carries many unrelated sessions and the restart kills their in-flight turns. The path swap costs no other session anything. Count the co-tenants first if you are still tempted:

```bash
nix run nixpkgs#sqlite -- "$DB" \
  "select s.id, s.title from session s join message m
     on m.id=(select id from message where session_id=s.id order by time_created desc limit 1)
   where m.data like '%\"port\":\"4098\"%'
     and m.time_created > (strftime('%s','now')-3600)*1000;"
```

## What survives

Committed work is safe: the branch ref outlives the worktree. **Uncommitted and untracked files are gone**, including scratch DBs. Tell the revived session to check HEAD and report what is missing instead of reconstructing from memory. It cannot distinguish "I did that" from "that got committed".

## Who deletes these

Identify the deleter rather than assuming; the same session has died twice from two different causes.

| Deleter | How to check | Note |
|---|---|---|
| **The session itself** | `grep -ahs "worktree remove" ~/.local/share/opencode/log/opencode.log{.1,}` | The most common cause: it finished a PR and removed the tree it was sitting in (see the `finishing-a-development-branch` override in AGENTS.md). |
| **`disk-cleanup.service`** | `journalctl --user -u disk-cleanup \| grep -i worktree` | Nightly. Walks `<repo>/.worktrees/*/` in every repo under `~/projects` and removes merged worktrees, skipping any that a live session is sitting in. Never touches a primary checkout. |
| **`reset-workspace`** (nightly) | its log lines name the repo | `work --prune-merged` on **one hardcoded work-repo root only** (`grep -n 'projects/' "$(readlink -f "$(command -v reset-workspace)")"`). If the dead worktree is in a different repo, it wasn't this. |

## Prevention

Before `git worktree remove`/`prune` or any cleanup of `.worktrees/`, check for a live session:

```bash
nix run nixpkgs#sqlite -- "$DB" "select id, title from session where directory like '%<slug>%';"
```

A session that has finished one PR and is moving to another branch should move its own directory (the update above) rather than delete the tree it is sitting in.

## Related

- `monitoring-serve-pool` (workstation repo-local): wedged vs. frozen serves. An orphaned session is neither; the serve is healthy and only this session is affected.
- `swarm-messaging`: a peer that has gone silent may be orphaned rather than busy.
- `shepherding-pull-requests`: what the shepherd wakes it would have received.
