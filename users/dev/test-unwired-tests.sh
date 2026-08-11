#!/usr/bin/env bash
# Reachability guard: every test file in this repo must be EXECUTED by CI.
#
# WHY THIS EXISTS
#
# Five times now, a test file was added to this repo and run by nothing, and
# every one was caught by a human reading code rather than by tooling:
#
#   1. S0/S1 (workstation-h0mp)      an unrun writer
#   2. users/dev/test-frontdoor-opacity.sh   a guard enforced NOWHERE, sat red
#                                    on main from #217 until 2026-08-01
#   3. pkgs/oc-auto-attach/test-project-key.sh  71 assertions, no doCheck,
#                                    no checkPhase (workstation-pscu)
#   4. workstation-dmat              three TS harnesses, 238 tests
#   5. pkgs/oc-session-list/test.sh  "sat unrun despite its derivation setting
#                                    doCheck = true -- the checkPhase only ran
#                                    `--help`" (see the oc-session-list-bin
#                                    comment in flake.nix)
#
# A test nobody runs is not a test. It is a comment that costs money to write
# and then lies about the state of the system. This guard makes instance #6
# fail CI instead of waiting for someone to notice.
#
# ---------------------------------------------------------------------------
# WHAT COUNTS AS "RUN BY CI" -- AND WHY checkPhase DOES NOT
#
# CI runs exactly one command (.github/workflows/ci.yml): `nix flake check`.
# So there are exactly two blessed ways to get a test file executed:
#
#   (a) a `checks.*` entry in flake.nix that executes it, directly or through
#       another script that a check executes (reachability is transitive), or
#   (b) an explicit step in .github/workflows/ that executes it -- for suites
#       that CANNOT be hermetic (needing network or loopback sockets).
#
# `doCheck = true` / `checkPhase` is DELIBERATELY NOT ACCEPTED as evidence,
# even though it is the obvious nix instinct, and even though it is sometimes
# genuinely executed (packages inside the home/system closures built by
# checks.home-dev, checks.home-cloudbox and checks.nixos-devbox really do run
# their checkPhase in CI -- pkgs/opencode-plugin-bundle is a live example).
#
# It is rejected because it is exactly where this repo has been fooled before.
# oc-session-list set doCheck = true and its checkPhase ran `--help`; the
# derivation was "checked", the 700-line suite next to it was not. Accepting
# checkPhase would make this guard certify instance #5 as covered. The whole
# point is to distinguish "a check exists" from "this file runs", and only a
# reference that actually executes the FILE can do that.
#
# If your test genuinely runs in a checkPhase, add a thin `checks.*` entry that
# runs the same script. That is a three-line diff and it makes the coverage
# legible to this guard and to the next reader.
#
# ---------------------------------------------------------------------------
# WHY THE MARKER LIVES IN THE UNWIRED FILE, NOT IN A LIST HERE
#
# This repo already litigated central-list-vs-marker and chose markers, for
# reasons written down in test-frontdoor-opacity.sh: a central allowlist goes
# stale because nothing forces it to be revisited when code moves, and the
# justification does not travel with the file.
#
# So an unwired test declares its own debt, in its own header:
#
#     unwired-test(<bead-id>): <one-line reason>
#
# Three properties fall out, and they are the entire anti-decay argument:
#
#   - The debt appears in the diff of the PR that creates it, where a reviewer
#     is actually looking, rather than as a one-line append to a long file
#     nobody reads.
#   - Deleting or wiring the file removes the marker automatically. No stale
#     entries, no rename drift.
#   - `git grep -c 'unwired-test('` is the backlog census, for free.
#
# The bead id is greppability and reviewer ceremony -- this script CANNOT
# verify that the bead exists (no network, no bd, in a build sandbox). Do not
# mistake it for mechanical enforcement; it is a pointer for the human.
#
# AND THE MARKER IS CHECKED IN BOTH DIRECTIONS. A file that IS wired but still
# carries a marker fails too. Otherwise markers accumulate on files that were
# fixed years ago and the census silently overstates the debt -- a stale
# exemption is how an exemption system stops meaning anything.
#
# Run: bash users/dev/test-unwired-tests.sh
# ---------------------------------------------------------------------------
set -o errexit -o nounset -o pipefail

