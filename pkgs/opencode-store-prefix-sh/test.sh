#!/usr/bin/env bash
# Unit tests for opencode-store-prefix.sh.
#
# The load-bearing test is `fresh serve is NOT reported stale` below. It is
# built from the real pair of paths observed on cloudbox 2026-08-01:
#
#   profile:        /nix/store/<H>-opencode-patched-1.17.13.6/bin/opencode
#   /proc/<pid>/exe /nix/store/<H>-opencode-patched-1.17.13.6/bin/.opencode-wrapped
#
# Same store path, different final component. A full-path equality check calls
# that STALE, always. This suite fails if the comparison ever regresses to that
# form -- see `broken_verdict` below, which encodes the wrong implementation and
# asserts that it disagrees, so the distinction cannot be quietly erased.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
# shellcheck source=./opencode-store-prefix.sh
source "$script_dir/opencode-store-prefix.sh"

fail=0
assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'PASS  %s\n' "$desc"
  else
    printf 'FAIL  %s\n        expected: %q\n        got:      %q\n' "$desc" "$expected" "$actual"
    fail=1
  fi
}

H=wlxpj0h74b85k9rghn3a8r4iyc70g3k1
PKG="/nix/store/$H-opencode-patched-1.17.13.6"
PROFILE_EXE="$PKG/bin/opencode"
PROC_EXE="$PKG/bin/.opencode-wrapped"

# ---------------------------------------------------------------------------
# opencode_store_prefix
# ---------------------------------------------------------------------------
assert_eq "$PKG" "$(opencode_store_prefix "$PROFILE_EXE")" \
  "prefix of the profile-resolved binary"
assert_eq "$PKG" "$(opencode_store_prefix "$PROC_EXE")" \
  "prefix of the /proc/<pid>/exe wrapper target"
assert_eq "$PKG" "$(opencode_store_prefix "$PKG")" \
  "prefix of a bare store path is itself"
assert_eq "" "$(opencode_store_prefix "")" \
  "empty input yields empty output"

# Equivalence with the `cut -d/ -f1-4` this replaced, including the non-store
# case the running-binary side depends on (see the library comment).
assert_eq "/usr/bin/opencode" "$(opencode_store_prefix /usr/bin/opencode)" \
  "non-store path with <4 fields echoes unchanged (cut parity)"
assert_eq "/opt/a/b" "$(opencode_store_prefix /opt/a/b/c/d)" \
  "non-store path with >4 fields truncates to 4 (cut parity)"

# ---------------------------------------------------------------------------
# opencode_is_opencode_prefix -- the reference-side shape gate
# ---------------------------------------------------------------------------
if opencode_is_opencode_prefix "$PKG"; then
  printf 'PASS  %s\n' "opencode package prefix accepted as reference"
else
  printf 'FAIL  %s\n' "opencode package prefix accepted as reference"; fail=1
fi

# The workstation-bcmi failure: mid-switch, readlink -f lands on the profile.
if opencode_is_opencode_prefix "/nix/store/5ndra5mzxggfh28icamhcwqdi8h6hm5j-profile"; then
  printf 'FAIL  %s\n' "profile store path rejected as reference (workstation-bcmi)"; fail=1
else
  printf 'PASS  %s\n' "profile store path rejected as reference (workstation-bcmi)"
fi

if opencode_is_opencode_prefix "/usr/bin/opencode"; then
  printf 'FAIL  %s\n' "non-store path rejected as reference"; fail=1
else
  printf 'PASS  %s\n' "non-store path rejected as reference"
fi

# ---------------------------------------------------------------------------
# opencode_reference_prefix -- resolution of the comparison reference
#
# Exercised against REAL files, because the executability check is a filesystem
# fact. An earlier revision of this suite re-implemented the composition inline
# and consequently could not have caught the reference gate being deleted.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mk_exe() { # relative path under $tmp -> absolute path
  local p="$tmp/$1"
  mkdir -p "$(dirname "$p")"
  : > "$p"
  chmod +x "$p"
  printf '%s\n' "$p"
}
# An executable file that is NOT shaped like an opencode package. The mktemp
# root (/tmp/... locally, /build/... in the nix sandbox) means the prefix
# reduction never yields a /nix/store path, so the shape gate must reject it --
# the same rejection that keeps a mid-switch `…-profile` path out.
wrong_shaped_exe="$(mk_exe "nix/store/5ndra5mzxggfh28icamhcwqdi8h6hm5j-profile/bin/opencode")"

