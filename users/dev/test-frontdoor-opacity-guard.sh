#!/usr/bin/env bash
# Meta-test: perturbation tests for test-frontdoor-opacity.sh.
#
# The guard's whole value is failing CLOSED on a new direct-to-serve call. A guard
# that cannot fail is a defect, and this project has shipped three "fixes" that
# reported healthy while doing nothing. So: copy the guard's universe into a
# fixture, perturb it, and assert the guard goes RED with the RIGHT message.
#
# Run: bash users/dev/test-frontdoor-opacity-guard.sh
set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
guard="users/dev/test-frontdoor-opacity.sh"
table="docs/plans/2026-07-26-phase9-consumer-disposition.md"

fail=0
pass_() { printf 'ok: %s\n' "$1"; }
bad()   { printf 'FAIL: %s\n' "$1"; fail=1; }

# A fixture is a minimal copy of everything the guard reads: itself, the table,
# and every governed file. Copied with --parents so relative paths survive.
new_fixture() {
  local fix; fix="$(mktemp -d)"
  ( cd "$repo_root" \
    && cp --parents --no-preserve=mode "$guard" "$table" $(printf '%s\n' \
         pkgs/*/default.nix \
         users/dev/home.base.nix users/dev/home.darwin.nix \
         users/dev/home.devbox.nix users/dev/home.cloudbox.nix \
         hosts/cloudbox/configuration.nix hosts/devbox/configuration.nix \
         2>/dev/null | while read -r f; do [ -f "$f" ] && echo "$f"; done) \
         "$fix/" )
  chmod -R +w "$fix"
  printf '%s' "$fix"
}

# Run the guard in a fixture. Output goes to a FILE; never pipe into grep -q,
# which under pipefail inverts its own result.
run_guard() {
  local fix="$1" out="$2"
  set +o errexit
  ( cd "$fix" && bash "$guard" ) > "$out" 2>&1
  local rc=$?
  set -o errexit
  return $rc
}

# Assert the guard is GREEN on an unperturbed fixture. If this fails, every
# perturbation case below is meaningless.
fix="$(new_fixture)"; out="$(mktemp)"
if run_guard "$fix" "$out"; then
  pass_ "baseline: guard is green on an unperturbed tree"
else
  bad "baseline: guard is RED on an unperturbed tree -- fix the tree before trusting any case below"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

# Case: a marker citing a row that does NOT name the citing file must be rejected.
# This is the exact shape a peer's subagent shipped on 2026-07-31 -- C3/C4 (cloudbox
# rows) cited from home.devbox.nix -- and the guard blessed it. Once the gate is
# armed this becomes the path of least resistance for anyone it blocks, so it must
# fail CLOSED.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i 's/frontdoor-exempt(C10)/frontdoor-exempt(C3)/' "$fix/users/dev/home.devbox.nix"
if run_guard "$fix" "$out"; then
  bad "laundering: guard PASSED a marker citing C3, a row that does not name home.devbox.nix"
else
  if grep -q 'does not name' "$out"; then
    pass_ "laundering: marker citing a row that does not name its file is rejected"
  else
    bad "laundering: guard failed, but not with the path-mismatch message (masked by another failure?)"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"

# Case: a marker citing a sibling-directory row (D2, naming home.darwin.nix) from
# home.devbox.nix must be rejected. The dirname fallback previously let any row
# in the same directory satisfy the check.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i 's/frontdoor-exempt(C10)/frontdoor-exempt(D2)/' "$fix/users/dev/home.devbox.nix"
if run_guard "$fix" "$out"; then
  bad "laundering: guard PASSED a marker citing D2 (home.darwin.nix) from home.devbox.nix (sibling directory leak)"
else
  if grep -q 'does not name' "$out"; then
    pass_ "laundering: marker citing a sibling-directory row (D2) is rejected"
  else
    bad "laundering: guard failed, but not with the path-mismatch message (masked by another failure?)"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"

# Case: a non-pool port (4090-4095) is not a serve and must not be flagged. The
# pool is :4096-4099. A peer adding a :4091 harness would otherwise be blocked with
# no legitimate row to cite -- the guard would be demanding a lie.
fix="$(new_fixture)"; out="$(mktemp)"
printf '\n  # harness, not a serve\n  TEST_HARNESS_URL = "http://127.0.0.1:4091/health";\n' >> "$fix/users/dev/home.base.nix"
if run_guard "$fix" "$out"; then
  pass_ "site-re: a non-pool port (:4091) is not treated as a serve-addressing site"
else
  bad "site-re: :4091 was flagged as a serve site (SITE_RE still matches 409[0-9])"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

# Case: a smuggled direct-to-serve call with a :-http default expansion must be caught, not skipped.
fix="$(new_fixture)"; out="$(mktemp)"
cat >> "$fix/users/dev/home.base.nix" <<'PERTURB'
  smuggledKill = ''curl -fsS -X POST "${OPENCODE_URL:-http://127.0.0.1:4096}/session/$sid/kill"'';
PERTURB
if run_guard "$fix" "$out"; then
  bad "skip-laundering: guard PASSED a smuggled :-http direct-to-serve call"
else
  if grep -q 'addresses a serve with no frontdoor-exempt marker' "$out"; then
    pass_ "skip-laundering: smuggled :-http direct-to-serve call is caught"
  else
    bad "skip-laundering: guard failed, but not with no-marker message"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"

# Case: a bare default assignment containing :-http puts a value in scope and must NOT be flagged.
fix="$(new_fixture)"; out="$(mktemp)"
cat >> "$fix/users/dev/home.base.nix" <<'PERTURB'
  FOO_URL="${FOO_URL:-http://127.0.0.1:4096}"
PERTURB
if run_guard "$fix" "$out"; then
  pass_ "skip-laundering: bare :-http assignment is skipped (not falsely flagged)"
else
  bad "skip-laundering: bare :-http assignment was falsely flagged as a serve site"
  sed 's/^/      /' "$out"
fi
rm -rf "$fix" "$out"

# Case: a file whose sites all rot out of the pattern, but which keeps its markers,
# must FAIL rather than silently pass. The per-file 1:1 check was gated on
# `fsites -gt 0`, so total rot in one file was invisible -- the exact shape of the
# [^\n] bug that once let 10 of 11 sites stop matching.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i 's|127\.0\.0\.1:4096|127.0.0.1:9999|g; s|\${serve_url}/|${serve_url}_ROTTED/|g; s|\$serve_url/|$serve_url_ROTTED/|g; s|OPENCODE_ANCHOR_URL=|OPENCODE_ANCHOR_URLX=|g' \
  "$fix/users/dev/home.devbox.nix"
if run_guard "$fix" "$out"; then
  bad "rot: a file kept its markers while all its sites stopped matching, and the guard passed"
else
  if grep -q 'ZERO matching sites' "$out"; then
    pass_ "rot: markers with zero matching sites is a failure"
  else
    bad "rot: guard failed, but not with ZERO matching sites (masked by another failure?)"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"

# Case: a NEW site in a file that already has sites, citing an EXISTING valid row,
# passes every per-site check. Only a count-shaped invariant catches it. This is why
# the manifest cannot be dropped in favour of per-site markers alone.
fix="$(new_fixture)"; out="$(mktemp)"
cat >> "$fix/users/dev/home.devbox.nix" <<'PERTURB'
  # frontdoor-exempt(C10): smuggled extra site citing a real, file-naming row
  extraProbe = "http://127.0.0.1:4096/global/health";
PERTURB
if run_guard "$fix" "$out"; then
  bad "manifest: an extra site citing an existing valid row passed -- no count-shaped invariant"
else
  pass_ "manifest: an extra site is caught by the per-file count"
fi
rm -rf "$fix" "$out"

# Case: a governed file absent from the manifest must fail, not pass silently.
fix="$(new_fixture)"; out="$(mktemp)"
sed -i '/^users\/dev\/home\.darwin\.nix /d' "$fix/$guard"
if run_guard "$fix" "$out"; then
  bad "manifest: a governed file missing from the manifest passed"
else
  pass_ "manifest: a governed file missing from the manifest is caught"
fi
rm -rf "$fix" "$out"

# Case: adding a serve site to a governed file that has NO manifest line and NO sites
# (e.g. home.base.nix) must fail, proving dropping 0-count lines did not open a hole.
# The site carries a valid exemption marker citing a row naming home.base.nix so ONLY the manifest check can fire.
fix="$(new_fixture)"; out="$(mktemp)"
printf '| C12 | `users/dev/home.base.nix` | `exempt-infra` | test row |\n' >> "$fix/$table"
cat >> "$fix/users/dev/home.base.nix" <<'PERTURB'
  # frontdoor-exempt(C12): test site in unlisted file
  probe = "http://127.0.0.1:4096/global/health";
PERTURB
if run_guard "$fix" "$out"; then
  bad "manifest: adding a site to a file absent from the manifest passed -- hole opened by dropping 0-lines"
else
  if grep -q 'no EXPECTED_MANIFEST line' "$out"; then
    pass_ "manifest: adding a site to an unlisted file is caught by manifest check"
  else
    bad "manifest: guard failed, but not with no EXPECTED_MANIFEST line"
    sed 's/^/      /' "$out"
  fi
fi
rm -rf "$fix" "$out"

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
