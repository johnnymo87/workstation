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

# Review-submission facts, for the approval gate (lgtm-f6ue). Read by
# classify_review below; the merge policy ignores them.
ev_vals=()       # every `event` value from a field flag, verbatim
ev_bad=0         # an event key this scan cannot read (event[...])
commit_ids=()    # every `commit_id` value from a field flag
field_count=0    # -f/-F/--field/--raw-field occurrences
input_count=0    # --input occurrences
input_idx=-1     # argv index of the (last) --input value, or of --input=VALUE
input_attached=0 # 1 when that index holds `--input=VALUE`
input_val=""
has_dashdash=0
rv_create_path=""  # a positional shaped like .../pulls/N/reviews
rv_events_path=""  # a positional shaped like .../pulls/N/reviews/ID/events
rv_paths=0
pr_approve=0     # `pr review` flags
pr_comment=0
pr_request=0

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

# A `key=value` field. `query` matters for graphql; `event` and `commit_id`
# for the approval gate. (A `-F event=@file` value needs no special case: the
# literal "@file" is never exactly COMMENT, so it is gated.)
scan_field() {
  local kv="$1" k v
  field_count=$((field_count + 1))
  k="${kv%%=*}"
  v="${kv#*=}"
  if [ "$k" = "query" ]; then
    case "$v" in
      @*) gql_opaque=1 ;;
      *)  gql_query="$gql_query $v" ;;
    esac
  fi
  case "$k" in
    event)      ev_vals+=("$v") ;;
    event\[*) ev_bad=1 ;;
    commit_id) commit_ids+=("$v") ;;
  esac
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
  # Deliberately LOOSE (any case, any prefix): a path the gate's strict parse
  # then cannot read is refused, which is the safe way for a near-miss to fail.
  local lower="${t,,}"
  if [[ "$lower" =~ (^|/)pulls/[^/]+/reviews/[^/]+/events$ ]]; then
    rv_events_path="$t"; rv_paths=$((rv_paths + 1))
  elif [[ "$lower" =~ (^|/)pulls/[^/]+/reviews$ ]]; then
    rv_create_path="$t"; rv_paths=$((rv_paths + 1))
  fi
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
  local a pending="" v i=-1
  for a in "$@"; do
    i=$((i + 1))
    case "$pending" in
      repo)   add_repo_hint "$a"; pending=""; continue ;;
      method) method="$a";        pending=""; continue ;;
      field)  scan_field "$a";    pending=""; continue ;;
      input)  gql_opaque=1; input_idx=$i; input_attached=0; input_val="$a"
              pending=""; continue ;;
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
      --input)                   pending=input; mutating=1; input_count=$((input_count + 1)) ;;
      --input=*)                 gql_opaque=1; mutating=1; input_count=$((input_count + 1))
                                 input_idx=$i; input_attached=1; input_val="${a#--input=}" ;;
      --disable-auto)            disable_auto=1 ;;
      --)                        has_dashdash=1 ;;
      # `pr review` event flags. Only read when the command IS `pr review`.
      -a|--approve|--approve=*)  pr_approve=1 ;;
      -c|--comment|--comment=*)  pr_comment=1 ;;
      -r|--request-changes|--request-changes=*) pr_request=1 ;;
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

