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
# Sole consumer today is the CLOUDBOX serve-canary (both sides of its one
# comparison). Devbox's serve-canary is liveness-only, and both frontdoor
# canaries compare a /healthz version against ExecStart instead, so neither
# needs this. "Both call sites" means both sides of that one comparison, not
# both hosts.
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

# opencode_reference_prefix REF_EXE
#
# REF_EXE is `readlink -f`'d from the profile symlink. Echoes the verified
# opencode store prefix to use as the comparison REFERENCE, or nothing at all if
# the reference cannot be trusted (UNKNOWN). NOTICE lines explaining an UNKNOWN
# go to stderr so they reach the journal without polluting the captured value.
#
# The two rejection paths are the whole point and must stay here rather than at
# the call site: "unknown" and "drift" have to be distinguishable, and both of
# the incidents this file records were caused by conflating them.
opencode_reference_prefix() {
  local ref_exe="${1:-}"
  [ -n "$ref_exe" ] || return 0

  if [ ! -x "$ref_exe" ]; then
    printf 'NOTICE: reference binary path is not executable (home-manager switch in flight?); treating as unknown (no alert): %s\n' \
      "$ref_exe" >&2
    return 0
  fi

  local candidate
  candidate="$(opencode_store_prefix "$ref_exe")"
  if opencode_is_opencode_prefix "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf 'NOTICE: reference binary resolved to an unexpected path; treating as unknown (no alert): %s\n' \
    "$ref_exe" >&2
}

# opencode_drift_verdict REF_PREFIX RUN_EXE
#
# Echoes exactly one of FRESH, STALE, UNKNOWN. REF_PREFIX comes from
# opencode_reference_prefix; RUN_EXE is `readlink /proc/<pid>/exe`.
#
# This is the composition the canary actually executes. It lives here, rather
# than being spelled out at the call site, so the tests exercise the deployed
# decision instead of a transcript of it -- a test that re-implements the logic
# it is checking is the same defect as a check that cannot fail.
#
# UNKNOWN is returned whenever either side is untrustworthy: an unverifiable
# reference (home-manager switch in flight) or an unreadable /proc/<pid>/exe
# (process died or is restarting). UNKNOWN must never be treated as drift --
# false alerts during transient states train the operator to ignore the channel,
# after which the alert throttle suppresses the one that matters.
opencode_drift_verdict() {
  local ref_prefix="${1:-}" run_exe="${2:-}" run_prefix

  [ -n "$ref_prefix" ] || { printf 'UNKNOWN\n'; return 0; }
  [ -n "$run_exe" ] || { printf 'UNKNOWN\n'; return 0; }

  run_prefix="$(opencode_store_prefix "$run_exe")"
  [ -n "$run_prefix" ] || { printf 'UNKNOWN\n'; return 0; }

  if [ "$ref_prefix" = "$run_prefix" ]; then
    printf 'FRESH\n'
  else
    printf 'STALE\n'
  fi
}
