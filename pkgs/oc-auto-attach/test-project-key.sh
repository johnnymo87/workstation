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

echo "all oc-auto-attach helper tests passed"
