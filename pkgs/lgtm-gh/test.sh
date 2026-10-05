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
#
# ONE substitution, and it is bounded: the approval gate's pins and its lgtm
# invocation live between `# BEGIN GATE PINS` / `# END GATE PINS`, and the copy
# under test swaps ONLY that block for a sandbox one whose policy command
# prints a canned payload. Every other byte is the shipped source, and a guard
# at the bottom asserts the shipped block byte for byte (lgtm-f6ue).
lgtm_gh() {
  bash "$gate_src" "$@"
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
gh_log="$sandbox/gh-log"
cat > "$fakebin/gh" <<EOF
#!$BASH
printf '%s\n' "\$*" >> "$gh_log"
# The approval gate's live-head read: \`api repos/O/R/pulls/N --jq ...\`. It
# answers from FAKE_PR_LINE ("<sha> <full_name>") and does NOT touch the
# record, so gh_record always describes the LAST non-GET call.
if [ "\$1" = api ] && [[ "\$2" =~ ^repos/[^/]+/[^/]+/pulls/[0-9]+\$ ]] && [ "\${3:-}" = --jq ]; then
  if [ -n "\${FAKE_PR_LINE:-}" ]; then printf '%s\n' "\$FAKE_PR_LINE"; fi
  exit "\${FAKE_PR_RC:-0}"
fi
{ echo "GH_TOKEN=\$GH_TOKEN"; echo "ARGS=\$*"; echo "GH_CONFIG_DIR=\${GH_CONFIG_DIR:-}"; echo "XDG_DATA_HOME=\${XDG_DATA_HOME:-}"; } > "$gh_record"
# What gh would have SENT as the --input body, if any (the wrapper may hand gh
# a rewritten copy; the copy is deleted when the wrapper exits).
prev=""
for a in "\$@"; do
  case "\$prev" in --input) cat "\$a" > "$gh_record.input" ;; esac
  case "\$a" in --input=*) cat "\${a#--input=}" > "$gh_record.input" ;; esac
  prev="\$a"
done
# FAKE_GH_BODY / FAKE_GH_RC let a test drive the response the wrapper parses.
if [ -n "\${FAKE_GH_BODY:-}" ]; then printf '%s' "\$FAKE_GH_BODY"; fi
exit "\${FAKE_GH_RC:-0}"
EOF
chmod +x "$fakebin/gh"
export PATH="$fakebin:$PATH"

# ---- the copy under test: shipped source with a sandbox GATE PINS block ----
#
# The sandbox block keeps the SHIPPED pin values (they are only strings the
# payload is compared against) and replaces the one thing that cannot run here:
# the lgtm invocation. It prints FAKE_POLICY_OUT, exits FAKE_POLICY_RC, and logs
# its argv so a test can prove the gate asked about the right repo/PR/head.
policy_log="$sandbox/policy-log"
gate_src="$sandbox/lgtm-gh.sh"
sandbox_block="$sandbox/pins.sh"
cat > "$sandbox_block" <<EOF
# BEGIN GATE PINS
gate_lgtm_dir="/home/dev/projects/lgtm"
gate_lgtm_config="/home/dev/projects/lgtm/lgtm.yml"
gate_lgtm_state_dir="/home/dev/.local/state/lgtm"
gate_lgtm_tokens_dir="/home/dev/.config/lgtm/tokens"
gate_lgtm_projects_dir="/home/dev/projects"
gate_lgtm_home="/home/dev"
gate_governed_floor=("food-truck/mono")
run_approval_policy() {
  printf '%s\n' "\$*" >> "$policy_log"
  if [ -n "\${FAKE_POLICY_ERR:-}" ]; then printf '%s\n' "\$FAKE_POLICY_ERR" >&2; fi
  if [ -n "\${FAKE_POLICY_OUT:-}" ]; then printf '%s\n' "\$FAKE_POLICY_OUT"; fi
  return "\${FAKE_POLICY_RC:-0}"
}
# END GATE PINS
EOF
awk -v blk="$sandbox_block" '
  /^# BEGIN GATE PINS$/ { while ((getline l < blk) > 0) print l; skip=1; next }
  /^# END GATE PINS$/   { skip=0; next }
  !skip { print }
' "$script_dir/lgtm-gh.sh" > "$gate_src"

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
lgtm_gh pr view 123 --json state
assert_eq "GH_TOKEN=ghp_krosantostoken" "$(sed -n 1p "$gh_record")" \
  "happy path -> gh sees the resolved PAT as GH_TOKEN"
assert_eq "ARGS=pr view 123 --json state" "$(sed -n 2p "$gh_record")" \
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

# ---- approval gate (lgtm-f6ue) ----------------------------------------------
#
# On a governed repo an APPROVE goes through only when lgtm --approval-policy
# says `clear` for the PR's LIVE head, with every key and config pin matching.
# A POSITIVE ALLOWLIST: a review whose event is not provably COMMENT or
# REQUEST_CHANGES is gated, whatever spelling carried it. COMMENT and
# REQUEST_CHANGES are never touched. Refusals start with the marker the review
# prompt keys on, exit 3 (policy) or 5 (plumbing), and append one line to the
# ledger lgtm pages from.

