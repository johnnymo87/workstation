# Nightly Bazel Cache Purge — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the orphan-only `cleanup_bazel()` in `users/dev/disk-cleanup.nix` with an unconditional nightly purge that reclaims ~70 GB of Bazel cache space (per-workspace output bases + shared disk_cache + external repository cache), so the cloudbox stops filling its disk between nightly runs.

**Architecture:** Single bash function rewrite inside an existing Nix-managed shell script. No new packages, no new systemd units, no new files outside docs. Verification is a one-shot manual `systemctl --user start disk-cleanup.service` followed by reading the journal and `df -h /`.

**Tech Stack:** bash (deployed via `home.file` in `users/dev/disk-cleanup.nix`), systemd user units, `home-manager switch` to apply.

**Reference design:** `docs/plans/2026-04-29-bazel-cache-nightly-purge-design.md`

---

## Pre-flight

These steps establish a clean working state and capture baseline metrics so the verification step has something to compare against.

### Task 0: Confirm baseline state on cloudbox

**Files:** none (read-only checks).

**Step 1: Confirm host is cloudbox.**

Run: `hostname`
Expected: `cloudbox`

If anything else, stop — this plan only applies to cloudbox.

**Step 2: Confirm the workstation repo is clean and on main.**

Run: `git -C ~/projects/workstation status --short && git -C ~/projects/workstation rev-parse --abbrev-ref HEAD`

Expected: branch is `main`, no modifications to tracked files. The untracked files (`bin/`, `patch.pl`, `test-argv*`, `test.nix`) from prior unrelated work may still be present — leave them alone.

**Step 3: Pull latest from origin.**

Run: `git -C ~/projects/workstation pull --rebase`

Expected: includes commit `9916e5b docs(plans): design for nightly Bazel cache purge in disk-cleanup`. If not present locally, this pull retrieves it.

**Step 4: Capture baseline disk + Bazel cache sizes.**

Run:

```bash
df -h /
du -sh ~/.cache/bazel ~/bazel-diskcache ~/bazel-cache 2>/dev/null
ls -la ~/.cache/bazel/_bazel_dev/ | head -20
```

Save the output somewhere visible (paste into the session, or `tee` to a scratch file). You'll diff against this after running the new cleanup.

**Step 5: Confirm no live Bazel servers right now.**

Run: `pgrep -af "java.*bazel" || echo "no live bazel servers"`

Expected: `no live bazel servers`. If any are listed, note their PIDs — the new code's PID-skip path will fire on those and you'll see WARN lines in the journal during verification.

---

## Implementation

### Task 1: Rewrite `cleanup_bazel()` in `users/dev/disk-cleanup.nix`

**Files:**
- Modify: `users/dev/disk-cleanup.nix:153-191` (the entire `# --- 3. Bazel orphan output bases ---` block, including the embedded Python heredoc)

**Step 1: Read the current implementation to confirm line range.**

Run: `sed -n '152,192p' ~/projects/workstation/users/dev/disk-cleanup.nix`

Expected: the block starting `# --- 3. Bazel orphan output bases ---` and ending with the closing `}` of `cleanup_bazel()`. The embedded Python script computes md5 hashes of workspace paths and prints orphan hashes on stdout.

**Step 2: Replace lines 153-191 with the new implementation.**

Use the Edit tool with the following exact replacement. The `oldString` is the existing block (lines 153-191 of `users/dev/disk-cleanup.nix`); the `newString` is the rewrite below. Preserve the surrounding 6-space indentation that matches the rest of the embedded script (the file is a Nix multi-line string with 6 spaces of base indent).

