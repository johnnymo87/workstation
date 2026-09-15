#!/usr/bin/env bash
# Unit tests for the lgtm-gh wrapper. Runs the REAL wrapper body
# (lgtm-gh.sh, which default.nix reads verbatim) against fixtures, with a fake
# `gh` on PATH so no real GitHub call happens.
# Run: bash test.sh

set -o errexit -o nounset -o pipefail

# Resolve this script's directory up front, before any `cd`, so the script
# under test and the packaging guard below can be found next to it.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- logic under test (THE REAL SOURCE) -------------------------------------
#
# lgtm-gh reads $PWD/.lgtm-reviewer (a single GitHub login), resolves that
# login's PAT at $HOME/.config/lgtm/tokens/<login>.pat, and execs `gh` with
# GH_TOKEN set to the PAT so the dispatched session acts as that identity.
#
# This used to be a hand-copied MIRROR of the logic in default.nix, which the
# file itself had to label "a design record, not evidence". The body now lives
# in lgtm-gh.sh and default.nix reads it verbatim, so these assertions run
# PRODUCTION SOURCE -- a subprocess, so its exec/exit are fine, with the fake
# `gh` below winning on PATH because nothing has prepended a pinned one.
lgtm_gh() {
  bash "$script_dir/lgtm-gh.sh" "$@"
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
  if grep -qF "$needle" <<<"$haystack"; then
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
{ echo "GH_TOKEN=\$GH_TOKEN"; echo "ARGS=\$*"; echo "GH_CONFIG_DIR=\${GH_CONFIG_DIR:-}"; echo "XDG_DATA_HOME=\${XDG_DATA_HOME:-}"; } > "$gh_record"
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


# ---- merge policy -----------------------------------------------------------
#
# lgtm has two lanes. The REVIEW lane can no longer merge anything (lgtm#110
# deleted its merge instruction). The ASSIST lane still merges, deliberately,
# but ONLY in blueapron/culinary-operations-server and
# blueapron/internal-frontends -- 15 merges on record, all COPS gem bumps.
# Dependency bumps anywhere else (food-truck/mono above all) belong to the
# goose lane, a different system.
#
# Before this, that was a property of PROMPT TEXT: the wrapper forwarded
# `pr merge` unchanged, so a PR comment that talked a session into merging
# simply worked. The assist lane is the one caller that MUST keep working, so
# the allow cases below matter as much as the deny ones.

printf 'Krosantos\n' > "$worktree/.lgtm-reviewer"
denials="$HOME/.local/state/lgtm/merge-denials.jsonl"

gh_ran() { [ -f "$gh_record" ] && echo yes || echo no; }

assert_allowed() {
  local msg="$1"; shift
  rm -f "$gh_record"
  lgtm_gh "$@" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "0" "$rc" "ALLOW $msg -> exit 0"
  assert_eq "yes" "$(gh_ran)" "ALLOW $msg -> gh was invoked"
}

assert_refused() {
  local msg="$1"; shift
  rm -f "$gh_record"
  err="$(lgtm_gh "$@" 2>&1 1>/dev/null)" && rc=0 || rc=$?
  assert_eq "3" "$rc" "DENY $msg -> exit 3"
  assert_eq "no" "$(gh_ran)" "DENY $msg -> gh was never invoked"
  assert_contains "$err" "lgtm-gh: refusing" "DENY $msg -> says it is refusing"
}

# --- pr merge: the assist lane's own call form (prompt.ts:260) ---------------
assert_allowed "assist form, culinary-operations-server" \
  pr merge 123 --repo blueapron/culinary-operations-server --auto --squash
assert_allowed "assist form, internal-frontends" \
  pr merge 123 --repo blueapron/internal-frontends --auto --squash
assert_eq "ARGS=pr merge 123 --repo blueapron/internal-frontends --auto --squash" \
  "$(sed -n 2p "$gh_record")" "ALLOW passes merge args through verbatim"

assert_refused "mono" pr merge 4559 --repo food-truck/mono --auto --squash
assert_refused "bare number, no --repo" pr merge 4559 --auto --squash

# In gh a PR-URL selector WINS over --repo (finder.go:117-122), so trusting
# --repo would resolve to an allowlisted repo while gh merged mono. And pflag
# is last-wins on a repeated flag. Disagreement is refused, not ranked.
assert_refused "PR URL says mono, --repo says allowlisted" \
  pr merge https://github.com/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "repeated --repo, allowlisted then not" \
  pr merge 5 --repo blueapron/internal-frontends --repo food-truck/mono
assert_allowed "PR URL alone, allowlisted" \
  pr merge https://github.com/blueapron/internal-frontends/pull/5 --squash

# --disable-auto CANCELS an auto-merge; refusing a de-escalation would be
# perverse, and gh forbids it alongside --auto/--admin (merge.go:129-133).
assert_allowed "--disable-auto, even in mono" \
  pr merge 5 --repo food-truck/mono --disable-auto

# --- gh api: REST merge endpoints -------------------------------------------
assert_refused "REST merge, -X PUT" api -X PUT repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, attached -XPUT" api -XPUT repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, --method=put" api --method=put repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, query string on path" \
  api -X PUT "repos/food-truck/mono/pulls/5/merge?foo=1"
assert_refused "REST merge, --input (a POST with no -f)" \
  api repos/food-truck/mono/pulls/5/merge --input /dev/null
# The numeric-id route is real and carries no slug -- which is exactly why
# "cannot resolve" has to refuse rather than fall through.
assert_refused "REST merge via repositories/<id>/" api -X PUT repositories/12345/pulls/5/merge
assert_refused "branch-merge endpoint" api repos/food-truck/mono/merges -f base=main -f head=topic
assert_allowed "REST merge in an allowlisted repo" \
  api -X PUT repos/blueapron/culinary-operations-server/pulls/5/merge
assert_allowed "GET on the merge endpoint is a read" \
  api repos/food-truck/mono/pulls/5/merge

# --- gh api graphql ----------------------------------------------------------
# These mutations carry a pull-request NODE ID, never a repo slug, so they can
# never be scoped -- refused outright. lgtm's prompts contain no graphql.
assert_refused "graphql enablePullRequestAutoMerge" \
  api graphql -f 'query=mutation{enablePullRequestAutoMerge(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql mergePullRequest" \
  api graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql enqueuePullRequest" \
  api graphql -f 'query=mutation{enqueuePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql query read from a file" api graphql -F query=@/dev/null
assert_refused "graphql query read from --input" api graphql --input /dev/null
assert_allowed "graphql read" api graphql -f 'query=query{viewer{login}}'

# --- subcommands that would hide a merge from the parser ---------------------
assert_refused "alias" alias set m "pr merge"
assert_refused "extension" extension install someone/gh-merge

# An alias that ALREADY exists expands inside gh, after this parser has run, so
# gh is pinned at a config dir the wrapper owns rather than the user's.
rm -f "$gh_record"
lgtm_gh pr view 123 >/dev/null
assert_contains "$(sed -n 3p "$gh_record")" "/.local/state/lgtm/gh-config" \
  "gh runs against the wrapper's own GH_CONFIG_DIR"

# --- shapes gh accepts that a naive scan does not (all confirmed against the
# --- real gh 2.83.2 by review, each one a merge in mono that the wrapper
# --- would otherwise have resolved to an allowlisted repo) -------------------

# gh's ParseURL takes any http(s) URL and then normalises the host: lowercase,
# `www.` stripped, port dropped (finder.go:306-333, repo.go:74-76). And the URL
# selector BEATS --repo. So only a bare number or the exact canonical URL is
# understood; everything else is unparseable and refuses.
assert_refused "www. host in the PR URL" \
  pr merge https://www.github.com/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "uppercase scheme in the PR URL" \
  pr merge HTTPS://github.com/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "mixed-case host in the PR URL" \
  pr merge https://GitHub.COM/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "port in the PR URL" \
  pr merge https://github.com:443/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
# gh also accepts a BRANCH as the selector; this scan does not model that.
assert_refused "branch name as the selector" \
  pr merge some-branch --repo blueapron/internal-frontends --auto

# A short CLUSTER hides a flag inside an argument this scan cannot decompose:
# `-sR X` is `--squash --repo X`, and pflag is last-wins.
assert_refused "short cluster smuggling a second --repo" \
  pr merge 5 --repo blueapron/internal-frontends -sR food-truck/mono

# `gh api`'s path is not reliably the first positional -- any value-taking flag
# before it shifts what lands there. Classification is by SHAPE, not position.
assert_refused "merge path behind -H (the form in every REST doc example)" \
  api -X PUT -H "Accept: application/vnd.github+json" repos/food-truck/mono/pulls/5/merge
assert_refused "merge path with -iXPUT (cluster carrying the method)" \
  api -iXPUT repos/food-truck/mono/pulls/5/merge
assert_refused "merge path with -iX PUT" \
  api -iX PUT repos/food-truck/mono/pulls/5/merge
assert_allowed "an allowlisted merge still works behind -H" \
  api -X PUT -H "Accept: application/vnd.github+json" \
  repos/blueapron/culinary-operations-server/pulls/5/merge

# `gh api /graphql` and `gh api -H ... graphql` reach the same endpoint while
# putting something other than the path first, so the mutation names are
# matched against the query text regardless of the path argument.
assert_refused "graphql via a leading-slash path" \
  api /graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql with a header before the path" \
  api -H "X: y" graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql mergeBranch (the twin of the /merges endpoint)" \
  api graphql -f 'query=mutation{mergeBranch(input:{repositoryId:"X"}){id}}'

# The repo of a merge comes from the MERGE PATH only. Otherwise a --template or
# --jq value carrying an allowlisted slug would clear a merge aimed elsewhere.
assert_refused "allowlisted slug in a -t value, merge aimed at a numeric-id route" \
  api -X PUT -t repos/blueapron/internal-frontends/x repositories/12345/pulls/5/merge

# gh extensions live under XDG_DATA_HOME, NOT GH_CONFIG_DIR (go-gh DataDir
# ignores it), and `lgtm-gh <ext>` parses as no subcommand this file knows.
rm -f "$gh_record"
lgtm_gh pr view 123 >/dev/null
assert_contains "$(sed -n 4p "$gh_record")" "/.local/state/lgtm/gh-data" \
  "gh runs against the wrapper's own XDG_DATA_HOME"

# The ledger's endpoint match is position-independent for the same reason the
# merge one is. Missing here is the SAFE direction (unrecorded reads as human),
# but a systematic miss on -H forms burns shepherd wakes.
rm -f "$ledger"
FAKE_GH_BODY='{"id":5150}' \
  lgtm_gh api -X POST -H "Accept: application/vnd.github+json" \
  repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "5150" "$(jq -r .id < "$ledger")" "review POST behind -H is still recorded"

# A refusal must say WHY in the caller's own terms. "cannot determine the
# target repository -- pass --repo" is wrong advice when --repo was already
# passed, and wrong advice at a refusal is the moment a session starts looking
# for another route.
err="$(lgtm_gh pr merge some-branch --repo blueapron/internal-frontends 2>&1 1>/dev/null)" || true
assert_contains "$err" "the PR selector is neither a bare number" \
  "refusal names the actual reason, not a generic one"
err="$(lgtm_gh api graphql --input /dev/null 2>&1 1>/dev/null)" || true
assert_contains "$err" "not inline" "opaque graphql refusal names the actual reason"

# --- the tripwire ------------------------------------------------------------
rm -f "$denials"
lgtm_gh pr merge 4559 --repo food-truck/mono --auto --squash >/dev/null 2>&1 || true
assert_eq "1" "$([ -f "$denials" ] && wc -l < "$denials" || echo 0)" \
  "a refusal is recorded once"
assert_eq "food-truck/mono" "$(jq -r .repo < "$denials")" "denial records the repo"
assert_eq "Krosantos" "$(jq -r .login < "$denials")" "denial records the acting login"

# ---- packaging check (default.nix) ------------------------------------------
#
# Everything above runs lgtm-gh.sh directly, which proves the LOGIC but not
# that the shipped derivation is built from that file. These greps pin the
# wiring, so a default.nix that quietly reverted to an inline copy (or dropped
# a runtime input the script needs) trips here rather than on cloudbox.
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
  grep_guard 'builtins\.readFile \./lgtm-gh\.sh' "derivation is built from lgtm-gh.sh, not an inline copy"
  grep_guard 'pkgs\.coreutils' "derivation pins coreutils (tr/cat/date/mktemp/mkdir)"
  grep_guard 'pkgs\.gh' "derivation pins the gh it wraps"
  grep_guard 'pkgs\.jq' "derivation pins jq (ledger + denial records)"

  body_sh="$script_dir/lgtm-gh.sh"
  if [ -f "$body_sh" ]; then
    default_nix="$body_sh"  # reuse grep_guard against the body
    grep_guard 'exec env GH_TOKEN' "body execs gh (replaces the wrapper process)"
    grep_guard 'reads as human' "body fails toward human on every record failure"
  else
    printf 'FAIL  packaging check: lgtm-gh.sh not found next to test (%s)\n' "$body_sh"
    fail=$((fail + 1))
  fi
else
  printf 'FAIL  production-source check: default.nix not found next to test (%s)\n' "$default_nix"
  fail=$((fail + 1))
fi

# ---- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh tests passed"
