#!/usr/bin/env bash
# Tests for the home-manager stale-deploy gate (bead workstation-h0mp).
#
# Wired into `nix flake check` as checks.hm-deploy-gate. The relation tests
# build REAL throwaway git repos in $TMPDIR rather than stubbing git, because
# the whole gate rests on `merge-base --is-ancestor` semantics and a stub would
# just assert my own belief about them back at me.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/hm-deploy-gate.sh"

PASS=0; FAIL=0

ok() { # ok <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1" >&2
    echo "  expected: [$2]" >&2
    echo "  actual:   [$3]" >&2
  fi
}

SHA_A=""; SHA_B=""; SHA_C=""; REPO=""

# --- fixture: a repo with a linear main (A -> B) plus a branch off A (C) -----
# This is the incident shape. A is the ~2-day-stale point, B is the commit that
# landed the session-state plugin (#230), C is a branch cut from A that has its
# own work -- the diverged case.
build_repo() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  echo a > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" commit -qm A
  SHA_A="$(git -C "$REPO" rev-parse HEAD)"
  echo b > "$REPO/f"; git -C "$REPO" commit -qam B
  SHA_B="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -b side "$SHA_A"
  echo c > "$REPO/g"; git -C "$REPO" add -A; git -C "$REPO" commit -qm C
  SHA_C="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q main
}
build_repo

# --- hm_gate_beacon_rev ------------------------------------------------------
ok "beacon_rev: clean sha"        "$SHA_A"  "$(hm_gate_beacon_rev "$SHA_A")"
ok "beacon_rev: dirty suffix"     "$SHA_A"  "$(hm_gate_beacon_rev "${SHA_A}-dirty")"
ok "beacon_rev: trailing newline" "$SHA_A"  "$(hm_gate_beacon_rev "$SHA_A
")"
ok "beacon_rev: empty"            ""        "$(hm_gate_beacon_rev "")"
ok "beacon_rev: literal unknown"  ""        "$(hm_gate_beacon_rev "unknown")"
# A short sha cannot be fed to ancestry safely, and must degrade to doubt (warn)
# rather than being silently zero-padded or partially matched.
ok "beacon_rev: short sha"        ""        "$(hm_gate_beacon_rev "${SHA_A:0:12}")"
ok "beacon_rev: non-hex"          ""        "$(hm_gate_beacon_rev "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")"

# --- hm_gate_beacon_dirty ----------------------------------------------------
ok "beacon_dirty: clean" "clean" "$(hm_gate_beacon_dirty "$SHA_A")"
ok "beacon_dirty: dirty" "dirty" "$(hm_gate_beacon_dirty "${SHA_A}-dirty")"

# --- hm_gate_relation --------------------------------------------------------
ok "relation: same"      "same"     "$(hm_gate_relation "$REPO" "$SHA_B" "$SHA_B")"
ok "relation: forward"   "contains" "$(hm_gate_relation "$REPO" "$SHA_B" "$SHA_A")"

# THE INCIDENT: deployed is B (fleet has the plugin), incoming is A (the stale
# worktree). Activating A drops B. This single assertion is the bead.
ok "relation: THE INCIDENT (strictly older)" "regress" \
   "$(hm_gate_relation "$REPO" "$SHA_A" "$SHA_B")"

# Diverged: the stale worktree also has its own commits. It still drops B, so it
# must be refused too -- "is HEAD behind main" would MISS this, because C is not
# an ancestor of B either.
ok "relation: diverged still regresses" "regress" \
   "$(hm_gate_relation "$REPO" "$SHA_C" "$SHA_B")"

ok "relation: unknown object" "unknown-object" \
   "$(hm_gate_relation "$REPO" "0000000000000000000000000000000000000000" "$SHA_B")"
ok "relation: empty incoming" "unknown-object" "$(hm_gate_relation "$REPO" "" "$SHA_B")"
ok "relation: missing repo"   "no-repo"        "$(hm_gate_relation "/nonexistent/xyz" "$SHA_B" "$SHA_A")"
NOTGIT="$(mktemp -d)"
ok "relation: dir is not a repo" "no-repo"     "$(hm_gate_relation "$NOTGIT" "$SHA_B" "$SHA_A")"

# Read-only contract: computing a relation must not create refs, move HEAD, or
# dirty the tree. Other agents hold live worktrees in the repo this consults.
BEFORE="$(git -C "$REPO" rev-parse HEAD)$(git -C "$REPO" status --porcelain)$(git -C "$REPO" for-each-ref)"
hm_gate_relation "$REPO" "$SHA_A" "$SHA_B" >/dev/null
AFTER="$(git -C "$REPO" rev-parse HEAD)$(git -C "$REPO" status --porcelain)$(git -C "$REPO" for-each-ref)"
ok "relation: read-only (no ref/HEAD/tree mutation)" "$BEFORE" "$AFTER"

