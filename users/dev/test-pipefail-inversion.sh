#!/usr/bin/env bash
#
# Bans the assertion shape that `set -o pipefail` can silently invert.
#
# THE DEFECT. Written as
#
#     printf '%s\n' "$VAR" | grep -q PAT
#
# under pipefail, `grep -q` exits the instant it matches and closes the pipe; a
# writer still holding data takes EPIPE and returns non-zero; pipefail then
# makes the whole pipeline non-zero EVEN THOUGH THE PATTERN WAS FOUND. The
# assertion inverts -- a match reads as a miss.
#
# Positive-sense uses turn into a false RED, which is merely annoying. The
# dangerous half is negative-sense (`... | grep -q BAD && { echo FAIL; }`),
# where the same inversion produces a false GREEN: the assertion stops checking
# instead of complaining, and nothing anywhere goes red to tell you. That is the
# reason this is a gate and not a style preference. See PRs #431 and #432, which
# removed 57 of these; this exists so number 58 cannot land.
#
# THE FIX IS ALWAYS ONE LINE:
#
#     grep -q PAT <<<"$VAR"
#
# bash writes the entire here-document before exec'ing grep, so there is no
# concurrent writer to receive EPIPE and no pipeline for pipefail to observe.
# (Note the folk justification "here-strings are temp files, not pipes" is
# false below ~64 KiB -- bash uses an anonymous pipe there. The pre-write is
# what makes it safe, not the backing store.)
#
# WHY THIS DOES NOT TRY TO PROVE pipefail IS ACTIVE. It would be tempting to
# only flag files that literally contain `set -o pipefail`. That test cannot be
# made reliable: `pkgs.writeShellApplication` INJECTS pipefail into shell
# embedded in .nix files (which is how the two production sites in #432 --
# including one that could `rm` a live nvim socket -- stayed invisible to a
# *.sh-only search), and any snippet may be sourced into a pipefail context
# later. So the shape is banned unconditionally. The cost of complying is one
# mechanical edit; the cost of reasoning about pipefail reachability per site is
# unbounded. A guard whose fix is cheaper than its exemption stays meaningful.
#
# EXEMPTIONS. A comment ON the offending line, or within 3 lines above it:
#
#     pipefail-exempt: <one-line reason>
#
# and a matching per-file count in EXPECTED_MANIFEST below. Deleting the line
# deletes the exemption, so there are no stale entries. The manifest is per-file
# rather than one scalar because a single number lets two concurrent PRs each
# make it consistent-but-wrong and merge clean; same-file edits are meant to
# collide and be resolved by hand. That lesson is inherited from
# test-frontdoor-opacity.sh, which shipped the scalar version first.
#
# The manifest is currently EMPTY, and that is the intended steady state. If you
# find yourself adding an entry, re-read "the fix is always one line" above.
set -uo pipefail

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# The banned shape. Deliberately NARROW: writer is `printf`/`echo` of a single
# double-quoted variable (including positionals like "$1"), reader is an
# early-exiting `grep -q`. Command writers (`cmd | grep -q`) are NOT matched --
# their mechanical fix is process substitution, and `grep -q P < <(cmd)`
# discards the writer's failure, i.e. it trades this silent-failure class for a
# different one. Those need `out=$(cmd)` first, which is a judgement call, and a
# guard that demands judgement gets exemptions instead of fixes.
#
# CALIBRATED, not guessed. Against the tree at c8169bf~1 (before #431) this
# matches exactly 57 sites -- every one the two sweeps removed by hand -- and 0
# at HEAD. Those two fixed points are the regression oracle for any future edit
# to this pattern: widen it, then re-check 57-and-0 before believing it.
#
# The variable part is any double-quoted string CONTAINING a `$`, not just a
# bare "$VAR". An earlier revision required the quote to sit flush against the
# name, which let through `echo "prefix: $VAR"` (the natural log-line shape) and
# `"${VAR:-}"` (the standard set -u idiom) -- i.e. the two things someone is
# most likely to write next. A quoted string with no `$` in it cannot match, so
# widening this costs no false positives.
SITE_RE='(printf|echo)([[:space:]]+[^|]*)?"[^"]*\$[^"]*"[^|]*\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+|command[[:space:]]+)*grep[[:space:]]+(-[a-zA-Z]*q|--quiet)'
MARKER_RE='pipefail-exempt:'
MARKER_LOOKBACK=3

