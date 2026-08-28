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
  local login_file token_file login ledger_dir ledger_file tmp rc
  login_file="$PWD/.lgtm-reviewer"
  [ -r "$login_file" ] || { echo "lgtm-gh: missing $login_file" >&2; return 1; }
  login=$(tr -d '[:space:]' < "$login_file")
  [ -n "$login" ] || { echo "lgtm-gh: empty $login_file" >&2; return 1; }
  token_file="$HOME/.config/lgtm/tokens/$login.pat"
  [ -r "$token_file" ] || { echo "lgtm-gh: missing $token_file for login=$login" >&2; return 1; }

  ledger_dir="$HOME/.local/state/lgtm"
  ledger_file="$ledger_dir/review-artifacts.jsonl"

  matched_endpoint=""
  is_review_post() {
    local a endpoint="" posty=0 prev=""
    for a in "$@"; do
      case "$a" in
        -f|-F|--field|--raw-field) posty=1 ;;
        POST|post) if [ "$prev" = "-X" ] || [ "$prev" = "--method" ]; then posty=1; fi ;;
      esac
      case "$a" in
        */pulls/*/reviews|*/pulls/*/comments|*/pulls/comments/*/replies)
          endpoint="$a" ;;
      esac
      prev="$a"
    done
    if [ -n "$endpoint" ] && [ "$posty" -eq 1 ]; then
      matched_endpoint="$endpoint"
      return 0
    fi
    return 1
  }

  record_artifact() {
    local endpoint="$1" body_file="$2" id kind ts
    mkdir -p "$ledger_dir" 2>/dev/null || {
      echo "lgtm-gh: cannot create $ledger_dir; artifact unrecorded (reads as human)" >&2
      return 0
    }
    id="$(jq -r '.id? // empty' < "$body_file" 2>/dev/null || true)"
    case "$id" in
      ""|*[!0-9]*)
        echo "lgtm-gh: no numeric id in response; artifact unrecorded (reads as human)" >&2
        return 0 ;;
    esac
    case "$endpoint" in
      */reviews)  kind="review" ;;
      */replies)  kind="reply" ;;
      *)          kind="comment" ;;
    esac
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -cn \
      --arg ts "$ts" --arg login "$login" --arg endpoint "$endpoint" \
      --arg kind "$kind" --argjson id "$id" \
      '{ts:$ts, login:$login, endpoint:$endpoint, kind:$kind, id:$id}' \
      >> "$ledger_file" 2>/dev/null \
      || echo "lgtm-gh: ledger append failed; artifact unrecorded (reads as human)" >&2
    return 0
  }

  if ! is_review_post "$@"; then
    env GH_TOKEN="$(cat "$token_file")" gh "$@"
    return $?
  fi

  tmp="$(mktemp 2>/dev/null)" || { env GH_TOKEN="$(cat "$token_file")" gh "$@"; return $?; }
  rc=0
  set +o errexit
  env GH_TOKEN="$(cat "$token_file")" gh "$@" > "$tmp"
  rc=$?
  set -o errexit
  cat "$tmp"
  if [ "$rc" -eq 0 ]; then
    record_artifact "$matched_endpoint" "$tmp"
  fi
  rm -f "$tmp"
  return "$rc"
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
# The shebang is the RUNNING bash, not `/usr/bin/env bash`: a nix build sandbox
# has no /usr/bin/env (measured -- only /bin/sh exists), so the hardcoded form
# made every behavioural case here die with "env: 'gh': No such file or
# directory" once this suite was wired as a check. A shebang is an absolute
# path, so no amount of PATH in the check can fix it from outside.
cat > "$fakebin/gh" <<EOF
#!$BASH
{ echo "GH_TOKEN=\$GH_TOKEN"; echo "ARGS=\$*"; } > "$gh_record"
# FAKE_GH_BODY / FAKE_GH_RC let a test drive the response the wrapper parses.
if [ -n "\${FAKE_GH_BODY:-}" ]; then printf '%s' "\$FAKE_GH_BODY"; fi
exit "\${FAKE_GH_RC:-0}"
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

