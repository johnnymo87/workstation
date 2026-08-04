#!/usr/bin/env bash
# Loader-replica pin guard.
#
# assets/opencode/plugins/test/plugin-loader-contract.test.ts replicates
# opencode's plugin loader. A replica is only as good as its pin: if the
# deployed opencode moves and the replica does not, the test keeps passing while
# asserting a contract that no longer exists. That is exactly how the guard it
# replaced (no-function-exports.test.ts) failed -- confidently green about a
# loader it no longer matched, on a file opencode was rejecting in production.
#
# WHY BASH AND NOT JUST THE VITEST CASE: CI runs `nix flake check` only. It does
# not run vitest -- there is no plugin-test derivation. The equivalent assertion
# living solely in the test suite would fire only when a human happened to run
# `npx vitest` locally, which is after the bump has already deployed. Same
# failure the frontdoor-opacity guard hit: "a guard nothing runs is
# documentation with a shebang." So the pin is enforced here, in the checked
# path, and duplicated in the test suite for fast local feedback.
#
# Five constants must agree:
#   1. upstreamVersion      users/dev/home.base.nix          (what we deploy)
#   2. LOADER_VERSION       plugin-loader-contract.test.ts   (what we replicate)
#   3. fixtures/VERSION     test/fixtures/                   (what we vendored)
#   4. LOADER_SEMANTICS_PIN pkgs/opencode-plugin-bundle/     (what the bundle
#                                                            checkPhase asserts)
#   5. LOADER_SEMANTICS_PIN pkgs/opencode-plugin-canary-sh/  (what the production
#                                                            canary greps for)
#
# (3) exists because the lazy path out of a red (1)!=(2) is to bump
# LOADER_VERSION and skip refreshing the fixtures, leaving the "mechanical diff"
# recipe pointing at sources that describe a different version.
#
# (4) is the THIRD in-repo copy of loader semantics: the bundle checkPhase
# asserts the v1 plugin shape against the built artifact, mirroring
# readV1Plugin/readPluginId. It was added uncoupled, with only a comment saying
# "when the pin moves, update this too; nothing will tell you" -- which is the
# same rot (2) and (3) are here to prevent, restated as a hope. Step 3 of
# docs/plans/2026-08-01-plugin-loader-hardening-roadmap.md WILL move the pin, so
# it is coupled now rather than after it silently drifts.
#
# (5) is the FOURTH copy, and the only one that runs in PRODUCTION. The E2 canary
# greps the serve log for opencode's own load-failure line, so the message string
# and the `path=file://...` field it parses are upstream internals on an 8-hourly
# auto-bump. If upstream rewords that line the canary's log leg goes blind while
# its test fixtures, carrying the old string, stay green -- and that leg is the
# ONLY cover for 8 of the 9 deployed plugin files, including the two external
# ones that have no build-time cover at all. Coupled here so a bump forces
# re-reading the real logError call site.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

nix_file="$repo_root/users/dev/home.base.nix"
test_file="$repo_root/assets/opencode/plugins/test/plugin-loader-contract.test.ts"
fixtures_dir="$repo_root/assets/opencode/plugins/test/fixtures"
fixture_version_file="$fixtures_dir/VERSION"
bundle_file="$repo_root/pkgs/opencode-plugin-bundle/default.nix"
canary_file="$repo_root/pkgs/opencode-plugin-canary-sh/opencode-plugin-canary.sh"

# Our own loader patch and the three files that carry the behaviour the canary
# parses. See "The loader patch's identity" below.
patch_file="$fixtures_dir/plugin-loader-observability.patch"
pristine_index="$fixtures_dir/plugin-index.ts"
patched_index="$fixtures_dir/plugin-index.patched.ts"
logging_fixture="$fixtures_dir/logging.ts"
config_plugin_fixture="$fixtures_dir/config-plugin.ts"

fail() {
  echo "FAIL: loader-replica pin guard" >&2
  echo >&2
  printf '%s\n' "$@" >&2
  exit 1
}

