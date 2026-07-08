{ pkgs }:

pkgs.writeShellApplication {
  name = "work";
  runtimeInputs = with pkgs; [
    git
    coreutils
    gnused
  ];
  text = ''
    # work - a repo-agnostic git-worktree helper
    #
    # Usage:
    #   work <slug> [branch]
    #   work --cd <slug> [branch]
    #   work --help

    log() {
      printf '[work] %s\n' "$*" >&2
    }

    die() {
      log "FATAL: $*"
      exit 1
    }

    show_help() {
      cat <<EOF
Usage: work [options] <slug> [branch]
       work --prune-merged [options]

Create a new git worktree under .worktrees/<slug> tracking the repository's trunk branch.

Arguments:
  <slug>      The name/identifier for the worktree directory under .worktrees/.
  [branch]    Optional branch name. Defaults to a sanitized version of <slug>.

Options:
  --cd        Instead of printing the absolute path, emit a 'cd <path>' command
              suitable for eval, e.g.: eval "\$(work --cd <slug>)"
  -t, --trunk <branch>
              Explicitly specify the trunk branch rather than auto-detecting it
              from origin/HEAD.
  --no-fetch  Skip the network 'git fetch origin <trunk>' before creating the
              worktree; branch off the LOCAL origin/<trunk> as-is. Use when the
              caller must not block on the network (e.g. opencode-launch).
  --prune-merged
              Sweep .worktrees/*: remove every worktree whose branch is fully
              merged into origin/<trunk> AND whose working tree is clean, then
              delete its branch. Never touches dirty or unmerged worktrees, the
              primary root, or the current worktree. Ignores <slug>.
  -h, --help  Show this help message.

Notes:
  The fetch is BEST-EFFORT and bounded by a timeout: a slow or failed fetch logs
  a warning and proceeds off the local origin/<trunk> rather than failing.

Examples:
  work feature-login
  work hotfix-123 hotfix/bug-123
  eval "\$(work --cd feature-xyz)"
  work --no-fetch quick-slice
  work --prune-merged
EOF
    }

    # Helper: resolve the primary repository root from a given directory
    resolve_primary_root() {
      local dir
      # -m (canonicalize-missing) so the ~/projects/<P> regex fast-path works
      # for a not-yet-existing path too, instead of realpath erroring and
      # silently falling through to the CWD-dependent git fallback.
      dir="$(realpath -m "$1")"
      # Collapse ~/projects/<P>/(/.worktrees/<W>)?(/.*)? -> ~/projects/<P>
      if [[ "$dir" =~ ^"''${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
        printf '%s/projects/%s\n' "''${HOME}" "''${BASH_REMATCH[1]}"
      else
        local common_dir
        if common_dir="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"; then
          if [[ "$common_dir" != /* ]]; then
            common_dir="$dir/$common_dir"
          fi
          realpath "$(dirname "$common_dir")"
        else
          die "Not inside a git repository"
        fi
      fi
    }

    # Helper: sanitize slug to a valid git branch name
    sanitize_branch() {
      local slug="$1"
      printf '%s\n' "$slug" | sed -E 's/[^A-Za-z0-9._/-]/-/g'
    }

    # Bounded, best-effort fetch of origin/<trunk>. Never fails the caller: a
    # slow/failed fetch logs a warning and returns 0, leaving the local
    # origin/<trunk> in place (already far fresher than a rotted primary root).
    # The launcher's "degrade, never fail" invariant depends on this.
    FETCH_TIMEOUT="''${WORK_FETCH_TIMEOUT:-15}"
    best_effort_fetch() {
      local root="$1" trunk="$2"
      log "Fetching latest origin/$trunk (best-effort, ''${FETCH_TIMEOUT}s timeout)..."
      if timeout "$FETCH_TIMEOUT" git -C "$root" fetch origin "$trunk" >&2; then
        return 0
      fi
      log "WARNING: fetch of origin/$trunk failed or timed out; proceeding with the local origin/$trunk (may be slightly stale)."
      return 0
    }

    # Helper: resolve the trunk branch (origin/HEAD short name, minus the
    # 'origin/' prefix), honoring an explicit override. Prints empty on failure.
    resolve_trunk() {
      local root="$1" override="''${2:-}"
      if [ -n "$override" ]; then
        printf '%s\n' "$override"
        return 0
      fi
      local trunk_ref
      trunk_ref="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      if [ -n "$trunk_ref" ]; then
        printf '%s\n' "''${trunk_ref#origin/}"
      fi
      return 0
    }

    # --prune-merged: remove every worktree under <root>/.worktrees/ whose branch
    # is fully merged into origin/<trunk> and whose working tree is clean, then
    # delete that branch. This is the pruning OWNER named in the Phase 3.5 design
    # (M1c): it reclaims the worktrees opencode-launch --worktree leaves behind on
    # the happy path. Safety by construction -- it NEVER removes:
    #   - the primary root or the current worktree
    #   - a worktree with uncommitted/untracked changes (status --porcelain)
    #   - a branch with commits not yet in origin/<trunk> (not an ancestor)
    # so an active session's worktree (which has unmerged work) is protected, and
    # we don't need a live-session probe here.
    prune_merged() {
      local no_fetch="''${1:-0}" trunk_override="''${2:-}"
      local root
      root="$(resolve_primary_root "$PWD")"

      local trunk
      trunk="$(resolve_trunk "$root" "$trunk_override")"
      if [ -z "$trunk" ]; then
        die "Could not determine the trunk branch from origin/HEAD (pass --trunk <branch>)."
      fi

      # Clean stale metadata, then refresh origin/<trunk> so the merged check is
      # accurate (best-effort; --no-fetch skips it).
      git -C "$root" worktree prune >&2
      if [ "$no_fetch" -eq 0 ]; then
        best_effort_fetch "$root" "$trunk"
      fi

      local self
      self="$(realpath "$PWD")"
      local wt_root="$root/.worktrees"

      local removed=0 kept=0
      local wt_path="" wt_branch="" line=""
      # Parse `git worktree list --porcelain`: records separated by blank lines,
      # "worktree <path>" then optionally "branch refs/heads/<name>". A record is
      # only evaluated when we have a non-empty wt_path, so the stream's trailing
      # blank line(s) don't inflate the kept count.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "worktree "*)
            wt_path="''${line#worktree }"
            wt_branch=""
            ;;
          "branch "*)
            wt_branch="''${line#branch refs/heads/}"
            ;;
          "")
            if [ -n "$wt_path" ]; then
              if prune_one "$root" "$trunk" "$self" "$wt_root" "$wt_path" "$wt_branch"; then
                removed=$((removed + 1))
              else
                kept=$((kept + 1))
              fi
            fi
            wt_path=""; wt_branch=""
            ;;
        esac
      done < <(git -C "$root" worktree list --porcelain; printf '\n')

      log "prune-merged: removed $removed, kept $kept."
    }

    # prune_one: evaluate a single worktree record and remove it if it is a
    # merged+clean worktree under .worktrees/. Returns 0 if removed, 1 otherwise.
    prune_one() {
      local root="$1" trunk="$2" self="$3" wt_root="$4" wt_path="$5" wt_branch="$6"
      [ -n "$wt_path" ] || return 1
      local real_wt
      real_wt="$(realpath "$wt_path" 2>/dev/null || printf '%s' "$wt_path")"
      # Only ever touch worktrees under <root>/.worktrees/.
      case "$real_wt/" in
        "$wt_root"/*) : ;;
        *) return 1 ;;
      esac
      # Never remove the current worktree or a detached one.
      [ "$real_wt" != "$self" ] || { log "prune-merged: keep $wt_path (current worktree)"; return 1; }
      [ -n "$wt_branch" ] || { log "prune-merged: keep $wt_path (detached HEAD)"; return 1; }
      # Never remove a dirty worktree.
      if [ -n "$(git -C "$real_wt" status --porcelain 2>/dev/null)" ]; then
        log "prune-merged: keep $wt_path (uncommitted changes)"
        return 1
      fi
      # Only remove if the branch tip is fully contained in origin/<trunk>.
      local tip
      tip="$(git -C "$root" rev-parse --verify "refs/heads/$wt_branch" 2>/dev/null || true)"
      if [ -z "$tip" ]; then
        log "prune-merged: keep $wt_path (branch '$wt_branch' missing)"
        return 1
      fi
      if git -C "$root" merge-base --is-ancestor "$tip" "origin/$trunk" 2>/dev/null; then
        git -C "$root" worktree remove "$real_wt" >&2 2>/dev/null \
          || git -C "$root" worktree remove --force "$real_wt" >&2
        git -C "$root" branch -D "$wt_branch" >&2 2>/dev/null || true
        log "prune-merged: removed $wt_path (branch '$wt_branch' merged into origin/$trunk)"
        return 0
      fi
      log "prune-merged: keep $wt_path (branch '$wt_branch' not merged into origin/$trunk)"
      return 1
    }

    main() {
      local CD_MODE=0
      local TRUNK_OVERRIDE=""
      local NO_FETCH=0
      local PRUNE_MERGED=0

      while [ $# -gt 0 ]; do
        case "$1" in
          -h|--help)
            show_help
            exit 0
            ;;
          --cd)
            CD_MODE=1
            shift
            ;;
          --no-fetch)
            NO_FETCH=1
            shift
            ;;
          --prune-merged)
            PRUNE_MERGED=1
            shift
            ;;
          -t|--trunk)
            if [ $# -lt 2 ]; then
              die "--trunk requires an argument"
            fi
            TRUNK_OVERRIDE="$2"
            shift 2
            ;;
          -*)
            die "Unknown option $1"
            ;;
          *)
            break
            ;;
        esac
      done

      # --prune-merged is a sweep mode: it takes no slug and exits when done.
      if [ "$PRUNE_MERGED" -eq 1 ]; then
        if [ $# -gt 0 ]; then
          die "--prune-merged takes no positional arguments (got '$1')"
        fi
        prune_merged "$NO_FETCH" "$TRUNK_OVERRIDE"
        exit 0
      fi

      if [ $# -lt 1 ]; then
        show_help
        exit 1
      fi

      local slug="$1"
      local branch_arg="''${2:-}"

      if [ $# -gt 2 ]; then
        die "Too many arguments (expected at most <slug> [branch])"
      fi

      # Guard the slug against path traversal: it becomes a directory name under
      # .worktrees/, so an absolute path or a '..' segment could escape the repo
      # (the branch name is separately sanitized, but the worktree PATH is not).
      case "$slug" in
        "" ) die "Slug must not be empty." ;;
        /* | -* ) die "Invalid slug '$slug': must not start with '/' or '-'." ;;
        *..* ) die "Invalid slug '$slug': must not contain '..'." ;;
      esac

      # Determine branch name
      local branch
      if [ -n "$branch_arg" ]; then
        branch="$branch_arg"
      else
        branch="$(sanitize_branch "$slug")"
      fi

      # Resolve primary repo root from current directory
      local root
      root="$(resolve_primary_root "$PWD")"

      # Determine trunk branch
      local trunk
      trunk="$(resolve_trunk "$root" "$TRUNK_OVERRIDE")"

      if [ -z "$trunk" ]; then
        echo "Error: Could not determine the trunk branch from origin/HEAD." >&2
        echo "Please set origin/HEAD in your repository by running:" >&2
        echo "  git -C $root remote set-head origin -a" >&2
        echo "Or pass the trunk branch name explicitly using --trunk <branch> (or -t <branch>)." >&2
        exit 1
      fi

      # Run non-destructive git prune to clean up stale metadata of manually rm -rf'd worktrees
      git -C "$root" worktree prune >&2

      local new_wt_path="$root/.worktrees/$slug"

      # Fail loudly if worktree path already exists
      if [ -e "$new_wt_path" ] || [ -d "$new_wt_path" ]; then
        die "Worktree directory already exists: $new_wt_path"
      fi

      # Fail loudly if branch name already exists in local branches
      if git -C "$root" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
        die "Branch '$branch' already exists."
      fi

      # Steps:
      # 1. git fetch origin <trunk>   (bounded, best-effort; skipped by --no-fetch)
      # 2. git worktree add <root>/.worktrees/<slug> -b <branch> origin/<trunk>
      if [ "$NO_FETCH" -eq 1 ]; then
        log "Skipping fetch (--no-fetch); branching off the local origin/$trunk."
      else
        best_effort_fetch "$root" "$trunk"
      fi

      log "Adding worktree for branch '$branch' at $new_wt_path tracking origin/$trunk..."
      git -C "$root" worktree add "$new_wt_path" -b "$branch" "origin/$trunk" >&2

      # Success output
      if [ "$CD_MODE" -eq 1 ]; then
        printf 'cd %q\n' "$new_wt_path"
      else
        echo "$new_wt_path"
        log "Worktree successfully created."
        log "To change into the new worktree, run:"
        printf "  cd %q\n" "$new_wt_path" >&2
      fi
    }

    if [[ "''${BASH_SOURCE[0]}" == "''${0}" ]]; then
      main "$@"
    fi
  '';
}
