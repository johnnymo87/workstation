#!/usr/bin/env bash
# Behavioural tests against the REAL shipped lgtm-gh binary.
#
# The sibling test.sh drives a COPY of the resolution logic, which flake.nix
# is careful to say is not production coverage: writeShellApplication prepends
# its runtimeInputs to PATH, so a fake `gh` on PATH loses to the pinned real
# one and the shipped wrapper cannot be intercepted from outside.
#
# This suite closes that gap for the artifact-ledger behaviour by building the
# wrapper with `pkgs.gh` OVERRIDDEN by a stub, so the binary under test is the
# one that ships, byte for byte, and the only substituted thing is the CLI it
# wraps. Every assertion here therefore exercises production.
#
# Usage: test-real.sh /nix/store/...-lgtm-gh/bin/lgtm-gh
set -o errexit -o nounset -o pipefail

wrapper="${1:?usage: test-real.sh <path-to-lgtm-gh>}"

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

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

export HOME="$sandbox/home"
mkdir -p "$HOME/.config/lgtm/tokens"
printf 'ghp_krosantostoken\n' > "$HOME/.config/lgtm/tokens/Krosantos.pat"
chmod 600 "$HOME/.config/lgtm/tokens/Krosantos.pat"

worktree="$sandbox/worktree"
mkdir -p "$worktree"
cd "$worktree"
printf 'Krosantos\n' > "$worktree/.lgtm-reviewer"

ledger="$HOME/.local/state/lgtm/review-artifacts.jsonl"
export GH_RECORD="$sandbox/gh-record"

ledger_lines() { [ -f "$ledger" ] && wc -l < "$ledger" || echo 0; }

# 1. Identity still resolves and args still pass through verbatim, on the
#    ordinary (exec) path. If the ledger work broke this, nothing else matters.
rm -f "$GH_RECORD"
"$wrapper" pr review --approve 123 >/dev/null
assert_eq "GH_TOKEN=ghp_krosantostoken" "$(sed -n 1p "$GH_RECORD")" \
  "real binary: non-review call threads the resolved PAT"
assert_eq "ARGS=pr review --approve 123" "$(sed -n 2p "$GH_RECORD")" \
  "real binary: non-review call passes args verbatim"
assert_eq "0" "$(ledger_lines)" "real binary: non-review call records nothing"

# 2. A review POST records id, kind and acting login.
rm -f "$ledger"
FAKE_GH_BODY='{"id":998877,"state":"COMMENTED"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "1" "$(ledger_lines)" "real binary: review POST writes exactly one line"
assert_eq "998877" "$(jq -r .id < "$ledger")" "real binary: records the artifact id"
assert_eq "review" "$(jq -r .kind < "$ledger")" "real binary: kind=review"
assert_eq "Krosantos" "$(jq -r .login < "$ledger")" "real binary: records acting login"

# 3. stdout replayed byte-for-byte. The agent parses this response; a wrapper
#    that mangles it breaks review posting itself.
out="$(FAKE_GH_BODY='{"id":11,"body":"hi"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT)"
assert_eq '{"id":11,"body":"hi"}' "$out" "real binary: stdout passed through verbatim"

# 4. Failure preserves gh's exit code and records nothing. An artifact that was
#    never created must not be claimed; every id it could match is someone else's.
rm -f "$ledger"
FAKE_GH_RC=22 FAKE_GH_BODY='{"message":"Validation Failed"}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null && rc=0 || rc=$?
assert_eq "22" "$rc" "real binary: failed POST preserves gh exit code"
assert_eq "0" "$(ledger_lines)" "real binary: failed POST records nothing"

# 5. Unparseable response never fails the call, and stays unrecorded -- which
#    downstream reads as a human. Failing toward human is the design rule.
rm -f "$ledger"
err="$(FAKE_GH_BODY='not json at all' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "0" "$rc" "real binary: unparseable response still succeeds"
assert_contains "$err" "reads as human" "real binary: warns and names the safe direction"
assert_eq "0" "$(ledger_lines)" "real binary: unparseable response records nothing"

# 6. A GET against a review endpoint is a read, not an artifact.
rm -f "$ledger"
FAKE_GH_BODY='{"id":555}' "$wrapper" api repos/food-truck/mono/pulls/42/reviews >/dev/null
assert_eq "0" "$(ledger_lines)" "real binary: GET on review endpoint records nothing"

