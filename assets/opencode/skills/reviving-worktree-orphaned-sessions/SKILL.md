---
name: reviving-worktree-orphaned-sessions
description: Diagnoses and revives an opencode session whose working directory was deleted. Use when a session stops answering swarm messages or shepherd wakes, when lgtm-shepherd logs "(human: worktree-gone)" or "dir_exists=no" for a PR, when pigeon logs "TargetUnavailableError ... working directory missing", when assistant turns finish instantly with zero output, or when the serve log shows "prompt_async failed ... FileSystem.realPath ... ENOENT". Also use before deleting or pruning any worktree that a live session may be sitting in.
---

# Reviving Worktree-Orphaned Sessions

A session whose `directory` no longer exists goes through two stages. The fix is the same for both: point `session.directory` at a path that exists.

| Stage | What you see | Seen |
|---|---|---|
| **Half-alive** (the serve still has an instance loaded for the deleted path) | Human prompts via Telegram still get normal answers. Every *automated* route refuses the session: pigeon's swarm arbiter will not send (`working directory missing`), and lgtm-shepherd sends the session's PR alerts (`ci_red`, `conflicted`, `needs_reply`) to the human instead (`human: worktree-gone`). | devbox 2026-11-02 |
| **Zombie** (the instance has to boot from the missing path, most likely after a serve restart) | Every turn finishes in under a second with zero parts. Human and swarm prompts alike get silence. Serve log: `prompt_async failed ... realPath ... ENOENT`. | cloudbox 2026-08-31 |

That half-alive turns into a zombie at the next serve restart (nightly, ~03:00) is inferred from how the serve caches instances per directory; nobody has watched it happen. Fix a half-alive session now, not later. It looks healthy because it answers when you ask it something, but it has already stopped receiving swarm messages and shepherd wakes.

## Workflow

```
- [ ] 1. Confirm the directory is gone (Diagnosis)
- [ ] 2. Pick the new path (Choosing the path)
- [ ] 3. Update session.directory
- [ ] 4. Wait out pigeon's cache, then probe
- [ ] 5. Brief the session on messages and PR signals it missed during the outage
```

## Diagnosis

`sqlite3` is not on PATH; use `nix run nixpkgs#sqlite --`.