```bash
      # --- 3. Bazel cache purge ---
      # Unconditionally nuke per-workspace output bases, the shared
      # --disk_cache, and the external repository cache. This trades
      # next-day "cold build" cost for never running out of disk.
      # Replaces the prior orphan-only logic, which couldn't recover
      # space from live worktrees (the actual source of bloat).
      # Design: docs/plans/2026-04-29-bazel-cache-nightly-purge-design.md
      cleanup_bazel() {
        log "Purging Bazel caches..."
        local bazel_freed_kb=0
        local before_kb after_kb

        # 3a. Per-workspace output bases (~/.cache/bazel/_bazel_dev/<hash>/).
        # Skip 'install/' (Bazel's installer cache, not workspace-specific,
        # ~189 MB; deleting it forces a re-extract for nothing).
        if [ -d "$BAZEL_BASE" ]; then
          for entry_path in "$BAZEL_BASE"/*; do
            [ -d "$entry_path" ] || continue
            entry=$(basename "$entry_path")
            [ "$entry" = "install" ] && continue

            # Server safety: if a live JVM holds this base, skip it.
            # Stale lock files are common; an actual server has
            # server/server.pid.txt with a live PID.
            local pid_file="$entry_path/server/server.pid.txt"
            if [ -f "$pid_file" ]; then
              local server_pid
              server_pid=$(cat "$pid_file" 2>/dev/null || echo "")
              if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
                local cwd_hint=""
                if [ -f "$entry_path/lock" ]; then
                  cwd_hint=$(grep -oP '(?<=^cwd=).*' "$entry_path/lock" 2>/dev/null || echo "?")
                fi
                log "WARN: skipping output base $entry, server PID $server_pid alive (cwd=$cwd_hint)"
                continue
              fi
            fi

            local size_kb
            size_kb=$(du -sk "$entry_path" 2>/dev/null | cut -f1 || echo 0)
            local size_h
            size_h=$(du -sh "$entry_path" 2>/dev/null | cut -f1 || echo "?")
            if sudo rm -rf "$entry_path" 2>&1; then
              log "Removed output base $entry ($size_h)"
              bazel_freed_kb=$((bazel_freed_kb + size_kb))
            else
              log "WARN: failed to remove output base $entry"
            fi
          done
        fi

        # 3b. Shared --disk_cache (~/bazel-diskcache, configured in
        # mono/.bazelrc:109 as --disk_cache=bazel-cache/diskcache/ ...).
        # Bazel's own GC keeps this at <=10 GB. Removing the contents
        # (not the dir) avoids "directory not found" errors on next build.
        # Leave tmp/ alone in case Bazel has in-flight writes there.
        local diskcache="$HOME/bazel-diskcache"
        if [ -d "$diskcache" ]; then
          before_kb=$(du -sk "$diskcache" 2>/dev/null | cut -f1 || echo 0)
          for sub in ac cas gc; do
            [ -d "$diskcache/$sub" ] && rm -rf "$diskcache/$sub" 2>/dev/null || true
          done
          after_kb=$(du -sk "$diskcache" 2>/dev/null | cut -f1 || echo 0)
          local diff_kb=$((before_kb - after_kb))
          if [ "$diff_kb" -gt 0 ]; then
            log "Purged ~/bazel-diskcache ($((diff_kb / 1024)) MB freed)"
            bazel_freed_kb=$((bazel_freed_kb + diff_kb))
          fi
        fi

        # 3c. External repository cache (~/bazel-cache/repository).
        # Downloaded Maven jars, source tarballs, etc. Refetching costs
        # network time on the next build.
        local repocache="$HOME/bazel-cache/repository"
        if [ -d "$repocache" ]; then
          before_kb=$(du -sk "$repocache" 2>/dev/null | cut -f1 || echo 0)
          if rm -rf "$repocache" 2>/dev/null; then
            log "Purged ~/bazel-cache/repository ($((before_kb / 1024)) MB freed)"
            bazel_freed_kb=$((bazel_freed_kb + before_kb))
          else
            log "WARN: failed to remove ~/bazel-cache/repository"
          fi
        fi

        log "Bazel cleanup complete: $((bazel_freed_kb / 1024)) MB freed total"
      }
```

**Notes for the editor:**

- The variable `$BAZEL_BASE` is already set at the top of the script (line 26) to `$HOME/.cache/bazel/_bazel_$(whoami)`. Reuse it; do not redeclare.
- Leave the `python3` package in `lib.makeBinPath` for now even though this function no longer uses it. Removing it is a separate cleanup; a future task can drop it once we're confident nothing else references it. (The current script doesn't use python3 anywhere else, so removing it is safe — but defer to keep this change minimal.)
- The `local` keyword is fine inside this function: the script already uses bash (`#!${pkgs.bash}/bin/bash` on line 10) and other functions (`cleanup_opencode_wal`, line 226) already use `local`.
- `sudo rm -rf` is consistent with the prior implementation (line 187) — Bazel sometimes creates files with restrictive perms inside the output base.

**Step 3: Verify the file still parses as Nix.**

Run: `cd ~/projects/workstation && nix-instantiate --parse users/dev/disk-cleanup.nix > /dev/null && echo "PARSE OK"`

