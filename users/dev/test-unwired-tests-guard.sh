#!/usr/bin/env bash
# Meta-test for users/dev/test-unwired-tests.sh.
#
# A guard that cannot fail is the exact defect it was built to detect, so this
# drives the guard against synthetic repos and asserts it says the right thing.
# The precedent is test-frontdoor-opacity-guard.sh, which exists for the same
# reason: the opacity guard sat red-then-inert on main for weeks and nothing
# noticed, because nothing tested the tester.
#
# Every case below is a real failure mode found while designing the guard, not
# an invented one. In particular cases 5 and 6 are the two SILENT directions --
# where the guard would wrongly certify an unwired test as covered. Those are
# worse than a false alarm: a false alarm gets fixed, a false pass gets shipped.
#
# Run: bash users/dev/test-unwired-tests-guard.sh
set -o errexit -o nounset -o pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-unwired-tests.sh"
[ -f "$GUARD" ] || { echo "FAIL: cannot find the guard at $GUARD" >&2; exit 1; }

pass_n=0
ok()   { printf 'PASS  %s\n' "$1"; pass_n=$((pass_n + 1)); }
oops() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# Build a synthetic repo. $1 = checks-block body, $2..= "path:::content" files.
mkrepo() {
  local root checks
  root="$(mktemp -d)"
  checks="$1"; shift
  mkdir -p "$root/users/dev" "$root/.github/workflows"
  cp "$GUARD" "$root/users/dev/test-unwired-tests.sh"
  cat > "$root/flake.nix" <<EOF
{
  outputs = { self }: {
    packages.x = 1;
    checks.aarch64-linux = {
$checks
    };
  };
}
EOF
  : > "$root/.github/workflows/ci.yml"
  local spec path body
  for spec in "$@"; do
    path="${spec%%:::*}"; body="${spec#*:::}"
    mkdir -p "$root/$(dirname "$path")"
    printf '%s\n' "$body" > "$root/$path"
  done
  printf '%s' "$root"
}

run_guard() { bash "$1/users/dev/test-unwired-tests.sh" > "$1/out.txt" 2>&1; echo $?; }

# ---------------------------------------------------------------------------
# 1. A correctly wired test passes. If this breaks, the guard is a wall.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/foo/test.sh";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
echo hi')"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a wired test file was flagged (the fatal false-positive direction)"; }
ok "a test executed by a checks entry passes"

# ---------------------------------------------------------------------------
# 2. An unwired test with no marker fails. The whole point.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "true";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
echo hi')"
[ "$(run_guard "$r")" = "1" ] || oops "an unwired test file did NOT fail the guard"
grep -q 'NOTHING in CI executes' "$r/out.txt" || oops "unwired failure lacked its explanation"
grep -q 'runCommand' "$r/out.txt" || oops "failure message lacked the paste-ready checks skeleton"
ok "an unwired test file fails, with a paste-ready wiring skeleton"

# ---------------------------------------------------------------------------
# 3. An unwired test that DECLARES its debt passes.
# ---------------------------------------------------------------------------
r="$(mkrepo '      w = runCommand "w" {} "bash pkgs/wired/test.sh";' \
      'pkgs/wired/test.sh:::#!/usr/bin/env bash
echo wired' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
# unwired-test(workstation-abcd): needs a live tmux server
echo hi')"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a declared-unwired file was still flagged"; }
ok "an unwired test with an unwired-test(<bead>) marker passes"

# ---------------------------------------------------------------------------
# 4. A WIRED file that still carries a marker fails.
#
# Without this the census rots: markers pile up on files that were fixed long
# ago and the backlog silently overstates itself, which is how an exemption
# system stops meaning anything.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/foo/test.sh";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
# unwired-test(workstation-abcd): stale, this file IS wired now
echo hi')"
[ "$(run_guard "$r")" = "1" ] || oops "a stale marker on a wired file did NOT fail"
grep -q 'stale exemption' "$r/out.txt" || oops "stale-marker failure lacked its explanation"
ok "a stale marker on a now-wired file fails"

# ---------------------------------------------------------------------------
# 5. SILENT DIRECTION: a path named only in a COMMENT is not coverage.
#
# Real instance: users/dev/test-frontdoor-opacity.sh IS reached by a check, and
# its header cites test-pool-route-clients.sh and opencode-launch/test.sh while
# explaining a past mistake. A bare-mention matcher would launder both of those
# genuinely-unwired suites into "covered" and nobody would ever know.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/foo/test.sh";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
# see pkgs/bar/test.sh:74 for why this is shaped like this
echo hi' \
      'pkgs/bar/test.sh:::#!/usr/bin/env bash