# ---- approval gate (lgtm-f6ue) ---------------------------------------------
#
# WHY THIS EXISTS. Some repos (food-truck/mono) have teams whose code lgtm may
# never approve on its own. lgtm records, per PR head, whether the change is
# clear of those teams; `lgtm --approval-policy` reads that record back. This
# block is the enforcement: an APPROVE goes through only when that command says
# `clear` for the PR's LIVE head and every key in its answer matches. A refused
# session is told (by lgtm's own text, or the fallback below) to leave a COMMENT
# and stop, and the refusal is appended to gate-refusals.jsonl, which lgtm reads
# every cycle to page Jonathan. Design: lgtm bead lgtm-f6ue and lgtm repo
# docs/plans/2026-09-10-blocked-owner-enforcement-plan.md §7.
#
# A POSITIVE ALLOWLIST, NOT AN APPROVE BLOCKLIST. Approve spellings are not
# enumerable (field, --input body, stdin, /events, `pr review -a`, GraphQL), so
# the question asked is the other one: is the event PROVABLY COMMENT or
# REQUEST_CHANGES? Those are never touched, in any state. Everything else that
# submits a review -- APPROVE, no event (a PENDING review), a lowercase event,
# an event read from a file -- is gated, on every repo, because whether a repo
# is governed is itself part of lgtm's answer.
#
# THE LIVE HEAD, NOT THE WORKTREE'S. The head comes from GET pulls/N, never
# `git rev-parse HEAD`: on the reawaken path the worktree sits at the old sha by
# design, and a stale verdict would match a stale worktree. A clear APPROVE on a
# governed repo is then PINNED to that head with commit_id, so it cannot land on
# a commit pushed after the check.
#
# THE FLOOR. `gate_governed_floor` is unioned with lgtm's answer: a wrong
# lgtm.yml (lgtm-dwic) can make lgtm say "ungoverned" for mono, and the floor is
# what refuses that. It only ever ADDS refusals, so if it drifts behind lgtm.yml
# nothing is unprotected that lgtm protects; gate-floor-drift.jsonl records it.
#
# WHAT THIS IS NOT, same as the merge policy above: a security boundary. Plain
# `gh` bypasses it (an accepted gap, lgtm-3za8). It catches a CONFUSED session,
# and its strictness stops there -- see the cases deliberately left ungated.
#
# Exit codes: 3 policy (lgtm judged the head), 5 plumbing (could not judge).
# Never 4: gh already uses 4 for "authentication required".
#
# The pins and the lgtm invocation are one delimited block so test.sh can swap
# in a sandbox for exactly that and nothing else; test.sh also asserts this
# block byte for byte. Every pin must equal what lgtm ECHOES (payload.config:
# path is path.resolve()d, stateDir verbatim), or every approve is refused:
# literal, normalised, no $HOME. roundtrip.sh proves it against the live lgtm.
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

GATE_MARKER="lgtm-gh: refusing to approve"
gate_refusals_file="$state_dir/gate-refusals.jsonl"
gate_drift_file="$state_dir/gate-floor-drift.jsonl"

review_kind=""    # "" | create | events | pr-review | graphql
review_safe=0     # 1 = provably COMMENT / REQUEST_CHANGES: never gated
gh_args=("$@")    # what gh is finally run with (the gate may pin it)
cleanup_files=()  # temp files to remove; their presence forces the capture path
body_copy=""      # private copy of an --input body
body_bad=0        # that body could not be read as exactly one JSON object
body_ev_vals=()
body_commit_ids=()

# Submitting, not reading: explicit POST, or gh's implicit POST (a field or
# --input with no method). An undecomposable short cluster might hide -XPOST.
is_submission() {
  [ "$sub1" = api ] || return 1
  [ "$unknown_flag" -eq 0 ] || return 0
  case "${method^^}" in
    POST) return 0 ;;
    "")   [ "$mutating" -eq 1 ] ;;
    *)    return 1 ;;
  esac
}

# Copy an --input body (file, or stdin for `-`) somewhere private, read its
# top-level event/commit_id, and point gh at the copy -- so gh sends exactly
# the bytes that were classified, and a pin can be added without touching the
# session's own file.
copy_review_body() {
  local raw
  body_copy="$(mktemp 2>/dev/null)" || { body_bad=1; return 0; }
  cleanup_files+=("$body_copy")
  if [ "$input_val" = "-" ]; then
    cat > "$body_copy" 2>/dev/null || { body_bad=1; return 0; }
  else
    cat -- "$input_val" > "$body_copy" 2>/dev/null || { body_bad=1; return 0; }
  fi
  if [ "$input_attached" -eq 1 ]; then
    gh_args[input_idx]="--input=$body_copy"
  else
    gh_args[input_idx]="$body_copy"
  fi
  jq -e -s 'length == 1 and (.[0] | type) == "object"' < "$body_copy" >/dev/null 2>&1 \
    || { body_bad=1; return 0; }
  # --stream sees EVERY occurrence of a duplicated key; `.event` keeps the last.
  raw="$(jq -r --stream '
      select(length == 2 and (.[0][0] == "event" or .[0][0] == "commit_id"))
      | if (.[0] | length) != 1 or (.[1] | type) != "string" then "BAD"
        else (.[0][0]) + "\t" + .[1] end' < "$body_copy" 2>/dev/null)" || { body_bad=1; return 0; }
  local line
  while IFS= read -r line; do
    case "$line" in
      "") ;;
      BAD) body_bad=1 ;;
      event$'\t'*)     body_ev_vals+=("${line#event$'\t'}") ;;
      commit_id$'\t'*) body_commit_ids+=("${line#commit_id$'\t'}") ;;
      *) body_bad=1 ;;
    esac
  done <<<"$raw"
  return 0
}

