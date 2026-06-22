#!/usr/bin/env bash
# Unit tests for the lgtm-gh wrapper. Mirrors the resolution logic from
# default.nix and exercises it directly against fixtures (with a fake `gh` on
# PATH so no real GitHub call happens), plus a source-grep guard so the mirror
# can't silently diverge from production.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# Resolve this script's directory up front, before any `cd`, so the
# production-source grep guard below can find default.nix next to it.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- logic under test (mirror of default.nix) -------------------------------
#
# lgtm-gh reads $PWD/.lgtm-reviewer (a single GitHub login), resolves that
# login's PAT at $HOME/.config/lgtm/tokens/<login>.pat, and execs `gh` with
# GH_TOKEN set to the PAT so the dispatched session acts as that identity.
# This mirror returns (instead of exec/exit) so the harness can keep running;
# the source-grep guard at the bottom asserts production uses exec/exit.
lgtm_gh() {
  local login_file token_file login
  login_file="$PWD/.lgtm-reviewer"
  [ -r "$login_file" ] || { echo "lgtm-gh: missing $login_file" >&2; return 1; }
  login=$(tr -d '[:space:]' < "$login_file")
  [ -n "$login" ] || { echo "lgtm-gh: empty $login_file" >&2; return 1; }
  token_file="$HOME/.config/lgtm/tokens/$login.pat"
  [ -r "$token_file" ] || { echo "lgtm-gh: missing $token_file for login=$login" >&2; return 1; }
  env GH_TOKEN="$(cat "$token_file")" gh "$@"
}

# ---- test infrastructure ----------------------------------------------------

pass=0
fail=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$msg"; pass=$((pass + 1))
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$msg" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    printf 'PASS  %s\n' "$msg"; pass=$((pass + 1))
  else
    printf 'FAIL  %s\n        wanted substring: %s\n        in:               %s\n' "$msg" "$needle" "$haystack"
    fail=$((fail + 1))
  fi
}

# Sandbox: fake HOME (token store) + fake gh on PATH + a worktree to cd into.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

export HOME="$sandbox/home"
mkdir -p "$HOME/.config/lgtm/tokens"

# Fake gh records the GH_TOKEN it saw and its argv, so we can assert the
# wrapper threaded the right identity + passed args through verbatim.
fakebin="$sandbox/bin"
mkdir -p "$fakebin"
gh_record="$sandbox/gh-record"
cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
{ echo "GH_TOKEN=\$GH_TOKEN"; echo "ARGS=\$*"; } > "$gh_record"
EOF
chmod +x "$fakebin/gh"
export PATH="$fakebin:$PATH"

worktree="$sandbox/worktree"
mkdir -p "$worktree"
cd "$worktree"

# ---- behavioral tests -------------------------------------------------------

# 1. Missing .lgtm-reviewer -> hard error to stderr, nonzero exit.
rm -f "$worktree/.lgtm-reviewer"
err="$(lgtm_gh pr view 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "missing .lgtm-reviewer -> nonzero exit"
assert_contains "$err" "missing" "missing .lgtm-reviewer -> 'missing' on stderr"

# 2. Empty .lgtm-reviewer -> hard error.
: > "$worktree/.lgtm-reviewer"
err="$(lgtm_gh pr view 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "empty .lgtm-reviewer -> nonzero exit"
assert_contains "$err" "empty" "empty .lgtm-reviewer -> 'empty' on stderr"

# 3. Login present but token file missing -> hard error naming the token path.
echo "Krosantos" > "$worktree/.lgtm-reviewer"
rm -f "$HOME/.config/lgtm/tokens/Krosantos.pat"
err="$(lgtm_gh pr view 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "missing token file -> nonzero exit"
assert_contains "$err" "Krosantos.pat" "missing token file -> names the token path"

# 4. Happy path: gh is exec'd with GH_TOKEN=<pat> and args passed through.
printf 'ghp_krosantostoken\n' > "$HOME/.config/lgtm/tokens/Krosantos.pat"
chmod 600 "$HOME/.config/lgtm/tokens/Krosantos.pat"
rm -f "$gh_record"
lgtm_gh pr review --approve 123
assert_eq "GH_TOKEN=ghp_krosantostoken" "$(sed -n 1p "$gh_record")" \
  "happy path -> gh sees the resolved PAT as GH_TOKEN"
assert_eq "ARGS=pr review --approve 123" "$(sed -n 2p "$gh_record")" \
  "happy path -> gh receives args verbatim"

# 5. Whitespace/newline around the login is stripped before lookup.
printf '  jamesvec\n' > "$worktree/.lgtm-reviewer"
printf 'ghp_jamestoken' > "$HOME/.config/lgtm/tokens/jamesvec.pat"
rm -f "$gh_record"
lgtm_gh api user
assert_eq "GH_TOKEN=ghp_jamestoken" "$(sed -n 1p "$gh_record")" \
  "login whitespace is stripped before token lookup"

# ---- production-source check (default.nix) ----------------------------------
#
# Grep default.nix directly so a source-level regression trips before deploy
# and the mirror above can't silently diverge from prod.
default_nix="$script_dir/default.nix"
if [ -f "$default_nix" ]; then
  grep_guard() {
    local pattern="$1" msg="$2"
    if grep -q "$pattern" "$default_nix"; then
      printf 'PASS  %s\n' "$msg"; pass=$((pass + 1))
    else
      printf 'FAIL  %s\n        pattern not found: %s\n        in: %s\n' "$msg" "$pattern" "$default_nix"
      fail=$((fail + 1))
    fi
  }
  grep_guard '\.lgtm-reviewer' "source reads .lgtm-reviewer"
  grep_guard '\.config/lgtm/tokens/' "source resolves token under ~/.config/lgtm/tokens"
  grep_guard 'GH_TOKEN=' "source sets GH_TOKEN for gh"
  grep_guard 'exec env GH_TOKEN' "source execs gh (replaces the wrapper process)"
  grep_guard 'tr -d' "source strips whitespace from the login"
  grep_guard 'exit 1' "source hard-errors (exit 1) on misconfiguration"
else
  printf 'FAIL  production-source check: default.nix not found next to test (%s)\n' "$default_nix"
  fail=$((fail + 1))
fi

# ---- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh tests passed"