H1="1111111111111111111111111111111111111111"
H2="2222222222222222222222222222222222222222"
refusals="$HOME/.local/state/lgtm/gate-refusals.jsonl"
drift="$HOME/.local/state/lgtm/gate-floor-drift.jsonl"
MARKER="lgtm-gh: refusing to approve"
CFG='{"path":"/home/dev/projects/lgtm/lgtm.yml","stateDir":"/home/dev/.local/state/lgtm","scopeSize":9,"governedRepos":["food-truck/mono"]}'
printf 'jamesvec\n' > "$worktree/.lgtm-reviewer"

# payload <jq-merge-expression>: a matching `clear` answer for mono#42@H1,
# with the expression applied on top.
payload() {
  jq -cn --argjson cfg "$CFG" --arg h "$H1" \
    "{repo:\"food-truck/mono\", prNumber:42, head:\$h, governed:true, verdict:\"clear\", reason:\"answered\", blockedOwners:[], ownerReviewers:[], warnings:0, config:\$cfg} | ${1:-.}"
}
POLICY_MSG='["lgtm-gh: refusing to approve food-truck/mono#42 at 111111111111: line one.","lgtm-gh: line two, verbatim."]'

reset_gate() {
  rm -f "$gh_record" "$gh_record.input" "$gh_log" "$policy_log" "$refusals" "$drift"
  unset FAKE_POLICY_OUT FAKE_POLICY_RC FAKE_PR_RC
  export FAKE_PR_LINE="$H1 food-truck/mono"
}
posted() { [ -f "$gh_record" ] && echo yes || echo no; }
policy_calls() { [ -f "$policy_log" ] && wc -l < "$policy_log" || echo 0; }
gets() { if [ -f "$gh_log" ]; then grep -c -- '--jq' "$gh_log" || true; else echo 0; fi; }
refusal_lines() { [ -f "$refusals" ] && wc -l < "$refusals" || echo 0; }
REVIEWS=repos/food-truck/mono/pulls/42/reviews

# run_gate <label> <expected-rc> -- <lgtm-gh args...>; leaves $err and $rc.
run_gate() {
  local label="$1" want="$2"; shift 3
  err="$(lgtm_gh "$@" 2>&1 1>/dev/null)" && rc=0 || rc=$?
  assert_eq "$want" "$rc" "GATE $label -> exit $want"
}

# --- never gated: COMMENT / REQUEST_CHANGES, reads, edits --------------------
reset_gate
run_gate "COMMENT on mono" 0 -- api -X POST $REVIEWS -f event=COMMENT -f body=x
assert_eq "0" "$(policy_calls)" "GATE COMMENT -> lgtm is not asked"
assert_eq "0" "$(gets)" "GATE COMMENT -> no live-head read"
assert_eq "ARGS=api -X POST $REVIEWS -f event=COMMENT -f body=x" "$(sed -n 2p "$gh_record")" \
  "GATE COMMENT -> argv untouched"

reset_gate
run_gate "COMMENT pinned to an OLD head (kxt6 fallback)" 0 -- \
  api -X POST $REVIEWS -f event=COMMENT -f commit_id=$H2 -f body=x
assert_eq "ARGS=api -X POST $REVIEWS -f event=COMMENT -f commit_id=$H2 -f body=x" "$(sed -n 2p "$gh_record")" \
  "GATE COMMENT keeps the session's commit_id (never force-pinned)"

reset_gate
run_gate "REQUEST_CHANGES with inline comments" 0 -- \
  api -X POST $REVIEWS -f event=REQUEST_CHANGES -F 'comments[][path]=a' -F 'comments[][line]=1'
assert_eq "0" "$(policy_calls)" "GATE REQUEST_CHANGES -> lgtm is not asked"

reset_gate
run_gate "pr review --comment" 0 -- pr review 42 --repo food-truck/mono --comment -b hi
run_gate "pr review -r" 0 -- pr review 42 --repo food-truck/mono -r -b hi
assert_eq "0" "$(policy_calls)" "GATE pr review comment/request-changes -> lgtm is not asked"

reset_gate
run_gate "-X GET read of reviews with a field" 0 -- api -X GET $REVIEWS -f per_page=100
assert_eq "0" "$(policy_calls)" "GATE a GET with -f is a read, not a submission"
run_gate "PUT reviews/ID (edit a body)" 0 -- api -X PUT $REVIEWS/77 -f body=edited
run_gate "dismissal" 0 -- api -X PUT $REVIEWS/77/dismissals -f message=m
run_gate "graphql review THREAD (a comment surface)" 0 -- \
  api graphql -f 'query=mutation{addPullRequestReviewThread(input:{}){thread{id}}}'
assert_eq "0" "$(policy_calls)" "GATE edits/dismissals/threads -> lgtm is not asked"