# A correctly shaped path that cannot exist, so the executability branch is
# exercised without depending on what happens to be installed on this host.
MISSING_EXE="/nix/store/0000000000000000000000000000000z-opencode-patched-0.0.0/bin/opencode"
assert_eq "" "$(opencode_reference_prefix "$MISSING_EXE" 2>/dev/null)" \
  "correctly shaped but non-existent reference is UNKNOWN, not drift"

assert_eq "" "$(opencode_reference_prefix "$wrong_shaped_exe" 2>/dev/null)" \
  "executable but wrong-shaped reference is UNKNOWN, not drift (workstation-bcmi)"

# Positive path: an executable, correctly shaped reference must yield its prefix.
#
# This needs a REAL /nix/store path -- the shape gate is anchored at the literal
# /nix/store and a test may not write there, so no mktemp fixture can stand in.
# `nix flake check` therefore builds a throwaway package whose name matches the
# gate and passes it in via OPENCODE_TEST_PKG_BIN; the check then greps for this
# assertion's PASS line, because a skipped assertion is not a passing one.
#
# Without that env var (a bare `bash test.sh` on a dev machine) we fall back to
# whatever the profile resolves to, and SKIP if there is nothing usable. This is
# the ONLY assertion that can be skipped, and it must never be skipped in CI:
# an opencode_reference_prefix that returns "" unconditionally leaves every
# canary pass UNKNOWN -- drift detection dead, silently, forever -- and every
# other assertion here expects "" and would stay green through it.
ref_fixture="${OPENCODE_TEST_PKG_BIN:-}"
if [ -z "$ref_fixture" ]; then
  ref_fixture="$(readlink -f /home/dev/.nix-profile/bin/opencode 2>/dev/null || true)"
fi
if [ -n "$ref_fixture" ] && [ -x "$ref_fixture" ] \
   && opencode_is_opencode_prefix "$(opencode_store_prefix "$ref_fixture")"; then
  assert_eq "$(opencode_store_prefix "$ref_fixture")" \
    "$(opencode_reference_prefix "$ref_fixture" 2>/dev/null)" \
    "reference prefix returned for an executable opencode package path"
elif [ -n "${OPENCODE_TEST_PKG_BIN:-}" ]; then
  # The fixture was supplied and is unusable -- that is a broken gate, not a
  # missing convenience. Never degrade to SKIP here.
  printf 'FAIL  %s\n        OPENCODE_TEST_PKG_BIN unusable: %q\n' \
    "reference prefix returned for an executable opencode package path" \
    "$OPENCODE_TEST_PKG_BIN"
  fail=1
else
  printf 'SKIP  %s (no opencode package resolvable; CI supplies OPENCODE_TEST_PKG_BIN)\n' \
    "reference prefix returned for an executable opencode package path"
fi

assert_eq "" "$(opencode_reference_prefix "" 2>/dev/null)" \
  "empty reference is UNKNOWN, not drift"

# The NOTICE must reach the journal, on stderr, without polluting the value.
notice="$(opencode_reference_prefix "$wrong_shaped_exe" 2>&1 >/dev/null)"
case "$notice" in
  NOTICE:*unexpected*) printf 'PASS  %s\n' "wrong-shaped reference logs a NOTICE on stderr" ;;
  *) printf 'FAIL  %s\n        got: %q\n' "wrong-shaped reference logs a NOTICE on stderr" "$notice"; fail=1 ;;
esac

# ---------------------------------------------------------------------------
# opencode_drift_verdict -- the decision the canary actually executes
# ---------------------------------------------------------------------------