# scan_tree <root> <file...> -> prints "path:lineno:exempt|violation" per site.
# Factored out so the self-test below can drive it over planted fixtures. A
# detector that has never been shown to detect is decoration.
scan_tree() {
  local root="$1"; shift
  local f abs lineno line start ctx
  for f in "$@"; do
    abs="$root/$f"
    [ -r "$abs" ] || continue
    while IFS=: read -r lineno _; do
      [ -z "${lineno:-}" ] && continue
      line="$(sed -n "${lineno}p" "$abs")"
      # A comment mentioning the shape is documentation, not a call site. This
      # is what keeps the guard from flagging its own header and the AGENTS.md
      # examples.
      case "$(sed -E 's/^[[:space:]]*//' <<<"$line")" in '#'*) continue ;; esac
      # Same, for a TRAILING comment (`foo; # example: printf "$V" | grep -q x`).
      # Strip from the first whitespace-preceded `#` and re-test: if the code
      # part alone no longer matches, the site was inside prose. Note this
      # cannot hide a real site behind a `#` in a grep PATTERN, because the
      # regex stops at the grep flags and never reaches the pattern argument.
      if ! grep -qE "$SITE_RE" <<<"$(sed -E 's/[[:space:]]#.*$//' <<<"$line")"; then
        continue
      fi
      start=$((lineno > MARKER_LOOKBACK ? lineno - MARKER_LOOKBACK : 1))
      ctx="$(sed -n "${start},${lineno}p" "$abs")"
      if grep -qE "$MARKER_RE" <<<"$ctx"; then
        echo "$f:$lineno:exempt"
      else
        echo "$f:$lineno:violation"
      fi
    done < <(grep -nE "$SITE_RE" "$abs" 2>/dev/null || true)
  done
}

# ---------------------------------------------------------------------------
# SELF-TEST. Runs before the real scan. If the regex rots, this fails loudly
# rather than the gate quietly going green over a repo full of violations --
# the exact failure mode a "0 sites found" guard is prone to.
# ---------------------------------------------------------------------------
selftest_dir="$(mktemp -d)"
trap 'rm -rf "$selftest_dir"' EXIT
mkdir -p "$selftest_dir/fx"

cat > "$selftest_dir/fx/violation.sh" <<'FIXTURE'
printf '%s\n' "$OUT" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/exempted.sh" <<'FIXTURE'
# pipefail-exempt: fixture proving the marker is honoured
printf '%s\n' "$OUT" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/commented.sh" <<'FIXTURE'
#   printf '%s\n' "$OUT" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/fixed.sh" <<'FIXTURE'
grep -q 'needle' <<<"$OUT"
FIXTURE

cat > "$selftest_dir/fx/positional.sh" <<'FIXTURE'
row_is_thing() { printf '%s' "$1" | grep -qE "$RE"; }
FIXTURE

# Each of these evaded an earlier revision of SITE_RE. They stay as fixtures so
# a future "simplification" of the pattern reopens the hole loudly.
cat > "$selftest_dir/fx/embedded.sh" <<'FIXTURE'
echo "prefix: $VAR" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/defaulted.sh" <<'FIXTURE'
printf '%s\n' "${VAR:-}" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/longflag.sh" <<'FIXTURE'
printf '%s\n' "$VAR" | grep --quiet 'needle'
FIXTURE

cat > "$selftest_dir/fx/prefixed.sh" <<'FIXTURE'
printf '%s\n' "$VAR" | LC_ALL=C grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/trailing_comment.sh" <<'FIXTURE'
true    # doc: printf '%s\n' "$VAR" | grep -q 'needle'
FIXTURE

cat > "$selftest_dir/fx/nodollar.sh" <<'FIXTURE'
echo "a literal string" | grep -q 'needle'
FIXTURE

st="$(scan_tree "$selftest_dir" \
  fx/violation.sh fx/exempted.sh fx/commented.sh fx/fixed.sh fx/positional.sh \
  fx/embedded.sh fx/defaulted.sh fx/longflag.sh fx/prefixed.sh \
  fx/trailing_comment.sh fx/nodollar.sh)"

expect_line() {
  if grep -qxF "$2" <<<"$st"; then echo "ok: $1"; else
    bad "self-test: $1"; printf '     scan output was:\n%s\n' "$st" >&2
  fi
}
expect_absent() {
  if grep -qE "^$2:" <<<"$st"; then bad "self-test: $1"; else echo "ok: $1"; fi
}