# --- governed + clear: allowed, PINNED to the live head ----------------------
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "APPROVE on mono, clear" 0 -- \
  api -X POST $REVIEWS -f event=APPROVE -f body=lgtm
assert_eq "food-truck/mono#42 $H1" "$(cat "$policy_log")" \
  "GATE asks lgtm about the LIVE head, canonical repo"
assert_eq "ARGS=api -X POST $REVIEWS -f event=APPROVE -f body=lgtm -f commit_id=$H1" "$(sed -n 2p "$gh_record")" \
  "GATE clear APPROVE is pinned with commit_id=<live head>"

reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "APPROVE already pinned to the live head" 0 -- \
  api -X POST $REVIEWS -f event=APPROVE -f commit_id=$H1
assert_eq "ARGS=api -X POST $REVIEWS -f event=APPROVE -f commit_id=$H1" "$(sed -n 2p "$gh_record")" \
  "GATE an existing matching commit_id is not duplicated"

reset_gate
export FAKE_PR_LINE="$H1 food-truck/mono"
FAKE_POLICY_OUT="$(payload)" run_gate "APPROVE spelled Food-Truck/MONO" 0 -- \
  api -X POST repos/Food-Truck/MONO/pulls/42/reviews -f event=APPROVE
assert_eq "food-truck/mono#42 $H1" "$(cat "$policy_log")" \
  "GATE canonicalises the repo from the PR GET before asking lgtm"

reset_gate
rm -f "$ledger"
FAKE_GH_BODY='{"id":31337}' FAKE_POLICY_OUT="$(payload)" run_gate "allowed APPROVE still ledgered" 0 -- \
  api -X POST $REVIEWS -f event=APPROVE
assert_eq "31337" "$(jq -r .id < "$ledger")" "GATE an allowed APPROVE still records its artifact id"

reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "absent event (PENDING) is gated" 0 -- \
  api -X POST $REVIEWS -f body=x
assert_eq "1" "$(policy_calls)" "GATE no event -> gated, lgtm asked"
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "lowercase event=comment is gated" 0 -- \
  api -X POST $REVIEWS -f event=comment
assert_eq "1" "$(policy_calls)" "GATE event=comment (not exactly COMMENT) -> gated"
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "COMMENT then APPROVE fields is gated" 0 -- \
  api -X POST $REVIEWS -f event=COMMENT -f event=APPROVE
assert_eq "1" "$(policy_calls)" "GATE any non-SAFE event value -> gated"
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "-F event=@file is gated" 0 -- \
  api -X POST $REVIEWS -F event=@/dev/null
assert_eq "1" "$(policy_calls)" "GATE -F event=@file -> gated"
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "implicit POST (no -X) APPROVE is gated" 0 -- \
  api $REVIEWS -f event=APPROVE
assert_eq "1" "$(policy_calls)" "GATE implicit POST -> gated"
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "full API URL path is gated" 0 -- \
  api -X POST https://api.github.com/$REVIEWS -f event=APPROVE
assert_eq "1" "$(policy_calls)" "GATE https://api.github.com/ path -> gated"

# --- governed + not clear: lgtm's refusal, verbatim ---------------------------
reset_gate
FAKE_POLICY_OUT="$(payload '.verdict="blocked" | .refusal={class:"policy", message:'"$POLICY_MSG"'}')" \
  run_gate "blocked" 3 -- api -X POST $REVIEWS -f event=APPROVE
assert_eq "no" "$(posted)" "GATE blocked -> nothing posted"
assert_eq "$(jq -r '.[]' <<<"$POLICY_MSG")" "$err" "GATE blocked -> lgtm's message printed verbatim, nothing else"
assert_eq "policy|blocked|answered|$H1" \
  "$(jq -r '[.refusal.class, .verdict, .reason, .head] | join("|")' < "$refusals")" \
  "GATE blocked -> ledger line carries class/verdict/reason/live head"

reset_gate
FAKE_POLICY_OUT="$(payload '.verdict="undetermined" | .reason="no-verdict-for-head" | .refusal={class:"plumbing", message:'"$POLICY_MSG"'}')" \
  FAKE_POLICY_RC=2 run_gate "undetermined (exit 2 with a refusal)" 5 -- api -X POST $REVIEWS -f event=APPROVE
assert_eq "plumbing|no-verdict-for-head" "$(jq -r '[.refusal.class, .reason] | join("|")' < "$refusals")" \
  "GATE plumbing refusal -> ledgered as plumbing with lgtm's reason"

# --- the wrapper's own fallbacks ----------------------------------------------
fallback_case() {  # <label> <cause>  (runs after the caller set FAKE_* and ran)
  assert_eq "no" "$(posted)" "GATE $1 -> nothing posted"
  assert_eq "$MARKER" "${err:0:${#MARKER}}" "GATE $1 -> starts with the marker"
  assert_contains "$err" "event=COMMENT" "GATE $1 -> tells the session to COMMENT"
  assert_contains "$err" "commit_id" "GATE $1 -> tells the session to pin commit_id"
  assert_eq "plumbing|$2" "$(jq -r '[.refusal.class, .refusal.cause] | join("|")' "$refusals" 2>/dev/null || true)" \
    "GATE $1 -> ledgered as plumbing/$2"
}

