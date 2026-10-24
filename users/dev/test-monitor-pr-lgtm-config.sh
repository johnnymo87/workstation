#!/usr/bin/env bash
# Guard: monitor-pr.py's lgtm.yml reader must agree with lgtm's own
# `filterByAuthors` (lgtm/src/discover.ts) about which PRs are lgtm-bound.
#
# WHY THIS EXISTS
#
# `_parse_lgtm_config` is a hand-rolled, indentation-based YAML-ish reader
# (stdlib-only on purpose -- the interpreter that runs this script has no
# PyYAML, and the script is deployed as a bare file by home-manager, not as a
# packaged derivation with dependencies). A hand-rolled reader silently
# mis-classifies config shapes it was not written for, and every such miss is
# a `lgtm-bound: False` on a PR that IS bound -- the unbounded-cost direction
# the skill warns about, because the session then stops shepherding.
#
# The shape that broke it (found 2026-08-31): a repo written as an INLINE
# EMPTY MAPPING, which is how two live repos are configured:
#
#     globex/ops-server: {}
#
# The key pattern required the line to END after the colon, so that repo was
# never seen as listed at all. The same pattern also hid `allAuthors: true`.
#
# These assertions call the parser directly against fixture configs rather
# than going through `gh`, so they are hermetic and fast.
#
# Run: bash users/dev/test-monitor-pr-lgtm-config.sh
set -o errexit -o nounset -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

SCRIPT="assets/opencode/skills/shepherding-pull-requests/monitor-pr.py"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A fixture that mirrors the SHAPES used by the real ~/projects/lgtm/lgtm.yml:
# block-form repos, an inline empty mapping, a repo-scoped author list, an
# inline nested mapping (`ownerReviewers`), `allAuthors: true`, and comments --
# plus the inline variants of each, which are the shapes that broke.
cat > "$tmp/lgtm.yml" <<'YAML'
reviewers:
  - johnnymo87
  - reviewer-k

authors:
  - author-p
  # a comment: with a colon in it
  - ELang7
  - commented-author  # temporarily allowlisted, remove after PROJ-1234
  - 'quoted-block-author'
  - hash#in#login
  - no-space-before-hash #comment
  - "spaced # scalar"

# Block style with an interleaved comment, matching how the real lgtm.yml
# writes this list. The flow-style spelling is covered by the third fixture
# below. (No TRAILING comments here: those are PR #435's subject, and a test
# that depends on an unmerged branch reports the wrong thing on this one.)
onRequestAuthors:
  # Reviewed only when a review is requested; never proactively swept.
  - author-r
  - second-on-request-author

repos:
  acme/monorepo:
    authors:
      - author-c
      - repo-commented-author  # same shape, one level deeper
    paths:
      - acme/platform-team
    ownerReviewers:
      # A sentinel login that is in NO author list: if ownerReviewers values
      # ever leak into the author union, only a login like this can show it.
      supplychain: [owner-reviewer-sentinel]
      consumer-team: [johnnymo87]

  acme/js-repo:
    allAuthors: True

  # Inline non-empty mapping: `{}` is the empty case of a form that can carry
  # settings, so the reader must not read the empty one and drop this one.
  acme/inline-settings: {allAuthors: true}
  acme/inline-authors: {authors: [inline-only-author]}

  globex/ops-server: {}
  globex/frontends:
    authors: [flow-style-author]
  globex/chef-app: {}
YAML

