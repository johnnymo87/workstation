#!/usr/bin/env bash
# THE BODY OF THE lgtm-gh WRAPPER. `default.nix` reads this file verbatim into
# pkgs.writeShellApplication, so this is production source, not a copy of it.
#
# It lives in its own file rather than inline in the nix expression for one
# reason: pkgs/lgtm-gh/test.sh can then run it DIRECTLY, with a fake `gh` on
# PATH. The shipped binary cannot be intercepted that way (writeShellApplication
# prepends its runtimeInputs to PATH, so the pinned real `gh` always wins), which
# is why test.sh used to drive a hand-copied mirror of this logic and had to be
# labelled "a design record, not evidence". There is no mirror now, and so
# nothing for it to drift from.
#
# Design: lgtm repo docs/plans/2026-04-30-multi-reviewer-identity-design.md.
set -o errexit -o nounset -o pipefail

# Identity for this worktree: a single GitHub login lgtm wrote here.
login_file="$PWD/.lgtm-reviewer"
if [ ! -r "$login_file" ]; then
  echo "lgtm-gh: missing $login_file" >&2
  exit 1
fi

login="$(tr -d '[:space:]' < "$login_file")"
if [ -z "$login" ]; then
  echo "lgtm-gh: empty $login_file" >&2
  exit 1
fi

# Resolve that login's PAT. On cloudbox this file is materialized from a
# sops secret by home.activation.deployLgtmTokens (chmod 600, owner dev).
token_file="$HOME/.config/lgtm/tokens/$login.pat"
if [ ! -r "$token_file" ]; then
  echo "lgtm-gh: missing $token_file for login=$login" >&2
  exit 1
fi

state_dir="$HOME/.local/state/lgtm"

# Pin gh at a config AND data directory this wrapper owns.
#
# Not cosmetic: a `gh` alias expands INSIDE gh, after this script has already
# classified the argv, so `lgtm-gh co 123` could run `pr merge` with the merge
# policy below none the wiser. Refusing the `alias` subcommand (it is refused)
# only stops this wrapper from CREATING one; an alias that already exists in
# the user's config would still expand. Pointing GH_CONFIG_DIR somewhere gh
# never wrote leaves none but gh's own built-in `co: pr checkout`.
#
# XDG_DATA_HOME is the same argument for EXTENSIONS, and needs saying
# separately because go-gh's DataDir() does NOT read GH_CONFIG_DIR: extensions
# live under $XDG_DATA_HOME/gh (default ~/.local/share/gh). An installed
# extension is arbitrary code that would be handed a reviewer PAT, and
# `lgtm-gh <ext>` parses as no subcommand this file knows.
#
# Costs no credentials ANYWHERE, which is the load-bearing claim rather than
# "cloudbox has no ~/.config/gh" -- this wrapper is installed from
# home.base.nix, so it also lands on devbox and macOS, where a hosts.yml may
# well exist. The reason it is safe is that every exec below sets GH_TOKEN
# explicitly, and an explicit GH_TOKEN beats anything in hosts.yml. (On
# cloudbox there is additionally nothing to lose: no ~/.config/gh and no gh
# extensions at all, and `gh auth status` without GH_TOKEN reports "not logged
# into any GitHub hosts".)
GH_CONFIG_DIR="$state_dir/gh-config"
XDG_DATA_HOME="$state_dir/gh-data"
mkdir -p "$GH_CONFIG_DIR" "$XDG_DATA_HOME" 2>/dev/null || true
export GH_CONFIG_DIR XDG_DATA_HOME

# ---- one pass over argv -----------------------------------------------------
#
# Two questions are asked of the same argv -- "is this a review-creating POST
# whose id the ledger needs?" and "is this a merge, and into which repo?" -- so
# there is ONE scan and two decision functions reading its results. Two scans
# would answer adjacent questions and drift.
#
# They must not share a verdict, because their safe directions are OPPOSITE:
# the ledger fails toward not-matched (an unrecorded artifact reads as a
# human's, the safe error), the merge gate fails toward matched.

