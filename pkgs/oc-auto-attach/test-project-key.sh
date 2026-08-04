#!/usr/bin/env bash
# Unit tests for oc-auto-attach helper functions.
# Mirror the helpers from default.nix and exercise them directly.
# Run: bash test-project-key.sh
#
# Wired into `nix flake check` as checks.oc-auto-attach (flake.nix). Before
# 2026-08-04 it was wired into NOTHING -- pkgs/oc-auto-attach/default.nix sets
# no doCheck/checkPhase and CI runs only `nix flake check` -- so every assertion
# below was, in flake.nix's own words, documentation with a shebang
# (workstation-pscu). Two things follow from that history and must not be
# undone:
#
#   1. TOOL ABSENCE IS FATAL INSIDE A NIX BUILD. Every optional-dependency
#      branch below SKIPs when its tool is missing, which is correct for a
#      developer laptop and catastrophic in CI: with jq/tmux/nvim absent this
#      suite printed "all oc-auto-attach helper tests passed" and exited 0
#      having silently dropped 20 of its 71 assertions -- including every
#      interesting one. Any runner that guarantees the tools sets
#      OC_AA_REQUIRE_ALL_TOOLS=1, which turns a missing tool into a hard
#      failure. That is POSITIVE CONTROL on purpose: the obvious heuristic,
#      "NIX_BUILD_TOP is set, so we are inside a Nix build", is simply false --
#      `nix-shell` exports NIX_BUILD_TOP=/tmp/nix-shell-<pid> and
#      IN_NIX_SHELL=impure, so a developer in any nix-shell without tmux would
#      get a hard failure whose message ("check is mis-wired") is a lie.
#      Sniffing the ambient environment guesses; an env var the runner sets
#      states. Forgetting to set it cannot open a silent hole either: the
#      flake check greps for the full tally and for the absence of SKIP.
#
#   2. THE ASSERTION COUNT IS ASSERTED. Reaching the end proves nothing about
#      how much ran; a suite that asserts nothing also exits 0. EXPECTED_ASSERTIONS
#      pins the number, so silently losing coverage fails loudly instead.

set -o errexit -o nounset -o pipefail

# Total assertions this suite makes when nothing is skipped. Bump it in the same
# commit that adds or removes an assertion -- a diff that changes coverage
# without touching this number is exactly the silent drift this pins down.
EXPECTED_ASSERTIONS=71

ASSERT_COUNT=0
SKIP_COUNT=0