# Driver: import monitor-pr.py by path, repoint LGTM_CONFIG_PATH at a fixture,
# and print one `case=verdict` line per assertion.
cat > "$tmp/drive.py" <<'PY'
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("monitor_pr", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.LGTM_CONFIG_PATH = Path(sys.argv[2])

def check(name, got, want):
    print(f"{name}={'PASS' if got == want else f'FAIL(got={got!r} want={want!r})'}")

d = mod.detect_lgtm_bound

# --- The bug: inline empty mapping (`{}`) is still a listed repo. ----------
check("inline-empty-repo-listed-author-global",
      d("globex", "ops-server", "author-p"), True)
check("inline-empty-repo-listed-author-reviewer",
      d("globex", "chef-app", "johnnymo87"), True)
check("inline-empty-repo-unknown-author",
      d("globex", "ops-server", "nobody-at-all"), False)

# --- No regression on the block form that already worked. -----------------
check("block-repo-global-author", d("acme", "monorepo", "author-p"), True)
check("block-repo-reviewer-is-author", d("acme", "monorepo", "reviewer-k"), True)
check("block-repo-scoped-author", d("acme", "monorepo", "author-c"), True)
check("block-repo-unknown-author", d("acme", "monorepo", "stranger"), False)

# --- A block list item keeps its login when the line carries a comment. ---
# YAML ends a scalar at ` #`, so these are the logins `commented-author` and
# `repo-commented-author`. A reader that requires the item to be the last
# thing on the line drops them silently, and silently dropping a login is a
# `lgtm-bound: False` on a PR lgtm reviews.
check("block-item-trailing-comment",
      d("acme", "monorepo", "commented-author"), True)
check("block-item-trailing-comment-repo-scoped",
      d("acme", "monorepo", "repo-commented-author"), True)
check("block-item-trailing-comment-repo-scoped-does-not-leak",
      d("globex", "chef-app", "repo-commented-author"), False)
check("block-item-quoted", d("acme", "monorepo", "quoted-block-author"), True)
# `#` NOT preceded by whitespace does not start a YAML comment, so the login
# is the whole token -- truncating at the first `#` would invent a login.
check("block-item-hash-without-space", d("acme", "monorepo", "hash#in#login"), True)
check("block-item-hash-not-truncated", d("acme", "monorepo", "hash"), False)
# The comment text itself must not become a login.
check("block-item-comment-text-not-an-author",
      d("acme", "monorepo", "temporarily"), False)
# One space before `#` is enough to start a YAML comment; none is required
# after it.
check("block-item-no-space-after-hash",
      d("acme", "monorepo", "no-space-before-hash"), True)
# A quoted scalar containing ` # ` is ONE scalar, not a login plus a comment.
# Capturing the prefix would invent the login `spaced` out of a line that
# names nobody -- and an invented login that happens to match the PR author
# makes the loop wait for an approval that cannot arrive.
check("quoted-scalar-with-hash-not-split",
      d("acme", "monorepo", "spaced"), False)

# A repo-scoped author must NOT leak to another repo (the union is
# global ∪ reviewers ∪ repos[R].authors -- R, not every R).
check("repo-scoped-author-does-not-leak",
      d("globex", "ops-server", "author-c"), False)

# Unlisted repo is never bound, whatever the author.
check("unlisted-repo", d("acme", "not-a-repo", "author-p"), False)

# Unknown author fails toward NOT-bound (documented in detect_lgtm_bound).
check("no-author-login", d("acme", "monorepo", None), False)

# --- allAuthors: true admits any human author in that repo only. ----------
check("all-authors-admits-stranger",
      d("acme", "js-repo", "stranger"), True)
check("all-authors-excludes-bot",
      d("acme", "js-repo", "dependabot[bot]"), False)
check("all-authors-does-not-leak",
      d("acme", "monorepo", "stranger"), False)

# --- Nested inline mappings must not be mistaken for repos or authors. ----
# `supplychain: [owner-reviewer-sentinel]` under ownerReviewers sits at
# repo-sub depth: it is neither a repo nor an author entry, and neither its
# key nor its value may reach the author union.
check("owner-reviewers-key-not-an-author",
      d("acme", "monorepo", "supplychain"), False)
check("owner-reviewers-value-not-an-author",
      d("acme", "monorepo", "owner-reviewer-sentinel"), False)

# --- Inline mappings that CARRY settings, not just `{}`. ------------------
check("inline-map-all-authors",
      d("acme", "inline-settings", "stranger"), True)
check("inline-map-all-authors-excludes-bot",
      d("acme", "inline-settings", "renovate"), False)
check("inline-map-repo-authors",
      d("acme", "inline-authors", "inline-only-author"), True)
check("inline-map-repo-authors-do-not-leak",
      d("acme", "monorepo", "inline-only-author"), False)
check("inline-map-repo-authors-reject-stranger",
      d("acme", "inline-authors", "stranger"), False)

# --- Flow sequences as author lists, at both indents. --------------------
# (These two logins are onRequestAuthors, so they need the request -- see the
# on-request section below for why.)
check("block-list-on-request-author",
      d("acme", "monorepo", "author-r", pool_engaged=True), True)
check("block-list-second-on-request-author",
      d("acme", "monorepo", "second-on-request-author", pool_engaged=True), True)
check("flow-list-repo-author",
      d("globex", "frontends", "flow-style-author"), True)
check("flow-list-repo-author-does-not-leak",
      d("acme", "monorepo", "flow-style-author"), False)

# --- onRequestAuthors bind only when a pool reviewer is engaged. ----------
# lgtm admits these logins in the two review-REQUESTED lanes only (tier 0 and
# tier 1, both keyed on `user-review-requested:`); the proactive tier-2 sweep
# passes `config.authors` WITHOUT them (discover.ts:238). So on a PR nobody
# requested a reviewer on, no dispatch can ever happen -- and reporting it
# lgtm-bound makes the loop wait for an approval that cannot arrive, which is
# the unbounded mistake, not the recoverable one.
check("on-request-author-without-request",
      d("acme", "monorepo", "author-r"), False)
check("on-request-author-with-request",
      d("acme", "monorepo", "author-r", pool_engaged=True), True)
# An ordinary allowlisted author needs no request: the proactive sweep covers
# them. Gating everyone on a request would be the opposite error.
check("global-author-needs-no-request",
      d("acme", "monorepo", "author-p", pool_engaged=False), True)
check("reviewer-as-author-needs-no-request",
      d("acme", "monorepo", "reviewer-k", pool_engaged=False), True)
check("repo-scoped-author-needs-no-request",
      d("acme", "monorepo", "author-c", pool_engaged=False), True)
# A request does not admit an author who is in no list at all.
check("request-does-not-admit-stranger",
      d("acme", "monorepo", "stranger", pool_engaged=True), False)
# allAuthors still admits humans in its repo without any request.
check("all-authors-needs-no-request",
      d("acme", "js-repo", "stranger", pool_engaged=False), True)
# ...including an on-request author, who is swept there like anybody else:
# `allAuthors` is inside filterByAuthors, so it admits in EVERY lane. Gating
# him on a request would be a false negative on a PR lgtm really does review.
check("all-authors-beats-on-request-gate",
      d("acme", "js-repo", "author-r", pool_engaged=False), True)
# But a bot is still excluded there, request or not.
check("all-authors-still-excludes-bot-with-request",
      d("acme", "js-repo", "renovate", pool_engaged=True), False)

# --- Engagement is computed from the PR payload, not guessed. -------------
# The pool is lgtm's `reviewers:` list; a request for one of them, or a review
# already submitted by one, means the request-only lane can fire.
e = mod.pool_reviewer_engaged
pool_pr = lambda requested, reviewed: {
    "reviewRequests": [{"login": r} for r in requested],
    "latestReviews": [{"author": {"login": r}} for r in reviewed],
}
check("engaged-nothing-requested", e(pool_pr([], []), {"johnnymo87"}), False)
check("engaged-pool-requested", e(pool_pr(["johnnymo87"], []), {"johnnymo87"}), True)
check("engaged-non-pool-requested",
      e(pool_pr(["someone-else"], []), {"johnnymo87"}), False)
# A pool member who already reviewed is proof the lane fired, even though the
# request that triggered it has been consumed and is no longer listed.
check("engaged-pool-already-reviewed",
      e(pool_pr([], ["johnnymo87"]), {"johnnymo87"}), True)
check("engaged-non-pool-reviewed",
      e(pool_pr([], ["someone-else"]), {"johnnymo87"}), False)
# Team review requests have no `login`; they must not crash or count.
check("engaged-team-request-ignored",
      e({"reviewRequests": [{"name": "some-team"}], "latestReviews": []},
        {"johnnymo87"}), False)
check("engaged-missing-fields", e({}, {"johnnymo87"}), False)

# --- The pool must be EXTRACTED from the config, not assumed. -------------
# Every assertion above hands `pool_engaged` or the pool in as a literal, so
# none of them would go red if the `reviewers:` bucket rotted out of the
# parser. The pool would come back empty, pool_reviewer_engaged would return
# False forever, and the gate would look like it was working.
check("reviewer-pool-extracted",
      mod.lgtm_reviewer_pool("acme", "monorepo"), {"johnnymo87", "reviewer-k"})
missing_cfg, mod.LGTM_CONFIG_PATH = mod.LGTM_CONFIG_PATH, Path("/nonexistent/lgtm.yml")
check("reviewer-pool-absent-config", mod.lgtm_reviewer_pool("x", "y"), set())
check("absent-config-not-bound", d("acme", "monorepo", "author-p"), False)
mod.LGTM_CONFIG_PATH = missing_cfg

# --- The main() wiring: which side of the trigger, and when. --------------
# lgtm keys its request lanes on its OWN login, so a request for a different
# pool member must NOT bind. This is the whole reason the daemon login is
# resolved at all, and nothing above would notice if the wiring dropped it.
calls = []
def fake_daemon(cmd):
    calls.append(cmd)
    return "johnnymo87\n"
real_run_cmd, mod.run_cmd = mod.run_cmd, fake_daemon
pr_of = lambda author, requested, reviewed: {
    "author": {"login": author},
    "reviewRequests": [{"login": r} for r in requested],
    "latestReviews": [{"author": {"login": r}} for r in reviewed],
}
b = lambda pr: mod.lgtm_bound_for_pr("acme", "monorepo", pr)
check("wiring-on-request-no-request", b(pr_of("author-r", [], [])), False)
check("wiring-on-request-daemon-requested",
      b(pr_of("author-r", ["johnnymo87"], [])), True)
check("wiring-on-request-other-pool-member-requested",
      b(pr_of("author-r", ["reviewer-k"], [])), False)
# ...but a pool member who ALREADY REVIEWED binds whoever they are: lgtm
# dispatches under a rotating pool identity, so the review that consumed the
# request need not be the daemon's.
check("wiring-on-request-other-pool-member-reviewed",
      b(pr_of("author-r", [], ["reviewer-k"])), True)
# An ordinary author must not pay for a `gh api user` round-trip at all.
calls.clear()
check("wiring-ordinary-author-bound", b(pr_of("author-p", [], [])), True)
check("wiring-ordinary-author-skips-daemon-lookup", calls, [])
mod.run_cmd = real_run_cmd

# --- The fields the engagement test reads must actually be FETCHED. -------
# A helper that reads a key `gh pr view --json` never asked for returns False
# forever and looks like a working gate.
requested_fields = []
def fake_run_cmd(cmd):
    requested_fields.append(cmd[cmd.index("--json") + 1])
    return '{"number":1}'
real_run_cmd, mod.run_cmd = mod.run_cmd, fake_run_cmd
mod.get_pr_info(1)
mod.run_cmd = real_run_cmd
fields = requested_fields[0].split(",")
check("pr-info-fetches-review-requests", "reviewRequests" in fields, True)
check("pr-info-fetches-latest-reviews", "latestReviews" in fields, True)

# --- Back-compat: no author config at all means no author filtering. ------
mod.LGTM_CONFIG_PATH = Path(sys.argv[3])
check("no-author-config-admits-anyone", d("globex", "chef-app", "stranger"), True)
check("no-author-config-still-needs-repo", d("globex", "nope", "stranger"), False)

# --- The same admissions, written in flow style. -------------------------
# The main fixture writes the global lists block-style because the real
# lgtm.yml does. Both spellings reach the same accumulators, and a fixture
# only proves the shapes someone thought to write down.
mod.LGTM_CONFIG_PATH = Path(sys.argv[4])
check("flow-globals-author", d("acme", "monorepo", "author-p"), True)
check("flow-globals-reviewer-is-author", d("acme", "monorepo", "reviewer-k"), True)
check("flow-globals-pool-extracted",
      mod.lgtm_reviewer_pool("acme", "monorepo"), {"johnnymo87", "reviewer-k"})
check("flow-globals-on-request-gated", d("acme", "monorepo", "author-r"), False)
check("flow-globals-on-request-with-request",
      d("acme", "monorepo", "author-r", pool_engaged=True), True)
PY

# Second fixture for the back-compat rule: repos, but zero author config.
cat > "$tmp/lgtm-noauthors.yml" <<'YAML'
reviewers:
  - johnnymo87

repos:
  globex/chef-app: {}
  acme/monorepo:
    paths:
      - acme/platform-team
YAML

# Third fixture: the same global lists, spelled in flow style.
cat > "$tmp/lgtm-flow.yml" <<'YAML'
reviewers: [johnnymo87, 'reviewer-k']
authors: [author-p, ELang7]
onRequestAuthors: [author-r]

repos:
  acme/monorepo: {}
YAML

out=$(python3 "$tmp/drive.py" "$SCRIPT" "$tmp/lgtm.yml" "$tmp/lgtm-noauthors.yml" "$tmp/lgtm-flow.yml")
echo "$out"

fail=0
while read -r line; do
  case "$line" in
    *=PASS) ;;
    *) echo "FAIL: $line" >&2; fail=1 ;;
  esac
