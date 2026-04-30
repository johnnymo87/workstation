# Nightly Bazel Cache Purge — Design

**Date:** 2026-04-29
**Status:** Proposed
**Scope:** `users/dev/disk-cleanup.nix` on cloudbox (the GCP ARM box).

## Problem

The cloudbox runs a nightly `disk-cleanup.timer` at 3 AM that prunes stale
worktrees, runs Nix GC, and removes a few app caches. It also has a Bazel
step (`cleanup_bazel()`) that deletes **orphan** output bases — output
bases under `~/.cache/bazel/_bazel_dev/<hash>/` whose corresponding
workspace directory no longer exists. The orphan check works correctly:
last night's run deleted 5 orphans.

But the orphan check by design **never touches output bases for live
worktrees**, and that's exactly where the bloat lives. Two examples
observed today:

- `~/.cache/bazel/_bazel_dev/b6a5be48...` — 22 GB — workspace:
  `mono/.worktrees/netty-bom-alignment` (still exists)
- `~/.cache/bazel/_bazel_dev/b973b3c0...` — 9.6 GB — workspace:
  `mono/.worktrees/p44-retag-bug` (still exists)

In total, ~57 GB of `~/.cache/bazel`, plus ~10 GB of the shared
`~/bazel-diskcache`, plus ~2.7 GB of `~/bazel-cache/repository` are
unbounded. This filled the disk to 99% today (3.4 GB free out of 197 GB).
The nightly cleanup ran but couldn't recover anything from these because
none of them were orphans.

## Goal

Reclaim all Bazel cache space nightly, unconditionally, even for live
worktrees. Pay the cost as a slower next-day `bazel build` in exchange
for never running out of disk again.

## Non-goals

- Pruning worktrees themselves. Existing `cleanup_worktrees()` already
  handles that with staleness logic (28d / merged / lgtm-pr-merged) and
  is unchanged.
- Touching `~/.gradle`, `~/.npm`, `~/.bun`, or other non-Bazel build
  caches. Out of scope for this change.
- Changing the timer schedule. Still runs at 3 AM with `Persistent=true`
  + 30min jitter.

## Design

Replace the current `cleanup_bazel()` (orphan-only) with a single
`cleanup_bazel()` that purges all Bazel-related caches unconditionally.
The orphan logic is fully subsumed: if "delete everything" runs cleanly,
"delete only orphans" is redundant.

### Algorithm

```
cleanup_bazel():
  # 1. Per-workspace output bases (and any other state under _bazel_dev)
  if ~/.cache/bazel/_bazel_dev/ exists:
    for each entry in ~/.cache/bazel/_bazel_dev/:
      skip if entry == "install"   # Bazel installer cache, ~189 MB, not workspace-specific
      if a live server PID is found for this base:   # see "server safety" below
        log WARN: skipping <hash>, server PID <pid> alive (workspace=<cwd>)
        continue
      sudo rm -rf <full_path>

  # 2. Shared --disk_cache (configured in mono/.bazelrc:109)
  if ~/bazel-diskcache exists:
    rm -rf ~/bazel-diskcache/ac
    rm -rf ~/bazel-diskcache/cas
    rm -rf ~/bazel-diskcache/gc
    # Leave tmp/ alone — Bazel may have in-flight writes there. The dir
    # itself is preserved so Bazel doesn't error on next build.

  # 3. External repository cache
  if ~/bazel-cache/repository exists:
    rm -rf ~/bazel-cache/repository

  log total space freed
```

### Bazel server safety

A long-running `bazel` JVM daemon holds an exclusive lock on its output
base. Naively `rm -rf`'ing the directory while the server runs corrupts
state and confuses the next build.

**Why we don't `bazel shutdown` per base:** the shutdown command must be
invoked from within the workspace (i.e. `cd $workspace && bazel
--output_base=$path shutdown`), because `bazel` outside a workspace runs
in batch mode and prints a warning instead of contacting the server.
Doing this correctly per base would require parsing the `lock` file's
`cwd=` field, `cd`'ing there, and only invoking `bazel` if the workspace
still exists. Significant complexity for negligible value (see below).