# 7. `gh api` implies POST once a field is present. The prompt tells agents to
#    reply to threads in exactly that form, so an -X-only test would miss them.
rm -f "$ledger"
FAKE_GH_BODY='{"id":4242}' \
  "$wrapper" api repos/food-truck/mono/pulls/comments/77/replies -f body=ack >/dev/null
assert_eq "4242" "$(jq -r .id < "$ledger")" "real binary: implicit POST (-f, no -X) recorded"
assert_eq "reply" "$(jq -r .kind < "$ledger")" "real binary: replies endpoint -> kind=reply"

# 8. Misconfiguration still hard-errors before any gh call.
rm -f "$worktree/.lgtm-reviewer"
err="$("$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "1" "$rc" "real binary: missing .lgtm-reviewer still exits 1"
assert_contains "$err" "missing" "real binary: missing .lgtm-reviewer names the problem"

# ---- merge policy -----------------------------------------------------------
#
# lgtm has two lanes. The REVIEW lane can no longer merge anything (lgtm#110
# deleted its merge instruction). The ASSIST lane still merges, deliberately,
# but ONLY in blueapron/culinary-operations-server and
# blueapron/internal-frontends -- 15 merges on record, all COPS gem bumps.
# Dependency bumps anywhere else (food-truck/mono especially) belong to the
# goose lane, a different system.
#
# Until now that was a property of PROMPT TEXT: this wrapper forwarded
# `pr merge` unchanged, so a PR comment that talked a session into merging
# succeeded. These assertions pin the repo-scoped refusal, on the SHIPPED
# binary. The assist lane is the one caller that must keep working, so the
# allow cases matter as much as the deny ones.

printf 'Krosantos\n' > "$worktree/.lgtm-reviewer"
denials="$HOME/.local/state/lgtm/merge-denials.jsonl"

# Did gh run at all? A refusal must never reach it.
gh_ran() { [ -f "$GH_RECORD" ] && echo yes || echo no; }

assert_allowed() {
  local msg="$1"; shift
  rm -f "$GH_RECORD"
  "$@" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "0" "$rc" "ALLOW $msg -> exit 0"
  assert_eq "yes" "$(gh_ran)" "ALLOW $msg -> gh was invoked"
}

assert_refused() {
  local msg="$1"; shift
  rm -f "$GH_RECORD"
  err="$("$@" 2>&1 1>/dev/null)" && rc=0 || rc=$?
  assert_eq "3" "$rc" "DENY $msg -> exit 3"
  assert_eq "no" "$(gh_ran)" "DENY $msg -> gh was never invoked"
  assert_contains "$err" "lgtm-gh: refusing" "DENY $msg -> says it is refusing"
}

# --- pr merge, the assist lane's own call form -------------------------------
assert_allowed "assist form in culinary-operations-server" \
  "$wrapper" pr merge 123 --repo blueapron/culinary-operations-server --auto --squash
assert_allowed "assist form in internal-frontends" \
  "$wrapper" pr merge 123 --repo blueapron/internal-frontends --auto --squash
assert_eq "ARGS=pr merge 123 --repo blueapron/internal-frontends --auto --squash" \
  "$(sed -n 2p "$GH_RECORD")" "ALLOW passes merge args through verbatim"

assert_refused "mono" \
  "$wrapper" pr merge 4559 --repo food-truck/mono --auto --squash
assert_refused "bare number, no --repo (unresolvable)" \
  "$wrapper" pr merge 4559 --auto --squash

# The wrong-direction bug this design was rebuilt around: in gh, a PR URL
# selector WINS over --repo (finder.go:117-122), so trusting --repo would have
# resolved to an allowlisted repo while gh merged mono. Disagreeing hints are
# refused rather than ranked.
assert_refused "PR URL says mono, --repo says an allowlisted repo" \
  "$wrapper" pr merge https://github.com/food-truck/mono/pull/5 \
  --repo blueapron/internal-frontends --auto
# pflag is last-wins on a repeated flag, so "take the first" is wrong the same way.
assert_refused "repeated --repo, allowlisted then not" \
  "$wrapper" pr merge 5 --repo blueapron/internal-frontends --repo food-truck/mono
assert_allowed "PR URL alone, allowlisted" \
  "$wrapper" pr merge https://github.com/blueapron/internal-frontends/pull/5 --squash

# --disable-auto CANCELS an auto-merge; refusing a de-escalation would be
# perverse. gh short-circuits it before merging (merge.go:548) and forbids it
# alongside --auto/--admin (merge.go:129-133), so it cannot smuggle a merge.
assert_allowed "--disable-auto, even in mono" \
  "$wrapper" pr merge 5 --repo food-truck/mono --disable-auto

