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

# parse_serve_url <route-json-body> <fallback-url>: extract .apiBase from a
# pigeon GET /route JSON body and print it. Falls back to <fallback-url> when
# the body is empty, not JSON, or .apiBase is absent/null/empty. Pure (no
# network) so the production caller does the curl and hands the body in.
# Mirror of the production function in default.nix; exercised by the tests
# below and kept in lockstep by the source-grep guard at the bottom.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.apiBase // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
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

# ---- parse_serve_url tests --------------------------------------------------
#
# Pool-aware serve resolution: oc-auto-attach asks pigeon's GET /route which
# serve owns a session, then attaches the TUI there. parse_serve_url is the
# pure parse+fallback core. The whole point is that ANY malformed/absent
# response degrades to the caller's fallback (today's :4096), so the fix can
# never be worse than the pre-pool behavior. Needs jq (a runtimeInput of the
# package); SKIP if absent in a stripped shell.
fallback_url="http://127.0.0.1:4096"
if command -v jq >/dev/null 2>&1; then
  # Happy path: a real /route body routes the TUI to the owning serve (:4097).
  route_body='{"sessionId":"ses_x","serveId":"serve-1","apiBase":"http://127.0.0.1:4097","eventUrl":"http://127.0.0.1:4097/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4097" "$(parse_serve_url "$route_body" "$fallback_url")" \
    "parse_serve_url: valid route body -> apiBase (owning serve)"

  # Empty body (pigeon down / curl failed) -> fallback.
  assert_eq "$fallback_url" "$(parse_serve_url "" "$fallback_url")" \
    "parse_serve_url: empty body -> fallback"

  # Non-JSON garbage (proxy error page, partial read) -> fallback.
  assert_eq "$fallback_url" "$(parse_serve_url "not json at all" "$fallback_url")" \
    "parse_serve_url: non-JSON body -> fallback"

  # Valid JSON but no apiBase field -> fallback.
  assert_eq "$fallback_url" "$(parse_serve_url '{"sessionId":"ses_x"}' "$fallback_url")" \
    "parse_serve_url: JSON without apiBase -> fallback"

  # apiBase present but null -> fallback.
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":null}' "$fallback_url")" \
    "parse_serve_url: apiBase null -> fallback"

  # apiBase present but empty string -> fallback.
  assert_eq "$fallback_url" "$(parse_serve_url '{"apiBase":""}' "$fallback_url")" \
    "parse_serve_url: apiBase empty string -> fallback"
else
  printf 'SKIP  parse_serve_url tests (jq not on PATH)\n'
fi

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

  # Isolate from the caller's tmux client env. A headless opencode serve
  # inherits leaked TMUX / TMUX_PANE from the viewer pane it was launched
  # under (same env-leak family as workstation-8iqt). Leaving them set lets
  # the caller's environment perturb `tmux -L <sock> new-session` against the
  # isolated server; unset them so this block is deterministic from ANY
  # caller env (interactive shell, inside tmux, or headless serve loop).
  unset TMUX TMUX_PANE

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

  # `new-session -d` returns as soon as the session exists, but the pane's
  # shell may not have exec'd / chdir'd yet: a freshly forked pane can briefly
  # report the server bootstrap command ("tmux") and the launch cwd (this
  # repo) instead of the shell sitting in proj-a. Under heavy load that window
  # widened enough for the assertions below to read a half-born pane and fail
  # (workstation-kpv9: `out: %0|tmux|/home/.../workstation`). Poll until BOTH
  # isolated panes report their expected cwd before scanning, and fail FAST
  # with a clear setup diagnostic if they never settle -- so a half-born pane
  # can never masquerade as a list_session_panes logic bug. (`SECONDS` is a
  # bash builtin counting whole seconds since shell start.)
  settle_deadline=$(( SECONDS + 5 ))
  while :; do
    panes_a="$(list_session_panes lgtm)"
    panes_b="$(list_session_panes main)"
    if [[ "$panes_a" == *"$scan_tmpdir/proj-a"* && "$panes_b" == *"$scan_tmpdir/proj-b"* ]]; then
      break
    fi
    if [ "$SECONDS" -ge "$settle_deadline" ]; then
      printf 'FAIL  list_session_panes: isolated tmux server never settled (setup)\n        lgtm: %s\n        main: %s\n' \
        "$panes_a" "$panes_b"
      exit 1
    fi
    sleep 0.1
  done

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
  # Pool-aware serve resolution must be present in the source: the
  # parse_serve_url helper, the PIGEON_DAEMON_URL env, and the /route query.
  if grep -q 'parse_serve_url()' "$default_nix"; then
    printf 'PASS  source defines parse_serve_url\n'
  else
    printf 'FAIL  source defines parse_serve_url\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'PIGEON_DAEMON_URL' "$default_nix"; then
    printf 'PASS  source honors PIGEON_DAEMON_URL\n'
  else
    printf 'FAIL  source honors PIGEON_DAEMON_URL\n        PIGEON_DAEMON_URL never referenced in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q '/route?session_id=' "$default_nix"; then
    printf 'PASS  source queries pigeon /route?session_id=\n'
  else
    printf 'FAIL  source queries pigeon /route?session_id=\n        "/route?session_id=" not found in: %s\n' "$default_nix"
    exit 1
  fi
else
  printf 'SKIP  production-source check (default.nix not next to test)\n'
fi

echo "all oc-auto-attach helper tests passed"