**What we do instead — a check-and-skip:** for each output base, look at
`<base>/server/server.pid.txt`. If the file exists and points to a live
PID (`kill -0 $pid` succeeds), log a WARN and skip that base; the orphan
or next nightly run will catch it. If the file doesn't exist or the PID
is dead, the server isn't running and `rm -rf` is safe.

**Empirical justification for "check and skip":**
- 3 AM (with 30min jitter) is well past any reasonable interactive build
  session.
- Bazel servers idle-timeout after 3 hours by default. Even the most
  aggressive overnight build process would be gone by 3 AM.
- Spot check on cloudbox 2026-04-29 22:40: 12 output bases on disk, zero
  running server JVMs (`pgrep java | grep bazel` empty). All `lock`
  files were stale client locks from prior bazelisk invocations.

So in practice the skip path almost never fires. The check is cheap
insurance, not the common case.

### Why nuke `~/bazel-diskcache` too?

The disk cache is a shared content-addressed store of action results
across all workspaces. Bazel's own GC (configured as
`--experimental_disk_cache_gc_max_size=10G`) keeps it pinned at exactly
10 GB. It's serving its purpose, but the user explicitly chose the
nuclear option in brainstorming: maximize space recovered, accept that
the next build is fully cold.

If first-build performance becomes painful, the trivial follow-up is to
remove the `~/bazel-diskcache/{ac,cas,gc}` lines from the cleanup
function. Bazel's own 10 GB GC will keep it bounded.

### Why nuke `~/bazel-cache/repository` too?

This is the external repository cache (Maven jars, downloaded source
tarballs, etc.). 2.7 GB of network-fetched dependencies. Refetching
costs network time, not just CPU, so this hurts more than the action
cache loss. Same rationale as above: user chose the nuclear option;
trivially reversible by removing the line.

### Logging

Each step logs before/after sizes:

```
[disk-cleanup] Bazel: purging per-workspace output bases...
[disk-cleanup] Shutting down Bazel server: b6a5be48... (22G)
[disk-cleanup] Removed b6a5be48... (22G freed)
... (repeat per workspace) ...
[disk-cleanup] Bazel: purging ~/bazel-diskcache (10G)...
[disk-cleanup] Bazel: purging ~/bazel-cache/repository (2.7G)...
[disk-cleanup] Bazel cleanup complete: ~70G freed
```

This makes recovery measurable in `journalctl --user -u disk-cleanup.service`.

### Error handling

Each `bazel shutdown` and `rm -rf` call is wrapped with `|| true` so a
single failure doesn't abort the rest of the script (the script runs
`set -euo pipefail` at the top). Failures are logged with `WARN:`
prefix so they show up grep-able in the journal.

### What about the install/ subdir?

`~/.cache/bazel/_bazel_dev/install/` (~189 MB) holds the unpacked Bazel
binary itself, not workspace state. It is not workspace-specific and
deleting it forces a re-extract on next invocation. We skip it — the
189 MB is not worth the overhead.

## Testing

Manual:

1. Apply the change: `nix run home-manager -- switch --flake .#dev`
2. Verify the script content includes the new bazel logic:
   `grep -n 'bazel-diskcache\|bazel-cache/repository' ~/.local/bin/disk-cleanup`
3. Trigger manually: `systemctl --user start disk-cleanup.service`
4. Tail the journal: `journalctl --user -u disk-cleanup.service --since "1 minute ago" -f`
5. Verify reclaim: `df -h /` before and after; expect ~70 GB delta on a
   day with full caches.
6. Verify Bazel still builds: `cd ~/projects/mono && bazel build //...`
   (will be slow — that's the point — but should succeed).

## Open questions

None at this point — user approved nuclear scope and graceful shutdown
in brainstorming.

## Files

- `users/dev/disk-cleanup.nix` — replace `cleanup_bazel()` body. The
  current implementation does Python-driven orphan detection; the new
  one is a straight bash purge with a server-PID check. No new
  packages need to be added to `lib.makeBinPath` — `coreutils`,
  `findutils`, and the existing `sudo` cover everything.
</content>
</invoke>