```bash
S=ses_xxxxxxxx
DB=~/.local/share/opencode/opencode.db

# The directory the session has, and whether it exists. Read the DB, not the
# serve API: an unauthenticated curl to a serve with auth on returns nothing,
# and `ls ""` then looks exactly like a missing directory.
D=$(nix run nixpkgs#sqlite -- "$DB" "select directory from session where id='$S';"); echo "$D"; [ -n "$D" ] && ls -ld "$D"

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

**Do not recreate the deleted path.** On cloudbox 2026-08-31 the dir was restored at 22:46:52, and the session still got ENOENT for that exact path at 22:47:19 and 22:48:42. Newer opencode may have fixed this, but a different path works either way.

**Which branch:** the branch of the PR the session still owes, not the one it was on when the tree vanished. A session often removes its tree right after that PR merges. Shepherd names the PRs it attributes to the session:

```bash
journalctl -u lgtm-shepherd.service --since -1d --no-pager | grep "candidate $S"
```

**Which path**, first that applies:

1. **The branch is already checked out in another worktree** (`git worktree list | grep <branch>`). Use that path if no other recent session works there. Sessions often `cd` into a worktree without their `directory` naming it, so check both the session table and recent tool calls:
   ```bash
   nix run nixpkgs#sqlite -- "$DB" "select id, title from session
     where directory = '<path>' and parent_id is null and id != '$S'
       and time_updated > (strftime('%s','now')-86400)*1000;"
   grep -ahs '<path>' ~/.local/share/opencode/log/opencode.log | grep -v "$S" | tail -3
   ```
   If another session is working there, use rule 3.
2. **The branch is not checked out anywhere:** `git worktree add .worktrees/<slug>-r2 <branch>`.
3. **The branch is checked out by someone else:** `git worktree add --detach .worktrees/<slug>-r2 <branch>`, and tell the revived session it is on a detached HEAD (it pushes with `git push origin HEAD:<branch>`).
4. **You already restored the old path:** `git worktree move .worktrees/<slug> .worktrees/<slug>-r2`.

## Updating the directory

Do this from another session, never from the orphaned one. The DB is in WAL mode with many concurrent writers; `.timeout` makes a busy DB wait instead of failing with "database is locked":

```bash
nix run nixpkgs#sqlite -- -cmd '.timeout 5000' "$DB" "update session set directory='<new-path>' where id='$S';"
nix run nixpkgs#sqlite -- "$DB" "select directory from session where id='$S';"
```

The serves and lgtm-shepherd read the new value straight away. The session's subagent children keep the old directory; leave them alone unless something is going to resume one.

**Pigeon caches each session's directory for up to 5 minutes** (`ttlMs` in pigeon's `packages/daemon/src/routing/directory-resolver.ts`). Until the cached entry expires, swarm sends keep failing with the *old* path in the error. A send is retried after 1 s, 2 s, 5 s, 15 s, then every 60 s, 10 attempts in all (about 6.5 minutes). That only just outlasts the cache, so wait 5 minutes before probing, or resend if the probe shows up as `failed (max attempts)`.

Probe with one swarm message asking for `pwd` and `git log --oneline -1` *without* a workdir override. The reply, arriving via the swarm, proves both that the path resolves and that automated delivery works again. The next shepherd sweep (every 10 min) should then log `dir_exists=yes would_route=yes` for its PRs.

**Do not delete the new path afterwards.** It is the session's cwd now.

## Messages lost during the outage

- **Ordinary swarm sends** fail permanently after 10 attempts. Pigeon tells the sender itself (a `delivery.failed` notice), so don't relay that. What the revived session lacks is the content; it was never delivered, and nothing will redeliver it.
- **Scheduled wakes** (`swarm_schedule`) are retried every 30 s without counting attempts, until they expire. After the fix they may all arrive in a burst; any that expired first are lost without a `failed` line.
- **Shepherd alerts** that went to the human (`human: worktree-gone`) are not re-sent to the session either.

```bash
journalctl --namespace=pigeon --since -1d --no-pager | grep "$S" | grep -E "failed \(max attempts\)|expired"
```

Brief the revived session on anything there and on any PR signal it missed.

## Restarting the serve is the wrong first move

It reloads the session's instance, but a pool serve carries many unrelated sessions and the restart kills their in-flight turns. The path swap costs no other session anything. Count the co-tenants first if you are still tempted:

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
| **The session itself** | `grep -ahs "worktree remove" ~/.local/share/opencode/log/opencode.log{.1,}` | It finished a PR and removed the tree it was sitting in (see the `finishing-a-development-branch` override in AGENTS.md). |
| **`disk-cleanup.service`** (cloudbox only) | `journalctl --user -u disk-cleanup \| grep -i worktree` | Nightly. Walks `<repo>/.worktrees/*/` in every repo under `~/projects` and removes merged worktrees. It spares a worktree whose session was active in the last 7 days or still owns an open PR, so an older or quieter session is fair game. Never touches a primary checkout. |
| **`reset-workspace`** (nightly) | its log lines name the repo | `work --prune-merged` on **one hardcoded work-repo root only** (`grep -n 'projects/' "$(readlink -f "$(command -v reset-workspace)")"`). If the dead worktree is in a different repo, it wasn't this. |

## Prevention

Before `git worktree remove`/`prune` or any cleanup of `.worktrees/`, check for a live session:

```bash
nix run nixpkgs#sqlite -- "$DB" "select id, title from session where directory like '%<slug>%';"
```

Never `git worktree remove` the tree you are sitting in, even after its PR merges; that is the AGENTS.md override for `finishing-a-development-branch`. A stale worktree costs some disk; a removed one costs a session.

## Goose sessions

A goose session (`goose:<id>` in the picker, `gse_…` in pigeon) whose worktree was deleted is revived differently, and the rest of this skill does not apply to it.

- **What you see:** shell calls fail with ENOENT while the directory is absent. Its swarm tools still work. The session may also be dropped by honkd after a goose-serve restart (it cannot load a missing cwd), so opening it fails.
- **Fix:** press Enter on its row in the session picker, or run `oc-revive goose:<id>`. This recreates the worktree **at the same path**, on the branch it had. No directory update and no new path are needed: goose-serve and honkd cache nothing per path, so the next turn just works (measured 2026-11-04).
- **It refuses** (`opencode_sibling:`) when an opencode session also has that directory: recreating it would turn that opencode session into a zombie. If that session is finished, archive it and re-run. If you still need it, revive it instead (`oc-revive <sid>`); that moves its branch to a new worktree, and this goose session can then no longer be revived.
- **Plain directory recreated by agent:** a dead goose session can recreate `.worktrees/<slug>` itself as a plain directory, because its write tool creates parent dirs. `oc-revive` then reports `directory_exists`. Check: no `.git` file in it (`ls -a`). Move the plain dir aside (to `/tmp`, not delete) and re-run.
- **No notice is sent** to the agent. Tell it that the worktree was recreated and that uncommitted work is gone.

## Related

- `monitoring-serve-pool` (workstation repo-local): wedged vs. frozen serves. An orphaned session is neither; the serve is healthy and only this session is affected.
- `swarm-messaging`: a peer that has gone silent may be orphaned rather than busy.
- `shepherding-pull-requests`: what the shepherd wakes it would have received.