# ---- review-artifact ledger -------------------------------------------------
#
# lgtm reviews as a pool of REAL human logins, so its comments are
# indistinguishable from those humans' own. Identity and time cannot separate
# them (Krosantos and jamesvec review PRs themselves); the artifact id can,
# because every artifact lgtm creates is created through this wrapper.

ledger="$HOME/.local/state/lgtm/review-artifacts.jsonl"
printf 'Krosantos\n' > "$worktree/.lgtm-reviewer"
printf 'ghp_krosantostoken\n' > "$HOME/.config/lgtm/tokens/Krosantos.pat"

# 6. A review POST records the artifact id, kind, and login.
rm -f "$ledger"
FAKE_GH_BODY='{"id":998877,"state":"COMMENTED"}' \
  lgtm_gh api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "1" "$(wc -l < "$ledger")" "review POST -> exactly one ledger line"
assert_eq "998877" "$(jq -r .id < "$ledger")" "review POST -> records the artifact id"
assert_eq "review" "$(jq -r .kind < "$ledger")" "review POST -> kind=review"
assert_eq "Krosantos" "$(jq -r .login < "$ledger")" "review POST -> records the acting login"

# 7. stdout is replayed byte-for-byte (the agent must see gh's real response).
out="$(FAKE_GH_BODY='{"id":11,"body":"hi"}' \
  lgtm_gh api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT)"
assert_eq '{"id":11,"body":"hi"}' "$out" "capture path -> stdout passed through verbatim"

# 8. A FAILED call preserves gh's exit code and records NOTHING. Recording a
#    failed post would mark an artifact that does not exist, and every id it
#    could later match belongs to someone else.
rm -f "$ledger"
FAKE_GH_RC=22 FAKE_GH_BODY='{"message":"Validation Failed"}' \
  lgtm_gh api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null && rc=0 || rc=$?
assert_eq "22" "$rc" "failed review POST -> gh exit code preserved"
assert_eq "0" "$([ -f "$ledger" ] && wc -l < "$ledger" || echo 0)" \
  "failed review POST -> nothing recorded"

# 9. An unparseable response does NOT fail the call, and stays unrecorded --
#    which downstream reads as a human. Failing toward human is the whole
#    point: mistaking a person for a machine erases evidence of engagement.
rm -f "$ledger"
err="$(FAKE_GH_BODY='not json at all' \
  lgtm_gh api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "0" "$rc" "unparseable response -> call still succeeds"
assert_contains "$err" "reads as human" "unparseable response -> warns, naming the safe direction"
assert_eq "0" "$([ -f "$ledger" ] && wc -l < "$ledger" || echo 0)" \
  "unparseable response -> nothing recorded"

# 10. A GET against a review endpoint is a READ and must not be recorded.
rm -f "$ledger"
FAKE_GH_BODY='{"id":555}' lgtm_gh api repos/food-truck/mono/pulls/42/reviews >/dev/null
assert_eq "0" "$([ -f "$ledger" ] && wc -l < "$ledger" || echo 0)" \
  "GET on a review endpoint -> nothing recorded"

# 11. `gh api` implies POST as soon as a field is present, with no -X POST.
#     That is the form the prompt tells agents to use for thread replies, so
#     requiring an explicit -X POST would miss exactly those calls.
rm -f "$ledger"
FAKE_GH_BODY='{"id":4242}' \
  lgtm_gh api repos/food-truck/mono/pulls/comments/77/replies -f body=ack >/dev/null
assert_eq "4242" "$(jq -r .id < "$ledger")" "implicit POST (-f, no -X) -> recorded"
assert_eq "reply" "$(jq -r .kind < "$ledger")" "replies endpoint -> kind=reply"

# 12. An ordinary non-review call is untouched by any of this.
rm -f "$ledger"
lgtm_gh pr view 123 >/dev/null
assert_eq "0" "$([ -f "$ledger" ] && wc -l < "$ledger" || echo 0)" \
  "non-review call -> nothing recorded"

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
  grep_guard 'review-artifacts\.jsonl' "source records artifacts to the ledger"
  grep_guard 'reads as human' "source fails toward human on every record failure"
else
  printf 'FAIL  production-source check: default.nix not found next to test (%s)\n' "$default_nix"
  fail=$((fail + 1))
fi

# ---- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh tests passed"