# Every event seen, from fields and body together, must be exactly COMMENT or
# REQUEST_CHANGES -- and there must be at least one.
events_are_safe() {
  local v n=0
  [ "$ev_bad" -eq 0 ] && [ "$body_bad" -eq 0 ] || return 1
  for v in "${ev_vals[@]}" "${body_ev_vals[@]}"; do
    case "$v" in
      COMMENT|REQUEST_CHANGES) n=$((n + 1)) ;;
      *) return 1 ;;
    esac
  done
  [ "$n" -gt 0 ]
}

classify_review() {
  if [ "$sub1" = pr ] && [ "$sub2" = review ]; then
    review_kind=pr-review
    if [ "$pr_approve" -eq 0 ] && [ "$unknown_flag" -eq 0 ] \
       && { [ "$pr_comment" -eq 1 ] || [ "$pr_request" -eq 1 ]; }; then
      review_safe=1
    fi
    return 0
  fi
  [ "$sub1" = api ] || return 0
  if [ "$graphql_path" -eq 1 ]; then
    if [[ "$gql_query" =~ (addPullRequestReview|submitPullRequestReview)([^A-Za-z0-9_]|$) ]]; then
      review_kind=graphql
    fi
    return 0
  fi
  [ "$rv_paths" -gt 0 ] || return 0
  is_submission || return 0
  if [ -n "$rv_events_path" ]; then review_kind=events; else review_kind=create; fi
  if [ "$input_count" -eq 1 ]; then copy_review_body; fi
  if [ "$input_count" -le 1 ] && events_are_safe; then review_safe=1; fi
  return 0
}

# The refused PR, for the ledger and the messages. g_repo is the canonical
# name once the live-head read has supplied it.
g_repo=""
g_pr=""
g_head=""
g_requested=""
policy_err=/dev/null

