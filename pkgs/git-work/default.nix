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
  -h, --help  Show this help message.

Examples:
  work feature-login
  work hotfix-123 hotfix/bug-123
  eval "\$(work --cd feature-xyz)"
EOF
    }

    # Helper: resolve the primary repository root from a given directory
    resolve_primary_root() {
      local dir
      dir="$(realpath "$1")"
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

    main() {
      local CD_MODE=0
      local TRUNK_OVERRIDE=""

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

      if [ $# -lt 1 ]; then
        show_help
        exit 1
      fi

      local slug="$1"
      local branch_arg="''${2:-}"

      if [ $# -gt 2 ]; then
        die "Too many arguments (expected at most <slug> [branch])"
      fi

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
      if [ -n "$TRUNK_OVERRIDE" ]; then
        trunk="$TRUNK_OVERRIDE"
      else
        local trunk_ref
        trunk_ref="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        if [ -n "$trunk_ref" ]; then
          trunk="''${trunk_ref#origin/}"
        else
          trunk=""
        fi
      fi

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
      # 1. git fetch origin <trunk>
      # 2. git worktree add <root>/.worktrees/<slug> -b <branch> origin/<trunk>
      log "Fetching latest origin/$trunk..."
      git -C "$root" fetch origin "$trunk" >&2

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
