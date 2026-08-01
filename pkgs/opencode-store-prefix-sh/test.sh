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
# The staleness verdict itself
# ---------------------------------------------------------------------------

# The comparison as the canary performs it.
verdict() { # ref_exe run_exe
  local ref run
  ref="$(opencode_store_prefix "$1")"
  run="$(opencode_store_prefix "$2")"
  opencode_is_opencode_prefix "$ref" || { echo UNKNOWN; return; }
  [ -n "$run" ] || { echo UNKNOWN; return; }
  if [ "$ref" = "$run" ]; then echo FRESH; else echo STALE; fi
}

# The comparison as it was written by hand on 2026-08-01, and as it must never
# be written again. Kept executable so the difference is asserted, not narrated.
broken_verdict() { # ref_exe run_exe
  if [ "$1" = "$2" ]; then echo FRESH; else echo STALE; fi
}

assert_eq "FRESH" "$(verdict "$PROFILE_EXE" "$PROC_EXE")" \
  "fresh serve is NOT reported stale (the 2026-08-01 false positive)"
assert_eq "STALE" "$(broken_verdict "$PROFILE_EXE" "$PROC_EXE")" \
  "full-path equality DOES misreport that same fresh serve (regression sentinel)"

# True positives must survive: a real version bump is still caught.
OLD="/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-opencode-patched-1.17.13.5/bin/.opencode-wrapped"
assert_eq "STALE" "$(verdict "$PROFILE_EXE" "$OLD")" \
  "serve running an older opencode store path IS reported stale"

# A serve whose exe escaped the store must still compare unequal, not be
# silently downgraded to UNKNOWN.
assert_eq "STALE" "$(verdict "$PROFILE_EXE" "/usr/bin/opencode")" \
  "serve running a non-store binary IS reported stale"

# Reference unresolvable (home-manager switch in flight) => never alert.
assert_eq "UNKNOWN" "$(verdict "/nix/store/5ndra5mzxggfh28icamhcwqdi8h6hm5j-profile/bin/opencode" "$PROC_EXE")" \
  "unresolvable reference is UNKNOWN, not drift (workstation-bcmi)"
assert_eq "UNKNOWN" "$(verdict "$PROFILE_EXE" "")" \
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

# ...and actually calls it on BOTH sides of the comparison. Sourcing without
# calling would leave a hand-rolled comparison in place, which is the defect.
for fn_site in 'REF_PREFIX_CANDIDATE=$(opencode_store_prefix' 'RUN_PREFIX=$(opencode_store_prefix'; do
  if grep -qF "$fn_site" "$canary_src"; then
    printf 'PASS  %s\n' "cloudbox serve-canary derives prefix via helper: ${fn_site%%=*}"
  else
    printf 'FAIL  %s\n' "cloudbox serve-canary derives prefix via helper: ${fn_site%%=*}"; fail=1
  fi
done

# The canary must never compare the raw exe paths to each other.
if grep -qE '\[ *"\$RUN_EXE" *!?= *"\$REF_EXE" *\]|\[ *"\$REF_EXE" *!?= *"\$RUN_EXE" *\]' "$canary_src"; then
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
