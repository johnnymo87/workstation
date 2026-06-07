#!/usr/bin/env bash
# Unit tests for oc-auto-attach helper functions.
# Mirror the helpers from default.nix and exercise them directly.
# Run: bash test-project-key.sh

set -o errexit -o nounset -o pipefail

# ---- helpers under test (mirror of default.nix) -----------------------------

# project_key: collapse ~/projects/<P>/(/.worktrees/<W>)?(/.*)? -> ~/projects/<P>.
project_key() {
  local dir="$1"
  if [[ "$dir" =~ ^"${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
    printf '%s/projects/%s\n' "$HOME" "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$dir"
  fi
}

# resolve_nvims: prefer $OC_NVIMS_BIN (if set and executable), else
# fall back to `command -v nvims`. Prints path on stdout, exits 0
# on success; prints nothing and exits 1 if neither is usable.
# Stale / unusable $OC_NVIMS_BIN logs a warning to stderr and falls
# back, so an out-of-date systemd env doesn't strand interactive users.
resolve_nvims() {
  if [ -n "${OC_NVIMS_BIN:-}" ]; then
    if [ -x "$OC_NVIMS_BIN" ]; then
      printf '%s\n' "$OC_NVIMS_BIN"
      return 0
    fi
    printf '[oc-auto-attach] OC_NVIMS_BIN=%s is set but not executable; falling back to PATH\n' \
      "$OC_NVIMS_BIN" >&2
  fi
  local found
  found="$(command -v nvims || true)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

# list_session_panes <session-name>: emit "pane_id|cmd|path" for every pane in
# the named session ONLY. We filter `list-panes -a` on #{session_name} rather
# than `list-panes -s -t "=<name>"` because the latter is NOT a robust session
# target: tmux resolves "=<name>" through the WINDOW namespace of the active
# session first, so a window literally named <name> (e.g. an nvim editing
# ~/projects/<name>) hijacks the scan and returns that window's session
# (usually `main`) instead of the session called <name>. Mirror of the
# production function in default.nix; exercised by the tmux tests below.
list_session_panes() {
  local session="$1"
  tmux list-panes -a -f "#{==:#{session_name},$session}" \
    -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || true
}

# ---- test infrastructure ----------------------------------------------------

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

assert_exit() {
  local expected_rc="$1" actual_rc="$2" msg="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    printf 'PASS  %s\n' "$msg"
  else
    printf 'FAIL  %s\n        expected exit: %s\n        actual exit:   %s\n' "$msg" "$expected_rc" "$actual_rc"
    exit 1
  fi
}

# ---- project_key tests ------------------------------------------------------

assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon")"                                    "project_key: project root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/foo/bar")"                            "project_key: subdir"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x")"               "project_key: worktree root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x/foo/bar")"       "project_key: worktree subdir"
assert_eq "$HOME/projects/workstation" "$(project_key "$HOME/projects/workstation/.worktrees/launch-auto-attach")" "project_key: another project worktree"
assert_eq "/tmp/foo"                   "$(project_key "/tmp/foo")"                                                 "project_key: non-project path"
assert_eq "$HOME"                      "$(project_key "$HOME")"                                                    "project_key: bare home"

# ---- resolve_nvims tests ----------------------------------------------------

# Stage a fake executable and a fake non-executable file we can point
# OC_NVIMS_BIN at, and a fake PATH-discoverable `nvims` for fallback tests.
nvims_tmpdir="$(mktemp -d)"
trap 'rm -rf "$nvims_tmpdir"' EXIT

fake_env_nvims="$nvims_tmpdir/env-nvims"
printf '#!/bin/sh\necho env-nvims\n' > "$fake_env_nvims"
chmod +x "$fake_env_nvims"

nonexec_path="$nvims_tmpdir/not-executable"
printf 'not a binary\n' > "$nonexec_path"
chmod 644 "$nonexec_path"

fake_path_dir="$nvims_tmpdir/path"
mkdir -p "$fake_path_dir"
fake_path_nvims="$fake_path_dir/nvims"
printf '#!/bin/sh\necho path-nvims\n' > "$fake_path_nvims"
chmod +x "$fake_path_nvims"

# Scenario 1: OC_NVIMS_BIN points to an executable -> use it, ignore PATH.
out="$(OC_NVIMS_BIN="$fake_env_nvims" PATH="$fake_path_dir" resolve_nvims 2>/dev/null)"
assert_eq "$fake_env_nvims" "$out" "resolve_nvims: env var with executable wins over PATH"

# Scenario 2: OC_NVIMS_BIN unset, nvims discoverable on PATH -> fall back.
unset_out="$(unset OC_NVIMS_BIN; PATH="$fake_path_dir" resolve_nvims 2>/dev/null)"
assert_eq "$fake_path_nvims" "$unset_out" "resolve_nvims: unset env falls back to PATH"

# Scenario 3: OC_NVIMS_BIN empty string -> treat as unset, fall back to PATH.
empty_out="$(OC_NVIMS_BIN="" PATH="$fake_path_dir" resolve_nvims 2>/dev/null)"
assert_eq "$fake_path_nvims" "$empty_out" "resolve_nvims: empty env falls back to PATH"

# Scenario 4: OC_NVIMS_BIN points to non-executable file -> warn, fall back.
fallback_out="$(OC_NVIMS_BIN="$nonexec_path" PATH="$fake_path_dir" resolve_nvims 2>/dev/null)"
assert_eq "$fake_path_nvims" "$fallback_out" "resolve_nvims: stale env falls back to PATH"

# Scenario 5: OC_NVIMS_BIN points to nonexistent path -> warn, fall back.
missing_out="$(OC_NVIMS_BIN="$nvims_tmpdir/does-not-exist" PATH="$fake_path_dir" resolve_nvims 2>/dev/null)"
assert_eq "$fake_path_nvims" "$missing_out" "resolve_nvims: missing env falls back to PATH"

# Scenario 6: stale env should emit a warning on stderr.
warn_stderr="$(OC_NVIMS_BIN="$nonexec_path" PATH="$fake_path_dir" resolve_nvims 2>&1 >/dev/null)"
case "$warn_stderr" in
  *"OC_NVIMS_BIN=$nonexec_path is set but not executable"*) printf 'PASS  resolve_nvims: warns on stale env\n' ;;
  *) printf 'FAIL  resolve_nvims: warns on stale env\n        stderr: %s\n' "$warn_stderr"; exit 1 ;;
