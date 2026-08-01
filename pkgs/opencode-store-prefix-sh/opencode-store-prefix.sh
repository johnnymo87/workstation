#!/usr/bin/env bash
# opencode-store-prefix.sh -- shared store-path reduction for staleness checks.
#
# WHY THIS EXISTS (2026-08-01, beads workstation-jj5x):
# Comparing "is this running process the binary the profile currently pins?"
# CANNOT be done with full-path equality, because the two sides resolve to
# DIFFERENT FINAL COMPONENTS inside the SAME store path:
#
#   readlink -f ~/.nix-profile/bin/opencode
#     -> /nix/store/<hash>-opencode-patched-1.17.13.6/bin/opencode
#   readlink /proc/<pid>/exe
#     -> /nix/store/<hash>-opencode-patched-1.17.13.6/bin/.opencode-wrapped
#
# `bin/opencode` is a wrapper that execs `bin/.opencode-wrapped` in the same
# store path, so /proc/<pid>/exe never equals the profile path even when the
# serve is perfectly fresh. A full-path `[ "$a" = "$b" ]` therefore reports
# STALE unconditionally -- a check that cannot produce a true negative, which
# is the same class of defect as a test that cannot fail.
#
# On 2026-08-01 an operator ran exactly that broken one-liner ad hoc, concluded
# all four pool serves were stale, and restarted the whole pool, killing live
# user sessions. The serves were fresh: profile generations 1957/1959/1961 all
# pinned the same opencode store hash. The deployed serve-canary was NOT
# affected -- it had always reduced both sides to the store-path prefix -- but
# that logic had ZERO test coverage, so nothing stopped it regressing into the
# broken form. This library is that logic, extracted so it can be tested.
#
# The correct comparison is the /nix/store/<hash>-<name> prefix of both sides.
#
# Pure bash: no coreutils, no PATH dependency, safe to source from a systemd
# unit's minimal environment.

# opencode_store_prefix PATH
#
# Echoes the first four slash-separated fields of PATH -- for a store path that
# is exactly `/nix/store/<hash>-<name>`. Byte-for-byte equivalent to the
# `cut -d/ -f1-4` this replaces, INCLUDING for non-store input: like cut, a path
# with fewer than four fields is echoed unchanged. That equivalence is
# deliberate. Callers on the "running binary" side rely on a non-store exe
# yielding a non-empty, non-matching value so it still registers as drift; if
# this returned empty for such paths, a serve running a binary from outside the
# store would be silently reclassified as "unknown" and never alerted on.
#
# Empty input echoes nothing.
opencode_store_prefix() {
  local path="${1:-}"
  [ -n "$path" ] || return 0

  local -a fields
  local IFS=/
  read -r -a fields <<< "$path"

  # Fewer than 4 fields: echo unchanged (cut's behaviour).
  if [ "${#fields[@]}" -lt 4 ]; then
    printf '%s\n' "$path"
    return 0
  fi

  printf '%s/%s/%s/%s\n' "${fields[0]}" "${fields[1]}" "${fields[2]}" "${fields[3]}"
}

# opencode_is_opencode_prefix PREFIX
#
# True only when PREFIX is a verified opencode package store path. Used to gate
# the REFERENCE side of a staleness comparison, where anything else must be
# treated as UNKNOWN rather than as drift.
#
# INCIDENT 2026-07-25 (bead workstation-bcmi): `readlink -f` resolves PARENT
# directories and returns a path even when the FINAL COMPONENT DOES NOT EXIST.
# During a home-manager switch there is a window where ~/.nix-profile/bin/opencode
# is missing, so the reference resolved to `/nix/store/<hash>-profile/bin/opencode`
# -- non-empty, but pointing at the PROFILE instead of through to the opencode
# package. Its prefix cannot equal any serve's real prefix, so ALL serves were
# reported as drifted. The serves were correct; the check was wrong. Hence a
# structural shape gate, not merely a non-empty test.
#
# Deliberately NOT applied to the running-binary side: a serve that genuinely
# drifted onto some other package must still compare unequal and alert.
opencode_is_opencode_prefix() {
  case "${1:-}" in
    /nix/store/*-opencode-patched-*) return 0 ;;
    *) return 1 ;;
  esac
}
