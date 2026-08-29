# Nightly disk cleanup for cloudbox
# Auto-discovers repos with worktrees, cleans orphan Bazel output bases,
# prunes stale caches, and runs nix garbage collection.
{ config, pkgs, lib, isCloudbox, ... }:

let
  # Same shared alert helper the opencode canaries use, so disk pressure reaches
  # the same place their drift does rather than inventing a second channel.
  driftAlert = pkgs.callPackage ../../pkgs/opencode-drift-alert { };
in
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

      # Remove a worktree whose branch/PR is already merged or closed.
      # Clean -> remove immediately. Dirty -> remove only once NOTHING anywhere
      # in the tree has been modified for WORKTREE_MAX_AGE_DAYS; otherwise
      # merged-but-dirty worktrees accumulate forever (30+ observed in the
      # 2026-08-28 disk-full incident, see beads workstation-zspp).
      #
      # Freshness is a full-tree mtime scan (find -newermt), NOT a parse of
      # `git status` paths. Porcelain quotes any path containing so much as a
      # space, so a stat-per-dirty-path check silently skips quoted paths --
      # a tree whose only FRESH dirt is "My Notes.md" would have been judged
      # by its stale dirt and reaped (adversarial review of PR #426). The
      # full-tree scan has no parsing to get wrong, and over-keeps by design:
      # ANY fresh file (build output, log) keeps the tree, which is the safe
      # direction on a box where ~15 concurrent sessions share these dirs.
      # Checkout itself sets fresh mtimes, so a worktree younger than the
      # window is never reaped. The removed HEAD sha is logged so unpushed
      # commits on a detached HEAD (lgtm pr-N worktrees) stay recoverable
      # from the journal within git's gc window.
      remove_merged_worktree() {
        local repo_dir="$1" wt_dir="$2" repo_name="$3" wt_name="$4" label="$5"
        local status_out head_sha

        if ! status_out=$(git -C "$wt_dir" status --porcelain --untracked-files=all 2>/dev/null); then
          log "WARN: keeping $label because status failed: $repo_name/$wt_name"
          return 0
        fi

        head_sha=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        if [ -n "$status_out" ]; then
          local cutoff_epoch fresh_path
          cutoff_epoch=$(( $(date +%s) - WORKTREE_MAX_AGE_DAYS * 86400 ))
          fresh_path=$(find "$wt_dir" -xdev -newermt "@$cutoff_epoch" -print -quit 2>/dev/null || true)

          if [ -n "$fresh_path" ]; then
            log "WARN: keeping $label with uncommitted changes (tree touched within ''${WORKTREE_MAX_AGE_DAYS}d): $repo_name/$wt_name"
            return 0
          fi

          log "Removing $label with stale uncommitted changes (untouched >=''${WORKTREE_MAX_AGE_DAYS}d, HEAD $head_sha): $repo_name/$wt_name"
          git -C "$repo_dir" worktree remove "$wt_dir" --force 2>&1 || true
          return 0
        fi

        log "Removing $label (HEAD $head_sha): $repo_name/$wt_name"
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
                remove_merged_worktree "$repo_dir" "$wt_dir" "$repo_name" "$wt_name" "lgtm pr-$pr_num worktree ($pr_state)"
                continue
              fi
              # OPEN / unknown -> leave alone, fall through to generic checks
            fi

            # Check if merged into origin/main
            head_sha=$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null) || continue
            if git -C "$repo_dir" merge-base --is-ancestor "$head_sha" origin/main 2>/dev/null; then
              remove_merged_worktree "$repo_dir" "$wt_dir" "$repo_name" "$wt_name" "merged worktree"
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

        # 3b. Shared --disk_cache (~/bazel-diskcache, configured by the
        # home-manager-generated ~/.bazelrc in home.base.nix -- the HOME rc
        # is read after the workspace rc, so it overrides mono/.bazelrc's
        # relative --disk_cache path; mono builds write here too).
        # Bazel's own GC keeps this at <=5 GB. Removing the contents
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

  # --------------------------------------------------------------------------
  # disk-watch: the alarm BETWEEN nightly cleanups.
  #
  # The cleanup above is not the problem -- when it runs it reclaims 80-90G in
  # about fifteen minutes. The problem is that it runs once a day and nothing
  # watches the other twenty-three hours. Twice in four days the volume filled
  # in the evening and was rescued only because a human happened to look:
  #
  #   2026-08-25 20:18   362G used, 15G free,  97%
  #   2026-08-28 18:46   373G used, 3.6G free, 100%   <- killed a running episode
  #
  # The second one exited an automation mid-flight with
  # `echo: write error: No space left on device`, which is a failure mode that
  # cannot even report itself: the notification path needed a write too.
  #
  # WHY 85%, from the nightly log series rather than taste. Post-cleanup baseline
  # is 245-285G (65-76%). Ordinary pre-nightly peaks were 81%, 82%, 84%. The two
  # incident days ran +117G and +112G instead of the usual +47..55G. 85% of 393G
  # is 334G -- above the worst ordinary peak (314G), below both incidents.
  # Replayed against 2026-08-28 it fires around 13:30, five hours before the box
  # filled. So it is quiet on a normal day and early on a bad one, which is the
  # only combination worth paging for.
  #
  # WHY IT ONLY WARNS, having deliberately dropped the auto-cleanup half:
  #   1. disk-cleanup runs `cleanup_nix` FIRST (see "--- Main ---" above), and
  #      the cleaning-disk skill documents that above ~90% a nix GC can generate
  #      enough I/O pressure that socket-activated sshd stops answering, needing
  #      a console reset. Triggering at 90% would launch the box-wedging step
  #      exactly and only inside the danger zone.
  #   2. It would not have helped anyway. The bazel purge SKIPS any output base
  #      whose server PID is alive, and a spike like these is *caused* by three
  #      live bazel servers holding 12-25G each. At the moment of peak pressure
  #      almost everything worth reclaiming is exactly what gets skipped.
  # Constant hazard, near-zero benefit. A human (or an agent reading the alert)
  # can run the cleanup deliberately, which is what happened both times already.
  home.file.".local/bin/disk-watch" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      # NOTE: `set -e` is deliberately absent. This script's whole job is to
      # report a problem, and a nonzero exit would put disk-watch.service into
      # `failed` -- a state nobody reads -- precisely when the disk is in
      # trouble. Every step below either succeeds or degrades to a log line.
      set -uo pipefail

      TARGET="''${DISK_WATCH_TARGET:-/}"
      STATE="''${DISK_WATCH_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/disk-watch/alert}"
      # Same override seam as the opencode plugin canary: the tests point this at
      # a stub, the unit gets the real store path.
      ALERT="''${DISK_WATCH_ALERT:-${driftAlert}}"

      WARN_PCT=85
      # Recovery floor. NOT 85: clearing the episode the moment we drop below the
      # warn line means an 84<->86 sawtooth starts a brand-new episode on every
      # crossing, and the helper dedupes per episode -- so it would alert on each
      # one, resetting the backoff counter every time. That is the alert storm
      # the helper exists to prevent. The gap between 80 and 85 is the dead band.
      CLEAR_PCT=80

      log() { printf '[disk-watch] %s\n' "$*" >&2; }

      # `df -P` guarantees the one-line-per-filesystem POSIX format, so the data
      # is on the LAST line; the first is the header, and parsing that yields the
      # literal string "Capacity" where a number belongs.
      LINE="$(df -P "$TARGET" 2>/dev/null | tail -1)"
      # Fields: filesystem blocks used available capacity mountpoint.
      PCT=""; AVAIL=""
      read -r _ _ _ AVAIL PCT _ <<< "$LINE"
      PCT="''${PCT%\%}"

      case "$PCT" in
        ""|*[!0-9]*)
          log "could not read a usage percentage for $TARGET from: $LINE"
          exit 0
          ;;
      esac

      if [ "$PCT" -ge "$WARN_PCT" ]; then
        case "$AVAIL" in ""|*[!0-9]*) AVAIL=0 ;; esac
        AVAIL_G=$(( AVAIL / 1048576 ))
        # NO $USER HERE. The unit sets only HOME and PATH, so $USER is unbound
        # under `set -u` and the script would abort BEFORE alerting -- putting
        # disk-watch.service into `failed` at exactly the moment the disk is
        # full, which is the one thing this script must never do. Caught by
        # running the suite under the unit's actual environment rather than an
        # interactive shell's; a glob needs no variable anyway.
        TEXT="Disk $TARGET is $PCT% full (''${AVAIL_G}G free) and the next scheduled cleanup is 03:00. Twice recently this went to 100% within hours and killed a running job. To reclaim now: systemctl --user start disk-cleanup.service (frees 80-90G, takes ~15min). If it reclaims little, the space is held by LIVE bazel servers, which the cleanup skips on purpose -- find them with: ls -d ~/.cache/bazel/_bazel_*/*/server"
        mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
        # 900s base, doubling, capped at 4h -- the house convention shared with
        # the auth-drift and plugin canaries.
        "$ALERT" "$STATE" "disk-warn" "$TEXT" 900 14400 \
          || log "alert helper failed (rc=$?); disk is at $PCT%"
      elif [ "$PCT" -lt "$CLEAR_PCT" ]; then
        # Episode over. Drop the helper's state so the next one starts at alert
        # #1 rather than inheriting a stale count and announcing itself as
        # "STILL UNRESOLVED: alert #7, first reported 400h ago".
        rm -f "$STATE" 2>/dev/null || true
      fi

      exit 0
    '';
  };

  systemd.user.services.disk-watch = {
    Unit = {
      Description = "Disk usage threshold watch (warn only)";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.local/bin/disk-watch";
      StandardOutput = "journal";
      StandardError = "journal";
      Nice = 19;
      IOSchedulingClass = "idle";
      Environment = [
        "HOME=%h"
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
      ];
    };
  };

  systemd.user.timers.disk-watch = {
    Unit = {
      Description = "Disk usage threshold watch timer";
    };
    Timer = {
      # OnUnitActiveSec alone would never fire: it is measured from the last
      # activation, and a unit that has never run has none. OnStartupSec gives
      # it the first one. Persistent= is omitted deliberately -- it only applies
      # to OnCalendar timers, and replaying a missed disk poll is meaningless
      # anyway since the reading is only ever about right now.
      OnStartupSec = "5min";
      OnUnitActiveSec = "15min";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
