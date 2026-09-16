#!/usr/bin/env bash
#
# Guards the per-host split of Bazel's local disk cache in the generated
# ~/.bazelrc (users/dev/home.base.nix, home.activation.generateBazelrc).
#
# WHY THIS EXISTS. The cloudbox rationale for `common --disk_cache=` is entirely
# host-specific -- 15-100 concurrent agent sessions, a nightly purge, a 4ms hop
# to BuildBuddy. None of it holds on the macOS laptop, which has few worktrees,
# no purge, a worse hop, and is sometimes offline, where the local cache is the
# ONLY cache. The failure mode this guard is aimed at is somebody "tidying up"
# the two branches into one shared line, which would silently strip the laptop's
# only offline cache. That is not hypothetical: the first draft of the cloudbox
# change did exactly that, because the --disk_cache line lived in the shared
# prefix rather than in a host branch.
#
# HOW IT CHECKS. Both hosts are asserted against their REAL EVALUATED ACTIVATION
# TEXT, handed in via the BAZELRC_CLOUDBOX_SRC / BAZELRC_DARWIN_SRC seams (same
# seam idea as DISK_WATCH_SRC / DISK_CLEANUP_SRC: a flake check cannot `nix eval`
# its own subject inside the build sandbox). Evaluating one string attribute out
# of darwinConfigurations works on Linux -- it is BUILDING the activation package
# that needs a macOS builder -- so there is no need to fall back to grepping the
# Nix source. A first draft of this file did fall back to source text, with an
# awk extractor keyed on `lib.optionals isDarwin [`; that would have silently
# started reading the wrong block as soon as a second such branch appeared above
# it in home.base.nix.
#
# NOTE ON THE HARNESS, learned the hard way. Every assertion goes through
# assert_ok / assert_not, which run the command inside an `if`. A bare
# `grep -q ...` followed by `check $?` is WRONG under `set -e`: the failing grep
# terminates the script before the reporting line runs, so a real regression
# exits silently with no FAIL line and no tally. The first draft of this file did
# exactly that and three of five mutants died invisibly instead of failing.
#
# Run standalone from the repo root with:
#   nix eval --raw .#homeConfigurations.cloudbox.config.home.activation.generateBazelrc.data > /tmp/cb.rc
#   nix eval --raw ".#darwinConfigurations.\"$(hostname_of_mac)\".config.home-manager.users.\"<user>\".home.activation.generateBazelrc.data" > /tmp/mac.rc
#   BAZELRC_CLOUDBOX_SRC=/tmp/cb.rc BAZELRC_DARWIN_SRC=/tmp/mac.rc \\
#     bash users/dev/test-bazelrc-disk-cache.sh
set -euo pipefail

PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# assert_ok <name> <diagnostic> -- <command...>   (command must SUCCEED)
assert_ok() {
  local name=$1 diag=$2; shift 3   # shift past name, diag, and the "--"
  if "$@"; then pass "$name"; else fail "$name" "$diag"; fi
}

# assert_not <name> <diagnostic> -- <command...>  (command must FAIL)
assert_not() {
  local name=$1 diag=$2; shift 3
  if "$@"; then fail "$name" "$diag"; else pass "$name"; fi
}

# --- Locate the subjects -----------------------------------------------------

for v in BAZELRC_CLOUDBOX_SRC BAZELRC_DARWIN_SRC; do
  if [ -z "${!v:-}" ]; then
    echo "$v is not set -- see header for how to run standalone" >&2
    exit 2
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Copy to files so every grep below reads a file rather than piping a variable
# into an early-exiting grep -- see the Pipefail Inversion Guard in AGENTS.md.
cat "$BAZELRC_CLOUDBOX_SRC" > "$WORK/cloudbox.rc"
cat "$BAZELRC_DARWIN_SRC"   > "$WORK/darwin.rc"

DISK_CACHE_RE='^[[:space:]]*(common|build|test|startup)[[:space:]]+--disk_cache'
EMPTY_FORM_RE='^[[:space:]]*common[[:space:]]+--disk_cache=[[:space:]]*$'
POPULATED_RE='^[[:space:]]*common[[:space:]]+--disk_cache[[:space:]=]+[^[:space:]]'
REMOTE_CACHE_RE='^[[:space:]]*(common|build|test)[[:space:]]+--remote_cache'
GC_TARGET_RE='^[[:space:]]*common[[:space:]]+--experimental_disk_cache_gc_max_size'

# --- Detector self-test ------------------------------------------------------
#
# A rotted regex must fail loudly rather than report a reassuring "0 problems".
# Each pattern is proven to match a positive fixture AND reject a negative one
# before it adjudicates anything real.

cat > "$WORK/fixture-off.rc" <<'EOF'
common --repository_cache ~/bazel-cache/repository
common --disk_cache=
EOF
cat > "$WORK/fixture-on.rc" <<'EOF'
common --repository_cache ~/bazel-cache/repository
common --disk_cache ~/bazel-diskcache
common --experimental_disk_cache_gc_max_size=5G
EOF

count_matches() { grep -Ec "$1" "$2" || true; }

assert_ok "self-test: empty-form regex matches the off fixture" \
  "EMPTY_FORM_RE no longer recognises 'common --disk_cache='" \
  -- grep -Eq "$EMPTY_FORM_RE" "$WORK/fixture-off.rc"

