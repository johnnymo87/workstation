#!/usr/bin/env bash
# Quick test for the project-key collapse logic.
# Run: bash test-project-key.sh

set -o errexit -o nounset -o pipefail

# Mirror the regex from default.nix
project_key() {
  local dir="$1"
  if [[ "$dir" =~ ^"${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
    printf '%s/projects/%s\n' "$HOME" "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$dir"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon")"                                    "project root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/foo/bar")"                            "subdir"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x")"               "worktree root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x/foo/bar")"       "worktree subdir"
assert_eq "$HOME/projects/workstation" "$(project_key "$HOME/projects/workstation/.worktrees/launch-auto-attach")" "another project worktree"
assert_eq "/tmp/foo"                   "$(project_key "/tmp/foo")"                                                 "non-project path"
assert_eq "$HOME"                      "$(project_key "$HOME")"                                                    "bare home"
echo "all project-key tests passed"