# THIS IS NOT A pflag REIMPLEMENTATION, and must not try to become one. gh's
# own flag parsing accepts short clusters, attached values, mixed-case URLs and
# host forms that no hand-written scan will ever track. The discipline that
# makes a partial parser safe is therefore: ANY ARGUMENT IT CANNOT DECOMPOSE
# BECOMES AN UNPARSEABLE REPO HINT, and an unparseable hint refuses.
#
# The one place that is not literally true, and the one thing a gh version bump
# has to re-check: an unrecognised LONG flag (`--*`) and an unrecognised single
# short flag (`-x`) are IGNORED rather than refused, because refusing them
# would refuse most ordinary reads. That is safe only against gh's current flag
# inventory -- for `pr merge` just `--repo` and `--disable-auto` change the
# target or the verdict, and for `api` just `-X/--method`, the field flags and
# `--input`. A future gh that adds a target-changing long flag is a silent gap
# here, not a refusal.

sub1=""          # 1st positional (the gh subcommand)
sub2=""          # 2nd positional
sub3=""          # 3rd positional (for `pr merge`, the PR selector)
pos_count=0
method=""        # -X / --method value, verbatim
mutating=0       # any -f/-F/--field/--raw-field/--input present
unknown_flag=0   # a short cluster this scan cannot decompose
merge_path=0     # some positional is a REST merge endpoint
graphql_path=0   # some positional is the graphql endpoint
review_endpoint=""
repo_hints=""    # space-separated OWNER/NAME candidates, one per hint SEEN
gql_query=""     # inline graphql query text, concatenated
gql_opaque=0     # graphql query supplied by file/stdin: cannot be inspected
disable_auto=0

# WHY a refusal happened, in the caller's words. Without this the "cannot
# determine the target repository" message tells an agent to pass --repo, which
# is wrong advice for four of the five ways a hint goes unparseable -- it
# already passed one. Wrong advice at a refusal is the moment a session starts
# looking for another route, which is the thing the refusal exists to prevent.
deny_why=""

# An argument this scan cannot decompose. Recorded as a HINT, not as silence,
# so it collides with every other hint and forces a refusal.
mark_unparseable() {
  [ -n "$deny_why" ] || deny_why="$1"
  repo_hints="$repo_hints !unparseable"
}

add_repo_hint() {
  local n="${1,,}"
  case "$n" in
    # gh accepts [HOST/]OWNER/REPO for --repo. Anything else is not a slug we
    # can reason about, and must NOT be truncated into one.
    */*/*/*) mark_unparseable "not a repository this wrapper can parse: '$1'"; return 0 ;;
    */*/*)   n="${n#*/}" ;;
    */*)     : ;;
    *)       mark_unparseable "not a repository this wrapper can parse: '$1'"; return 0 ;;
  esac
  repo_hints="$repo_hints $n"
}

# A `key=value` field. Only `query` matters, and only for graphql.
scan_field() {
  local kv="$1" k v
  k="${kv%%=*}"
  v="${kv#*=}"
  if [ "$k" = "query" ]; then
    case "$v" in
      @*) gql_opaque=1 ;;
      *)  gql_query="$gql_query $v" ;;
    esac
  fi
}

# Every positional after the subcommand, classified by SHAPE rather than by
# position. Position is not usable: `gh api -H 'Accept: x' <path>` and
# `gh api -X PUT <path>` both put something that is not the path where the
# path would otherwise be, and enumerating gh's value-taking flags to skip
# their arguments is exactly the pflag reimplementation this refuses to be.
scan_path() {
  local t="$1" owner name rest
  t="${t%%\?*}"
  t="${t%%#*}"
  t="${t%/}"
  case "$t" in
    graphql|*/graphql) graphql_path=1 ;;
  esac
  case "$t" in
    */pulls/*/reviews|*/pulls/*/comments|*/pulls/comments/*/replies)
      review_endpoint="$t" ;;
  esac
  case "$t" in
    */pulls/*/merge|*/merges)
      merge_path=1
      # The repo of a merge is the repo IN THE MERGE PATH -- never one picked
      # up from some other argument, which is how a --template or --jq value
      # could otherwise supply an allowlisted slug for a merge aimed
      # elsewhere. A merge path that names no slug (the real
      # `repositories/<id>/pulls/N/merge` route) yields an unparseable hint,
      # not silence.
      case "$t" in
        *repos/*/*/*)
          rest="${t#*repos/}"
          owner="${rest%%/*}"
          rest="${rest#*/}"
          name="${rest%%/*}"
          add_repo_hint "$owner/$name"
          ;;
        *) mark_unparseable "the merge path names no OWNER/NAME: '$t'" ;;
      esac
      ;;
  esac
}

