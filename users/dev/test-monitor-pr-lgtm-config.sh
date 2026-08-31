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
#     blueapron/culinary-operations-server: {}
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
  - Krosantos

authors:
  - pfarina
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
  - ratnikov
  - second-on-request-author

repos:
  food-truck/mono:
    authors:
      - camden-wonder
      - repo-commented-author  # same shape, one level deeper
    paths:
      - wonder/blueapron
    ownerReviewers:
      # A sentinel login that is in NO author list: if ownerReviewers values
      # ever leak into the author union, only a login like this can show it.
      supplychain: [owner-reviewer-sentinel]
      ba-consumer: [johnnymo87]

  food-truck/salmon-of-knowledge:
    allAuthors: True

  # Inline non-empty mapping: `{}` is the empty case of a form that can carry
  # settings, so the reader must not read the empty one and drop this one.
  food-truck/inline-settings: {allAuthors: true}
  food-truck/inline-authors: {authors: [inline-only-author]}

  blueapron/culinary-operations-server: {}
  blueapron/internal-frontends:
    authors: [flow-style-author]
  blueapron/bluechef: {}
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
      d("blueapron", "culinary-operations-server", "pfarina"), True)
check("inline-empty-repo-listed-author-reviewer",
      d("blueapron", "bluechef", "johnnymo87"), True)
check("inline-empty-repo-unknown-author",
      d("blueapron", "culinary-operations-server", "nobody-at-all"), False)

# --- No regression on the block form that already worked. -----------------
check("block-repo-global-author", d("food-truck", "mono", "pfarina"), True)
check("block-repo-reviewer-is-author", d("food-truck", "mono", "Krosantos"), True)
check("block-repo-scoped-author", d("food-truck", "mono", "camden-wonder"), True)
check("block-repo-unknown-author", d("food-truck", "mono", "stranger"), False)

# --- A block list item keeps its login when the line carries a comment. ---
# YAML ends a scalar at ` #`, so these are the logins `commented-author` and
# `repo-commented-author`. A reader that requires the item to be the last
# thing on the line drops them silently, and silently dropping a login is a
# `lgtm-bound: False` on a PR lgtm reviews.
check("block-item-trailing-comment",
      d("food-truck", "mono", "commented-author"), True)
check("block-item-trailing-comment-repo-scoped",
      d("food-truck", "mono", "repo-commented-author"), True)
check("block-item-trailing-comment-repo-scoped-does-not-leak",
      d("blueapron", "bluechef", "repo-commented-author"), False)
check("block-item-quoted", d("food-truck", "mono", "quoted-block-author"), True)
# `#` NOT preceded by whitespace does not start a YAML comment, so the login
# is the whole token -- truncating at the first `#` would invent a login.
check("block-item-hash-without-space", d("food-truck", "mono", "hash#in#login"), True)
check("block-item-hash-not-truncated", d("food-truck", "mono", "hash"), False)
# The comment text itself must not become a login.
check("block-item-comment-text-not-an-author",
      d("food-truck", "mono", "temporarily"), False)
# One space before `#` is enough to start a YAML comment; none is required
# after it.
check("block-item-no-space-after-hash",
      d("food-truck", "mono", "no-space-before-hash"), True)
# A quoted scalar containing ` # ` is ONE scalar, not a login plus a comment.
# Capturing the prefix would invent the login `spaced` out of a line that
# names nobody -- and an invented login that happens to match the PR author
# makes the loop wait for an approval that cannot arrive.
check("quoted-scalar-with-hash-not-split",
      d("food-truck", "mono", "spaced"), False)

# A repo-scoped author must NOT leak to another repo (the union is
# global ∪ reviewers ∪ repos[R].authors -- R, not every R).
check("repo-scoped-author-does-not-leak",
      d("blueapron", "culinary-operations-server", "camden-wonder"), False)

# Unlisted repo is never bound, whatever the author.
check("unlisted-repo", d("food-truck", "not-a-repo", "pfarina"), False)

# Unknown author fails toward NOT-bound (documented in detect_lgtm_bound).
check("no-author-login", d("food-truck", "mono", None), False)

# --- allAuthors: true admits any human author in that repo only. ----------
check("all-authors-admits-stranger",
      d("food-truck", "salmon-of-knowledge", "stranger"), True)
check("all-authors-excludes-bot",
      d("food-truck", "salmon-of-knowledge", "dependabot[bot]"), False)
check("all-authors-does-not-leak",
      d("food-truck", "mono", "stranger"), False)

# --- Nested inline mappings must not be mistaken for repos or authors. ----
# `supplychain: [owner-reviewer-sentinel]` under ownerReviewers sits at
# repo-sub depth: it is neither a repo nor an author entry, and neither its
# key nor its value may reach the author union.
check("owner-reviewers-key-not-an-author",
      d("food-truck", "mono", "supplychain"), False)
check("owner-reviewers-value-not-an-author",
      d("food-truck", "mono", "owner-reviewer-sentinel"), False)

# --- Inline mappings that CARRY settings, not just `{}`. ------------------
check("inline-map-all-authors",
      d("food-truck", "inline-settings", "stranger"), True)
check("inline-map-all-authors-excludes-bot",
      d("food-truck", "inline-settings", "renovate"), False)
check("inline-map-repo-authors",
      d("food-truck", "inline-authors", "inline-only-author"), True)
check("inline-map-repo-authors-do-not-leak",
      d("food-truck", "mono", "inline-only-author"), False)
check("inline-map-repo-authors-reject-stranger",
      d("food-truck", "inline-authors", "stranger"), False)

