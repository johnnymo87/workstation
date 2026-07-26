#!/usr/bin/env bash
# Phase 9.2 grep-guard — "no other door than the front door."
#
# Mechanically enforces docs/plans/2026-07-26-phase9-consumer-disposition.md:
# no shipped consumer may address an individual serve unless it carries an
# inline exemption marker naming a row of that table.
#
# Run: bash users/dev/test-frontdoor-opacity.sh
#
# ---------------------------------------------------------------------------
# WHY THE MARKER LIVES IN THE CODE, NOT IN A LIST HERE
#
# The two tests this phase had to rewrite (test-pool-route-clients.sh:74 and
# opencode-launch/test.sh:214) both failed the same way: they asserted a
# specific stale string from a distance, stayed green while the world moved,
# and ended up protecting the very call sites they were meant to police. A
# central allowlist of file:line pairs would fail identically -- line numbers
# drift, and nothing forces the list to be revisited when code moves.
#
# So an exemption is a comment ON the exempting line (or within
# MARKER_LOOKBACK lines above it), in the form:
#
#     frontdoor-exempt(<ROW>): <one-line reason>
#
# Properties this buys:
#   - The justification travels with the code under any refactor.
#   - Deleting the call deletes the exemption. No stale entries.
#   - <ROW> must resolve to a real row in the disposition table (checked
#     below), so code and table cannot drift apart silently.
#   - A new direct-to-serve call fails CLOSED: no marker, no pass.
# ---------------------------------------------------------------------------
set -o errexit -o nounset -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
table="$repo_root/docs/plans/2026-07-26-phase9-consumer-disposition.md"

MARKER_LOOKBACK=10
fail=0
note() { printf 'ok: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$table" ]; then
  echo "FAIL: disposition table missing: $table"
  echo "  The guard is meaningless without the table it enforces."
  exit 1
fi

# Row ids defined by the table (| C1 | ... -> C1). These are the only legal
# marker targets.
mapfile -t table_rows < <(grep -oE '^\| (A|B|C|D)[0-9]+ \|' "$table" | tr -d '| ' | sort -u)
if [ "${#table_rows[@]}" -eq 0 ]; then
  bad "could not parse any row ids out of $table (format changed?)"
fi
row_exists() { local r="$1" x; for x in "${table_rows[@]}"; do [ "$x" = "$r" ] && return 0; done; return 1; }

# Files the guard governs: shipped consumer code. Docs, plans and test files
# are excluded -- they describe or perturb these patterns by design.
mapfile -t files < <(cd "$repo_root" && printf '%s\n' \
  pkgs/*/default.nix \
  users/dev/home.base.nix users/dev/home.darwin.nix \
  users/dev/home.devbox.nix users/dev/home.cloudbox.nix \
  hosts/cloudbox/configuration.nix hosts/devbox/configuration.nix \
  2>/dev/null | while read -r f; do [ -f "$repo_root/$f" ] && echo "$f"; done)

# A "serve-addressing site" is a REQUEST against a non-door base, or an env
# export that points a consumer at one. Deliberately not matching bare
# variable defaults (`OPENCODE_URL="${OPENCODE_URL:-...}"`), which merely put a
# value in scope; what matters is where it is USED.
# NB: `[^"]*`, NOT `[^\n]*`. In a POSIX bracket expression `\n` is not a newline
# escape -- `[^\n]` means "neither a backslash nor the letter n". The first draft
# of this guard used it and therefore could not match any call site containing an
# `n` between the verb and the URL, which silently skipped
# reset-workspace/default.nix:490 (`curl ... --connect-timeout 3 "$u/..."`) while
# matching its identical siblings at :822/:862. A guard that under-scans in
# silence is worse than no guard; grep is line-oriented here, so `[^"]*` is both
# correct and tighter.
SITE_RE='(curl|attach)[^"]*"\$(serve_url|u|OPENCODE_URL)/|"http://127\.0\.0\.1:409[0-9][^"]*"|^\s*(export )?"?OPENCODE(_ANCHOR)?_URL(=|\s*=\s*)'

echo "--- scanning ${#files[@]} shipped consumer file(s) against ${#table_rows[@]} table row(s)"

hits=0
exempted=0
for f in "${files[@]}"; do
  abs="$repo_root/$f"
  while IFS=: read -r lineno _; do
    [ -z "${lineno:-}" ] && continue
    line="$(sed -n "${lineno}p" "$abs")"
    # Skip pure comment lines: prose mentioning a port is not a call site.
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
    # A door URL is never a violation.
    case "$line" in *'FRONTDOOR_URL'*|*':4700'*) continue ;; esac
    # Skip the inert parameterised default (`VAR="${VAR:-http://...}"`). It only
    # puts a value in scope; what the guard cares about is where that value is
    # USED, and every such use is matched on its own line. Marking these too
    # would add ~7 markers of no diagnostic value and train people to sprinkle
    # markers reflexively -- which is how an exemption system stops meaning
    # anything.
    case "$line" in *':-http'*) continue ;; esac
    hits=$((hits + 1))
    start=$((lineno > MARKER_LOOKBACK ? lineno - MARKER_LOOKBACK : 1))
    ctx="$(sed -n "${start},${lineno}p" "$abs")"
    marker="$(printf '%s' "$ctx" | grep -oE 'frontdoor-exempt\((A|B|C|D)[0-9]+\)' | tail -1 || true)"
    if [ -z "$marker" ]; then
      bad "$f:$lineno addresses a serve with no frontdoor-exempt marker"
      printf '      %s\n' "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-100)"
      printf '      -> add `frontdoor-exempt(<ROW>): <reason>` citing a row of\n'
      printf '         docs/plans/2026-07-26-phase9-consumer-disposition.md, or route it through the door.\n'
      continue
    fi
    row="$(printf '%s' "$marker" | sed -E 's/frontdoor-exempt\((.*)\)/\1/')"
    if ! row_exists "$row"; then
      bad "$f:$lineno cites frontdoor-exempt($row), which is not a row in the disposition table"
      continue
    fi
    exempted=$((exempted + 1))
  done < <(grep -nE "$SITE_RE" "$abs" 2>/dev/null || true)
done

echo "--- $hits serve-addressing site(s); $exempted carry a valid table row"

# Anti-vacuity: if the scan matches nothing, the guard has silently stopped
# guarding (a pattern rename, a file move). That is the failure mode this
# project keeps hitting, so assert the scan still sees the known exemptions.
if [ "$hits" -eq 0 ]; then
  bad "scan matched ZERO sites -- the guard has gone vacuous (pattern or file list drifted)"
else
  note "scan is non-vacuous ($hits site(s) matched)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