reset_gate
FAKE_POLICY_OUT="$(payload '.verdict="undetermined" | .reason="no-verdict-for-head"')" FAKE_POLICY_RC=2 \
  run_gate "governed non-clear WITHOUT refusal (version skew)" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "version skew" answer-untrusted

reset_gate
FAKE_POLICY_RC=1 run_gate "lgtm failed, no output" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "lgtm failed" policy-command-failed
assert_eq "null" "$(jq -r '.verdict // "null"' < "$refusals")" "GATE no answer -> no verdict copied"

reset_gate
FAKE_POLICY_OUT='not json' run_gate "garbled answer" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "garbled" policy-command-failed

reset_gate
FAKE_POLICY_OUT="$(payload) $(payload)" run_gate "two JSON documents" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "two documents" policy-command-failed

reset_gate
FAKE_POLICY_OUT="$(payload)" FAKE_POLICY_RC=2 run_gate "clear payload but nonzero exit" 5 -- \
  api -X POST $REVIEWS -f event=APPROVE
fallback_case "clear+rc2" policy-command-failed

reset_gate
FAKE_POLICY_OUT="$(payload '.prNumber=43 | .verdict="blocked" | .refusal={class:"policy", message:'"$POLICY_MSG"'}')" \
  run_gate "answer about another PR" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "payload pr mismatch" payload-mismatch
assert_eq "" "$(grep -F 'line two, verbatim' <<<"$err")" "GATE mismatched payload -> its message is NOT printed"
reset_gate
FAKE_POLICY_OUT="$(payload ".head=\"$H2\"")" run_gate "answer about another head" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "payload head mismatch" payload-mismatch
reset_gate
FAKE_POLICY_OUT="$(payload '.repo="food-truck/other"')" run_gate "answer about another repo" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "payload repo mismatch" payload-mismatch
reset_gate
FAKE_POLICY_OUT="$(payload '.prNumber="42"')" run_gate "prNumber as a string" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "prNumber string" payload-mismatch

reset_gate
FAKE_POLICY_OUT="$(payload '.config.path="/home/dev/other/lgtm.yml"')" run_gate "config path not the pin" 5 -- \
  api -X POST $REVIEWS -f event=APPROVE
fallback_case "config path" answer-untrusted
reset_gate
FAKE_POLICY_OUT="$(payload '.config.stateDir="/home/dev/.local/state/lgtm/"')" run_gate "stateDir with trailing slash" 5 -- \
  api -X POST $REVIEWS -f event=APPROVE
fallback_case "stateDir" answer-untrusted
reset_gate
FAKE_POLICY_OUT="$(payload 'del(.config)')" run_gate "no config echo (old lgtm)" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "no config" answer-untrusted
reset_gate
FAKE_POLICY_OUT="$(payload '.governed=false')" run_gate "clear but governed:false" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "clear+ungoverned" answer-untrusted
reset_gate
FAKE_POLICY_OUT="$(payload '.config.governedRepos=["food-truck/other"]')" run_gate "governed but absent from governedRepos" 5 -- \
  api -X POST $REVIEWS -f event=APPROVE
fallback_case "governed not listed" answer-untrusted

reset_gate
FAKE_PR_RC=1 FAKE_PR_LINE="" run_gate "live head unreadable" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "GET failed" live-head-unreadable
assert_eq "0" "$(policy_calls)" "GATE GET failed -> lgtm not asked"
assert_eq "null" "$(jq -r '.head // "null"' < "$refusals")" "GATE GET failed -> no head recorded"
reset_gate
FAKE_PR_LINE="nothex food-truck/mono" run_gate "live head garbled" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "GET garbled" live-head-unreadable

# The race the pin exists for: the session reviewed H2, the author pushed H1.
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "APPROVE pinned to a stale head" 5 -- \
  api -X POST $REVIEWS -f event=APPROVE -f commit_id=$H2
fallback_case "stale commit_id" head-mismatch
assert_eq "$H1|$H2" "$(jq -r '[.head, .requestedHead] | join("|")' < "$refusals")" \
  "GATE head-mismatch -> head=live, requestedHead=the session's"
assert_eq "0" "$(policy_calls)" "GATE floor repo + stale pin -> refused before asking lgtm"

