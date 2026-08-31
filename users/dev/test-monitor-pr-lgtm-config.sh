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

onRequestAuthors: [ratnikov, 'quoted-author']

repos:
  food-truck/mono:
    authors:
      - camden-wonder
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
check("flow-list-global-author", d("food-truck", "mono", "ratnikov"), True)
check("flow-list-global-quoted-author", d("food-truck", "mono", "quoted-author"), True)
check("flow-list-repo-author",
      d("blueapron", "internal-frontends", "flow-style-author"), True)
check("flow-list-repo-author-does-not-leak",
      d("food-truck", "mono", "flow-style-author"), False)

# --- Back-compat: no author config at all means no author filtering. ------
mod.LGTM_CONFIG_PATH = Path(sys.argv[3])
check("no-author-config-admits-anyone", d("blueapron", "bluechef", "stranger"), True)
check("no-author-config-still-needs-repo", d("blueapron", "nope", "stranger"), False)
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

out=$(python3 "$tmp/drive.py" "$SCRIPT" "$tmp/lgtm.yml" "$tmp/lgtm-noauthors.yml")
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
if [ "$count" -lt 26 ]; then
  echo "FAIL: expected >=26 assertions, got $count (driver did not run?)" >&2
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
            listed, _allowed, _all = mod._parse_lgtm_config(owner, repo)
            if not listed:
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