# The `pr merge` selector. gh's ParseURL accepts any http(s) URL and then
# normalises the host (lowercase, `www.` stripped, port dropped), so
# `https://www.GitHub.com:443/food-truck/mono/pull/5` targets mono while
# looking nothing like the one form this scan could match. Rather than chase
# that, ONLY a bare number or the exact canonical URL is understood; every
# other selector -- including a branch name, which gh also accepts -- is
# unparseable and refuses.
scan_pr_selector() {
  local sel="$1"
  [ -n "$sel" ] || return 0
  if [[ "$sel" =~ ^#?[0-9]+$ ]]; then
    return 0
  fi
  if [[ "$sel" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/[0-9]+$ ]]; then
    add_repo_hint "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return 0
  fi
  mark_unparseable "the PR selector is neither a bare number nor a canonical https://github.com/OWNER/NAME/pull/N URL: '$sel'"
}

scan_argv() {
  local a pending="" v
  for a in "$@"; do
    case "$pending" in
      repo)   add_repo_hint "$a"; pending=""; continue ;;
      method) method="$a";        pending=""; continue ;;
      field)  scan_field "$a";    pending=""; continue ;;
      input)  gql_opaque=1;       pending=""; continue ;;
    esac
    case "$a" in
      # Both the separated and the ATTACHED form of every flag that can carry a
      # value we depend on. `-XPUT` and `--method=put` are the forms a merge
      # arrives in when someone is not copying the prompt's example, and a
      # previous-argument scan sees neither.
      --repo|-R)                 pending=repo ;;
      --repo=*)                  add_repo_hint "${a#--repo=}" ;;
      -R?*)                      v="${a#-R}"; add_repo_hint "${v#=}" ;;
      -X|--method)               pending=method ;;
      --method=*)                method="${a#--method=}" ;;
      -X?*)                      v="${a#-X}"; method="${v#=}" ;;
      -f|-F|--field|--raw-field) pending=field; mutating=1 ;;
      --field=*|--raw-field=*)   scan_field "${a#*=}"; mutating=1 ;;
      -f?*|-F?*)                 v="${a#-?}"; scan_field "${v#=}"; mutating=1 ;;
      # `gh api --input FILE` is a POST with no field flag at all.
      --input)                   pending=input; mutating=1 ;;
      --input=*)                 gql_opaque=1; mutating=1 ;;
      --disable-auto)            disable_auto=1 ;;
      --*)                       : ;;
      -[A-Za-z])                 : ;;
      # A short CLUSTER. `-sR food-truck/mono` is `--squash --repo
      # food-truck/mono`, and `-iXPUT` is `-i -X PUT`; both hide a
      # merge-relevant flag inside an argument this scan cannot decompose.
      -*)                        unknown_flag=1
                                 mark_unparseable "this wrapper cannot decompose the argument '$a'; pass its flags separately" ;;
      *)
        pos_count=$((pos_count + 1))
        case "$pos_count" in
          1) sub1="$a" ;;
          2) sub2="$a"; scan_path "$a" ;;
          3) sub3="$a"; scan_path "$a" ;;
          *) scan_path "$a" ;;
        esac
        ;;
    esac
  done
  if [ "$sub1" = "pr" ] && [ "$sub2" = "merge" ]; then
    scan_pr_selector "$sub3"
    # A 4th positional to `pr merge` is a shape this scan does not model.
    if [ "$pos_count" -gt 3 ]; then
      mark_unparseable "unexpected extra argument to 'pr merge'"
    fi
  fi
}

is_write_method() {
  case "${method^^}" in
    PUT|POST|PATCH|DELETE) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- merge policy -----------------------------------------------------------