# --- ungoverned repos ----------------------------------------------------------
UNG=repos/blueapron/internal-frontends/pulls/9/reviews
ungov() {
  jq -cn --argjson cfg "$CFG" --arg h "$H1" \
    "{repo:\"blueapron/internal-frontends\", prNumber:9, head:\$h, governed:false, verdict:\"ungoverned\", reason:\"ungoverned\", blockedOwners:[], ownerReviewers:[], warnings:0, config:\$cfg} | ${1:-.}"
}
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov)" run_gate "APPROVE on an ungoverned repo" 0 -- api -X POST $UNG -f event=APPROVE
assert_eq "ARGS=api -X POST $UNG -f event=APPROVE" "$(sed -n 2p "$gh_record")" \
  "GATE ungoverned allow -> argv untouched (no pin)"
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov)" run_gate "ungoverned APPROVE with a stale commit_id" 0 -- \
  api -X POST $UNG -f event=APPROVE -f commit_id=$H2
assert_eq "0" "$(refusal_lines)" "GATE no head check on ungoverned repos"
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov '.config.governedRepos=[]')" run_gate "ungoverned but floor not in governedRepos" 5 -- \
  api -X POST $UNG -f event=APPROVE
fallback_case "floor not subset" answer-untrusted
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov '.config.governedRepos=["food-truck/mono","blueapron/internal-frontends"]')" \
  run_gate "ungoverned but listed in governedRepos" 5 -- api -X POST $UNG -f event=APPROVE
fallback_case "ungoverned but listed" answer-untrusted
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov '.config.path="/tmp/lgtm.yml"')" run_gate "ungoverned from the wrong config" 5 -- \
  api -X POST $UNG -f event=APPROVE
fallback_case "ungoverned wrong config" answer-untrusted
# dwic: the wrong lgtm.yml says mono is ungoverned. The FLOOR catches it.
reset_gate
FAKE_POLICY_OUT="$(payload '.governed=false | .verdict="ungoverned" | .reason="ungoverned" | .config.governedRepos=[]')" \
  run_gate "lgtm says mono is ungoverned (wrong config)" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "floor overrides ungoverned" answer-untrusted

# --- --input bodies -------------------------------------------------------------
body="$sandbox/review.json"
reset_gate
printf '{"event":"COMMENT","body":"x"}' > "$body"
run_gate "--input COMMENT body" 0 -- api -X POST $REVIEWS --input "$body"
assert_eq "0" "$(policy_calls)" "GATE --input COMMENT -> not gated"
assert_eq '{"event":"COMMENT","body":"x"}' "$(cat "$gh_record.input")" "GATE --input COMMENT -> gh sends the same bytes"

reset_gate
printf '{"event":"APPROVE","body":"x"}' > "$body"
FAKE_POLICY_OUT="$(payload)" run_gate "--input APPROVE body, clear" 0 -- api -X POST $REVIEWS --input "$body"
assert_eq "APPROVE|$H1" "$(jq -r '[.event, .commit_id] | join("|")' < "$gh_record.input")" \
  "GATE --input APPROVE -> body sent with commit_id=<live head>"
assert_eq '{"event":"APPROVE","body":"x"}' "$(cat "$body")" "GATE --input -> the session's file is not modified"
assert_eq "" "$(grep -F -- "-f commit_id" "$gh_record")" "GATE --input -> pin is NOT appended as a query field"

reset_gate
err="$(printf '{"event":"APPROVE"}' | FAKE_POLICY_OUT="$(payload)" lgtm_gh api -X POST $REVIEWS --input - 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "0" "$rc" "GATE --input - (stdin) APPROVE, clear -> exit 0"
assert_eq "$H1" "$(jq -r .commit_id < "$gh_record.input")" "GATE --input - -> body sent pinned"

# Private copies are removed on every exit path (allow, refusal, capture).
reset_gate
gate_tmp="$sandbox/gate-tmp"; mkdir -p "$gate_tmp"
printf '{"event":"APPROVE"}' > "$body"
TMPDIR="$gate_tmp" FAKE_POLICY_OUT="$(payload)" run_gate "--input APPROVE (temp-file check)" 0 -- \
  api -X POST $REVIEWS --input "$body"
TMPDIR="$gate_tmp" run_gate "--input APPROVE refused (temp-file check)" 5 -- \
  api -X POST $REVIEWS --input "$body" -f x=y
printf '{"event":"COMMENT"}' > "$body"
TMPDIR="$gate_tmp" run_gate "--input COMMENT (temp-file check)" 0 -- api -X POST $REVIEWS --input "$body"
assert_eq "0" "$(find "$gate_tmp" -type f | wc -l | tr -d ' ')" "GATE leaves no temp files behind"

reset_gate
printf '{"event":"APPROVE","commit_id":"%s"}' "$H2" > "$body"
FAKE_POLICY_OUT="$(payload)" run_gate "--input body pinned to a stale head" 5 -- api -X POST $REVIEWS --input "$body"
fallback_case "--input stale" head-mismatch

reset_gate
printf '{"event":"COMMENT","event":"APPROVE"}' > "$body"
FAKE_POLICY_OUT="$(payload)" run_gate "--input duplicate event keys" 0 -- api -X POST $REVIEWS --input "$body"
assert_eq "1" "$(policy_calls)" "GATE duplicate event keys in a body -> gated"