echo bar')"
[ "$(run_guard "$r")" = "1" ] || oops "a test mentioned only in a comment was counted as covered"
grep -q 'pkgs/bar/test.sh is a test file' "$r/out.txt" || oops "wrong file flagged for the comment case"
ok "a path cited in a comment does NOT count as executed"

# ---------------------------------------------------------------------------
# 6. SILENT DIRECTION: checkPhase is not accepted as evidence.
#
# oc-session-list set doCheck = true while its checkPhase ran `--help`; the
# 700-line suite beside it never ran for months. Accepting checkPhase would
# make this guard certify that very instance as covered.
# ---------------------------------------------------------------------------
r="$(mkrepo '      w = runCommand "w" {} "bash pkgs/wired/test.sh";' \
      'pkgs/wired/test.sh:::#!/usr/bin/env bash
echo wired' \
      'pkgs/foo/default.nix:::{ }: {
  doCheck = true;
  checkPhase = "bash pkgs/foo/test.sh";
}' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
echo hi')"
[ "$(run_guard "$r")" = "1" ] || oops "checkPhase was accepted as coverage (it must not be)"
grep -q 'pkgs/foo/test.sh is a test file' "$r/out.txt" || oops "checkPhase case failed for the wrong reason"
ok "a checkPhase that runs the test does NOT count as executed"

# ---------------------------------------------------------------------------
# 7. Transitive reachability: a check runs A, A runs B, so B is covered.
#
# Real instance: assets/nvim/test-session-switcher.sh runs two .lua unit files
# that appear nowhere in flake.nix. Demanding markers on those would be a false
# positive on correctly-wired code.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/foo/test.sh";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
nvim --clean -l pkgs/foo/test-unit.lua' \
      'pkgs/foo/test-unit.lua:::print("ok")')"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a transitively-executed file was flagged"; }
ok "a file executed BY another executed file is covered (transitive)"

# ---------------------------------------------------------------------------
# 7b. Transitive reachability THROUGH A dirname-DELEGATION SHIM.
#
# Case 7 covers a clean literal path. The delegation shape actually used in this
# repo is not literal:
#
#   exec bash "$(dirname "${BASH_SOURCE[0]}")/../opencode-plugin-bundle/test.sh"
#
# resolve_ref has always handled the RESOLUTION half of this (its comment names
# these very shims), but refs_in_text never extracted the reference in the first
# place -- its path character class excludes `(`, `)` and `"`, so the line
# yielded nothing and the closure never reached the shared runner. The resolver
# was dead code for the shape it named. Found while wiring workstation-m98t,
# whose two shims are exactly this.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/shim/test.sh";' \
      'pkgs/shim/test.sh:::#!/usr/bin/env bash
exec bash "$(dirname "${BASH_SOURCE[0]}")/../runner/test.sh" some-arg' \
      'pkgs/runner/test.sh:::#!/usr/bin/env bash
echo hi')"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a file reached through a dirname-delegation shim was flagged"; }
ok "a file executed through a \$(dirname ...) delegation shim is covered"

# ---------------------------------------------------------------------------
# 8. A workflow step counts, for suites that cannot be hermetic.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "true";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
echo hi')"
printf 'jobs:\n  check:\n    steps:\n      - run: bash pkgs/foo/test.sh\n' \
  > "$r/.github/workflows/ci.yml"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a workflow-executed test was flagged"; }
ok "a test executed by a CI workflow step is covered"

# ---------------------------------------------------------------------------
# 9. Vacuity: adjudicating nothing must fail, not pass.
#
# The guard's worst failure is silence. Note it must count ADJUDICATED files,
# not enumerated ones: the guard matches its own filename taxonomy, so a naive
# emptiness check can never fire. That bug was live until this case caught it.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "true";')"
[ "$(run_guard "$r")" = "1" ] || oops "an empty enumeration passed vacuously"
grep -q 'vacuous' "$r/out.txt" || oops "vacuity failure did not name itself"
ok "an empty enumeration fails as vacuous rather than passing"

# ---------------------------------------------------------------------------
# 10. A broken seed must fail loudly, not report a plausible-looking subset.
#
# Live prototype bug: the checks-block extractor assumed two-space indentation
# where flake.nix uses four. It reported 10 reachable files and flagged a dozen
# correctly-wired ones. No per-file assertion catches that; only this does.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "true";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
# unwired-test(workstation-abcd): declared
echo hi')"
[ "$(run_guard "$r")" = "1" ] || oops "a repo where nothing is reachable did not fail"
grep -q 'not one test file is reachable' "$r/out.txt" || oops "broken-seed failure did not name itself"
ok "a seed that reaches nothing fails loudly"