# The comparison as it was written by hand on 2026-08-01, and as it must never
# be written again. Kept executable so the difference is asserted, not narrated.
broken_verdict() { # ref_exe run_exe
  if [ "$1" = "$2" ]; then echo FRESH; else echo STALE; fi
}

assert_eq "FRESH" "$(opencode_drift_verdict "$PKG" "$PROC_EXE")" \
  "fresh serve is NOT reported stale (the 2026-08-01 false positive)"
assert_eq "STALE" "$(broken_verdict "$PROFILE_EXE" "$PROC_EXE")" \
  "full-path equality DOES misreport that same fresh serve (regression sentinel)"

# True positives must survive: a real version bump is still caught.
OLD="/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-opencode-patched-1.17.13.5/bin/.opencode-wrapped"
assert_eq "STALE" "$(opencode_drift_verdict "$PKG" "$OLD")" \
  "serve running an older opencode store path IS reported stale"

# A serve whose exe escaped the store must still compare unequal, not be
# silently downgraded to UNKNOWN.
assert_eq "STALE" "$(opencode_drift_verdict "$PKG" "/usr/bin/opencode")" \
  "serve running a non-store binary IS reported stale"

# Either side untrustworthy => never alert.
assert_eq "UNKNOWN" "$(opencode_drift_verdict "" "$PROC_EXE")" \
  "unresolvable reference is UNKNOWN, not drift (workstation-bcmi)"
assert_eq "UNKNOWN" "$(opencode_drift_verdict "$PKG" "")" \
  "unreadable /proc/<pid>/exe is UNKNOWN, not drift"

# ---------------------------------------------------------------------------
# Deployed-site guard
# ---------------------------------------------------------------------------
# A unit test for a library the shipped canary does not use would be exactly the
# defect this file exists to prevent. Assert the wiring.
# Grep for the literal `source` line, not merely for the package name -- the
# callPackage binding also mentions it, and a name-only grep passed even with
# the source line deleted.
canary_src="$repo_root/hosts/cloudbox/configuration.nix"
if grep -qF 'source "${opencode-store-prefix-sh}"' "$canary_src"; then
  printf 'PASS  %s\n' "cloudbox serve-canary sources the shared prefix library"
else
  printf 'FAIL  %s\n' "cloudbox serve-canary sources the shared prefix library"; fail=1
fi

# ...and actually delegates BOTH decisions to it. Sourcing without calling would
# leave a hand-rolled comparison in place, which is the defect. Note these guard
# the *reference resolution* and the *verdict* -- not merely the prefix helper --
# because an earlier revision wired only the prefix reduction, which left the
# reference shape gate (workstation-bcmi) deletable with every test still green.
declare -A required_calls=(
  ["REF_PREFIX=\$(opencode_reference_prefix"]="reference resolution (incl. the shape gate)"
  ["DRIFT_VERDICT=\$(opencode_drift_verdict"]="staleness verdict"
)
for call in "${!required_calls[@]}"; do
  if grep -qF "$call" "$canary_src"; then
    printf 'PASS  %s\n' "cloudbox serve-canary delegates ${required_calls[$call]}"
  else
    printf 'FAIL  %s\n' "cloudbox serve-canary delegates ${required_calls[$call]}"; fail=1
  fi
done

# Tripwire for the literal 2026-08-01 form. This is a backstop, NOT proof: a
# renamed variable evades it. The real protection is that the verdict lives in
# this library and is asserted above, so the call site has nothing left to get
# wrong.
if grep -qE '(\[\[?) *"?\$\{?(RUN|REF)_EXE\}?"? *[!=]?= *"?\$\{?(REF|RUN)_EXE\}?"?' "$canary_src"; then
  printf 'FAIL  %s\n' "cloudbox serve-canary does not compare raw exe paths"; fail=1
else
  printf 'PASS  %s\n' "cloudbox serve-canary does not compare raw exe paths"
fi

if [ "$fail" -eq 0 ]; then
  printf '\nAll opencode-store-prefix tests passed.\n'
else
  printf '\nFAILURES present.\n'
fi
exit "$fail"
