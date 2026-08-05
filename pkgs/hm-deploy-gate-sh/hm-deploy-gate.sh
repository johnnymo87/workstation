#!/usr/bin/env bash
# hm-deploy-gate.sh -- pure logic for the home-manager stale-deploy gate.
#
# WHY THIS EXISTS (bead workstation-h0mp)
# home-manager is last-writer-wins over ONE user profile, but this box runs many
# concurrent swarm worktrees at different commits. On 2026-08-01 09:22 a switch
# from a ~2-day-stale worktree silently un-deployed the session-state writer
# plugin (#230) and a shell-env fix (#225) fleet-wide. Nothing alerted; it was
# found ~32h later by accident. The switch SUCCEEDS and the missing plugin
# produces no output, so the failure is silent on both ends.
#
# WHAT THIS DETECTS, AND WHY THE OBVIOUS CHECK DOES NOT
# The bead's stated MVP -- "verify the expected files exist in the NEW
# generation" -- does not detect either half of that incident. Measured:
#   * `git show 84900bd~1:users/dev/opencode-config.nix | grep -c session-state`
#     is 0. The stale config declared the plugin ZERO times, so its generation
#     CORRECTLY lacked the file. An existence check passes.
#   * the same command for shell-env is 1: declared before and after, so the
#     file existed in both generations and only its CONTENT reverted. An
#     existence check passes.
# home-manager already guarantees declared->linked (activation fails otherwise),
# so that check largely re-tests home-manager. Detecting this class requires
# comparing against a reference OUTSIDE the config being deployed.
#
# THE REFERENCE USED HERE: the currently-deployed revision, recorded by the
# previous switch in a beacon file. The gate refuses when the incoming revision
# does not CONTAIN the deployed one -- i.e. when activating would drop commits
# that are live right now. That needs no network and no plugin inventory: any
# regression is caught regardless of which file changed.
#
# FAIL-CLOSED ON PROOF, FAIL-OPEN ON DOUBT -- deliberately asymmetric.
# This gate can block every agent on a shared box (4 switches landed on
# 2026-08-04 alone). A false refusal is worse than the incident, so the gate
# aborts ONLY on a positive, verifiable regression and otherwise WARNS. Every
# warn path is a hole the drift canary (workstation-4ze8) is meant to cover;
# they are enumerated in hm_gate_verdict below so that bead can consume them.
#
# Consumers: users/dev/home.base.nix (home.activation.assertFreshDeploy).
# Tests: pkgs/hm-deploy-gate-sh/test.sh, wired into `nix flake check` as
# checks.hm-deploy-gate.