reset_gate
printf '["not an object"]' > "$body"
run_gate "--input non-object body" 5 -- api -X POST $REVIEWS --input "$body"
fallback_case "--input non-object" unparseable-event
reset_gate
run_gate "--input missing file" 5 -- api -X POST $REVIEWS --input "$sandbox/nope.json"
fallback_case "--input missing" unparseable-event

reset_gate
printf '{"event":"APPROVE"}' > "$body"
run_gate "--input plus a field" 5 -- api -X POST $REVIEWS --input "$body" -f commit_id=$H1
fallback_case "--input + field" unparseable-event
reset_gate
run_gate "repeated --input" 5 -- api -X POST $REVIEWS --input "$body" --input "$body"
fallback_case "repeated --input" unparseable-event
reset_gate
run_gate "-- in a gated argv" 5 -- api -X POST $REVIEWS -f event=APPROVE --
fallback_case "dashdash" unparseable-event

# --- surfaces refused everywhere, without asking anyone ------------------------
reset_gate
run_gate "pr review --approve" 5 -- pr review 42 --repo food-truck/mono --approve
fallback_case "pr review --approve" unsupported-surface
assert_eq "0" "$(gets)" "GATE pr review --approve -> no network"
reset_gate
run_gate "pr review -a on an ungoverned repo" 5 -- pr review 9 --repo blueapron/internal-frontends -a
assert_eq "no" "$(posted)" "GATE pr review -a refused on every repo"
reset_gate
run_gate "pr review with no event flag" 5 -- pr review 42 --repo food-truck/mono -b hi
assert_eq "no" "$(posted)" "GATE pr review without -c/-r is gated"

reset_gate
run_gate "/events APPROVE" 5 -- api -X POST $REVIEWS/77/events -f event=APPROVE
fallback_case "/events APPROVE" unsupported-surface
reset_gate
run_gate "/events COMMENT" 0 -- api -X POST $REVIEWS/77/events -f event=COMMENT
assert_eq "yes" "$(posted)" "GATE /events COMMENT -> posted"

reset_gate
run_gate "graphql addPullRequestReview" 5 -- \
  api graphql -f 'query=mutation{addPullRequestReview(input:{pullRequestId:"X",event:APPROVE}){clientMutationId}}'
assert_eq "no" "$(posted)" "GATE graphql addPullRequestReview -> nothing posted"
assert_eq "$MARKER" "${err:0:${#MARKER}}" "GATE graphql -> starts with the marker"
assert_eq "0" "$(refusal_lines)" "GATE graphql -> no ledger line (no repo to name)"
reset_gate
run_gate "graphql submitPullRequestReview" 5 -- \
  api graphql -f 'query=mutation{submitPullRequestReview(input:{pullRequestReviewId:"X",event:APPROVE}){clientMutationId}}'
assert_eq "no" "$(posted)" "GATE graphql submitPullRequestReview -> nothing posted"

reset_gate
run_gate "placeholder repo in the path" 5 -- api -X POST 'repos/{owner}/{repo}/pulls/42/reviews' -f event=APPROVE
assert_eq "$MARKER" "${err:0:${#MARKER}}" "GATE placeholder path -> starts with the marker"
assert_eq "0" "$(gets)" "GATE placeholder path -> no network"
assert_eq "0" "$(refusal_lines)" "GATE placeholder path -> no (invalid) ledger line"
reset_gate
run_gate "numeric repositories/<id> route" 5 -- api -X POST repositories/123/pulls/42/reviews -f event=APPROVE
assert_eq "no" "$(posted)" "GATE repositories/<id> reviews -> nothing posted"
reset_gate
run_gate "a short cluster on a review path" 5 -- api -iXPOST $REVIEWS -f event=APPROVE
assert_eq "no" "$(posted)" "GATE short cluster on a review submission -> refused"

# --- gaps found by mutation testing ---------------------------------------------
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "COMMENT plus an event[] key" 0 -- \
  api -X POST $REVIEWS -f event=COMMENT -f 'event[]=APPROVE'
assert_eq "1" "$(policy_calls)" "GATE an event[...] key makes the event unreadable -> gated"
reset_gate
printf '{"event":"COMMENT"}{"event":"COMMENT"}' > "$body"
run_gate "--input with two JSON documents" 5 -- api -X POST $REVIEWS --input "$body"
fallback_case "--input two documents" unparseable-event
reset_gate
printf '{"event":["COMMENT"]}' > "$body"
run_gate "--input with a non-string event" 5 -- api -X POST $REVIEWS --input "$body"
fallback_case "--input nested event" unparseable-event
reset_gate
printf '{"event":"COMMENT","event":{"a":"APPROVE"}}' > "$body"
run_gate "--input COMMENT then an object-valued duplicate event" 5 -- api -X POST $REVIEWS --input "$body"
fallback_case "--input duplicate object event" unparseable-event
reset_gate
run_gate "a short cluster hiding -XPOST, no fields" 5 -- api -iXPOST $REVIEWS
assert_eq "no" "$(posted)" "GATE -iXPOST with no fields is still a submission -> gated"
reset_gate
export FAKE_PR_LINE="$H1 blueapron/internal-frontends"
FAKE_POLICY_OUT="$(ungov)" FAKE_POLICY_RC=2 run_gate "ungoverned answer with a nonzero exit" 5 -- \
  api -X POST $UNG -f event=APPROVE