# Resolve the repo root from this script's own location. Do NOT depend on the
# caller's cwd: pkgs/oc-auto-attach/test-project-key.sh silently passed for
# months partly because it only worked from one directory (workstation-pscu).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail_count=0
bad() { echo "FAIL: $*" >&2; fail_count=$((fail_count + 1)); }

# This guard and its own meta-test are excluded from the reference scan. Both
# necessarily mention test paths, and a naive follow would let the guard
# certify files as reachable *via the guard itself*.
SELF="users/dev/test-unwired-tests.sh"
SELF_TEST="users/dev/test-unwired-tests-guard.sh"

# ---------------------------------------------------------------------------
# 1. Enumerate candidate test files.
#
# `find`, not `git ls-files`: inside a nix build the source is a store copy
# with no .git, and git would either fail or silently enumerate nothing --
# which would make this guard vacuously pass. Vacuity is checked in step 5.
#
# The taxonomy is deliberately shaped so that `vitest.config.ts` does NOT
# match. A substring test for "test" catches it (vi-TEST) and a config file is
# not a test; that false positive is the kind that trains people to reach for
# a marker reflexively.
# ---------------------------------------------------------------------------
mapfile -t candidates < <(
  find . -type f \
    \( -path ./.git -o -path './**/node_modules' -o -name node_modules \
       -o -name dist -o -path './**/fixtures' -o -name fixtures \) -prune -o \
    -type f -print 2>/dev/null |
  sed 's|^\./||' |
  while read -r f; do
    b="${f##*/}"
    case "$b" in
      *.test.ts|*.spec.ts|*.test.js|*.spec.js) echo "$f" ;;
      test.sh|test-*.sh|test_*.sh|*-test.sh)   echo "$f" ;;
      test-*.lua|test_*.lua|*-test.lua)        echo "$f" ;;
      test_*.py|test-*.py|*_test.py)           echo "$f" ;;
      test-*.js|*-test.js)                     echo "$f" ;;
    esac
  done | sort
)

# Note the vacuity assertions live AFTER adjudication (step 6), not here. This
# script matches its own filename taxonomy, so `candidates` is never empty even
# if find(1) returns nothing else -- checking emptiness here would be a test
# that cannot fail, which is the joke this whole guard is about.

# ---------------------------------------------------------------------------
# 2. Seed the reachability closure from the two blessed channels.
#
# Channel (a): the checks block of flake.nix. Everything above it is packages
# and overlays, where a mention is not an execution.
# Channel (b): .github/workflows/*.yml -- for suites that cannot be hermetic.
# ---------------------------------------------------------------------------
seed_text=""
if [ -f flake.nix ]; then
  flake_checks="$(awk '/^[[:space:]]*checks\./{f=1} f' flake.nix)"
  # Sanity-check the EXTRACTION, not just its result. If this pattern stops
  # matching -- someone reindents flake.nix, or renames the attribute -- the
  # seed silently empties and dozens of correctly-wired files get reported as
  # unwired. That failure is loud but its diagnostic is a lie, and a lie that
  # tells people to add markers is the precise way this guard would become
  # worse than nothing. Verified by mutation: it reported "14 problems".
  case "$flake_checks" in
    *runCommand*) ;;
    *)
      echo "FAIL: could not extract the checks block from flake.nix." >&2
      echo "      The seed is empty, so nothing would look reachable. Fix the" >&2
      echo "      extraction in this script; do NOT add markers to the files" >&2
      echo "      this would otherwise flag -- they are almost certainly wired." >&2
      exit 1
      ;;
  esac
  seed_text+="$flake_checks"$'\n'
fi
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$wf" ] && seed_text+="$(cat "$wf")"$'\n'
done