#
# WHY THIS EXISTS. lgtm has two lanes. The REVIEW lane can no longer merge
# anything, for anyone (lgtm#110 deleted its Phase 4 and the config field
# behind it). The ASSIST lane still merges, deliberately, and ONLY in the two
# repos below -- 15 merges on record, all culinary-operations-server gem bumps.
# A dependency bump anywhere else, food-truck/mono above all, belongs to the
# goose lane (eng-agent-platform/lanes), which is a different system.
#
# Until this block existed, all of that was a property of PROMPT TEXT: this
# wrapper forwarded `pr merge` unchanged, so a PR comment that talked a session
# into merging simply worked. A refusal in argv is not persuadable the way a
# paragraph in a prompt is -- but argv can still be SHAPED, and the scan above
# is a partial parser, not a reimplementation of gh's. What makes that safe is
# that it recognises the shapes lgtm's prompts emit plus the obvious variants,
# and turns arguments it cannot decompose into a refusal -- with the
# long-flag caveat recorded above the scan.
#
# A BLANKET denylist would be wrong, not merely blunt: it would break the
# assist lane, whose entire purpose is to merge in those two repos. Hence
# repo-scoped.
#
# WHAT THIS IS NOT. It is not a security boundary, and must not be described as
# one. assets/opencode/plugins/shell-env.ts injects /run/secrets/github_api_token
# as GH_TOKEN into EVERY bash tool call in EVERY opencode session on cloudbox,
# lgtm's dispatched sessions included, so plain `gh pr merge --repo food-truck/mono`
# works today without passing through here. What this stops is a session that
# FOLLOWS its instruction to use lgtm-gh for state-changing calls and is wrong
# about whether it may merge -- which is the failure that actually happened.
# Closing the bypass means withholding that token from lgtm worktrees, which
# also takes away `git push` (git's credential helper here is
# `gh auth git-credential`) and is a cross-repo change.
#
# IT IS ALSO REPO-SCOPED, NOT LANE-SCOPED. The incident behind lgtm#110 --
# 73 review-lane dependabot dispatches, culinary-operations-server #4261-#4265
# merged seconds later under pool identities -- happened INSIDE an allowlisted
# repo, so this block would have permitted every one of those merges. The
# review lane's inability to merge in those two repos is still a property of
# lgtm's prompt text. Closing that needs lgtm to write the lane beside
# `.lgtm-reviewer` and this file to require lane==assist.
#
# MIRROR OF ASSIST_REPO_ALLOWLIST in lgtm's src/discover.ts. Two lists in two
# repos: if they diverge, the failure is an assist merge REFUSED (the PR sits
# approved-but-unmerged and the session's own verification step notices), not
# an unauthorized merge permitted. Keep them in step anyway.
merge_allowlist=(
  "blueapron/culinary-operations-server"
  "blueapron/internal-frontends"
)

# Non-empty iff this invocation is a merge. Value names which surface, for the
# denial record.
merge_kind=""

classify_merge() {
  if [ "$sub1" = "pr" ] && [ "$sub2" = "merge" ]; then
    # --disable-auto CANCELS a pending auto-merge. Refusing a de-escalation
    # would be perverse, and it cannot smuggle a merge through: gh returns
    # before merging (merge.go:548) and rejects it alongside --auto/--admin
    # (merge.go:129-133).
    if [ "$disable_auto" -eq 1 ]; then return 0; fi
    merge_kind="pr-merge"
    return 0
  fi
  if [ "$sub1" != "api" ]; then return 0; fi

  # The merge MUTATIONS carry a pull-request node ID, never a repo slug, so
  # there is nothing to scope them by and they are refused outright. Checked
  # against the query text regardless of which path argument gh was given,
  # because `gh api /graphql` and `gh api -H 'X: y' graphql` both reach the
  # same endpoint while putting something else where the path would be.
  # lgtm's prompts contain no graphql at all, so this costs the assist lane
  # nothing.
  case "$gql_query" in
    *mergePullRequest*|*enablePullRequestAutoMerge*|*enqueuePullRequest*|*mergeBranch*)
      merge_kind="graphql-merge"
      return 0 ;;
  esac
  if [ "$graphql_path" -eq 1 ] && [ "$gql_opaque" -eq 1 ]; then
    # Query came from a file or stdin. It cannot be read, so it cannot be
    # cleared.
    mark_unparseable "the graphql query was not inline, so it could not be inspected"
    merge_kind="graphql-opaque"
    return 0
  fi

  if [ "$merge_path" -eq 1 ]; then
    # GET /pulls/N/merge is the legitimate "has this merged?" read, so a merge
    # endpoint alone is not a merge. An undecomposable short cluster might be
    # hiding `-X PUT`, so it counts as a write.
    if [ "$mutating" -eq 1 ] || [ "$unknown_flag" -eq 1 ] || is_write_method; then
      merge_kind="rest-merge"
    fi
  fi
  return 0
}