done <<<"$out"

# Vacuity guard: the driver must actually have produced assertions. `|| true`
# because grep exits 1 on zero matches, and under errexit that would kill the
# script before it could print the diagnostic explaining why.
count=$(grep -c '=' <<<"$out" || true)
if [ "$count" -lt 67 ]; then
  echo "FAIL: expected >=67 assertions, got $count (driver did not run?)" >&2
  fail=1
fi

# --- Drift check against the REAL config, when one is present. -------------
# The fixtures above are hand-written shapes, and a fixture only proves the
# parser handles shapes someone thought to write down -- which is exactly how
# `{}` stayed invisible. So when ~/projects/lgtm/lgtm.yml exists (it does not
# inside the nix sandbox, and does not on devbox), assert that EVERY repo it
# lists is seen as listed. The repo keys are extracted by a separate, cruder
# regex so the check is not the parser grading its own homework.
real="$HOME/projects/lgtm/lgtm.yml"
if [ -f "$real" ]; then
  if ! python3 - "$SCRIPT" "$real" <<'PY'
import importlib.util, re, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("monitor_pr", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.LGTM_CONFIG_PATH = Path(sys.argv[2])
text = Path(sys.argv[2]).read_text().splitlines()
in_repos, missing, seen = False, [], 0
for line in text:
    if re.match(r"^\S", line):
        in_repos = line.startswith("repos:")
    elif in_repos:
        m = re.match(r"^  ([\w.-]+/[\w.-]+):", line)
        if m:
            seen += 1
            owner, _, repo = m.group(1).partition("/")
            if not mod._parse_lgtm_config(owner, repo).repo_listed:
                missing.append(m.group(1))
if not seen:
    print("FAIL: real lgtm.yml has no repos: entries -- extractor is broken")
    sys.exit(1)
if missing:
    print(f"FAIL: parser does not see these listed repos: {missing}")
    sys.exit(1)
print(f"OK: all {seen} repos in {sys.argv[2]} parse as listed")
PY
  then
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: monitor-pr.py lgtm.yml parser disagrees with lgtm's filterByAuthors" >&2
  exit 1
fi

echo "OK: $count lgtm.yml parser assertions passed"