shared_fixture="$fixtures_dir/plugin-shared.ts"
loader_fixture="$fixtures_dir/loader.ts"

# Every vendored file is listed here. A fixture that nothing references can be
# deleted without failing anything, which makes the refresh ritual quietly
# optional -- plugin-shared.ts and loader.ts were both in that state.
for f in "$nix_file" "$test_file" "$fixture_version_file" "$bundle_file" "$canary_file" \
         "$patch_file" "$pristine_index" "$patched_index" "$logging_fixture" \
         "$config_plugin_fixture" "$shared_fixture" "$loader_fixture"; do
  [ -f "$f" ] || fail "missing required file: $f" \
    "" \
    "If this file was moved or renamed, this guard is silently dead." \
    "Repoint it -- do not delete it."
done

deployed="$(sed -nE 's/^[[:space:]]*upstreamVersion[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$nix_file" | head -1)"
# patchedRevision is NOT compared against anything (that design was withdrawn --
# see the header). It is read only so the refresh recipe can name the fork tag
# our patch should be fetched from.
deployed_rev="$(sed -nE 's/^[[:space:]]*patchedRevision[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$nix_file" | head -1)"
rev_suffix="${deployed_rev:+.${deployed_rev}}"
replica="$(sed -nE 's/^const LOADER_VERSION = "([^"]+)".*/\1/p' "$test_file" | head -1)"
fixtures="$(tr -d '[:space:]' < "$fixture_version_file")"
bundle="$(sed -nE 's/^[[:space:]]*#[[:space:]]*LOADER_SEMANTICS_PIN:[[:space:]]*([0-9][^[:space:]]*).*/\1/p' "$bundle_file" | head -1)"
canary="$(sed -nE 's/^[[:space:]]*#[[:space:]]*LOADER_SEMANTICS_PIN:[[:space:]]*([0-9][^[:space:]]*).*/\1/p' "$canary_file" | head -1)"

[ -n "$deployed" ] || fail "could not parse \`upstreamVersion\` from $nix_file"
[ -n "$replica" ] || fail "could not parse \`LOADER_VERSION\` from $test_file"
[ -n "$fixtures" ] || fail "$fixture_version_file is empty"
[ -n "$bundle" ] || fail "could not find a \`# LOADER_SEMANTICS_PIN: <version>\` marker in $bundle_file" \
  "" \
  "That marker couples the bundle checkPhase's v1-shape assertions to the loader" \
  "version they mirror. If the marker was deleted or reworded, this arm of the" \
  "guard is silently dead -- restore it rather than dropping the check."
[ -n "$canary" ] || fail "could not find a \`# LOADER_SEMANTICS_PIN: <version>\` marker in $canary_file" \
  "" \
  "That marker couples the PRODUCTION canary's log pattern to the loader version" \
  "whose output it greps. Without it, an upstream reword blinds the only leg that" \
  "covers 8 of the 9 deployed plugin files -- silently, and green."

refresh_recipe() {
  cat <<EOF
  V=$deployed
  F=assets/opencode/plugins/test/fixtures
  U="https://raw.githubusercontent.com/sst/opencode/v\$V/packages"

  # 1. Upstream sources, verbatim. (sst/opencode and anomalyco/opencode serve
  #    byte-identical content for v1.17.13; the difference is cosmetic.)
  for f in index shared; do
    curl -sfL "\$U/opencode/src/plugin/\$f.ts" -o "\$F/plugin-\$f.ts"
  done
  # NB: loader.ts is vendored under its own name, NOT as plugin-loader.ts.
  curl -sfL "\$U/opencode/src/plugin/loader.ts"        -o "\$F/loader.ts"
  curl -sfL "\$U/opencode/src/config/plugin.ts"        -o "\$F/config-plugin.ts"
  curl -sfL "\$U/core/src/observability/logging.ts"    -o "\$F/logging.ts"

  # 2. OUR loader patch, from the fork, at the release we deploy.
  curl -sfL "https://raw.githubusercontent.com/johnnymo87/opencode-patched/v${deployed}-patched${rev_suffix}/patches/plugin-loader-observability.patch" \\
    -o "\$F/plugin-loader-observability.patch"

  # 3. Compose the patched fixture: what production ACTUALLY runs.
  s=\$(mktemp -d); mkdir -p "\$s/packages/opencode/src/plugin"
  cp "\$F/plugin-index.ts" "\$s/packages/opencode/src/plugin/index.ts"
  (cd "\$s" && patch -p1 --silent < "\$OLDPWD/\$F/plugin-loader-observability.patch")
  cp "\$s/packages/opencode/src/plugin/index.ts" "\$F/plugin-index.patched.ts"
  rm -rf "\$s"

  # 4. Record the patch identity where the canary can see it, and the version.
  sha256sum "\$F/plugin-loader-observability.patch" | cut -d' ' -f1
  #   -> paste into the '# LOADER_PATCH_SHA256:' marker in
  #      pkgs/opencode-plugin-canary-sh/opencode-plugin-canary.sh
  echo "\$V" > "\$F/VERSION"
EOF
}

if [ "$replica" != "$deployed" ]; then
  fail \
    "  deployed opencode (home.base.nix upstreamVersion): $deployed" \
    "  loader replica pin (LOADER_VERSION):               $replica" \
    "" \
    "plugin-loader-contract.test.ts replicates opencode's plugin loader and is" \
    "pinned to a version we no longer deploy. Until this is resolved that test" \
    "is asserting a contract that may not exist, and will keep passing." \
    "" \
    "Re-verify the loader semantics against the vendored fixtures:" \
    "  curl -sL https://raw.githubusercontent.com/sst/opencode/v$deployed/packages/opencode/src/plugin/index.ts | diff - assets/opencode/plugins/test/fixtures/plugin-index.ts" \
    "  curl -sL https://raw.githubusercontent.com/sst/opencode/v$deployed/packages/opencode/src/plugin/shared.ts | diff - assets/opencode/plugins/test/fixtures/plugin-shared.ts" \
    "" \
    "If the diffs are empty, the semantics are unchanged: refresh the fixtures" \
    "and bump LOADER_VERSION." \
    "If they are NOT empty, update the replica FIRST, then the pin." \
    "" \
    "$(refresh_recipe)"
fi

if [ "$fixtures" != "$replica" ]; then
  fail \
    "  loader replica pin (LOADER_VERSION): $replica" \
    "  vendored fixtures (fixtures/VERSION): $fixtures" \
    "" \
    "The pin was bumped without refreshing the vendored upstream sources, so the" \
    "'mechanical diff' recipe now points at sources describing a different" \
    "version. This is the lazy path out of a red pin, and it makes the next" \
    "person's re-verification actively misleading." \
    "" \
    "$(refresh_recipe)"
fi

if [ "$bundle" != "$replica" ]; then
  fail \
    "  loader replica pin (LOADER_VERSION):            $replica" \
    "  bundle checkPhase (LOADER_SEMANTICS_PIN):       $bundle" \
    "" \
    "pkgs/opencode-plugin-bundle/default.nix asserts the v1 plugin shape against" \
    "the BUILT artifact -- a third copy of loader semantics, and the only cover" \
    "the bundled plugins have until step 4 of the plugin-loader hardening" \
    "roadmap runs CI against deployed artifacts." \
    "" \
    "Re-read readV1Plugin and readPluginId in the refreshed fixtures and confirm" \
    "the checkPhase still mirrors them (id trimming, the server/tui rules), then" \
    "move its LOADER_SEMANTICS_PIN marker to $replica." \
    "" \
    "Note the checkPhase is deliberately STRICTER than the loader in one place:" \
    "it rejects a bare-function default, which the loader still accepts. That is" \
    "a policy ratchet against reverting to the legacy shape, not a mirror, and" \
    "it should survive a pin bump untouched."
fi

if [ "$canary" != "$replica" ]; then
  fail \
    "  loader replica pin (LOADER_VERSION):              $replica" \
    "  plugin canary (LOADER_SEMANTICS_PIN):            $canary" \
    "" \
    "pkgs/opencode-plugin-canary-sh/opencode-plugin-canary.sh greps the SERVE LOG" \
    "for opencode's own plugin load-failure line. The message string and the" \
    "\`path=file://...\` field it parses are upstream internals, and this is the" \
    "only copy of loader semantics that runs in production." \
    "" \
    "If upstream reworded that line, the canary's log leg is now blind -- and it is" \
    "the ONLY cover for 8 of the 9 deployed plugin files, including opencode-pigeon.ts" \
    "and superpowers.js, which have no build-time cover at all. It fails GREEN: the" \
    "fixtures below still carry the old string." \
    "" \
    "Re-read the logError call in the refreshed fixtures and confirm both the" \
    "message text and the path= field still match:" \
    "  grep -n 'failed to load plugin' assets/opencode/plugins/test/fixtures/plugin-index.ts" \
    "" \
    "Then move the marker to $replica. Do NOT move it to make this quiet."
fi

# ---------------------------------------------------------------------------
# The loader patch's identity (constant 6), and what it must still produce.
#
# The five constants above answer "which UPSTREAM loader?". They deliberately
# stay on the upstream version and say nothing about our own patch -- keying
# them to patchedRevision would turn this guard red on every one of the fork's
# ~27 patches, on a PR update-opencode-patched.yml AUTO-MERGES. A guard that
# cries wolf on every release is pin-rot in a fresh costume.
#
# So our patch is pinned separately, by content, in three layers:
#   6a. the vendored patch's sha256 is recorded in the canary (forced visit)
#   6b. plugin-index.patched.ts must equal pristine + patch (no hand-edits)
#   6c. the strings the canary greps must actually occur in that composed file
#
# 6c is the one that pins MEANING rather than bytes: it is the only mechanical
# link between the production canary's patterns and the loader source. Without
# it, that link is human ritual -- displayed only in a failure message that
# appears when the guard is already red for some other reason.
# ---------------------------------------------------------------------------

recorded_sha="$(sed -nE 's/^[[:space:]]*#[[:space:]]*LOADER_PATCH_SHA256:[[:space:]]*([0-9a-f]{64}).*/\1/p' "$canary_file" | head -1)"
actual_sha="$(sha256sum "$patch_file" | cut -d' ' -f1)"

[ -n "$recorded_sha" ] || fail \
  "could not find a \`# LOADER_PATCH_SHA256: <sha256>\` marker in $canary_file" \
  "" \
  "That marker is how editing OUR loader patch forces a visit to the canary --" \
  "the script whose grep patterns the patch's log lines have to satisfy. If it" \
  "was deleted or reworded, this arm is silently dead. Restore it."

if [ "$actual_sha" != "$recorded_sha" ]; then
  fail \
    "  vendored loader patch (sha256): $actual_sha" \
    "  recorded in canary  (marker):   $recorded_sha" \
    "" \
    "assets/opencode/plugins/test/fixtures/plugin-loader-observability.patch is" \
    "our own patch to opencode's plugin loader. It changed, and the canary has" \
    "not been re-read." \
    "" \
    "That patch is the ONLY reason plugin load failures are visible at all: it" \
    "adds the log line at the four report.error stages and at report.missing," \
    "which upstream leaves completely silent. The production canary parses that" \
    "line. Go read these three places in $canary_file and confirm the patch" \
    "still satisfies them:" \
    "" \
    "  :50   the anchored pattern      ^timestamp=... level=ERROR ...failed to load plugin" \
    "  :97   per-file key extraction   path=file://.../plugins/<name>" \
    "  :100  the fallback extraction   path=file://.../<name>" \
    "" \
    "THEN update the marker:" \
    "  sha256sum assets/opencode/plugins/test/fixtures/plugin-loader-observability.patch" \
    "" \
    "Do NOT regenerate the marker to make this quiet. Rewording the message or" \
    "dropping the \`path\` field blinds the canary while every test stays green --" \
    "and that leg is the only cover for 8 of the 9 deployed plugin files."
fi

# 6b: the patched fixture must be exactly pristine-upstream + our patch.
compose_dir="$(mktemp -d)"
trap 'rm -rf "$compose_dir"' EXIT
mkdir -p "$compose_dir/packages/opencode/src/plugin"
cp "$pristine_index" "$compose_dir/packages/opencode/src/plugin/index.ts"
if ! (cd "$compose_dir" && patch -p1 --silent < "$patch_file") 2>/dev/null; then
  fail \
    "our loader patch does not apply to the vendored pristine upstream loader" \
    "" \
    "  patch:    $patch_file" \
    "  pristine: $pristine_index" \
    "" \
    "Either the fixtures were refreshed to a new upstream whose loader moved" \
    "under the patch, or the patch was edited. If upstream moved, the fork's" \
    "patch needs rebasing FIRST -- a patch that no longer applies means the next" \
    "fork build silently loses the observability it adds." \
    "" \
    "$(refresh_recipe)"
fi
if ! diff -q "$compose_dir/packages/opencode/src/plugin/index.ts" "$patched_index" >/dev/null; then
  fail \
    "  composed (pristine + patch): differs" \
    "  vendored plugin-index.patched.ts" \
    "" \
    "plugin-index.patched.ts is supposed to BE upstream plus our patch -- it is" \
    "the fixture that describes the loader actually running in production. It" \
    "does not match what composing them produces, so it was hand-edited or a" \
    "refresh was done halfway." \
    "" \
    "A hand-edited 'patched' fixture is worse than none: every other check here" \
    "and the canary's re-verification ritual read it as ground truth." \
    "" \
    "Regenerate it -- never edit it by hand:" \
    "" \
    "$(refresh_recipe)"
fi

# 6c: the canary's literals must occur in the loader that production runs.
canary_msg="$(sed -nE "s/^[[:space:]]*printf .*level=ERROR \.\*(.+)'[[:space:]]*$/\1/p" "$canary_file" | head -1)"
[ -n "$canary_msg" ] || fail \
  "could not extract the load-failure message literal from $canary_file" \
  "" \
  "Expected a line of the shape:" \
  "  printf '%s\\\\n' '^timestamp=[^ ]+ level=ERROR .*<message literal>'" \
  "" \
  "This guard reads that literal and checks it against the loader source, so a" \
  "reword of either side goes red. If the pattern was restructured, repoint" \
  "this extraction -- do not drop the check."

if ! grep -qF "$canary_msg" "$patched_index"; then
  fail \
    "  canary greps for:  \"$canary_msg\"" \
    "  not found in:      $patched_index" \
    "" \
    "The production canary is looking for a message the loader no longer emits." \
    "This is the canary's failure mode that fails GREEN: nothing errors, the" \
    "log leg simply never matches again, and the only cover for 8 of the 9" \
    "deployed plugin files is gone silently." \
    "" \
    "Reconcile them. If the loader's wording changed deliberately, update the" \
    "canary pattern at $canary_file:50 to match, then re-run."
fi

# EVERY emission site must carry the `path` annotation -- not merely one of them.
#
# Checking that `path:` appears *somewhere* would be satisfied by upstream's own
# apply-stage call alone, and so could not see our patch dropping `path` from
# the five load-stage sites it adds -- which are the entire reason this pin
# exists. Per-site is what makes the check reachable: it is the one assertion
# here that a dutifully-regenerated LOADER_PATCH_SHA256 marker cannot silence.
missing_path="$(grep -n 'failed to load plugin' "$patched_index" | grep -v 'path:' || true)"
if [ -n "$missing_path" ]; then
  fail \
    "a load-failure log site in $patched_index omits the \`path\` annotation:" \
    "" \
    "$missing_path" \
    "" \
    "The canary extracts its per-file key from \`path=file://...\` ($canary_file:97,100)." \
    "A site without it still logs, still trips the canary red -- but it can no" \
    "longer say WHICH plugin broke, and it cannot auto-clear per file. Every" \
    "failure collapses into one shared \`unknown\` latch." \
    "" \
    "That is a silent downgrade: the canary keeps working, so nothing announces" \
    "that per-file attribution was lost."
fi

# 6d: the CALL SITES, which neither check above can see.
#
# Our patch routes all five stages through one helper, so the literal
# "failed to load plugin" appears only at the helper's definition and at
# upstream's own apply-stage call. Delete both call sites -- a plausible
# outcome of resolving a rebase conflict in the report.error region -- and every
# check above stays green while all five stages go silent again: the exact
# blindness this whole bead exists to kill, reinstated inside its own fix.
#
# Checking the emitted STRING therefore cannot establish that anything emits it.
# These assertions name the call sites instead. They will red on a legitimate
# refactor of the patch; that is the same reconcile-and-move cost the other
# constants impose, and it is paid at a moment when the loader really did change.
assert_site() {
  local needle="$1" what="$2"
  grep -qF "$needle" "$patched_index" || fail \
    "$what is missing from $patched_index" \
    "" \
    "  expected to find: $needle" \
    "" \
    "This file is composed from pristine upstream plus our loader patch, so the" \
    "site vanished from the PATCH -- most likely a rebase onto a new upstream" \
    "where a hunk in this region was resolved by dropping it." \
    "" \
    "Upstream logs NOTHING at the four report.error stages or at report.missing." \
    "Measured: a real unpatched binary emitted 0 log lines, 0 level=ERROR lines," \
    "and 118 bytes of stdout while THREE plugins failed to load, returning HTTP" \
    "200 throughout. Our patch is the only thing standing between that and the" \
    "production canary." \
    "" \
    "Losing one of these sites is invisible to every other check here: the" \
    "message string still occurs elsewhere in the file, so the canary's pattern" \
    "still matches something and the guard would otherwise stay green while the" \
    "stage it covered went dark. Restore the site; do not weaken this check."
}

assert_site 'function logPluginError('                          "the load-failure log helper"

# ...and the helper must emit the string the canary greps for. Checking only
# that the literal occurs SOMEWHERE in the file (6c) is satisfied by upstream's
# own apply-stage call at the bottom, so rewording just our helper would leave
# 6c green while install/compatibility/entry/load/missing all stopped matching.
# Same shape as the two weaknesses already fixed above: a check answered by a
# line other than the one it is actually about.
helper_body="$(sed -n '/function logPluginError(/,/^ *}/p' "$patched_index")"
if ! printf '%s' "$helper_body" | grep -qF "$canary_msg"; then
  fail \
    "the load-failure helper does not emit the message the canary greps for" \
    "" \
    "  canary greps for: \"$canary_msg\"" \
    "  helper body:" \
    "$helper_body" \
    "" \
    "Every one of the five previously-silent stages logs through this helper." \
    "If its message no longer matches, the canary goes blind on all five at once" \
    "-- while staying GREEN, because upstream's own apply-stage call still" \
    "carries the old string elsewhere in this file." \
    "" \
    "Reconcile the two. If the wording changed deliberately, update the canary" \
    "pattern at $canary_file:50 to match."
fi
assert_site 'logPluginError(candidate.plan.spec, "missing"'     "the report.missing call site (the quietest stage: upstream's is a bare no-op that does not even publishPluginError)"
assert_site 'logPluginError(spec, stage, message)'              "the report.error call site (covers all four of install/compatibility/entry/load)"
assert_site 'Effect.logInfo("plugin loaded"'                    "the per-plugin success line (workstation-0lkp will key auto-clear on it)"

echo "OK: loader pin consistent (deployed=$deployed replica=$replica fixtures=$fixtures bundle=$bundle canary=$canary)"
echo "OK: loader patch identity ${actual_sha:0:12}… ; composed fixture matches; canary literal \"$canary_msg\" present"