# --- hm_gate_verdict ---------------------------------------------------------
ok "verdict: same"     "allow:same"           "$(hm_gate_verdict same "")"
ok "verdict: contains" "allow:forward"        "$(hm_gate_verdict contains "")"
ok "verdict: regress"  "refuse:regress"       "$(hm_gate_verdict regress "")"
ok "verdict: unknown-object" "warn:unknown-object" "$(hm_gate_verdict unknown-object "")"
ok "verdict: no-repo"       "warn:no-repo"       "$(hm_gate_verdict no-repo "")"
ok "verdict: no-beacon"     "warn:no-beacon"     "$(hm_gate_verdict no-beacon "")"
ok "verdict: unknown-rev"   "warn:unknown-rev"   "$(hm_gate_verdict unknown-rev "")"
ok "verdict: unrecognised token degrades to warn" "warn:unclassified" \
   "$(hm_gate_verdict wat "")"

# The escape hatch downgrades a refusal but must NOT become silent -- it stays a
# warn so the activation still prints, and it must not affect any other verdict.
ok "verdict: override downgrades refuse" "warn:override"  "$(hm_gate_verdict regress 1)"
ok "verdict: override leaves allow alone" "allow:forward" "$(hm_gate_verdict contains 1)"
# Only the exact value "1" overrides: a stray "0"/"false"/"no" in the env must
# not be read as truthy and silently disarm the gate.
ok "verdict: override ignores 0"     "refuse:regress" "$(hm_gate_verdict regress 0)"
ok "verdict: override ignores false" "refuse:regress" "$(hm_gate_verdict regress false)"

# --- end-to-end: beacon text -> verdict -------------------------------------
# Calls hm_gate_classify, the SAME function the activation script calls. An
# earlier draft re-implemented the dispatch here; that made the suite test its
# own mirror instead of the shipped logic (bead workstation-dimz).
e2e() { # e2e <incoming-beacon> <deployed-beacon>
  hm_gate_verdict "$(hm_gate_classify "$REPO" "$1" "$2")" ""
}

# Direct coverage of the dispatch itself, not only through a verdict.
ok "classify: no deployed beacon"    "no-beacon"   "$(hm_gate_classify "$REPO" "$SHA_B" "")"
ok "classify: unknown beacon text"   "no-beacon"   "$(hm_gate_classify "$REPO" "$SHA_B" "unknown")"
ok "classify: incoming has no rev"   "unknown-rev" "$(hm_gate_classify "$REPO" "unknown" "$SHA_B")"
# Both unknown -> the self-healing bootstrap label wins.
ok "classify: both unknown"          "no-beacon"   "$(hm_gate_classify "$REPO" "unknown" "")"
ok "classify: incident"              "regress"     "$(hm_gate_classify "$REPO" "$SHA_A" "$SHA_B")"
ok "classify: dirty stale"           "regress"     "$(hm_gate_classify "$REPO" "${SHA_A}-dirty" "$SHA_B")"
ok "classify: forward"               "contains"    "$(hm_gate_classify "$REPO" "$SHA_B" "$SHA_A")"
ok "e2e: incident replay"            "refuse:regress" "$(e2e "$SHA_A" "$SHA_B")"
ok "e2e: dirty stale tree refused"   "refuse:regress" "$(e2e "${SHA_A}-dirty" "$SHA_B")"
ok "e2e: dirty current tree allowed" "allow:same"     "$(e2e "${SHA_B}-dirty" "$SHA_B")"
ok "e2e: forward"                    "allow:forward"  "$(e2e "$SHA_B" "$SHA_A")"
ok "e2e: no beacon deployed"         "warn:no-beacon" "$(e2e "$SHA_B" "")"
ok "e2e: incoming has no rev"        "warn:unknown-rev" "$(e2e "unknown" "$SHA_B")"

rm -rf "$REPO" "$NOTGIT"

echo
echo "hm-deploy-gate: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo "hm-deploy-gate: FAILURES PRESENT" >&2
  exit 1
fi
# The check greps for this exact line, so a suite that silently runs zero
# assertions cannot pass as green.
if [ "$PASS" -lt 40 ]; then
  echo "hm-deploy-gate: TOO FEW ASSERTIONS RAN ($PASS) -- suite truncated?" >&2
  exit 1
fi
echo "hm-deploy-gate: ALL PASS"