# ---------------------------------------------------------------------------
# 3. Execution-shaped reference matching.
#
# We do NOT match bare path mentions. A path in prose is not an execution, and
# counting it is the SILENT failure direction -- it marks a genuinely unwired
# test as covered, which is the exact defect this guard exists to detect.
#
# This is not hypothetical. test-frontdoor-opacity.sh's own header cites
# `test-pool-route-clients.sh:74` and `opencode-launch/test.sh:214` while
# explaining a past mistake. That file IS reached by a check, so a bare-mention
# matcher would launder both of those genuinely-unwired suites into "covered".
#
# So a reference counts only when preceded by something that runs it. Full-line
# comments are stripped first, which additionally defuses the `# Run: bash ...`
# header convention most of these scripts carry.
# ---------------------------------------------------------------------------
strip_comments() { sed -E 's/^[[:space:]]*(#|--|\/\/).*$//'; }

RUNNERS='(bash|sh|source|\.|exec bash|node|bun|npx|python3?|pytest|lua|nvim( +--clean)?( +-l)?)'

refs_in_text() {
  # stdin: file text. stdout: repo-relative paths that the text EXECUTES.
  strip_comments |
    grep -oE "${RUNNERS}[[:space:]]+[\"']?[A-Za-z0-9_./\$\{\}-]+\.(sh|lua|ts|js|py)" |
    grep -oE "[A-Za-z0-9_./\$\{\}-]+\.(sh|lua|ts|js|py)$" |
    sed 's|^\./||' || true
}

# ---------------------------------------------------------------------------
# 4. Transitive closure.
#
# A file reached by a check can itself run others: assets/nvim/
# test-session-switcher.sh runs two .lua unit files via `nvim --clean -l`, and
# neither appears anywhere in flake.nix. A closure that stopped at depth 1
# would demand markers on two files that run on every PR -- a false positive on
# correctly-wired code, which is how a guard trains people to ignore it.
# ---------------------------------------------------------------------------
declare -A reached=()
frontier=()

# Resolve a raw reference against the repo, and against the referrer's dir for
# the `"$(dirname "${BASH_SOURCE[0]}")/../other/test.sh"` delegation shape used
# by pkgs/session-state-plugin/test.sh and pkgs/self-compact-plugin/test.sh.
resolve_ref() {
  local raw="$1" from_dir="$2" cleaned
  cleaned="$(printf '%s' "$raw" | sed -E 's/\$\{[^}]*\}//g; s/\$\([^)]*\)//g; s|^/+||')"
  [ -n "$cleaned" ] || return 0
  if [ -f "$cleaned" ]; then printf '%s\n' "$cleaned"; return 0; fi
  local joined
  joined="$(cd "$from_dir" 2>/dev/null && cd "$(dirname "$cleaned")" 2>/dev/null && pwd)/$(basename "$cleaned")" || return 0
  joined="${joined#"$repo_root"/}"
  [ -f "$joined" ] && printf '%s\n' "$joined"
  return 0
}

while read -r r; do
  p="$(resolve_ref "$r" "$repo_root")" || true
  [ -n "${p:-}" ] && [ -z "${reached[$p]:-}" ] && { reached[$p]=1; frontier+=("$p"); }
done < <(printf '%s' "$seed_text" | refs_in_text)