expect_line  "detector flags the banned shape"            "fx/violation.sh:1:violation"
expect_line  "detector honours an inline exemption marker" "fx/exempted.sh:2:exempt"
expect_absent "detector ignores the shape inside a comment" "fx/commented.sh"
expect_absent "detector accepts the here-string fix"        "fx/fixed.sh"
expect_line  "detector catches positional-parameter writers" "fx/positional.sh:1:violation"
expect_line  "detector catches a var embedded in a larger string" "fx/embedded.sh:1:violation"
expect_line  "detector catches \${VAR:-} default-expansion writers" "fx/defaulted.sh:1:violation"
expect_line  "detector catches grep --quiet long form"            "fx/longflag.sh:1:violation"
expect_line  "detector catches an env-prefixed grep"              "fx/prefixed.sh:1:violation"
expect_absent "detector ignores the shape in a TRAILING comment"  "fx/trailing_comment.sh"
expect_absent "detector ignores a quoted string with no variable" "fx/nodollar.sh"

# ---------------------------------------------------------------------------
# THE REAL SCAN
# ---------------------------------------------------------------------------
# `find`, not `git ls-files`: this runs inside a nix build sandbox where ${self}
# is a store copy with no .git and no git binary. That copy already contains
# exactly the tracked files, so find over it is equivalent there -- and when run
# by hand in a worktree it is strictly better, catching a bad line in a file you
# have not committed yet. Prunes are for nested worktrees and build output,
# which are other checkouts' problems, not this tree's.
mapfile -t files < <(
  cd "$repo_root" && find . \
      \( -name .git -o -name .worktrees -o -name node_modules -o -name 'result' -o -name 'result-*' \) -prune -o \
      \( -name '*.sh' -o -name '*.nix' \) -print \
    | sed 's|^\./||' \
    | grep -v '^users/dev/test-pipefail-inversion\.sh$' \
    | sort
)
[ "${#files[@]}" -gt 0 ] || { bad "no .sh/.nix files found under $repo_root -- scan is vacuous"; exit 1; }
# A guard that silently scans nothing is worse than no guard. Floors are
# PER-EXTENSION, not a single total: the whole lesson of #432 was that the
# production sites hid in .nix, and a combined floor of 50 would sit green if a
# glob typo dropped every .nix file (75 .sh alone clears it). A class going
# missing has to be as loud as the whole enumeration going missing.
n_sh=$(printf '%s\n' "${files[@]}" | grep -c '\.sh$' || true)
n_nix=$(printf '%s\n' "${files[@]}" | grep -c '\.nix$' || true)
[ "$n_sh"  -ge 40 ] || bad "only $n_sh .sh file(s) enumerated (expected >=40) -- file discovery has rotted"
[ "$n_nix" -ge 40 ] || bad "only $n_nix .nix file(s) enumerated (expected >=40) -- file discovery has rotted"

results="$(scan_tree "$repo_root" "${files[@]}")"
violations="$(grep ':violation$' <<<"$results" || true)"
exemptions="$(grep ':exempt$' <<<"$results" || true)"

n_viol=$([ -z "$violations" ] && echo 0 || wc -l <<<"$violations")
n_exempt=$([ -z "$exemptions" ] && echo 0 || wc -l <<<"$exemptions")

echo "--- scanned ${#files[@]} .sh/.nix file(s): $n_viol violation(s), $n_exempt exemption(s)"

if [ "$n_viol" -gt 0 ]; then
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    f="${v%%:*}"; rest="${v#*:}"; ln="${rest%%:*}"
    bad "$f:$ln pipes a variable into an early-exiting \`grep -q\` under possible pipefail"
    printf '      %s\n' "$(sed -n "${ln}p" "$repo_root/$f" | sed -E 's/^[[:space:]]*//' | cut -c1-100)" >&2
    printf '      -> rewrite as `grep <flags> PATTERN <<<"$VAR"`, or add `pipefail-exempt: <reason>`\n' >&2
    printf '         on/above the line AND a count for %s in EXPECTED_MANIFEST.\n' "$f" >&2
  done <<<"$violations"
fi

# Per-file exemption manifest. Empty is the intended steady state.
read -r -d '' EXPECTED_MANIFEST <<'MANIFEST' || true
MANIFEST

actual_manifest="$(
  if [ -n "$exemptions" ]; then
    cut -d: -f1 <<<"$exemptions" | sort | uniq -c | awk '{print $2" "$1}'
  fi
)"
expected_manifest="$(grep -vE '^[[:space:]]*(#|$)' <<<"$EXPECTED_MANIFEST" | sort || true)"

if [ "$actual_manifest" != "$expected_manifest" ]; then
  bad "exemption manifest drift"
  printf '      expected:\n%s\n      actual:\n%s\n' \
    "${expected_manifest:-        (none)}" "${actual_manifest:-        (none)}" >&2
  printf '      -> update EXPECTED_MANIFEST in %s\n' "users/dev/test-pipefail-inversion.sh" >&2
else
  echo "ok: exemption manifest matches ($n_exempt exemption(s))"
fi

if [ "$fail" = 0 ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
fi
exit "$fail"