fallback_case "ungoverned+rc2" policy-command-failed
reset_gate
run_gate "pr review --comment AND --approve" 5 -- pr review 42 --repo food-truck/mono -c -a
assert_eq "no" "$(posted)" "GATE pr review with -a is gated even beside -c"
reset_gate
FAKE_POLICY_OUT="$(payload '.verdict="blocked" | .refusal={class:"policy", message:[1,2]}')" \
  run_gate "refusal message that is not strings" 5 -- api -X POST $REVIEWS -f event=APPROVE
fallback_case "non-string refusal message" answer-untrusted
reset_gate
export FAKE_PR_LINE="$H1 food-truck/other"
FAKE_POLICY_OUT="$(payload '.repo="food-truck/other" | .config.governedRepos=["food-truck/mono","food-truck/other"]')" \
  run_gate "governed repo OFF the floor, stale commit_id" 5 -- \
  api -X POST repos/food-truck/other/pulls/42/reviews -f event=APPROVE -f commit_id=$H2
fallback_case "governed off-floor stale pin" head-mismatch
reset_gate
printf '{"event":"COMMENT"}' > "$body"
FAKE_POLICY_OUT="$(payload)" run_gate "event=COMMENT field plus two --input bodies" 5 -- \
  api -X POST $REVIEWS -f event=COMMENT --input "$body" --input "$body"
assert_eq "no" "$(posted)" "GATE two --input bodies are never SAFE"
reset_gate
run_gate "pr review -a with a branch selector" 5 -- pr review some-branch --repo food-truck/mono -a
assert_eq "0" "$(refusal_lines)" "GATE no PR number -> no (invalid) ledger line"
assert_eq "$MARKER" "${err:0:${#MARKER}}" "GATE no PR number -> still the marker"
reset_gate
run_gate "two review paths in one call" 5 -- \
  api -X POST $REVIEWS repos/food-truck/other/pulls/1/reviews -f event=APPROVE
assert_eq "0" "$(gets)" "GATE two review paths -> refused before any network"
reset_gate
gate_tmp2="$sandbox/gate-tmp2"; mkdir -p "$gate_tmp2"
printf '{"event":"COMMENT"}' > "$body"
TMPDIR="$gate_tmp2" run_gate "/events COMMENT via --input" 0 -- api -X POST $REVIEWS/77/events --input "$body"
assert_eq "0" "$(find "$gate_tmp2" -type f | wc -l | tr -d ' ')" "GATE /events --input leaves no temp file"

# --- review fixes -------------------------------------------------------------
errlog="$HOME/.local/state/lgtm/gate-errors.log"
reset_gate; rm -f "$errlog"
run_approval_policy_stderr='Error: something broke inside lgtm'
FAKE_POLICY_OUT="" FAKE_POLICY_RC=1 FAKE_POLICY_ERR="$run_approval_policy_stderr" \
  run_gate "lgtm fails with stderr" 5 -- api -X POST $REVIEWS -f event=APPROVE
assert_contains "$(cat "$errlog" 2>/dev/null)" "something broke inside lgtm" "GATE a failing lgtm's stderr is kept for the operator"
assert_eq "" "$(grep -F 'something broke' <<<"$err")" "GATE ...but not shown to the session"
reset_gate; rm -f "$errlog"
FAKE_POLICY_OUT="$(payload)" FAKE_POLICY_ERR="noise" run_gate "allowed, with stderr noise" 0 -- api -X POST $REVIEWS -f event=APPROVE
assert_eq "no" "$([ -f "$errlog" ] && echo yes || echo no)" "GATE an allow writes no error log"

reset_gate
FAKE_POLICY_OUT="$(payload '.config.path="/x" | .verdict="undetermined" | .reason="no-verdict-for-head" | .refusal={class:"plumbing", message:["m"]}')" \
  FAKE_POLICY_RC=2 run_gate "untrusted answer that names a race reason" 5 -- api -X POST $REVIEWS -f event=APPROVE
assert_eq "null|answer-untrusted" "$(jq -r '[(.reason // "null"), .refusal.cause] | join("|")' "$refusals" 2>/dev/null || true)" \
  "GATE answer-untrusted copies no reason (it must not be held as a race)"

reset_gate; rm -f "$ledger"
printf '{"event":"COMMENT"}' > "$body"
FAKE_GH_BODY='{"id":4444}' run_gate "/events COMMENT via --input (artifact)" 0 -- api -X POST $REVIEWS/77/events --input "$body"
assert_eq "0" "$([ -f "$ledger" ] && wc -l < "$ledger" | tr -d ' ' || echo 0)" \
  "GATE a forced capture with no review endpoint records no malformed artifact"