Expected: `PARSE OK`. If it fails with a syntax error, you almost certainly broke string interpolation — Nix `''...''` strings need `''$` to escape literal `$` and `'''` to escape literal `''`. The new code has neither (all `$VAR` references are intentional bash variable expansions), so this should pass cleanly.

**Step 4: Verify the bash inside the Nix string is well-formed.**

Run:

```bash
nix-instantiate --eval --strict --json -E \
  '(import ~/projects/workstation/users/dev/disk-cleanup.nix
     { config = {}; pkgs = import <nixpkgs> {};
       lib = (import <nixpkgs> {}).lib; isCloudbox = true; }
   ).home.file.".local/bin/disk-cleanup".text' 2>/dev/null \
  | jq -r . | bash -n && echo "BASH SYNTAX OK"
```

Expected: `BASH SYNTAX OK`. If `bash -n` reports a syntax error, the line number it gives is the line within the *rendered* script, not the source `.nix` file — adjust by the offset of the heredoc start.

If the eval pipeline is too brittle (it's sensitive to how the module is structured), a faster fallback is to extract the new function body to a scratch file and `bash -n` that:

```bash
sed -n '/cleanup_bazel() {/,/^      }$/p' ~/projects/workstation/users/dev/disk-cleanup.nix > /tmp/cleanup_bazel.sh
bash -n /tmp/cleanup_bazel.sh && echo "BASH SYNTAX OK"
```

**Step 5: Commit just the disk-cleanup.nix change.**

```bash
cd ~/projects/workstation
git add users/dev/disk-cleanup.nix
git commit -m "feat(disk-cleanup): nightly Bazel cache purge replaces orphan-only logic

The prior cleanup_bazel() only removed orphan output bases (workspaces
deleted from disk). On 2026-04-29 the cloudbox filled to 99% because
~57 GB of per-worktree Bazel output bases for *live* worktrees
(netty-bom-alignment 22 GB, p44-retag-bug 9.6 GB, ...) accumulated
unbounded; orphan detection couldn't touch them.

New cleanup_bazel() unconditionally purges:
  * per-workspace output bases under ~/.cache/bazel/_bazel_dev/
    (skipping install/ and any base with a live server JVM)
  * shared --disk_cache contents in ~/bazel-diskcache/{ac,cas,gc}
  * external repository cache ~/bazel-cache/repository

Trade-off: next-day 'bazel build' is fully cold. Acceptable: cloudbox
runs at 3 AM with 30min jitter, well past any active build session,
and the user explicitly opted into the nuclear scope.

Design: docs/plans/2026-04-29-bazel-cache-nightly-purge-design.md"
```

---

## Verification

### Task 2: Apply on cloudbox and trigger a manual run

**Files:** none (deployment + observation).

**Step 1: Apply via home-manager.**

Run: `cd ~/projects/workstation && nix run home-manager -- switch --flake .#dev`

Expected: completes without errors. Look for activation lines mentioning `home.file '.local/bin/disk-cleanup'` being relinked. If you see `error: ...`, fix and re-apply before proceeding.

**Step 2: Verify the new script content is in place.**

Run:

```bash
grep -n "Bazel cache purge\|bazel-diskcache\|bazel-cache/repository" ~/.local/bin/disk-cleanup
```

Expected: at least 4 matches showing the new implementation:
- `# --- 3. Bazel cache purge ---`
- `# 3b. Shared --disk_cache (~/bazel-diskcache, ...`
- `local diskcache="$HOME/bazel-diskcache"`
- `local repocache="$HOME/bazel-cache/repository"`

If you see the old `import hashlib, os, sys` line instead, the home-manager apply didn't take — re-run Step 1.

**Step 3: Snapshot disk state immediately before triggering.**

Run:

```bash
df -h /
du -sh ~/.cache/bazel ~/bazel-diskcache ~/bazel-cache 2>/dev/null
```

Save this output. You'll diff against it after the run.

**Step 4: Trigger the disk-cleanup service manually.**

Run: `systemctl --user start disk-cleanup.service`

This blocks until the service finishes (oneshot type). Expect a few seconds to ~30 seconds depending on how much there is to delete (cleanup may need to remove tens of GB).

**Step 5: Read the journal to confirm the new code ran.**

Run: `journalctl --user -u disk-cleanup.service --since "2 minutes ago" --no-pager | tail -60`

Expected: lines including
```
[disk-cleanup] ... Purging Bazel caches...
[disk-cleanup] ... Removed output base <hash> (...G)
[disk-cleanup] ... Purged ~/bazel-diskcache (... MB freed)
[disk-cleanup] ... Purged ~/bazel-cache/repository (... MB freed)
[disk-cleanup] ... Bazel cleanup complete: ... MB freed total
```

If you see WARN lines about skipping a base because of a live server PID — that's expected if you happen to have an active Bazel server right now (you'd have noticed in Task 0 Step 5). The skip path was triggered as designed.