# ---------------------------------------------------------------------------
# hm_gate_beacon_rev <beacon-contents>
#
# Extracts the base commit sha from a beacon value. Nix gives the flake source
# rev as `self.rev` for a CLEAN tree and `self.dirtyRev` for a dirty one, and
# those are mutually exclusive -- measured on cloudbox 2026-08-04:
#   clean: rev=a59a911...  dirtyRev=ABSENT
#   dirty: rev=ABSENT      dirtyRev=a59a911...-dirty
# A dirty tree still carries a usable base sha, so the `-dirty` suffix is
# stripped rather than treated as unknown: uncommitted local edits are normal
# here, but the COMMIT the tree sits on is what decides whether activating
# would drop live commits.
#
# Echoes the 40-char sha, or nothing if the value is absent/unknown/malformed.
hm_gate_beacon_rev() {
  local raw="${1-}"
  raw="${raw%$'\n'}"
  raw="${raw%-dirty}"
  # Only a full 40-char hex sha is usable for ancestry. Anything else (empty,
  # "unknown", a tag, a truncated sha) is doubt, not proof.
  if [[ "$raw" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$raw"
  fi
}

# hm_gate_beacon_dirty <beacon-contents>
# Echoes "dirty" if the beacon records an uncommitted tree, else "clean".
hm_gate_beacon_dirty() {
  local raw="${1-}"
  raw="${raw%$'\n'}"
  case "$raw" in
    *-dirty) printf 'dirty\n' ;;
    *)       printf 'clean\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# hm_gate_relation <repo> <incoming-sha> <deployed-sha>
#
# Classifies the incoming revision against the one currently deployed, using
# `git merge-base --is-ancestor`. Echoes exactly one token:
#
#   same           identical revisions
#   contains       incoming has deployed as an ancestor -- moving forward
#   regress        deployed is NOT contained in incoming -- activating would
#                  drop commits that are live right now (covers both the
#                  strictly-older case and the diverged case; both lose commits)
#   unknown-object at least one sha is not present in this repo, so ancestry
#                  cannot be computed
#   no-repo        the repo path is missing or is not a git repository
#
# Read-only: runs only `git cat-file -e` and `git merge-base --is-ancestor`.
# Never fetches, never writes refs, never touches a working tree -- this runs
# during activation on a box where other agents hold live worktrees.
hm_gate_relation() {
  local repo="${1-}" incoming="${2-}" deployed="${3-}"

  if [ -z "$repo" ] || [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'no-repo\n'; return 0
  fi
  if [ -z "$incoming" ] || [ -z "$deployed" ]; then
    printf 'unknown-object\n'; return 0
  fi
  if ! git -C "$repo" cat-file -e "${incoming}^{commit}" 2>/dev/null \
     || ! git -C "$repo" cat-file -e "${deployed}^{commit}" 2>/dev/null; then
    printf 'unknown-object\n'; return 0
  fi
  if [ "$incoming" = "$deployed" ]; then
    printf 'same\n'; return 0
  fi
  if git -C "$repo" merge-base --is-ancestor "$deployed" "$incoming" 2>/dev/null; then
    printf 'contains\n'; return 0
  fi
  printf 'regress\n'
}

# ---------------------------------------------------------------------------
# hm_gate_classify <repo> <incoming-beacon-raw> <deployed-beacon-raw>
#
# The whole decision, from two raw beacon values to a relation token. This
# exists so the activation script and the tests run the SAME dispatch: an
# earlier draft inlined this `if` in users/dev/hm-deploy-gate.nix and mirrored
# it in test.sh, which meant the suite tested its own copy and any drift in the
# real one stayed green. That is the defect bead workstation-dimz is about, and
# it does not get to ship inside the guard family that exists to kill it.
#
# Order matters: a missing DEPLOYED beacon is reported as no-beacon even when
# the incoming rev is also unknown, because that is the self-healing bootstrap
# case (the next switch writes one) and the more actionable label.
hm_gate_classify() {
  local repo="${1-}" inc_raw="${2-}" dep_raw="${3-}"
  local inc dep
  inc="$(hm_gate_beacon_rev "$inc_raw")"
  dep="$(hm_gate_beacon_rev "$dep_raw")"

  if [ -z "$dep" ]; then
    printf 'no-beacon\n'
  elif [ -z "$inc" ]; then
    printf 'unknown-rev\n'
  else
    hm_gate_relation "$repo" "$inc" "$dep"
  fi
}

# ---------------------------------------------------------------------------
# hm_gate_verdict <relation> <allow-stale>
#
# Maps a relation to an action. Echoes "<action>:<reason>" where action is one
# of allow | warn | refuse.
#
# Only `regress` refuses, and only because it is PROVEN: git has both objects
# and says the deployed revision is not reachable from the incoming one, so
# commits that are live right now would be dropped. Everything else is doubt
# and warns -- see the fail-closed-on-proof note at the top of this file.
#
# The warn paths are the canary's ledger (workstation-4ze8):
#   no-beacon      first switch after this gate lands, or a generation deployed
#                  by a config that predates the beacon. Self-healing: the next
#                  switch writes one. A stale worktree that predates the gate
#                  entirely also lands here -- the bootstrap hole, and the
#                  reason a second detector in another deploy channel exists.
#   unknown-object the repo consulted lacks one of the commits, e.g. a worktree
#                  that never fetched the deployed commit. Note this is itself
#                  weak evidence of staleness, but it is not proof, so it warns.
#   no-repo        no clone to compute ancestry in.
#   unknown-rev    the incoming flake source has no rev at all (a path: source,
#                  or an export without git metadata).
hm_gate_verdict() {
  local relation="${1-}" allow_stale="${2-}"

  if [ "$relation" = "regress" ] && [ "$allow_stale" = "1" ]; then
    printf 'warn:override\n'; return 0
  fi

  case "$relation" in
    same)           printf 'allow:same\n' ;;
    contains)       printf 'allow:forward\n' ;;
    regress)        printf 'refuse:regress\n' ;;
    unknown-object) printf 'warn:unknown-object\n' ;;
    no-repo)        printf 'warn:no-repo\n' ;;
    no-beacon)      printf 'warn:no-beacon\n' ;;
    unknown-rev)    printf 'warn:unknown-rev\n' ;;
    *)              printf 'warn:unclassified\n' ;;
  esac
}