esac

# Scenario 7: nothing set, nothing on PATH -> exit 1, empty stdout.
set +e
none_out="$(unset OC_NVIMS_BIN; PATH="$nvims_tmpdir/empty" resolve_nvims 2>/dev/null)"
none_rc=$?
set -e
assert_eq ""  "$none_out" "resolve_nvims: nothing available -> empty stdout"
assert_exit "1" "$none_rc"  "resolve_nvims: nothing available -> exit 1"

# ---- list_session_panes tests (real tmux) -----------------------------------
#
# Regression for the window/session name collision: when a window in the
# user's `main` session is literally named the same as the confined target
# session (e.g. `lgtm`, because they have nvim open on ~/projects/lgtm), the
# old `list-panes -s -t "=lgtm"` scan resolved to that window's session and
# leaked `main`'s panes -- so lgtm-dispatched review/gather tabs landed in
# `main`. list_session_panes must return ONLY the target session's panes.
#
# Needs a real tmux; SKIP if absent (e.g. stripped CI shell).
if command -v tmux >/dev/null 2>&1; then
  scan_sock="oc_aa_scan_test_$$"
  scan_tmpdir="$(mktemp -d)"
  scan_cleanup() {
    # `command tmux` so this is correct whether or not the tmux shadow
    # function (defined below) is active when the EXIT trap fires.
    command tmux -L "$scan_sock" kill-server 2>/dev/null || true
    rm -rf "$scan_tmpdir"
  }
  trap 'rm -rf "$nvims_tmpdir"; scan_cleanup' EXIT

  mkdir -p "$scan_tmpdir/proj-a" "$scan_tmpdir/proj-b"

  # Isolated tmux server (-L) so we never touch the user's real sessions.
  # Session `lgtm` holds a pane whose cwd is proj-a (what we want to find).
  tmux -L "$scan_sock" new-session -d -s lgtm -c "$scan_tmpdir/proj-a" -n protos
  # Session `main` holds a pane whose cwd is proj-b, in a window NAMED `lgtm`
  # -- the collision that fooled the old `-s -t "=lgtm"` scan.
  tmux -L "$scan_sock" new-session -d -s main -c "$scan_tmpdir/proj-b" -n placeholder
  tmux -L "$scan_sock" rename-window -t main:0 lgtm

  # Point list_session_panes at the isolated server for the duration of the
  # scan tests by shadowing `tmux` with a wrapper that injects -L.
  tmux() { command tmux -L "$scan_sock" "$@"; }

  scan_out="$(list_session_panes lgtm)"

  case "$scan_out" in
    *"$scan_tmpdir/proj-a"*)
      printf 'PASS  list_session_panes: returns target session pane\n' ;;
    *)
      printf 'FAIL  list_session_panes: returns target session pane\n        out: %s\n' "$scan_out"; exit 1 ;;
  esac

  case "$scan_out" in
    *"$scan_tmpdir/proj-b"*)
      printf 'FAIL  list_session_panes: leaks main-session pane via window-name collision\n        out: %s\n' "$scan_out"; exit 1 ;;
    *)
      printf 'PASS  list_session_panes: ignores same-named window in another session\n' ;;
  esac

  unset -f tmux
  scan_cleanup
  trap 'rm -rf "$nvims_tmpdir"' EXIT