# pass <msg>: record and report one satisfied assertion. Every PASS in this file
# goes through here so the count cannot drift from what is printed.
pass() {
  ASSERT_COUNT=$((ASSERT_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

# require_tool <tool> <what-would-be-skipped>: 0 if the tool is usable, 1 if the
# caller should SKIP. When OC_AA_REQUIRE_ALL_TOOLS is set there is no third
# option -- the runner promised the tool, so absence is a mis-wired check, not a
# degraded environment, and skipping would restore the blind spot this suite was
# un-blinded to fix.
require_tool() {
  local tool="$1" what="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${OC_AA_REQUIRE_ALL_TOOLS:-}" ]; then
    printf 'FAIL  %s: %s missing but OC_AA_REQUIRE_ALL_TOOLS is set (check is mis-wired)\n' "$what" "$tool"
    exit 1
  fi
  printf 'SKIP  %s (%s not on PATH)\n' "$what" "$tool"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  return 1
}

# Absolute repo root, so every path below is independent of the caller's cwd.
# The nvim harness used to `loadfile` a path relative to cwd, which meant the
# suite passed from the repo root and failed from its own directory -- and a
# Nix build runs from neither by default.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# nvim writes state/shada under $HOME; in a Nix sandbox HOME is /homeless-shelter
# and unwritable. Give it a scratch one there (TMPDIR is the build dir, which Nix
# removes for us). Outside the sandbox the caller's HOME is left alone -- these
# tests read it symbolically and asserting against the real one is the point.
if [ ! -w "${HOME:-/nonexistent}" ]; then
  export HOME="${TMPDIR:-/tmp}/oc-aa-test-home-$$"
  mkdir -p "$HOME"
fi

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

# window_name: the tmux window name oc-auto-attach derives for a session dir.
# Mirrors the same branch as project_key in default.nix: for ~/projects/<P>[/...]
# it is <P>; otherwise it is basename(dir). Kept in lockstep with the source by
# the derivation grep guard in the production-source check below (same guard
# also covers project_key).
window_name() {
  local dir="$1"
  if [[ "$dir" =~ ^"${HOME}/projects/"([^/]+)(/.*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$(basename "$dir")"
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
# pigeon GET /route or POST /place JSON body and print it. Falls back to
# <fallback-url> when the body is empty, not JSON, or the serve-URL field is
# absent/null/empty. Accepts BOTH `apiBase` (route, camelCase) and `api_base`
# (place, snake_case). Pure (no network) so the production caller does the curl
# and hands the body in. Mirror of the production function in default.nix;
# exercised by the tests below and kept in lockstep by the source-grep guard.
parse_serve_url() {
  local body="$1" fallback="$2" api
  api="$(printf '%s' "$body" | jq -r '.apiBase // .api_base // empty' 2>/dev/null || true)"
  if [ -n "$api" ] && [ "$api" != "null" ]; then
    printf '%s\n' "$api"
  else
    printf '%s\n' "$fallback"
  fi
}

# classify_session_probe <http_code> <body>: decide what the step-1 readiness
# loop should do with ONE `GET /session/<id>` result. Prints exactly one line:
#   FOUND <directory>  200 with a non-empty .directory -> attach can proceed.
#   MISS               404: the session is absent from the shared opencode.db.
#                      Every serve in the K-serve pool reads that one DB, so a
#                      404 from the routed owner is CONCLUSIVE -- waiting cannot
#                      make it appear. The loop gives up fast (after a short
#                      grace for the launch-commit race) instead of burning the
#                      whole 30s window (workstation-ovqu).
#   WAIT               anything else -- empty/000 (connection refused, or a
#                      --max-time abort while the event loop is wedged), 5xx, or
#                      200 without a directory yet -- a TRANSIENT condition;
#                      keep polling through the full timeout.
# Mirror of the production function in default.nix; kept in lockstep by the
# source-grep guard at the bottom. Needs jq (a runtimeInput of the package).
classify_session_probe() {
  local code="$1" body="$2" dir
  if [ "$code" = "200" ]; then
    dir="$(printf '%s' "$body" | jq -r '.directory // empty' 2>/dev/null || true)"
    if [ -n "$dir" ] && [ "$dir" != "null" ]; then
      printf 'FOUND %s\n' "$dir"
      return 0
    fi
    printf 'WAIT\n'
    return 0
  fi
  if [ "$code" = "404" ]; then
    printf 'MISS\n'
    return 0
  fi
  printf 'WAIT\n'
  return 0
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

# resolve_pigeon_auth: resolve pigeon bearer auth token at call time.
# Mirror of default.nix function.
resolve_pigeon_auth() {
  local token="${PIGEON_DAEMON_AUTH_TOKEN:-}"
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  if [ -z "$token" ]; then
    local token_file="${PIGEON_DAEMON_AUTH_TOKEN_FILE:-/run/secrets/pigeon_daemon_auth_token}"
    if [ -r "$token_file" ]; then
      token="$(cat "$token_file" 2>/dev/null || true)"
      token="$(printf '%s' "$token" | tr -d '[:space:]')"
    fi
  fi
  place_auth=()
  if [ -n "$token" ]; then
    place_auth=(-H "Authorization: Bearer $token")
  fi
}

# ---- test infrastructure ----------------------------------------------------

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$msg"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    exit 1
  fi
}

assert_exit() {
  local expected_rc="$1" actual_rc="$2" msg="$3"
  if [ "$expected_rc" = "$actual_rc" ]; then
    pass "$msg"
  else
    printf 'FAIL  %s\n        expected exit: %s\n        actual exit:   %s\n' "$msg" "$expected_rc" "$actual_rc"
    exit 1
  fi
}

# ---- project_key / window_name tests ----------------------------------------

assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon")"                                    "project_key: project root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/foo/bar")"                            "project_key: subdir"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x")"               "project_key: worktree root"
assert_eq "$HOME/projects/pigeon"      "$(project_key "$HOME/projects/pigeon/.worktrees/feature-x/foo/bar")"       "project_key: worktree subdir"
assert_eq "$HOME/projects/workstation" "$(project_key "$HOME/projects/workstation/.worktrees/launch-auto-attach")" "project_key: another project worktree"
assert_eq "/tmp/foo"                   "$(project_key "/tmp/foo")"                                                 "project_key: non-project path"
assert_eq "$HOME"                      "$(project_key "$HOME")"                                                    "project_key: bare home"

# 2026-07-16: the morning reset agent launches in $HOME/morning (not a ~/projects
# path), so project_key stays verbatim and window_name is its basename `morning`.
# This is the derivation the non-headless-morning-agent fix relies on.
assert_eq "$HOME/morning" "$(project_key "$HOME/morning")" "project_key: morning marker dir stays verbatim"
assert_eq "morning"       "$(window_name "$HOME/morning")" "window_name: morning marker dir -> morning"
# Lock the window_name mirror against the /projects branch too, so the mirror
# itself is trustworthy (matches project_key's own cases above).
assert_eq "pigeon"      "$(window_name "$HOME/projects/pigeon")"             "window_name: project root -> project name"
assert_eq "pigeon"      "$(window_name "$HOME/projects/pigeon/foo/bar")"     "window_name: project subdir -> project name"
assert_eq "workstation" "$(window_name "$HOME/projects/workstation/.worktrees/x")" "window_name: worktree -> project name"
assert_eq "foo"         "$(window_name "/tmp/foo")"                          "window_name: non-project path -> basename"

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
  *"OC_NVIMS_BIN=$nonexec_path is set but not executable"*) pass 'resolve_nvims: warns on stale env' ;;
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
if require_tool jq 'parse_serve_url tests'; then
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

  # POST /place returns snake_case api_base (GET /route returns camelCase
  # apiBase). parse_serve_url must accept BOTH so it can parse a /place response
  # for the authoritative owning serve as well as a /route response.
  place_body='{"ok":true,"session_id":"ses_x","serve_id":"serve-1","api_base":"http://127.0.0.1:4097","event_url":"http://127.0.0.1:4097/event?session_ids=ses_x"}'
  assert_eq "http://127.0.0.1:4097" "$(parse_serve_url "$place_body" "$fallback_url")" \
    "parse_serve_url: /place api_base (snake_case) -> owning serve"

  # api_base present but null/empty -> fallback (mirror the apiBase cases).
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":null}' "$fallback_url")" \
    "parse_serve_url: api_base null -> fallback"
  assert_eq "$fallback_url" "$(parse_serve_url '{"api_base":""}' "$fallback_url")" \
    "parse_serve_url: api_base empty string -> fallback"
fi

# ---- classify_session_probe tests -------------------------------------------
#
# The step-1 readiness loop must distinguish a DEFINITIVE 404 (the session is
# absent from the shared opencode.db -> give up fast) from a TRANSIENT stall
# (a 000 --max-time abort while the event loop is wedged, or a 5xx -> keep
# polling the full 30s). Before this fix oc-auto-attach swallowed the 404 with
# `curl -sf ... || true` and burned the whole 30s window on a session that
# could never appear -- a manual attach of a stale/nonexistent sid hung the
# terminal for 30s (workstation-ovqu). Needs jq (a runtimeInput); SKIP if absent.
if require_tool jq 'classify_session_probe tests'; then
  assert_eq "FOUND /home/dev/projects/workstation" \
    "$(classify_session_probe 200 '{"directory":"/home/dev/projects/workstation"}')" \
    "classify_session_probe: 200 + directory -> FOUND <dir>"

  # The fix: a real 404 (live serve, NotFoundError body) is a definitive MISS.
  assert_eq "MISS" \
    "$(classify_session_probe 404 '{"name":"NotFoundError","data":{"message":"Session not found"}}')" \
    "classify_session_probe: 404 -> MISS (definitive, fast-fail)"

  # Transient: curl could not connect / --max-time aborted a wedged event loop.
  # http_code is 000; the loop must keep polling, NOT give up like a 404.
  assert_eq "WAIT" \
    "$(classify_session_probe 000 '')" \
    "classify_session_probe: 000 (connect refused / timeout) -> WAIT (transient)"

  # Transient: serve returned a 5xx -> keep polling.
  assert_eq "WAIT" \
    "$(classify_session_probe 503 'service unavailable')" \
    "classify_session_probe: 5xx -> WAIT (transient)"

  # 200 but the session row has no directory yet -> not ready, keep polling.
  assert_eq "WAIT" \
    "$(classify_session_probe 200 '{"id":"ses_x"}')" \
    "classify_session_probe: 200 without directory -> WAIT (transient)"

  # 200 with an explicit null directory -> same as missing -> keep polling.
  assert_eq "WAIT" \
    "$(classify_session_probe 200 '{"directory":null}')" \
    "classify_session_probe: 200 with null directory -> WAIT"
fi

# ---- resolve_pigeon_auth tests ----------------------------------------------
# Test 1: env var set
PIGEON_DAEMON_AUTH_TOKEN="  env_token_aa  "
resolve_pigeon_auth
assert_eq "2" "${#place_auth[@]}" "resolve_pigeon_auth: env set yields auth array of length 2"
assert_eq "Authorization: Bearer env_token_aa" "${place_auth[1]}" "resolve_pigeon_auth: env set second element Bearer token"

# Test 2: env unset, token file present
unset PIGEON_DAEMON_AUTH_TOKEN
tf_aa="$(mktemp)"
printf "  file_token_aa \n" > "$tf_aa"
PIGEON_DAEMON_AUTH_TOKEN_FILE="$tf_aa"
resolve_pigeon_auth
rm -f "$tf_aa"
assert_eq "2" "${#place_auth[@]}" "resolve_pigeon_auth: file fallback yields auth array of length 2"
assert_eq "Authorization: Bearer file_token_aa" "${place_auth[1]}" "resolve_pigeon_auth: file fallback token trimmed"

# Test 3: neither set
unset PIGEON_DAEMON_AUTH_TOKEN
PIGEON_DAEMON_AUTH_TOKEN_FILE="/nonexistent/pigeon_token_test"
resolve_pigeon_auth
assert_eq "0" "${#place_auth[@]}" "resolve_pigeon_auth: neither set yields empty auth array"
unset PIGEON_DAEMON_AUTH_TOKEN_FILE

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
if require_tool tmux 'list_session_panes tmux tests'; then
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
  #
  # The deadline is 30s, not the 5s that sufficed locally: this now runs in CI
  # alongside every other check on a shared aarch64 runner, and the repo already
  # documents 5-15s stalls for its own processes under load (default.nix:285).
  # The deadline only costs time when something is actually broken, and a check
  # that flakes under load gets disabled -- which would restore the blindness
  # this whole change exists to end.
  settle_deadline=$(( SECONDS + 30 ))
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
      pass 'list_session_panes: returns target session pane' ;;
    *)
      printf 'FAIL  list_session_panes: returns target session pane\n        out: %s\n' "$scan_out"; exit 1 ;;
  esac

  case "$scan_out" in
    *"$scan_tmpdir/proj-b"*)
      printf 'FAIL  list_session_panes: leaks main-session pane via window-name collision\n        out: %s\n' "$scan_out"; exit 1 ;;
    *)
      pass 'list_session_panes: ignores same-named window in another session' ;;
  esac

  unset -f tmux
  scan_cleanup
  trap 'rm -rf "$nvims_tmpdir"' EXIT
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
    pass 'production script defines resolve_nvims'
  else
    printf 'FAIL  production script defines resolve_nvims\n        not found in: %s\n' "$oc_aa"
    exit 1
  fi
  if grep -q 'OC_NVIMS_BIN' "$oc_aa"; then
    pass 'production script honors OC_NVIMS_BIN'
  else
    printf 'FAIL  production script honors OC_NVIMS_BIN\n        OC_NVIMS_BIN never referenced in: %s\n' "$oc_aa"
    exit 1
  fi