# Empty unless EXACTLY ONE distinct repo is named by the command line.
#
# Deliberately not a precedence order. In gh a PR-URL argument WINS over
# `--repo` (finder.go:117-122) and pflag is last-wins on a repeated flag, so
# any ranking this file invented could resolve to an allowlisted repo while gh
# merged a different one -- the only direction that silently permits a merge.
# Disagreement is refused instead of ranked.
#
# `$GH_REPO` and the git remote of $PWD are deliberately NOT consulted. The
# assist lane always passes --repo (lgtm prompt.ts:260), so neither buys
# anything for the caller that must keep working, and the remote is not
# trustworthy: `gh repo set-default` writes remote.origin.gh-resolved, and
# lgtm reuses any worktree at a matching SHA regardless of where it lives
# (worktree.ts:99-104).
target_repo=""
resolve_repo() {
  local -a hints
  local h
  read -ra hints <<<"$repo_hints"
  for h in "${hints[@]:-}"; do
    [ -n "$h" ] || continue
    if [ -z "$target_repo" ]; then
      target_repo="$h"
    elif [ "$h" != "$target_repo" ]; then
      target_repo=""
      return 0
    fi
  done
  case "$target_repo" in
    "!unparseable") target_repo="" ;;
  esac
}

# Best-effort tripwire. Same discipline as the artifact ledger: it must never
# be the reason a refusal fails to happen, so every error here is swallowed.
record_denial() {
  local repo="$1" kind="$2" ts
  mkdir -p "$state_dir" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn \
    --arg ts "$ts" --arg login "$login" --arg repo "$repo" --arg kind "$kind" \
    '{ts:$ts, login:$login, repo:$repo, kind:$kind}' \
    >> "$state_dir/merge-denials.jsonl" 2>/dev/null || true
  return 0
}

# Exit 3, distinct from gh's own codes, so a caller can tell policy from failure.
deny_merge() {
  local repo="$1"
  record_denial "$repo" "$merge_kind"
  if [ "$repo" = "?" ]; then
    echo "lgtm-gh: refusing this merge: its target repository cannot be established from the command line." >&2
    if [ -n "$deny_why" ]; then
      echo "lgtm-gh: reason: $deny_why" >&2
    else
      echo "lgtm-gh: reason: nothing on the command line names a repository." >&2
    fi
    echo "lgtm-gh: the understood form is 'pr merge <number> --repo OWNER/NAME'." >&2
  else
    echo "lgtm-gh: refusing to merge in $repo." >&2
    echo "lgtm-gh: lgtm merges only in ${merge_allowlist[*]}." >&2
    echo "lgtm-gh: dependency bumps elsewhere belong to the goose lane, not to this session." >&2
  fi
  echo "lgtm-gh: this is policy, not a malfunction. Do not look for another way to land it --" >&2
  echo "lgtm-gh: finish the review and report needs-human instead." >&2
  exit 3
}

scan_argv "$@"

# Neither can be parsed for policy: an alias expands inside gh AFTER this scan,
# and an extension is arbitrary code handed the PAT. lgtm's prompts use
# neither.
case "$sub1" in
  alias|extension)
    echo "lgtm-gh: refusing 'gh $sub1': it would run under a reviewer identity without passing this wrapper's policy." >&2
    echo "lgtm-gh: this is policy, not a malfunction." >&2
    exit 3
    ;;
