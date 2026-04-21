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
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
        pkgs.nix
        pkgs.python3
      ]}:$PATH"

      PROJECTS="$HOME/projects"
      BAZEL_BASE="$HOME/.cache/bazel/_bazel_$(whoami)"
      WORKTREE_MAX_AGE_DAYS=28
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

          # Fetch and prune remote refs
          git -C "$repo_dir" fetch --prune origin 2>/dev/null || {
            log "WARN: fetch failed for $repo_name, skipping"
            continue
          }

          for wt_dir in "$repo_dir"/.worktrees/*/; do
            [ -d "$wt_dir" ] || continue
            wt_name=$(basename "$wt_dir")

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

      # --- 3. Bazel orphan output bases ---
      cleanup_bazel() {
        [ -d "$BAZEL_BASE" ] || return 0
        log "Scanning for orphan Bazel output bases..."

        python3 -c "
      import hashlib, os, sys

      base = '$BAZEL_BASE'
      projects = '$PROJECTS'

      # Build map of all known workspace hashes
      known = set()
      for repo in os.listdir(projects):
          repo_path = os.path.join(projects, repo)
          if not os.path.isdir(repo_path):
              continue
          known.add(hashlib.md5(repo_path.encode()).hexdigest())
          wt_dir = os.path.join(repo_path, '.worktrees')
          if os.path.isdir(wt_dir):
              for wt in os.listdir(wt_dir):
                  wt_path = os.path.join(wt_dir, wt)
                  if os.path.isdir(wt_path):
                      known.add(hashlib.md5(wt_path.encode()).hexdigest())

      # Find orphans
      for entry in os.listdir(base):
          if entry == 'install':
              continue
          path = os.path.join(base, entry)
          if os.path.isdir(path) and entry not in known:
              print(entry)
      " | while read -r orphan; do
          log "Removing orphan Bazel output base: $orphan"
          sudo rm -rf "$BAZEL_BASE/$orphan" 2>&1 || log "WARN: failed to remove $orphan, continuing"
        done

        log "Bazel cleanup complete"
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