# --- gh api: the REST merge endpoints ----------------------------------------
assert_refused "REST merge, -X PUT" \
  "$wrapper" api -X PUT repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, attached -XPUT" \
  "$wrapper" api -XPUT repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, --method=put (lowercase, = form)" \
  "$wrapper" api --method=put repos/food-truck/mono/pulls/5/merge
assert_refused "REST merge, query string on the path" \
  "$wrapper" api -X PUT "repos/food-truck/mono/pulls/5/merge?foo=1"
assert_refused "REST merge, --input makes it a POST with no -f" \
  "$wrapper" api repos/food-truck/mono/pulls/5/merge --input /dev/null
# The numeric-id route works (repositories/<id>/...) and carries no repo slug,
# so it is unresolvable -- which is exactly why unresolvable must refuse.
assert_refused "REST merge via repositories/<id>/ (no slug to resolve)" \
  "$wrapper" api -X PUT repositories/12345/pulls/5/merge
assert_refused "branch merge endpoint" \
  "$wrapper" api repos/food-truck/mono/merges -f base=main -f head=topic
assert_allowed "REST merge in an allowlisted repo" \
  "$wrapper" api -X PUT repos/blueapron/culinary-operations-server/pulls/5/merge
# GET /pulls/N/merge is the legitimate "has it merged?" read.
assert_allowed "GET on the merge endpoint is a read" \
  "$wrapper" api repos/food-truck/mono/pulls/5/merge

# --- gh api graphql ----------------------------------------------------------
# The mutation carries a node ID, not a repo slug, so it can never be scoped.
assert_refused "graphql enablePullRequestAutoMerge" \
  "$wrapper" api graphql -f 'query=mutation{enablePullRequestAutoMerge(input:{pullRequestId:"X"}){clientMutationId}}'
assert_refused "graphql mergePullRequest" \
  "$wrapper" api graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){clientMutationId}}'
assert_refused "graphql enqueuePullRequest (merge queue)" \
  "$wrapper" api graphql -f 'query=mutation{enqueuePullRequest(input:{pullRequestId:"X"}){clientMutationId}}'
# A query read out of a file cannot be inspected, so it cannot be cleared.
assert_refused "graphql query from a file (-F query=@...)" \
  "$wrapper" api graphql -F query=@/dev/null
assert_refused "graphql query from --input" \
  "$wrapper" api graphql --input /dev/null
assert_allowed "graphql read" \
  "$wrapper" api graphql -f 'query=query{viewer{login}}'

# --- subcommands that would hide a merge from the parser ---------------------
assert_refused "alias (could alias away pr merge)" \
  "$wrapper" alias set m "pr merge"
assert_refused "extension (arbitrary code with the PAT)" \
  "$wrapper" extension install someone/gh-merge

# A pre-existing alias cannot be parsed at all, so the wrapper pins gh at its
# own config dir rather than the user's.
rm -f "$GH_RECORD"
"$wrapper" pr view 123 >/dev/null
assert_contains "$(sed -n 3p "$GH_RECORD")" "/.local/state/lgtm/gh-config" \
  "real binary: gh runs against the wrapper's own GH_CONFIG_DIR"

# --- shapes gh accepts that a naive scan does not (all confirmed against the
# --- real gh 2.83.2 by review, each one a merge in mono that the wrapper
# --- would otherwise have resolved to an allowlisted repo) -------------------

# gh's ParseURL takes any http(s) URL and then normalises the host: lowercase,
# `www.` stripped, port dropped (finder.go:306-333, repo.go:74-76). And the URL
# selector BEATS --repo. So only a bare number or the exact canonical URL is
# understood; everything else is unparseable and refuses.
assert_refused "www. host in the PR URL" \
  "$wrapper" pr merge https://www.github.com/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "uppercase scheme in the PR URL" \
  "$wrapper" pr merge HTTPS://github.com/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "mixed-case host in the PR URL" \
  "$wrapper" pr merge https://GitHub.COM/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
assert_refused "port in the PR URL" \
  "$wrapper" pr merge https://github.com:443/food-truck/mono/pull/5 --repo blueapron/internal-frontends --auto
# gh also accepts a BRANCH as the selector; this scan does not model that.
assert_refused "branch name as the selector" \
  "$wrapper" pr merge some-branch --repo blueapron/internal-frontends --auto

# A short CLUSTER hides a flag inside an argument this scan cannot decompose:
# `-sR X` is `--squash --repo X`, and pflag is last-wins.
assert_refused "short cluster smuggling a second --repo" \
  "$wrapper" pr merge 5 --repo blueapron/internal-frontends -sR food-truck/mono