# Best-effort, like record_denial: never the reason a refusal fails to happen.
# Writes nothing it knows the reader would reject (lgtm counts, and logs every
# cycle, each invalid line forever).
record_gate_refusal() {
  local class="$1" cause="$2" payload="${3:-null}" ts head="" req=""
  [[ "$g_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 0
  [[ "$g_pr" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$g_pr))" -gt 0 ] || return 0
  [[ "$g_head" =~ ^[0-9a-f]{40}$ ]] && head="$g_head"
  [[ "$g_requested" =~ ^[0-9a-f]{40}$ ]] && req="$g_requested"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn \
    --arg ts "$ts" --arg login "$login" --arg repo "$g_repo" --argjson pr "$((10#$g_pr))" \
    --arg head "$head" --arg req "$req" --arg class "$class" --arg cause "$cause" \
    --argjson p "$payload" '
      {ts: $ts, login: $login, repo: $repo, prNumber: $pr}
      + (if $head != "" then {head: $head} else {} end)
      + (if $req != "" then {requestedHead: $req} else {} end)
      + (if ($p | type) == "object"
         then ({reason: $p.reason, verdict: $p.verdict, warningClass: $p.warningClass}
               | with_entries(select((.value | type) == "string" and (.value | length) > 0)))
         else {} end)
      + {refusal: ({class: $class} + (if $cause != "" then {cause: $cause} else {} end))}' \
    >> "$gate_refusals_file" 2>/dev/null || true
  return 0
}

# The wrapper's OWN refusal text, for everything lgtm did not answer. It must
# carry the same instruction as lgtm's (gateRefusal.ts) and the review prompt:
# no retry, no re-route, one pinned COMMENT, stop.
gate_fallback() {
  local cause="$1" detail="$2" recorded="${3:-1}" payload="${4:-null}" where target
  if [ -n "$g_repo" ]; then where="$g_repo${g_pr:+#$g_pr}"
  elif [ -n "$g_pr" ]; then where="PR #$g_pr"
  else where="this PR"; fi
  target="repos/${g_repo:-OWNER/NAME}/pulls/${g_pr:-N}/reviews"
  if [ "$recorded" -eq 1 ]; then record_gate_refusal plumbing "$cause" "$payload"; fi
  {
    echo "$GATE_MARKER $where: $detail ($cause)."
    echo "lgtm-gh: this is not a judgement on the code -- the approval gate could not clear this approval. It is still final for this session."
    echo "lgtm-gh: do NOT retry the approval, and do NOT approve any other way: not plain gh, not gh pr review --approve, not the GraphQL API. Re-running anything will not change this answer."
    echo "lgtm-gh: instead, submit your review ONCE as event=COMMENT ('lgtm-gh api -X POST $target'), pinned with -f commit_id=<sha> to the commit you were dispatched to review (your instructions name it; never drop commit_id), and start its body with: Would approve; lgtm's ownership gate refused the approval: $cause."
    if [ "$recorded" -eq 1 ] && [ -n "$g_repo" ]; then
      echo "lgtm-gh: then end your session. Do not REQUEST_CHANGES to compensate (nothing is wrong with the code) and do not @-mention anyone. lgtm records this refusal and alerts a human."
    else
      echo "lgtm-gh: then end your session. Do not REQUEST_CHANGES to compensate and do not @-mention anyone. This refusal could NOT be recorded, so say in your final report that lgtm-gh refused the approval, and why."
    fi
  } >&2
  exit 5
}

# OWNER/NAME and N from a review path, or nothing.
parse_review_path() {
  local t="$1" re
  t="${t#https://api.github.com}"
  t="${t#/}"
  re='^repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pulls/([0-9]{1,9})/reviews(/[0-9]+/events)?$'
  if [[ "$t" =~ $re ]]; then
    g_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    g_pr="$((10#${BASH_REMATCH[3]}))"
    return 0
  fi
  return 1
}

floor_has() {
  local r
  for r in "${gate_governed_floor[@]}"; do
    [ "${r,,}" = "${1,,}" ] && return 0
  done
  return 1
}

# Any commit_id the session asked for that is not the live head -> the race the
# pin exists for. Checked only once the repo is known to be governed.
check_requested_head() {
  local c
  for c in "${commit_ids[@]}" "${body_commit_ids[@]}"; do
    if [ "${c,,}" != "$g_head" ]; then
      g_requested="${c,,}"
      gate_fallback head-mismatch "you asked to approve commit '$c', but the PR's head is now $g_head; that head has not been checked"
    fi
  done
}

gate_review() {
  local line live canon out rc decision floor_json payload_one
  case "$review_kind" in
    graphql)
      gate_fallback unsupported-surface "GraphQL review mutations name no repository, so this wrapper cannot check them" 0 ;;
    pr-review)
      resolve_repo
      g_repo="$target_repo"
      if [[ "$sub3" =~ ^#?([0-9]{1,9})$ ]]; then
        g_pr="$((10#${BASH_REMATCH[1]}))"
      elif [[ "$sub3" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/([0-9]{1,9})$ ]]; then
        g_pr="$((10#${BASH_REMATCH[1]}))"
      fi
      gate_fallback unsupported-surface "'gh pr review' cannot be pinned to the commit that was checked, so this wrapper does not approve through it" ;;
    events)
      parse_review_path "$rv_events_path" || true
      gate_fallback unsupported-surface "submitting a pending review cannot be checked against the PR's live head" ;;
  esac

  # create: POST .../pulls/N/reviews
  if [ "$rv_paths" -ne 1 ] || ! parse_review_path "$rv_create_path"; then
    g_repo=""; g_pr=""
    gate_fallback unresolvable-target "the repository and PR cannot be read from '$rv_create_path'; use repos/OWNER/NAME/pulls/N/reviews" 0
  fi
  if [ "$input_count" -gt 1 ] || [ "$has_dashdash" -eq 1 ] || [ "$body_bad" -eq 1 ] \
     || { [ "$input_count" -eq 1 ] && [ "$field_count" -gt 0 ]; }; then
    gate_fallback unparseable-event "the review event cannot be determined from this command line (one --input body with no field flags, or field flags alone)"
  fi

  # The live head, and the repository's canonical name (which also settles a
  # renamed repo: GitHub answers under the new name).
  line="$(timeout -k 2 20 env GH_TOKEN="$(cat "$token_file")" gh api "repos/$g_repo/pulls/$g_pr" \
            --jq '.head.sha + " " + .base.repo.full_name' 2>/dev/null)" || line=""
  live="${line%% *}"
  canon="${line#* }"
  if ! [[ "$live" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$canon" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    gate_fallback live-head-unreadable "the PR's current head could not be read from GitHub"
  fi
  g_head="$live"
  g_repo="$canon"

  if floor_has "$g_repo"; then check_requested_head; fi

  set +o errexit
  policy_err="$(mktemp 2>/dev/null)" || policy_err=/dev/null
  [ "$policy_err" = /dev/null ] || cleanup_files+=("$policy_err")
  out="$(run_approval_policy "$g_repo#$g_pr" "$g_head" 2>"$policy_err")"
  rc=$?
  set -o errexit

  floor_json="$(printf '%s\n' "${gate_governed_floor[@]}" | jq -R 'ascii_downcase' | jq -sc .)"
  decision="$(printf '%s' "$out" | jq -rs \
      --arg repo "$g_repo" --argjson pr "$g_pr" --arg head "$g_head" \
      --arg cfg "$gate_lgtm_config" --arg sd "$gate_lgtm_state_dir" \
      --argjson floor "$floor_json" --argjson rc "$rc" '
    if length != 1 or (.[0] | type) != "object" then "nodoc"
    else .[0] as $p
    | if ($p.repo | type) != "string" or ($p.repo | ascii_downcase) != ($repo | ascii_downcase)
         or ($p.prNumber | type) != "number" or $p.prNumber != $pr or $p.head != $head
      then "mismatch"
      elif ($p.config | type) != "object" or $p.config.path != $cfg or $p.config.stateDir != $sd
           or ($p.config.governedRepos | type) != "array"
      then "untrusted"
      else [$p.config.governedRepos[] | strings | ascii_downcase] as $gr
      | ($gr | index($repo | ascii_downcase)) as $listed
      | ($floor | index($repo | ascii_downcase)) as $onfloor
      | if $rc == 0 and $p.governed == true and $listed != null and $p.verdict == "clear"
        then "allow-governed"
        elif $rc == 0 and $p.governed == false and $p.verdict == "ungoverned"
             and $listed == null and $onfloor == null and (($floor - $gr) | length) == 0
        then "allow-ungoverned"
        elif $p.governed == true and $listed != null and $p.verdict != "clear"
             and ($p.refusal | type) == "object"
             and ($p.refusal.class == "policy" or $p.refusal.class == "plumbing")
             and ($p.refusal.message | type) == "array" and ($p.refusal.message | length) > 0
             and all($p.refusal.message[]; type == "string")
        then "refuse-" + $p.refusal.class
        elif $rc != 0 and ($p.verdict == "clear" or $p.verdict == "ungoverned") then "failed"
        else "untrusted" end
      end
    end' 2>/dev/null)" || decision="nodoc"

  payload_one="null"
  case "$decision" in
    nodoc|mismatch|"") ;;
    *) payload_one="$(printf '%s' "$out" | jq -c . 2>/dev/null)" || payload_one="null"
       record_floor_drift "$payload_one" ;;
  esac

  # Anything but an allow keeps lgtm's own stderr, so that if the gate ever
  # starts refusing every approve (a broken checkout, an empty scope, a bad
  # PAT) the operator deciding whether to roll back can see WHY. Never shown
  # to the session: it is not lgtm's refusal text.
  case "$decision" in
    allow-*) ;;
    *) record_policy_stderr "$rc" "$decision" ;;
  esac

  case "$decision" in
    allow-governed)
      check_requested_head
      pin_to_live_head
      return 0 ;;
    allow-ungoverned)
      return 0 ;;
    refuse-policy|refuse-plumbing)
      record_gate_refusal "${decision#refuse-}" "" "$payload_one"
      printf '%s' "$payload_one" | jq -r '.refusal.message[]' >&2
      if [ "$decision" = refuse-policy ]; then exit 3; fi
      exit 5 ;;
    mismatch)
      gate_fallback payload-mismatch "lgtm's answer is about a different repository, PR or head than the one asked about" ;;
    untrusted)
      # No payload copied: an untrusted answer's `reason` must not decide how
      # the reader classifies the page (a copied no-verdict-for-head would be
      # held as a race).
      gate_fallback answer-untrusted "lgtm's answer cannot be trusted (wrong or missing config echo, or it contradicts the governed floor)" ;;
    *)
      gate_fallback policy-command-failed "lgtm --approval-policy did not give a usable answer (exit $rc)" 1 "$payload_one" ;;
  esac
}

