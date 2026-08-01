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
row_is_exemption() { printf '%s' "$1" | grep -qE "$LEGAL_ROW_RE"; }

row_names_file() {
  local r="$1" f="$2" row_line paths tok pat
  row_line="$(grep -E "^\| $r \|" "$table" | head -1)"
  [ -n "$row_line" ] || return 1
  paths="$(printf '%s' "$row_line" | awk -F'|' '{print $3}')"
  # Each path token is backticked and may carry a `:12,34` line-number suffix.
  # Match on the PATH only -- this table cites line numbers and has already
  # drifted them twice.
  #
  # Glob-aware, but NOT directory-wide. An earlier version fell back to
  # `dirname`, which let any row naming any sibling file satisfy the check: a
  # home.devbox.nix site could cite D2 (home.darwin.nix) and pass, because both
  # sit in users/dev/. That is the same laundering this function exists to stop,
  # one directory over.
  while read -r tok; do
    [ -n "$tok" ] || continue
    pat="${tok%%:*}"
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2053  # unquoted RHS is deliberate: glob match
    [[ "$f" == $pat ]] && return 0
  done < <(printf '%s' "$paths" | grep -oE '`[^`]+`' | tr -d '`')
  return 1
}

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
# ---------------------------------------------------------------------------
# SITE_RE matches serve-reference TOKENS, not verb+URL shapes.
#
# The first version anchored on `(curl|attach)[^"]*"\$(serve_url|u|OPENCODE_URL)/`
# and an adversarial review demolished it: measured against realistic violation
# shapes it missed SEVEN of NINE, including the two exact lines it had just been
# built to stop regressing (the B2/B3 attach hints, where the quote precedes
# `opencode` and the variable is followed by a space, not a slash). It also let a
# multi-line `curl` through -- the verb sits on a previous line -- which is how it
# reported ALL PASS while an unmarked direct-to-serve degrade leg was added to
# opencode-launch in this very session.
#
# Also removed: the old whole-line skip for any line containing FRONTDOOR_URL or
# `:4700`. That laundered violations by mere mention (`curl "$serve_url/x" #
# unlike the FRONTDOOR_URL path` was skipped). Door references simply are not in
# the token set, so no skip is needed.
#
# Precision matters as much as recall: an intermediate token-only version flagged
# mere MENTIONS (`if [ -z "$serve_url" ]`, assignments, log prose). Marking those
# would have added a dozen markers of no diagnostic value and trained everyone to
# sprinkle them reflexively -- which is how an exemption system stops meaning
# anything. So a "site" is a serve reference USED as a URL base (followed by `/`),
# handed to `attach`, exported as an endpoint env var, or a literal host:port.
# Validated 8/8 real shapes caught, 0/5 mentions falsely caught.
#
# Known remaining gaps (deliberate, documented rather than pretended away):
# indirection through a renamed variable (`base=$serve_url; curl "$base/..."`),
# non-curl verbs reaching a literal host built at runtime, and any consumer in a
# file outside FILE list below. A grep cannot close those. If opacity must be a
# guarantee rather than a convention, the fix is structural -- serves on unix
# sockets or a netns only the door/pigeon/infra can enter -- and this guard
# becomes defense-in-depth. Tracked separately.
# ---------------------------------------------------------------------------
# Serve pool ports are 4096-4099. Matching 4090-4095 previously flagged non-serve
# ports (e.g. test harnesses) and demanded a marker for things that are not serves.
SITE_RE='\$\{?(serve_url|u|OPENCODE_URL|OPENCODE_ANCHOR_URL)\}?/|attach[^"]*\$\{?(serve_url|u|OPENCODE_URL|OPENCODE_ANCHOR_URL)\}?|(PIGEON_SERVE_ENDPOINTS|OPENCODE_URL|OPENCODE_ANCHOR_URL)=|(127\.0\.0\.1|localhost):409[6-9]'

# Legal exemption rows are the EXEMPT classes only. Citing a door row (A*) or a
# repointed-violation row (B*) as an exemption is semantic nonsense and used to
# pass: row_exists() only checked existence.
LEGAL_ROW_RE='^(C|D)[0-9]+$'

# Marker must be on the flagged line or within MARKER_LOOKBACK lines above it.
# Was 10 with `tail -1`, which let any site within ten lines below an existing
# marker inherit that exemption unexamined -- fail-open exactly where violations
# accrete, next to existing serve-addressing code. Tightened to 3 (enough for a
# multi-line curl) and backed by a per-file 1:1 marker:site count assertion, so a
# laundered site shows up as a count mismatch.
MARKER_LOOKBACK=3

echo "--- scanning ${#files[@]} shipped consumer file(s) against ${#table_rows[@]} table row(s)"

declare -A sites_per_file
hits=0
exempted=0
for f in "${files[@]}"; do
  abs="$repo_root/$f"
  while IFS=: read -r lineno _; do
    [ -z "${lineno:-}" ] && continue
    line="$(sed -n "${lineno}p" "$abs")"
    # Skip pure comment lines: prose mentioning a port is not a call site.
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')" in '#'*) continue ;; esac
    # Skip the inert parameterised default (`VAR="${VAR:-http://...}"`). It only
    # puts a value in scope; what the guard cares about is where that value is
    # USED, and every such use is matched on its own line. Marking these too
    # would add ~7 markers of no diagnostic value and train people to sprinkle
    # markers reflexively -- which is how an exemption system stops meaning
    # anything.
    case "$line" in *':-http'*) continue ;; esac
    hits=$((hits + 1))
    sites_per_file[$f]=$(( ${sites_per_file[$f]:-0} + 1 ))
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
    if ! row_is_exemption "$row"; then
      bad "$f:$lineno cites frontdoor-exempt($row), which is a door/repointed row, not an exemption class (use C* or D*)"
      continue
    fi
    if ! row_names_file "$row" "$f"; then
      bad "$f:$lineno cites frontdoor-exempt($row), but row $row does not name $f -- cite a row that describes THIS file, or add one; do not borrow another host's row"
      continue
    fi
    exempted=$((exempted + 1))
  done < <(grep -nE "$SITE_RE" "$abs" 2>/dev/null || true)