esac

classify_merge
if [ -n "$merge_kind" ]; then
  resolve_repo
  if [ -z "$target_repo" ]; then
    deny_merge "?"
  fi
  allowed=0
  for r in "${merge_allowlist[@]}"; do
    if [ "$r" = "$target_repo" ]; then allowed=1; fi
  done
  if [ "$allowed" -ne 1 ]; then
    deny_merge "$target_repo"
  fi
fi

# ---- review-artifact ledger --------------------------------------------
#
# WHY THIS EXISTS. lgtm reviews as a POOL OF REAL HUMAN LOGINS
# (johnnymo87, Krosantos, jamesvec), so its review comments are
# indistinguishable from those humans' own comments: same login, same
# __typename "User", no marker. The shepherd's needs_reply signal
# therefore cannot tell "a human is waiting on the author" from "lgtm is
# waiting on the author", and a wake budget can be spent entirely on lgtm
# talking to an AI agent with no person anywhere in the loop.
#
# Identity cannot answer this and neither can time: Krosantos and jamesvec
# are real colleagues who also review PRs themselves, so correlating by
# (login, time window) misclassifies a real human as machine -- the
# expensive direction. The only reliable discriminator is the ARTIFACT ID,
# because every artifact lgtm creates is created HERE, and a human posting
# from a browser never passes through this wrapper.
#
# FAILS TOWARD HUMAN, ALWAYS. Any failure below (no jq, unparseable body,
# unwritable state dir, non-numeric id) leaves the artifact UNRECORDED,
# and an unrecorded artifact is read downstream as a human's. That is the
# safe direction: at worst we spend a wake answering a machine, whereas
# the inverse silently erases evidence that a person was engaged.
#
# It must NEVER break the underlying call. Recording is best-effort and
# the exit code always comes from gh.
ledger_dir="$state_dir"
ledger_file="$ledger_dir/review-artifacts.jsonl"

# Does this invocation CREATE a review artifact whose id we must record?
# Sets `matched_endpoint` as a side effect. Note `gh api` implies POST as
# soon as any -f/-F field is present, so requiring an explicit `-X POST`
# would miss exactly the calls the prompt tells agents to make.
matched_endpoint=""
is_review_post() {
  [ "$sub1" = "api" ] || return 1
  [ -n "$review_endpoint" ] || return 1
  if [ "$mutating" -eq 1 ] || is_write_method; then
    matched_endpoint="$review_endpoint"
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
  # One line, one write: an O_APPEND write of a short line is atomic
  # enough for concurrent reviewers appending to the same ledger.
  jq -cn \
    --arg ts "$ts" --arg login "$login" --arg endpoint "$endpoint" \
    --arg kind "$kind" --argjson id "$id" \
    '{ts:$ts, login:$login, endpoint:$endpoint, kind:$kind, id:$id}' \
    >> "$ledger_file" 2>/dev/null \
    || echo "lgtm-gh: ledger append failed; artifact unrecorded (reads as human)" >&2
  return 0
}

# Everything that is not a review-creating POST keeps the original exec
# path verbatim: same process replacement, same streaming, no capture.
# This wrapper mediates EVERY state-changing call lgtm makes, so the
# deviation below is confined to the calls whose ids we actually need.
if ! is_review_post; then
  # exec so GH_TOKEN lives only for gh's lifetime; the agent never sees it.
  exec env GH_TOKEN="$(cat "$token_file")" gh "$@"
fi

# Capture path. stdout is buffered to a temp file so the id can be read
# out of it, then replayed byte-for-byte; stderr is untouched and gh's
# exit code is preserved exactly.
tmp="$(mktemp 2>/dev/null)" || exec env GH_TOKEN="$(cat "$token_file")" gh "$@"
rc=0
set +o errexit
env GH_TOKEN="$(cat "$token_file")" gh "$@" > "$tmp"
rc=$?
set -o errexit
cat "$tmp"
# Only a successful call created an artifact worth recording.
if [ "$rc" -eq 0 ]; then
  record_artifact "$matched_endpoint" "$tmp"
fi
rm -f "$tmp"
exit "$rc"