elif [ -n "${OC_AA_REQUIRE_ALL_TOOLS:-}" ]; then
  # The runner promised oc-auto-attach on PATH; absence means mis-wiring.
  printf 'FAIL  production-script integration check: oc-auto-attach missing but OC_AA_REQUIRE_ALL_TOOLS is set (check is mis-wired)\n'
  exit 1
else
  printf 'SKIP  production-script integration check (oc-auto-attach not on PATH)\n'
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ---- production-source check (default.nix) -----------------------------------
#
# The artifact check above greps the *deployed* binary, which lags the source
# until a rebuild+switch. This check greps the default.nix sibling directly so
# a source-level regression (reintroducing the fragile confined scan) trips
# immediately, before deploy. The session-scan command form survives Nix's
# '' string verbatim (no ${ } or '' sequences), so a literal grep is reliable.
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  if grep -q 'list_session_panes()' "$default_nix"; then
    pass 'source defines list_session_panes'
  else
    printf 'FAIL  source defines list_session_panes\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'list-panes -a -f' "$default_nix"; then
    pass 'source scans session via #{session_name} filter'
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
    pass 'source has no fragile confined scan (list-panes -s -t "=...")'
  fi
  # Pool-aware serve resolution must be present in the source: the
  # parse_serve_url helper, the PIGEON_DAEMON_URL env, and the /route query.
  if grep -q 'parse_serve_url()' "$default_nix"; then
    pass 'source defines parse_serve_url'
  else
    printf 'FAIL  source defines parse_serve_url\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'resolve_pigeon_auth()' "$default_nix"; then
    pass 'source defines resolve_pigeon_auth'
  else
    printf 'FAIL  source defines resolve_pigeon_auth\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'place_auth' "$default_nix" && grep -q '/route?session_id=' "$default_nix"; then
    pass 'source passes place_auth array to GET /route'
  else
    printf 'FAIL  source passes place_auth array to GET /route\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'PIGEON_DAEMON_URL' "$default_nix"; then
    pass 'source honors PIGEON_DAEMON_URL'
  else
    printf 'FAIL  source honors PIGEON_DAEMON_URL\n        PIGEON_DAEMON_URL never referenced in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q '/route?session_id=' "$default_nix"; then
    pass 'source queries pigeon /route?session_id='
  else
    printf 'FAIL  source queries pigeon /route?session_id=\n        "/route?session_id=" not found in: %s\n' "$default_nix"
    exit 1
  fi
  # Front door polling: the step-1 readiness poll must go through the front door.
  if grep -qF 'FRONTDOOR_URL=' "$default_nix"; then
    pass 'source defines FRONTDOOR_URL'
  else
    printf 'FAIL  source defines FRONTDOOR_URL\n        "FRONTDOOR_URL=" not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -qF '"$FRONTDOOR_URL"' "$default_nix"; then
    pass 'source passes FRONTDOOR_URL to the poll subshell'
  else
    printf 'FAIL  source passes FRONTDOOR_URL to the poll subshell\n        "\"$FRONTDOOR_URL\"" not found in: %s\n' "$default_nix"
    exit 1
  fi
  # Placement (workstation-iwpj + fable M2 #1): the door places sessions it
  # creates, so the common path is a read-only GET /route (asserted above). But
  # a never-placed session (minted via the in-TUI new-session keybind, direct to
  # a serve) 404s on /route, and the source MUST fall back to POST /place to heal
  # it (else the TUI pins to the anchor and goes stale). Assert the fallback call
  # is present. Match the actual call so accurate comments don't trip the guard.
  if grep -q '\-X POST "\$PIGEON_DAEMON_URL/place"' "$default_nix"; then
    pass 'source falls back to POST /place for never-placed sessions'
  else
    printf 'FAIL  source falls back to POST /place for never-placed sessions\n        -X POST "$PIGEON_DAEMON_URL/place" not found in: %s\n' "$default_nix"
    exit 1
  fi
  # 404 fast-fail (workstation-ovqu): the step-1 readiness probe must give up
  # fast on a DEFINITIVE 404 instead of burning the full 30s window, while
  # still polling through transient 000/5xx stalls. Guard that the source
  # defines the classifier and wires the bounded 404-grace fast-fail path.
  if grep -q 'classify_session_probe()' "$default_nix"; then
    pass 'source defines classify_session_probe'
  else
    printf 'FAIL  source defines classify_session_probe\n        not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -q 'OC_AA_404_GRACE_SECS' "$default_nix"; then
    pass 'source fast-fails on definitive 404 (OC_AA_404_GRACE_SECS grace)'
  else
    printf 'FAIL  source fast-fails on definitive 404\n        OC_AA_404_GRACE_SECS not found in: %s\n' "$default_nix"
    exit 1
  fi
  # The old swallow-everything SESSION probe (`curl -sf ... "$url/session/$sid"`
  # with no http_code inspection) must not come back, or 404s silently burn the
  # 30s window again. Scoped to the /session/ probe so it does not flag the
  # /route call, which legitimately keeps `curl -sf ... || true`.
  if grep -Eq 'curl -sf[^|]*/session/' "$default_nix"; then
    printf 'FAIL  source still uses 404-swallowing /session probe (curl -sf .../session/...)\n        in: %s\n' "$default_nix"
    exit 1
  else
    pass 'source /session probe no longer swallows the http status (curl -sf)'
  fi
  # The morning-agent fix relies on oc-auto-attach deriving window_name from the
  # session dir basename for non-~/projects paths (so $HOME/morning -> `morning`),
  # and NOT collapsing non-project dirs. Guard the production derivation so a
  # source-side refactor trips here instead of silently breaking the morning window.
  if grep -qF '/projects/"([^/]+)(/.*)?$' "$default_nix"; then
    pass 'source derives project via ~/projects/<P> regex'
  else
    printf 'FAIL  source derives project via ~/projects/<P> regex\n        derivation regex not found in: %s\n' "$default_nix"
    exit 1
  fi
  if grep -qF 'window_name="$(basename "$session_dir")"' "$default_nix"; then
    pass 'source derives window_name as basename for non-project dirs'
  else
    printf 'FAIL  source derives window_name as basename for non-project dirs\n        basename derivation not found in: %s\n' "$default_nix"
    exit 1
  fi

  # ---- backpressure / settle & flock source guards ---------------------------

  if grep -q 'util-linux' "$default_nix"; then
    pass 'source includes util-linux in runtimeInputs'
  else
    printf 'FAIL  source includes util-linux in runtimeInputs\n        util-linux not found in: %s\n' "$default_nix"
    exit 1
  fi

  if grep -q 'OC_AA_SERIALIZE' "$default_nix"; then
    pass 'source defines serialization knob (OC_AA_SERIALIZE)'
  else
    printf 'FAIL  source defines serialization knob (OC_AA_SERIALIZE)\n        OC_AA_SERIALIZE not found in: %s\n' "$default_nix"
    exit 1
  fi

  if grep -q 'OC_AA_MAX_CONCURRENCY' "$default_nix"; then
    printf 'FAIL  source still contains misleading OC_AA_MAX_CONCURRENCY knob\n        in: %s\n' "$default_nix"
    exit 1
  else
    pass 'source removed misleading OC_AA_MAX_CONCURRENCY knob'
  fi

  if grep -q 'OC_AA_SETTLE_SECS' "$default_nix"; then
    pass 'source defines settle window timeout (OC_AA_SETTLE_SECS)'
  else
    printf 'FAIL  source defines settle window timeout (OC_AA_SETTLE_SECS)\n        OC_AA_SETTLE_SECS not found in: %s\n' "$default_nix"
    exit 1
  fi

  if grep -qF '5000 ms + margin' "$default_nix"; then
    pass 'source includes 5000 ms + margin derivation comment for settle window'
  else
    printf 'FAIL  source includes 5000 ms + margin derivation comment for settle window\n        derivation comment not found in: %s\n' "$default_nix"
    exit 1
  fi

  if grep -q 'require('"'"'user.oc_auto_attach'"'"').status' "$default_nix"; then
    pass 'source queries user.oc_auto_attach.status via RPC'
  else
    printf 'FAIL  source queries user.oc_auto_attach.status via RPC\n        status query expression not found in: %s\n' "$default_nix"
    exit 1
  fi

  if grep -q 'exit 6' "$default_nix"; then
    pass 'source exits non-zero on attach failure / settle timeout'
  else
    printf 'FAIL  source exits non-zero on attach failure / settle timeout\n        exit 6 not found in: %s\n' "$default_nix"
    exit 1
  fi