done

echo "--- $hits serve-addressing site(s); $exempted carry a valid exemption row"

# Per-file 1:1 accounting. A site that laundered a neighbour's marker leaves
# markers < sites, which no per-site check can see.
for f in "${files[@]}"; do
  abs="$repo_root/$f"
  fsites="${sites_per_file[$f]:-0}"
  fmarks="$(grep -cE 'frontdoor-exempt\((A|B|C|D)[0-9]+\)' "$abs" 2>/dev/null || true)"
  if [ "$fmarks" -gt 0 ] && [ "$fsites" -eq 0 ]; then
    bad "$f: $fmarks frontdoor-exempt marker(s) but ZERO matching sites -- either the markers are stale, or SITE_RE has rotted and stopped seeing this file's sites"
  elif [ "$fsites" -gt 0 ] && [ "$fmarks" != "$fsites" ]; then
    bad "$f: $fsites serve-addressing site(s) but $fmarks marker(s) -- not 1:1, so a site may be laundering a neighbour's exemption"
  fi
done

# Per-file expected site counts. SORTED BY PATH, one file per line.
# Only files with >0 serve-addressing sites are listed. Adding the first site to a
# file requires adding a line here.
#
# WHY NOT A SINGLE SCALAR: `EXPECTED_SITES=14` merged WRONG rather than
# conflicting. Two concurrent PRs each adding one site both write 15; git sees an
# identical edit and merges it clean; both are green in isolation; main lands at 16
# and goes red, blocking everyone *after the fact*. Per-file lines make
# different-file additions merge clean AND correct, and same-file additions collide
# textually so a human must resolve them.
#
# WHY KEEP A COUNT AT ALL, given per-site markers: a NEW site citing an EXISTING
# valid row passes every per-site check silently. Only a count catches that.
#
# To change a number here you must also add the marker and the table row, in the
# same PR. That is the protocol, and it is documented in AGENTS.md.
read -r -d '' EXPECTED_MANIFEST <<'MANIFEST' || true
hosts/cloudbox/configuration.nix 6
hosts/devbox/configuration.nix 2
pkgs/opencode-launch/default.nix 2
pkgs/reset-workspace/default.nix 3
users/dev/home.darwin.nix 1
users/dev/home.devbox.nix 2
MANIFEST

while read -r mfile mcount; do
  [ -z "${mfile:-}" ] && continue
  actual="${sites_per_file[$mfile]:-0}"
  if [ "$actual" -ne "$mcount" ]; then
    bad "$mfile: manifest expects $mcount serve-addressing site(s), found $actual -- if intentional, update the manifest, add the frontdoor-exempt marker, and add/extend the disposition-table row, all in the same PR"
  fi
done <<< "$EXPECTED_MANIFEST"

# A file WITH sites that no manifest line counts is a hole. A file with zero
# sites needs no line: it hides nothing, and demanding one would fail every
# unrelated new package (including the auto-merge bot PRs that add them),
# training people to silence the manifest rather than read it.
for f in "${files[@]}"; do
  [ "${sites_per_file[$f]:-0}" -gt 0 ] || continue
  case "$EXPECTED_MANIFEST" in
    *"$f "*) ;;
    *) bad "$f has ${sites_per_file[$f]} serve-addressing site(s) but no EXPECTED_MANIFEST line -- add one, plus the frontdoor-exempt marker and the disposition-table row, in the same PR" ;;
  esac
done

# A marker must never land INSIDE a shell line-continuation. Inserting one
# between `curl ... \` and its next argument line silently breaks the command:
# the `\` swallows the comment and the following `-X POST ...` starts a new
# command. Bash accepts it; shellcheck (which the nix build runs) rejects it with
# SC2215; and none of the fast checks here would have caught it. That is exactly
# how a broken opencode-launch reached a deploy attempt on 2026-07-26 -- the
# artifact had been built and verified BEFORE the markers were added, and not
# rebuilt after. Cheap to assert, so assert it.
for f in "${files[@]}"; do
  abs="$repo_root/$f"
  while IFS=: read -r ln _; do
    [ -z "${ln:-}" ] && continue
    [ "$ln" -lt 2 ] && continue
    prev="$(sed -n "$((ln - 1))p" "$abs")"
    case "$prev" in
      *\\) bad "$f:$ln marker sits inside a line-continuation (previous line ends with a backslash) -- this breaks the command; move it above the statement" ;;
    esac
  done < <(grep -nE 'frontdoor-exempt\((A|B|C|D)[0-9]+\)' "$abs" 2>/dev/null || true)
done

# Anti-vacuity: if the scan matches nothing, the guard has silently stopped
# guarding (a pattern rename, a file move). That is the failure mode this
# project keeps hitting, so assert the scan still sees the known exemptions.
if [ "$hits" -eq 0 ]; then
  bad "scan matched ZERO sites -- the guard has gone vacuous (pattern or file list drifted)"
else
  note "scan is non-vacuous ($hits site(s) matched)"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME TESTS FAILED"; exit 1; }