record_policy_stderr() {
  local rc="$1" decision="$2"
  [ -s "$policy_err" ] || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  {
    printf '%s %s#%s head=%s rc=%s decision=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$g_repo" "$g_pr" "$g_head" "$rc" "$decision"
    tail -n 20 "$policy_err" | sed 's/^/  /'
  } >> "$state_dir/gate-errors.log" 2>/dev/null || true
  return 0
}

# Item (7) of lgtm-dwic: lgtm governs a repo this file's floor does not list.
# Recorded, never refused and never shown to the session.
record_floor_drift() {
  local p="$1" extra
  extra="$(printf '%s' "$p" | jq -c --argjson floor "$floor_json" \
    '[(.config.governedRepos // [])[] | strings | ascii_downcase] - $floor' 2>/dev/null)" || return 0
  [ -n "$extra" ] && [ "$extra" != "[]" ] || return 0
  mkdir -p "$state_dir" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson extra "$extra" \
    '{ts: $ts, extra: $extra}' >> "$gate_drift_file" 2>/dev/null || true
  return 0
}

# Governed allow: the approval must land on the commit that was checked.
pin_to_live_head() {
  local pinned
  if [ "${#commit_ids[@]}" -gt 0 ] || [ "${#body_commit_ids[@]}" -gt 0 ]; then
    return 0  # already present, and check_requested_head proved it is the live head
  fi
  if [ "$input_count" -eq 1 ]; then
    pinned="$(mktemp 2>/dev/null)" || gate_fallback policy-command-failed "could not pin the approval to the checked commit"
    cleanup_files+=("$pinned")
    jq --arg c "$g_head" '. + {commit_id: $c}' < "$body_copy" > "$pinned" 2>/dev/null \
      || gate_fallback policy-command-failed "could not pin the approval to the checked commit"
    if [ "$input_attached" -eq 1 ]; then
      gh_args[input_idx]="--input=$pinned"
    else
      gh_args[input_idx]="$pinned"
    fi
  else
    gh_args+=(-f "commit_id=$g_head")
  fi
}