# `gh api`'s path is not reliably the first positional -- any value-taking flag
# before it shifts what lands there. Classification is by SHAPE, not position.
assert_refused "merge path behind -H (the form in every REST doc example)" \
  "$wrapper" api -X PUT -H "Accept: application/vnd.github+json" repos/food-truck/mono/pulls/5/merge
assert_refused "merge path with -iXPUT (cluster carrying the method)" \
  "$wrapper" api -iXPUT repos/food-truck/mono/pulls/5/merge
assert_refused "merge path with -iX PUT" \
  "$wrapper" api -iX PUT repos/food-truck/mono/pulls/5/merge
assert_allowed "an allowlisted merge still works behind -H" \
  "$wrapper" api -X PUT -H "Accept: application/vnd.github+json" \
  repos/blueapron/culinary-operations-server/pulls/5/merge

# `gh api /graphql` and `gh api -H ... graphql` reach the same endpoint while
# putting something other than the path first, so the mutation names are
# matched against the query text regardless of the path argument.
assert_refused "graphql via a leading-slash path" \
  "$wrapper" api /graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql with a header before the path" \
  "$wrapper" api -H "X: y" graphql -f 'query=mutation{mergePullRequest(input:{pullRequestId:"X"}){id}}'
assert_refused "graphql mergeBranch (the twin of the /merges endpoint)" \
  "$wrapper" api graphql -f 'query=mutation{mergeBranch(input:{repositoryId:"X"}){id}}'

# The repo of a merge comes from the MERGE PATH only. Otherwise a --template or
# --jq value carrying an allowlisted slug would clear a merge aimed elsewhere.
assert_refused "allowlisted slug in a -t value, merge aimed at a numeric-id route" \
  "$wrapper" api -X PUT -t repos/blueapron/internal-frontends/x repositories/12345/pulls/5/merge

# gh extensions live under XDG_DATA_HOME, NOT GH_CONFIG_DIR (go-gh DataDir
# ignores it), and `lgtm-gh <ext>` parses as no subcommand this file knows.
rm -f "$GH_RECORD"
"$wrapper" pr view 123 >/dev/null
assert_contains "$(sed -n 4p "$GH_RECORD")" "/.local/state/lgtm/gh-data" \
  "gh runs against the wrapper's own XDG_DATA_HOME"

# The ledger's endpoint match is position-independent for the same reason the
# merge one is. Missing here is the SAFE direction (unrecorded reads as human),
# but a systematic miss on -H forms burns shepherd wakes.
rm -f "$ledger"
FAKE_GH_BODY='{"id":5150}' \
  "$wrapper" api -X POST -H "Accept: application/vnd.github+json" \
  repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "5150" "$(jq -r .id < "$ledger")" "review POST behind -H is still recorded"

# A refusal must say WHY in the caller's own terms. "cannot determine the
# target repository -- pass --repo" is wrong advice when --repo was already
# passed, and wrong advice at a refusal is the moment a session starts looking
# for another route.
err="$("$wrapper" pr merge some-branch --repo blueapron/internal-frontends 2>&1 1>/dev/null)" || true
assert_contains "$err" "the PR selector is neither a bare number" \
  "refusal names the actual reason, not a generic one"
err="$("$wrapper" api graphql --input /dev/null 2>&1 1>/dev/null)" || true
assert_contains "$err" "not inline" "opaque graphql refusal names the actual reason"

# --- the tripwire ------------------------------------------------------------
rm -f "$denials"
"$wrapper" pr merge 4559 --repo food-truck/mono --auto --squash >/dev/null 2>&1 || true
assert_eq "1" "$([ -f "$denials" ] && wc -l < "$denials" || echo 0)" \
  "real binary: a refusal is recorded once"
assert_eq "food-truck/mono" "$(jq -r .repo < "$denials")" "real binary: denial records the repo"
assert_eq "Krosantos" "$(jq -r .login < "$denials")" "real binary: denial records the acting login"

# --- the ledger path still works after the parser rewrite --------------------
rm -f "$ledger"
FAKE_GH_BODY='{"id":31337}' \
  "$wrapper" api -X POST repos/food-truck/mono/pulls/42/reviews -f event=COMMENT >/dev/null
assert_eq "31337" "$(jq -r .id < "$ledger")" "real binary: review POST still recorded after rewrite"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "all lgtm-gh real-binary tests passed"