else
  if [ -n "${OC_AA_REQUIRE_ALL_TOOLS:-}" ]; then
    printf 'FAIL  production-source check: %s missing but OC_AA_REQUIRE_ALL_TOOLS is set (check is mis-wired)\n' "$default_nix"
    exit 1
  fi
  printf 'SKIP  production-source check (default.nix not next to test)\n'
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ---- lua helper guards & unit tests ------------------------------------------

lua_source="$repo_root/assets/nvim/lua/user/oc_auto_attach.lua"
if [ -f "$lua_source" ]; then
  if grep -q 'on_exit' "$lua_source"; then
    pass 'lua source defines on_exit handler'
  else
    printf 'FAIL  lua source defines on_exit handler\n        on_exit not found in: %s\n' "$lua_source"
    exit 1
  fi

  if grep -q 'function M\.status' "$lua_source"; then
    pass 'lua source exposes status query function (M.status)'
  else
    printf 'FAIL  lua source exposes status query function (M.status)\n        function M.status not found in: %s\n' "$lua_source"
    exit 1
  fi

  if require_tool nvim 'lua module unit test via nvim -l'; then
    lua_out="$(OC_AA_LUA_SOURCE="$lua_source" nvim -l /dev/stdin <<< '
      local M = loadfile(os.getenv("OC_AA_LUA_SOURCE"))()
      assert(type(M.status) == "function", "M.status is function")
      assert(M.status("ses_test") == "unknown", "unknown sid -> unknown")
      assert(M.open(nil) == 0, "invalid opts -> 0")
      assert(M.open({sid="ses_123", dir="/nonexistent/dir", url="http://127.0.0.1:4096"}) == 0, "invalid dir -> 0")

      -- Test pre-settle vs post-settle discriminator
      local last_opts1, last_buf1
      vim.fn.jobstart = function(cmd, opts)
        last_opts1 = opts
        last_buf1 = vim.api.nvim_get_current_buf()
        return 100
      end
      M.open({sid="ses_test1", dir=".", url="http://127.0.0.1:4096", settle_ms=5000})
      vim.wait(100, function() return last_opts1 ~= nil end)
      last_opts1.on_exit(100, 0, "exit")
      assert(M.status("ses_test1") == "failed", "pre-settle exit -> status failed")
      assert(vim.api.nvim_buf_get_name(last_buf1):find("%[FAILED%]"), "pre-settle exit -> buffer renamed [FAILED]")

      local last_opts2, last_buf2
      vim.fn.jobstart = function(cmd, opts)
        last_opts2 = opts
        last_buf2 = vim.api.nvim_get_current_buf()
        return 101
      end
      M.open({sid="ses_test2", dir=".", url="http://127.0.0.1:4096", settle_ms=0})
      vim.wait(100, function() return last_opts2 ~= nil end)
      vim.wait(10)
      last_opts2.on_exit(101, 0, "exit")
      assert(M.status("ses_test2") == "exited", "post-settle exit -> status exited")
      assert(not vim.api.nvim_buf_get_name(last_buf2):find("%[FAILED%]"), "post-settle exit -> buffer NOT renamed [FAILED]")

      print("LUA_TEST_OK")
    ' 2>&1 || true)"
    case "$lua_out" in
      *"LUA_TEST_OK"*) pass 'lua module unit test via nvim -l (pre/post-settle discriminator)' ;;
      *) printf 'FAIL  lua module unit test via nvim -l\n        out: %s\n' "$lua_out"; exit 1 ;;
    esac
  fi