while [ ${#frontier[@]} -gt 0 ]; do
  cur="${frontier[0]}"; frontier=("${frontier[@]:1}")
  [ "$cur" = "$SELF" ] || [ "$cur" = "$SELF_TEST" ] && continue
  [ -f "$cur" ] || continue
  while read -r r; do
    p="$(resolve_ref "$r" "$repo_root/$(dirname "$cur")")" || true
    [ -n "${p:-}" ] && [ -z "${reached[$p]:-}" ] && { reached[$p]=1; frontier+=("$p"); }
  done < <(refs_in_text < "$cur")
done

# ---------------------------------------------------------------------------
# 4b. Runner-glob channel, with a tripwire.
#
# assets/opencode/plugins/test/*.{test,spec}.ts are executed by vitest and bun,
# which are pointed at the DIRECTORY, so no individual path is ever named. They
# are reachable -- but only while the two checks that enforce the globs still
# enforce them. dmat's whole defect was a runner whose include pattern silently
# stopped matching a file, so trusting a glob permanently would rebuild the
# original bug. Assert the gates still exist before honouring the glob.
# ---------------------------------------------------------------------------
PLUGIN_TEST_DIR="assets/opencode/plugins/test"
if [ -d "$PLUGIN_TEST_DIR" ]; then
  # Match the ATTRIBUTE DEFINITIONS, not bare mentions. Verified by mutation:
  # renaming `plugin-vitest = ...` left two prose mentions behind, so a
  # substring test kept honouring the glob for a gate that no longer existed.
  if grep -qE '^[[:space:]]*plugin-vitest[[:space:]]*=' flake.nix \
     && grep -qE '^[[:space:]]*plugin-bun[[:space:]]*=' flake.nix \
     && grep -qE '^[[:space:]]*plugin-test-coverage[[:space:]]*=' flake.nix; then
    for f in "$PLUGIN_TEST_DIR"/*.test.ts "$PLUGIN_TEST_DIR"/*.spec.ts; do
      [ -f "$f" ] && reached["$f"]=1
    done
  else
    bad "the plugin-vitest / plugin-bun / test-runner-coverage checks that make"
    printf '      %s/ reachable are gone from flake.nix. Either restore them or\n' "$PLUGIN_TEST_DIR" >&2
    printf '      stop treating that directory as glob-covered here.\n' >&2
  fi
fi

# pkgs/opencode-frontdoor/test/*.test.ts, same channel, same tripwire shape
# (bead workstation-5m47). Run by `checks.frontdoor-vitest`, which invokes
# vitest against the directory.
#
# WHY A SECOND HARDCODED ENTRY IS NOT THE CENTRAL LIST THIS REPO REJECTED.
# That argument was litigated for DEBT declarations, and it turns on decay
# DIRECTION. A stale exemption keeps excusing a file: it decays silently, in
# the dangerous direction, which is why those live as markers in the file. A
# stale entry HERE decays loudly and safely -- rename or move the directory and
# the glob stops matching, so its files report as unwired and CI goes red;
# delete it and the `[ -d ]` test makes the entry inert.
#
# The inverse design -- a `.glob-covered-by` dotfile in the test directory
# naming its check -- was considered and REJECTED for the same reason. That
# marker would assert "I AM covered", and this script cannot evaluate nix to
# falsify it, so a wrong one fails SILENTLY: exactly the direction section 3
# above refuses to accept, and a self-service channel for laundering any
# directory into "covered" by naming any attribute that happens to exist.
# Editing this guard is deliberately higher ceremony than dropping a dotfile;
# a coverage claim should be reviewed in the most sceptical file in the repo.
#
# NOTE the scope is *.test.ts ONLY, unlike the plugin entry above, and that is
# deliberate rather than an omission: it mirrors EXACTLY what that check's own
# on-disk-vs-actually-ran set diff enforces (`find test -name '*.test.ts'`). A
# stray test/foo.spec.ts is NOT run by that check, so certifying it here would
# rebuild the dmat defect inside the fix for it -- covered on paper, executed
# by nothing. Widen this glob only in the same breath as the check's find(1).
FRONTDOOR_TEST_DIR="pkgs/opencode-frontdoor/test"
if [ -d "$FRONTDOOR_TEST_DIR" ]; then
  # One attribute, where the plugin entry above demands three. Weaker than that
  # precedent, and worth naming: the plugins have a dependency-free bash
  # sibling (plugin-test-coverage) that independently audits the runner claims,
  # and the frontdoor has no equivalent. What backs this entry instead is
  # INSIDE the check -- a skip census and a set diff of on-disk vs executed
  # files -- which this script cannot see and cannot enforce.
  if grep -qE '^[[:space:]]*frontdoor-vitest[[:space:]]*=' flake.nix; then
    for f in "$FRONTDOOR_TEST_DIR"/*.test.ts; do
      [ -f "$f" ] && reached["$f"]=1
    done
  else
    bad "the frontdoor-vitest check that makes $FRONTDOOR_TEST_DIR/ reachable is"
    printf '      gone from flake.nix. Either restore it or stop treating that\n' >&2
    printf '      directory as glob-covered here.\n' >&2
  fi
fi

# ---------------------------------------------------------------------------
# 5. Adjudicate every candidate, in both directions.
# ---------------------------------------------------------------------------
MARKER_RE='unwired-test\([a-z0-9-]+\)'
n_reached=0; n_marked=0

for f in "${candidates[@]}"; do
  [ "$f" = "$SELF" ] && continue
  [ "$f" = "$SELF_TEST" ] && continue

  marker="$(grep -oE "$MARKER_RE" "$f" 2>/dev/null | head -1 || true)"

  if [ -n "${reached[$f]:-}" ]; then
    n_reached=$((n_reached + 1))
    if [ -n "$marker" ]; then
      bad "$f IS executed by CI but still carries an $marker marker."
      printf '      Delete the marker line: a stale exemption makes the census lie\n' >&2
      printf '      about how much debt is left, and that is how the census dies.\n' >&2
    fi
    continue
  fi

  if [ -n "$marker" ]; then
    n_marked=$((n_marked + 1))
    continue
  fi

  bad "$f is a test file that NOTHING in CI executes."
  cat >&2 <<EOF
      CI runs only \`nix flake check\`, so an unwired test never runs and never
      fails -- it just quietly stops being true. Pick one:

      (1) WIRE IT (preferred). Add a checks entry in flake.nix, e.g.:

            my-thing = devboxPkgs.runCommand "my-thing-tests" {
              nativeBuildInputs = [ devboxPkgs.bash ];
            } ''
              cd \${self}
              bash $f 2>&1 | tee "\$TMPDIR/out.txt"
              grep -q '^ALL PASS' "\$TMPDIR/out.txt" || {
                echo "GATE FAILURE: the suite did not reach ALL PASS." >&2; exit 1; }
              touch \$out
            '';

          Copy \`checks.ff-mono-root\` or \`checks.oc-auto-attach\` in flake.nix;
          both are this exact shape. Grep for the final PASS line as shown --
          running a script proves nothing if you do not assert it got to the end.

      (2) If it CANNOT be hermetic (needs network or loopback sockets), run it
          from a step in .github/workflows/ci.yml instead. That counts too.

      (3) If it genuinely should not run in CI, file a bead and declare the debt
          in the file's own header:

            # unwired-test(workstation-xxxx): <why this cannot run in CI>
EOF
done

# ---------------------------------------------------------------------------
# 6. Vacuity. The guard's worst outcome is not a false alarm -- it is silence.
#
# Both of these have already happened in prototype: an enumeration that found
# nothing, and a seed pattern that matched nothing because flake.nix indents
# `checks.` by four spaces and the pattern assumed two. The second reported a
# green-looking 10 reachable files while quietly flagging correctly-wired ones.
# Neither would be caught by any assertion about individual files.
# ---------------------------------------------------------------------------
adjudicated=$((n_reached + n_marked + fail_count))
if [ "$adjudicated" -eq 0 ]; then
  echo "FAIL: adjudicated zero test files -- the guard is vacuous." >&2
  echo "      The taxonomy or find(1) broke; this guard is currently proving nothing." >&2
  exit 1
fi
if [ "$n_reached" -eq 0 ]; then
  echo "FAIL: not one test file is reachable from CI." >&2
  echo "      That is almost certainly a broken seed (flake.nix checks-block" >&2
  echo "      extraction or the workflow scan), not a genuinely untested repo." >&2
  exit 1
fi

if [ "$fail_count" -gt 0 ]; then
  echo "" >&2
  echo "FAILED: $fail_count problem(s). ${#candidates[@]} candidate test files;" >&2
  echo "        $n_reached executed by CI, $n_marked declared unwired." >&2
  exit 1
fi

echo "PASS: ${#candidates[@]} candidate test files -- $n_reached executed by CI, $n_marked declared unwired via marker"
echo "ALL PASS (test reachability)"
