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
                log "Removing lgtm pr-$pr_num worktree ($pr_state): $repo_name/$wt_name"
                git -C "$repo_dir" worktree remove "$wt_dir" --force 2>&1 || true
                continue
              fi
              # OPEN / unknown -> leave alone, fall through to generic checks
            fi

            # Check if merged into origin/main
            head_sha=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null) || continue
            if git -C "$repo_dir" merge-base --is-ancestor "$head_sha" origin/main 2>/dev/null; then
              log "Removing merged worktree: $repo_name/$wt_name"
              git -C "$repo_dir" worktree remove "$wt_dir" --force 2>&1 || true
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
        ; do
          if [ -d "$cache_dir" ]; then
            size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1)
            rm -rf "$cache_dir"
            log "Removed $cache_dir ($size)"
          fi
        done

        # Stale /tmp files
        sudo find /tmp -maxdepth 1 -name "nix-shell.*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "nix-*" -mtime +7 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "pip-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "pyright-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
        sudo find /tmp -maxdepth 1 -name "fp-digest-*" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

        log "Cache cleanup complete"
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