else
  if [ -n "${OC_AA_REQUIRE_ALL_TOOLS:-}" ]; then
    printf 'FAIL  lua source check: %s missing but OC_AA_REQUIRE_ALL_TOOLS is set (check is mis-wired)\n' "$lua_source"
    exit 1
  fi
  printf 'SKIP  lua source check (oc_auto_attach.lua not found)\n'
  SKIP_COUNT=$((SKIP_COUNT + 1))
fi

# ---- coverage gate ----------------------------------------------------------
#
# Reaching this line proves the suite did not fail. It proves nothing about how
# much of it RAN -- which is the failure that made this file worth fixing: with
# jq/tmux/nvim absent it printed a triumphant final line having quietly dropped
# 20 of its 71 assertions. Pin the number.

if [ "$SKIP_COUNT" -gt 0 ]; then
  # Only reachable outside a Nix build (require_tool hard-fails inside one).
  # Not fatal -- a laptop without tmux may still run the rest -- but never
  # silent, and never dressed up as full coverage.
  printf 'INCOMPLETE (oc-auto-attach): %d/%d assertions ran, %d group(s) skipped for missing tools.\n' \
    "$ASSERT_COUNT" "$EXPECTED_ASSERTIONS" "$SKIP_COUNT"
  printf '  This is NOT full coverage. CI runs the complete suite via `nix flake check`.\n'
  exit 0
fi

if [ "$ASSERT_COUNT" -ne "$EXPECTED_ASSERTIONS" ]; then
  printf 'FAIL  assertion-count gate: ran %d assertions, expected %d.\n' \
    "$ASSERT_COUNT" "$EXPECTED_ASSERTIONS"
  printf '        Nothing was skipped, so coverage changed without EXPECTED_ASSERTIONS\n'
  printf '        being updated. If you added or removed assertions deliberately,\n'
  printf '        bump EXPECTED_ASSERTIONS in the same commit. If you did not, a\n'
  printf '        branch you did not expect is being taken.\n'
  exit 1
fi

printf 'ALL PASS (oc-auto-attach): %d assertions\n' "$ASSERT_COUNT"