# ---------------------------------------------------------------------------
# 11. A seed that cannot be extracted must say SO, not blame the test files.
#
# Found by mutation: making the checks-block pattern miss (a reindent of
# flake.nix would do it) emptied the seed and reported "14 problems" naming
# correctly-wired files. Failing loudly is not enough when the message tells
# people to add markers to files that are already covered -- that is precisely
# how an exemption system fills up with lies.
# ---------------------------------------------------------------------------
r="$(mkrepo '      foo = runCommand "f" {} "bash pkgs/foo/test.sh";' \
      'pkgs/foo/test.sh:::#!/usr/bin/env bash
echo hi')"
cat > "$r/flake.nix" <<'NOCHECKS'
{ outputs = { self }: { packages.x = 1; }; }
NOCHECKS
[ "$(run_guard "$r")" = "1" ] || oops "an unextractable checks block did not fail"
grep -q 'could not extract the checks block' "$r/out.txt" \
  || oops "seed-extraction failure blamed the test files instead of itself"
grep -q 'do NOT add markers' "$r/out.txt" \
  || oops "seed-extraction failure did not warn against adding markers"
ok "an unextractable checks block blames itself, not the test files"

# ---------------------------------------------------------------------------
# 12. The runner-glob tripwire fires when the gates behind the glob disappear.
#
# Found by mutation: the first version grepped for the bare string
# 'plugin-vitest', which survived in prose after the attribute was renamed, so
# the glob kept being honoured for a gate that no longer existed. dmat's defect
# exactly -- trusting an include pattern that stopped including.
# ---------------------------------------------------------------------------
r="$(mkrepo '      pluginVitestRenamed = runCommand "f" {} "true";' \
      'assets/opencode/plugins/test/a.test.ts:::// nothing')"
[ "$(run_guard "$r")" = "1" ] || oops "the glob tripwire did not fire when its gates vanished"
grep -q 'are gone from flake.nix' "$r/out.txt" || oops "glob tripwire failed for the wrong reason"
ok "the runner-glob tripwire fires when the checks behind it are renamed away"

# ---------------------------------------------------------------------------
# 13. The frontdoor glob channel is honoured while its check is defined.
#
# checks.frontdoor-vitest points vitest at pkgs/opencode-frontdoor/test, so no
# individual path is ever named and the execution-shaped matcher cannot see
# those 25 files. Measured before this existed: deleting their markers made the
# guard report all 25 as executed by nothing -- a false positive on code that
# genuinely runs on every PR.
# ---------------------------------------------------------------------------
r="$(mkrepo '      frontdoor-vitest = runCommand "f" {} "vitest run";' \
      'pkgs/opencode-frontdoor/test/a.test.ts:::// nothing')"
[ "$(run_guard "$r")" = "0" ] || { cat "$r/out.txt"; oops "a glob-covered frontdoor test was flagged unwired"; }
ok "the frontdoor test dir is covered while checks.frontdoor-vitest is defined"

# ---------------------------------------------------------------------------
# 14. ...and its tripwire fires when that check is renamed away.
# ---------------------------------------------------------------------------
r="$(mkrepo '      frontdoorVitestRenamed = runCommand "f" {} "vitest run";' \
      'pkgs/opencode-frontdoor/test/a.test.ts:::// nothing')"
[ "$(run_guard "$r")" = "1" ] || oops "the frontdoor glob tripwire did not fire when its check vanished"
grep -q 'frontdoor-vitest check that makes' "$r/out.txt" \
  || oops "frontdoor glob tripwire failed for the wrong reason"
ok "the frontdoor glob tripwire fires when checks.frontdoor-vitest is renamed away"

# ---------------------------------------------------------------------------
# 15. SILENT DIRECTION: the frontdoor glob must NOT cover a *.spec.ts.
#
# The plugin entry covers *.test.ts AND *.spec.ts because two runners there
# split on that suffix. checks.frontdoor-vitest runs neither bun nor a .spec
# glob -- its own set diff enumerates `find test -name '*.test.ts'` -- so a
# stray .spec.ts in that directory is executed by NOTHING. Copying the plugin
# entry verbatim would certify it as covered and rebuild the dmat defect inside
# the fix for it. This case exists to make that copy fail.
# ---------------------------------------------------------------------------
r="$(mkrepo '      frontdoor-vitest = runCommand "f" {} "vitest run";' \
      'pkgs/opencode-frontdoor/test/a.test.ts:::// covered' \
      'pkgs/opencode-frontdoor/test/stray.spec.ts:::// run by nothing')"
[ "$(run_guard "$r")" = "1" ] || oops "a .spec.ts in the frontdoor dir was laundered into covered"
grep -q 'stray.spec.ts is a test file' "$r/out.txt" \
  || oops "the stray .spec.ts case failed for the wrong reason"
ok "a *.spec.ts in the frontdoor test dir is NOT covered by the .test.ts glob"

echo ""
echo "ALL PASS (test-unwired-tests guard meta-test, $pass_n cases)"