# --- floor drift (never a refusal) ---------------------------------------------
reset_gate
FAKE_POLICY_OUT="$(payload '.config.governedRepos=["food-truck/mono","food-truck/newteam"]')" \
  run_gate "lgtm governs a repo the floor lacks" 0 -- api -X POST $REVIEWS -f event=APPROVE
assert_eq '["food-truck/newteam"]' "$(jq -c .extra < "$drift")" "GATE drift -> recorded, not refused"
assert_eq "" "$(grep -i drift <<<"$err")" "GATE drift -> nothing on stderr"

# --- every ledger line this suite wrote satisfies the reader's validator -------
# (src/gateRefusalAlert.ts validate(): repo regex, integer prNumber > 0,
# 40-hex head/requestedHead, class enum.) The real-parser round trip is in
# roundtrip.sh, which runs lgtm's own parseGateRefusals on cloudbox.
all_lines="$sandbox/all-refusals.jsonl"
: > "$all_lines"
validate_line() {
  jq -e '
    (.ts|type=="string") and (.ts|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and
    (.repo|test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    (.prNumber|type=="number" and . == floor and . > 0) and
    ((.head // "0000000000000000000000000000000000000000")|test("^[0-9a-f]{40}$")) and
    ((.requestedHead // "0000000000000000000000000000000000000000")|test("^[0-9a-f]{40}$")) and
    (.refusal.class=="policy" or .refusal.class=="plumbing") and
    (.login|test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))
  ' >/dev/null
}
reset_gate
FAKE_POLICY_OUT="$(payload '.verdict="blocked" | .warningClass="attribution" | .refusal={class:"policy", message:'"$POLICY_MSG"'}')" \
  run_gate "ledger shape: policy" 3 -- api -X POST $REVIEWS -f event=APPROVE
{ cat "$refusals" >> "$all_lines"; } 2>/dev/null || true
reset_gate
run_gate "ledger shape: fallback" 5 -- pr review 42 --repo food-truck/mono -a
{ cat "$refusals" >> "$all_lines"; } 2>/dev/null || true
reset_gate
FAKE_POLICY_OUT="$(payload)" run_gate "ledger shape: head-mismatch" 5 -- api -X POST $REVIEWS -f event=APPROVE -f commit_id=$H2
{ cat "$refusals" >> "$all_lines"; } 2>/dev/null || true
bad=0
while IFS= read -r l; do validate_line <<<"$l" || bad=$((bad + 1)); done < "$all_lines"
assert_eq "3|0" "$(wc -l < "$all_lines" | tr -d ' ')|$bad" "GATE every ledger line passes the reader's validation rules"
assert_eq "attribution" "$(head -1 "$all_lines" | jq -r .warningClass)" "GATE ledger copies warningClass"
assert_eq "jamesvec" "$(head -1 "$all_lines" | jq -r .login)" "GATE ledger records the acting login"

# --- the shipped GATE PINS block, byte for byte ---------------------------------
#
# The sandbox above replaces this block, so nothing else here would notice a
# drifted pin. A pin that differs from what lgtm echoes refuses EVERY approve
# (dwic item 6): no $HOME, no trailing slash, the exact live paths.
expected_block="$sandbox/expected-pins.sh"
cat > "$expected_block" <<'EOF'
# BEGIN GATE PINS
gate_lgtm_dir="/home/dev/projects/lgtm"
gate_lgtm_config="/home/dev/projects/lgtm/lgtm.yml"
gate_lgtm_state_dir="/home/dev/.local/state/lgtm"
gate_lgtm_tokens_dir="/home/dev/.config/lgtm/tokens"
gate_lgtm_projects_dir="/home/dev/projects"
gate_lgtm_home="/home/dev"
gate_governed_floor=("food-truck/mono")
run_approval_policy() {
  local node_bin
  node_bin="$(command -v node)" || return 127
  ( cd "$gate_lgtm_dir" || exit 126
    timeout -k 2 20 env -i \
      HOME="$gate_lgtm_home" PATH="${node_bin%/*}" \
      LGTM_CONFIG="$gate_lgtm_config" LGTM_STATE_DIR="$gate_lgtm_state_dir" \
      LGTM_TOKENS_DIR="$gate_lgtm_tokens_dir" LGTM_PROJECTS_DIR="$gate_lgtm_projects_dir" \
      "$node_bin" "$gate_lgtm_dir/node_modules/tsx/dist/cli.mjs" src/index.ts \
      --approval-policy "$1" --head "$2" )
}
# END GATE PINS
EOF
assert_eq "$(cat "$expected_block")" \
  "$(sed -n '/^# BEGIN GATE PINS$/,/^# END GATE PINS$/p' "$script_dir/lgtm-gh.sh")" \
  "GATE the shipped pin block is exactly the live pins"

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
  grep_guard 'pkgs\.nodejs_22' "derivation pins node for the approval gate's env -i lgtm call"

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