assert_not "self-test: empty-form regex rejects the populated fixture" \
  "EMPTY_FORM_RE wrongly matches a populated --disk_cache line" \
  -- grep -Eq "$EMPTY_FORM_RE" "$WORK/fixture-on.rc"

assert_ok "self-test: populated-form regex matches the on fixture" \
  "POPULATED_RE no longer recognises a --disk_cache with a path" \
  -- grep -Eq "$POPULATED_RE" "$WORK/fixture-on.rc"

assert_not "self-test: populated-form regex rejects the off fixture" \
  "POPULATED_RE wrongly matches the empty form" \
  -- grep -Eq "$POPULATED_RE" "$WORK/fixture-off.rc"

assert_ok "self-test: disk_cache regex counts exactly one line in the on fixture" \
  "DISK_CACHE_RE mis-counts the on fixture" \
  -- test "$(count_matches "$DISK_CACHE_RE" "$WORK/fixture-on.rc")" = 1

# --- Cloudbox: assertions against the real evaluated activation text ----------

N_DISK="$(count_matches "$DISK_CACHE_RE" "$WORK/cloudbox.rc")"
assert_ok "cloudbox rc declares --disk_cache exactly once" \
  "expected 1 --disk_cache line, found $N_DISK" \
  -- test "$N_DISK" = 1

assert_ok "cloudbox rc disables the disk cache with the empty form" \
  "expected a bare 'common --disk_cache='; Bazel 8.5.1 treats only null-or-empty as off" \
  -- grep -Eq "$EMPTY_FORM_RE" "$WORK/cloudbox.rc"

assert_not "cloudbox rc names no disk-cache directory" \
  "a populated --disk_cache path reappeared on cloudbox" \
  -- grep -Eq "$POPULATED_RE" "$WORK/cloudbox.rc"

assert_ok "cloudbox rc keeps the repository cache" \
  "--repository_cache went missing; it is bounded, cheap, and expensive to refill" \
  -- grep -Eq '^[[:space:]]*common[[:space:]]+--repository_cache[[:space:]]+' "$WORK/cloudbox.rc"

# The home rc must never set --remote_cache: it is read AFTER the workspace rc,
# so anything set here shadows mono's grpcs BuildBuddy endpoint. Doing that broke
# every bazel invocation in mono on 2026-09-15 (workstation#530, lgtm-4j2).
# Comment lines mentioning the flag are fine and are deliberately not matched.
assert_not "cloudbox rc sets no --remote_cache" \
  "the home rc must not shadow the workspace's remote cache -- see workstation#530" \
  -- grep -Eq "$REMOTE_CACHE_RE" "$WORK/cloudbox.rc"

# Not load-bearing (an empty --disk_cache makes the GC constructor return null),
# but a leftover target signals the branch was edited without being reread.
assert_not "cloudbox rc carries no orphaned disk-cache GC target" \
  "--experimental_disk_cache_gc_max_size is inert once --disk_cache is empty; drop it" \
  -- grep -Eq "$GC_TARGET_RE" "$WORK/cloudbox.rc"

# --- Darwin: assertions against the real evaluated activation text -----------
#
# This is the half that actually matters. cloudbox's change is the one being
# made, so it will be reread; macOS is the one that gets broken by someone
# tidying two branches into one, months from now, without a laptop to notice on.

N_DISK_MAC="$(count_matches "$DISK_CACHE_RE" "$WORK/darwin.rc")"
assert_ok "darwin rc declares --disk_cache exactly once" \
  "expected 1 --disk_cache line, found $N_DISK_MAC" \
  -- test "$N_DISK_MAC" = 1

assert_ok "darwin rc keeps a POPULATED local disk cache" \
  "macOS lost its disk cache. It is sometimes offline, where that is the ONLY cache." \
  -- grep -Eq "$POPULATED_RE" "$WORK/darwin.rc"

assert_not "darwin rc has not inherited cloudbox's empty form" \
  "macOS must not get --disk_cache= -- none of the cloudbox rationale transfers" \
  -- grep -Eq "$EMPTY_FORM_RE" "$WORK/darwin.rc"

assert_ok "darwin rc keeps its disk-cache GC target" \
  "without a GC target the laptop's cache grows unbounded (2026-08-28 incident)" \
  -- grep -Eq "$GC_TARGET_RE" "$WORK/darwin.rc"

assert_ok "darwin rc keeps the repository cache" \
  "--repository_cache went missing on macOS" \
  -- grep -Eq '^[[:space:]]*common[[:space:]]+--repository_cache[[:space:]]+' "$WORK/darwin.rc"

assert_not "darwin rc sets no --remote_cache" \
  "the home rc must not shadow the workspace's remote cache -- see workstation#530" \
  -- grep -Eq "$REMOTE_CACHE_RE" "$WORK/darwin.rc"

# The whole point of the split: the two hosts must not agree about this.
assert_not "the two hosts' disk-cache policies have not been unified" \
  "cloudbox and macOS render the same --disk_cache line; the split was collapsed" \
  -- cmp -s <(grep -E "$DISK_CACHE_RE" "$WORK/cloudbox.rc") \
            <(grep -E "$DISK_CACHE_RE" "$WORK/darwin.rc")

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
