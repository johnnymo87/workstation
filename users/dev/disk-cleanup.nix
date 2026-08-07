# Nightly disk cleanup for cloudbox
# Auto-discovers repos with worktrees, cleans orphan Bazel output bases,
# prunes stale caches, and runs nix garbage collection.
{ config, pkgs, lib, isCloudbox, ... }:

lib.mkIf isCloudbox {
  home.file.".local/bin/disk-cleanup" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      PATH="${lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gh
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.python3
      ]}:$PATH"

      PROJECTS="$HOME/projects"
      BAZEL_BASE="$HOME/.cache/bazel/_bazel_$(whoami)"
      WORKTREE_MAX_AGE_DAYS=14
      NIX_KEEP_GENERATIONS=3

      log() { echo "[disk-cleanup] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

      remove_worktree_if_clean() {
        local repo_dir="$1" wt_dir="$2" repo_name="$3" wt_name="$4" label="$5"
        local status_out

        if ! status_out=$(git -C "$wt_dir" status --porcelain --untracked-files=all 2>/dev/null); then
          log "WARN: keeping $label because status failed: $repo_name/$wt_name"
          return 0
        fi

        if [ -n "$status_out" ]; then
          log "WARN: keeping $label with uncommitted changes: $repo_name/$wt_name"
          return 0
        fi

        log "Removing $label: $repo_name/$wt_name"
        git -C "$repo_dir" worktree remove "$wt_dir" --force 2>&1 || true
      }

      # Make the GitHub token available so `gh auth git-credential` (configured
      # as the credential helper for https://github.com in home.base.nix) can
      # authenticate `git fetch` against private repos. Without this, fetches
      # of private HTTPS remotes (mono, internal-frontends, etc.) fail and
      # the worktree-pruning step skips those repos. Login shells export this
      # via home.cloudbox.nix, but systemd user units inherit a minimal env.
      GH_TOKEN_FILE="/run/secrets/github_api_token"
      if [ -r "$GH_TOKEN_FILE" ]; then
        export GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
      else
        log "WARN: $GH_TOKEN_FILE not readable; private fetches will fail"
      fi

      # --- 1. Nix garbage collection ---
      cleanup_nix() {
        log "Pruning nix generations..."

        # HM generations (user)
        nix-env --delete-generations "+$NIX_KEEP_GENERATIONS" \
          --profile "$HOME/.local/state/nix/profiles/home-manager" 2>&1 || true

        # System generations (requires sudo)
        sudo nix-env --delete-generations "+$NIX_KEEP_GENERATIONS" \
          --profile /nix/var/nix/profiles/system 2>&1 || true

        sudo nix-collect-garbage 2>&1 || true
        log "Nix GC complete"
      }

      # --- 2. Worktree cleanup (all repos) ---
      cleanup_worktrees() {
        log "Scanning for stale worktrees..."

        for repo_dir in "$PROJECTS"/*/; do
          [ -d "$repo_dir/.worktrees" ] || continue
          repo_name=$(basename "$repo_dir")

          # Resolve org/repo slug from origin URL once per repo, for `gh` calls
          # used by the lgtm pr-N pruning step below. Falls back to "" so the
          # `gh` step is skipped when the URL doesn't match a known shape.
          repo_slug=""
          origin_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "")
          case "$origin_url" in
            https://github.com/*)
              repo_slug="''${origin_url#https://github.com/}"
              ;;
            git@github.com:*)
              repo_slug="''${origin_url#git@github.com:}"
              ;;
          esac
          repo_slug="''${repo_slug%.git}"

          # Fetch and prune remote refs. Capture stderr so we can include the
          # first error line in the WARN; otherwise auth/network failures are
          # invisible in the journal.
          fetch_err=$(git -C "$repo_dir" fetch --prune origin 2>&1 >/dev/null) || {
            first_err=$(printf '%s\n' "$fetch_err" | head -1)
            log "WARN: fetch failed for $repo_name, skipping: $first_err"
            continue
          }

          for wt_dir in "$repo_dir"/.worktrees/*/; do
            [ -d "$wt_dir" ] || continue
            wt_name=$(basename "$wt_dir")

            # lgtm pr-N worktrees are detached-HEAD checkouts of refs/pull/N/head.
            # The generic merged/aged checks below can't catch them: there's no
            # local branch (so `branch=HEAD`), the PR head SHA is rarely on
            # origin/main directly (squash merges), and `last_commit_epoch` is
            # the PR commit time which keeps moving. So they accumulated
            # forever -- one ~14 GB pile across mono/internal-frontends/culops.
            # Source: lgtm/src/worktree.ts createWorktree (named pr-<N>).
            # Fix: ask GitHub for state and prune if MERGED or CLOSED.
            if [[ "$wt_name" =~ ^pr-([0-9]+)$ ]] && [ -n "$repo_slug" ]; then
              pr_num="''${BASH_REMATCH[1]}"
              pr_state=$(gh pr view "$pr_num" --json state --repo "$repo_slug" 2>/dev/null \
                | jq -r '.state // empty' 2>/dev/null || echo "")
              if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
                remove_worktree_if_clean "$repo_dir" "$wt_dir" "$repo_name" "$wt_name" "lgtm pr-$pr_num worktree ($pr_state)"
                continue
              fi
              # OPEN / unknown -> leave alone, fall through to generic checks
            fi

            # Check if merged into origin/main
            head_sha=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null) || continue
            if git -C "$repo_dir" merge-base --is-ancestor "$head_sha" origin/main 2>/dev/null; then
              remove_worktree_if_clean "$repo_dir" "$wt_dir" "$repo_name" "$wt_name" "merged worktree"
              continue
            fi

            # Check age + remote status for abandoned worktrees
            branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
            last_commit_epoch=$(git -C "$wt_dir" log -1 --format="%ct" 2>/dev/null) || continue
            now_epoch=$(date +%s)
            age_days=$(( (now_epoch - last_commit_epoch) / 86400 ))

            if [ "$age_days" -ge "$WORKTREE_MAX_AGE_DAYS" ]; then
              # Check if remote branch still exists
              has_remote=false
              if [ "$branch" != "HEAD" ] && \
                 git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
                has_remote=true
              fi

              if [ "$has_remote" = "false" ]; then
                log "Removing abandoned worktree ($age_days days old): $repo_name/$wt_name"
                git -C "$repo_dir" worktree remove "$wt_dir" --force 2>&1 || true
              fi
            fi
          done

          # Clean up stale worktree metadata
          git -C "$repo_dir" worktree prune 2>/dev/null || true
        done

        log "Worktree cleanup complete"
      }

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

            local size_kb size_h err_out
            size_kb=$(du -sk "$entry_path" 2>/dev/null | cut -f1 || true)
            size_h=$(du -sh "$entry_path" 2>/dev/null | cut -f1 || true)
            if err_out=$(sudo rm -rf "$entry_path" 2>&1); then
              log "Removed output base $entry (''${size_h:-?})"
              bazel_freed_kb=$((bazel_freed_kb + ''${size_kb:-0}))
            else
              log "WARN: failed to remove output base $entry: $err_out"
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
          before_kb=$(du -sk "$diskcache" 2>/dev/null | cut -f1 || true)
          for sub in ac cas gc; do
            [ -d "$diskcache/$sub" ] && rm -rf "$diskcache/$sub" 2>/dev/null || true
          done
          after_kb=$(du -sk "$diskcache" 2>/dev/null | cut -f1 || true)
          local diff_kb=$((''${before_kb:-0} - ''${after_kb:-0}))
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
          before_kb=$(du -sk "$repocache" 2>/dev/null | cut -f1 || true)
          if rm -rf "$repocache" 2>/dev/null; then
            log "Purged ~/bazel-cache/repository ($((''${before_kb:-0} / 1024)) MB freed)"
            bazel_freed_kb=$((bazel_freed_kb + ''${before_kb:-0}))
          else
            log "WARN: failed to remove ~/bazel-cache/repository"
          fi
        fi

        log "Bazel cleanup complete: $((bazel_freed_kb / 1024)) MB freed total"
      }

      # --- 4. Safe cache cleanup ---
      cleanup_caches() {
        log "Cleaning safe caches..."

        # Application caches that re-download on demand
        for cache_dir in \
          "$HOME/.cache/Cypress" \
          "$HOME/.cache/coursier" \
          "$HOME/.cache/pnpm" \
          "$HOME/.cache/pip" \
          "$HOME/.cache/ms-playwright" \
          "$HOME/.cache/node-gyp" \
          "$HOME/.cache/electron" \
          "$HOME/.npm/_cacache" \
        ; do
          if [ -d "$cache_dir" ]; then
            size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1)
            rm -rf "$cache_dir"
            log "Removed $cache_dir ($size)"
          fi
        done

        # NB: _cacache above, NOT $HOME/.npm wholesale. $HOME/.npm/_npx holds
        # UNPACKED packages that long-running `npm exec` processes execute out
        # of -- the Slack and nx MCP servers were observed running directly
        # from _npx binaries. Deleting it kills them mid-session. _cacache is
        # only the download cache and was measured at 35 GB.

        # Stale /tmp files
        sudo find /tmp -maxdepth 1 -name "nix-shell.*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "nix-*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "pip-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "pyright-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "fp-digest-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

        cleanup_tmp_scratch

        log "Cache cleanup complete"
      }

      # --- 4b. Stale /tmp scratch directories ---
      #
      # The name-pattern sweep above only catches tool-generated names
      # (nix-shell.*, pip-*, ...). It caught none of the 26 GB of abandoned
      # agent-session scratch found on cloudbox in 2026-08: build checkouts,
      # throwaway clones and $(mktemp -d) trees with arbitrary names, the
      # oldest from June. Those accumulate forever, so sweep by AGE and SIZE
      # instead of by name.
      #
      # Three guards, because /tmp on this host is shared by a dozen concurrent
      # agent sessions and one of them deleting another's working tree is a
      # real data-loss event:
      #
      #   1. older than TMP_SCRATCH_AGE_DAYS and at least TMP_SCRATCH_MIN_MB
      #   2. no live process has it as cwd/exe or holds an fd inside it
      #   3. if it is a git repo: skip when dirty OR carrying unpushed commits
      #
      # Guard 3 distinguishes a REAL repo from a gutted `.git` left behind by a
      # half-removed worktree. An earlier version of this conflated "git cannot
      # read this" with "this has uncommitted work" and would have protected
      # 12 GB of unrecoverable junk forever while sounding careful.
      TMP_SCRATCH_AGE_DAYS=7
      TMP_SCRATCH_MIN_MB=100

      cleanup_tmp_scratch() {
        log "Sweeping stale /tmp scratch (>''${TMP_SCRATCH_AGE_DAYS}d, >=''${TMP_SCRATCH_MIN_MB}MB)..."
        python3 - "$TMP_SCRATCH_AGE_DAYS" "$TMP_SCRATCH_MIN_MB" <<'PYEOF' || log "WARN: /tmp scratch sweep failed"
      import os, shutil, subprocess, sys, time

      age_days, min_mb = int(sys.argv[1]), int(sys.argv[2])
      cutoff = time.time() - age_days * 86400
      roots = ["/tmp", "/tmp/opencode"]

      def measure(p):
          """(megabytes, newest mtime anywhere in the tree).

          The newest mtime is the load-bearing half. A DIRECTORY's own mtime
          only moves when its top-level entries change -- writing to
          `<dir>/sub/file` does not touch `<dir>`. Long-running agent scratch is
          created once and then written through nested paths, so judging it by
          `os.lstat(dir).st_mtime` would read a tree that was active five
          minutes ago as untouched for a month, and delete it.

          The in-use check below does not cover that gap: it sees only
          processes holding a handle at the instant the sweep runs, and scratch
          written by a series of short-lived commands holds nothing in between.

          So "abandoned" has to mean "nothing ANYWHERE underneath has changed
          within the window". Walking is also cheaper than it looks -- it
          replaces the `du` subprocess rather than adding to it.
          """
          total = 0
          newest = 0.0
          for dirpath, dirnames, filenames in os.walk(p, onerror=lambda e: None):
              try: newest = max(newest, os.lstat(dirpath).st_mtime)
              except OSError: pass
              for name in filenames + dirnames:
                  try: st = os.lstat(os.path.join(dirpath, name))
                  except OSError: continue
                  newest = max(newest, st.st_mtime)
                  if not os.path.islink(os.path.join(dirpath, name)):
                      total += getattr(st, "st_blocks", 0) * 512
          return total // (1024 * 1024), newest

      def classify(p):
          """'no-repo' | 'clean' | 'dirty' | 'unpushed'. Only the last two protect."""
          if not os.path.exists(os.path.join(p, ".git")):
              return "no-repo"
          if subprocess.run(["git", "-C", p, "rev-parse", "--git-dir"],
                            capture_output=True).returncode != 0:
              return "no-repo"          # stray or gutted .git, not a real repo
          st = subprocess.run(["git", "-C", p, "status", "--porcelain",
                               "--untracked-files=all"], capture_output=True, text=True)
          if st.returncode != 0 or st.stdout.strip():
              return "dirty"            # cannot tell counts as dirty
          up = subprocess.run(["git", "-C", p, "log", "--branches", "--not",
                               "--remotes", "--oneline"], capture_output=True, text=True)
          return "unpushed" if (up.returncode == 0 and up.stdout.strip()) else "clean"

      cands = []
      for root in roots:
          if not os.path.isdir(root): continue
          for name in sorted(os.listdir(root)):
              p = os.path.join(root, name)
              if root == "/tmp" and name == "opencode": continue   # swept per-child
              if not os.path.isdir(p) or os.path.islink(p): continue
              try: st = os.lstat(p)
              except OSError: continue
              if st.st_uid != os.getuid(): continue
              if st.st_mtime >= cutoff: continue      # cheap reject first
              mb, newest = measure(p)                 # then the honest test
              if newest >= cutoff:
                  print(f"  keep {mb}M {p} (touched {(time.time()-newest)/86400:.1f}d ago, nested)")
                  continue
              if mb >= min_mb: cands.append((mb, p))

      inuse = set()
      for pid in os.listdir("/proc"):
          if not pid.isdigit(): continue
          links = [f"/proc/{pid}/cwd", f"/proc/{pid}/exe"]
          try: links += [f"/proc/{pid}/fd/{f}" for f in os.listdir(f"/proc/{pid}/fd")]
          except OSError: pass
          for link in links:
              try: real = os.readlink(link)
              except OSError: continue
              for _, p in cands:
                  if real == p or real.startswith(p + "/"): inuse.add(p)

      freed = 0
      for mb, p in sorted(cands, reverse=True):
          if p in inuse:
              print(f"  keep {mb}M {p} (open by a live process)"); continue
          state = classify(p)
          if state in ("dirty", "unpushed"):
              print(f"  keep {mb}M {p} ({state})"); continue
          gitfile = os.path.join(p, ".git")
          if os.path.isfile(gitfile):
              # A registered worktree: deregister so the parent repo does not
              # keep a dangling administrative entry.
              try:
                  gitdir = open(gitfile).read().strip().split("gitdir:", 1)[1].strip()
                  main = gitdir.split("/.git/worktrees/")[0]
                  subprocess.run(["git", "-C", main, "worktree", "remove", "--force", p],
                                 capture_output=True)
              except (IndexError, OSError):
                  pass
          if os.path.exists(p):
              shutil.rmtree(p, ignore_errors=True)
          print(f"  removed {mb}M {p} ({state})")
          freed += mb
      print(f"  /tmp scratch sweep freed {freed} MB")
      PYEOF
      }

      # --- 5. OpenCode WAL checkpoint ---
      cleanup_opencode_wal() {
        local db="$HOME/.local/share/opencode/opencode.db"
        [ -f "$db" ] || return 0

        local wal="$db-wal"
        if [ -f "$wal" ]; then
          wal_size=$(du -sh "$wal" 2>/dev/null | cut -f1)
          log "OpenCode WAL is $wal_size, checkpointing..."
          # Use nix-shell to get sqlite3 since it's not in the system path
          nix-shell -p sqlite --run "sqlite3 '$db' 'PRAGMA wal_checkpoint(TRUNCATE);'" 2>/dev/null || {
            log "WARN: WAL checkpoint failed (opencode may be running)"
          }
        fi
      }

      # --- Main ---
      log "Starting disk cleanup..."
      log "Disk before: $(df -h / | tail -1 | awk '{print $3, "used,", $4, "free,", $5}')"

      cleanup_nix
      cleanup_worktrees
      cleanup_bazel
      cleanup_caches
      cleanup_opencode_wal

      log "Disk after:  $(df -h / | tail -1 | awk '{print $3, "used,", $4, "free,", $5}')"
      log "Disk cleanup complete"
    '';
  };

  # Systemd service for disk cleanup
  systemd.user.services.disk-cleanup = {
    Unit = {
      Description = "Nightly disk cleanup (worktrees, caches, nix GC)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/disk-cleanup";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 19;
      IOSchedulingClass = "idle";
      Environment = [
        "HOME=%h"
        # /run/wrappers/bin must precede /run/current-system/sw/bin so `sudo`
        # resolves to the setuid wrapper, not the non-setuid symlink in
        # /run/current-system/sw/bin (which exits 1 with "sudo: must be owned
        # by uid 0 and have the setuid bit set" and aborts the script under
        # `set -e`).
        "PATH=${pkgs.nix}/bin:${pkgs.git}/bin:/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
  };

  # Timer: run daily at 3 AM
  systemd.user.timers.disk-cleanup = {
    Unit = {
      Description = "Nightly disk cleanup timer";
    };
    Timer = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