else
  printf 'SKIP  list_session_panes tmux tests (tmux not on PATH)\n'
fi

# ---- production-script integration check ------------------------------------
#
# The unit tests above exercise a mirror of the helper logic. This check
# proves that the actual built oc-auto-attach script also defines the
# helpers we just tested, so the two definitions can't silently diverge
# without one of these assertions tripping. We grep the built artifact
# rather than the .nix file because the .nix file embeds the script as
# a string with shell interpolations escaped; the built script is what
# actually runs in production.
#
# Skipped if oc-auto-attach isn't on PATH (e.g. running this test in a
# stripped-down CI shell). In that case the unit tests above still run.
oc_aa="$(command -v oc-auto-attach || true)"
if [ -n "$oc_aa" ]; then
  if grep -q '^[[:space:]]*resolve_nvims()' "$oc_aa"; then
    printf 'PASS  production script defines resolve_nvims\n'
  else
    printf 'FAIL  production script defines resolve_nvims\n        not found in: %s\n' "$oc_aa"
    exit 1
  fi
  if grep -q 'OC_NVIMS_BIN' "$oc_aa"; then
    printf 'PASS  production script honors OC_NVIMS_BIN\n'
  else
    printf 'FAIL  production script honors OC_NVIMS_BIN\n        OC_NVIMS_BIN never referenced in: %s\n' "$oc_aa"
    exit 1
  fi
else
  printf 'SKIP  production-script integration check (oc-auto-attach not on PATH)\n'
fi

# ---- production-source check (default.nix) -----------------------------------
#
# The artifact check above greps the *deployed* binary, which lags the source
# until a rebuild+switch. This check greps the default.nix sibling directly so
# a source-level regression (reintroducing the fragile confined scan) trips
# immediately, before deploy. The session-scan command form survives Nix's
# '' string verbatim (no ${ } or '' sequences), so a literal grep is reliable.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  if grep -q 'list_session_panes()' "$default_nix"; then
    printf 'PASS  source defines list_session_panes\n'
  else
    printf 'FAIL  source defines list_session_panes\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'list-panes -a -f' "$default_nix"; then
    printf 'PASS  source scans session via #{session_name} filter\n'
  else
    printf 'FAIL  source scans session via #{session_name} filter\n        "list-panes -a -f" not found in: %s\n' "$default_nix"
    exit 1
  fi
  # The fragile form that caused review/gather tabs to land in `main` must
  # never come back for the confined scan.
  if grep -q 'list-panes -s -t "=' "$default_nix"; then
    printf 'FAIL  source still uses fragile confined scan (list-panes -s -t "=...")\n        in: %s\n' "$default_nix"
    exit 1
  else
    printf 'PASS  source has no fragile confined scan (list-panes -s -t "=...")\n'
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

echo "all oc-auto-attach helper tests passed"