# --- Flow sequences as author lists, at both indents. --------------------
# (These two logins are onRequestAuthors, so they need the request -- see the
# on-request section below for why.)
check("block-list-on-request-author",
      d("food-truck", "mono", "ratnikov", pool_engaged=True), True)
check("block-list-second-on-request-author",
      d("food-truck", "mono", "second-on-request-author", pool_engaged=True), True)
check("flow-list-repo-author",
      d("blueapron", "internal-frontends", "flow-style-author"), True)
check("flow-list-repo-author-does-not-leak",
      d("food-truck", "mono", "flow-style-author"), False)

# --- onRequestAuthors bind only when a pool reviewer is engaged. ----------
# lgtm admits these logins in the two review-REQUESTED lanes only (tier 0 and
# tier 1, both keyed on `user-review-requested:`); the proactive tier-2 sweep
# passes `config.authors` WITHOUT them (discover.ts:238). So on a PR nobody
# requested a reviewer on, no dispatch can ever happen -- and reporting it
# lgtm-bound makes the loop wait for an approval that cannot arrive, which is
# the unbounded mistake, not the recoverable one.
check("on-request-author-without-request",
      d("food-truck", "mono", "ratnikov"), False)
check("on-request-author-with-request",
      d("food-truck", "mono", "ratnikov", pool_engaged=True), True)
# An ordinary allowlisted author needs no request: the proactive sweep covers
# them. Gating everyone on a request would be the opposite error.
check("global-author-needs-no-request",
      d("food-truck", "mono", "pfarina", pool_engaged=False), True)
check("reviewer-as-author-needs-no-request",
      d("food-truck", "mono", "Krosantos", pool_engaged=False), True)
check("repo-scoped-author-needs-no-request",
      d("food-truck", "mono", "camden-wonder", pool_engaged=False), True)
# A request does not admit an author who is in no list at all.
check("request-does-not-admit-stranger",
      d("food-truck", "mono", "stranger", pool_engaged=True), False)
# allAuthors still admits humans in its repo without any request.
check("all-authors-needs-no-request",
      d("food-truck", "salmon-of-knowledge", "stranger", pool_engaged=False), True)
# ...including an on-request author, who is swept there like anybody else:
# `allAuthors` is inside filterByAuthors, so it admits in EVERY lane. Gating
# him on a request would be a false negative on a PR lgtm really does review.
check("all-authors-beats-on-request-gate",
      d("food-truck", "salmon-of-knowledge", "ratnikov", pool_engaged=False), True)
# But a bot is still excluded there, request or not.
check("all-authors-still-excludes-bot-with-request",
      d("food-truck", "salmon-of-knowledge", "renovate", pool_engaged=True), False)

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
      mod.lgtm_reviewer_pool("food-truck", "mono"), {"johnnymo87", "Krosantos"})
missing_cfg, mod.LGTM_CONFIG_PATH = mod.LGTM_CONFIG_PATH, Path("/nonexistent/lgtm.yml")
check("reviewer-pool-absent-config", mod.lgtm_reviewer_pool("x", "y"), set())
check("absent-config-not-bound", d("food-truck", "mono", "pfarina"), False)
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
b = lambda pr: mod.lgtm_bound_for_pr("food-truck", "mono", pr)
check("wiring-on-request-no-request", b(pr_of("ratnikov", [], [])), False)
check("wiring-on-request-daemon-requested",
      b(pr_of("ratnikov", ["johnnymo87"], [])), True)
check("wiring-on-request-other-pool-member-requested",
      b(pr_of("ratnikov", ["Krosantos"], [])), False)
# ...but a pool member who ALREADY REVIEWED binds whoever they are: lgtm
# dispatches under a rotating pool identity, so the review that consumed the
# request need not be the daemon's.
check("wiring-on-request-other-pool-member-reviewed",
      b(pr_of("ratnikov", [], ["Krosantos"])), True)
# An ordinary author must not pay for a `gh api user` round-trip at all.
calls.clear()
check("wiring-ordinary-author-bound", b(pr_of("pfarina", [], [])), True)
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
check("no-author-config-admits-anyone", d("blueapron", "bluechef", "stranger"), True)
check("no-author-config-still-needs-repo", d("blueapron", "nope", "stranger"), False)

# --- The same admissions, written in flow style. -------------------------
# The main fixture writes the global lists block-style because the real
# lgtm.yml does. Both spellings reach the same accumulators, and a fixture
# only proves the shapes someone thought to write down.
mod.LGTM_CONFIG_PATH = Path(sys.argv[4])
check("flow-globals-author", d("food-truck", "mono", "pfarina"), True)
check("flow-globals-reviewer-is-author", d("food-truck", "mono", "Krosantos"), True)
check("flow-globals-pool-extracted",
      mod.lgtm_reviewer_pool("food-truck", "mono"), {"johnnymo87", "Krosantos"})
check("flow-globals-on-request-gated", d("food-truck", "mono", "ratnikov"), False)
check("flow-globals-on-request-with-request",
      d("food-truck", "mono", "ratnikov", pool_engaged=True), True)
PY

# Second fixture for the back-compat rule: repos, but zero author config.
cat > "$tmp/lgtm-noauthors.yml" <<'YAML'
reviewers:
  - johnnymo87

repos:
  blueapron/bluechef: {}
  food-truck/mono:
    paths:
      - wonder/blueapron
YAML

# Third fixture: the same global lists, spelled in flow style.
cat > "$tmp/lgtm-flow.yml" <<'YAML'
reviewers: [johnnymo87, 'Krosantos']
authors: [pfarina, ELang7]
onRequestAuthors: [ratnikov]

repos:
  food-truck/mono: {}
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