trap 'rm -f "${cleanup_files[@]}"' EXIT
classify_review
if [ -n "$review_kind" ] && [ "$review_safe" -eq 0 ]; then
  gate_review
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
# A temp body (the gate's --input copy) must outlive gh and then be removed, so
# its presence also forces the non-exec path.
if ! is_review_post && [ "${#cleanup_files[@]}" -eq 0 ]; then
  # exec so GH_TOKEN lives only for gh's lifetime; the agent never sees it.
  exec env GH_TOKEN="$(cat "$token_file")" gh "${gh_args[@]}"
fi

# Capture path. stdout is buffered to a temp file so the id can be read
# out of it, then replayed byte-for-byte; stderr is untouched and gh's
# exit code is preserved exactly.
tmp="$(mktemp 2>/dev/null)" || exec env GH_TOKEN="$(cat "$token_file")" gh "${gh_args[@]}"
cleanup_files+=("$tmp")
rc=0
set +o errexit
env GH_TOKEN="$(cat "$token_file")" gh "${gh_args[@]}" > "$tmp"
rc=$?
set -o errexit
cat "$tmp"
# Only a successful call created an artifact worth recording.
# (matched_endpoint is empty when the capture path was forced only by a temp
# body -- e.g. a SAFE /events submission -- which is not an artifact to record.)
if [ "$rc" -eq 0 ] && [ -n "$matched_endpoint" ]; then
  record_artifact "$matched_endpoint" "$tmp"
fi
rm -f "$tmp"
exit "$rc"