If you see a line like `WARN: failed to remove output base ...` with no further detail, that suggests sudo prompted for a password (the user systemd unit has no TTY for interactive sudo). On cloudbox, `security.sudo.wheelNeedsPassword=false` should mean no prompt — but if you see this, run `sudo -n true; echo $?` to confirm passwordless sudo is in effect.

**Step 6: Verify disk reclaim.**

Run:

```bash
df -h /
du -sh ~/.cache/bazel ~/bazel-diskcache ~/bazel-cache 2>/dev/null
ls -la ~/.cache/bazel/_bazel_dev/ 2>/dev/null
```

Expected:
- `df -h /` Avail column larger than the Step 3 snapshot, by roughly the "Bazel cleanup complete: X MB freed total" number.
- `~/.cache/bazel/_bazel_dev/` should now contain only `install/` (and possibly any base that was skipped due to a live PID).
- `~/bazel-diskcache/` exists but contains only `tmp/` (or nothing, if `tmp/` wasn't there before).
- `~/bazel-cache/repository` is gone (the parent dir `~/bazel-cache/` may or may not still exist).

**Step 7: Sanity check — the script can still run with empty caches.**

Run: `systemctl --user start disk-cleanup.service && journalctl --user -u disk-cleanup.service --since "1 minute ago" --no-pager | tail -20`

Expected: completes cleanly with `Bazel cleanup complete: 0 MB freed total` (or close to 0). No errors. This confirms the function handles the "nothing to do" case gracefully — important because most nightly runs will be after a low-build day.

**Step 8: Functional test — Bazel still works.**

This step exercises a real `bazel` invocation to confirm the cache purge didn't leave the workspace in a broken state. It will be slow (cold build), so pick a small target.

Run:

```bash
cd ~/projects/workstation     # any small workspace; this is fine because
                              # workstation has no real Bazel build, so
                              # `bazel info` is enough to confirm Bazel
                              # can re-initialize its output base.
bazelisk info output_base
```

Expected: bazelisk creates a fresh output base under `~/.cache/bazel/_bazel_dev/<hash>/` and prints its path. No errors about lock files or corrupted state.

If you want a more thorough test (heavier but more realistic), `cd ~/projects/mono && bazel info output_base` does the same thing in mono's workspace. Either works.

---

## Cleanup

### Task 3: Push and close the loop

**Files:** none (just git).

**Step 1: Push the implementation commit.**

Run:

```bash
cd ~/projects/workstation
git pull --rebase
git push
git status
```

Expected: `git status` shows `Your branch is up to date with 'origin/main'`. The `pull --rebase` is defensive in case anything else landed while you were working; the change is minimal so conflicts are extremely unlikely.

**Step 2: Verify CI / no follow-up needed.**

This repo doesn't have CI that runs on pushes to main (workstation is a personal config repo). Nothing to wait for.

**Step 3: Note for future observability.**

Tomorrow morning (i.e. ~3 AM with jitter), the timer fires automatically. The first natural run can be inspected with:

```bash
journalctl --user -u disk-cleanup.service --since "today 02:30" --no-pager | grep -E "Bazel|Disk after"
```

If the "Disk after" line shows a delta close to "Bazel cleanup complete" + the existing `cleanup_caches()` reclaim (~922 MB historically for coursier), the change is operating as designed.

---

## Rollback

If something goes wrong (Bazel won't rebuild, sudo issues, anything else), revert the implementation commit:

```bash
cd ~/projects/workstation
git revert HEAD~1   # the disk-cleanup commit (HEAD is the design doc)
                    # Adjust ~1 if commit topology differs
nix run home-manager -- switch --flake .#dev
```

This restores the orphan-only `cleanup_bazel()` exactly as it was before this plan ran. Disk will fill again, but no other functionality is affected.
</content>
</invoke>